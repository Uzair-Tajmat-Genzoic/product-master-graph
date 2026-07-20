-- Competitive-pricing seed for product-master graph (dataset: ctx_upside_master_data).
-- 6 REAL competitor brands, 16 competitor products mapped 1:1 to TenTen SKUs.
-- All products verified to actually sell online in India (Zepto/Blinkit/Swiggy/Amazon/
-- brand sites) so Gemini Google-Search grounding returns live prices. City = Pune.
-- Run with a default project set: bq --project_id=gen-lang-client-0520145261 ... < this file

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

