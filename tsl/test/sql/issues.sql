-- This file and its contents are licensed under the Timescale License.
-- Please see the included NOTICE for copyright information and
-- LICENSE-TIMESCALE for a copy of the license.

\c :TEST_DBNAME :ROLE_CLUSTER_SUPERUSER;

SET client_min_messages TO ERROR;
DROP DATABASE IF EXISTS data_node_1;
DROP DATABASE IF EXISTS data_node_2;
DROP DATABASE IF EXISTS data_node_3;
SET client_min_messages TO NOTICE;

SELECT * FROM add_data_node('data_node_1', host => 'localhost',
                            database => 'data_node_1');
SELECT * FROM add_data_node('data_node_2', host => 'localhost',
                            database => 'data_node_2');
SELECT * FROM add_data_node('data_node_3', host => 'localhost',
                            database => 'data_node_3');

GRANT USAGE
   ON FOREIGN SERVER data_node_1, data_node_2, data_node_3
   TO :ROLE_1;

-- #168407735
-- Segfault when cancelling long running distributed insert
SET ROLE :ROLE_1;

CREATE TABLE buggy(inserted timestamptz not null, partkey text not null, value float);
SELECT create_distributed_hypertable('buggy', 'inserted', 'partkey');

INSERT INTO buggy
	SELECT now() - random() * interval '2 years', (i/100)::text, random()
FROM
	generate_series(1,1000) AS sub(i);

SET statement_timeout to '1s';

\set ON_ERROR_STOP 0

INSERT INTO buggy
	SELECT now() - random() * interval '2 years', (i/100)::text, random()
FROM
	generate_series(1,300000) AS sub(i);

\set ON_ERROR_STOP 1

RESET ROLE;
DROP DATABASE data_node_1;
DROP DATABASE data_node_2;
DROP DATABASE data_node_3;