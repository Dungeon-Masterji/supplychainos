-- =============================================================================
-- SupplyChainOS: Evaluation Framework — Gold Questions + Test Procedure
-- =============================================================================
-- 30 gold-standard questions with trusted SQL, expected results, and an
-- automated stored procedure that executes each query and validates row counts.
--
-- Depends on: SUPPLYCHAIN_DB.CORE.* (7 tables, populated)
--             SUPPLYCHAIN_DB.EVAL schema (from 01_setup_database.sql)
-- =============================================================================

USE DATABASE SUPPLYCHAIN_DB;
USE SCHEMA EVAL;


-- =========================================================================
-- 1. GOLD_QUESTIONS TABLE
-- =========================================================================
CREATE OR REPLACE TABLE GOLD_QUESTIONS (
    QUESTION_ID      VARCHAR(10)  NOT NULL PRIMARY KEY,
    QUESTION_TEXT    VARCHAR(500) NOT NULL,
    GOLD_SQL         VARCHAR      NOT NULL,
    EXPECTED_METRIC  VARCHAR(100) NOT NULL,
    EXPECTED_RESULT  VARIANT      NOT NULL,
    RESULT_COUNT     INTEGER      NOT NULL,
    NOTES            VARCHAR(500)
) COMMENT = 'Gold-standard evaluation: 30 questions with trusted SQL and expected results.';


-- =========================================================================
-- 2. LOAD ALL 30 QUESTIONS
-- =========================================================================

-- Q001-Q005: Simple metrics
INSERT INTO GOLD_QUESTIONS
SELECT 'Q001', 'What is our overall on-time delivery?',
 'SELECT ROUND(COUNT_IF(ARRIVAL_DATE <= REQUESTED_DELIVERY_DATE)::FLOAT / NULLIF(COUNT(*), 0), 4) AS OTD FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT WHERE IS_VALID_SHIPMENT = TRUE AND REQUESTED_DELIVERY_DATE IS NOT NULL',
 'on_time_delivery', PARSE_JSON('{"otd": 0.6981}'), 1, 'Eligible: valid transit + non-null requested date'
UNION ALL SELECT 'Q002', 'What is our overall fill rate?',
 'WITH spo AS (SELECT ORDER_ID, SUM(SHIPPED_QUANTITY) AS S FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT WHERE IS_VALID_SHIPMENT=TRUE GROUP BY ORDER_ID) SELECT ROUND(SUM(spo.S)/NULLIF(SUM(fo.ORDERED_QUANTITY),0),4) AS FILL_RATE FROM SUPPLYCHAIN_DB.CORE.FACT_ORDER fo LEFT JOIN spo ON fo.ORDER_ID=spo.ORDER_ID',
 'fill_rate', PARSE_JSON('{"fill_rate": 0.9091}'), 1, 'Aggregate shipped to order level first'
UNION ALL SELECT 'Q003', 'What are our current days of inventory?',
 'SELECT ROUND(SUM(INVENTORY_QUANTITY)/NULLIF(SUM(DAILY_DEMAND),0),2) AS DOI FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY WHERE SNAPSHOT_DATE=(SELECT MAX(SNAPSHOT_DATE) FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY)',
 'days_of_inventory', PARSE_JSON('{"doi": 5.41}'), 1, 'Latest snapshot (2024-04-10), network-wide'
UNION ALL SELECT 'Q004', 'What is our total landed cost?',
 'SELECT ROUND(SUM(MATERIAL_COST)+SUM(FREIGHT_COST)+SUM(DUTY_COST)+SUM(HANDLING_COST),2) AS LANDED_COST FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT WHERE IS_VALID_SHIPMENT=TRUE',
 'total_landed_cost', PARSE_JSON('{"landed_cost": 10193841.18}'), 1, 'Sum of 4 cost components'
