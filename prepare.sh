#!/usr/bin/env bash
set -e

show_help() {
    cat <<EOF
    Usage: bash ${0##*/} [-s scale] [-i pginstdir] [-d pgdatadir] [-t tpchtmp]
    [-p pgport] [-n tpchdbname] [-g dbgenpath] [-e] [-x] [-h]

    Prepare Postgres cluster for running TPC-H queries:
      * Create Postgres cluster at pgdatadr via initdb from pginstdir
      * Merge configuration from postgresql.conf with default configuration at
      	pgdatadir/postgresql.conf, if the former exists
      * Run the cluster on port pgport
      * Generate *.tbl files with TPC-H data, if needed, using dbgenpath
      * Create database with TPC-H tables named tpchdbname
      * Fill this tables with generated (or existing) data
      * Remove generated data, if needed
      * Create indexes, if needed
      * Reset Postgres state (vacuum-analyze-checkpoint)
      * Generate the queries and put them to PGDATADIR/queries

    Options
    The first six options are read from $CONFIGFILE file, but you can overwrite
    them in command line args. See their meaning in that file. The rest are:

    -e don't generate *.tbl files, use the existing ones
    -r remove generated *.tbl files after use, the are not removed by default
    -x don't create indexes, they are created by default
    -h display this help and exit
EOF
    exit 0
}

source common.sh

GENDATA=true
REMOVEGENDATA=false
CREATEINDEXES=true
OPTIND=1
while getopts "s:i:d:t:p:n:g:erxh" opt; do
    case $opt in
	h)
	    show_help
	    exit 0
	    ;;
	s)
	    SCALE="$OPTARG"
	    ;;
	i)
	    PGINSTDIR="$OPTARG"
	    ;;
	d)
	    PGDATADIR="$OPTARG"
	    ;;
	t)
	    TPCHTMP="$OPTARG"
	    ;;
	p)
	    PGPORT="$OPTARG"
	    ;;
	n)
	    TPCHDBNAME="$OPTARG"
	    ;;
	g)
	    DBGENPATH="$OPTARG"
	    ;;
	e)
	    GENDATA=false
	    ;;
	r)
	    REMOVEGENDATA=true
	    ;;
	s)
	    CREATEINDEXES=false
	    ;;
	\?)
	    show_help >&2
	    exit 1
	    ;;
    esac
done

if [ -z "$SCALE" ]; then die "scale is empty"; fi
if [ -z "$PGINSTDIR" ]; then die "pginstdir is empty"; fi
if [ -z "$PGDATADIR" ]; then die "pgdatadir is empty"; fi
if [ -z "$TPCHTMP" ]; then die "tpchtmp is empty"; fi
if [ -z "$PGPORT" ]; then die "pgport is empty"; fi
if [ -z "$TPCHDBNAME" ]; then die "tpchdbname is empty"; fi
if [[ "$GENDATA"=false && -z "$DBGENPATH" ]]; then die "dbgenpath is empty"; fi

# directory with this script
BASEDIR=`dirname "$(readlink -f "$0")"`
PGBINDIR="${PGINSTDIR}/bin"

# ================== Check it's ok to run pgsql server =========================
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

# ========================== Preparing DB =========================
# Current time
t=$(timer)

# create database cluster
rm -r "$PGDATADIR"
mkdir -p "$PGDATADIR"
$PGBINDIR/initdb -D "$PGDATADIR" --encoding=UTF-8 --locale=C

# copy postgresql settings
if [ -f "$BASEDIR/postgresql.conf" ]; then
    # Merge our config with a default one.
    # sed removes all the comments started with #
    # grep removes all empty lines
    # awk uses as a separator '=' with any spaces around it. It remembers
    # settings in an array, and prints the setting only if it is not a duplicate.
    cat "$BASEDIR/postgresql.conf" "$PGDATADIR/postgresql.conf" |
	sed 's/\#.*//' |
	grep -v -E '^[[:space:]]*$' |
	awk -F' *= *' '!($1 in settings) {settings[$1] = $2; print}' \
	    > "$PGDATADIR/postgresql.conf"
    echo "Postgres config applied"
else
    echo "Config file postgresql.conf not found, using the default"
fi

# Start a new instance of Postgres
postgres_start
exit 0

# create db with this user's name to give access
$PGBINDIR/createdb -h /tmp -p $PGPORT `whoami` --encoding=UTF-8 --locale=C;

echo "Current settings are"
$PGBINDIR/psql -h /tmp -p $PGPORT -c "select name, current_setting(name) from
pg_settings where name in('debug_assertions', 'wal_level',
'checkpoint_segments', 'shared_buffers', 'wal_buffers', 'fsync',
'maintenance_work_mem', 'checkpoint_completion_target', 'max_connections');"

WAL_LEVEL_MINIMAL=`$PGBINDIR/psql -h /tmp -p $PGPORT -c 'show wal_level' -t | grep minimal | wc -l`
DEBUG_ASSERTIONS=`$PGBINDIR/psql -h /tmp -p $PGPORT -c 'show debug_assertions' -t | grep on | wc -l`
if [ $WAL_LEVEL_MINIMAL != 1 ] ; then die "Postgres wal_level is not set to
minimal; 'Elide WAL traffic' optimization cannot be used"; fi
if [ $DEBUG_ASSERTIONS = 1 ] ; then die "Option debug_assertions is enabled"; fi

# generate *.tbl files, if needed
if [ "$GENDATA" = true ]; then
    cd "$BASEDIR"
    cd "$DBGENPATH" || die "dbgen directory not found"
    DBGENABSPATH=`readlink -f "$(pwd)"`
    if ! [ -x "$DBGENABSPATH/dbgen" ] || ! [ -x "$DBGENABSPATH/qgen" ]; then
	die "Can't find dbgen or qgen.";
    fi

    mkdir -p "$TPCHTMP" || die "Failed to create temporary directory: '$TPCHTMP'"
    cd "$TPCHTMP"
    cp "$DBGENABSPATH/dists.dss" . || die "dists.dss not found"
    cp "$DBGENABSPATH/dss.ddl" . || die "dss.ddl not found"
    # Create table files separately to have better IO throughput
    # -v is verbose, -f for overwrtiting existing files, -T <letter> is
    # "generate only table <letter>"
    for TABLENAME in c s n r O L P s; do
	"$DBGENABSPATH/dbgen" -s $SCALE -f -v -T $TABLENAME &
    done
    wait_jobs
    echo "TPC-H data \*.tbl files generated at $TPCHTMP"
fi

$PGBINDIR/createdb -h /tmp -p $PGPORT $TPCHDBNAME --encoding=UTF-8 --locale=C
if [ $? != 0 ]; then die "Error: Can't proceed without database"; fi
TIME=`date`
$PGBINDIR/psql -h /tmp -p $PGPORT -d $TPCHDBNAME -c "comment on database
$TPCHDBNAME is 'TPC-H data, created at $TIME'"
echo "TPC-H database created"

$PGBINDIR/psql -h /tmp -p $PGPORT -d $DB_NAME < "$TPCHTMP/dss.ddl"
echo "TPCH-H tables created"



echo "scale is $SCALE"
echo "pginstdir is $PGINSTDIR"
echo "pgdatadir is $PGDATADIR"
echo "TPCHTMP is $TPCHTMP"
echo "PGPORT is $PGPORT"
echo "TPCHDBNAME is $TPCHDBNAME"
echo "GENDATA is $GENDATA"