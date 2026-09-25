# SupplyChainOS

**Governed Supply Chain Intelligence powered by Snowflake**

## Problem Statement

Data is scattered, business meaning is ambiguous. Three teams ask the same question, get different answers.

- Planning asks "What is our fill rate?" and gets 43.7%.
- Procurement asks "How well are orders fulfilled?" and gets 122%.
- Logistics asks "What's the fulfillment rate?" and gets 65%.

Same metric. Three answers. The root cause: no governed semantic layer, no canonical definitions, and ad-hoc joins that silently fan out.

## Solution

One governed semantic layer. Multiple personas. One business truth.

SupplyChainOS is a full-stack supply chain analytics platform that demonstrates how a **Snowflake Semantic View** + **Cortex Agent** eliminates metric inconsistency. A single semantic model defines four canonical KPIs, and a conversational agent resolves natural-language questions from any persona to the same governed SQL.

### Four Canonical Metrics

| Metric | Definition | Gold Value |
|--------|-----------|------------|
| **On-Time Delivery (OTD)** | `COUNT_IF(arrival <= requested) / COUNT(*)` from shipments | 69.81% |
| **Fill Rate** | `SUM(shipped_qty) / SUM(ordered_qty)` from pre-aggregated order fulfillment | 90.91% |
| **Days of Inventory (DOI)** | `SUM(inventory_qty) / SUM(daily_demand)` from inventory | 5.41 days |
| **Total Landed Cost** | `SUM(material + freight + duty + handling)` from shipments | $10,193,841.18 |

## Architecture

```
                     ┌──────────────────────────┐
                     │     Streamlit App         │
                     │   (app.py — 5 tabs)       │
                     └────────┬─────────────────┘
                              │
                     ┌────────▼─────────────────┐
                     │   Cortex Agent            │
                     │   SUPPLYCHAINOS_AGENT     │
                     └────────┬─────────────────┘
                              │
                     ┌────────▼─────────────────┐
                     │   Semantic View           │
                     │   SUPPLY_CHAIN_SV         │
                     │   8 tables · 4 metrics    │
                     │   16 VQRs · 14 SQL rules  │
                     └────────┬─────────────────┘
                              │
          ┌───────────┬───────┴───────┬───────────┐
          ▼           ▼               ▼           ▼
     DIM_SUPPLIER  DIM_PART     FACT_ORDER   FACT_SHIPMENT
     DIM_PLANT     DIM_CUSTOMER FACT_INVENTORY V_ORDER_FULFILLMENT
```

### Data Pipeline

```
Source CSVs → RAW (as-is) → STAGING (typed/cleaned) → CORE (star schema) → SEMANTIC (governed views)
```

| Schema | Purpose |
|--------|---------|
| `RAW` | Landing zone for source CSVs |
| `STAGING` | Cleaned, typed, deduplicated |
| `CORE` | Star schema: 4 dimensions, 3 facts, 1 pre-aggregated view |
| `SEMANTIC` | Semantic view + Cortex Agent |
| `EVAL` | 30 gold-standard test questions |

## Quick Start

### Prerequisites

- Snowflake account with `ACCOUNTADMIN` or equivalent privileges
- Python 3.9+
- Snowflake CLI configured (`~/.snowflake/connections.toml`)
- Cortex Code CLI (`cortex`)

### Setup

**1. Clone and install dependencies**

```bash
git clone <repo-url> && cd SupplyChainOS
pip install -r .cortex/requirements.txt
```

**2. Configure Snowflake connection**

Ensure your `~/.snowflake/connections.toml` has an entry:

```toml
[myconnection]
account = "your-account"
user = "your-user"
authenticator = "externalbrowser"
warehouse = "COMPUTE_WH"
database = "SUPPLYCHAIN_DB"
schema = "CORE"
```

**3. Bootstrap Snowflake objects**

Run the SQL scripts in order against your Snowflake account:

```bash
# 1. Create database and schemas
snowsql -c myconnection -f .cortex/sql/01_setup_database.sql

# 2. Create raw tables and load source CSVs
snowsql -c myconnection -f .cortex/sql/02_create_raw_tables.sql

# 3. Create core star schema
snowsql -c myconnection -f .cortex/sql/03_create_core_tables.sql

# 4. Run ETL procedures
snowsql -c myconnection -f .cortex/sql/04_etl_procedures.sql

# 5. Deploy semantic view
snowsql -c myconnection -f .cortex/sql/05_semantic_views.sql

# 6. Load evaluation gold questions
snowsql -c myconnection -f .cortex/sql/06_evaluation_schema.sql
```

**4. Deploy the Cortex Agent**

```bash
cortex agent-studio agent-deploy \
  --connection myconnection \
  --file-path .cortex/cortex_project/SUPPLYCHAINOS_AGENT.agent.yaml \
  --fqn SUPPLYCHAIN_DB.SEMANTIC.SUPPLYCHAINOS_AGENT
```

**5. Launch the app**