UNION ALL SELECT 'Q005', 'What is our OTD?',
 'SELECT ROUND(COUNT_IF(ARRIVAL_DATE <= REQUESTED_DELIVERY_DATE)::FLOAT / NULLIF(COUNT(*), 0), 4) AS OTD FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT WHERE IS_VALID_SHIPMENT = TRUE AND REQUESTED_DELIVERY_DATE IS NOT NULL',
 'on_time_delivery', PARSE_JSON('{"otd": 0.6981}'), 1, 'Synonym test: OTD = on_time_delivery';

-- Q006-Q010: Dimension slicing
INSERT INTO GOLD_QUESTIONS
SELECT 'Q006', 'What is OTD by plant?',
 'SELECT dp.PLANT_NAME, ROUND(COUNT_IF(fs.ARRIVAL_DATE<=fs.REQUESTED_DELIVERY_DATE)::FLOAT/NULLIF(COUNT(*),0),4) AS OTD FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp ON fs.DESTINATION_PLANT_ID=dp.PLANT_ID WHERE fs.IS_VALID_SHIPMENT=TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY dp.PLANT_NAME ORDER BY OTD',
 'on_time_delivery', PARSE_JSON('[{"plant":"Chicago Facility","otd":0.5385},{"plant":"New York Facility","otd":0.7246},{"plant":"Houston Facility","otd":0.7368},{"plant":"St. Louis Facility","otd":0.9231}]'), 4, 'By destination plant'
UNION ALL SELECT 'Q007', 'What is OTD by supplier?',
 'SELECT ds.SUPPLIER_NAME, ROUND(COUNT_IF(fs.ARRIVAL_DATE<=fs.REQUESTED_DELIVERY_DATE)::FLOAT/NULLIF(COUNT(*),0),4) AS OTD FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID=dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID=ds.SUPPLIER_ID WHERE fs.IS_VALID_SHIPMENT=TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY ds.SUPPLIER_NAME ORDER BY OTD',
 'on_time_delivery', PARSE_JSON('[{"supplier":"Midwest Supply Inc","otd":0.68},{"supplier":"Apex Components","otd":0.6867},{"supplier":"Pacific Materials","otd":0.7255}]'), 3, 'Via part->supplier join'
UNION ALL SELECT 'Q008', 'What is fill rate by supplier?',
 'WITH spo AS (SELECT ORDER_ID, SUM(SHIPPED_QUANTITY) AS S FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT WHERE IS_VALID_SHIPMENT=TRUE GROUP BY ORDER_ID) SELECT ds.SUPPLIER_NAME, ROUND(SUM(COALESCE(spo.S,0))/NULLIF(SUM(fo.ORDERED_QUANTITY),0),4) AS FILL_RATE FROM SUPPLYCHAIN_DB.CORE.FACT_ORDER fo LEFT JOIN spo ON fo.ORDER_ID=spo.ORDER_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fo.PART_ID=dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID=ds.SUPPLIER_ID GROUP BY ds.SUPPLIER_NAME ORDER BY FILL_RATE',
 'fill_rate', PARSE_JSON('[{"supplier":"Apex Components","fill_rate":0.5942},{"supplier":"Pacific Materials","fill_rate":1.1681},{"supplier":"Midwest Supply Inc","fill_rate":1.8779}]'), 3, 'Pre-aggregated shipped per order'
UNION ALL SELECT 'Q009', 'What is landed cost by supplier?',
 'SELECT ds.SUPPLIER_NAME, ROUND(SUM(fs.LANDED_COST),2) AS TOTAL_LANDED FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID=dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID=ds.SUPPLIER_ID WHERE fs.IS_VALID_SHIPMENT=TRUE GROUP BY ds.SUPPLIER_NAME ORDER BY TOTAL_LANDED DESC',
 'total_landed_cost', PARSE_JSON('[{"supplier":"Apex Components","landed":5336097.68},{"supplier":"Pacific Materials","landed":2443552.48},{"supplier":"Midwest Supply Inc","landed":2414191.02}]'), 3, 'Apex highest due to volume'
