-- This file defines DDL functions for adding and manipulating hypertables.

-- Converts a regular postgres table to a hypertable.
--
-- main_table - The OID of the table to be converted
-- time_column_name - Name of the column that contains time for a given record
-- partitioning_column - Name of the column to partition data by
-- number_partitions - (Optional) Number of partitions for data
-- associated_schema_name - (Optional) Schema for internal hypertable tables
-- associated_table_prefix - (Optional) Prefix for internal hypertable table names
-- chunk_time_interval - (Optional) Initial time interval for a chunk
-- create_default_indexes - (Optional) Whether or not to create the default indexes.
CREATE OR REPLACE FUNCTION  create_hypertable(
    main_table              REGCLASS,
    time_column_name        NAME,
    partitioning_column     NAME = NULL,
    number_partitions       INTEGER = NULL,
    associated_schema_name  NAME = NULL,
    associated_table_prefix NAME = NULL,
    chunk_time_interval     anyelement = NULL::bigint,
    create_default_indexes  BOOLEAN = TRUE,
    if_not_exists           BOOLEAN = FALSE
)
    RETURNS VOID LANGUAGE PLPGSQL VOLATILE
    SECURITY DEFINER SET search_path = ''
    AS
$BODY$
<<vars>>
DECLARE
    hypertable_row   _timescaledb_catalog.hypertable;
    table_name                 NAME;
    schema_name                NAME;
    table_owner                NAME;
    tablespace_oid             OID;
    tablespace_name            NAME;
    main_table_has_items       BOOLEAN;
    is_hypertable              BOOLEAN;
    chunk_time_interval_actual BIGINT;
    time_type                  REGTYPE;
