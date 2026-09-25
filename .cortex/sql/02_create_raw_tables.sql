-- =============================================================================
-- SupplyChainOS: RAW Table DDL
-- =============================================================================
-- Creates five RAW tables that mirror the source CSVs column-for-column.
-- All source columns are VARCHAR (no type inference at the RAW layer).
-- Column order matches CSV header order so COPY INTO works without mapping.
--
-- Every source column is NOT NULL (data dictionary confirms zero nulls across
-- all five files). Two audit columns are appended to each table:
--   LOAD_TIMESTAMP  -- when the row was loaded into Snowflake
--   SOURCE_FILE     -- which staged file the row came from (METADATA$FILENAME)
--
-- Depends on: 01_setup_database.sql (database + schemas + file format + stage)
-- =============================================================================

USE DATABASE SUPPLYCHAIN_DB;
USE SCHEMA RAW;


-- =============================================================================
-- 1. RAW_SHIPMENT  (source: shipment.csv, 83 rows, 15 columns)
-- =============================================================================
-- One row per shipment. Contains denormalized vehicle and location attributes.
-- Column order: matches shipment.csv header exactly.
-- =============================================================================
CREATE OR REPLACE TABLE RAW_SHIPMENT (
    -- source columns (CSV column order)
    VEHICLE_UNIT_CAPACITY       VARCHAR NOT NULL   COMMENT 'shipment.csv → vehicle_unit_capacity | Max unit capacity of assigned vehicle',
    SHIPMENT_ID                 VARCHAR NOT NULL   COMMENT 'shipment.csv → shipment_id | UUID, unique per shipment',
    SHIPMENT_NAME               VARCHAR NOT NULL   COMMENT 'shipment.csv → shipment_name | Human label (Shipment 1..83)',
    ORIGIN_LOCATION_NAME        VARCHAR NOT NULL   COMMENT 'shipment.csv → origin_location_name | Origin facility name (denorm from location)',
    DESTINATION_LOCATION_NAME   VARCHAR NOT NULL   COMMENT 'shipment.csv → destination_location_name | Destination facility name (denorm from location)',
    ORIGIN_LOCATION_ID          VARCHAR NOT NULL   COMMENT 'shipment.csv → origin_location_id | FK → location.location_id',
    DESTINATION_LOCATION_ID     VARCHAR NOT NULL   COMMENT 'shipment.csv → destination_location_id | FK → location.location_id',
    DEPARTING_ORIGIN_DATE       VARCHAR NOT NULL   COMMENT 'shipment.csv → departing_origin_date | Departure date (YYYY-MM-DD)',
    ARRIVING_DESTINATION_DATE   VARCHAR NOT NULL   COMMENT 'shipment.csv → arriving_destination_date | Arrival date (YYYY-MM-DD)',
    ORIGIN_LOCATION_GEOHASH     VARCHAR NOT NULL   COMMENT 'shipment.csv → origin_location_geohash | Lat/lon of origin (denorm from location)',
    DESTINATION_LOCATION_GEOHASH VARCHAR NOT NULL  COMMENT 'shipment.csv → destination_location_geohash | Lat/lon of destination (denorm from location)',
    VEHICLE_ID                  VARCHAR NOT NULL   COMMENT 'shipment.csv → vehicle_id | FK → vehicle.vehicle_id (1:1 with shipment)',
    VEHICLE_NAME                VARCHAR NOT NULL   COMMENT 'shipment.csv → vehicle_name | Human label (denorm from vehicle)',
    TOTAL_UNIT_QUANTITY         VARCHAR NOT NULL   COMMENT 'shipment.csv → total_unit_quantity | Sum of product quantities in shipment',
    STATUS                      VARCHAR NOT NULL   COMMENT 'shipment.csv → status | Shipment status (all rows: Scheduled)',

    -- audit columns (not in source CSV)
    LOAD_TIMESTAMP              TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
                                               COMMENT 'Audit: when this row was loaded into Snowflake',
    SOURCE_FILE                 VARCHAR        COMMENT 'Audit: staged file path (METADATA$FILENAME)',

    -- constraints
    CONSTRAINT PK_RAW_SHIPMENT PRIMARY KEY (SHIPMENT_ID)
)
COMMENT = 'RAW landing table for shipment.csv. All VARCHAR, no transformations.';