UNION ALL SELECT 'Q010', 'What is DOI by plant?',
 'SELECT dp.PLANT_NAME, ROUND(SUM(fi.INVENTORY_QUANTITY)/NULLIF(SUM(fi.DAILY_DEMAND),0),2) AS DOI FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY fi JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp ON fi.PLANT_ID=dp.PLANT_ID WHERE fi.SNAPSHOT_DATE=(SELECT MAX(SNAPSHOT_DATE) FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY) GROUP BY dp.PLANT_NAME ORDER BY DOI',
 'days_of_inventory', PARSE_JSON('[{"plant":"Houston Facility","doi":1.97},{"plant":"St. Louis Facility","doi":4.89},{"plant":"Chicago Facility","doi":5.07},{"plant":"New York Facility","doi":11.26}]'), 4, 'Houston critical at ~2 days';

-- Q011-Q015: Ranking/filtering
INSERT INTO GOLD_QUESTIONS
SELECT 'Q011', 'Which suppliers have OTD below 90%?',
 'SELECT ds.SUPPLIER_NAME, ROUND(COUNT_IF(fs.ARRIVAL_DATE<=fs.REQUESTED_DELIVERY_DATE)::FLOAT/NULLIF(COUNT(*),0),4) AS OTD FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID=dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID=ds.SUPPLIER_ID WHERE fs.IS_VALID_SHIPMENT=TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY ds.SUPPLIER_NAME HAVING OTD<0.90 ORDER BY OTD',
 'on_time_delivery', PARSE_JSON('[{"supplier":"Midwest Supply Inc","otd":0.68},{"supplier":"Apex Components","otd":0.6867},{"supplier":"Pacific Materials","otd":0.7255}]'), 3, 'All 3 below 90%'
UNION ALL SELECT 'Q012', 'Which suppliers have the highest landed cost?',
 'SELECT ds.SUPPLIER_NAME, ROUND(SUM(fs.LANDED_COST),2) AS TOTAL_LANDED FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID=dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID=ds.SUPPLIER_ID WHERE fs.IS_VALID_SHIPMENT=TRUE GROUP BY ds.SUPPLIER_NAME ORDER BY TOTAL_LANDED DESC',
 'total_landed_cost', PARSE_JSON('[{"supplier":"Apex Components","landed":5336097.68},{"supplier":"Pacific Materials","landed":2443552.48},{"supplier":"Midwest Supply Inc","landed":2414191.02}]'), 3, 'Ranked DESC'
UNION ALL SELECT 'Q013', 'Which parts have the lowest fill rate?',
 'WITH spo AS (SELECT ORDER_ID, SUM(SHIPPED_QUANTITY) AS S FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT WHERE IS_VALID_SHIPMENT=TRUE GROUP BY ORDER_ID) SELECT dpt.PART_NAME, ROUND(SUM(COALESCE(spo.S,0))/NULLIF(SUM(fo.ORDERED_QUANTITY),0),4) AS FILL_RATE FROM SUPPLYCHAIN_DB.CORE.FACT_ORDER fo LEFT JOIN spo ON fo.ORDER_ID=spo.ORDER_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fo.PART_ID=dpt.PART_ID GROUP BY dpt.PART_NAME ORDER BY FILL_RATE',
 'fill_rate', PARSE_JSON('[{"part":"Blue Triangles","fill_rate":0.5942},{"part":"Red Squares","fill_rate":1.1681},{"part":"Yellow Circles","fill_rate":1.8779}]'), 3, 'Blue Triangles lowest'
