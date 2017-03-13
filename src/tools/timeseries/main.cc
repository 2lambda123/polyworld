#include <iostream>
#include <limits>
#include <stdlib.h>
#include <string>
#include <string.h>

#include "brain/Brain.h"
#include "brain/NeuronModel.h"
#include "brain/RqNervousSystem.h"
#include "sim/globals.h"
#include "utils/AbstractFile.h"
#include "utils/analysis.h"
#include "utils/misc.h"

struct Args {
    std::string run;
    std::string stage;
    int repeats;
    int transient;
    int steps;
    int start;
    int count;
    bool passive;
    bool bf;
    std::string output;
};

void printUsage(int, char**);
bool tryParseArgs(int, char**, Args&);
void printArgs(const Args&);
void printHeader(int, RqNervousSystem*);
void printTimeSeries(RqNervousSystem*, int, int);
void writeBrainFunction(AbstractFile*, int, RqNervousSystem*, int, int, int);

int main(int argc, char** argv) {
    Args args;
    if (!tryParseArgs(argc, argv, args)) {
        printUsage(argc, argv);
        return 1;
    }
    if (args.bf) {
        makeDirs(args.output);
    } else {
        printArgs(args);
    }
    analysis::initialize(args.run);
    int maxAgent = analysis::getMaxAgent(args.run);
    for (int index = 0; index < args.count; index++) {
        int agent = args.start + index;
        if (agent > maxAgent) {
            break;
        }
        RqNervousSystem* cns = analysis::getNervousSystem(args.run, agent, args.stage, args.passive);
        if (cns == NULL) {
            continue;
        }
        cns->getBrain()->freeze();
        if (args.bf) {
            char path[256];
            sprintf(path, "%s/brainFunction_%d.txt", args.output.c_str(), agent);
            AbstractFile* file = AbstractFile::open(globals::recordFileType, path, "w");
            writeBrainFunction(file, agent, cns, args.repeats, args.transient, args.steps);
            delete file;
        } else {
            printHeader(agent, cns);
            std::cout << "# BEGIN ENSEMBLE" << std::endl;
            for (int index = 0; index < args.repeats; index++) {
                printTimeSeries(cns, args.transient, args.steps);
            }
            std::cout << "# END ENSEMBLE" << std::endl;
        }
        delete cns;
    }
    return 0;
}

void printUsage(int argc, char** argv) {
    std::cerr << "Usage: " << argv[0] << " [--passive] [--bf OUTPUT] RUN STAGE REPEATS TRANSIENT STEPS [START [COUNT]]" << std::endl;
    std::cerr << std::endl;
    std::cerr << "Generates neural activation time series using random inputs." << std::endl;
    std::cerr << std::endl;
    std::cerr << "  RUN          Run directory" << std::endl;
    std::cerr << "  STAGE        Life stage (incept, birth, or death)" << std::endl;
    std::cerr << "  REPEATS      Number of time series per agent" << std::endl;
    std::cerr << "  TRANSIENT    Initial number of timesteps to ignore" << std::endl;
    std::cerr << "  STEPS        Number of timesteps to display" << std::endl;
    std::cerr << "  START        Starting agent index" << std::endl;
    std::cerr << "  COUNT        Number of agents" << std::endl;
    std::cerr << std::endl;
    std::cerr << "  --passive    Use passive agents" << std::endl;
    std::cerr << "  --bf OUTPUT  Write brain function files to OUTPUT directory" << std::endl;
}

