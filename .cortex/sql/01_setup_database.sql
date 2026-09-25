-- =============================================================================
-- SupplyChainOS: Database Bootstrap
-- =============================================================================
-- Idempotent script -- safe to re-run. Creates the database, all five schemas,
-- a CSV file format, and an internal stage. Run this FIRST before any other
-- SQL script in the project.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. DATABASE
-- -----------------------------------------------------------------------------
-- Single database that houses every layer of the supply-chain data platform.
CREATE DATABASE IF NOT EXISTS SUPPLYCHAIN_DB;
USE DATABASE SUPPLYCHAIN_DB;


-- -----------------------------------------------------------------------------
-- 2. SCHEMAS
-- -----------------------------------------------------------------------------
-- Drop the auto-created PUBLIC schema -- we use purpose-named schemas only.
DROP SCHEMA IF EXISTS PUBLIC;

-- RAW: Landing zone for source CSV data loaded as-is, no transformations.
CREATE SCHEMA IF NOT EXISTS RAW
    COMMENT = 'Landing zone for source CSV data loaded as-is, no transformations.';

-- STAGING: Cleaned, typed, and validated data. BOM stripped, nulls handled,
-- dates cast, deduplication applied. Intermediate layer between RAW and CORE.
CREATE SCHEMA IF NOT EXISTS STAGING
    COMMENT = 'Cleaned, typed, and validated data between RAW and CORE.';

-- CORE: Canonical star-schema model. Dimension tables (product, location,
-- vehicle) and fact tables (shipment, product_shipment) with foreign keys,
-- computed columns (delivery_days, risk_flag, decision), and window functions.
CREATE SCHEMA IF NOT EXISTS CORE
    COMMENT = 'Canonical star-schema: dimensions, facts, and computed risk columns.';

-- SEMANTIC: Semantic views consumed by Cortex Analyst / Cortex Agent.
-- No raw data stored here -- views and YAML definitions only.
CREATE SCHEMA IF NOT EXISTS SEMANTIC
    COMMENT = 'Semantic views for Cortex Analyst and Cortex Agent.';

-- EVAL: Evaluation and test-harness schema. Holds known-answer test rows,
-- quality checks, and metric snapshots used to validate the pipeline.
CREATE SCHEMA IF NOT EXISTS EVAL
    COMMENT = 'Evaluation test data and quality-check artifacts.';


-- -----------------------------------------------------------------------------
-- 3. FILE FORMAT
-- -----------------------------------------------------------------------------
-- Reusable CSV format matching the five source files (shipment.csv, etc.).
-- SKIP_HEADER = 1       : all source CSVs have a header row
-- FIELD_OPTIONALLY_ENCLOSED_BY : handles the quoted geohash values like
--                                "38.684780,-90.216816"
-- NULL_IF               : treats empty strings and literal NULL/null as NULL
-- ENCODING = 'UTF-8'    : source files contain a UTF-8 BOM on the first column
USE SCHEMA RAW;

CREATE OR REPLACE FILE FORMAT CSV_FF
    TYPE                         = CSV
    SKIP_HEADER                  = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF                      = ('', 'NULL', 'null')
    ENCODING                     = 'UTF-8'
    COMMENT                      = 'Standard CSV format for SupplyChainOS source files.';


-- -----------------------------------------------------------------------------
-- 4. INTERNAL STAGE
-- -----------------------------------------------------------------------------
-- Named internal stage used to PUT the five source CSVs before COPY INTO.
-- Points to CSV_FF so every COPY INTO from this stage auto-applies the format.
CREATE OR REPLACE STAGE SUPPLY_CHAIN_STAGE
    FILE_FORMAT = CSV_FF
    COMMENT     = 'Internal stage for SupplyChainOS source CSV uploads.';


-- -----------------------------------------------------------------------------
-- 5. VERIFY
-- -----------------------------------------------------------------------------
-- Quick sanity check: list all schemas and the stage.
SHOW SCHEMAS IN DATABASE SUPPLYCHAIN_DB;
SHOW STAGES  IN SCHEMA   SUPPLYCHAIN_DB.RAW;

-- =============================================================================
-- Done. Next step: run 02_create_raw_tables.sql
-- =============================================================================
