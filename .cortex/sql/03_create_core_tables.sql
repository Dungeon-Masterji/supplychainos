-- =============================================================================
-- SupplyChainOS: CORE Layer DDL — Seven Canonical Tables
-- =============================================================================
-- 4 Dimensions:  DIM_SUPPLIER, DIM_PART, DIM_PLANT, DIM_CUSTOMER
-- 3 Facts:       FACT_ORDER, FACT_SHIPMENT, FACT_INVENTORY
--
-- Data type conventions (from PRD):
--   IDs         → VARCHAR          (e.g. 'supplier-1', 'ORD-0001')
--   Names       → VARCHAR
--   Dates       → DATE
--   Timestamps  → TIMESTAMP_NTZ
--   Quantities  → NUMBER(18,2)     (units, days, capacities)
--   Costs       → NUMBER(18,2)     (monetary amounts)
--   Rates       → NUMBER(10,6)     (reliability scores, duty rates)
--   Flags       → BOOLEAN
--   Lat/Lon     → FLOAT
--
-- Foreign keys are declared as constraints. Snowflake enforces NOT NULL but
-- does not enforce referential integrity at DML time — constraints serve as
-- documentation for BI tools and query optimizers.
--
-- Each statement is self-contained with fully-qualified table names.
-- Execution order matters: dimensions before facts (FK references).
--
-- Depends on: 01_setup_database.sql
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- DIMENSION 1: DIM_SUPPLIER
-- ─────────────────────────────────────────────────────────────────────────────
-- Source:       data/synthetic/suppliers.csv  (6 rows)
-- Natural key:  supplier_id
-- Grain:        1 row per supplier
-- Business:     External companies that manufacture and supply parts.
--               2 per product: 1 primary (Tier 1), 1 alternate (Tier 2).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER (
    -- PRIMARY KEY
    SUPPLIER_ID         VARCHAR        NOT NULL
        COMMENT 'PK | synthetic/suppliers.csv → supplier_id',

    -- Attributes
    SUPPLIER_NAME       VARCHAR        NOT NULL
        COMMENT 'Human-readable name | synthetic/suppliers.csv → supplier_name',
    REGION              VARCHAR        NOT NULL
        COMMENT 'Geographic region: AMERICAS, EMEA, or APAC | synthetic → region',
    TIER                VARCHAR        NOT NULL
        COMMENT 'Tier 1 (primary) or Tier 2 (alternate) | synthetic → tier',
    RELIABILITY_SCORE   NUMBER(10,6)   NOT NULL
        COMMENT 'On-time delivery rate 0.000000–1.000000 | synthetic → reliability_score',
    LEAD_TIME_DAYS      NUMBER(18,2)   NOT NULL
        COMMENT 'Avg lead time in calendar days | synthetic → lead_time_days',

    -- Audit
    CREATED_AT          TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()
        COMMENT 'Row creation timestamp',

    CONSTRAINT PK_DIM_SUPPLIER PRIMARY KEY (SUPPLIER_ID)
)
COMMENT = 'Dimension: external suppliers of parts. Grain: 1 row per supplier (6 rows). Each part has 1 primary + 1 alternate supplier.';


-- ─────────────────────────────────────────────────────────────────────────────
-- DIMENSION 2: DIM_PART
-- ─────────────────────────────────────────────────────────────────────────────
-- Source:       data/source/product.csv (3 rows) + synthetic cost constants
-- Natural key:  part_id  (= product_id in source, renamed for domain clarity)
-- Grain:        1 row per part
-- Business:     Distinct goods shipped across the network. Category inferred
--               from part_name (shape-based naming convention).
-- FK:           supplier_id → DIM_SUPPLIER (primary supplier for this part)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE SUPPLYCHAIN_DB.CORE.DIM_PART (
    -- PRIMARY KEY
    PART_ID             VARCHAR        NOT NULL
        COMMENT 'PK | source/product.csv → product_id (renamed to part_id)',

    -- Attributes
    PART_NAME           VARCHAR        NOT NULL
        COMMENT 'Descriptive name (Blue Triangles) | source → product_description',
    CATEGORY            VARCHAR        NOT NULL
        COMMENT 'Inferred from part_name: Triangles / Squares / Circles | DERIVED',
    UNIT_COST           NUMBER(18,2)   NOT NULL
        COMMENT 'Standard cost per unit ($12.50/$8.75/$15.00) | SYNTHETIC constant',

    -- Foreign keys
    SUPPLIER_ID         VARCHAR        NOT NULL
        COMMENT 'FK → DIM_SUPPLIER.SUPPLIER_ID | primary supplier (positional map)',

    -- Audit
    CREATED_AT          TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()
        COMMENT 'Row creation timestamp',

    CONSTRAINT PK_DIM_PART PRIMARY KEY (PART_ID),
    CONSTRAINT FK_PART_SUPPLIER FOREIGN KEY (SUPPLIER_ID)
        REFERENCES SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER(SUPPLIER_ID)
)
COMMENT = 'Dimension: parts (products) shipped in the supply chain. Grain: 1 row per part (3 rows). FK to primary supplier.';


