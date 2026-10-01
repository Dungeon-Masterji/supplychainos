# OntoCoCo presents SupplyChainOS

**Governed Supply Chain Intelligence powered by Snowflake**

**Team:** OntoCoCo  
**Team Size:** 1  
**Project:** SupplyChainOS  
**Hackathon:** Snowflake CoCo CLI Hackathon — GCC Edition  
**Challenge:** Supply Chain Ontology and Governed Conversational Analytics

[Demo Video](https://drive.google.com/file/d/1czje0GhAhHDRYsUBAkgYxXCTisMFwpiN/view?usp=sharing) · [Architecture](#architecture) · [Evaluation](#evaluation-framework) · [Quick Start](#quick-start)

---

# Executive Summary

SupplyChainOS is a full-stack supply chain analytics platform that demonstrates how a **Snowflake Semantic View + Cortex Agent** can establish a shared business truth across supply-chain personas.

The system models supply-chain entities and relationships, defines four canonical KPIs, encodes those definitions into a governed semantic layer, and exposes the model through conversational analytics.

A natural-language question from Planning, Procurement, or Logistics is resolved against the same governed semantic model rather than independently interpreting raw columns and joins.

### Current evaluation

- **Strict accuracy:** 90.0% (27/30)
- **Lenient accuracy:** 100.0% (30/30)
- **Persona consistency:** 100% (3/3)
- **Simple metrics:** 100%
- **Dimension breakdown:** 100%
- **Synonym/rephrase:** 100%
- **Ranking/filter:** 80%
- **Temporal:** 80%
- **Cross-metric:** 80%

---

## 1. Problem Statement

Data is scattered, business meaning is ambiguous. Three teams ask the same question, get different answers.

- Planning asks "What is our fill rate?" and gets 43.7%.
- Procurement asks "How well are orders fulfilled?" and gets 122%.
- Logistics asks "What's the fulfillment rate?" and gets 65%.

Same metric. Three answers. 
The root cause:

- no governed semantic layer
- no canonical definitions
- ad-hoc joins
- incorrect aggregation across relationships
- semantic ambiguity
- metric definitions reconstructed independently by different users

The challenge is therefore not simply to place conversational AI over supply-chain data.

The challenge is to establish a **shared business model and governed semantic layer first**, then allow natural-language analytics to operate against that model.

---

## 2. Solution

## One governed semantic layer. Multiple personas. One business truth.

SupplyChainOS establishes a governed semantic layer between users and the underlying supply-chain data.

```text
Natural Language Question
          │
          ▼
┌─────────────────────────┐
│      Cortex Agent       │
│ SUPPLYCHAINOS_AGENT     │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│   SUPPLY_CHAIN_SV       │
│                         │
│ Ontology                │
│ Relationships           │
│ Canonical Metrics       │
│ VQRs                    │
│ AI SQL Rules            │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│    Snowflake CORE       │
│                         │
│ Orders                  │
│ Shipments               │
│ Inventory               │
│ Suppliers               │
│ Parts                   │
│ Plants                  │
│ Customers               │
└────────────┬────────────┘
             │
             ▼
       Governed Result
```
The system defines the supply-chain entities and relationships once, establishes canonical KPI definitions, and gives the conversational agent a governed semantic model to reason over.

### Core principle

> **Ontology first → Governance second → Agent third.**

---

## 3. Challenge Alignment

| Challenge requirement | SupplyChainOS implementation |
|---|---|
| Define supply-chain ontology | Supplier, Part, Plant, Customer, Order, Shipment, Inventory and Order Fulfillment |
| Define relationships and entity model | 15 governed relationships in `SUPPLY_CHAIN_SV` |
| Define canonical metrics | OTD, Fill Rate, DOI and Total Landed Cost |
| Encode ontology as Semantic Views | `SUPPLY_CHAIN_SV` in `SUPPLYCHAIN_DB.SEMANTIC` |
| Business meaning drives answers | Semantic entities, relationships, metrics, VQRs and SQL-generation rules |
| Governed conversational analytics | `SUPPLYCHAINOS_AGENT` powered by Cortex Agent |
| Cross-domain questions | Dimension, ranking, temporal, cross-metric and synonym/rephrase evaluation |
| Same metric across personas | Planning, Procurement and Logistics consistency testing |
| Demonstrate trustworthy answers | Gold-standard evaluation, VQRs, SQL guardrails and fanout prevention |

---

<a id="architecture"></a>

## 4. Architecture

### 4.1 High-Level Design

```text
┌─────────────────────────────────────────────────────────────┐
│                         USERS                               │
│       Planning · Procurement · Logistics · Operations       │
└────────────────────────────┬────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                     STREAMLIT APP                           │
│ KPI Dashboard · Agent Copilot · Network · Explorer · Gov.  │
└────────────────────────────┬────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                    CORTEX AGENT                             │
│                  SUPPLYCHAINOS_AGENT                        │
└────────────────────────────┬────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                  SUPPLY_CHAIN_SV                            │
│                                                             │
│  8 logical tables · 15 relationships · 4 metrics            │
│  23 VQRs · 15 AI_SQL_GENERATION rules                       │
└────────────────────────────┬────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                    CORE DATA MODEL                          │
│  Suppliers · Parts · Plants · Customers                     │
│  Orders · Shipments · Inventory · Fulfillment               │
└────────────────────────────┬────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                   RAW / STAGING DATA                        │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Data Pipeline

```text
Source CSVs
    │
    ▼
RAW
(as-is landing)
    │
    ▼
STAGING
(typed / cleaned / deduplicated)
    │
    ▼
CORE
(star schema + fulfillment view)
    │
    ▼
SEMANTIC
(governed Semantic View + Cortex Agent)
    │
    ▼
EVAL
(gold questions + validation)
```

| Schema | Purpose |
|---|---|
| `RAW` | Landing zone for source CSVs |
| `STAGING` | Cleaned, typed and deduplicated data |
| `CORE` | Star schema: dimensions, facts and fulfillment view |
| `SEMANTIC` | Governed Semantic View and Cortex Agent |
| `EVAL` | Gold-standard evaluation questions |

---

## 5. Supply Chain Ontology

The domain model represents the major business entities required for governed supply-chain analytics.

```text
                         Supplier
                            │
                            ▼
                           Part
                            │
                            ▼
                          Plant
                       ┌────┴────┐
                       │         │
                       ▼         ▼
                     Order    Inventory
                       │
                       ▼
                  Order Fulfillment
                       │
                       ▼
                    Shipment
                       │
                       ▼
                    Customer
```

### Core entities

| Entity | Role |
|---|---|
| Supplier | Source of supplied parts/material |
| Part | Item being supplied, ordered or moved |
| Plant | Operational facility |
| Customer | Demand destination |
| Order | Customer demand / ordered quantity |
| Shipment | Physical movement and delivery event |
| Inventory | Inventory snapshot and demand coverage |
| Order Fulfillment | Pre-aggregated order-level fulfillment relationship |

The semantic model contains:

- **4 dimensions:** Supplier, Part, Plant, Customer
- **3 facts:** Order, Shipment, Inventory
- **1 pre-aggregated logical view:** Order Fulfillment

---

## 6. Semantic Model

`SUPPLY_CHAIN_SV` is the core governed layer.

### Model composition

| Component | Count |
|---|---:|
| Logical tables | 8 |
| Relationships | 15 |
| Canonical metrics | 4 |
| Verified Query Recipes (VQRs) | 23 |
| `AI_SQL_GENERATION` rules | 15 |

The Semantic View defines how business concepts relate rather than leaving the agent to infer relationships directly from raw column names.

### Governance layers

```text
Business Entity Model
        ↓
Relationships
        ↓
Dimensions / Facts
        ↓
Canonical Metrics
        ↓
Verified Query Recipes
        ↓
AI SQL Generation Rules
        ↓
Cortex Agent
```

---

## 7. Canonical Metrics

The project defines four canonical supply-chain KPIs.

| Metric | Canonical definition | Gold value |
|---|---|---:|
| **On-Time Delivery (OTD)** | `COUNT_IF(arrival <= requested) / COUNT(*)` | **69.81%** |
| **Fill Rate** | `SUM(shipped_qty) / SUM(ordered_qty)` using pre-aggregated fulfillment | **90.91%** |
| **Days of Inventory (DOI)** | `SUM(inventory_qty) / SUM(daily_demand)` | **5.41 days** |
| **Total Landed Cost** | `SUM(material + freight + duty + handling)` | **$10,193,841.18** |

These definitions are encoded in the semantic layer rather than being recreated independently for every user question.

---

## 8. Critical Technical Design: Preventing Fill-Rate Fanout

One of the most important implementation decisions is the treatment of order fulfillment.

A direct order-to-shipment join creates a one-to-many relationship:

```text
Orders
83 rows
   │
   │ 1 → many
   ▼
Shipments
159 rows
```

If order quantities are aggregated after that join, `ordered_quantity` can be duplicated and the Fill Rate becomes incorrect.

SupplyChainOS therefore creates:

```text
Orders + Shipments
       │
       ▼
V_ORDER_FULFILLMENT
       │
       ▼
One row per order
       │
       ▼
Canonical Fill Rate
```

This pre-aggregated view is exposed to the semantic layer as the `order_fulfillment` logical table.

This is a core example of why the semantic layer is part of the solution rather than simply an interface layer.

---

## 9. Low-Level Design

### 9.1 Data Layer

```text
RAW
 │
 ├── source data
 │
 ▼
STAGING
 │
 ├── typing
 ├── cleaning
 └── deduplication
 │
 ▼
CORE
 │
 ├── DIM_SUPPLIER
 ├── DIM_PART
 ├── DIM_PLANT
 ├── DIM_CUSTOMER
 ├── FACT_ORDER
 ├── FACT_SHIPMENT
 ├── FACT_INVENTORY
 └── V_ORDER_FULFILLMENT
 │
 ▼
SEMANTIC
 └── SUPPLY_CHAIN_SV
```

### 9.2 Agent Layer

```text
User question
     │
     ▼
Cortex Agent
     │
     ▼
Intent + semantic concept resolution
     │
     ▼
Semantic View
     │
     ├── Canonical metric
     ├── Relationship path
     ├── VQR
     └── AI SQL rule
     │
     ▼
Generated SQL
     │
     ▼
Snowflake execution
     │
     ▼
Result
     │
     ▼
Natural-language answer
```

### 9.3 Application Layer

The Streamlit application exposes five functional surfaces:

| Tab | Purpose |
|---|---|
| **KPI Dashboard** | Four canonical KPI cards, charts, breakdowns and trends |
| **Agent Copilot** | Natural-language supply-chain questions with governed SQL and results |
| **Supply Network** | Supplier → plant → customer network visualization |
| **Data Explorer** | Interactive exploration of CORE tables |
| **Governance** | Semantic View metadata, relationships, metrics and verified queries |

---

## 10. Governance and Guardrails

The system is designed so that conversational analytics operates against governed business meaning.

### Canonical definitions

Each KPI has one definition in the Semantic View.

### Verified Query Recipes

VQRs provide pre-validated SQL patterns for common analytical questions, including temporal and cross-metric patterns.

### AI SQL generation rules

The `AI_SQL_GENERATION` rules guide:

- correct metric selection
- correct relationship paths
- aggregation behavior
- fanout prevention
- temporal date-column selection
- cross-metric CTE patterns
- threshold interpretation

### Temporal governance

The agent is explicitly guided on metric-specific date columns:

| Metric | Temporal field |
|---|---|
| OTD | Departure date |
| Fill Rate | Order date |
| DOI | Snapshot date |

### Cross-metric governance

Cross-metric queries use governed CTE patterns rather than arbitrary joins between incompatible grains.

---

## 11. Agentic Workflow

SupplyChainOS is an **analytical agent**, not an operational ERP action agent.

Its agentic behavior is the reasoning workflow between natural language and governed analytical execution:

```text
Natural-language intent
        ↓
Semantic concept selection
        ↓
Metric / relationship resolution
        ↓
Governed SQL generation
        ↓
Snowflake execution
        ↓
Result interpretation
        ↓
Natural-language response
```

The agent is therefore grounded in the ontology and semantic model rather than answering from ungoverned text or raw column names.

---

## 12. CoCo Lifecycle

CoCo was used across the project lifecycle rather than only as a code-generation utility.

| Lifecycle phase | CoCo usage |
|---|---|
| **Planning** | Explored the data, framed the problem, designed the ontology, data model and workflow |
| **Development** | Iterated on SQL, data transformations, semantic views, agent configuration and application code |
| **Execution** | Ran and deployed the Snowflake-backed workflow and application |
| **Testing & validation** | Executed evaluation questions, diagnosed failures, fixed semantic/temporal/cross-metric issues and re-ran validation |
| **Iteration** | Used evaluation failures to drive targeted changes to VQRs, SQL rules and agent instructions |

The project also uses CoCo to work with the synthetic data, semantic model and evaluation workflow.

---

## 13. Synthetic Data

The project extends the available shipment data with a synthetic supply-chain layer so the required business entities can be represented without relying on production data.

The resulting model includes:

```text
Supplier
   ↓
Part
   ↓
Plant
   ↓
Shipment
   ↓
Order
   ↓
Customer

+ Inventory
+ Order Fulfillment
```

The synthetic layer is designed to maintain the relationships required by the ontology and downstream evaluation.

---

## 14. Persona Consistency

The challenge requires the same metric to resolve consistently across personas.

SupplyChainOS explicitly tests this.

Example equivalent intents:

```text
Planning:
"What is our on-time delivery rate?"

Procurement:
"How reliable are our suppliers?"

Logistics:
"What percentage of shipments arrive on time?"
```

The evaluation maps these questions to the same governed metric.

### Result

**Persona consistency: 100% (3/3)**

Tested metrics include:

- OTD
- Fill Rate
- Total Landed Cost

---

<a id="evaluation-framework"></a>

## 15. Evaluation

SupplyChainOS includes a 30-question gold-standard evaluation suite.

### Evaluation categories

| Category | Questions | Purpose |
|---|---:|---|
| `simple_metric` | 5 | Single KPI questions |
| `dimension_breakdown` | 5 | KPI grouped by entity |
| `ranking_filter` | 5 | Top-N and threshold queries |
| `temporal` | 5 | Monthly, weekly and date-based reasoning |
| `cross_metric` | 5 | Multi-metric analytical reasoning |
| `synonym_rephrase` | 5 | Equivalent questions with different wording |

### Scoring

- **Pass:** exact match within 0.1%
- **Partial:** correct row count or more than 50% of values match
- **Fail:** otherwise

---

## 16. Evaluation Results

### Current results

| Metric | Result |
|---|---:|
| **Strict accuracy** | **90.0% (27/30)** |
| **Lenient accuracy** | **100.0% (30/30)** |
| **Persona consistency** | **100% (3/3)** |
| Simple metric | 100% |
| Dimension breakdown | 100% |
| Synonym / rephrase | 100% |
| Ranking / filter | 80% |
| Temporal | 80% |
| Cross-metric | 80% |

### Iterative improvement

```text
Round 1 — Baseline
Strict: 40.0%
        │
        ▼
Round 2 — Semantic governance
Strict: 63.3%
        │
        ▼
Round 3 — Temporal + cross-metric reasoning
Strict: 90.0%
```

### Round 1 → Round 2

The initial evaluation exposed:

- Fill Rate fanout
- missing VQR coverage
- weak synonym resolution
- inconsistent persona results

Targeted fixes included:

- `V_ORDER_FULFILLMENT`
- expanded VQR coverage
- metric synonym mappings
- stronger agent orchestration
- supplier filtering rules

Result:

**40.0% → 63.3% strict accuracy**

and:

**67% → 100% persona consistency**

### Round 2 → Round 3

The remaining major failures were temporal and cross-metric reasoning.

Targeted fixes included:

- temporal VQRs
- metric-specific date guidance
- temporal reference rules
- cross-metric CTE patterns
- threshold definitions
- additional cross-metric VQRs
- evaluation harness correction
- agent instructions for temporal/cross-metric reasoning

Result:

**63.3% → 90.0% strict accuracy**

### Remaining partial results

Q015, Q020 and Q024 return correct data but are marked partial by the current evaluation harness because its metric-name detection check does not find the metric identifier in the agent response text.

The limitation is in the scoring harness rather than the returned analytical values.

---

## 17. Example Agent Questions

The agent is evaluated against questions such as:

```text
What is our overall on-time delivery rate?

What is the fill rate by customer segment?

What are the days of inventory by plant for the latest snapshot?

Which suppliers have low OTD and high landed cost?

What was OTD last month?

Which plants have poor inventory coverage while relying on
poor-performing suppliers?
```

The application exposes both the natural-language interaction and the governed analytical result.

---

## 18. Application

### KPI Dashboard

Four canonical KPI cards with:

- OTD
- Fill Rate
- DOI
- Total Landed Cost
- dimension breakdowns
- trend charts

### Agent Copilot

Natural-language questions are routed through the Cortex Agent and semantic layer.

### Supply Network

Interactive network visualization showing supplier, plant and customer relationships.

### Data Explorer

Interactive access to CORE tables for inspection and analysis.

### Governance

Displays Semantic View metadata, including tables, relationships, metrics and verified queries.

---

## 19. Snowflake Objects

| Object | Type | Location |
|---|---|---|
| `SUPPLYCHAIN_DB` | Database | — |
| `DIM_SUPPLIER` | Table | `CORE` |
| `DIM_PART` | Table | `CORE` |
| `DIM_PLANT` | Table | `CORE` |
| `DIM_CUSTOMER` | Table | `CORE` |
| `FACT_ORDER` | Table | `CORE` |
| `FACT_SHIPMENT` | Table | `CORE` |
| `FACT_INVENTORY` | Table | `CORE` |
| `V_ORDER_FULFILLMENT` | View | `CORE` |
| `SUPPLY_CHAIN_SV` | Semantic View | `SEMANTIC` |
| `SUPPLYCHAINOS_AGENT` | Cortex Agent | `SEMANTIC` |
| `GOLD_QUESTIONS` | Table | `EVAL` |

---

## 20. Project Structure

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

---

<a id="quick-start"></a>

## 21. Quick Start

### Prerequisites

- Snowflake account with required privileges
- Python 3.9+
- Snowflake CLI / connection configuration
- Cortex Code (`cortex`) CLI

### 1. Clone and install

```bash
git clone <repo-url>
cd SupplyChainOS

pip install -r .cortex/requirements.txt
```

### 2. Configure Snowflake

Create a connection in `~/.snowflake/connections.toml`:

```toml
[myconnection]
account = "your-account"
user = "your-user"
authenticator = "externalbrowser"
warehouse = "COMPUTE_WH"
database = "SUPPLYCHAIN_DB"
schema = "CORE"
```

### 3. Bootstrap Snowflake objects

Run the SQL scripts in order:

```bash
snowsql -c myconnection -f .cortex/sql/01_setup_database.sql
snowsql -c myconnection -f .cortex/sql/02_create_raw_tables.sql
snowsql -c myconnection -f .cortex/sql/03_create_core_tables.sql
snowsql -c myconnection -f .cortex/sql/04_etl_procedures.sql
snowsql -c myconnection -f .cortex/sql/05_semantic_views.sql
snowsql -c myconnection -f .cortex/sql/06_evaluation_schema.sql
```

### 4. Deploy the Cortex Agent

```bash
cortex agent-studio agent-deploy \
  --connection myconnection \
  --file-path .cortex/cortex_project/SUPPLYCHAINOS_AGENT.agent.yaml \
  --fqn SUPPLYCHAIN_DB.SEMANTIC.SUPPLYCHAINOS_AGENT
```

### 5. Launch the Streamlit application

```bash
SNOWFLAKE_DEFAULT_CONNECTION_NAME=myconnection \
streamlit run .cortex/app.py
```

Open:

```text
http://localhost:8501
```

---

## 22. Evaluation Commands

### Agent evaluation

```bash
SNOWFLAKE_DEFAULT_CONNECTION_NAME=myconnection \
python .cortex/eval_agent.py
```

Outputs:

```text
evaluation/evaluation_results.csv
evaluation/evaluation_report.txt
evaluation/evaluation_failures.txt
```

### Persona consistency

```bash
SNOWFLAKE_DEFAULT_CONNECTION_NAME=myconnection \
python .cortex/persona_consistency.py
```

Output:

```text
evaluation/persona_consistency_results.json
```

---

## 23. Usage Examples

### Query the Semantic View

```sql
SELECT *
FROM SEMANTIC_VIEW(
    SUPPLYCHAIN_DB.SEMANTIC.SUPPLY_CHAIN_SV
    DIMENSIONS plants.plant_name
    METRICS shipments.on_time_delivery
);
```

### Grant access

```sql
GRANT SELECT
ON SEMANTIC VIEW SUPPLYCHAIN_DB.SEMANTIC.SUPPLY_CHAIN_SV
TO ROLE app_role;
```

### Snowpark connection

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

---

## 24. Deployment

SupplyChainOS is designed around Snowflake as the governed data and intelligence platform.

```text
                    Snowflake
┌─────────────────────────────────────────────┐
│                                             │
│ RAW → STAGING → CORE → SEMANTIC             │
│                         │                   │
│                         ▼                   │
│                  Cortex Agent               │
│                                             │
└─────────────────────────┬───────────────────┘
                          │
                          ▼
                    Streamlit App
```

The application supports:

1. Streamlit-in-Snowflake runtime
2. Local Streamlit development using `SNOWFLAKE_DEFAULT_CONNECTION_NAME`
3. Optional Streamlit secrets configuration

---

## 25. Limitations

Current scope focuses on **governed analytical conversational workflows**.

The current prototype does not claim to provide:

- autonomous ERP transactions
- operational work-order execution
- broad external-system MCP integrations
- multi-agent operational orchestration
- production-scale real-time supply-chain streaming

These are potential future extensions rather than implemented capabilities.

---

## 26. Future Scope

Potential extensions include:

- MCP integrations with enterprise operational systems
- real-time and incremental supply-chain pipelines
- scheduled monitoring and alerts
- operational agent actions
- additional supply-chain personas
- larger evaluation datasets
- broader ontology coverage
- multi-agent workflows
- confidence and human-review workflows

---

## 27. Why SupplyChainOS

SupplyChainOS is not simply a chatbot over supply-chain tables.

Its architecture places the **business ontology and governance layer between the user and the data**:

```text
Traditional approach:

User → LLM → Raw Data


SupplyChainOS:

User
 ↓
Cortex Agent
 ↓
Governed Ontology
 ↓
Semantic View
 ↓
Canonical Metrics
 ↓
Snowflake
```

The result is a conversational analytics workflow where the agent is grounded in shared business definitions rather than independently reconstructing them for every question.

---

## 28. Technology Stack

| Layer | Technology |
|---|---|
| Data platform | Snowflake |
| Semantic layer | Snowflake Semantic Views |
| Conversational intelligence | Cortex Agent / Cortex Analyst |
| Development | Snowflake CoCo / Cortex Code CLI |
| Application | Streamlit |
| Data access | Snowpark |
| Visualization | Plotly |
| Evaluation | Python + Snowflake gold-standard queries |

---

<a id="demo"></a>

## 29. Demo

**Demo video:** [Watch the demo](<DEMO_VIDEO_URL>)

The demo should show an end-to-end CoCo workflow:

```text
Input
  ↓
Ontology / Semantic Layer
  ↓
Cortex Agent
  ↓
Governed SQL
  ↓
Snowflake Execution
  ↓
Output
```

Recommended demo flow:

1. Show the supply-chain problem.
2. Show the ontology and Semantic View.
3. Ask a natural-language KPI question.
4. Show generated SQL and result.
5. Demonstrate a temporal or cross-metric question.
6. Demonstrate persona consistency.
7. Show governance/evaluation evidence.

---

## 30. Team

### OntoCoCo

**Solo builder:** Aditya Raj

**Project:** SupplyChainOS

**Challenge:** Supply Chain Ontology and Governed Conversational Analytics

---

## License

MIT