BEGIN
    SELECT relname, nspname, reltablespace
    INTO STRICT table_name, schema_name, tablespace_oid
    FROM pg_class c
    INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
    WHERE c.OID = main_table;

    SELECT tableowner
    INTO STRICT table_owner
    FROM pg_catalog.pg_tables
    WHERE schemaname = schema_name
          AND tablename = table_name;

    IF table_owner <> session_user THEN
        RAISE 'Must be owner of relation %', table_name
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- tables that don't have an associated tablespace has reltablespace OID set to 0
    -- in pg_class and there is no matching row in pg_tablespace
    SELECT spcname
    INTO tablespace_name
    FROM pg_tablespace t
    WHERE t.OID = tablespace_oid;

    EXECUTE format('SELECT TRUE FROM _timescaledb_catalog.hypertable WHERE
                    hypertable.schema_name = %L AND
                    hypertable.table_name = %L',
                    schema_name, table_name) INTO is_hypertable;

    IF is_hypertable THEN
       IF if_not_exists THEN
          RAISE NOTICE 'hypertable % already exists, skipping', main_table;
              RETURN;
        ELSE
              RAISE EXCEPTION 'hypertable % already exists', main_table
              USING ERRCODE = 'IO110';
          END IF;
    END IF;

    EXECUTE format('SELECT TRUE FROM %s LIMIT 1', main_table) INTO main_table_has_items;

    IF main_table_has_items THEN
        RAISE EXCEPTION 'the table being converted to a hypertable must be empty'
        USING ERRCODE = 'IO102';
    END IF;

    -- We don't use INTO STRICT here because that error (no column) is surfaced later.
    SELECT atttypid
    INTO time_type
    FROM pg_attribute
    WHERE attrelid = main_table AND attname = time_column_name;

    -- Timestamp types can use default value, integral should be an error if NULL
    IF time_type IN ('TIMESTAMP', 'TIMESTAMPTZ', 'DATE') THEN
        IF chunk_time_interval IS NULL THEN
            chunk_time_interval_actual := _timescaledb_internal.interval_to_usec('1 month');
        ELSIF pg_typeof(chunk_time_interval) IN ('INT'::regtype, 'SMALLINT'::regtype, 'BIGINT'::regtype) THEN
            chunk_time_interval_actual := chunk_time_interval::BIGINT;
            IF chunk_time_interval_actual < _timescaledb_internal.interval_to_usec('1 second') THEN 
                RAISE WARNING 'You specified a chunk_time_interval of less than a second, make sure that this is what you intended'
                USING HINT = 'chunk_time_interval is specified in microseconds';
            END IF;
        ELSIF pg_typeof(chunk_time_interval) = 'INTERVAL'::regtype THEN
            SELECT (EXTRACT(EPOCH FROM chunk_time_interval)*1000000)::BIGINT
            INTO STRICT chunk_time_interval_actual;
        ELSE
            RAISE EXCEPTION 'chunk_time_interval needs to be an INTERVAL or integer type for TIMESTAMP, TIMESTAMPTZ, or DATE time columns'
            USING ERRCODE = 'IO102';
        END IF;
    ELSIF time_type IN ('SMALLINT', 'INTEGER', 'BIGINT') THEN
        IF chunk_time_interval IS NULL THEN
            RAISE EXCEPTION 
            'chunk_time_interval needs to be explicitly set for time columns of type SMALLINT, INTEGER, and BIGINT'
            USING ERRCODE = 'IO102';
        ELSIF pg_typeof(chunk_time_interval) IN ('INT'::regtype, 'SMALLINT'::regtype, 'BIGINT'::regtype) THEN
            chunk_time_interval_actual := chunk_time_interval::BIGINT;
        ELSE
            RAISE EXCEPTION 'chunk_time_interval needs to be an integer type for SMALLINT, INTEGER, and BIGINT time columns'
            USING ERRCODE = 'IO102';
        END IF;
    ELSE
        chunk_time_interval_actual := chunk_time_interval;
    END IF;

    -- Bounds check for integral timestamp types
    IF time_type = 'INTEGER'::REGTYPE AND chunk_time_interval_actual > 2147483647 THEN
        RAISE EXCEPTION 'chunk_time_interval is too large for type INTEGER (max: 2147483647)'
        USING ERRCODE = 'IO102';
    ELSIF time_type = 'SMALLINT'::REGTYPE AND chunk_time_interval_actual > 65535 THEN
        RAISE EXCEPTION 'chunk_time_interval is too large for type SMALLINT (max: 65535)'
        USING ERRCODE = 'IO102';
    END IF;

    BEGIN
        SELECT *
        INTO hypertable_row
        FROM  _timescaledb_internal.create_hypertable_row(
            main_table,
            schema_name,
            table_name,
            time_column_name,
            partitioning_column,
            number_partitions,
            associated_schema_name,
            associated_table_prefix,
            chunk_time_interval_actual,
            tablespace_name
        );
    EXCEPTION
        WHEN unique_violation THEN
            IF if_not_exists THEN
               RAISE NOTICE 'hypertable % already exists, skipping', main_table;
               RETURN;
            ELSE
               RAISE EXCEPTION 'hypertable % already exists', main_table
               USING ERRCODE = 'IO110';
            END IF;
        WHEN foreign_key_violation THEN
            RAISE EXCEPTION 'database not configured for hypertable storage (not setup as a data-node)'
            USING ERRCODE = 'IO101';
    END;

    PERFORM _timescaledb_internal.add_constraint(hypertable_row.id, oid)
    FROM pg_constraint
    WHERE conrelid = main_table;

    PERFORM 1
    FROM pg_index,
    LATERAL _timescaledb_internal.add_index(
        hypertable_row.id,
        hypertable_row.schema_name,
        (SELECT relname FROM pg_class WHERE oid = indexrelid::regclass),
        _timescaledb_internal.get_general_index_definition(indexrelid, indrelid, hypertable_row)
    )
    WHERE indrelid = main_table AND _timescaledb_internal.need_chunk_index(hypertable_row.id, pg_index.indexrelid)
    ORDER BY pg_index.indexrelid;

    PERFORM 1
    FROM pg_trigger,
    LATERAL _timescaledb_internal.add_trigger(
        hypertable_row.id,
        oid
    )
    WHERE tgrelid = main_table
    AND _timescaledb_internal.need_chunk_trigger(hypertable_row.id, oid);

    IF create_default_indexes THEN
        PERFORM _timescaledb_internal.create_default_indexes(hypertable_row, main_table, partitioning_column);
    END IF;
END
$BODY$;