UNION ALL SELECT 'Q014', 'Which parts have fewer than 10 days of inventory?',
 'SELECT dpt.PART_NAME, ROUND(SUM(fi.INVENTORY_QUANTITY)/NULLIF(SUM(fi.DAILY_DEMAND),0),2) AS DOI FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY fi JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fi.PART_ID=dpt.PART_ID WHERE fi.SNAPSHOT_DATE=(SELECT MAX(SNAPSHOT_DATE) FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY) GROUP BY dpt.PART_NAME HAVING DOI<10 ORDER BY DOI',
 'days_of_inventory', PARSE_JSON('[{"part":"Red Squares","doi":0.75},{"part":"Yellow Circles","doi":2.36}]'), 2, 'Blue Triangles excluded (DOI>=10)'
UNION ALL SELECT 'Q015', 'Which plants have the most late shipments?',
 'SELECT dp.PLANT_NAME, COUNT_IF(fs.ARRIVAL_DATE>fs.REQUESTED_DELIVERY_DATE) AS LATE_COUNT, COUNT(*) AS TOTAL FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp ON fs.DESTINATION_PLANT_ID=dp.PLANT_ID WHERE fs.IS_VALID_SHIPMENT=TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY dp.PLANT_NAME ORDER BY LATE_COUNT DESC',
 'on_time_delivery', PARSE_JSON('[{"plant":"New York Facility","late":19},{"plant":"Chicago Facility","late":18},{"plant":"Houston Facility","late":10},{"plant":"St. Louis Facility","late":1}]'), 4, 'New York most late';

-- Q016-Q020: Temporal/trend
INSERT INTO GOLD_QUESTIONS
SELECT 'Q016', 'How has OTD changed by month?',
 'SELECT DATE_TRUNC(''month'',fs.DEPARTURE_DATE) AS MONTH, ROUND(COUNT_IF(fs.ARRIVAL_DATE<=fs.REQUESTED_DELIVERY_DATE)::FLOAT/NULLIF(COUNT(*),0),4) AS OTD FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs WHERE fs.IS_VALID_SHIPMENT=TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY 1 ORDER BY 1',
 'on_time_delivery', PARSE_JSON('[{"month":"2024-04","otd":0.6981}]'), 1, 'Single month in data'
UNION ALL SELECT 'Q017', 'What was OTD last month?',
 'SELECT ROUND(COUNT_IF(fs.ARRIVAL_DATE<=fs.REQUESTED_DELIVERY_DATE)::FLOAT/NULLIF(COUNT(*),0),4) AS OTD FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs WHERE fs.IS_VALID_SHIPMENT=TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL AND DATE_TRUNC(''month'',fs.DEPARTURE_DATE)=(SELECT MAX(DATE_TRUNC(''month'',DEPARTURE_DATE)) FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT)',
 'on_time_delivery', PARSE_JSON('{"otd": 0.6981}'), 1, 'Last month = only month = Apr 2024'
UNION ALL SELECT 'Q018', 'Compare OTD between the first and second week of April',
 'SELECT DATE_TRUNC(''week'',fs.DEPARTURE_DATE) AS WEEK_START, COUNT(*) AS ELIGIBLE, ROUND(COUNT_IF(fs.ARRIVAL_DATE<=fs.REQUESTED_DELIVERY_DATE)::FLOAT/NULLIF(COUNT(*),0),4) AS OTD FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs WHERE fs.IS_VALID_SHIPMENT=TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY 1 ORDER BY 1',
 'on_time_delivery', PARSE_JSON('[{"week":"2024-04-01","otd":0.5},{"week":"2024-04-08","otd":0.7032}]'), 2, 'Week 1 had only 4 shipments'
