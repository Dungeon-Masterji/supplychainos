-- =============================================================================
-- SupplyChainOS: Semantic View DDL  (v2 — with VQRs and fill-rate fix)
-- =============================================================================
-- Creates SUPPLY_CHAIN_SV — the governed semantic layer for SupplyChainOS.
--
-- 8 logical tables:  4 dimensions + 3 facts + 1 pre-aggregated fulfillment view
-- 15 relationships:  all FK paths for bidirectional navigation
-- 16 facts:          raw numeric measures
-- 29 dimensions:     attributes for slicing and filtering
-- 4 metrics:         OTD, Fill Rate, Days of Inventory, Landed Cost
-- 16 verified queries (VQRs)
-- Strengthened AI_SQL_GENERATION rules
--
-- Depends on: SUPPLYCHAIN_DB.CORE.* (all 7 tables + V_ORDER_FULFILLMENT view)
-- =============================================================================

CREATE OR REPLACE SEMANTIC VIEW SUPPLYCHAIN_DB.SEMANTIC.SUPPLY_CHAIN_SV

-- =========================================================================
-- TABLES: 4 dimensions + 4 fact sources
-- =========================================================================
TABLES (
    suppliers AS SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER
        PRIMARY KEY (SUPPLIER_ID)
        WITH SYNONYMS = ('vendor', 'manufacturer')
        COMMENT = 'Dimension: external suppliers of parts. 2 per product (Tier 1 primary + Tier 2 alternate). 6 rows total but only 3 Tier-1 suppliers have shipment/order activity.',

    parts AS SUPPLYCHAIN_DB.CORE.DIM_PART
        PRIMARY KEY (PART_ID)
        WITH SYNONYMS = ('product', 'item', 'component', 'SKU')
        COMMENT = 'Dimension: distinct goods shipped across the supply chain. 3 parts: Blue Triangles, Red Squares, Yellow Circles.',

    plants AS SUPPLYCHAIN_DB.CORE.DIM_PLANT
        PRIMARY KEY (PLANT_ID)
        WITH SYNONYMS = ('facility', 'site', 'warehouse', 'location')
        COMMENT = 'Dimension: physical facilities that originate/receive shipments and hold inventory. 4 US plants.',

    customers AS SUPPLYCHAIN_DB.CORE.DIM_CUSTOMER
        PRIMARY KEY (CUSTOMER_ID)
        WITH SYNONYMS = ('account', 'client', 'buyer')
        COMMENT = 'Dimension: companies that place orders. 2 per destination plant, segmented Strategic/Premium/Standard. 8 rows.',

    orders AS SUPPLYCHAIN_DB.CORE.FACT_ORDER
        PRIMARY KEY (ORDER_ID)
        WITH SYNONYMS = ('purchase order', 'PO', 'demand')
        COMMENT = 'Fact: demand signal. 1 row per customer order. May be fulfilled by 1+ shipment lines. 83 rows.',

    shipments AS SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT
        PRIMARY KEY (SHIPMENT_LINE_ID)
        WITH SYNONYMS = ('delivery', 'transport', 'movement')
        COMMENT = 'Fact: physical movement of goods. 1 row per shipment x part (159 rows). Includes costs and risk classification.',

    -- Pre-aggregated fulfillment view: 1 row per order (83 rows).
    -- shipped_quantity is already summed to the order level, preventing fan-out.
    order_fulfillment AS SUPPLYCHAIN_DB.CORE.V_ORDER_FULFILLMENT
        PRIMARY KEY (ORDER_ID)
        WITH SYNONYMS = ('fulfillment', 'order fulfillment')
        COMMENT = 'Pre-aggregated order fulfillment: 1 row per order with ordered_quantity and shipped_quantity at order grain (83 rows). Use ONLY this table for fill rate calculations.',

    inventory AS SUPPLYCHAIN_DB.CORE.FACT_INVENTORY
        PRIMARY KEY (PLANT_ID, PART_ID, SNAPSHOT_DATE)
        WITH SYNONYMS = ('stock', 'on-hand', 'stock level')
        COMMENT = 'Fact: daily inventory snapshot per plant and part. 360 rows (30 days x 4 plants x 3 parts).'
)