-- ─────────────────────────────────────────────────────────────────────────────
-- DIMENSION 3: DIM_PLANT
-- ─────────────────────────────────────────────────────────────────────────────
-- Source:       data/source/location.csv  (4 rows)
-- Natural key:  plant_id  (= location_id in source, renamed for domain clarity)
-- Grain:        1 row per plant/facility
-- Business:     Physical facilities that originate/receive shipments and hold
--               inventory. All four are US-based (AMERICAS).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE SUPPLYCHAIN_DB.CORE.DIM_PLANT (
    -- PRIMARY KEY
    PLANT_ID            VARCHAR        NOT NULL
        COMMENT 'PK | source/location.csv → location_id (renamed to plant_id)',

    -- Attributes
    PLANT_NAME          VARCHAR        NOT NULL
        COMMENT 'Facility name (Houston Facility) | source → location.name',
    REGION              VARCHAR        NOT NULL
        COMMENT 'Geographic region (all AMERICAS) | DERIVED from US locations',
    LATITUDE            FLOAT          NOT NULL
        COMMENT 'Latitude | DERIVED: parsed from source → location.geohash',
    LONGITUDE           FLOAT          NOT NULL
        COMMENT 'Longitude | DERIVED: parsed from source → location.geohash',

    -- Audit
    CREATED_AT          TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()
        COMMENT 'Row creation timestamp',

    CONSTRAINT PK_DIM_PLANT PRIMARY KEY (PLANT_ID)
)
COMMENT = 'Dimension: physical facilities (plants). Grain: 1 row per plant (4 rows). Origin/destination for shipments; holds inventory.';


-- ─────────────────────────────────────────────────────────────────────────────
-- DIMENSION 4: DIM_CUSTOMER
-- ─────────────────────────────────────────────────────────────────────────────
-- Source:       data/synthetic/customers.csv  (8 rows)
-- Natural key:  customer_id
-- Grain:        1 row per customer
-- Business:     Companies that place orders. 2 per destination plant, segmented
--               by inbound shipment volume (Strategic > Premium > Standard).
-- FK:           plant_id → DIM_PLANT (the plant this customer is assigned to)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE SUPPLYCHAIN_DB.CORE.DIM_CUSTOMER (
    -- PRIMARY KEY
    CUSTOMER_ID         VARCHAR        NOT NULL
        COMMENT 'PK | synthetic/customers.csv → customer_id',

    -- Attributes
    CUSTOMER_NAME       VARCHAR        NOT NULL
        COMMENT 'Company name (Empire Manufacturing) | synthetic → customer_name',
    REGION              VARCHAR        NOT NULL
        COMMENT 'Geographic region (all AMERICAS) | DERIVED from plant location',
    SEGMENT             VARCHAR        NOT NULL
        COMMENT 'Strategic / Premium / Standard | SYNTHETIC (volume-ranked)',

    -- Foreign keys
    PLANT_ID            VARCHAR        NOT NULL
        COMMENT 'FK → DIM_PLANT.PLANT_ID | assigned destination plant',

    -- Audit
    CREATED_AT          TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()
        COMMENT 'Row creation timestamp',

    CONSTRAINT PK_DIM_CUSTOMER PRIMARY KEY (CUSTOMER_ID),
    CONSTRAINT FK_CUSTOMER_PLANT FOREIGN KEY (PLANT_ID)
        REFERENCES SUPPLYCHAIN_DB.CORE.DIM_PLANT(PLANT_ID)
)
COMMENT = 'Dimension: customers who place orders. Grain: 1 row per customer (8 rows). 2 per destination plant, volume-ranked segments.';


