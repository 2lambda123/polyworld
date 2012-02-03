#!/bin/bash

if [ -z "$PWFARM_SCRIPTS_DIR" ]; then
    source $( dirname $BASH_SOURCE )/__pwfarm_runutil.sh || exit 1
else
    source $PWFARM_SCRIPTS_DIR/__pwfarm_runutil.sh || exit 1
fi

function usage()
{
    cat >&2 <<EOF
usage: $( basename $0 ) [-w:p:N:a:D:f:o:] run_id

ARGS:

   run_id         If using -w, specifies Run ID of new run. If using -p, this is
                the root Run ID, where each overlay clause is given its own Run ID
                like <run_id>/overlay_<clause_index>.

                  If not using -w, then run_id is operated on hierarchically where any
                Run IDs beginning with run_id will be processed. For example,
                'frun -a ... foo' would operate on runs with Run IDs
                {foo/overlay_0, foo/overlay_1}. Also note that wildcards may be used,
                but should be contained within quotes.

OPTIONS:

   -w worldfile
                  Path of local worldfile to be executed. If not provided, it is
                assumed a run already exists on the farm of run_id.

   -p parms_overlay
                  Path of local worldfile overlay file. Allows for setting parameters
                on a per-run basis.

   -N num_seeds
                  Specify number of RNG seeds to be executed. When not using overlays,
                this specifies the total number of runs. When used with overlays, this
                specifies the number of runs per overlay clause.

                  If specified without a worldfile, it is assumed runs of this Run ID already
                exist, but with number of individual runs < N. For example, if a previous
                -N -w had been executed with N=3, you could then exeute -N 10 to cause an
                additional 7 runs to be executed. Note this mode will operate hierarchically
                on Run ID.

   -a analysis_script
                  Path of script that is to be executed after simulation.

   -D driven_runid
                  Specify Run ID of driven run, meaning that you are executing passive.
                Does not support -N, -p, or -w.

   -F fetch_list
                Files to be pulled back from run. For example:

                    -F "condprop/*.log brain/"

                If a directory is specified, then all of its content including
                subdirectories is fetched. Note that you may fetch an entire run
                directory via "-F .".

                The following is always fetched so scripts properly operate:

                    $IMPLICIT_FETCH_LIST

   -f fields
                  Specify fields on which this should run. Must be a single argument,
                so use quotes. e.g. -f "0 1" or -f "{0..3}"

   -o run_owner
                  Specify owner of run.
EOF

    if [ ! -z "$1" ]; then
	echo >&2
	err $*
    fi

    exit 1
}

if [ -z "$1" ]; then
    usage
fi

if [ "$1" == "--field" ]; then
    field=true
else
    field=false
fi

