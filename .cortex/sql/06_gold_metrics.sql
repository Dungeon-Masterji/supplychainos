-- =============================================================================
-- SupplyChainOS: Gold SQL — Four Canonical Metrics
-- =============================================================================
-- Each metric is self-contained SQL against CORE tables.
-- No views, no dependencies between metrics.
--
-- Structure per metric:
--   1. GOLD SQL    — the canonical calculation
--   2. TEST QUERY  — dimensional breakdowns with manual verification
--
-- Table reference:
--   SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT   (159 rows, grain: shipment × part)
--   SUPPLYCHAIN_DB.CORE.FACT_ORDER      (83 rows,  grain: 1 per order)
--   SUPPLYCHAIN_DB.CORE.FACT_INVENTORY  (360 rows, grain: plant × part × day)
--   SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER    (6 rows)
--   SUPPLYCHAIN_DB.CORE.DIM_PART        (3 rows)
--   SUPPLYCHAIN_DB.CORE.DIM_PLANT       (4 rows)
--   SUPPLYCHAIN_DB.CORE.DIM_CUSTOMER    (8 rows)
-- =============================================================================

USE DATABASE SUPPLYCHAIN_DB;
USE SCHEMA CORE;


-- #############################################################################
-- METRIC 1: ON-TIME DELIVERY (OTD)
-- #############################################################################
--
-- Business definition:
--   Percentage of eligible shipment lines delivered on or before the
--   customer's requested delivery date.
--
-- Formula:
--   COUNT_IF(arrival_date <= requested_delivery_date)
--   / NULLIF(COUNT(*), 0)
--
-- Eligibility rules:
--   - EXCLUDE shipments where requested_delivery_date IS NULL
--   - EXCLUDE shipments where is_valid_shipment = FALSE (arrival < departure)
--
-- On-time condition: arrival_date <= requested_delivery_date (inclusive)
-- Result range: 0.0000 to 1.0000
-- Edge cases:
--   - arrival = requested → ON TIME (uses <=, not <)
--   - NULL requested date → excluded from numerator AND denominator
--   - Zero eligible rows for a slice → NULL via NULLIF
-- #############################################################################


-- ─── OTD GOLD: Overall on-time delivery rate ────────────────────────────────

WITH eligible_shipments AS (
    -- Filter to shipment lines that qualify for OTD measurement:
    -- must have a valid transit (arrival >= departure) and a non-NULL requested date.
    SELECT
        SHIPMENT_LINE_ID,
        SHIPMENT_ID,
        ARRIVAL_DATE,
        REQUESTED_DELIVERY_DATE,
        -- The on-time flag: TRUE if arrived on or before the requested date
        ARRIVAL_DATE <= REQUESTED_DELIVERY_DATE     AS IS_ON_TIME
    FROM FACT_SHIPMENT
    WHERE IS_VALID_SHIPMENT = TRUE                  -- exclude invalid transits
      AND REQUESTED_DELIVERY_DATE IS NOT NULL        -- exclude missing request dates
)
SELECT
    COUNT(*)                                        AS ELIGIBLE_SHIPMENTS,
    COUNT_IF(IS_ON_TIME)                            AS ON_TIME_COUNT,
    COUNT_IF(NOT IS_ON_TIME)                        AS LATE_COUNT,
    ROUND(
        COUNT_IF(IS_ON_TIME) / NULLIF(COUNT(*), 0),
        4
    )                                               AS OTD
FROM eligible_shipments;

-- Expected: ELIGIBLE=159, ON_TIME=111, LATE=48, OTD=0.6981


-- ─── OTD TEST: By supplier (via DIM_PART → DIM_SUPPLIER) ───────────────────
-- Business question: "Which supplier's parts have the worst delivery performance?"
-- Join path: FACT_SHIPMENT.part_id → DIM_PART.supplier_id → DIM_SUPPLIER

