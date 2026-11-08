-- 01: Create an empty schema "dw" and make it the default for this session.
-- WARNING: re-running this file drops everything inside dw.
DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA dw;
SET search_path TO dw;