if ! $field; then
    validate_farm_env

    ########################
    ###                  ###
    ### EXECUTE ON LOCAL ###
    ###                  ###
    ########################

    WORLDFILE="nil"
    OVERLAY="nil"
    NRUNS="nil"
    POSTRUN="nil"
    DRIVEN="nil"
    OWNER=$( pwenv pwuser )
    FETCH_LIST="$DEFAULT_FETCH_LIST"

    while getopts "w:p:N:a:D:f:o:F:" opt; do
	case $opt in
	    w)
		WORLDFILE="$OPTARG"
		;;
	    p)
		OVERLAY="$OPTARG"
		;;
	    N)
		NRUNS="$OPTARG"
		is_integer "$NRUNS" || err "-N value must be integer"
		[ "$NRUNS" -gt "0" ] || err "-N value must be > 0"
		;;
	    a)
		POSTRUN="$OPTARG"
		;;
	    D)
		DRIVEN="$OPTARG"
		validate_runid "$DRIVEN"
		;;
	    f)
		__pwfarm_config env set fieldnumbers "$OPTARG"
		validate_farm_env
		;;
	    o)
		OWNER="$OPTARG"
		;;
	    F)
		FETCH_LIST="$OPTARG"
		;;
	    *)
		exit 1
		;;
	esac
    done

    if [ "$OVERLAY" != "nil" ]; then
	[ "$WORLDFILE" != "nil" ] || err "-p requires -w"
    fi

    if [ "$WORLDFILE" == "nil" ]; then
	if [ "$POSTRUN" == "nil" ] && [ "$NRUNS" == "nil" ] && [ "$DRIVEN" == "nil" ]; then
	    err "Nothing to do -- without -w, you must use -a or -N or -D"
	fi
    fi

    if [ "$DRIVEN" != "nil" ]; then
	[ "$WORLDFILE" == "nil" ] || err "-D doesn't support -w"
	[ "$NRUNS" == "nil" ] || err "-D doesn't support -N"
	[ "$OVERLAY" == "nil" ] || err "-D doesn't support -p"
    fi

    shift $(( $OPTIND - 1 ))
    if [ $# -lt 1 ]; then
	usage "Missing arguments"
    elif [ $# -gt 1 ]; then
	shift
	usage "Unexpected arguments: $*"
    fi

    RUNID="$( normalize_runid "$1" )"

    if [ "$WORLDFILE" != "nil" ] || [ "$DRIVEN" != "nil" ]; then
	validate_runid "$RUNID"
    else
	# Wildcards are allowed when -w not used.
	validate_runid --wildcards "$RUNID"
    fi

    TMP_DIR=$( create_tmpdir )
    PAYLOAD_DIR=$TMP_DIR/payload
    TASKS_DIR=$TMP_DIR/tasks
    RUN_PACKAGE_DIR=$PAYLOAD_DIR/run_package
    WORLDFILE_DIR=$PAYLOAD_DIR/worldfiles
    OVERLAY_DIR=$PAYLOAD_DIR/overlays

    mkdir -p $PAYLOAD_DIR
    mkdir -p $TASKS_DIR
    mkdir -p $RUN_PACKAGE_DIR
    mkdir -p $WORLDFILE_DIR
    mkdir -p $OVERLAY_DIR

    TASKS=""

     if [ "$WORLDFILE" != "nil" ]; then
	#
	# Have Worldfile
	#
	if [ "$OVERLAY" != "nil" ]; then
	    #
	    # Have Overlay
	    #
	    noverlays=$( proputil len "$OVERLAY" overlays ) || exit 1

	    # Verify we can apply the overlay, for catching errors quickly.
	    mkdir -p $TMP_DIR/overlay

	    for (( i=0; i < $noverlays; i++ )); do
		(
		    success=false
		    if proputil overlay "$WORLDFILE" "$OVERLAY" $i >$TMP_DIR/overlay/$i; then
			if proputil apply $POLYWORLD_DIR/default.wfs $TMP_DIR/overlay/$i >/dev/null; then
			    success=true
			fi
		    fi
		    if ! $success; then
			touch $TMP_DIR/overlay/fail
		    fi
		) &
	    done

	    wait

	    [ ! -e $TMP_DIR/overlay/fail ] || exit 1


	    if [ "$NRUNS" == "nil" ]; then
		nruns=1
		rngseed=false
	    else
		nruns=$NRUNS
		rngseed=true
	    fi

	    #
	    # Place overlay in payload
	    #
	    cp $OVERLAY $OVERLAY_DIR/overlay.wfo || exit 1

	    #
	    # Define Overlay Tasks
	    #
	    taskid=0
	    for (( ioverlay=0; ioverlay < $noverlays; ioverlay++ )); do
		for (( nid=0; nid < $nruns; nid++ )); do
		    path=$TASKS_DIR/$taskid
		    TASKS="$TASKS $path"

		    taskmeta set $path id $taskid
		    taskmeta set $path nid $nid
		    taskmeta set $path runid $RUNID/overlay_$ioverlay
		    taskmeta set $path rngseed $rngseed
		    taskmeta set $path ioverlay $ioverlay
		    taskmeta set $path overlay overlay.wfo

		    taskid=$(( $taskid + 1 ))
		done
	    done
	else
	    #
	    # No Overlay
	    #
	    if [ "$NRUNS" != "nil" ]; then
		ntasks=$NRUNS
	    else
		ntasks=$( len $(pwenv fieldnumbers) )
	    fi

	    #
	    # Define Worldfile Tasks
	    #
	    for (( taskid=0; taskid < $ntasks; taskid++ )); do
		path=$TASKS_DIR/$taskid
		TASKS="$TASKS $path"

		taskmeta set $path id $taskid
		taskmeta set $path nid $taskid
		taskmeta set $path rngseed true
	    done
	fi
	
	#
	# Place Worldfile in payload and update tasks to reference it.
	#
	cp $WORLDFILE $WORLDFILE_DIR/worldfile.wf || exit 1
	for path in $TASKS; do
	    taskmeta set $path worldfile worldfile.wf
	done
     elif [ "$DRIVEN" != "nil" ]; then
	 #
	 # Executing Passive
	 #
	 driven_runs=$( find_runs_local "$OWNER" "$DRIVEN" )

	 if [ -z "$driven_runs" ]; then
	     err "Cannot find local driven run data. Please fetch run data."
	 fi

	 taskid=0

	 for run in $driven_runs; do
	     assert [ -e $run/.pwfarm/fieldnumber ]
	     assert [ -e $run/.pwfarm/nid ]
	     assert [ -e $run/normalized.wf ]

	     fieldnumber=$(cat $run/.pwfarm/fieldnumber)

	     nid=$(cat $run/.pwfarm/nid)
	     #
	     # Following three lines of code are a work around
	     # for an error in the data migration to the task-based
	     # farm run format. The correct fix would be to update
	     # all the run/.pwfarm/nid files, but this will do for now.
	     # TODO: Fix the nid files.
	     #
	     if [[ $nid == "" ]]; then
		 nid=$fieldnumber
	     fi
	     assert [ "run_$nid" == "$(basename $run)" ]

	     path=$TASKS_DIR/$taskid
	     TASKS="$TASKS $path"

	     taskmeta set $path id $taskid
	     taskmeta set $path required_field $fieldnumber
	     taskmeta set $path nid $nid
	     taskmeta set $path runid $RUNID
	     taskmeta set $path driven_nid $nid
	     taskmeta set $path driven_runid $DRIVEN
	     taskmeta set $path rngseed false

	     cp $run/normalized.wf $WORLDFILE_DIR/worldfile_${taskid}.wf || exit 1
	     taskmeta set $path worldfile worldfile_${taskid}.wf

	     taskid=$(( $taskid + 1 ))

	 done

	 rm -f $TMP_DIR/failed
	 for wf in $WORLDFILE_DIR/*.wf; do
	     (
		 wfutil.py edit $wf PassiveLockstep=True || touch $TMP_DIR/failed
	     ) &
	 done

	 wait

	 [ ! -e $TMP_DIR/failed ] || err "Failed setting PassiveLockstep property"

     else
	#
	# No Worldfile
	#
	runs=$( find_runs_local "$OWNER" "$RUNID" )

	if [ -z "$runs" ]; then
	    err "Cannot find local run data. Please fetch run data."
	fi

	if [ "$NRUNS" == "nil" ]; then
	    #
	    #  Define Analysis Tasks
	    #
	    taskid=0

	    fieldnumbers=$( pwenv fieldnumbers )

	    for run in $runs; do
		assert [ -e $run/.pwfarm/fieldnumber ]
		assert [ -e $run/.pwfarm/nid ]

		fieldnumber=$(cat $run/.pwfarm/fieldnumber)

		if contains $fieldnumbers $fieldnumber; then
		    nid=$(cat $run/.pwfarm/nid)
		    #
		    # Following three lines of code are a work around
		    # for an error in the data migration to the task-based
		    # farm run format. The correct fix would be to update
		    # all the run/.pwfarm/nid files, but this will do for now.
		    # TODO: Fix the nid files.
		    #
		    if [[ $nid == "" ]]; then
			nid=$fieldnumber
		    fi
		    assert [ "run_$nid" == "$(basename $run)" ]

		    path=$TASKS_DIR/$taskid
		    TASKS="$TASKS $path"

		    taskmeta set $path id $taskid
		    taskmeta set $path required_field $fieldnumber
		    taskmeta set $path nid $nid
		    taskmeta set $path runid $( parse_stored_run_path_local --runid $run )

		    #
		    # Package the Checksums
		    #
		    checksums=$RUN_PACKAGE_DIR/checksums_$taskid
		    $POLYWORLD_SCRIPTS_DIR/archive_delta.sh checksums \
			$checksums \
			$run \
			"$FETCH_LIST $IMPLICIT_FETCH_LIST"

		    taskid=$(( $taskid + 1 ))
		fi

	    done
	else
	    #
            # Define tasks for appending runs
	    #
	    runids=$(
		for run in $runs; do
		    parse_stored_run_path_local --runid $run
		done |
		sort |
		uniq
	    )

	    taskid=0

	    for runid in $runids; do
		runs=$( find_runs_local "$OWNER" "$runid" )
		run0=$( stored_run_path_local $OWNER $runid 0 )
		nruns=$( echo $runs | wc -w )

		echo "Executing $(python -c "print max(0, $NRUNS - $nruns)") runs for $runid"

		for (( nid=$nruns; nid < $NRUNS; nid++ )); do
		    path=$TASKS_DIR/$taskid
		    TASKS="$TASKS $path"

		    taskmeta set $path append "true"
		    taskmeta set $path id $taskid
		    taskmeta set $path nid $nid
		    taskmeta set $path runid $runid
		    taskmeta set $path rngseed "true"

		    cp $run0/farm.wf $WORLDFILE_DIR/worldfile${taskid}.wf
		    taskmeta set $path worldfile worldfile${taskid}.wf

		    if [ -e $run0/.pwfarm/ioverlay ]; then
			assert [ -e $run0/parms.wfo ]

			cp $run0/parms.wfo $OVERLAY_DIR/overlay${taskid}.wfo
			taskmeta set $path overlay overlay${taskid}.wfo

			taskmeta set $path ioverlay $( cat $run0/.pwfarm/ioverlay )
		    fi

		    taskid=$(( $taskid + 1 ))
		done
	    done
	fi
    fi

    #
    # Set Common Task Properties
    #
    fieldnumbers=$( pwenv fieldnumbers )
    for path in $TASKS; do
	taskmeta set $path command "./pwfarm_run.sh --field"
	taskmeta set $path prompterr "true"
	taskmeta set $path sudo "false"

	if ! taskmeta has $path append; then
	    taskmeta set $path append "false"
	fi

	if ! taskmeta has $path runid; then
	    taskmeta set $path runid $RUNID
	fi

	taskmeta set $path outputdir "$( stored_run_path_local $OWNER $(taskmeta get $path runid) $(taskmeta get $path nid) )"
	if [ $(len $TASKS) -gt $(len $fieldnumbers) ]; then
	    taskmeta set $path statusid "$(taskmeta get $path id)"
	fi
    done

    ###
    ### Create Payload
    ###

    cp $0 $PAYLOAD_DIR/pwfarm_run.sh || exit 1

    function cpopt()
    {
	if [ "$1" != "nil" ]; then
	    cp "$1" "$PAYLOAD_DIR/$2" || exit 1
	fi
    }

    cpopt "$POSTRUN" postrun.sh

    echo "$OWNER" > $PAYLOAD_DIR/owner

    for x in "$FETCH_LIST"; do
	echo "$x" >> $RUN_PACKAGE_DIR/input
    done

    PAYLOAD=$TMP_DIR/payload.tbz

    pushd_quiet .
    cd $PAYLOAD_DIR
    archive pack $PAYLOAD .
    popd_quiet

    ##
    ## Execute
    ##
    dispatcher dispatch $PAYLOAD $TASKS

    rm -rf $TMP_DIR
    rm -rf $overlay_tmpdir
else
    ##############################
    ###                        ###
    ### EXECUTE ON REMOTE HOST ###
    ###                        ###
    ##############################

    if [ ! -e "$POLYWORLD_PWFARM_APP_DIR" ]; then
	err "No app directory! Please do a pwfarm_build."
    fi

    lock_app || exit 1

    PAYLOAD_DIR=$( pwd )
    cd "$POLYWORLD_PWFARM_APP_DIR" || exit 1

    if PWFARM_TASKMETA has worldfile; then
	export POLYWORLD_PWFARM_WORLDFILE="$PAYLOAD_DIR/worldfiles/$(PWFARM_TASKMETA get worldfile)"
    fi
    export POLYWORLD_PWFARM_RUN_PACKAGE=$PAYLOAD_DIR/run_package/input

    export DISPLAY=:0.0 # for Linux -- allow graphics from ssh
    ulimit -n 4096      # for Mac -- allow enough file descriptors
    ulimit -c unlimited # for Mac -- generate core dump on trap
    export PATH=$( canonpath scripts ):$( canonpath bin ):$PATH

    OWNER=$(cat $PAYLOAD_DIR/owner)
    RUNID=$(PWFARM_TASKMETA get runid)
    NID=$(PWFARM_TASKMETA get nid)
    BATCHID=$( PWFARM_TASKMETA get batchid )

    ###
    ### If a run is already here, store it away.
    ###
    store_orphan_run ./run

    # These files will be used for run identity if our run gets orphaned.
    echo $OWNER > ./owner
    echo $RUNID > ./runid
    echo $NID > ./nid

    ###
    ### If we're running Polyworld, make sure a run with a conflicting ID doesn't already exist.
    ###
    if PWFARM_TASKMETA has worldfile; then
	if $( PWFARM_TASKMETA get append ); then
	    opt_batch="--ignorebatch"
	fi
	if conflicting_run_exists $opt_batch $OWNER $RUNID $NID $BATCHID; then
	    # conflicting_run_exists will print details to stderr
	    err "Aborting due to conflicting run!"
	fi
    fi

    if ! PWFARM_TASKMETA has worldfile; then
	###
	### No worldfile, so relocate requested run to current directory
	###
	unstore_run $OWNER $RUNID $NID ./run || exit 1
    else
	###
	### Worldfile exists, so exec Polyworld
	###

	###
	### Process Parms Overlay
	###
	if PWFARM_TASKMETA has overlay; then
	    ioverlay=$(PWFARM_TASKMETA get ioverlay)
	    PATH_OVERLAY="$PAYLOAD_DIR/overlays/$(PWFARM_TASKMETA get overlay)"
	    proputil overlay $POLYWORLD_PWFARM_WORLDFILE $PATH_OVERLAY $ioverlay > ./worldfile || exit 1
	else
	    cp $POLYWORLD_PWFARM_WORLDFILE ./worldfile || exit 1
	fi

	if $( PWFARM_TASKMETA get rngseed ); then
	    ###
	    ### Set the seed based on NID
	    ###
	    if [ "$NID" == "0" ]; then
		seed=42
	    else
		seed="$NID"
	    fi
	    ./scripts/wfutil edit ./worldfile InitSeed=$seed || exit 1
	fi

	if PWFARM_TASKMETA has driven_runid; then
	    driven_runid=$( PWFARM_TASKMETA get driven_runid )
	    driven_nid=$( PWFARM_TASKMETA get driven_nid )
	    driven_run=$( stored_run_path_field "good" "$OWNER" "$driven_runid" "$driven_nid" )
	    [ -e $driven_run ] || err "Cannot find driven run dir $driven_run"
	    cp $driven_run/BirthsDeaths.log ./LOCKSTEP-BirthsDeaths.log || exit 1
	fi

	########################
	###                  ###
	### Run Polyworld!!! ###
	###                  ###
	########################
	PWFARM_STATUS "Polyworld"

	./Polyworld --status ./worldfile
	exitval=$?

	if ! is_good_run --exit $exitval ./run; then
	    store_failed_run $OWNER $RUNID $NID ./run
	    exit 1
	fi

	cp $POLYWORLD_PWFARM_WORLDFILE run/farm.wf
	if [ ! -z "$PATH_OVERLAY" ]; then
	    cp $PATH_OVERLAY run/parms.wfo
	fi

	mkdir -p run/.pwfarm
	echo $( pwenv fieldnumber ) > run/.pwfarm/fieldnumber
	echo $( PWFARM_TASKMETA get nid ) > run/.pwfarm/nid
	echo $BATCHID > run/.pwfarm/batchid
	if PWFARM_TASKMETA has ioverlay; then
	    PWFARM_TASKMETA get ioverlay > run/.pwfarm/ioverlay
	fi
    fi

    ###
    ### Execute the postrun script
    ###
    postrun_failed=false

    if [ -f $PAYLOAD_DIR/postrun.sh ]; then
	PWFARM_STATUS "Analysis Script"

	chmod +x $PAYLOAD_DIR/postrun.sh

	if ! $PAYLOAD_DIR/postrun.sh; then
	    postrun_failed=true
	fi
    fi

    PWFARM_STATUS "Package Run"

    ###
    ### Store a code snapshot
    ###
    if [ -e $PAYLOAD_DIR/postrun.sh ]; then
	scripts/run_history.sh src run $postrun_failed $PAYLOAD_DIR/postrun.sh
    else
	scripts/run_history.sh src run "false"
    fi

    ###
    ### Create archive pulled to workstation
    ###
    cd run || err "postrun script moved ./run!!!"

    $POLYWORLD_PWFARM_SCRIPTS_DIR/archive_delta.sh archive \
	-e $PAYLOAD_DIR/run_package/checksums_$(PWFARM_TASKMETA get id) \
	$PWFARM_OUTPUT_ARCHIVE \
	. \
	"$( cat $POLYWORLD_PWFARM_RUN_PACKAGE ) $IMPLICIT_FETCH_LIST"

    cd ..

    ###
    ### Store run
    ###
    store_good_run $OWNER $RUNID $NID "./run"

    ###
    ### Exit
    ###
    unlock_app

    if $postrun_failed; then
	exit 1
    else
	exit 0
    fi
fi