-- =========================================================================
-- RELATIONSHIPS: 15 foreign key paths
-- =========================================================================
RELATIONSHIPS (
    -- Dimension-to-dimension
    parts_to_suppliers    AS parts     (SUPPLIER_ID)         REFERENCES suppliers,
    customers_to_plants   AS customers (PLANT_ID)            REFERENCES plants,

    -- Order FKs
    orders_to_customers   AS orders    (CUSTOMER_ID)         REFERENCES customers,
    orders_to_plants      AS orders    (PLANT_ID)            REFERENCES plants,
    orders_to_parts       AS orders    (PART_ID)             REFERENCES parts,

    -- Shipment FKs (note: two paths to plants — origin and destination)
    shipments_to_orders      AS shipments (ORDER_ID)         REFERENCES orders,
    shipments_to_parts       AS shipments (PART_ID)          REFERENCES parts,
    shipments_to_origin      AS shipments (ORIGIN_PLANT_ID)  REFERENCES plants,
    shipments_to_destination AS shipments (DESTINATION_PLANT_ID) REFERENCES plants,

    -- Order fulfillment FKs (for fill rate dimensional breakdowns)
    fulfillment_to_parts      AS order_fulfillment (PART_ID)      REFERENCES parts,
    fulfillment_to_plants     AS order_fulfillment (PLANT_ID)     REFERENCES plants,
    fulfillment_to_customers  AS order_fulfillment (CUSTOMER_ID)  REFERENCES customers,

    -- Inventory FKs
    inventory_to_plants   AS inventory  (PLANT_ID)           REFERENCES plants,
    inventory_to_parts    AS inventory  (PART_ID)            REFERENCES parts
)

-- =========================================================================
-- FACTS: 16 raw numeric measures
-- =========================================================================
FACTS (
    -- Shipment measures
    shipments.shipped_quantity       AS shipments.SHIPPED_QUANTITY
        COMMENT = 'Units of this part on this shipment line.',
    shipments.vehicle_capacity       AS shipments.VEHICLE_CAPACITY
        COMMENT = 'Max unit capacity of the assigned vehicle.',
    shipments.material_cost          AS shipments.MATERIAL_COST
        COMMENT = 'Product cost: unit_cost x shipped_quantity.',
    shipments.freight_cost           AS shipments.FREIGHT_COST
        COMMENT = 'Distance-based freight cost.',
    shipments.duty_cost              AS shipments.DUTY_COST
        COMMENT = 'Import duty: quantity x duty_rate.',
    shipments.handling_cost          AS shipments.HANDLING_COST
        COMMENT = 'Handling: $150 base + $0.02 per unit.',
    shipments.landed_cost_amount     AS shipments.LANDED_COST
        COMMENT = 'Total landed cost: material + freight + duty + handling.',
    shipments.delivery_days_value    AS shipments.DELIVERY_DAYS
        COMMENT = 'Transit time in days: DATEDIFF(day, departure, arrival).',
    shipments.avg_route_days         AS shipments.AVG_ROUTE_DELIVERY_DAYS
        COMMENT = 'Route-level average delivery days.',
    shipments.distance_km_value      AS shipments.DISTANCE_KM
        COMMENT = 'Great-circle distance origin to destination in km.',

    -- Order measures (raw orders table — do NOT use for fill rate)
    orders.ordered_quantity          AS orders.ORDERED_QUANTITY
        COMMENT = 'Quantity ordered by the customer. WARNING: do not join directly to shipments for fill rate (fan-out).',

    -- Order fulfillment measures (pre-aggregated — USE for fill rate)
    order_fulfillment.fulfillment_ordered  AS order_fulfillment.ORDERED_QUANTITY
        COMMENT = 'Ordered quantity at order grain. Use for fill rate calculations.',
    order_fulfillment.fulfillment_shipped  AS order_fulfillment.SHIPPED_QUANTITY
        COMMENT = 'Total shipped quantity pre-aggregated to order grain. Use for fill rate calculations.',

    -- Inventory measures
    inventory.inventory_quantity     AS inventory.INVENTORY_QUANTITY
        COMMENT = 'Units on hand at end of day (floored at 0).',
    inventory.daily_demand           AS inventory.DAILY_DEMAND
        COMMENT = 'Constant daily consumption rate (200-800 units).',
    inventory.inbound_quantity       AS inventory.INBOUND_QUANTITY
        COMMENT = 'Units arriving from shipment deliveries on this date.'
)

