#!/usr/bin/env bash

set -u
set -e
CURRENT_DIR=$(dirname $0)
EXE_DIR=${EXE_DIR:-${CURRENT_DIR}}
PG_REGRESS_PSQL=$1
PSQL=${PSQL:-$PG_REGRESS_PSQL}
PSQL="${PSQL} -X" # Prevent any .psqlrc files from being executed during the tests
TEST_PGUSER=${TEST_PGUSER:-postgres}
TEST_INPUT_DIR=${TEST_INPUT_DIR:-${EXE_DIR}}
TEST_OUTPUT_DIR=${TEST_OUTPUT_DIR:-${EXE_DIR}}
TEST_SUPPORT_FILE=${CURRENT_DIR}/sql/utils/testsupport.sql

# PGAPPNAME will be 'pg_regress/test' so we cut off the prefix
# to get the name of the test (PG 10 and 11 only)
if [[ ${PGAPPNAME} = pg_regress/* ]]; then
  CURRENT_TEST=${PGAPPNAME##pg_regress/}
else
  # PG 9.6 pg_regress does not pass in testname
  # so we generate unique name from pid
  CURRENT_TEST="test_$$"
fi
TEST_DBNAME="db_${CURRENT_TEST}"

# Read the extension version from version.config
read -r VERSION < ${CURRENT_DIR}/../version.config
EXT_VERSION=${VERSION##version = }

#docker doesn't set user
USER=${USER:-`whoami`}

TEST_SPINWAIT_ITERS=${TEST_SPINWAIT_ITERS:-10}

TEST_ROLE_SUPERUSER=${TEST_ROLE_SUPERUSER:-super_user}
TEST_ROLE_DEFAULT_PERM_USER=${TEST_ROLE_DEFAULT_PERM_USER:-default_perm_user}
TEST_ROLE_DEFAULT_PERM_USER_2=${TEST_ROLE_DEFAULT_PERM_USER_2:-default_perm_user_2}

# Users for clustering. These users have password auth enabled in pg_hba.conf
TEST_ROLE_CLUSTER_SUPERUSER=${TEST_ROLE_CLUSTER_SUPERUSER:-cluster_superuser}
TEST_ROLE_CLUSTER_SUPERUSER_PASS=${TEST_ROLE_CLUSTER_SUPERUSER_PASS:-superpass}
TEST_ROLE_DEFAULT_CLUSTER_USER=${TEST_ROLE_DEFAULT_CLUSTER_USER:-default_cluster_user}
TEST_ROLE_DEFAULT_CLUSTER_USER_PASS=${TEST_ROLE_DEFAULT_CLUSTER_USER_PASS:-pass}

shift

function cleanup {
  ${PSQL} $@ -U $TEST_ROLE_SUPERUSER -d postgres -v ECHO=none -c "DROP DATABASE \"${TEST_DBNAME}\";" >/dev/null
}

trap cleanup EXIT

# setup clusterwide settings on first run
if [[ ! -f ${TEST_OUTPUT_DIR}/.pg_init ]]; then
    touch ${TEST_OUTPUT_DIR}/.pg_init
    cat <<EOF | ${PSQL} $@ -U ${USER} -d template1 -v ECHO=none >/dev/null 2>&1
    SET client_min_messages=ERROR;
    ALTER USER ${TEST_ROLE_SUPERUSER} WITH SUPERUSER;
    ALTER USER ${TEST_ROLE_CLUSTER_SUPERUSER} WITH SUPERUSER PASSWORD '${TEST_ROLE_CLUSTER_SUPERUSER_PASS}';
    ALTER USER ${TEST_ROLE_DEFAULT_CLUSTER_USER} WITH CREATEDB PASSWORD '${TEST_ROLE_DEFAULT_CLUSTER_USER_PASS}';
EOF
    ${PSQL} $@ -U $TEST_ROLE_SUPERUSER -d template1 -v ECHO=none -v MODULE_PATHNAME="'timescaledb-${EXT_VERSION}'" < ${TEST_SUPPORT_FILE} >/dev/null 2>&1
fi

cd ${EXE_DIR}/sql

# create database and install timescaledb
${PSQL} $@ -U $TEST_ROLE_SUPERUSER -d postgres -v ECHO=none -c "CREATE DATABASE \"${TEST_DBNAME}\";"
${PSQL} $@ -U $TEST_ROLE_SUPERUSER -d ${TEST_DBNAME} -v ECHO=none -c "set client_min_messages=error; CREATE EXTENSION timescaledb; GRANT USAGE ON FOREIGN DATA WRAPPER timescaledb_fdw TO ${TEST_ROLE_DEFAULT_CLUSTER_USER};"

export TEST_DBNAME

# we strip out any output between <exclude_from_test></exclude_from_test>
# and the part about memory usage in EXPLAIN ANALYZE output of Sort nodes
${PSQL} -U ${TEST_PGUSER} \
     -v ON_ERROR_STOP=1 \
     -v VERBOSITY=terse \
     -v ECHO=all \
     -v DISABLE_OPTIMIZATIONS=off \
     -v TEST_DBNAME="${TEST_DBNAME}" \
     -v TEST_TABLESPACE1_PATH=\'${TEST_TABLESPACE1_PATH}\' \
     -v TEST_TABLESPACE2_PATH=\'${TEST_TABLESPACE2_PATH}\' \
     -v TEST_TABLESPACE3_PATH=\'${TEST_TABLESPACE3_PATH}\' \
     -v TEST_INPUT_DIR=${TEST_INPUT_DIR} \
     -v TEST_OUTPUT_DIR=${TEST_OUTPUT_DIR} \
     -v TEST_SPINWAIT_ITERS=${TEST_SPINWAIT_ITERS} \
     -v ROLE_SUPERUSER=${TEST_ROLE_SUPERUSER} \
     -v ROLE_DEFAULT_PERM_USER=${TEST_ROLE_DEFAULT_PERM_USER} \
     -v ROLE_DEFAULT_PERM_USER_2=${TEST_ROLE_DEFAULT_PERM_USER_2} \
     -v ROLE_CLUSTER_SUPERUSER=${TEST_ROLE_CLUSTER_SUPERUSER} \
     -v ROLE_CLUSTER_SUPERUSER_PASS=${TEST_ROLE_CLUSTER_SUPERUSER_PASS} \
     -v ROLE_DEFAULT_CLUSTER_USER=${TEST_ROLE_DEFAULT_CLUSTER_USER} \
     -v ROLE_DEFAULT_CLUSTER_USER_PASS=${TEST_ROLE_DEFAULT_CLUSTER_USER_PASS} \
     -v MODULE_PATHNAME="'timescaledb-${EXT_VERSION}'" \
     -v TSL_MODULE_PATHNAME="'timescaledb-tsl-${EXT_VERSION}'" \
     -v TEST_SUPPORT_FILE=${TEST_SUPPORT_FILE} \
     $@ -d ${TEST_DBNAME} 2>&1 | sed -e '/<exclude_from_test>/,/<\/exclude_from_test>/d' -e 's! Memory: [0-9]\{1,\}kB!!' -e 's! Memory Usage: [0-9]\{1,\}kB!!'