-- ─────────────────────────────────────────────────────────────────────────────
-- FACT 1: FACT_ORDER
-- ─────────────────────────────────────────────────────────────────────────────
-- Source:       data/synthetic/orders.csv  (83 rows)
-- Natural key:  order_id
-- Grain:        1 row per customer order
-- Business:     Demand signal — may be fulfilled by one or more shipments.
--               Placed before departure; has a requested delivery date that
--               may differ from actual arrival (creates on-time/late mix).
-- FKs:          customer_id → DIM_CUSTOMER
--               plant_id    → DIM_PLANT   (fulfilling/destination plant)
--               part_id     → DIM_PART    (primary part ordered)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE SUPPLYCHAIN_DB.CORE.FACT_ORDER (
    -- PRIMARY KEY
    ORDER_ID                 VARCHAR       NOT NULL
        COMMENT 'PK | synthetic/orders.csv → order_id (ORD-NNNN)',

    -- Foreign keys
    CUSTOMER_ID              VARCHAR       NOT NULL
        COMMENT 'FK → DIM_CUSTOMER.CUSTOMER_ID | who placed the order',
    PLANT_ID                 VARCHAR       NOT NULL
        COMMENT 'FK → DIM_PLANT.PLANT_ID | fulfilling/destination plant',
    PART_ID                  VARCHAR       NOT NULL
        COMMENT 'FK → DIM_PART.PART_ID | primary part ordered',

    -- Dates
    ORDER_DATE               DATE          NOT NULL
        COMMENT 'Date order placed (1–5d before departure) | DERIVED from shipment',
    REQUESTED_DELIVERY_DATE  DATE          NOT NULL
        COMMENT 'Customer-requested date (actual ± -5..+10d) | DERIVED with RNG offset',

    -- Measures
    ORDERED_QUANTITY         NUMBER(18,2)  NOT NULL
        COMMENT 'Quantity ordered (≥ shipped_quantity) | DERIVED: shipped + surplus',
    PRIORITY                 VARCHAR       NOT NULL
        COMMENT 'High / Medium / Low | DERIVED from quantity terciles',
    STATUS                   VARCHAR       NOT NULL
        COMMENT 'Order status (all Completed) | SYNTHETIC',

    -- Audit
    CREATED_AT               TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
        COMMENT 'Row creation timestamp',

    CONSTRAINT PK_FACT_ORDER PRIMARY KEY (ORDER_ID),
    CONSTRAINT FK_ORDER_CUSTOMER FOREIGN KEY (CUSTOMER_ID)
        REFERENCES SUPPLYCHAIN_DB.CORE.DIM_CUSTOMER(CUSTOMER_ID),
    CONSTRAINT FK_ORDER_PLANT FOREIGN KEY (PLANT_ID)
        REFERENCES SUPPLYCHAIN_DB.CORE.DIM_PLANT(PLANT_ID),
    CONSTRAINT FK_ORDER_PART FOREIGN KEY (PART_ID)
        REFERENCES SUPPLYCHAIN_DB.CORE.DIM_PART(PART_ID)
)
COMMENT = 'Fact: demand signal. Grain: 1 row per customer order (83 rows). May be fulfilled by one or more shipments.';