-- =========================================================================
-- DIMENSIONS: 29 attributes for slicing and filtering
-- =========================================================================
DIMENSIONS (
    -- Supplier
    suppliers.supplier_name    AS suppliers.SUPPLIER_NAME
        WITH SYNONYMS = ('supplier', 'vendor', 'vendor name')
        SAMPLE_VALUES ('Apex Components', 'Pacific Materials', 'Midwest Supply Inc', 'Delta Parts Co', 'Rhine Industries', 'Eastern Logistics')
        IS_ENUM
        COMMENT = 'Supplier company name.',
    suppliers.supplier_region  AS suppliers.REGION
        WITH SYNONYMS = ('supplier geography')
        SAMPLE_VALUES ('AMERICAS', 'EMEA', 'APAC') IS_ENUM
        COMMENT = 'Supplier region: AMERICAS, EMEA, or APAC.',
    suppliers.tier             AS suppliers.TIER
        WITH SYNONYMS = ('supplier tier', 'supplier level')
        SAMPLE_VALUES ('Tier 1', 'Tier 2') IS_ENUM
        COMMENT = 'Tier 1 (primary) or Tier 2 (alternate). Only Tier 1 suppliers have shipment/order activity.',
    suppliers.reliability      AS suppliers.RELIABILITY_SCORE
        WITH SYNONYMS = ('reliability score', 'supplier reliability')
        COMMENT = 'Historical on-time rate (0.0-1.0).',
    suppliers.lead_time        AS suppliers.LEAD_TIME_DAYS
        WITH SYNONYMS = ('lead time', 'supplier lead time')
        COMMENT = 'Average lead time in calendar days.',

    -- Part
    parts.part_name            AS parts.PART_NAME
        WITH SYNONYMS = ('product', 'product name', 'item', 'item name')
        SAMPLE_VALUES ('Blue Triangles', 'Red Squares', 'Yellow Circles') IS_ENUM
        COMMENT = 'Product name: Blue Triangles, Red Squares, or Yellow Circles.',
    parts.part_category        AS parts.CATEGORY
        WITH SYNONYMS = ('product category', 'category')
        SAMPLE_VALUES ('Triangles', 'Squares', 'Circles') IS_ENUM
        COMMENT = 'Category: Triangles, Squares, or Circles.',
    parts.unit_cost            AS parts.UNIT_COST
        WITH SYNONYMS = ('standard cost', 'cost per unit')
        COMMENT = 'Standard cost per unit.',

    -- Plant
    plants.plant_name          AS plants.PLANT_NAME
        WITH SYNONYMS = ('facility', 'facility name', 'site', 'site name')
        SAMPLE_VALUES ('Houston Facility', 'New York Facility', 'Chicago Facility', 'St. Louis Facility') IS_ENUM
        COMMENT = 'Facility name: Houston, New York, Chicago, or St. Louis.',
    plants.plant_region        AS plants.REGION
        WITH SYNONYMS = ('plant geography', 'plant region')
        COMMENT = 'Plant region (all AMERICAS).',

    -- Customer
    customers.customer_name    AS customers.CUSTOMER_NAME
        WITH SYNONYMS = ('account', 'account name', 'client', 'client name')
        COMMENT = 'Customer company name.',
    customers.customer_segment AS customers.SEGMENT
        WITH SYNONYMS = ('segment', 'customer tier', 'account tier')
        SAMPLE_VALUES ('Strategic', 'Premium', 'Standard') IS_ENUM
        COMMENT = 'Strategic, Premium, or Standard.',
    customers.customer_region  AS customers.REGION
        WITH SYNONYMS = ('customer geography')
        COMMENT = 'Customer region (all AMERICAS).',

    -- Order
    orders.order_date          AS orders.ORDER_DATE
        WITH SYNONYMS = ('date ordered', 'purchase date')
        COMMENT = 'Date the order was placed.',
    orders.requested_delivery  AS orders.REQUESTED_DELIVERY_DATE
        WITH SYNONYMS = ('requested date', 'due date', 'expected delivery')
        COMMENT = 'Customer-requested delivery date.',
    orders.order_priority      AS orders.PRIORITY
        WITH SYNONYMS = ('priority', 'urgency')
        SAMPLE_VALUES ('High', 'Medium', 'Low') IS_ENUM
        COMMENT = 'High, Medium, or Low.',
    orders.order_status        AS orders.STATUS
        WITH SYNONYMS = ('status')
        COMMENT = 'Order status (all Completed).',

    -- Order fulfillment
    order_fulfillment.fulfillment_order_date AS order_fulfillment.ORDER_DATE
        WITH SYNONYMS = ('fulfillment date')
        COMMENT = 'Order date on the fulfillment record.',

    -- Shipment
    shipments.shipment_departure_date   AS shipments.DEPARTURE_DATE
        WITH SYNONYMS = ('ship date', 'departure date')
        COMMENT = 'Date shipment departs origin plant.',
    shipments.shipment_arrival_date     AS shipments.ARRIVAL_DATE
        WITH SYNONYMS = ('delivery date', 'arrival date', 'date delivered')
        COMMENT = 'Date shipment arrives at destination.',
    shipments.shipment_requested_date   AS shipments.REQUESTED_DELIVERY_DATE
        WITH SYNONYMS = ('shipment due date')
        COMMENT = 'Customer-requested date from linked order.',
    shipments.risk_flag                 AS shipments.RISK_FLAG
        WITH SYNONYMS = ('risk level', 'risk category', 'delivery risk')
        SAMPLE_VALUES ('High', 'Medium', 'Low') IS_ENUM
        COMMENT = 'Risk: High (>avg+3), Medium (>avg), Low (<=avg).',
    shipments.decision                  AS shipments.DECISION
        WITH SYNONYMS = ('action', 'recommended action')
        SAMPLE_VALUES ('Investigate', 'Monitor', 'Normal') IS_ENUM
        COMMENT = 'Action: Investigate, Monitor, or Normal.',
    shipments.is_valid_shipment LABELS = (FILTER) AS shipments.IS_VALID_SHIPMENT
        COMMENT = 'TRUE if arrival >= departure.',
    shipments.origin_plant_id           AS shipments.ORIGIN_PLANT_ID
        COMMENT = 'FK to origin plant.',
    shipments.destination_plant_id      AS shipments.DESTINATION_PLANT_ID
        COMMENT = 'FK to destination plant.',

    -- Inventory
    inventory.inventory_snapshot_date   AS inventory.SNAPSHOT_DATE
        WITH SYNONYMS = ('snapshot date', 'inventory date', 'stock date')
        COMMENT = 'Date of inventory snapshot (2024-03-12 to 2024-04-10).'
)