UNION ALL SELECT 'Q019', 'Which weeks had the best fill rate?',
 'WITH spo AS (SELECT ORDER_ID, SUM(SHIPPED_QUANTITY) AS S FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT WHERE IS_VALID_SHIPMENT=TRUE GROUP BY ORDER_ID) SELECT DATE_TRUNC(''week'',fo.ORDER_DATE) AS WEEK_START, ROUND(SUM(COALESCE(spo.S,0))/NULLIF(SUM(fo.ORDERED_QUANTITY),0),4) AS FILL_RATE FROM SUPPLYCHAIN_DB.CORE.FACT_ORDER fo LEFT JOIN spo ON fo.ORDER_ID=spo.ORDER_ID GROUP BY 1 ORDER BY FILL_RATE DESC',
 'fill_rate', PARSE_JSON('[{"week":"2024-04-01","fill_rate":0.9167},{"week":"2024-03-31","fill_rate":0.9032}]'), 2, 'By order_date week'
UNION ALL SELECT 'Q020', 'Show inventory trend over the last 30 days',
 'SELECT fi.SNAPSHOT_DATE, ROUND(SUM(fi.INVENTORY_QUANTITY)/NULLIF(SUM(fi.DAILY_DEMAND),0),2) AS DOI FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY fi GROUP BY fi.SNAPSHOT_DATE ORDER BY fi.SNAPSHOT_DATE',
 'days_of_inventory', PARSE_JSON('{"rows": 30, "first_doi": 30.51, "last_doi": 5.41}'), 30, 'Daily DOI trend 30.51 down to 5.41';

-- Q021-Q025: Cross-domain
INSERT INTO GOLD_QUESTIONS
SELECT 'Q021', 'Which suppliers have both poor OTD and high landed cost?',
 'WITH sotd AS (SELECT dpt.SUPPLIER_ID, ROUND(COUNT_IF(fs.ARRIVAL_DATE<=fs.REQUESTED_DELIVERY_DATE)::FLOAT/NULLIF(COUNT(*),0),4) AS OTD FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID=dpt.PART_ID WHERE fs.IS_VALID_SHIPMENT=TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY 1), scost AS (SELECT dpt.SUPPLIER_ID, ROUND(SUM(fs.LANDED_COST),2) AS TOTAL_LANDED FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID=dpt.PART_ID WHERE fs.IS_VALID_SHIPMENT=TRUE GROUP BY 1), med AS (SELECT MEDIAN(TOTAL_LANDED) AS M FROM scost) SELECT ds.SUPPLIER_NAME, sotd.OTD, scost.TOTAL_LANDED FROM sotd JOIN scost ON sotd.SUPPLIER_ID=scost.SUPPLIER_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON sotd.SUPPLIER_ID=ds.SUPPLIER_ID CROSS JOIN med WHERE sotd.OTD<0.70 AND scost.TOTAL_LANDED>med.M ORDER BY sotd.OTD',
 'on_time_delivery+total_landed_cost', PARSE_JSON('[{"supplier":"Apex Components","otd":0.6867,"landed":5336097.68}]'), 1, 'Only Apex qualifies'
UNION ALL SELECT 'Q022', 'Which parts are causing inventory risk?',
 'SELECT dp.PLANT_NAME, dpt.PART_NAME, ROUND(fi.INVENTORY_QUANTITY/NULLIF(fi.DAILY_DEMAND,0),2) AS DOI FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY fi JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp ON fi.PLANT_ID=dp.PLANT_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fi.PART_ID=dpt.PART_ID WHERE fi.SNAPSHOT_DATE=(SELECT MAX(SNAPSHOT_DATE) FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY) AND fi.INVENTORY_QUANTITY/NULLIF(fi.DAILY_DEMAND,0)<5 ORDER BY DOI',
 'days_of_inventory', PARSE_JSON('[{"count":8}]'), 8, '5 stockouts + 3 critical'
