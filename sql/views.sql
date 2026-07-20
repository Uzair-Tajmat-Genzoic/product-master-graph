-- Helper views for the product-master context graph.
-- Run ONCE in BigQuery (project erp-set-up) before `contextgraph apply`.
--   bq query --use_legacy_sql=false < sql/views.sql
-- or paste into the BigQuery console.
--
-- PIM views live in ctx_upside_master_data. Live views live in bronze and
-- reach silver/gold via fully-qualified names.

-- =====================================================================
-- PIM (gen-lang-client-0520145261.ctx_upside_master_data)
-- =====================================================================

-- Product node: flatten the three 1:1 facets onto DIM_PRODUCT so Product
-- is one clean node (mirrors how Monginis folded pricing onto Product).
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_ENRICHED` AS
SELECT
  p.SKU,
  p.DISPLAY_NAME,
  p.FLAVOUR,
  p.SIZE_GM,
  p.SIZE_LABEL,
  p.VERSION,
  p.STATUS,
  p.VEG_NONVEG,
  p.IS_ACTIVE,
  p.DESCRIPTION,
  p.IMAGES_LINK,
  pr.BASE_PRICE_INR,
  pr.GST_RATE,
  pr.MRP_INR,
  pr.TOTAL_COGS_INR,
  pr.SHELF_LIFE_DAYS,
  pk.PACKAGING_TYPE,
  pk.GS1_BARCODE,
  pk.ORG_LABELLING_COMPLIANCE,
  nu.SERVING_SIZE
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` p
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_PRICING`   pr USING (SKU)
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_PACKAGING` pk USING (SKU)
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_NUTRITION` nu USING (SKU);

-- Claim node: give each highlight a stable single-column id.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_CLAIM` AS
SELECT
  CONCAT(SKU, '-', CAST(HIGHLIGHT_SEQ AS STRING)) AS CLAIM_ID,
  SKU,
  HIGHLIGHT_SEQ,
  HIGHLIGHT_TEXT
FROM `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_HIGHLIGHT`;

-- Nutrient dimension (empty until parse_nutrients.py populates PRODUCT_NUTRIENT).
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_NUTRIENT_DIM` AS
SELECT DISTINCT NUTRIENT_NAME
FROM `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_NUTRIENT`;

-- =====================================================================
-- LIVE (gen-lang-client-0520145261.bronze / silver / gold)
-- =====================================================================

-- Complaint node: EVENT_ID is null for rows ingested via the email-parsing
-- path (no ticketing EVENT_ID was ever assigned) — EMAIL_MESSAGE_ID is
-- present and unique whenever EVENT_ID isn't, so coalesce them into one
-- always-populated, always-unique id.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_COMPLAINT_EVENTS` AS
SELECT * REPLACE (COALESCE(EVENT_ID, EMAIL_MESSAGE_ID) AS EVENT_ID)
FROM `gen-lang-client-0520145261.bronze.CUSTOMER_COMPLAINT_EVENTS`;

-- stocked_at edge: latest FLAGGED_INVENTORY row per store x SKU (one edge each).
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_STOCKED_AT` AS
SELECT * EXCEPT(rn) FROM (
  SELECT
    SKU_ID,
    MASTER_STORE_ID,
    TOTAL_STOCK,
    SAFE_STOCK,
    EXPIRED_STOCK,
    SOONEST_EXPIRY,
    QTY_EXPIRING_WITHIN_RISK_DAYS,
    WASTAGE_FLAG,
    LOW_STOCK_FLAG,
    SHELF_LIFE_DAYS,
    ROW_NUMBER() OVER (PARTITION BY MASTER_STORE_ID, SKU_ID ORDER BY REPORT_DATE DESC) AS rn
  FROM `gen-lang-client-0520145261.bronze.FLAGGED_INVENTORY`
)
WHERE rn = 1;

-- (forecast: no view. The Product "Forecast quantity by store" widget queries
-- the gold base table gold.FORECAST_RESULTS_UPDATE directly via a raw widget
-- query — latest run, next 1-3 days, summed per store. See link_datasets.yaml.)

-- transfer_route edge: FROM/TO_STORE_ID are the same store identity as
-- MASTER_STORE_ID (confirmed) — cast INT64 -> STRING to bridge the type difference.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_TRANSFER_ROUTE` AS
SELECT
  CAST(FROM_STORE_ID AS STRING) AS FROM_STORE_ID,
  CAST(TO_STORE_ID   AS STRING) AS TO_STORE_ID,
  DISTANCE_KM,
  PREFERRED_FOR_TRANSFER