-- =========================================================================
-- METRICS: the four canonical KPIs
-- =========================================================================
METRICS (
    -- 1. ON-TIME DELIVERY (OTD)
    shipments.on_time_delivery AS
        COUNT_IF(shipments.ARRIVAL_DATE <= shipments.REQUESTED_DELIVERY_DATE)
        / NULLIF(COUNT(shipments.SHIPMENT_LINE_ID), 0)
        WITH SYNONYMS = ('OTD', 'delivery performance', 'on-time performance', 'delivery reliability', 'on-time rate', 'percentage of shipments arriving on time')
        COMMENT = 'On-Time Delivery: pct of eligible shipments delivered on or before requested date. Filter: is_valid_shipment=TRUE AND requested_delivery_date IS NOT NULL. Range 0.0-1.0.',

    -- 2. FILL RATE (uses order_fulfillment — fan-out-safe)
    order_fulfillment.fill_rate AS
        SUM(order_fulfillment.SHIPPED_QUANTITY) / NULLIF(SUM(order_fulfillment.ORDERED_QUANTITY), 0)
        WITH SYNONYMS = ('fulfillment rate', 'order fill', 'quantity fill', 'order fulfillment rate')
        COMMENT = 'Fill Rate: SUM(shipped) / SUM(ordered) from the pre-aggregated order_fulfillment table. NEVER compute from shipments table directly. Range 0.0-1.0+.',

    -- 3. DAYS OF INVENTORY (DOI)
    inventory.days_of_inventory AS
        SUM(inventory.INVENTORY_QUANTITY) / NULLIF(SUM(inventory.DAILY_DEMAND), 0)
        WITH SYNONYMS = ('DOI', 'inventory coverage', 'days cover', 'days of supply', 'days on hand')
        COMMENT = 'Days of Inventory: inventory / demand. Filter to latest snapshot_date. NULL when demand=0. Range 0-100+ days.',

    -- 4. LANDED COST
    shipments.total_landed_cost AS
        SUM(shipments.MATERIAL_COST) + SUM(shipments.FREIGHT_COST)
        + SUM(shipments.DUTY_COST) + SUM(shipments.HANDLING_COST)
        WITH SYNONYMS = ('landed cost', 'fully loaded cost', 'total cost', 'delivered cost', 'acquisition cost')
        COMMENT = 'Landed Cost: material + freight + duty + handling. Currency USD.'
)

COMMENT = 'Governed supply-chain semantic layer for SupplyChainOS. 4 dims + 4 fact sources + 4 canonical metrics (OTD, fill rate, DOI, landed cost). Use order_fulfillment table for fill rate. Use shipments table for OTD and landed cost. Use inventory table for DOI.'

AI_SQL_GENERATION
'CRITICAL RULES — follow exactly:

1. FILL RATE: ALWAYS use the order_fulfillment table. NEVER compute fill rate from the shipments table or by joining shipments to orders. The order_fulfillment table has shipped_quantity pre-aggregated to order grain, preventing the 1-order-to-many-shipment-lines fan-out. Formula: SUM(order_fulfillment.shipped_quantity) / NULLIF(SUM(order_fulfillment.ordered_quantity), 0).

2. ON-TIME DELIVERY: Use the shipments table. Only count rows where is_valid_shipment=TRUE and requested_delivery_date IS NOT NULL. On-time means arrival_date <= requested_delivery_date (inclusive).

3. DAYS OF INVENTORY: Use the inventory table. Always filter to a specific snapshot_date (usually MAX(snapshot_date)) BEFORE aggregating. Return NULL when daily_demand=0.

4. LANDED COST: Use the shipments table. Sum four cost components: material_cost + freight_cost + duty_cost + handling_cost. For per-unit cost, divide SUM(landed_cost) by SUM(shipped_quantity) AFTER aggregation, not before.

5. SUPPLIER DIMENSION: Suppliers connect to shipments/orders through parts (parts_to_suppliers). There are 6 suppliers but only 3 Tier-1 suppliers have shipment/order activity. When a question asks about supplier performance (OTD, fill rate, landed cost), only include suppliers that have associated data — do NOT LEFT JOIN all 6 suppliers and return NULL rows. Use INNER JOIN to parts.

6. FILTERING AND THRESHOLDS: When a question asks "which X have metric below/above N%", calculate the metric per group first, then filter with HAVING. Return ONLY the matching rows, not all rows. When a question says "poor OTD" without a specific number, use OTD < 0.70 as the threshold. When a question says "high landed cost" without a specific number, compare against the MEDIAN of landed costs across the dimension.