UNION ALL SELECT 'Q023', 'Which plants are holding inventory for poorly performing suppliers?',
 'WITH sotd AS (SELECT dpt.SUPPLIER_ID, ROUND(COUNT_IF(fs.ARRIVAL_DATE<=fs.REQUESTED_DELIVERY_DATE)::FLOAT/NULLIF(COUNT(*),0),4) AS OTD FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID=dpt.PART_ID WHERE fs.IS_VALID_SHIPMENT=TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY 1) SELECT dp.PLANT_NAME, ds.SUPPLIER_NAME, sotd.OTD, ROUND(fi.INVENTORY_QUANTITY/NULLIF(fi.DAILY_DEMAND,0),2) AS DOI FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY fi JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp ON fi.PLANT_ID=dp.PLANT_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fi.PART_ID=dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID=ds.SUPPLIER_ID JOIN sotd ON dpt.SUPPLIER_ID=sotd.SUPPLIER_ID WHERE fi.SNAPSHOT_DATE=(SELECT MAX(SNAPSHOT_DATE) FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY) AND fi.INVENTORY_QUANTITY>0 AND sotd.OTD<0.70 ORDER BY DOI',
 'days_of_inventory+on_time_delivery', PARSE_JSON('[{"count":5}]'), 5, 'Apex and Midwest have OTD<70%'
UNION ALL SELECT 'Q024', 'Which late shipments are associated with high-risk routes?',
 'SELECT dpo.PLANT_NAME AS ORIGIN, dpd.PLANT_NAME AS DESTINATION, fs.RISK_FLAG, COUNT(*) AS CNT FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dpo ON fs.ORIGIN_PLANT_ID=dpo.PLANT_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dpd ON fs.DESTINATION_PLANT_ID=dpd.PLANT_ID WHERE fs.RISK_FLAG=''High'' GROUP BY 1,2,3 ORDER BY CNT DESC',
 'on_time_delivery', PARSE_JSON('[{"count":5,"total_shipments":13}]'), 5, '13 High-risk lines across 5 routes'
UNION ALL SELECT 'Q025', 'Show supplier performance including OTD and fill rate for parts with low inventory',
 'WITH sotd AS (SELECT dpt.SUPPLIER_ID, dpt.PART_ID, ROUND(COUNT_IF(fs.ARRIVAL_DATE<=fs.REQUESTED_DELIVERY_DATE)::FLOAT/NULLIF(COUNT(*),0),4) AS OTD FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID=dpt.PART_ID WHERE fs.IS_VALID_SHIPMENT=TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY 1,2), spo AS (SELECT ORDER_ID, SUM(SHIPPED_QUANTITY) AS S FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT WHERE IS_VALID_SHIPMENT=TRUE GROUP BY ORDER_ID), sfr AS (SELECT fo.PART_ID, ROUND(SUM(COALESCE(spo.S,0))/NULLIF(SUM(fo.ORDERED_QUANTITY),0),4) AS FILL_RATE FROM SUPPLYCHAIN_DB.CORE.FACT_ORDER fo LEFT JOIN spo ON fo.ORDER_ID=spo.ORDER_ID GROUP BY 1), sdoi AS (SELECT PART_ID, ROUND(SUM(INVENTORY_QUANTITY)/NULLIF(SUM(DAILY_DEMAND),0),2) AS DOI FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY WHERE SNAPSHOT_DATE=(SELECT MAX(SNAPSHOT_DATE) FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY) GROUP BY 1 HAVING DOI<10) SELECT ds.SUPPLIER_NAME, dpt.PART_NAME, sotd.OTD, sfr.FILL_RATE, sdoi.DOI FROM sdoi JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON sdoi.PART_ID=dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID=ds.SUPPLIER_ID LEFT JOIN sotd ON dpt.SUPPLIER_ID=sotd.SUPPLIER_ID AND dpt.PART_ID=sotd.PART_ID LEFT JOIN sfr ON dpt.PART_ID=sfr.PART_ID ORDER BY sdoi.DOI',
 'on_time_delivery+fill_rate+days_of_inventory', PARSE_JSON('[{"supplier":"Pacific Materials","part":"Red Squares","otd":0.7255,"fill_rate":1.1681,"doi":0.75},{"supplier":"Midwest Supply Inc","part":"Yellow Circles","otd":0.68,"fill_rate":1.8779,"doi":2.36}]'), 2, 'Only parts with DOI<10';