-- ─────────────────────────────────────────────────────────────────────────────
-- FACT 2: FACT_SHIPMENT
-- ─────────────────────────────────────────────────────────────────────────────
-- Source:       source/product_shipment.csv (159 rows)
--               + source/shipment.csv       (route, vehicle, dates)
--               + synthetic/synthetic_costs.csv (cost measures)
--               + synthetic/orders.csv      (order linkage, requested date)
-- Natural key:  shipment_line_id (= product_shipment_id in source)
-- Grain:        1 row per shipment × part
--               (a truck carrying 3 products = 3 rows with same shipment_id)
-- Business:     Physical movement of goods between plants — may fulfill part
--               of an order. Carries cost breakdown and the PySpark-derived
--               risk classification (delivery_days vs route avg).
--
-- COMPUTED COLUMNS (ported from src/transformation.py):
--   delivery_days           = DATEDIFF('day', departure_date, arrival_date)
--   is_valid_shipment       = delivery_days >= 0
--   avg_route_delivery_days = AVG(delivery_days) OVER (PARTITION BY route)
--   risk_flag               = High if > avg+3, Medium if > avg, else Low
--   decision                = Investigate / Monitor / Normal
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT (
    -- PRIMARY KEY
    SHIPMENT_LINE_ID         VARCHAR       NOT NULL
        COMMENT 'PK | source/product_shipment.csv → product_shipment_id',

    -- Grouping key
    SHIPMENT_ID              VARCHAR       NOT NULL
        COMMENT 'Parent shipment UUID — groups all parts on one truck | SOURCE',

    -- Foreign keys
    ORDER_ID                 VARCHAR       NOT NULL
        COMMENT 'FK → FACT_ORDER.ORDER_ID | the order this line fulfills',
    PART_ID                  VARCHAR       NOT NULL
        COMMENT 'FK → DIM_PART.PART_ID | which part is being shipped',
    ORIGIN_PLANT_ID          VARCHAR       NOT NULL
        COMMENT 'FK → DIM_PLANT.PLANT_ID | departure facility',
    DESTINATION_PLANT_ID     VARCHAR       NOT NULL
        COMMENT 'FK → DIM_PLANT.PLANT_ID | arrival facility',
    VEHICLE_ID               VARCHAR       NOT NULL
        COMMENT 'Vehicle ref | source/vehicle.csv → vehicle_id',

    -- Dates
    DEPARTURE_DATE           DATE          NOT NULL
        COMMENT 'Shipment departs origin | SOURCE: departing_origin_date',
    ARRIVAL_DATE             DATE          NOT NULL
        COMMENT 'Shipment arrives at dest | SOURCE: arriving_destination_date',
    REQUESTED_DELIVERY_DATE  DATE          NOT NULL
        COMMENT 'Customer-requested date | DERIVED: from linked FACT_ORDER',

    -- Quantity measures
    SHIPPED_QUANTITY         NUMBER(18,2)  NOT NULL
        COMMENT 'Units of this part on this shipment | SOURCE: quantity',
    VEHICLE_CAPACITY         NUMBER(18,2)  NOT NULL
        COMMENT 'Max unit capacity of assigned vehicle | SOURCE: vehicle_unit_capacity',

    -- Cost measures (from synthetic_costs.csv)
    UNIT_COST                NUMBER(18,2)  NOT NULL
        COMMENT 'Cost per unit for this part | SYNTHETIC: $12.50/$8.75/$15.00',
    MATERIAL_COST            NUMBER(18,2)  NOT NULL
        COMMENT 'unit_cost × shipped_quantity | DERIVED',
    FREIGHT_COST             NUMBER(18,2)  NOT NULL
        COMMENT 'haversine_km × $0.012 + (qty/1000) × $2.50 | DERIVED',
    DUTY_COST                NUMBER(18,2)  NOT NULL
        COMMENT 'quantity × duty_rate (3%/5%/4% by product) | DERIVED',
    HANDLING_COST            NUMBER(18,2)  NOT NULL
        COMMENT '$150 base + $0.02 per unit | DERIVED',
    LANDED_COST              NUMBER(18,2)  NOT NULL
        COMMENT 'material + freight + duty + handling | DERIVED',
    DISTANCE_KM              NUMBER(18,2)  NOT NULL
        COMMENT 'Great-circle distance origin→dest (km) | DERIVED: haversine',

    -- Computed: PySpark transformation logic (src/transformation.py)
    DELIVERY_DAYS            NUMBER(18,2)  NOT NULL
        COMMENT 'DATEDIFF(day, departure_date, arrival_date) | DERIVED: transit time',
    IS_VALID_SHIPMENT        BOOLEAN       NOT NULL
        COMMENT 'delivery_days >= 0 | DERIVED: data quality gate',
    AVG_ROUTE_DELIVERY_DAYS  NUMBER(18,2)  NOT NULL
        COMMENT 'AVG(delivery_days) OVER (PARTITION BY origin, destination) | DERIVED',
    RISK_FLAG                VARCHAR       NOT NULL
        COMMENT 'High (>avg+3) / Medium (>avg) / Low (≤avg) | DERIVED: PySpark logic',
    DECISION                 VARCHAR       NOT NULL
        COMMENT 'Investigate (High) / Monitor (Medium) / Normal (Low) | DERIVED',

    -- Audit
    CREATED_AT               TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
        COMMENT 'Row creation timestamp',

    CONSTRAINT PK_FACT_SHIPMENT PRIMARY KEY (SHIPMENT_LINE_ID),
    CONSTRAINT FK_SHIPMENT_ORDER FOREIGN KEY (ORDER_ID)
        REFERENCES SUPPLYCHAIN_DB.CORE.FACT_ORDER(ORDER_ID),
    CONSTRAINT FK_SHIPMENT_PART FOREIGN KEY (PART_ID)
        REFERENCES SUPPLYCHAIN_DB.CORE.DIM_PART(PART_ID),
    CONSTRAINT FK_SHIPMENT_ORIGIN FOREIGN KEY (ORIGIN_PLANT_ID)
        REFERENCES SUPPLYCHAIN_DB.CORE.DIM_PLANT(PLANT_ID),
    CONSTRAINT FK_SHIPMENT_DEST FOREIGN KEY (DESTINATION_PLANT_ID)
        REFERENCES SUPPLYCHAIN_DB.CORE.DIM_PLANT(PLANT_ID)
)
COMMENT = 'Fact: physical movement of goods. Grain: 1 row per shipment × part (159 rows). Includes costs and PySpark-derived risk classification (delivery_days vs route average).';