-- =============================================================================
-- 2. RAW_PRODUCT_SHIPMENT  (source: product_shipment.csv, 159 rows, 14 columns)
-- =============================================================================
-- One row per product-line within a shipment (bridge between shipment and product).
-- A single shipment can carry 1-3 products, each as a separate row here.
-- Column order: matches product_shipment.csv header exactly.
-- =============================================================================
CREATE OR REPLACE TABLE RAW_PRODUCT_SHIPMENT (
    -- source columns (CSV column order)
    PRODUCT_SHIPMENT_ID         VARCHAR NOT NULL   COMMENT 'product_shipment.csv → product_shipment_id | UUID-suffix, unique per product-line',
    SHIPMENT_NAME               VARCHAR NOT NULL   COMMENT 'product_shipment.csv → shipment_name | Parent shipment label (denorm)',
    SHIPMENT_ID                 VARCHAR NOT NULL   COMMENT 'product_shipment.csv → shipment_id | FK → shipment.shipment_id',
    PRODUCT_DESCRIPTION         VARCHAR NOT NULL   COMMENT 'product_shipment.csv → product_description | Product name (denorm from product)',
    QUANTITY                    VARCHAR NOT NULL   COMMENT 'product_shipment.csv → quantity | Units shipped (fact measure)',
    PRODUCT_ID                  VARCHAR NOT NULL   COMMENT 'product_shipment.csv → product_id | FK → product.product_id',
    DEPARTING_ORIGIN_DATE       VARCHAR NOT NULL   COMMENT 'product_shipment.csv → departing_origin_date | Departure date (denorm from shipment)',
    ARRIVING_DESTINATION_DATE   VARCHAR NOT NULL   COMMENT 'product_shipment.csv → arriving_destination_date | Arrival date (denorm from shipment)',
    VEHICLE_NAME                VARCHAR NOT NULL   COMMENT 'product_shipment.csv → vehicle_name | Vehicle label (denorm from shipment)',
    ORIGIN_LOCATION_NAME        VARCHAR NOT NULL   COMMENT 'product_shipment.csv → origin_location_name | Origin facility (denorm)',
    ORIGIN_LOCATION_GEOHASH     VARCHAR NOT NULL   COMMENT 'product_shipment.csv → origin_location_geohash | Origin coords (denorm)',
    DESTINATION_LOCATION_NAME   VARCHAR NOT NULL   COMMENT 'product_shipment.csv → destination_location_name | Destination facility (denorm)',
    DESTINATION_LOCATION_GEOHASH VARCHAR NOT NULL  COMMENT 'product_shipment.csv → destination_location_geohash | Destination coords (denorm)',
    PRODUCT_SHIPMENT_NAME       VARCHAR NOT NULL   COMMENT 'product_shipment.csv → product_shipment_name | Human label (Product Shipment N-S)',

    -- audit columns
    LOAD_TIMESTAMP              TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
                                               COMMENT 'Audit: when this row was loaded into Snowflake',
    SOURCE_FILE                 VARCHAR        COMMENT 'Audit: staged file path (METADATA$FILENAME)',

    -- constraints
    CONSTRAINT PK_RAW_PRODUCT_SHIPMENT PRIMARY KEY (PRODUCT_SHIPMENT_ID)
)
COMMENT = 'RAW landing table for product_shipment.csv. Bridge between shipment and product.';


-- =============================================================================
-- 3. RAW_PRODUCT  (source: product.csv, 3 rows, 2 columns)
-- =============================================================================
-- Reference/dimension table: one row per product.
-- Column order: matches product.csv header exactly.
-- =============================================================================
CREATE OR REPLACE TABLE RAW_PRODUCT (
    -- source columns (CSV column order)
    PRODUCT_ID                  VARCHAR NOT NULL   COMMENT 'product.csv → product_id | Unique product identifier (product-1, product-2, product-3)',
    PRODUCT_DESCRIPTION         VARCHAR NOT NULL   COMMENT 'product.csv → product_description | Product name (Blue Triangles / Red Squares / Yellow Circles)',

    -- audit columns
    LOAD_TIMESTAMP              TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
                                               COMMENT 'Audit: when this row was loaded into Snowflake',
    SOURCE_FILE                 VARCHAR        COMMENT 'Audit: staged file path (METADATA$FILENAME)',

    -- constraints
    CONSTRAINT PK_RAW_PRODUCT PRIMARY KEY (PRODUCT_ID)
)
COMMENT = 'RAW landing table for product.csv. Product dimension (3 products).';


-- =============================================================================
-- 4. RAW_LOCATION  (source: location.csv, 4 rows, 3 columns)
-- =============================================================================
-- Reference/dimension table: one row per facility location.
-- Column order: matches location.csv header exactly.
-- =============================================================================
CREATE OR REPLACE TABLE RAW_LOCATION (
    -- source columns (CSV column order)
    LOCATION_ID                 VARCHAR NOT NULL   COMMENT 'location.csv → location_id | Unique location identifier (location-{city})',
    NAME                        VARCHAR NOT NULL   COMMENT 'location.csv → name | Facility name (Houston / New York / Chicago / St. Louis)',
    GEOHASH                     VARCHAR NOT NULL   COMMENT 'location.csv → geohash | Lat/lon coordinates as string',

    -- audit columns
    LOAD_TIMESTAMP              TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
                                               COMMENT 'Audit: when this row was loaded into Snowflake',
    SOURCE_FILE                 VARCHAR        COMMENT 'Audit: staged file path (METADATA$FILENAME)',

    -- constraints
    CONSTRAINT PK_RAW_LOCATION PRIMARY KEY (LOCATION_ID)
)
COMMENT = 'RAW landing table for location.csv. Location dimension (4 facilities).';


-- =============================================================================
-- 5. RAW_VEHICLE  (source: vehicle.csv, 83 rows, 3 columns)
-- =============================================================================
-- Reference/dimension table: one row per vehicle.
-- Column order: matches vehicle.csv header exactly.
-- =============================================================================
CREATE OR REPLACE TABLE RAW_VEHICLE (
    -- source columns (CSV column order)
    UNIT_CAPACITY               VARCHAR NOT NULL   COMMENT 'vehicle.csv → unit_capacity | Max unit capacity (10000-50000)',
    VEHICLE_ID                  VARCHAR NOT NULL   COMMENT 'vehicle.csv → vehicle_id | Unique vehicle identifier (vehicle-001..083)',
    VEHICLE_NAME                VARCHAR NOT NULL   COMMENT 'vehicle.csv → vehicle_name | Human label (Vehicle 1..83)',

    -- audit columns
    LOAD_TIMESTAMP              TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
                                               COMMENT 'Audit: when this row was loaded into Snowflake',
    SOURCE_FILE                 VARCHAR        COMMENT 'Audit: staged file path (METADATA$FILENAME)',

    -- constraints
    CONSTRAINT PK_RAW_VEHICLE PRIMARY KEY (VEHICLE_ID)
)
COMMENT = 'RAW landing table for vehicle.csv. Vehicle dimension (83 vehicles).';