-- Q026-Q030: Persona-specific
INSERT INTO GOLD_QUESTIONS
SELECT 'Q026', 'Which suppliers have poor delivery performance?',
 'SELECT ds.SUPPLIER_NAME, ROUND(COUNT_IF(fs.ARRIVAL_DATE<=fs.REQUESTED_DELIVERY_DATE)::FLOAT/NULLIF(COUNT(*),0),4) AS OTD FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID=dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID=ds.SUPPLIER_ID WHERE fs.IS_VALID_SHIPMENT=TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY ds.SUPPLIER_NAME ORDER BY OTD',
 'on_time_delivery', PARSE_JSON('[{"supplier":"Midwest Supply Inc","otd":0.68},{"supplier":"Apex Components","otd":0.6867},{"supplier":"Pacific Materials","otd":0.7255}]'), 3, 'Planning persona. Same SQL as Q007'
UNION ALL SELECT 'Q027', 'How reliable are our suppliers?',
 'SELECT ds.SUPPLIER_NAME, ROUND(COUNT_IF(fs.ARRIVAL_DATE<=fs.REQUESTED_DELIVERY_DATE)::FLOAT/NULLIF(COUNT(*),0),4) AS OTD FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID=dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID=ds.SUPPLIER_ID WHERE fs.IS_VALID_SHIPMENT=TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL GROUP BY ds.SUPPLIER_NAME ORDER BY OTD',
 'on_time_delivery', PARSE_JSON('[{"supplier":"Midwest Supply Inc","otd":0.68},{"supplier":"Apex Components","otd":0.6867},{"supplier":"Pacific Materials","otd":0.7255}]'), 3, 'Procurement persona. Reliable = OTD'
UNION ALL SELECT 'Q028', 'What percentage of shipments arrived on time?',
 'SELECT ROUND(COUNT_IF(ARRIVAL_DATE <= REQUESTED_DELIVERY_DATE)::FLOAT / NULLIF(COUNT(*), 0), 4) AS OTD FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT WHERE IS_VALID_SHIPMENT = TRUE AND REQUESTED_DELIVERY_DATE IS NOT NULL',
 'on_time_delivery', PARSE_JSON('{"otd": 0.6981}'), 1, 'Logistics persona. Same SQL as Q001'
UNION ALL SELECT 'Q029', 'How well did suppliers fill orders?',
 'WITH spo AS (SELECT ORDER_ID, SUM(SHIPPED_QUANTITY) AS S FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT WHERE IS_VALID_SHIPMENT=TRUE GROUP BY ORDER_ID) SELECT ds.SUPPLIER_NAME, ROUND(SUM(COALESCE(spo.S,0))/NULLIF(SUM(fo.ORDERED_QUANTITY),0),4) AS FILL_RATE FROM SUPPLYCHAIN_DB.CORE.FACT_ORDER fo LEFT JOIN spo ON fo.ORDER_ID=spo.ORDER_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fo.PART_ID=dpt.PART_ID JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID=ds.SUPPLIER_ID GROUP BY ds.SUPPLIER_NAME ORDER BY FILL_RATE',
 'fill_rate', PARSE_JSON('[{"supplier":"Apex Components","fill_rate":0.5942},{"supplier":"Pacific Materials","fill_rate":1.1681},{"supplier":"Midwest Supply Inc","fill_rate":1.8779}]'), 3, 'Planning persona. Same SQL as Q008'
UNION ALL SELECT 'Q030', 'What is the order fulfillment rate?',
 'WITH spo AS (SELECT ORDER_ID, SUM(SHIPPED_QUANTITY) AS S FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT WHERE IS_VALID_SHIPMENT=TRUE GROUP BY ORDER_ID) SELECT ROUND(SUM(spo.S)/NULLIF(SUM(fo.ORDERED_QUANTITY),0),4) AS FILL_RATE FROM SUPPLYCHAIN_DB.CORE.FACT_ORDER fo LEFT JOIN spo ON fo.ORDER_ID=spo.ORDER_ID',
 'fill_rate', PARSE_JSON('{"fill_rate": 0.9091}'), 1, 'Procurement persona. Fulfillment = fill_rate';