WITH eligible AS (
    SELECT
        fs.SHIPMENT_LINE_ID,
        fs.PART_ID,
        fs.ARRIVAL_DATE,
        fs.REQUESTED_DELIVERY_DATE,
        fs.ARRIVAL_DATE <= fs.REQUESTED_DELIVERY_DATE AS IS_ON_TIME,
        -- Days early (positive) or late (negative)
        DATEDIFF('day', fs.ARRIVAL_DATE, fs.REQUESTED_DELIVERY_DATE) AS DAYS_VARIANCE
    FROM FACT_SHIPMENT fs
    WHERE fs.IS_VALID_SHIPMENT = TRUE
      AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL
)
SELECT
    ds.SUPPLIER_ID,
    ds.SUPPLIER_NAME,
    dpt.PART_NAME,
    COUNT(*)                                        AS ELIGIBLE_LINES,
    COUNT_IF(e.IS_ON_TIME)                          AS ON_TIME,
    COUNT_IF(NOT e.IS_ON_TIME)                      AS LATE,
    ROUND(COUNT_IF(e.IS_ON_TIME)::FLOAT / NULLIF(COUNT(*), 0), 4)
                                                    AS OTD,
    ROUND(AVG(e.DAYS_VARIANCE), 1)                  AS AVG_DAYS_VARIANCE
FROM eligible e
JOIN DIM_PART      dpt ON e.PART_ID     = dpt.PART_ID
JOIN DIM_SUPPLIER  ds  ON dpt.SUPPLIER_ID = ds.SUPPLIER_ID
GROUP BY ds.SUPPLIER_ID, ds.SUPPLIER_NAME, dpt.PART_NAME
ORDER BY OTD;

-- Verification logic:
--   Supplier-1 (Apex, Blue Triangles): 83 lines, heaviest volume → expect ~70% OTD
--   Supplier-3 (Pacific, Red Squares):  51 lines → compare against network avg
--   Supplier-5 (Midwest, Yellow Circles): 25 lines → smallest sample
--   All three OTDs should bracket the overall 69.81%
--   AVG_DAYS_VARIANCE > 0 means generally early; < 0 means generally late


-- ─── OTD TEST: Show individual on-time vs late shipments for one supplier ───
-- Drill into Supplier-1 (Apex Components, Blue Triangles) to see actual dates.

SELECT
    fs.SHIPMENT_LINE_ID,
    fs.DEPARTURE_DATE,
    fs.ARRIVAL_DATE,
    fs.REQUESTED_DELIVERY_DATE,
    fs.DELIVERY_DAYS,
    DATEDIFF('day', fs.ARRIVAL_DATE, fs.REQUESTED_DELIVERY_DATE) AS DAYS_EARLY_OR_LATE,
    CASE WHEN fs.ARRIVAL_DATE <= fs.REQUESTED_DELIVERY_DATE
         THEN 'ON TIME' ELSE 'LATE' END                         AS OTD_STATUS,
    fs.RISK_FLAG
FROM FACT_SHIPMENT fs
JOIN DIM_PART dpt ON fs.PART_ID = dpt.PART_ID
WHERE dpt.SUPPLIER_ID = 'supplier-1'                            -- Apex Components
  AND fs.IS_VALID_SHIPMENT = TRUE
  AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL
ORDER BY DAYS_EARLY_OR_LATE
LIMIT 10;

-- Verification: LATE rows should have negative DAYS_EARLY_OR_LATE.
--               High-risk shipments should skew late.
--               ON TIME rows should have DAYS_EARLY_OR_LATE >= 0.


-- #############################################################################
-- METRIC 2: FILL RATE
-- #############################################################################
--
-- Business definition:
--   Total quantity shipped divided by total quantity ordered.
--
-- Formula:
--   SUM(shipped_quantity) / NULLIF(SUM(ordered_quantity), 0)
--
-- CRITICAL — fan-out prevention:
--   FACT_ORDER has 1 row per order (83 rows).
--   FACT_SHIPMENT has 1-3 rows per order (159 total — one per product on the truck).
--   A naive JOIN inflates ordered_quantity by the number of shipment lines.
--
--   Correct approach: aggregate shipped_quantity TO the order level FIRST,
--   then join to FACT_ORDER for ordered_quantity.
--
-- Result range: 0.0000 to 1.0000+ (can exceed 1.0 if adjustments cause overship)
-- Edge cases:
--   - ordered_quantity = 0 → NULL via NULLIF
--   - No shipment lines for an order → shipped = 0, fill_rate = 0.0
-- #############################################################################