-- ─────────────────────────────────────────────────────────────────────────────
-- FACT 3: FACT_INVENTORY
-- ─────────────────────────────────────────────────────────────────────────────
-- Source:       data/synthetic/inventory.csv  (360 rows)
-- Natural key:  (plant_id, part_id, snapshot_date) — composite PK
-- Grain:        1 row per plant × part × day
-- Business:     Daily inventory snapshot. Supports Days of Inventory (DOI)
--               calculation: inventory_quantity / daily_demand.
--               Tracks stockouts (qty = 0) and inbound replenishment from
--               shipment arrivals.
-- FKs:          plant_id → DIM_PLANT
--               part_id  → DIM_PART
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE SUPPLYCHAIN_DB.CORE.FACT_INVENTORY (
    -- Composite PRIMARY KEY
    PLANT_ID                 VARCHAR       NOT NULL
        COMMENT 'PK (1/3) + FK → DIM_PLANT.PLANT_ID | which facility',
    PART_ID                  VARCHAR       NOT NULL
        COMMENT 'PK (2/3) + FK → DIM_PART.PART_ID | which part',
    SNAPSHOT_DATE            DATE          NOT NULL
        COMMENT 'PK (3/3) | calendar date (2024-03-12 to 2024-04-10)',

    -- Measures
    INVENTORY_QUANTITY       NUMBER(18,2)  NOT NULL
        COMMENT 'Units on hand at end of day (≥ 0, floored) | DERIVED: formula',
    DAILY_DEMAND             NUMBER(18,2)  NOT NULL
        COMMENT 'Constant daily consumption rate (200–800) | SYNTHETIC: seeded',
    INBOUND_QUANTITY         NUMBER(18,2)  NOT NULL DEFAULT 0
        COMMENT 'Units arriving from shipments on this date | DERIVED: from arrivals',

    -- Audit
    CREATED_AT               TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
        COMMENT 'Row creation timestamp',

    CONSTRAINT PK_FACT_INVENTORY PRIMARY KEY (PLANT_ID, PART_ID, SNAPSHOT_DATE),
    CONSTRAINT FK_INVENTORY_PLANT FOREIGN KEY (PLANT_ID)
        REFERENCES SUPPLYCHAIN_DB.CORE.DIM_PLANT(PLANT_ID),
    CONSTRAINT FK_INVENTORY_PART FOREIGN KEY (PART_ID)
        REFERENCES SUPPLYCHAIN_DB.CORE.DIM_PART(PART_ID)
)
COMMENT = 'Fact: daily inventory snapshot. Grain: 1 row per plant × part × day (360 rows). DOI = inventory_quantity / daily_demand.';
