#!/bin/bash

set -e
readonly ME=${0##*/}
readonly SRCDIR=$(dirname $0)

QUERY_DIR=$SRCDIR/queries
BENCHMARKS_REPO="$GOPATH/src/github.com/dgraph-io/benchmarks"
SCHEMA_FILE="$BENCHMARKS_REPO/data/21million.schema"
DATA_FILE="$BENCHMARKS_REPO/data/21million.rdf.gz"

# this may be used to load a smaller data set when testing the test itself
#DATA_FILE="$BENCHMARKS_REPO/data/goldendata.rdf.gz"

function Info {
    echo -e "INFO: $*"
}

function DockerCompose {
    docker-compose -p dgraph "$@"
}

HELP= LOADER=bulk CLEANUP= SAVEDIR= LOAD_ONLY= QUIET=

ARGS=$(/usr/bin/getopt -n$ME -o"h" -l"help,loader:,cleanup:,savedir:,load-only,quiet" -- "$@") || exit 1
eval set -- "$ARGS"
while true; do
    case "$1" in
        -h|--help)      HELP=yes;              ;;
        --loader)       LOADER=${2,,}; shift   ;;
        --cleanup)      CLEANUP=${2,,}; shift  ;;
        --savedir)      SAVEDIR=${2,,}; shift  ;;
        --load-only)    LOAD_ONLY=yes          ;;
        --quiet)        QUIET=yes              ;;
        --)             shift; break           ;;
    esac
    shift
done

if [[ $HELP ]]; then
    cat <<EOF
usage: $ME [-h|--help] [--loader=<bulk|live|none>] [--cleanup=<all|none|servers>] [--savedir=path]

options:

    --loader        bulk = use dgraph bulk (default)
                    live = use dgraph live
                    none = use data loaded by previous run
    --cleanup       all = take down containers and data volume (default)
                    servers = take down dgraph zero and alpha but leave data volume up
                    none = leave up containers and data volume
    --savedir=path  specify a directory to save test failure json in
                    for easier post-test review
    --load-only     load data but do not run tests
    --quiet         just report which queries differ, without a diff
EOF
    exit 0
fi

if [[ $LOADER != bulk && $LOADER != live && $LOADER != none ]]; then
    echo >&2 "$ME: loader must be 'bulk' or 'live' or 'none' -- $LOADER"
    exit 1
fi

# default to leaving the data around for another run
# if already re-using it from a previous run
if [[ $LOADER == none && -z $CLEANUP ]]; then
    CLEANUP=servers
fi

# default to cleaning up both services and volume
if [[ -z $CLEANUP  ]]; then
    CLEANUP=all
elif [[ $CLEANUP != all && $CLEANUP != servers && $CLEANUP != none ]]; then
    echo >&2 "$ME: cleanup must be 'all' or 'servers' or 'none' -- $LOADER"
    exit 1
fi

# default to quiet mode if diffs are being saved in a directory
if [[ -n $SAVEDIR ]]; then
    QUIET=yes
fi

Info "entering directory $SRCDIR"
cd $SRCDIR

if [[ $LOADER != none ]]; then
    Info "removing old data (if any)"
    DockerCompose down -v --remove-orphans
else
    Info "using previously loaded data"
fi

Info "bringing up zero container"
DockerCompose up -d --remove-orphans --force-recreate zero1

Info "waiting for zero to become leader"
DockerCompose logs -f zero1 | grep -q -m1 "I've become the leader"

if [[ $LOADER == bulk ]]; then
    Info "bulk loading data set"
    DockerCompose run -v $BENCHMARKS_REPO:$BENCHMARKS_REPO --name bulk_load --rm alpha1 \
        bash -s <<EOF
            /gobin/dgraph bulk --schema=$SCHEMA_FILE --files=$DATA_FILE \
                               --format=rdf --zero=zero1:5180 --out=/data/alpha1/bulk
            mv /data/alpha1/bulk/0/p /data/alpha1
EOF
fi

Info "bringing up alpha container"
DockerCompose up -d --force-recreate alpha1

Info "waiting for alpha to be ready"
DockerCompose logs -f alpha1 | grep -q -m1 "Server is ready"
# after the server prints the log "Server is ready", it may be still loading data from badger
Info "sleeping for 10 seconds for the server to be ready"
sleep 10

if [[ $LOADER == live ]]; then
    Info "live loading data set"
    dgraph live --schema=$SCHEMA_FILE --files=$DATA_FILE \
                --format=rdf --zero=:5180 --alpha=:9180 --logtostderr
fi

if [[ $LOAD_ONLY ]]; then
    Info "exiting after data load"
    exit 0
fi

# replace variables if set with the corresponding option
SAVEDIR=${SAVEDIR:+-savedir=$SAVEDIR}
QUIET=${QUIET:+-quiet}

Info "running benchmarks/regression queries"

if [[ ! -z "$TEAMCITY_VERSION" ]]; then
    # Make TeamCity aware of Go tests
    export GOFLAGS="-json"
fi
go test -v -tags standalone $SAVEDIR $QUIET || FOUND_DIFFS=1

if [[ $CLEANUP == all ]]; then
    Info "bringing down zero and alpha and data volumes"
    DockerCompose down -v
elif [[ $CLEANUP == none ]]; then
    Info "leaving up zero and alpha"
else
    Info "bringing down zero and alpha only"
    DockerCompose down
fi

if [[ $FOUND_DIFFS -eq 0 ]]; then
    Info "no diffs found in query results"
else
    Info "found some diffs in query results"
fi

exit $FOUND_DIFFS