-- ─── FILL RATE GOLD: Overall fill rate ──────────────────────────────────────

WITH shipped_per_order AS (
    -- Step 1: Aggregate shipped quantity to the ORDER level.
    -- This collapses the 1-to-many (order → shipment lines) before dividing.
    SELECT
        ORDER_ID,
        SUM(SHIPPED_QUANTITY)       AS TOTAL_SHIPPED
    FROM FACT_SHIPMENT
    WHERE IS_VALID_SHIPMENT = TRUE
    GROUP BY ORDER_ID
)
SELECT
    SUM(spo.TOTAL_SHIPPED)                                              AS TOTAL_SHIPPED,
    SUM(fo.ORDERED_QUANTITY)                                             AS TOTAL_ORDERED,
    ROUND(
        SUM(spo.TOTAL_SHIPPED) / NULLIF(SUM(fo.ORDERED_QUANTITY), 0),
        4
    )                                                                    AS FILL_RATE
FROM FACT_ORDER fo
LEFT JOIN shipped_per_order spo
    ON fo.ORDER_ID = spo.ORDER_ID;

-- Expected: TOTAL_SHIPPED=860000, TOTAL_ORDERED=946000, FILL_RATE=0.9091


-- ─── FILL RATE TEST: By supplier ───────────────────────────────────────────
-- Business question: "Which supplier's parts have the lowest fulfillment?"
-- Join: FACT_ORDER.part_id → DIM_PART.supplier_id → DIM_SUPPLIER

WITH shipped_per_order AS (
    SELECT ORDER_ID, SUM(SHIPPED_QUANTITY) AS TOTAL_SHIPPED
    FROM FACT_SHIPMENT
    WHERE IS_VALID_SHIPMENT = TRUE
    GROUP BY ORDER_ID
)
SELECT
    ds.SUPPLIER_ID,
    ds.SUPPLIER_NAME,
    dpt.PART_NAME,
    COUNT(fo.ORDER_ID)                                                   AS ORDER_COUNT,
    SUM(fo.ORDERED_QUANTITY)                                             AS TOTAL_ORDERED,
    SUM(COALESCE(spo.TOTAL_SHIPPED, 0))                                  AS TOTAL_SHIPPED,
    ROUND(
        SUM(COALESCE(spo.TOTAL_SHIPPED, 0))
        / NULLIF(SUM(fo.ORDERED_QUANTITY), 0),
        4
    )                                                                    AS FILL_RATE,
    -- Under-fill count: orders where shipped < ordered
    COUNT_IF(COALESCE(spo.TOTAL_SHIPPED, 0) < fo.ORDERED_QUANTITY)       AS UNDER_FILLED_ORDERS
FROM FACT_ORDER fo
LEFT JOIN shipped_per_order spo ON fo.ORDER_ID = spo.ORDER_ID
JOIN DIM_PART      dpt ON fo.PART_ID      = dpt.PART_ID
JOIN DIM_SUPPLIER  ds  ON dpt.SUPPLIER_ID = ds.SUPPLIER_ID
GROUP BY ds.SUPPLIER_ID, ds.SUPPLIER_NAME, dpt.PART_NAME
ORDER BY FILL_RATE;

-- Verification logic:
--   Each supplier maps to one part. Fill rates should reflect the ratio
--   of shipped vs ordered for orders dominated by that part.
--   All fill rates should be < 1.0 (our data has surplus-added ordered_quantity).
--   UNDER_FILLED_ORDERS > 0 confirms partial fulfillment exists.