7. RANKING: When a question asks "top N" or "highest/lowest", use ORDER BY metric DESC/ASC LIMIT N. When it asks "rank" or "which has the most/least", ORDER BY appropriately.

8. ROUTES: Defined by origin_plant_id + destination_plant_id on the shipments table. Join to plants via shipments_to_origin and shipments_to_destination. When asked about late shipments on high-risk routes, GROUP BY origin and destination plant to get counts per route, not individual shipment rows.

9. RISK: risk_flag column on shipments: High means delivery_days > avg_route_delivery_days + 3, Medium means > avg, Low means <= avg. The decision column maps: High→Investigate, Medium→Monitor, Low→Normal. When asked about high-risk routes, filter WHERE risk_flag = ''High'' and aggregate by route.

10. TEMPORAL DATE COLUMNS: Each metric has a specific date column for temporal aggregation:
  - OTD: Use shipments.DEPARTURE_DATE for monthly/weekly grouping (GROUP BY DATE_TRUNC(''month'', DEPARTURE_DATE) or DATE_TRUNC(''week'', DEPARTURE_DATE)).
  - Fill Rate: Use order_fulfillment.ORDER_DATE for monthly/weekly grouping (GROUP BY DATE_TRUNC(''month'', ORDER_DATE) or DATE_TRUNC(''week'', ORDER_DATE)).
  - DOI: Use inventory.SNAPSHOT_DATE. For trends, group by SNAPSHOT_DATE directly.
  - Landed Cost: Use shipments.DEPARTURE_DATE for monthly/weekly grouping.
  Shipment data covers April 2024 (departures 2024-04-07 to 2024-04-11, arrivals 2024-04-17 to 2024-04-29). Order data covers 2024-04-03 to 2024-04-09. Inventory data covers 2024-03-12 to 2024-04-10.
  Do not fabricate data for periods that do not exist.

11. TEMPORAL REFERENCES: When a question says "last month", "previous month", or "most recent month", resolve to the latest month in the data: use WHERE DATE_TRUNC(''month'', date_col) = (SELECT MAX(DATE_TRUNC(''month'', date_col)) FROM table). When asked "by month" or "monthly", GROUP BY DATE_TRUNC(''month'', date_col). When asked "by week" or "weekly", GROUP BY DATE_TRUNC(''week'', date_col). When asked about "first week" or "second week" of a month, the first week starts with DATE_TRUNC(''week'', first_day_of_month) and the second week is the next DATE_TRUNC week boundary.

12. CROSS-METRIC PATTERN: When combining metrics from different tables (OTD + fill rate, OTD + landed cost, OTD + DOI, etc.), use separate CTEs for each metric aggregated to the required common grain (e.g. supplier level), then JOIN the CTEs together. NEVER join multiple fact tables in a single pass. Example pattern:
  WITH cte_otd AS (SELECT supplier_id, OTD FROM shipments GROUP BY supplier_id),
       cte_cost AS (SELECT supplier_id, cost FROM shipments GROUP BY supplier_id)
  SELECT ... FROM cte_otd JOIN cte_cost ON supplier_id
  For cross-metric filtering ("poor OTD AND high cost"), apply filters AFTER computing each metric independently.

13. CODE EXECUTION PROHIBITION: ALWAYS use the Cortex Analyst SQL generation tool for supply-chain metric questions. Do NOT switch to code execution or Python for questions that can be answered with SQL against the semantic model.

14. SYNONYM RESOLUTION: "delivery performance", "delivery reliability", "how reliable" all map to on_time_delivery. "order fill", "fulfillment rate", "how well did X fill orders" all map to fill_rate. "fully loaded cost", "delivered cost", "acquisition cost" all map to total_landed_cost. "inventory coverage", "days cover", "days of supply" all map to days_of_inventory.

15. INVENTORY RISK: Parts with DOI < 5 at the latest snapshot are at inventory risk. DOI < 3 is critical risk. DOI = 0 means stockout. When asked about "inventory risk" or "low inventory", filter to DOI < 5. Filter inventory to MAX(snapshot_date) and compute DOI per plant and part.'

