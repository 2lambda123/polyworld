import re
import common_complexity

####################################################################################
###
### FUNCTION parse_complexities()
###
####################################################################################
def parse_complexities(path):
    """Parses complexities from a given file and returns a dictionary containing version, type, critter numbers, and complexities.
    Parameters:
        - path (str): Path to the file containing complexities.
    Returns:
        - dict: Dictionary containing version, type, critter numbers, and complexities.
    Processing Logic:
        - Opens the file and reads the first 5 million characters.
        - Sets the version based on the first line.
        - Sets the column number and critter numbers if the version is 2.
        - Skips the column headers if the version is 2.
        - Appends complexities to the complexities list.
        - Closes the file.
        - Returns the dictionary containing all the parsed information."""
    
    retval = {}

    f = open(path, 'r')
    line = f.readline(5_000_000)

    retval['version'] = version = get_version(line)

    col_num = None
    col_c = 0
    critter_numbers = None

    if version == 0:
        f.seek(0, 0)
    if version == 2:
        col_num = 0
        col_c = 1
        retval['type'] = get_equals_decl(f.readline(5_000_000), 'type')
        f.readline(5_000_000) # skip column headers
        retval['critter_numbers'] = critter_numbers = []

    retval['complexities'] = complexities = []

    for line in f:
        cols = line.split()

        if version == 2:
            critter_numbers.append(int(cols[col_num]))

        complexities.append(float(cols[col_c]))

    f.close()

    return retval

####################################################################################
###
### FUNCTION write_avr()
###
####################################################################################
def write_avr(path):
    """"""
    
    pass

####################################################################################
###
### FUNCTION parse_avr()
###
####################################################################################
def parse_avr(path):
    """"""
    
    f = open(path, 'r')
    
    version = get_version(f.readline(5_000_000))

    types = {}
    typenames = []

    if version == 2:
        while True:
            typename = seek_next_tag(f)
            if not typename: break

            typenames.append(typename)

            header = f.readline(5_000_000)
            fieldnames = header.split()[1:] # skip leading '#'
            
            fields = {}

            for fname in fieldnames:
                fields[fname] = []

            while True:
                line = f.readline(5_000_000)
                tag = get_end_tag(line)

                if tag:
                    assert(tag == typename)
                    break

                data = line.split()

                assert(len(data) == len(fieldnames))

                for i in range(len(data)):
                    fields[fieldnames[i]].append(data[i])

            types[typename] = {'fieldnames': fieldnames,
                               'fields': fields}

    elif version == 1:
        f.readline(5_000_000) # skip column headers

        typenames = common_complexity.DEFAULT_COMPLEXITIES
        fieldnames = common_complexity.AVR_FIELDS

        for typename in typenames:
            type = types[typename] = {}
            type['fieldnames'] = fieldnames
            type['fields'] = {}
            for field in fieldnames:
                type['fields'][field] = []

        while True:
            data = f.readline(5_000_000).split()
            if len(data) == 0: break

            t = data.pop(0)

            for typename in typenames:
                type = types[typename]
                fields = type['fields']

                for fieldname in fieldnames[1:]: # skip timestep
                    fields[fieldname].append(data.pop(0))
                    
    return {'typenames': typenames,
            'types': types}

        
####################################################################################
###
### FUNCTION write_plot_data()
###
####################################################################################
def write_plot_data(path, types, typenames, fieldnames):
    """"""
    
    f = open(path, 'w')

    for typename in typenames:
        f.write('#<%s>\n' % (typename))

        f.write('#\t')
        for fieldname in fieldnames:
            f.write('%18s ' % (fieldname))
        f.write('\n')

        type = types[typename]
        fields = type['fields']
        nrecords = len(fields[fieldnames[0]]) 

        for i in range(nrecords):
            f.write('\t')
            for fieldname in fieldnames:
                field = fields[fieldname]
                value = field[i]
                f.write('%18s ' % (value))
            f.write('\n')
                

        f.write('#</%s>\n\n\n' % (typename))

    f.close()