-- #############################################################################
-- METRIC 3: DAYS OF INVENTORY (DOI)
-- #############################################################################
--
-- Business definition:
--   How many days current inventory will last at current demand rate.
--
-- Formula:
--   SUM(inventory_quantity) / NULLIF(SUM(daily_demand), 0)
--
-- Grain: 1 row per plant × part × day in FACT_INVENTORY.
-- Typically filtered to the latest snapshot_date for "current" DOI.
--
-- Zero-demand handling: Returns NULL when daily_demand = 0 (signals "no demand
--   signal" rather than "infinite coverage").
-- Edge cases:
--   - inventory = 0, demand > 0 → DOI = 0.00 (stockout)
--   - inventory > 0, demand = 0 → DOI = NULL (no demand to measure against)
--   - Both zero → NULL
-- Result range: 0.00 to ~100+ days
-- #############################################################################


-- ─── DOI GOLD: Network-wide, latest snapshot ────────────────────────────────

SELECT
    fi.SNAPSHOT_DATE,
    SUM(fi.INVENTORY_QUANTITY)                                          AS TOTAL_INVENTORY,
    SUM(fi.DAILY_DEMAND)                                                AS TOTAL_DAILY_DEMAND,
    ROUND(
        SUM(fi.INVENTORY_QUANTITY) / NULLIF(SUM(fi.DAILY_DEMAND), 0),
        2
    )                                                                    AS DAYS_OF_INVENTORY
FROM FACT_INVENTORY fi
WHERE fi.SNAPSHOT_DATE = (SELECT MAX(SNAPSHOT_DATE) FROM FACT_INVENTORY)
GROUP BY fi.SNAPSHOT_DATE;

-- Expected: SNAPSHOT_DATE=2024-04-10, TOTAL_INV=31920, DEMAND=5899, DOI=5.41


-- ─── DOI TEST: By plant, latest snapshot ────────────────────────────────────
-- Business question: "Which plant is closest to stockout?"

SELECT
    fi.PLANT_ID,
    dp.PLANT_NAME,
    fi.SNAPSHOT_DATE,
    SUM(fi.INVENTORY_QUANTITY)                                          AS TOTAL_INVENTORY,
    SUM(fi.DAILY_DEMAND)                                                AS TOTAL_DAILY_DEMAND,
    ROUND(
        SUM(fi.INVENTORY_QUANTITY) / NULLIF(SUM(fi.DAILY_DEMAND), 0),
        2
    )                                                                    AS DAYS_OF_INVENTORY,
    -- Stockout flag: any part at this plant with zero inventory?
    COUNT_IF(fi.INVENTORY_QUANTITY = 0)                                  AS PARTS_AT_STOCKOUT,
    -- Min DOI across individual parts (most vulnerable)
    MIN(
        ROUND(fi.INVENTORY_QUANTITY / NULLIF(fi.DAILY_DEMAND, 0), 2)
    )                                                                    AS MIN_PART_DOI
FROM FACT_INVENTORY fi
JOIN DIM_PLANT dp ON fi.PLANT_ID = dp.PLANT_ID
WHERE fi.SNAPSHOT_DATE = (SELECT MAX(SNAPSHOT_DATE) FROM FACT_INVENTORY)
GROUP BY fi.PLANT_ID, dp.PLANT_NAME, fi.SNAPSHOT_DATE
ORDER BY DAYS_OF_INVENTORY;

-- Verification logic:
--   Houston should be lowest DOI (~2 days) — highest demand, many outbound shipments
--   New York should be highest DOI (~11 days) — receives the most inbound shipments
--   PARTS_AT_STOCKOUT > 0 confirms real stockout conditions exist
--   MIN_PART_DOI = 0.00 means at least one part is fully stocked out


-- ─── DOI TEST: Drill into Houston (most at-risk plant) ─────────────────────

SELECT
    fi.PLANT_ID,
    dp.PLANT_NAME,
    fi.PART_ID,
    dpt.PART_NAME,
    fi.SNAPSHOT_DATE,
    fi.INVENTORY_QUANTITY,
    fi.DAILY_DEMAND,
    fi.INBOUND_QUANTITY,
    ROUND(
        fi.INVENTORY_QUANTITY / NULLIF(fi.DAILY_DEMAND, 0),
        2
    )                                                                    AS DAYS_OF_INVENTORY,
    CASE WHEN fi.INVENTORY_QUANTITY = 0 THEN 'STOCKOUT'
         WHEN fi.INVENTORY_QUANTITY / NULLIF(fi.DAILY_DEMAND, 0) < 3 THEN 'CRITICAL'
         WHEN fi.INVENTORY_QUANTITY / NULLIF(fi.DAILY_DEMAND, 0) < 7 THEN 'LOW'
         ELSE 'HEALTHY'
    END                                                                  AS HEALTH_STATUS
FROM FACT_INVENTORY fi
JOIN DIM_PLANT dp  ON fi.PLANT_ID = dp.PLANT_ID
JOIN DIM_PART  dpt ON fi.PART_ID  = dpt.PART_ID
WHERE fi.PLANT_ID = 'location-houston'
  AND fi.SNAPSHOT_DATE = (SELECT MAX(SNAPSHOT_DATE) FROM FACT_INVENTORY)
ORDER BY DAYS_OF_INVENTORY;

-- Verification: At least one part should show STOCKOUT or CRITICAL status.


-- #############################################################################
-- METRIC 4: LANDED COST
-- #############################################################################
--
-- Business definition:
--   Total acquisition cost: product cost + freight + duty + handling.
--
-- Formula:
--   SUM(material_cost) + SUM(freight_cost) + SUM(duty_cost) + SUM(handling_cost)
--   which equals SUM(landed_cost)  [pre-computed in FACT_SHIPMENT]
--
-- Per-unit version:
--   SUM(landed_cost) / NULLIF(SUM(shipped_quantity), 0)
--   IMPORTANT: divide AFTER aggregation, not before.
--
-- Grain: Shipment-line level (159 rows).
-- Multiple lines: A shipment with 3 products has 3 rows. Aggregation
--   naturally sums costs correctly because each row has its own cost.
-- Edge cases:
--   - shipped_quantity = 0 → per-unit cost = NULL
--   - All cost components are NOT NULL in current data
-- Result range: 0 to millions (USD)
-- #############################################################################


-- ─── LANDED COST GOLD: Overall and component breakdown ──────────────────────

SELECT
    COUNT(*)                                        AS SHIPMENT_LINES,
    SUM(SHIPPED_QUANTITY)                           AS TOTAL_UNITS,

    -- Component costs
    ROUND(SUM(MATERIAL_COST), 2)                   AS TOTAL_MATERIAL,
    ROUND(SUM(FREIGHT_COST), 2)                    AS TOTAL_FREIGHT,
    ROUND(SUM(DUTY_COST), 2)                       AS TOTAL_DUTY,
    ROUND(SUM(HANDLING_COST), 2)                   AS TOTAL_HANDLING,

    -- Total landed (pre-computed column — should equal sum of components)
    ROUND(SUM(LANDED_COST), 2)                     AS TOTAL_LANDED,

    -- Cross-check: compute from components to verify consistency
    ROUND(SUM(MATERIAL_COST) + SUM(FREIGHT_COST) + SUM(DUTY_COST) + SUM(HANDLING_COST), 2)
                                                   AS LANDED_FROM_COMPONENTS,

    -- Per-unit (divide AFTER aggregation)
    ROUND(
        SUM(LANDED_COST) / NULLIF(SUM(SHIPPED_QUANTITY), 0),
        4
    )                                               AS COST_PER_UNIT

FROM FACT_SHIPMENT
WHERE IS_VALID_SHIPMENT = TRUE;

-- Expected: TOTAL_LANDED ≈ $10.19M, COST_PER_UNIT ≈ $11.85
-- Verification: TOTAL_LANDED = LANDED_FROM_COMPONENTS (must match exactly)


-- ─── LANDED COST TEST: By supplier ─────────────────────────────────────────
-- Business question: "Which supplier's parts have the highest landed cost per unit?"

SELECT
    ds.SUPPLIER_ID,
    ds.SUPPLIER_NAME,
    dpt.PART_NAME,
    ds.REGION                                       AS SUPPLIER_REGION,

    COUNT(*)                                        AS SHIPMENT_LINES,
    SUM(fs.SHIPPED_QUANTITY)                        AS TOTAL_UNITS,

    -- Per-component breakdown
    ROUND(SUM(fs.MATERIAL_COST), 2)                AS TOTAL_MATERIAL,
    ROUND(SUM(fs.FREIGHT_COST), 2)                 AS TOTAL_FREIGHT,
    ROUND(SUM(fs.DUTY_COST), 2)                    AS TOTAL_DUTY,
    ROUND(SUM(fs.HANDLING_COST), 2)                AS TOTAL_HANDLING,
    ROUND(SUM(fs.LANDED_COST), 2)                  AS TOTAL_LANDED,

    -- Per-unit landed cost
    ROUND(
        SUM(fs.LANDED_COST) / NULLIF(SUM(fs.SHIPPED_QUANTITY), 0),
        4
    )                                               AS COST_PER_UNIT,

    -- Cost composition percentages
    ROUND(SUM(fs.MATERIAL_COST) / NULLIF(SUM(fs.LANDED_COST), 0) * 100, 1)
                                                    AS MATERIAL_PCT,
    ROUND(SUM(fs.FREIGHT_COST)  / NULLIF(SUM(fs.LANDED_COST), 0) * 100, 1)
                                                    AS FREIGHT_PCT,
    ROUND(SUM(fs.DUTY_COST)     / NULLIF(SUM(fs.LANDED_COST), 0) * 100, 1)
                                                    AS DUTY_PCT,
    ROUND(SUM(fs.HANDLING_COST) / NULLIF(SUM(fs.LANDED_COST), 0) * 100, 1)
                                                    AS HANDLING_PCT

FROM FACT_SHIPMENT fs
JOIN DIM_PART      dpt ON fs.PART_ID      = dpt.PART_ID
JOIN DIM_SUPPLIER  ds  ON dpt.SUPPLIER_ID = ds.SUPPLIER_ID
WHERE fs.IS_VALID_SHIPMENT = TRUE
GROUP BY ds.SUPPLIER_ID, ds.SUPPLIER_NAME, dpt.PART_NAME, ds.REGION
ORDER BY COST_PER_UNIT DESC;

-- Verification logic:
--   Yellow Circles (Supplier-5, Midwest) should have highest per-unit cost
--     because unit_cost = $15.00 (highest) and duty_rate = 4%.
--   Red Squares (Supplier-3, Pacific) should have lowest per-unit cost
--     because unit_cost = $8.75 (lowest).
--   Material cost should dominate (>99%) — freight/duty/handling are small.
--   MATERIAL_PCT + FREIGHT_PCT + DUTY_PCT + HANDLING_PCT ≈ 100%.


-- ─── LANDED COST TEST: Cross-check component additivity ────────────────────
-- Verify that landed_cost = material + freight + duty + handling for EVERY row.
-- Any mismatch indicates a data integrity issue.

SELECT
    COUNT(*)                                        AS TOTAL_ROWS,
    COUNT_IF(
        ABS(LANDED_COST - (MATERIAL_COST + FREIGHT_COST + DUTY_COST + HANDLING_COST)) < 0.01
    )                                               AS MATCHING_ROWS,
    COUNT_IF(
        ABS(LANDED_COST - (MATERIAL_COST + FREIGHT_COST + DUTY_COST + HANDLING_COST)) >= 0.01
    )                                               AS MISMATCHED_ROWS
FROM FACT_SHIPMENT;

-- Expected: TOTAL=159, MATCHING=159, MISMATCHED=0
