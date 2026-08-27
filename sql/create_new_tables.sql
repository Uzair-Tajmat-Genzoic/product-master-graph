-- Base tables for the product-master graph (dataset: ctx_upside_master_data).
--
-- THE TWO HALVES RE-RUN DIFFERENTLY -- read before running the whole file.
--   Competitive pricing (CREATE OR REPLACE): re-running DROPS the competitor rows, and no seed
--   script here can rebuild them. Run one statement at a time unless you mean to reseed.
--   Recipes & costing (IF NOT EXISTS): re-running is a no-op. DROP explicitly to change a schema.
--
-- Recipe/costing seed: scripts/generate_recipes_and_costs.py; derived cost is in sql/views.sql.

CREATE OR REPLACE TABLE `ctx_upside_master_data.DIM_COMPETITOR` (
  COMPETITOR_ID STRING, COMPETITOR_NAME STRING, WEBSITE STRING, HQ_CITY STRING,
  COUNTRY STRING, CATEGORY STRING, TIER STRING, CHANNELS STRING, IS_ACTIVE BOOL
);
CREATE OR REPLACE TABLE `ctx_upside_master_data.DIM_COMPETITOR_PRODUCT` (
  COMPETITOR_PRODUCT_ID STRING, COMPETITOR_ID STRING, PRODUCT_NAME STRING,
  SIZE STRING, CITY STRING, IS_ACTIVE BOOL
);
CREATE OR REPLACE TABLE `ctx_upside_master_data.MAP_COMPETITOR_PRODUCT_TO_PRODUCT` (
  COMPETITOR_PRODUCT_ID STRING, SKU STRING, MATCH_CONFIDENCE FLOAT64, NOTE STRING
);

CREATE TABLE IF NOT EXISTS `ctx_upside_master_data.DIM_RECIPE` (
  RECIPE_ID           STRING NOT NULL,   -- 'RCP-<SKU|IDEA_ID>-v<n>'
  SKU                 STRING,            -- SKU or IDEA_ID is set, never both
  IDEA_ID             STRING,
  RECIPE_NAME         STRING,
  VERSION_NO          INT64,
  PARENT_RECIPE_ID    STRING,
  STATUS              STRING,
  IS_CURRENT          BOOL,
  BATCH_SIZE_G        NUMERIC,           -- = DIM_PRODUCT.SIZE_GM for SKU baselines
  PACKAGING_COST_INR  NUMERIC,
  LABOUR_OVERHEAD_INR NUMERIC,           -- conversion cost; the non-ingredient, non-packaging half
  TARGET_COGS_INR     NUMERIC,
  AUTHOR              STRING,
  NOTES               STRING,
  CREATED_AT          TIMESTAMP
);

CREATE TABLE IF NOT EXISTS `ctx_upside_master_data.MAP_RECIPE_INGREDIENT` (
  RECIPE_LINE_ID  STRING NOT NULL,       -- 'RCPL-<RECIPE_ID>-<nn>', not an entity id
  RECIPE_ID       STRING NOT NULL,
  INGREDIENT_ID   STRING NOT NULL,
  QTY_NET_G       NUMERIC,               -- canonical; all cost math is grams/1000 * INR/kg
  QTY_AUTHORED    NUMERIC,
  UOM             STRING,                -- 'g' | 'ml', label only
  LOSS_PCT        NUMERIC,               -- gross = net / (1 - LOSS_PCT/100); cost charged on gross
  ROLE            STRING,
  LINE_SEQ        INT64,
  IS_OPTIONAL     BOOL,
  NOTES           STRING
);

CREATE TABLE IF NOT EXISTS `ctx_upside_master_data.DIM_INGREDIENT_PRICE` (
  PRICE_ID          STRING NOT NULL,     -- 'IPR-<INGREDIENT_ID>-<seq>'
  INGREDIENT_ID     STRING NOT NULL,
  SUPPLIER_NAME     STRING,              -- free text; no DIM_SUPPLIER by design
  PRICE_INR         NUMERIC,
  PRICE_UOM         STRING,              -- 'kg' | 'L' only
  DENSITY_G_PER_ML  NUMERIC,             -- only when PRICE_UOM='L'
  EFFECTIVE_FROM    DATE NOT NULL,
  EFFECTIVE_TO      DATE,                -- NULL = current; window is half-open
  PRICE_SOURCE      STRING,
  NOTE              STRING,
  CREATED_AT        TIMESTAMP
);