AI_VERIFIED_QUERIES (
    -- ═══ OTD ═══
    overall_otd AS (
        QUESTION 'What is our overall on-time delivery?'
        SQL 'SELECT ROUND(COUNT_IF(ARRIVAL_DATE <= REQUESTED_DELIVERY_DATE)::FLOAT / NULLIF(COUNT(*), 0), 4) AS on_time_delivery FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT WHERE IS_VALID_SHIPMENT = TRUE AND REQUESTED_DELIVERY_DATE IS NOT NULL'
    ),
    otd_by_supplier AS (
        QUESTION 'What is OTD by supplier?'
        SQL 'SELECT ds.SUPPLIER_NAME, ROUND(COUNT_IF(fs.ARRIVAL_DATE <= fs.REQUESTED_DELIVERY_DATE)::FLOAT / NULLIF(COUNT(*), 0), 4) AS on_time_delivery FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID = dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID = ds.SUPPLIER_ID WHERE fs.IS_VALID_SHIPMENT = TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY ds.SUPPLIER_NAME ORDER BY on_time_delivery'
    ),
    otd_by_plant AS (
        QUESTION 'What is OTD by plant?'
        SQL 'SELECT dp.PLANT_NAME, ROUND(COUNT_IF(fs.ARRIVAL_DATE <= fs.REQUESTED_DELIVERY_DATE)::FLOAT / NULLIF(COUNT(*), 0), 4) AS on_time_delivery FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp ON fs.DESTINATION_PLANT_ID = dp.PLANT_ID WHERE fs.IS_VALID_SHIPMENT = TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY dp.PLANT_NAME ORDER BY on_time_delivery'
    ),
    suppliers_below_otd_threshold AS (
        QUESTION 'Which suppliers have OTD below 90%?'
        SQL 'SELECT ds.SUPPLIER_NAME, ROUND(COUNT_IF(fs.ARRIVAL_DATE <= fs.REQUESTED_DELIVERY_DATE)::FLOAT / NULLIF(COUNT(*), 0), 4) AS on_time_delivery FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID = dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID = ds.SUPPLIER_ID WHERE fs.IS_VALID_SHIPMENT = TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY ds.SUPPLIER_NAME HAVING on_time_delivery < 0.90 ORDER BY on_time_delivery'
    ),
    late_shipments_by_plant AS (
        QUESTION 'Which plants have the most late shipments?'
        SQL 'SELECT dp.PLANT_NAME, COUNT_IF(fs.ARRIVAL_DATE > fs.REQUESTED_DELIVERY_DATE) AS late_count, COUNT(*) AS total, ROUND(COUNT_IF(fs.ARRIVAL_DATE > fs.REQUESTED_DELIVERY_DATE)::FLOAT / NULLIF(COUNT(*), 0), 4) AS late_rate FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp ON fs.DESTINATION_PLANT_ID = dp.PLANT_ID WHERE fs.IS_VALID_SHIPMENT = TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY dp.PLANT_NAME ORDER BY late_count DESC'
    ),

    -- ═══ TEMPORAL OTD ═══
    otd_by_month AS (
        QUESTION 'How has OTD changed by month?'
        SQL 'SELECT DATE_TRUNC(''month'', fs.DEPARTURE_DATE) AS month, ROUND(COUNT_IF(fs.ARRIVAL_DATE <= fs.REQUESTED_DELIVERY_DATE)::FLOAT / NULLIF(COUNT(*), 0), 4) AS on_time_delivery FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs WHERE fs.IS_VALID_SHIPMENT = TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY 1 ORDER BY 1'
    ),
    otd_last_month AS (
        QUESTION 'What was OTD last month?'
        SQL 'SELECT ROUND(COUNT_IF(fs.ARRIVAL_DATE <= fs.REQUESTED_DELIVERY_DATE)::FLOAT / NULLIF(COUNT(*), 0), 4) AS on_time_delivery FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs WHERE fs.IS_VALID_SHIPMENT = TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL AND DATE_TRUNC(''month'', fs.DEPARTURE_DATE) = (SELECT MAX(DATE_TRUNC(''month'', DEPARTURE_DATE)) FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT)'
    ),
    otd_by_week AS (
        QUESTION 'Compare OTD between the first and second week of April'
        SQL 'SELECT DATE_TRUNC(''week'', fs.DEPARTURE_DATE) AS week_start, COUNT(*) AS eligible, ROUND(COUNT_IF(fs.ARRIVAL_DATE <= fs.REQUESTED_DELIVERY_DATE)::FLOAT / NULLIF(COUNT(*), 0), 4) AS on_time_delivery FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs WHERE fs.IS_VALID_SHIPMENT = TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY 1 ORDER BY 1'
    ),

    -- ═══ TEMPORAL FILL RATE ═══
    fill_rate_by_week AS (
        QUESTION 'Which weeks had the best fill rate?'
        SQL 'SELECT DATE_TRUNC(''week'', vof.ORDER_DATE) AS week_start, ROUND(SUM(vof.SHIPPED_QUANTITY) / NULLIF(SUM(vof.ORDERED_QUANTITY), 0), 4) AS fill_rate FROM SUPPLYCHAIN_DB.CORE.V_ORDER_FULFILLMENT vof GROUP BY 1 ORDER BY fill_rate DESC'
    ),

    -- ═══ FILL RATE ═══
    overall_fill_rate AS (
        QUESTION 'What is our overall fill rate?'
        SQL 'SELECT ROUND(SUM(SHIPPED_QUANTITY) / NULLIF(SUM(ORDERED_QUANTITY), 0), 4) AS fill_rate FROM SUPPLYCHAIN_DB.CORE.V_ORDER_FULFILLMENT'
    ),
    fill_rate_by_supplier AS (
        QUESTION 'What is fill rate by supplier?'
        SQL 'SELECT ds.SUPPLIER_NAME, ROUND(SUM(vof.SHIPPED_QUANTITY) / NULLIF(SUM(vof.ORDERED_QUANTITY), 0), 4) AS fill_rate FROM SUPPLYCHAIN_DB.CORE.V_ORDER_FULFILLMENT vof JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON vof.PART_ID = dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID = ds.SUPPLIER_ID GROUP BY ds.SUPPLIER_NAME ORDER BY fill_rate'
    ),
    fill_rate_by_part AS (
        QUESTION 'What is fill rate by part?'
        SQL 'SELECT dpt.PART_NAME, ROUND(SUM(vof.SHIPPED_QUANTITY) / NULLIF(SUM(vof.ORDERED_QUANTITY), 0), 4) AS fill_rate FROM SUPPLYCHAIN_DB.CORE.V_ORDER_FULFILLMENT vof JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON vof.PART_ID = dpt.PART_ID GROUP BY dpt.PART_NAME ORDER BY fill_rate'
    ),
    fill_rate_by_plant AS (
        QUESTION 'What is fill rate by plant?'
        SQL 'SELECT dp.PLANT_NAME, ROUND(SUM(vof.SHIPPED_QUANTITY) / NULLIF(SUM(vof.ORDERED_QUANTITY), 0), 4) AS fill_rate FROM SUPPLYCHAIN_DB.CORE.V_ORDER_FULFILLMENT vof JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp ON vof.PLANT_ID = dp.PLANT_ID GROUP BY dp.PLANT_NAME ORDER BY fill_rate'
    ),

    -- ═══ DAYS OF INVENTORY ═══
    doi_overall AS (
        QUESTION 'What are our current days of inventory?'
        SQL 'SELECT ROUND(SUM(INVENTORY_QUANTITY) / NULLIF(SUM(DAILY_DEMAND), 0), 2) AS days_of_inventory FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY WHERE SNAPSHOT_DATE = (SELECT MAX(SNAPSHOT_DATE) FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY)'
    ),
    doi_by_plant AS (
        QUESTION 'What is DOI by plant?'
        SQL 'SELECT dp.PLANT_NAME, ROUND(SUM(fi.INVENTORY_QUANTITY) / NULLIF(SUM(fi.DAILY_DEMAND), 0), 2) AS days_of_inventory FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY fi JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp ON fi.PLANT_ID = dp.PLANT_ID WHERE fi.SNAPSHOT_DATE = (SELECT MAX(SNAPSHOT_DATE) FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY) GROUP BY dp.PLANT_NAME ORDER BY days_of_inventory'
    ),
    inventory_risk AS (
        QUESTION 'Which parts are causing inventory risk?'
        SQL 'SELECT dpt.PART_NAME, dp.PLANT_NAME, fi.INVENTORY_QUANTITY, fi.DAILY_DEMAND, ROUND(fi.INVENTORY_QUANTITY / NULLIF(fi.DAILY_DEMAND, 0), 2) AS days_of_inventory, CASE WHEN fi.INVENTORY_QUANTITY = 0 THEN ''STOCKOUT'' WHEN fi.INVENTORY_QUANTITY / NULLIF(fi.DAILY_DEMAND, 0) < 3 THEN ''CRITICAL'' ELSE ''AT_RISK'' END AS risk_status FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY fi JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fi.PART_ID = dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp ON fi.PLANT_ID = dp.PLANT_ID WHERE fi.SNAPSHOT_DATE = (SELECT MAX(SNAPSHOT_DATE) FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY) AND fi.INVENTORY_QUANTITY / NULLIF(fi.DAILY_DEMAND, 0) < 5 ORDER BY days_of_inventory'
    ),

    -- ═══ LANDED COST ═══
    landed_cost_overall AS (
        QUESTION 'What is our total landed cost?'
        SQL 'SELECT ROUND(SUM(LANDED_COST), 2) AS total_landed_cost FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT WHERE IS_VALID_SHIPMENT = TRUE'
    ),
    landed_cost_by_supplier AS (
        QUESTION 'What is landed cost by supplier?'
        SQL 'SELECT ds.SUPPLIER_NAME, ROUND(SUM(fs.LANDED_COST), 2) AS total_landed_cost FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID = dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID = ds.SUPPLIER_ID WHERE fs.IS_VALID_SHIPMENT = TRUE GROUP BY ds.SUPPLIER_NAME ORDER BY total_landed_cost DESC'
    ),
    landed_cost_by_part AS (
        QUESTION 'What is landed cost by part?'
        SQL 'SELECT dpt.PART_NAME, ROUND(SUM(fs.LANDED_COST), 2) AS total_landed_cost FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID = dpt.PART_ID WHERE fs.IS_VALID_SHIPMENT = TRUE GROUP BY dpt.PART_NAME ORDER BY total_landed_cost DESC'
    ),

    -- ═══ CROSS-METRIC ═══
    supplier_otd_and_cost AS (
        QUESTION 'Which suppliers have both poor OTD and high landed cost?'
        SQL 'WITH sotd AS (SELECT dpt.SUPPLIER_ID, ROUND(COUNT_IF(fs.ARRIVAL_DATE <= fs.REQUESTED_DELIVERY_DATE)::FLOAT / NULLIF(COUNT(*), 0), 4) AS on_time_delivery FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID = dpt.PART_ID WHERE fs.IS_VALID_SHIPMENT = TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY 1), scost AS (SELECT dpt.SUPPLIER_ID, ROUND(SUM(fs.LANDED_COST), 2) AS total_landed_cost FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID = dpt.PART_ID WHERE fs.IS_VALID_SHIPMENT = TRUE GROUP BY 1), med AS (SELECT MEDIAN(total_landed_cost) AS m FROM scost) SELECT ds.SUPPLIER_NAME, sotd.on_time_delivery, scost.total_landed_cost FROM sotd JOIN scost ON sotd.SUPPLIER_ID = scost.SUPPLIER_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON sotd.SUPPLIER_ID = ds.SUPPLIER_ID CROSS JOIN med WHERE sotd.on_time_delivery < 0.70 AND scost.total_landed_cost > med.m ORDER BY sotd.on_time_delivery'
    ),
    plants_inventory_poor_suppliers AS (
        QUESTION 'Which plants are holding inventory for poorly performing suppliers?'
        SQL 'WITH sotd AS (SELECT dpt.SUPPLIER_ID, ROUND(COUNT_IF(fs.ARRIVAL_DATE <= fs.REQUESTED_DELIVERY_DATE)::FLOAT / NULLIF(COUNT(*), 0), 4) AS on_time_delivery FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID = dpt.PART_ID WHERE fs.IS_VALID_SHIPMENT = TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY 1) SELECT dp.PLANT_NAME, ds.SUPPLIER_NAME, sotd.on_time_delivery, ROUND(fi.INVENTORY_QUANTITY / NULLIF(fi.DAILY_DEMAND, 0), 2) AS days_of_inventory FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY fi JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp ON fi.PLANT_ID = dp.PLANT_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fi.PART_ID = dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID = ds.SUPPLIER_ID JOIN sotd ON dpt.SUPPLIER_ID = sotd.SUPPLIER_ID WHERE fi.SNAPSHOT_DATE = (SELECT MAX(SNAPSHOT_DATE) FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY) AND fi.INVENTORY_QUANTITY > 0 AND sotd.on_time_delivery < 0.70 ORDER BY days_of_inventory'
    ),
    late_shipments_high_risk_routes AS (
        QUESTION 'Which late shipments are associated with high-risk routes?'
        SQL 'SELECT dpo.PLANT_NAME AS origin, dpd.PLANT_NAME AS destination, fs.RISK_FLAG, COUNT(*) AS cnt FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dpo ON fs.ORIGIN_PLANT_ID = dpo.PLANT_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dpd ON fs.DESTINATION_PLANT_ID = dpd.PLANT_ID WHERE fs.RISK_FLAG = ''High'' GROUP BY 1, 2, 3 ORDER BY cnt DESC'
    ),
    supplier_performance_low_inventory AS (
        QUESTION 'Show supplier performance including OTD and fill rate for parts with low inventory'
        SQL 'WITH sotd AS (SELECT dpt.SUPPLIER_ID, dpt.PART_ID, ROUND(COUNT_IF(fs.ARRIVAL_DATE <= fs.REQUESTED_DELIVERY_DATE)::FLOAT / NULLIF(COUNT(*), 0), 4) AS on_time_delivery FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID = dpt.PART_ID WHERE fs.IS_VALID_SHIPMENT = TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY 1, 2), sfr AS (SELECT vof.PART_ID, ROUND(SUM(vof.SHIPPED_QUANTITY) / NULLIF(SUM(vof.ORDERED_QUANTITY), 0), 4) AS fill_rate FROM SUPPLYCHAIN_DB.CORE.V_ORDER_FULFILLMENT vof GROUP BY 1), sdoi AS (SELECT PART_ID, ROUND(SUM(INVENTORY_QUANTITY) / NULLIF(SUM(DAILY_DEMAND), 0), 2) AS days_of_inventory FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY WHERE SNAPSHOT_DATE = (SELECT MAX(SNAPSHOT_DATE) FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY) GROUP BY 1 HAVING days_of_inventory < 10) SELECT ds.SUPPLIER_NAME, dpt.PART_NAME, sotd.on_time_delivery, sfr.fill_rate, sdoi.days_of_inventory FROM sdoi JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON sdoi.PART_ID = dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID = ds.SUPPLIER_ID LEFT JOIN sotd ON dpt.SUPPLIER_ID = sotd.SUPPLIER_ID AND dpt.PART_ID = sotd.PART_ID LEFT JOIN sfr ON dpt.PART_ID = sfr.PART_ID ORDER BY sdoi.days_of_inventory'
    )
)
;