```bash
SNOWFLAKE_DEFAULT_CONNECTION_NAME=myconnection streamlit run .cortex/app.py
```

Open http://localhost:8501.

## Application

The Streamlit app (`app.py`) has five tabs:

| Tab | Description |
|-----|-------------|
| **KPI Dashboard** | Four metric cards (OTD, Fill Rate, DOI, Landed Cost) with Plotly charts, dimension breakdowns, and trend lines |
| **Agent Copilot** | Natural-language Q&A powered by Cortex Agent. Ask any supply chain question and get governed SQL + results |
| **Supply Network** | Interactive Plotly network graph showing supplier-plant-customer flow with edge weights |
| **Data Explorer** | Browse raw data from any CORE table with dynamic filters |
| **Governance** | Semantic view metadata via `DESCRIBE SEMANTIC VIEW` — tables, relationships, metrics, verified queries |

### Connection Priority

The app connects to Snowflake in this order:

1. **Streamlit-in-Snowflake** runtime (SiS — `get_active_session()`)
2. **`SNOWFLAKE_DEFAULT_CONNECTION_NAME`** environment variable (local development)
3. **`st.secrets["snowflake"]`** from `.streamlit/secrets.toml` (optional fallback)

## Evaluation Framework

SupplyChainOS includes a rigorous evaluation suite that measures agent accuracy against gold-standard SQL.

### 30-Question Evaluation (`eval_agent.py`)

Tests the Cortex Agent across six categories:

| Category | Questions | Description |
|----------|-----------|-------------|
| `simple_metric` | 5 | Single KPI, no filters |
| `dimension_breakdown` | 5 | KPI grouped by supplier/plant/part |
| `ranking_filter` | 5 | Top-N, threshold filters |
| `temporal` | 5 | Monthly/weekly trends, date ranges |
| `cross_metric` | 5 | Multi-metric joins (OTD + cost, etc.) |
| `synonym_rephrase` | 5 | Same question, different wording |

**Scoring**: Pass (exact match within 0.1%), Partial (row count or >50% values match), Fail.

```bash
SNOWFLAKE_DEFAULT_CONNECTION_NAME=myconnection python .cortex/eval_agent.py
```

Outputs: `evaluation/evaluation_results.csv`, `evaluation/evaluation_report.txt`, `evaluation/evaluation_failures.txt`

### Persona Consistency Test (`persona_consistency.py`)

Verifies that semantically equivalent questions from different personas resolve to the same numeric result:

| Test Case | Personas | Metric |
|-----------|----------|--------|
| OTD for Apex Components | Planning, Procurement, Logistics | `on_time_delivery` |
| Fill Rate for Pacific Materials | Planning, Procurement, Logistics | `fill_rate` |
| Landed Cost for Red Squares | Procurement, Finance, Logistics | `total_landed_cost` |

```bash
SNOWFLAKE_DEFAULT_CONNECTION_NAME=myconnection python .cortex/persona_consistency.py
```

Outputs: `evaluation/persona_consistency_results.json`

### Current Results

| Metric | Score |
|--------|-------|
| Strict accuracy | 63.3% (19/30) |
| Lenient accuracy | 76.7% (23/30) |
| Persona consistency | 100% (3/3) |
| Category: simple_metric | 100% |
| Category: dimension_breakdown | 100% |
| Category: synonym_rephrase | 100% |
| Category: ranking_filter | 60% |
| Category: temporal | 20% |
| Category: cross_metric | 0% |

## Project Structure

```
SupplyChainOS/                          <- PROJECT ROOT (root of repo)
│
├── .cortex/                            <- Cortex project directory
│   ├── .streamlit/
│   │   └── config.toml                 # Streamlit server + theme config
│   │
│   ├── configs/                        # Environment and app configuration
│   │
│   ├── cortex_project/
│   │   ├── cortex-project.yaml         # Cortex project manifest
│   │   ├── SUPPLYCHAINOS_AGENT.agent.yaml  # Agent specification
│   │   └── SUPPLYCHAINOS_AGENT_EVAL.dataset.yaml  # Eval dataset
│   │
│   ├── data/
│   │   ├── source/                     # Raw source CSVs (5 files)
│   │   ├── synthetic/                  # Generated synthetic data (8 files)
│   │   └── eval/                       # Evaluation question bank
│   │
│   ├── docs/                           # Project documentation
│   │
│   ├── evaluation/                     # Evaluation outputs (auto-generated)
│   │   ├── evaluation_results.csv      # Per-question detail
│   │   ├── evaluation_report.txt       # Human-readable summary
│   │   ├── evaluation_failures.txt     # Prioritized failure analysis
│   │   ├── evaluation_comparison.txt   # Before/after improvement report
│   │   └── persona_consistency_results.json  # Persona test results
│   │
│   ├── logs/                           # Runtime logs
│   │
│   ├── scripts/                        # Utility scripts
│   │
│   ├── semantic/                       # Semantic model artifacts
│   │
│   ├── sql/
│   │   ├── 01_setup_database.sql       # Database, schemas, stage
│   │   ├── 02_create_raw_tables.sql    # RAW table DDL + COPY INTO
│   │   ├── 03_create_core_tables.sql   # Star schema DDL
│   │   ├── 04_etl_procedures.sql       # ETL stored procedures
│   │   ├── 05_semantic_views.sql       # Semantic view DDL (v2)
│   │   ├── 06_evaluation_schema.sql    # Gold questions + test procedure
│   │   └── 06_gold_metrics.sql         # Gold SQL for 4 canonical metrics
│   │
│   ├── .env.example                    # Environment variable template
│   ├── app.py                          # Streamlit application (5 tabs)
│   ├── eval_agent.py                   # 30-question agent evaluation
│   ├── persona_consistency.py          # Persona consistency test
│   ├── pyproject.toml                  # Project metadata
│   ├── README.md                       # This file
│   └── requirements.txt                # Python dependencies
│
├── .git/                               # Git repository
├── .gitignore                          # Git ignore rules
└── [other root-level files]
```