FROM `gen-lang-client-0520145261.bronze.STORE_TRANSFER_DISTANCES`;

-- complaint_about_product edge (OPTIONAL, deferred): fuzzy item-name -> SKU.
-- Enable the edge in live_bq.yaml once you've validated the match rate.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_COMPLAINT_RESOLVED` AS
SELECT
  c.EVENT_ID,
  p.SKU AS SKU_ID
FROM `gen-lang-client-0520145261.bronze.V_COMPLAINT_EVENTS` c
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` p
  ON UPPER(TRIM(c.ITEM_NAME)) = UPPER(TRIM(p.DISPLAY_NAME));

-- =====================================================================
-- MARKETING (gen-lang-client-0520145261.bronze)  —  campaigns + segments
-- =====================================================================

-- Store's currently-running campaigns this month. RAW_MARKETING_DATA is Zomato
-- ad data at the daily x campaign grain with no store id — RES_ID is the Zomato
-- restaurant id, resolved to MASTER_STORE_ID via STORE_CHANNEL_MAPPING.ZOMATO_ID
-- (INT64 -> STRING). Keeps only campaigns live today (CURRENT_DATE between
-- START/END) and sums this calendar month's daily rows to one row per campaign.
-- Dynamic on CURRENT_DATE(), so it re-scopes to "this month / running now" on
-- every render — this is a fast-moving lazy link, not materialised on apply.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_STORE_CAMPAIGN_CURRENT` AS
SELECT
  m.MASTER_STORE_ID,
  r.CAMPAIGN_ID,
  ANY_VALUE(r.PRODUCT_TYPE)          AS PRODUCT_TYPE,
  ANY_VALUE(r.TARGETING)             AS TARGETING,
  ANY_VALUE(r.SEGMENTS)              AS SEGMENTS,
  MIN(r.START_DATE)                  AS START_DATE,
  MAX(r.END_DATE)                    AS END_DATE,
  ROUND(SUM(r.AD_SPEND_RS), 0)       AS AD_SPEND_RS,
  ROUND(SUM(r.AD_SALES_RS), 0)       AS AD_SALES_RS,
  SUM(r.AD_ORDERS)                   AS AD_ORDERS,
  SUM(r.AD_IMPRESSIONS)              AS AD_IMPRESSIONS,
  SUM(r.AD_CLICKS)                   AS AD_CLICKS
FROM `gen-lang-client-0520145261.bronze.RAW_MARKETING_DATA` r
JOIN `gen-lang-client-0520145261.bronze.STORE_CHANNEL_MAPPING` m
  ON r.RES_ID = CAST(m.ZOMATO_ID AS STRING)
WHERE r.DATE >= DATE_TRUNC(CURRENT_DATE(), MONTH)
  AND CURRENT_DATE() BETWEEN r.START_DATE AND r.END_DATE
GROUP BY m.MASTER_STORE_ID, r.CAMPAIGN_ID;

-- segment_on_channel edge: MARKETING_SEGMENT_MASTER.CHANNEL ('SWIGGY'/'ZOMATO')
-- resolves to the Channel node by name (DIM_CHANNEL.CHANNEL_NAME). Gives each
-- CustomerSegment its Channel id (CH-012 Swiggy / CH-015 Zomato).
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_SEGMENT_ON_CHANNEL` AS
SELECT
  s.SEGMENT_ID,
  ch.CHANNEL_ID
FROM `gen-lang-client-0520145261.bronze.MARKETING_SEGMENT_MASTER` s
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CHANNEL` ch
  ON UPPER(ch.CHANNEL_NAME) = UPPER(s.CHANNEL);

-- Segment budget allocations: MARKETING_BUDGET.SEGMENT_TYPE == SEGMENT_CODE
-- (per channel) -> exposes SEGMENT_ID so the link can scope to one segment.
-- Shows which stores fund this segment, on which channel, and how much.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_SEGMENT_BUDGET` AS
SELECT
  s.SEGMENT_ID,
  b.MASTER_STORE_ID,
  b.STORE_NAME,
  b.CHANNEL,
  b.BUDGET_MONTH,
  b.ALLOCATED_BUDGET_RS,
  b.EXPECTED_REVENUE_RS
FROM `gen-lang-client-0520145261.bronze.MARKETING_BUDGET` b
JOIN `gen-lang-client-0520145261.bronze.MARKETING_SEGMENT_MASTER` s
  ON b.SEGMENT_TYPE = s.SEGMENT_CODE
 AND UPPER(b.CHANNEL) = UPPER(s.CHANNEL);
