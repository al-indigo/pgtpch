error() {
  local parent_lineno="$1"
  local message="$2"
  local code="${3:-1}"
  if [[ -n "$message" ]] ; then
    echo "Error on or near line ${parent_lineno}: ${message}; exiting with status ${code}"
  else
    echo "Error on or near line ${parent_lineno}; exiting with status ${code}"
  fi
  postgres_stop 0
  exit "${code}"
}
# on error, print bad line number and exit
trap 'error ${LINENO}' ERR

CONFIGFILE="pgtpch.conf"
NUMTPCHQUERIES=22

# =========================== Functions ======================================

# Parses config files written in format 'optname = optvalue'
# Accepts any number of filenames as an argument. The first encountered setting
# is used.
# Files with names containing spaces are not supported at the moment.
read_conf() {
    # concat all arguments
    CONFFILES=""
    for f in "$@"; do
	CONFFILES="$CONFFILES $f"
    done

    echo "Reading configs $CONFFILES..."
    # Now merge the configs
    # sed removes all the comments started with #
    # grep removes all empty lines
    CONFS=`cat $CONFFILES | sed 's/\#.*//' | grep -v -E '^[[:space:]]*$'`
    # awk uses as a separator '=' with any spaces around it. It remembers
    # keys in an array, and prints the setting only if it is not a duplicate.
    CONFS=`echo "$CONFS" | awk -F' *= *' '!($1 in settings) {settings[$1]; print}'`

    SCALE=$(echo "$CONFS" | awk -F' *= *' '/^scale/{print $2}')
    PGINSTDIR=$(echo "$CONFS" | awk -F' *= *' '/^pginstdir/{print $2}')
    PGDATADIR=$(echo "$CONFS" | awk -F' *= *' '/^pgdatadir/{print $2}')
    PGPORT=$(echo "$CONFS" | awk -F' *= *' '/^pgport/{print $2}')
    TPCHDBNAME=$(echo "$CONFS" | awk -F' *= *' '/^tpchdbname/{print $2}')
    # values for prepare.sh
    TPCHTMP=$(echo "$CONFS" | awk -F' *= *' '/^tpchtmp/{print $2}')
    DBGENPATH=$(echo "$CONFS" | awk -F' *= *' '/^dbgenpath/{print $2}')
    # values for run.sh
    EXTCONFFILE=$(echo "$CONFS" | awk -F' *= *' '/^extconffile/{print $2}')
    COPYDIR=$(echo "$CONFS" | awk -F' *= *' '/^copydir/{print $2}')
    QUERIES=$(echo "$CONFS" | awk -F' *= *' '/^queries/{print $2}')
    WARMUPS=$(echo "$CONFS" | awk -F' *= *' '/^warmups/{print $2}')
    TIMERRUNS=$(echo "$CONFS" | awk -F' *= *' '/^timerruns/{print $2}')
    # precmd might contain '=' symbols, so things are different.
    # \s is whitespace, \K ignores part of line matched before \K.
    PRECMD=$(echo "$CONFS" | grep --perl-regexp --only-matching '^precmd\s*=\s*\K.*')
    PRECMDFILE=$(echo "$CONFS" | awk -F' *= *' '/^precmdfile/{print $2}')
    PGUSER=$(echo "$CONFS" | awk -F' *= *' '/^pguser/{print $2}')

    if [ -z "$PGUSER" ]; then
	PGUSER=`whoami`
    fi
}

# Calculates elapsed time. Use it like this:
# curr_t = $(timer)
# t_elapsed = $(timer $curr_t)
timer() {
    if [[ $# -eq 0 ]]; then
	echo $(date '+%s')
    else
	local  stime=$1
	etime=$(date '+%s')

	if [[ -z "$stime" ]]; then stime=$etime; fi

	dt=$((etime - stime))
	ds=$((dt % 60))
	dm=$(((dt / 60) % 60))
	dh=$((dt / 3600))
	printf '%d:%02d:%02d' $dh $dm $ds
    fi
}

# To perform checks
die() {
    echo "ERROR: $@"
    exit -1;
}

# Wait for all pending jobs to finish except for Postgres itself; it's pid must
# be in $PGPID.
wait_jobs() {
    for p in $(jobs -p); do
	if [ $p != $PGPID ]; then wait $p; fi
    done
}

# Check server PGBINDIR at PGDATADIR is running. Returns 0 if running. PGLIBDIR
# should point to right libs.
server_running() {
    LD_LIBRARY_PATH="$LD_LIBRARY_PATH":"$PGLIBDIR" $PGBINDIR/pg_ctl status \
		   -D $PGDATADIR | grep "server is running" -q
}

# Drop caches
drop_caches() {
  echo -n "Drop caches..."
  sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  echo "done"
}

# Start postgres PGBINDIR at PGDATADIR on PGPORT and save it's pid in PGPID.
# PGLIBDIR should point to right libs.
# Calls drop_caches if $1 is 1
postgres_start() {
    # Check for the running Postgres; exit if there is any on the given port
    PGPORT_PROCLIST="$(lsof -i tcp:$PGPORT | tail -n +2 | awk '{print $2}')"
    if [[ $(echo "$PGPORT_PROCLIST" | wc -w) -gt 0 ]]; then
	echo "The following processes have taken port $PGPORT"
	echo "Please terminate them before running this script"
	echo
	for p in $PGPORT_PROCLIST; do ps -o pid,cmd $p; done
	die ""
    fi

    # Check if a Postgres server is running in the same directory
    if server_running; then
	die "Postgres server is already running in the $PGDATADIR directory.";
    fi

    if [[ "x$1" = "x1" ]]; then
      drop_caches
    fi

    LD_LIBRARY_PATH="$LD_LIBRARY_PATH":"$PGLIBDIR" $PGBINDIR/postgres \
		   -D "$PGDATADIR" -p $PGPORT &
    PGPID=$!
    sleep 2
    while ! server_running; do
	echo "Waiting for the Postgres server to start"
	sleep 2
    done
    sleep 3 # To avoid 'the database system is starting up'
    echo "Postgres server started"
}

# Stop postgres PGBINDIR at PGDATADIR
# PGLIBDIR should point to right libs.
# Calls drop_caches if $1 is 1
postgres_stop() {
    LD_LIBRARY_PATH="$LD_LIBRARY_PATH":"$PGLIBDIR" $PGBINDIR/pg_ctl stop \
		   -D $PGDATADIR
    if [[ "x$1" = "x1" ]]; then
      drop_caches
    fi
}

# Generate queries and put them to $1/queries/qxx.sql, where xx is a number
# of the query. Also generates qxx.explain.sql and qxx.analyze.sql.
# Requires DBGENABSPATH set with path to dbgen
gen_queries() {
    cd "$DBGENABSPATH"
    make -j # build dbgen
    if ! [ -x "$DBGENABSPATH/dbgen" ] || ! [ -x "$DBGENABSPATH/qgen" ]; then
        die "Can't find dbgen or qgen.";
    fi
    mkdir -p "$1/queries"
    for i in $(seq 1 $NUMTPCHQUERIES); do
	ii=$(printf "%02d" $i)
	# DSS_QUERY points to dir with queries that qgen uses to build the actual
	# queries
	DSS_QUERY="$DBGENABSPATH/queries" ./qgen $i > "$1/queries/q${ii}.sql"
	sed 's/^select/explain select/' "$1/queries/q${ii}.sql" > \
	    "$1/queries/q${ii}.explain.sql"
	sed 's/^select/explain analyze select/' "$1/queries/q${ii}.sql" > \
	    "$1/queries/q${ii}.analyze.sql"
    done
    echo "Queries generated"
}
