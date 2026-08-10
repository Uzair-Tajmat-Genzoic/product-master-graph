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

-- Manufacturing capability envelope: one row per product line actually made
-- today, with category, active SKU count, observed COGS range and shelf life.
-- Feeds idea_capture_triage's feasibility step — a form factor absent from this
-- view is one the company has NEVER produced.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_LINE_CAPABILITY` AS
SELECT
  l.PRODUCT_LINE_ID,
  l.PRODUCT_LINE_NAME,
  c.CATEGORY_NAME,
  COUNT(*)                      AS ACTIVE_SKUS,
  ROUND(MIN(v.TOTAL_COGS_INR))  AS MIN_COGS_INR,
  ROUND(MAX(v.TOTAL_COGS_INR))  AS MAX_COGS_INR,
  ROUND(AVG(v.SHELF_LIFE_DAYS)) AS AVG_SHELF_LIFE_DAYS
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` d
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_ENRICHED` v ON v.SKU = d.SKU
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT_LINE`   l ON l.PRODUCT_LINE_ID = d.PRODUCT_LINE_ID
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CATEGORY`       c ON c.CATEGORY_ID = d.CATEGORY_ID
WHERE v.IS_ACTIVE
GROUP BY 1, 2, 3;

-- Triage similarity candidates: every pipeline idea plus every active competitor
-- product, unioned into ONE rowset so idea_capture_triage's first step can pull
-- them through a single step-level `fetch:` and see them UN-TRUNCATED. Reading
-- them as two separate context_package keys previews each list down to 4 rows
-- (_compact_facts), which silently hid 12 of 16 competitor products.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_TRIAGE_SIMILARITY_CANDIDATES` AS
SELECT
  'IDEA'                                AS SOURCE,
  i.IDEA_ID                             AS CANDIDATE_ID,
  i.NAME                                AS NAME,
  i.STAGE                               AS STAGE,
  i.HYPOTHESIS                          AS HYPOTHESIS,
  i.THESIS_FIT                          AS THESIS_FIT,
  CAST(i.TARGET_COGS_INR AS STRING)     AS TARGET_COGS_INR,
  CAST(NULL AS STRING)                  AS CITY,
  CAST(NULL AS STRING)                  AS COMPETITOR_ID,
  CAST(NULL AS STRING)                  AS CATEGORY
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_IDEA` i
UNION ALL
SELECT
  'COMPETITOR_PRODUCT'                  AS SOURCE,
  cp.COMPETITOR_PRODUCT_ID              AS CANDIDATE_ID,
  cp.PRODUCT_NAME                       AS NAME,
  CAST(NULL AS STRING)                  AS STAGE,
  CAST(NULL AS STRING)                  AS HYPOTHESIS,
  CAST(NULL AS STRING)                  AS THESIS_FIT,
  CAST(NULL AS STRING)                  AS TARGET_COGS_INR,
  cp.CITY                               AS CITY,
  cp.COMPETITOR_ID                      AS COMPETITOR_ID,
  cm.CATEGORY                           AS CATEGORY
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_COMPETITOR_PRODUCT` cp
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_COMPETITOR` cm
  ON cm.COMPETITOR_ID = cp.COMPETITOR_ID AND cm.IS_ACTIVE
WHERE cp.IS_ACTIVE;

-- Time in stage: DAYS_IN_STAGE computed live in SQL (CURRENT_DATE()), not left
-- for a step's LLM pass to guess — a model has no reliable clock of its own.
-- Requires DIM_IDEA.STAGE_ENTERED_AT (see sql/alter_dim_idea.sql, run first).
-- This is "days in the current STAGE", not "days since first captured" —
-- STAGE_ENTERED_AT resets to CURRENT_TIMESTAMP() each time STAGE changes
-- (conditional CASE in dataset_upsert's MERGE), so the clock restarts on
-- every stage transition.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_IDEA_STAGE_AGE` AS
SELECT
  IDEA_ID,
  NAME,
  STAGE,
  STAGE_ENTERED_AT,
  DATE_DIFF(CURRENT_DATE(), DATE(STAGE_ENTERED_AT), DAY) AS DAYS_IN_STAGE
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_IDEA`;

-- ---------------------------------------------------------------------
-- Innovation pipeline prioritisation (processes/innovation_pipeline_prioritisation.yaml)
-- ---------------------------------------------------------------------

-- Scoring inputs, one row per ACTIVE brief. Every number a machine can know is
-- computed here so the process's LLM pass only reads and explains it — same
-- division of labour as V_STORE_CAMPAIGN_CURRENT's ROI/ROAS/CTR.
--
-- "Active" = STAGE NOT IN ('Rejected','Launch'). The IS NULL arm is deliberate:
-- `NULL NOT IN (...)` is NULL, so without it an idea with no STAGE would vanish
-- from the ranking silently rather than be ranked as the un-staged brief it is.
--
-- STAGE_RANK mirrors the IdeaStage vocabulary order in master_data/vocabularies.yaml.
-- It is duplicated here because SQL cannot read that file; if a stage is added
-- there, add it here too (an unmapped stage yields NULL, not a wrong number).
--
-- COGS_FIT is banded in SQL, not by the model, and TARGET_COGS_INR is nullable —
-- hence an explicit 'UNKNOWN' arm so a missing target can never read as 'INSIDE'.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_IDEA_PRIORITY_INPUTS` AS
WITH envelope AS (
  -- The cost envelope this company actually manufactures inside, collapsed to one
  -- row and cross-joined so every brief carries it.
  SELECT
    ROUND(MIN(MIN_COGS_INR)) AS PORTFOLIO_MIN_COGS_INR,
    ROUND(MAX(MAX_COGS_INR)) AS PORTFOLIO_MAX_COGS_INR
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_LINE_CAPABILITY`
)
SELECT
  i.IDEA_ID,
  i.NAME,
  i.STAGE,
  i.HYPOTHESIS,
  i.THESIS_FIT,
  i.TARGET_COGS_INR,
  a.DAYS_IN_STAGE,
  CASE i.STAGE
    WHEN 'Capture'     THEN 1
    WHEN 'Triage'      THEN 2
    WHEN 'Feasibility' THEN 3
    WHEN 'Pipeline'    THEN 4
    WHEN 'Development' THEN 5
  END                                     AS STAGE_RANK,
  e.PORTFOLIO_MIN_COGS_INR,
  e.PORTFOLIO_MAX_COGS_INR,
  CASE
    WHEN i.TARGET_COGS_INR IS NULL                                                  THEN 'UNKNOWN'
    WHEN CAST(i.TARGET_COGS_INR AS FLOAT64) < e.PORTFOLIO_MIN_COGS_INR              THEN 'BELOW'
    WHEN CAST(i.TARGET_COGS_INR AS FLOAT64) > e.PORTFOLIO_MAX_COGS_INR              THEN 'ABOVE'
    ELSE 'INSIDE'
  END                                     AS COGS_FIT
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_IDEA` i
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.V_IDEA_STAGE_AGE` a
  ON a.IDEA_ID = i.IDEA_ID
CROSS JOIN envelope e
WHERE i.STAGE IS NULL OR i.STAGE NOT IN ('Rejected', 'Launch');

-- Market signal per category, from REALISED DEMAND — not competitor counts.
-- DIM_COMPETITOR_PRODUCT holds 16 hand-curated Pune rows across 6 categories
-- (sql/create_new_tables.sql), which is fine as the "is anyone else here" card
-- idea_capture_triage shows for ONE idea, but far too coarse to order ~38 ideas
-- against each other. So the primary signal is our own sales in the category the
-- idea targets, and the competitor count rides along as a labelled tiebreaker.
--
-- ORDER_STATE <> 'Cancelled' is the repo's established completed-orders filter
-- (see the Sales widgets in technical_assets/catalog/link_datasets.yaml); TOTAL
-- is the revenue column those widgets use (NET also exists).
--
-- GROWTH_PCT uses SAFE_DIVIDE, so a category with no prior-window sales yields
-- NULL rather than 0 — "we have no baseline" must not read as "flat".
--
-- CAVEAT on the competitor columns: DIM_COMPETITOR.CATEGORY is a free-text
-- competitor-brand category and is NOT guaranteed to use the same vocabulary as
-- DIM_CATEGORY.CATEGORY_NAME (idea_capture_triage never joins them — it has the
-- model match the names). The LEFT JOIN below normalises case/whitespace and
-- leaves the counts NULL when the two vocabularies don't line up. NULL here means
-- "not comparable", not "no competitors" — the process instruction says so, and
-- it is a tiebreaker only, so a NULL cannot move a brief up or down on its own.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_CATEGORY_MARKET_SIGNAL` AS
WITH sku_category AS (
  SELECT p.SKU, c.CATEGORY_NAME
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` p
  JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CATEGORY` c
    ON c.CATEGORY_ID = p.CATEGORY_ID
),
sales AS (
  SELECT
    sc.CATEGORY_NAME,
    SUM(IF(b.ORDER_DATE >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY), b.QUANTITY, NULL)) AS UNITS_90D,
    SUM(IF(b.ORDER_DATE >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY), b.TOTAL,    NULL)) AS NET_REVENUE_90D,
    SUM(IF(b.ORDER_DATE <  DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY), b.QUANTITY, NULL)) AS UNITS_PRIOR_90D
  FROM `gen-lang-client-0520145261.silver.BUSINESS_ANALYTICS` b
  JOIN sku_category sc ON sc.SKU = b.SKU_ID
  WHERE b.ORDER_STATE <> 'Cancelled'
    AND b.ORDER_DATE >= DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
  GROUP BY 1
),
forecast AS (
  -- FORWARD-LOOKING ONLY, and that FORECAST_DATE filter is load-bearing:
  -- IS_LATEST_FORECAST = TRUE does NOT isolate a single forecast run. Measured, it
  -- spans 312 distinct FORECAST_DATEs across 16 stores, so `IS_LATEST_FORECAST AND
  -- DAYS_AHEAD BETWEEN 1 AND 3` on its own summed 312 days of historical 1-3 day
  -- predictions into one number — 18,413 units, against 10,490 units of ACTUAL
  -- sales in the last 90 days. A "3-day forecast" bigger than a quarter of real
  -- demand is not a signal, it is an artifact, and it sat one field away from
  -- UNITS_90D where a reader would naturally compare the two.
  -- Scoped to today onward, this is genuinely "units predicted for the next 1-3
  -- days"; if the forecast table holds no forward rows it resolves to NULL, which
  -- the candidates view renders as `none` and the scoring step ignores.
  SELECT
    sc.CATEGORY_NAME,
    ROUND(SUM(f.PREDICTED_SALES_QUANTITY), 1) AS FORECAST_UNITS_NEXT
  FROM `gen-lang-client-0520145261.gold.FORECAST_RESULTS_UPDATE` f
  JOIN sku_category sc ON sc.SKU = f.SKU_ID
  WHERE f.IS_LATEST_FORECAST = TRUE
    AND f.DAYS_AHEAD BETWEEN 1 AND 3
    AND f.FORECAST_DATE >= CURRENT_DATE()
  GROUP BY 1
),
active_skus AS (
  SELECT sc.CATEGORY_NAME, COUNT(*) AS ACTIVE_SKUS_IN_CATEGORY
  FROM sku_category sc
  JOIN `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_ENRICHED` v ON v.SKU = sc.SKU
  WHERE v.IS_ACTIVE
  GROUP BY 1
),
competitors AS (
  SELECT
    UPPER(TRIM(cm.CATEGORY))                 AS CATEGORY_KEY,
    COUNT(*)                                 AS ACTIVE_COMPETITOR_PRODUCTS,
    COUNT(DISTINCT cm.COMPETITOR_ID)         AS DISTINCT_COMPETITORS
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_COMPETITOR_PRODUCT` cp
  JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_COMPETITOR` cm
    ON cm.COMPETITOR_ID = cp.COMPETITOR_ID AND cm.IS_ACTIVE
  WHERE cp.IS_ACTIVE
  GROUP BY 1
)
SELECT
  c.CATEGORY_NAME,
  s.UNITS_90D,
  s.NET_REVENUE_90D,
  s.UNITS_PRIOR_90D,
  ROUND(SAFE_DIVIDE(s.UNITS_90D - s.UNITS_PRIOR_90D, s.UNITS_PRIOR_90D) * 100, 1) AS GROWTH_PCT,
  f.FORECAST_UNITS_NEXT,
  k.ACTIVE_SKUS_IN_CATEGORY,
  x.ACTIVE_COMPETITOR_PRODUCTS,
  x.DISTINCT_COMPETITORS
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CATEGORY` c
LEFT JOIN sales       s ON s.CATEGORY_NAME = c.CATEGORY_NAME
LEFT JOIN forecast    f ON f.CATEGORY_NAME = c.CATEGORY_NAME
LEFT JOIN active_skus k ON k.CATEGORY_NAME = c.CATEGORY_NAME
LEFT JOIN competitors x ON x.CATEGORY_KEY  = UPPER(TRIM(c.CATEGORY_NAME));

-- Channel fit per category: how many channels this category already sells on.
--
-- MAP_PRODUCT_CHANNEL.APPLICABLE IS NOT A BOOLEAN, despite the name. Measured
-- values across 794 rows: 'Suitable For' (490), NULL (229), 'Combo/Large Pack' (64),
-- 'Small Pack' (11) — it describes WHICH PACK FORMAT suits the channel, not whether
-- the SKU is listed. An earlier truthy predicate (IN ('TRUE','Y','1',…)) therefore
-- matched nothing and reported CHANNELS_LISTED = 0 for every category. "Listed" =
-- a mapping row exists with a pack format recorded, i.e. APPLICABLE IS NOT NULL.
--
-- HEADS UP — this factor currently has NO discriminating power. Every category with
-- active SKUs maps to 14 or 15 of the 15 channels in DIM_CHANNEL, so channel_fit
-- scores near-identically for every brief and cannot change the ranking. It is kept
-- because use-case row #17 names it, and it will start discriminating once channel
-- mapping becomes SKU-specific rather than blanket. Until then, read it as
-- "confirmed distribution exists", not as a differentiator.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_CATEGORY_CHANNEL_COVERAGE` AS
SELECT
  c.CATEGORY_NAME,
  COUNT(DISTINCT p.SKU)                                                   AS ACTIVE_SKUS,
  COUNT(DISTINCT IF(m.APPLICABLE IS NOT NULL, m.CHANNEL_ID, NULL))        AS CHANNELS_LISTED,
  COUNT(DISTINCT ch.CHANNEL_ID)                                           AS CHANNELS_MAPPED,
  STRING_AGG(DISTINCT ch.CHANNEL_NAME, '|' ORDER BY ch.CHANNEL_NAME)      AS CHANNEL_NAMES
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` p
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_ENRICHED` v ON v.SKU = p.SKU
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CATEGORY` c ON c.CATEGORY_ID = p.CATEGORY_ID
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.MAP_PRODUCT_CHANNEL` m ON m.SKU = p.SKU
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CHANNEL` ch ON ch.CHANNEL_ID = m.CHANNEL_ID
WHERE v.IS_ACTIVE
GROUP BY 1;

-- Compliance readiness per category.
--
-- READ THIS BEFORE TRUSTING THE NUMBER: this is a PROXY for "how well-trodden the
-- compliance path is for this category", NOT the readiness of any individual idea.
-- An idea has no label, no barcode and no allergen declaration yet — there is
-- nothing idea-level to measure. Use-case row #17 marks this factor "Known
-- unknown"; that is exactly what this view is. Making it idea-level needs
-- TARGET_CATEGORY on DIM_IDEA plus per-idea label/allergen data that doesn't exist.
--
-- Presence tests cast to STRING so they hold whatever the underlying column type
-- turns out to be (ORG_LABELLING_COMPLIANCE is declared `string` in
-- ontology/entities.yaml, but the cast costs nothing and cannot error).
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_CATEGORY_COMPLIANCE_READINESS` AS
SELECT
  c.CATEGORY_NAME,
  COUNT(*)                                                                     AS ACTIVE_SKUS,
  COUNTIF(TRIM(CAST(v.ORG_LABELLING_COMPLIANCE AS STRING)) NOT IN ('', 'false')) AS SKUS_WITH_LABEL_COMPLIANCE,
  COUNTIF(TRIM(CAST(v.GS1_BARCODE AS STRING)) <> '')                           AS SKUS_WITH_BARCODE,
  COUNTIF(al.SKU IS NOT NULL)                                                  AS SKUS_WITH_DECLARED_ALLERGENS
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` p
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_ENRICHED` v ON v.SKU = p.SKU
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CATEGORY` c ON c.CATEGORY_ID = p.CATEGORY_ID
LEFT JOIN (
  SELECT DISTINCT SKU FROM `gen-lang-client-0520145261.ctx_upside_master_data.MAP_PRODUCT_ALLERGEN`
) al ON al.SKU = p.SKU
WHERE v.IS_ACTIVE
GROUP BY 1;

-- The single un-truncated feed for innovation_pipeline_prioritisation's scoring
-- step. Four grains unioned behind a SRC discriminator, mirroring how
-- V_TRIAGE_SIMILARITY_CANDIDATES gets two grains through one step-level `fetch`.
--
-- WHY THIS SHAPE — the two engine limits it is built around:
--  1. `_compact_facts` (event_agent.py) previews ANY list fact longer than 4 rows
--     down to 4. Only a step's OWN `fetch` lands un-previewed, in STEP INPUT DATA.
--     So every one of the ~38 briefs and all of its reference data must arrive
--     through ONE fetch, or the scoring step sees 4 briefs and invents the rest.
--  2. STEP INPUT DATA is hard-capped at 9000 chars. That cap is why:
--     - there are only FOUR columns. Every column is serialised as a JSON key on
--       every row, so a wide table spends its budget on `"UNITS_90D":null` padding
--       for the 38 rows that aren't category rows. Per-grain fields are packed
--       into the DATA string instead.
--     - the 153-row ingredient master is ONE row with the names in a single cell.
--       As 153 rows of a 4-column table it cost ~23k of mostly-null padding; as one
--       packed cell it costs ~2k.
--     - BRIEF's DATA is POSITIONAL (`stage|days|cogs|fit`), not labelled. The four
--       `stg=`/`days=`/`cogs=`/`fit=` labels cost ~22 chars on every brief row —
--       ~0.8k at 38 briefs, which is the difference between fitting and not. The
--       legend lives in the process step's instruction; keep the two in sync.
--     - HYPOTHESIS is NOT here (it is in V_IDEA_PRIORITY_INPUTS for the reviewer
--       card). It is long free text; carrying it for 38 briefs blows the budget,
--       so ingredient derivation works from NAME.
--   Measured, serialised the way event_agent dumps it (38 briefs @32-char names,
--   153 ingredients @11 chars): BRIEF ~4.2k + CATEGORY ~1.6k + ENVELOPE ~0.1k +
--   INGREDIENT ~2.0k = ~8.4k, ~600 chars of headroom. Re-check with:
--     SELECT LENGTH(TO_JSON_STRING(ARRAY_AGG(t))) FROM V_PIPELINE_PRIORITY_CANDIDATES t
--   The labelled form measured 9.2k — i.e. it did NOT fit. If briefs or ingredient
--   names grow enough to push this back over 9000, cut the ingredient cap below
--   before touching the brief rows.
--
-- GRACEFUL DEGRADATION, two mechanisms, because an overflow here fails SILENTLY:
--  1. The SRC values sort BRIEF < CATEGORY < ENVELOPE < INGREDIENT and the step
--     fetches with `order_by: SRC, order_dir: asc`. The cap truncates the TAIL, so
--     an overflow costs ingredient scoring first and the briefs last. Keep that
--     ordering if you add a grain.
--  2. The ingredient cell states its own item count AT THE HEAD (`count=153;`).
--     A cut anywhere in the tail therefore still leaves the model able to see that
--     it holds fewer names than the count claims. The process instruction tells it
--     to score unmatched ingredients as UNKNOWN, not as net-new, whenever the two
--     disagree — so a truncated master can never turn into a false "needs net-new
--     sourcing" claim. This is why the count is at the head and not appended: a
--     trailing marker is itself in the tail, and gets cut with everything else.
--
-- DATA layout, decoded in the process step's instruction — keep the two in sync:
--   BRIEF      POSITIONAL, pipe-delimited: stage|days_in_stage|target_cogs|cogs_fit
--   CATEGORY   labelled (only 6 rows, and this is the scoring evidence a reviewer
--              audits): units90 / prior90 / growth_pct / fcast / skus / chan /
--              chan_names / label_ok / barcode / allergen / comp_products / comp_brands
--   ENVELOPE   cogs_min / cogs_max
--   INGREDIENT count=<n>; names: <comma-separated, lowercased>
--
-- NOTE the empty-portfolio edge case: `unknown` appears in BRIEF's DATA wherever
-- DIM_IDEA has no stage date or no target COGS. The instruction scores those
-- factors at the neutral midpoint rather than 0 — a missing number must not read
-- as a bad number.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_PIPELINE_PRIORITY_CANDIDATES` AS
-- BRIEF rows: positional DATA. Order is stage|days|cogs|fit and must not be
-- reordered without updating the legend in the process step's instruction.
SELECT
  'BRIEF'    AS SRC,
  b.IDEA_ID  AS ID,
  b.NAME     AS NAME,
  CONCAT(
    IFNULL(b.STAGE, 'unknown'),                            '|',
    IFNULL(CAST(b.DAYS_IN_STAGE AS STRING), 'unknown'),     '|',
    IFNULL(CAST(b.TARGET_COGS_INR AS STRING), 'unknown'),   '|',
    b.COGS_FIT
  )          AS DATA
FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_IDEA_PRIORITY_INPUTS` b

UNION ALL
SELECT
  'CATEGORY',
  CAST(NULL AS STRING),
  m.CATEGORY_NAME,
  CONCAT(
    'units90=',        IFNULL(CAST(m.UNITS_90D AS STRING), 'none'),
    '; prior90=',      IFNULL(CAST(m.UNITS_PRIOR_90D AS STRING), 'none'),
    '; growth_pct=',   IFNULL(CAST(m.GROWTH_PCT AS STRING), 'no_baseline'),
    '; fcast=',        IFNULL(CAST(m.FORECAST_UNITS_NEXT AS STRING), 'none'),
    '; skus=',         IFNULL(CAST(m.ACTIVE_SKUS_IN_CATEGORY AS STRING), '0'),
    -- chan is `listed/mapped` so the model reads a ratio it can score directly,
    -- instead of inferring the denominator by eyeballing the other CATEGORY rows.
    '; chan=',         IFNULL(CAST(v.CHANNELS_LISTED AS STRING), '0'),
    '/',               IFNULL(CAST(v.CHANNELS_MAPPED AS STRING), '0'),
    '; chan_names=',   IFNULL(v.CHANNEL_NAMES, 'none'),
    '; label_ok=',     IFNULL(CAST(r.SKUS_WITH_LABEL_COMPLIANCE AS STRING), '0'),
    '/',               IFNULL(CAST(r.ACTIVE_SKUS AS STRING), '0'),
    '; barcode=',      IFNULL(CAST(r.SKUS_WITH_BARCODE AS STRING), '0'),
    '; allergen=',     IFNULL(CAST(r.SKUS_WITH_DECLARED_ALLERGENS AS STRING), '0'),
    -- 'not_comparable' (not '0') when the competitor-category vocabulary doesn't
    -- line up with DIM_CATEGORY — see the CAVEAT on V_CATEGORY_MARKET_SIGNAL.
    '; comp_products=', IFNULL(CAST(m.ACTIVE_COMPETITOR_PRODUCTS AS STRING), 'not_comparable'),
    '; comp_brands=',   IFNULL(CAST(m.DISTINCT_COMPETITORS AS STRING), 'not_comparable')
  )
FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_CATEGORY_MARKET_SIGNAL` m
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.V_CATEGORY_CHANNEL_COVERAGE` v
  ON v.CATEGORY_NAME = m.CATEGORY_NAME
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.V_CATEGORY_COMPLIANCE_READINESS` r
  ON r.CATEGORY_NAME = m.CATEGORY_NAME