CREATE OR REPLACE FUNCTION  add_dimension(
    main_table              REGCLASS,
    column_name             NAME,
    number_partitions       INTEGER = NULL,
    interval_length         BIGINT = NULL
)
    RETURNS VOID LANGUAGE PLPGSQL VOLATILE AS
$BODY$
<<main_block>>
DECLARE
    table_name       NAME;
    schema_name      NAME;
    hypertable_row   _timescaledb_catalog.hypertable;
BEGIN
    SELECT relname, nspname
    INTO STRICT table_name, schema_name
    FROM pg_class c
    INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
    WHERE c.OID = main_table;

    SELECT *
    INTO STRICT hypertable_row
    FROM _timescaledb_catalog.hypertable h
    WHERE h.schema_name = main_block.schema_name
    AND h.table_name = main_block.table_name
    FOR UPDATE;

    PERFORM _timescaledb_internal.add_dimension(main_table,
                                                hypertable_row,
                                                column_name,
                                                number_partitions,
                                                interval_length);
END
$BODY$;

-- Update chunk_time_interval for a hypertable
CREATE OR REPLACE FUNCTION  set_chunk_time_interval(
    main_table              REGCLASS,
    chunk_time_interval     BIGINT
)
    RETURNS VOID LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
    main_table_name       NAME;
    main_schema_name      NAME;
BEGIN
    SELECT relname, nspname
    INTO STRICT main_table_name, main_schema_name
    FROM pg_class c
    INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
    WHERE c.OID = main_table;

    UPDATE _timescaledb_catalog.dimension d
    SET interval_length = set_chunk_time_interval.chunk_time_interval
    FROM _timescaledb_internal.dimension_get_time(
        (
            SELECT id
            FROM _timescaledb_catalog.hypertable h
            WHERE h.schema_name = main_schema_name AND
            h.table_name = main_table_name
    )) time_dim
    WHERE time_dim.id = d.id;
END
$BODY$;

-- Restore the database after a pg_restore.
CREATE OR REPLACE FUNCTION restore_timescaledb()
    RETURNS VOID LANGUAGE SQL VOLATILE AS
$BODY$
    SELECT _timescaledb_internal.setup_main(true);
$BODY$;

-- Drop chunks that are older than a timestamp.
-- TODO how does drop_chunks work with integer time tables?
CREATE OR REPLACE FUNCTION drop_chunks(
    older_than TIMESTAMPTZ,
    table_name  NAME = NULL,
    schema_name NAME = NULL
)
    RETURNS VOID LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
    older_than_internal BIGINT;
BEGIN
    SELECT (EXTRACT(epoch FROM older_than)*1e6)::BIGINT INTO older_than_internal;
    PERFORM _timescaledb_internal.drop_chunks_older_than(older_than_internal, table_name, schema_name);
END
$BODY$;

-- Drop chunks older than an interval.
CREATE OR REPLACE FUNCTION drop_chunks(
    older_than  INTERVAL,
    table_name  NAME = NULL,
    schema_name NAME = NULL
)
    RETURNS VOID LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
    older_than_ts TIMESTAMPTZ;
BEGIN
    older_than_ts := now() - older_than;
    PERFORM drop_chunks(older_than_ts, table_name, schema_name);
END
$BODY$;

CREATE OR REPLACE FUNCTION attach_tablespace(
       hypertable REGCLASS,
       tablespace NAME
)
    RETURNS VOID LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
    main_schema_name  NAME;
    main_table_name   NAME;
    hypertable_id     INTEGER;
    tablespace_oid    OID;
BEGIN
    SELECT nspname, relname
    FROM pg_class c INNER JOIN pg_namespace n
    ON (c.relnamespace = n.oid)
    WHERE c.oid = hypertable
    INTO STRICT main_schema_name, main_table_name;

    SELECT id
    FROM _timescaledb_catalog.hypertable h
    WHERE (h.schema_name = main_schema_name)
    AND (h.table_name = main_table_name)
    INTO hypertable_id;

    IF hypertable_id IS NULL THEN
       RAISE EXCEPTION 'No hypertable "%" exists', main_table_name
       USING ERRCODE = 'IO101';
    END IF;

    PERFORM _timescaledb_internal.attach_tablespace(hypertable_id, tablespace);
END
$BODY$;