-- =========================================================================
-- 3. RUN_GOLD_QUESTIONS STORED PROCEDURE
-- =========================================================================
-- Iterates all 30 gold questions, executes each SQL, compares row count
-- to expected, and returns a pass/fail summary.
--
-- Usage: CALL SUPPLYCHAIN_DB.EVAL.RUN_GOLD_QUESTIONS();
-- =========================================================================

CREATE OR REPLACE PROCEDURE RUN_GOLD_QUESTIONS()
RETURNS TABLE(
    QUESTION_ID VARCHAR, QUESTION_TEXT VARCHAR, EXPECTED_METRIC VARCHAR,
    EXPECTED_ROWS INTEGER, ACTUAL_ROWS INTEGER, ROW_COUNT_MATCH VARCHAR,
    EXECUTION_STATUS VARCHAR, ERROR_MESSAGE VARCHAR
)
LANGUAGE SQL
EXECUTE AS CALLER
AS $$
DECLARE
    res RESULTSET;
BEGIN
    -- Temp table to accumulate results
    CREATE OR REPLACE TEMPORARY TABLE EVAL_RESULTS (
        QUESTION_ID VARCHAR, QUESTION_TEXT VARCHAR, EXPECTED_METRIC VARCHAR,
        EXPECTED_ROWS INTEGER, ACTUAL_ROWS INTEGER, ROW_COUNT_MATCH VARCHAR,
        EXECUTION_STATUS VARCHAR, ERROR_MESSAGE VARCHAR
    );

    -- Iterate over all gold questions
    LET c CURSOR FOR
        SELECT QUESTION_ID, QUESTION_TEXT, GOLD_SQL, EXPECTED_METRIC, RESULT_COUNT
        FROM SUPPLYCHAIN_DB.EVAL.GOLD_QUESTIONS
        ORDER BY QUESTION_ID;

    FOR rec IN c DO
        BEGIN
            -- Extract cursor values into local variables (required for SQL statements)
            LET qid VARCHAR := rec.QUESTION_ID;
            LET qtxt VARCHAR := rec.QUESTION_TEXT;
            LET qmet VARCHAR := rec.EXPECTED_METRIC;
            LET qexp INTEGER := rec.RESULT_COUNT;
            LET sql_text VARCHAR := rec.GOLD_SQL;

            -- Wrap gold SQL in COUNT(*) to get row count
            LET count_sql VARCHAR := 'SELECT COUNT(*) AS CNT FROM (' || :sql_text || ')';
            LET actual_cnt INTEGER := 0;

            -- Execute and capture row count
            LET rs RESULTSET := (EXECUTE IMMEDIATE :count_sql);
            LET cur CURSOR FOR rs;
            FOR r IN cur DO
                actual_cnt := r.CNT;
            END FOR;

            -- Compare
            LET match_status VARCHAR :=
                CASE WHEN :actual_cnt = :qexp THEN 'PASS' ELSE 'FAIL' END;

            INSERT INTO EVAL_RESULTS VALUES (
                :qid, :qtxt, :qmet, :qexp, :actual_cnt, :match_status, 'SUCCESS', NULL
            );
        EXCEPTION
            WHEN OTHER THEN
                INSERT INTO EVAL_RESULTS VALUES (
                    :qid, :qtxt, :qmet, :qexp, NULL, 'ERROR', 'FAILED', SQLERRM
                );
        END;
    END FOR;

    -- Return all results
    res := (SELECT * FROM EVAL_RESULTS ORDER BY QUESTION_ID);
    RETURN TABLE(res);
END;
$$;
