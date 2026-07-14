# product-master-graph

Context graph for the better-for-you snacks & desserts brand, built on the
`contextgraph` engine (same pattern as `../monginis-graph`). All source data is
in one GCP project — **`erp-set-up`** — across 4 datasets:

| Dataset | Role | Feeds |
|---|---|---|
| `ctx_upside_master_data` | PIM — product truth | `integrations/pim_bq.yaml` |
| `bronze` / `silver` / `gold` | live warehouse — daily pulse | `integrations/live_bq.yaml` |

**20 node types · 29 relationships · 5 tiers.** See the explainer artifact for
the visual ontology map and the numbered relationship legend.

## Layout

```
graph.yaml                 project manifest
ontology/                  entities.yaml + relationships.yaml (all 20 nodes / 29 edges)
integrations/pim_bq.yaml   ctx_upside_master_data -> nodes & edges
integrations/live_bq.yaml  bronze/silver/gold -> the live edges
master_data/               vocabularies, hierarchies, kpis
policies/constraints.yaml  business rules (metadata)
processes/                 shelf_life_liquidation, demand_forecast_dispatch (Ops/SC POC)
sql/views.sql              helper BigQuery views (RUN THIS FIRST)
migrations/0001_initial.yaml
```

## What extracts vs. what's curated

- **Extracted now (PIM + live):** Product, Category, ProductLine, Ingredient,
  Allergen, Nutrient, Channel, Claim, Store, InventoryBatch, Review, Complaint,
  CustomerSegment — plus edges #1–7, #17, #20–26.
- **Declared but not extracted (curated tier, like Monginis' `Deal`):**
  Regulation, Certification, Supplier, Idea, Competitor, CompetitorProduct,
  Campaign — and their edges (#8–16, #18–19, #29). Author these in-graph when
  you build the compliance / NPD / competitive demos.
- **Deferred edges** (need a fuzzy/lookup view): `complaint_about_product` (#27)
  — commented in `live_bq.yaml`. (`segment_on_channel` #28 is now live via
  `V_SEGMENT_ON_CHANNEL`.)

## Prerequisites

1. **Postgres 14+ with `pgvector`** reachable via `DATABASE_URL`.
2. **`contextgraph` CLI** with the BigQuery extra: `pip install 'contextgraph[bigquery]'`.
3. A **service account** that can read all four datasets.

## Setup

```bash
cp .env.example .env          # set DATABASE_URL + GCP_PROJECT + GOOGLE_APPLICATION_CREDENTIALS_JSON

# 1. Create the helper views in BigQuery (once):
bq query --use_legacy_sql=false < sql/views.sql

# 2. Validate config, run migrations, ingest the ontology, start the MCP server:
contextgraph dev -C .

# 3. Pull real rows from BigQuery into the graph (PIM first, then live):
contextgraph apply -C . -s pim_bq
contextgraph apply -C . -s live_bq
#    (or `contextgraph apply -C .` for everything)
```

## Drive the Ops / Supply-Chain demo

Once applied, the graph answers use cases **26.0 / 27.0 / 25.0** by traversal:

- **Shelf-life risk (26):** products `stocked_at` a store where `wastage_flag`
  is set / `soonest_expiry` is near.
- **Liquidation & transfer (27):** for a surplus, near-expiry SKU, compare
  `forecast_for` at the store vs stock, then walk `transfer_route` to a nearby
  store forecast to sell it.
- **Forecast & dispatch (25):** `forecast_for` + `stocked_at` per store × SKU.

The **read/decide** side is the graph. The **last mile** — creating the transfer
/ PO / markdown in ERPNext or the channel app — is an **action connector**
(the platform's action layer), not graph data.

## Known caveats (also flagged in the artifact appendix)

- **SKU is the cross-layer key** — `DIM_PRODUCT.SKU` must equal the live
  `SKU_ID` / `product_sku` exactly. Constraint `live_sku_resolves` tracks misses.
- **`PRODUCT_NUTRIENT` is empty** until the nutrition-panel OCR runs — the
  `Nutrient` node and `declares_nutrient` edge extract 0 rows until then.
- **`transfer_route`**: `STORE_TRANSFER_DISTANCES` store ids are the same
  identity as `MASTER_STORE_ID` (confirmed) — `V_TRANSFER_ROUTE` casts INT64 → STRING to match.
- **Never commit `.env`** — it holds live credentials (see `.gitignore`).