## Semantic View Design

The semantic view (`SUPPLY_CHAIN_SV`) is the core of the governed layer:

- **8 logical tables**: 4 dimensions (`suppliers`, `parts`, `plants`, `customers`) + 3 facts (`orders`, `shipments`, `inventory`) + 1 pre-aggregated view (`order_fulfillment`)
- **15 relationships**: Full FK graph enabling bidirectional navigation
- **4 metrics**: Canonical KPI definitions that cannot be overridden
- **16 verified queries (VQRs)**: Pre-validated SQL patterns for common questions
- **14 AI_SQL_GENERATION rules**: Guardrails preventing fan-out, wrong joins, and incorrect aggregations

### The Fill Rate Fix

The most critical design decision: fill rate uses a **pre-aggregated view** (`V_ORDER_FULFILLMENT`) instead of joining shipments to orders directly. Without this, the 1-to-many relationship between orders (83 rows) and shipments (159 rows) inflates `ordered_quantity`, producing wrong fill rates.

## Snowflake Objects

| Object | Type | Location |
|--------|------|----------|
| `SUPPLYCHAIN_DB` | Database | — |
| `DIM_SUPPLIER` | Table | `CORE` (6 rows) |
| `DIM_PART` | Table | `CORE` (3 rows) |
| `DIM_PLANT` | Table | `CORE` (4 rows) |
| `DIM_CUSTOMER` | Table | `CORE` (8 rows) |
| `FACT_ORDER` | Table | `CORE` (83 rows) |
| `FACT_SHIPMENT` | Table | `CORE` (159 rows) |
| `FACT_INVENTORY` | Table | `CORE` (360 rows) |
| `V_ORDER_FULFILLMENT` | View | `CORE` (83 rows) |
| `SUPPLY_CHAIN_SV` | Semantic View | `SEMANTIC` |
| `SUPPLYCHAINOS_AGENT` | Cortex Agent | `SEMANTIC` |
| `GOLD_QUESTIONS` | Table | `EVAL` (30 rows) |

## Usage Examples

### Python: Connect via Snowpark Session (environment variables)

```python
from snowflake.snowpark import Session
import os

connection_params = {
    "account": os.getenv("SNOWFLAKE_ACCOUNT"),
    "user": os.getenv("SNOWFLAKE_USER"),
    "password": os.getenv("SNOWFLAKE_PASSWORD"),
    "warehouse": os.getenv("SNOWFLAKE_WAREHOUSE"),
    "database": os.getenv("SNOWFLAKE_DATABASE")
}

session = Session.builder.configs(connection_params).create()
```

### Python: Connect via Streamlit secrets

```python
import streamlit as st
from snowflake.snowpark import Session

sf_config = st.secrets["snowflake"]
session = Session.builder.configs(sf_config).create()
```

### Python: Call the Cortex Agent via REST API

```python
import os
import requests

response = requests.post(
    os.getenv("CORTEX_AGENT_URL") + "/query",
    headers={"Authorization": f"Bearer {os.getenv('CORTEX_API_KEY')}"},
    json={"question": user_question}
)
```

### SQL: Query the Semantic View directly

```sql
SELECT *
FROM SEMANTIC_VIEW(
    SUPPLYCHAIN_DB.SEMANTIC.SUPPLY_CHAIN_SV
    DIMENSIONS plants.plant_name
    METRICS shipments.on_time_delivery
);
```

### SQL: Grant access to the Semantic View

```sql
GRANT SELECT ON SEMANTIC VIEW SUPPLYCHAIN_DB.SEMANTIC.SUPPLY_CHAIN_SV TO ROLE app_role;
```

## Tech Stack

- **Snowflake**: Warehouse, Semantic Views, Cortex Agent, Cortex Analyst
- **Streamlit**: Interactive dashboard (local or Streamlit-in-Snowflake)
- **Snowpark**: Python DataFrame API for Snowflake connectivity
- **Plotly**: Interactive charts and network visualization
- **Cortex Code (CoCo)**: Agent deployment and evaluation tooling

## License

MIT