bool tryParseArgs(int argc, char** argv, Args& args) {
    if (argc < 6 || argc > 11) {
        return false;
    }
    std::string run;
    std::string stage;
    int repeats;
    int transient;
    int steps;
    int start = 1;
    int count = std::numeric_limits<int>::max();
    bool passive = false;
    bool bf = false;
    std::string output;
    try {
        int argi = 1;
        if (strcmp(argv[argi], "--passive") == 0) {
            passive = true;
            argi++;
        }
        if (strcmp(argv[argi], "--bf") == 0) {
            bf = true;
            argi++;
            output = std::string(argv[argi++]);
            if (exists(output)) {
                return false;
            }
        }
        run = std::string(argv[argi++]);
        if (!exists(run + "/endStep.txt")) {
            return false;
        }
        stage = std::string(argv[argi++]);
        if (stage != "incept" && stage != "birth" && stage != "death") {
            return false;
        }
        repeats = atoi(argv[argi++]);
        if (repeats < 1) {
            return false;
        }
        transient = atoi(argv[argi++]);
        if (transient < 0) {
            return false;
        }
        steps = atoi(argv[argi++]);
        if (steps < 1) {
            return false;
        }
        if (argc > argi) {
            start = atoi(argv[argi++]);
            if (start < 1) {
                return false;
            }
            if (argc > argi) {
                count = atoi(argv[argi++]);
                if (count < 1) {
                    return false;
                }
            }
        }
    } catch (...) {
        return false;
    }
    args.run = run;
    args.stage = stage;
    args.repeats = repeats;
    args.transient = transient;
    args.steps = steps;
    args.start = start;
    args.count = count;
    args.passive = passive;
    args.bf = bf;
    args.output = output;
    return true;
}

void printArgs(const Args& args) {
    std::cout << "# BEGIN ARGUMENTS" << std::endl;
    std::cout << "stage = " << args.stage << std::endl;
    std::cout << "repeats = " << args.repeats << std::endl;
    std::cout << "transient = " << args.transient << std::endl;
    std::cout << "steps = " << args.steps << std::endl;
    std::cout << "# END ARGUMENTS" << std::endl;
}

void printHeader(int agent, RqNervousSystem* cns) {
    std::cout << "# AGENT " << agent << std::endl;
    NeuronModel::Dimensions dims = cns->getBrain()->getDimensions();
    std::cout << "# DIMENSIONS";
    std::cout << " " << dims.numNeurons;
    std::cout << " " << dims.numInputNeurons;
    std::cout << " " << dims.numOutputNeurons;
    std::cout << std::endl;
}

void printTimeSeries(RqNervousSystem* cns, int transient, int steps) {
    cns->getBrain()->randomizeActivations();
    for (int step = 1; step <= transient; step++) {
        cns->update(false);
    }
    NeuronModel::Dimensions dims = cns->getBrain()->getDimensions();
    double* activations = new double[dims.numNeurons];
    std::cout << "# BEGIN TIME SERIES" << std::endl;
    for (int step = 1; step <= steps; step++) {
        cns->update(false);
        cns->getBrain()->getActivations(activations, 0, dims.numNeurons);
        for (int neuron = 0; neuron < dims.numNeurons; neuron++) {
            if (neuron > 0) {
                std::cout << " ";
            }
            std::cout << activations[neuron];
        }
        std::cout << std::endl;
    }
    std::cout << "# END TIME SERIES" << std::endl;
    delete[] activations;
}

void writeBrainFunction(AbstractFile* file, int agent, RqNervousSystem* cns, int repeats, int transient, int steps) {
    NeuronModel::Dimensions dims = cns->getBrain()->getDimensions();
    file->printf("version 1\n");
    file->printf("brainFunction %d %d %d %d\n", agent, dims.numNeurons, dims.numInputNeurons, dims.numOutputNeurons);
    double* activations = new double[dims.numNeurons];
    for (int index = 0; index < repeats; index++) {
        cns->getBrain()->randomizeActivations();
        for (int step = 1; step <= transient; step++) {
            cns->update(false);
        }
        for (int step = 1; step <= steps; step++) {
            cns->update(false);
            cns->getBrain()->getActivations(activations, 0, dims.numNeurons);
            for (int neuron = 0; neuron < dims.numNeurons; neuron++) {
                file->printf("%d %g\n", neuron, activations[neuron]);
            }
        }
    }
    file->printf("end fitness = 0\n");
    delete[] activations;
}