UNION ALL
-- One row: the manufacturing cost envelope, which is identical for every brief.
-- Carried once instead of on all 38 BRIEF rows (~1.5k of duplication saved).
SELECT
  'ENVELOPE',
  CAST(NULL AS STRING),
  'portfolio cost envelope',
  CONCAT(
    'cogs_min=', IFNULL(CAST(MIN(MIN_COGS_INR) AS STRING), 'unknown'),
    '; cogs_max=', IFNULL(CAST(MAX(MAX_COGS_INR) AS STRING), 'unknown')
  )
FROM `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_LINE_CAPABILITY`

UNION ALL
-- One row: the whole ingredient master packed into a single cell. Presence means
-- "we already buy this"; absence means net-new sourcing. Carries NO stock
-- quantities — see the DIM_INGREDIENT note in link_datasets.yaml.
--
-- COMPLETENESS IS SELF-DECLARED, in two markers, because THE MODEL CANNOT COUNT.
-- This cell is last in SRC order and so the first thing the 9000-char STEP INPUT
-- DATA cap eats into, and SUBSTR below can also cut it — the reader has to be able
-- to tell. `count=<n>` alone did NOT work: asking a model to count 153 comma-
-- separated items is asking for the one thing it is worst at, and it is genuinely
-- ambiguous here because the names THEMSELVES contain commas ("a non-caloric
-- sweetener blend (erythritol, stevia, allulose)" reads as three items). Observed
-- result: every run hedged to "master appears partial" on a master that was fully
-- delivered, pinning ingredient_availability — a weight-4 factor, 20% of the score —
-- at the neutral 2.5 on every brief, which then escalated the whole ranking.
-- So the two truncation modes are each flagged deterministically instead:
--   `list=complete|partial` — SQL knows whether ITS OWN SUBSTR cut the names.
--   `; end_of_list` terminator — present only if the tail survived, so its ABSENCE
--     is how the reader detects the engine's 9000-char cap eating the end. SQL
--     cannot see that cap, hence a sentinel rather than another computed flag.
-- The instruction reads these two markers and never counts. Keep both, and keep the
-- terminator last — a marker in the middle would survive the very cut it must catch.
--
-- SUBSTR is 4000, not 2000: measured, the 153 names pack to 3,995 chars (avg name
-- 24 chars, max 127 — they are descriptive phrases like "a non-caloric sweetener
-- blend (erythritol, stevia, allulose)", not tidy single words). At 2000 only ~76
-- of 153 survived, which silently halved a weight-4 factor's evidence.
--
-- KNOWN LIMIT: 4000 fits comfortably today only because DIM_IDEA holds a handful of
-- active briefs. Once the real ~35-40-brief pipeline is loaded, brief rows will need
-- ~5k and this cell will start truncating again — the count guard will correctly
-- turn ingredient_availability neutral rather than produce a wrong answer, but the
-- factor goes quiet. The durable fix is cleaning DIM_INGREDIENT itself: the master
-- carries near-duplicate descriptive variants (three separate erythritol/stevia/
-- allulose blend spellings), and normalising those would cut the packed size enough
-- to fit alongside a full pipeline.
SELECT
  'INGREDIENT',
  CAST(NULL AS STRING),
  'ingredient master (already sourced)',
  CONCAT('count=', CAST(i.n AS STRING),
         '; list=', IF(LENGTH(i.names) > 4000, 'partial', 'complete'),
         '; names: ', IFNULL(SUBSTR(i.names, 1, 4000), 'none'),
         '; end_of_list')
FROM (
  SELECT
    COUNT(DISTINCT LOWER(TRIM(INGREDIENT_NAME)))                                                  AS n,
    STRING_AGG(DISTINCT LOWER(TRIM(INGREDIENT_NAME)), ', ' ORDER BY LOWER(TRIM(INGREDIENT_NAME))) AS names
  FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_INGREDIENT`
) i;

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

-- Store's currently-running campaigns this month. RAW_MARKETING_DATA is ad
-- data at the daily x campaign grain with no store id — RES_ID is a
-- platform-specific ad/restaurant id, resolved to MASTER_STORE_ID via
-- STORE_CHANNEL_MAPPING, matching RES_ID against ZOMATO_ID/SWIGGY_ID it came
-- from (INT64 -> STRING). Only Zomato/Swiggy are joined/resolved today;
-- extend the join and PLATFORM case below when Urban Piper/Petpooja ad data
-- is available. Keeps only campaigns live today (CURRENT_DATE
-- between START/END) and sums this calendar month's daily rows to one row
-- per campaign. Dynamic on CURRENT_DATE(), so it re-scopes to "this month /
-- running now" on every render — this is a fast-moving lazy link, not
-- materialised on apply.
-- matched_platform/RES_ID kept for traceability (which platform id resolved this row);
-- ROI recomputed from the summed totals (SAFE_DIVIDE) rather than averaging
-- RAW_MARKETING_DATA's daily per-row ratios, since this view is already collapsing
-- daily rows to one this-month-to-date row per store x campaign. ADS_M2O_PCT/
-- OVERALL_M2O_PCT are carried via ANY_VALUE of the daily ratio (not re-derived
-- from summed totals — no underlying menu-visit/order counts to sum here). DATE
-- here is MAX(r.DATE) — the most recent daily row rolled into this total, not a
-- per-day value.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_STORE_CAMPAIGN_CURRENT` AS
SELECT
  m.MASTER_STORE_ID,
  r.CAMPAIGN_ID,
  ANY_VALUE(r.RES_ID) AS RES_ID,
  ANY_VALUE(
    CASE
      WHEN r.RES_ID = CAST(m.ZOMATO_ID AS STRING) THEN 'ZOMATO'
      WHEN r.RES_ID = CAST(m.SWIGGY_ID AS STRING) THEN 'SWIGGY'
      ELSE 'UNKNOWN'
    END
  ) AS PLATFORM,
  ANY_VALUE(r.PRODUCT_TYPE) AS PRODUCT_TYPE,
  ANY_VALUE(r.TARGETING) AS TARGETING,
  ANY_VALUE(r.SEGMENTS) AS SEGMENTS,
  MAX(r.DATE) AS DATE,
  MIN(r.START_DATE) AS START_DATE,
  MAX(r.END_DATE) AS END_DATE,
  ROUND(SUM(r.AD_SPEND_RS), 0) AS AD_SPEND_RS,
  ROUND(SUM(r.AD_SALES_RS), 0) AS AD_SALES_RS,
  SUM(r.AD_ORDERS) AS AD_ORDERS,
  SUM(r.AD_IMPRESSIONS) AS AD_IMPRESSIONS,
  SUM(r.AD_CLICKS) AS AD_CLICKS,
  SAFE_DIVIDE(SUM(r.AD_SALES_RS), SUM(r.AD_SPEND_RS)) AS ROI,
  ANY_VALUE(CAST(r.ADS_M2O_PCT AS FLOAT64)) AS ADS_M2O_PCT,
  ANY_VALUE(CAST(r.OVERALL_M2O_PCT AS FLOAT64)) AS OVERALL_M2O_PCT,
  -- ROAS/CTR computed here (not by the campaign_planning_optimisation agent step)
  -- because the process YAML's compute DSL has no arithmetic op (see days_until/
  -- bucket only) — same reason ROI above is SAFE_DIVIDE here rather than in the
  -- process. Keeping the agent step's job to "read this number" instead of
  -- "compute this number" removes a place it was reaching for a tool call instead.
  -- Distinct from ROI: ROAS is net return on spend (sales minus spend, relative
  -- to spend), where ROI above is gross sales-to-spend ratio.
  SAFE_DIVIDE(SUM(r.AD_SALES_RS) - SUM(r.AD_SPEND_RS), SUM(r.AD_SPEND_RS)) AS ROAS,
  SAFE_DIVIDE(SUM(r.AD_CLICKS), SUM(r.AD_IMPRESSIONS)) AS CTR
FROM `gen-lang-client-0520145261.bronze.RAW_MARKETING_DATA` r
JOIN `gen-lang-client-0520145261.bronze.STORE_CHANNEL_MAPPING` m
  ON r.RES_ID IN (
      CAST(m.ZOMATO_ID AS STRING),
      CAST(m.SWIGGY_ID AS STRING)
  )
WHERE r.DATE >= DATE_TRUNC(CURRENT_DATE(), MONTH)
  AND CURRENT_DATE() BETWEEN r.START_DATE AND r.END_DATE
GROUP BY
  m.MASTER_STORE_ID,
  r.CAMPAIGN_ID;

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