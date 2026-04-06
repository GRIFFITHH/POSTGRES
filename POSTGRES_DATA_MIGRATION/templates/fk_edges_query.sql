-- Run this on each TO-BE database to extract FK dependency edges.
-- This query is read-only.
SELECT
  current_database() AS target_db,
  child_ns.nspname AS child_schema,
  child_tbl.relname AS child_table,
  parent_ns.nspname AS parent_schema,
  parent_tbl.relname AS parent_table
FROM pg_constraint con
JOIN pg_class child_tbl ON child_tbl.oid = con.conrelid
JOIN pg_namespace child_ns ON child_ns.oid = child_tbl.relnamespace
JOIN pg_class parent_tbl ON parent_tbl.oid = con.confrelid
JOIN pg_namespace parent_ns ON parent_ns.oid = parent_tbl.relnamespace
WHERE con.contype = 'f'
ORDER BY 1,2,3,4,5;
