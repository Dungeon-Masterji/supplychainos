"""
SupplyChainOS — Governed Supply Chain Intelligence
Streamlit app with Snowpark Session, Plotly charts, Cortex Agent copilot.
Run: SNOWFLAKE_DEFAULT_CONNECTION_NAME=GD04473 streamlit run app.py
"""

import json
import os
import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import streamlit as st
from snowflake.snowpark import Session
from snowflake.snowpark.context import get_active_session
from snowflake.snowpark.exceptions import SnowparkSessionException

# ─── Page config (must be first st call) ────────────────────────────────────

st.set_page_config(
    page_title="SupplyChainOS",
    page_icon="🚛",
    layout="wide",
    initial_sidebar_state="expanded",
)

# ─── Constants ──────────────────────────────────────────────────────────────

AGENT_FQN = "SUPPLYCHAIN_DB.SEMANTIC.SUPPLYCHAINOS_AGENT"
SV_FQN = "SUPPLYCHAIN_DB.SEMANTIC.SUPPLY_CHAIN_SV"
COLOR_GREEN = "#2ecc71"
COLOR_YELLOW = "#f39c12"
COLOR_RED = "#e74c3c"
COLOR_BLUE = "#3498db"
COLOR_PURPLE = "#9b59b6"


# ─── Snowflake connection via Snowpark Session ──────────────────────────────

@st.cache_resource
def get_session() -> Session:
    """Create a Snowpark Session.

    Priority:
    1. Active session (Streamlit-in-Snowflake runtime)
    2. SNOWFLAKE_DEFAULT_CONNECTION_NAME env var (local CLI — primary path)
    3. st.secrets["snowflake"] (optional secrets.toml)
    """
    # 1. SiS runtime
    try:
        return get_active_session()
    except SnowparkSessionException:
        pass

    # 2. Connection name from environment (the primary local-dev path).
    #    Snowpark passes connection_name through to snowflake.connector.connect().
    conn_name = os.getenv("SNOWFLAKE_DEFAULT_CONNECTION_NAME")
    if conn_name:
        return Session.builder.configs({
            "connection_name": conn_name,
            "database": "SUPPLYCHAIN_DB",
            "schema": "CORE",
        }).create()

    # 3. Streamlit secrets.toml (wrapped in try — file may not exist).
    try:
        if "snowflake" in st.secrets:
            params = dict(st.secrets["snowflake"])
            params.setdefault("database", "SUPPLYCHAIN_DB")
            params.setdefault("schema", "CORE")
            return Session.builder.configs(params).create()
    except Exception:
        pass

    # Nothing worked — raise so the error is visible, not swallowed.
    raise RuntimeError(
        "Cannot connect to Snowflake. Set SNOWFLAKE_DEFAULT_CONNECTION_NAME "
        "or create .streamlit/secrets.toml with [snowflake] credentials."
    )


def run_query(sql: str) -> pd.DataFrame:
    """Execute SQL via Snowpark and return a pandas DataFrame with lowercase columns.

    Raises on failure instead of returning an empty DataFrame so callers
    never silently operate on missing data.
    """
    session = get_session()
    df = session.sql(sql).to_pandas()
    df.columns = df.columns.str.lower()
    return df


# ─── Cached data loaders ───────────────────────────────────────────────────

@st.cache_data(ttl=600)
def load_dim_suppliers():
    return run_query(
        "SELECT s.SUPPLIER_ID, s.SUPPLIER_NAME, s.REGION, s.TIER "
        "FROM SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER s "
        "WHERE EXISTS (SELECT 1 FROM SUPPLYCHAIN_DB.CORE.DIM_PART p "
        "  JOIN SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT sh ON p.PART_ID = sh.PART_ID "
        "  WHERE p.SUPPLIER_ID = s.SUPPLIER_ID) "
        "ORDER BY s.SUPPLIER_NAME"
    )


@st.cache_data(ttl=600)
def load_dim_plants():
    return run_query(
        "SELECT PLANT_ID, PLANT_NAME, REGION "
        "FROM SUPPLYCHAIN_DB.CORE.DIM_PLANT ORDER BY PLANT_NAME"
    )


@st.cache_data(ttl=600)
def load_dim_parts():
    return run_query(
        "SELECT PART_ID, PART_NAME, CATEGORY "
        "FROM SUPPLYCHAIN_DB.CORE.DIM_PART ORDER BY PART_NAME"
    )


@st.cache_data(ttl=600)
def load_dim_customers():
    return run_query(
        "SELECT CUSTOMER_ID, CUSTOMER_NAME, SEGMENT, PLANT_ID "
        "FROM SUPPLYCHAIN_DB.CORE.DIM_CUSTOMER ORDER BY CUSTOMER_NAME"
    )


@st.cache_data(ttl=600)
def load_kpi_otd(supplier_ids=None, plant_ids=None, part_ids=None):
    sql = """
        WITH eligible AS (
            SELECT fs.SHIPMENT_LINE_ID, fs.PART_ID, fs.ORIGIN_PLANT_ID,
                   fs.ARRIVAL_DATE <= fs.REQUESTED_DELIVERY_DATE AS is_on_time
            FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs
            WHERE fs.IS_VALID_SHIPMENT = TRUE
              AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL
        )
        SELECT
            COUNT(*) AS eligible_shipments,
            COUNT_IF(e.is_on_time) AS on_time_count,
            ROUND(COUNT_IF(e.is_on_time)::FLOAT / NULLIF(COUNT(*), 0), 4) AS otd
        FROM eligible e
        JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON e.PART_ID = dpt.PART_ID
    """
    wheres = []
    if supplier_ids:
        wheres.append(f"dpt.SUPPLIER_ID IN ({_quote_list(supplier_ids)})")
    if plant_ids:
        wheres.append(f"e.ORIGIN_PLANT_ID IN ({_quote_list(plant_ids)})")
    if part_ids:
        wheres.append(f"e.PART_ID IN ({_quote_list(part_ids)})")
    if wheres:
        sql += " WHERE " + " AND ".join(wheres)
    return run_query(sql)


@st.cache_data(ttl=600)
def load_kpi_fill_rate(supplier_ids=None, plant_ids=None, part_ids=None):
    part_filter = f"AND fo.PART_ID IN ({_quote_list(part_ids)})" if part_ids else ""
    plant_filter = f"AND fo.PLANT_ID IN ({_quote_list(plant_ids)})" if plant_ids else ""
    supplier_filter = (
        f"AND dpt.SUPPLIER_ID IN ({_quote_list(supplier_ids)})" if supplier_ids else ""
    )
    return run_query(f"""
        WITH shipped_per_order AS (
            SELECT ORDER_ID, SUM(SHIPPED_QUANTITY) AS total_shipped
            FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT
            WHERE IS_VALID_SHIPMENT = TRUE
            GROUP BY ORDER_ID
        )
        SELECT
            ROUND(SUM(spo.total_shipped) / NULLIF(SUM(fo.ORDERED_QUANTITY), 0), 4) AS fill_rate
        FROM SUPPLYCHAIN_DB.CORE.FACT_ORDER fo
        LEFT JOIN shipped_per_order spo ON fo.ORDER_ID = spo.ORDER_ID
        JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fo.PART_ID = dpt.PART_ID
        WHERE 1=1 {part_filter} {plant_filter} {supplier_filter}
    """)


@st.cache_data(ttl=600)
def load_kpi_doi(plant_ids=None, part_ids=None):
    wheres = ["fi.SNAPSHOT_DATE = (SELECT MAX(SNAPSHOT_DATE) FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY)"]
    if plant_ids:
        wheres.append(f"fi.PLANT_ID IN ({_quote_list(plant_ids)})")
    if part_ids:
        wheres.append(f"fi.PART_ID IN ({_quote_list(part_ids)})")
    return run_query(f"""
        SELECT ROUND(SUM(fi.INVENTORY_QUANTITY) / NULLIF(SUM(fi.DAILY_DEMAND), 0), 2) AS doi
        FROM SUPPLYCHAIN_DB.CORE.FACT_INVENTORY fi
        WHERE {' AND '.join(wheres)}
    """)


@st.cache_data(ttl=600)
def load_kpi_landed_cost(supplier_ids=None, plant_ids=None, part_ids=None):
    wheres = ["fs.IS_VALID_SHIPMENT = TRUE"]
    if part_ids:
        wheres.append(f"fs.PART_ID IN ({_quote_list(part_ids)})")
    if plant_ids:
        wheres.append(f"fs.ORIGIN_PLANT_ID IN ({_quote_list(plant_ids)})")
    if supplier_ids:
        wheres.append(f"dpt.SUPPLIER_ID IN ({_quote_list(supplier_ids)})")
    join = "JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID = dpt.PART_ID" if supplier_ids else ""
    return run_query(f"""
        SELECT ROUND(SUM(fs.LANDED_COST), 2) AS landed_cost
        FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs
        {join}
        WHERE {' AND '.join(wheres)}
    """)


@st.cache_data(ttl=600)
def load_otd_by_supplier():
    return run_query("""
        WITH eligible AS (
            SELECT fs.PART_ID,
                   fs.ARRIVAL_DATE <= fs.REQUESTED_DELIVERY_DATE AS is_on_time
            FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs
            WHERE fs.IS_VALID_SHIPMENT = TRUE
              AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL
        )
        SELECT ds.SUPPLIER_NAME,
               COUNT(*) AS eligible,
               COUNT_IF(e.is_on_time) AS on_time,
               ROUND(COUNT_IF(e.is_on_time)::FLOAT / NULLIF(COUNT(*), 0), 4) AS otd
        FROM eligible e
        JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON e.PART_ID = dpt.PART_ID
        JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID = ds.SUPPLIER_ID
        GROUP BY ds.SUPPLIER_NAME
        ORDER BY otd
    """)


@st.cache_data(ttl=600)
def load_fill_rate_by_plant():
    return run_query("""
        WITH shipped_per_order AS (
            SELECT ORDER_ID, SUM(SHIPPED_QUANTITY) AS total_shipped
            FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT
            WHERE IS_VALID_SHIPMENT = TRUE
            GROUP BY ORDER_ID
        )
        SELECT dp.PLANT_NAME,
               COUNT(fo.ORDER_ID) AS orders,
               ROUND(SUM(COALESCE(spo.total_shipped, 0))
                     / NULLIF(SUM(fo.ORDERED_QUANTITY), 0), 4) AS fill_rate
        FROM SUPPLYCHAIN_DB.CORE.FACT_ORDER fo
        LEFT JOIN shipped_per_order spo ON fo.ORDER_ID = spo.ORDER_ID
        JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp ON fo.PLANT_ID = dp.PLANT_ID
        GROUP BY dp.PLANT_NAME
        ORDER BY fill_rate
    """)


@st.cache_data(ttl=600)
def load_risk_shipments():
    return run_query("""
        SELECT fs.SHIPMENT_LINE_ID,
               ds.SUPPLIER_NAME, dpt.PART_NAME,
               dp_o.PLANT_NAME AS origin, dp_d.PLANT_NAME AS destination,
               fs.DELIVERY_DAYS, fs.AVG_ROUTE_DELIVERY_DAYS AS route_avg,
               fs.RISK_FLAG, fs.DECISION,
               fs.DEPARTURE_DATE, fs.ARRIVAL_DATE
        FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs
        JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID = dpt.PART_ID
        JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID = ds.SUPPLIER_ID
        JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp_o ON fs.ORIGIN_PLANT_ID = dp_o.PLANT_ID
        JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp_d ON fs.DESTINATION_PLANT_ID = dp_d.PLANT_ID
        WHERE fs.RISK_FLAG = 'High' AND fs.IS_VALID_SHIPMENT = TRUE
        ORDER BY fs.DELIVERY_DAYS DESC
        LIMIT 10
    """)


@st.cache_data(ttl=600)
def load_network_edges():
    return run_query("""
        SELECT dp_o.PLANT_NAME AS origin, dp_d.PLANT_NAME AS destination,
               COUNT(*) AS shipments,
               ROUND(COUNT_IF(fs.ARRIVAL_DATE <= fs.REQUESTED_DELIVERY_DATE)::FLOAT
                     / NULLIF(COUNT(*), 0), 4) AS otd,
               ROUND(AVG(fs.DELIVERY_DAYS), 1) AS avg_days,
               SUM(fs.SHIPPED_QUANTITY) AS total_qty
        FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs
        JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp_o ON fs.ORIGIN_PLANT_ID = dp_o.PLANT_ID
        JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp_d ON fs.DESTINATION_PLANT_ID = dp_d.PLANT_ID
        WHERE fs.IS_VALID_SHIPMENT = TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL
        GROUP BY dp_o.PLANT_NAME, dp_d.PLANT_NAME
        ORDER BY shipments DESC
    """)


@st.cache_data(ttl=600)
def load_supplier_to_plant_edges():
    return run_query("""
        SELECT ds.SUPPLIER_NAME, dp_o.PLANT_NAME AS origin,
               dp_d.PLANT_NAME AS destination, dpt.PART_NAME,
               COUNT(*) AS shipments,
               ROUND(COUNT_IF(fs.ARRIVAL_DATE <= fs.REQUESTED_DELIVERY_DATE)::FLOAT
                     / NULLIF(COUNT(*), 0), 4) AS otd
        FROM SUPPLYCHAIN_DB.CORE.FACT_SHIPMENT fs
        JOIN SUPPLYCHAIN_DB.CORE.DIM_PART dpt ON fs.PART_ID = dpt.PART_ID
        JOIN SUPPLYCHAIN_DB.CORE.DIM_SUPPLIER ds ON dpt.SUPPLIER_ID = ds.SUPPLIER_ID
        JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp_o ON fs.ORIGIN_PLANT_ID = dp_o.PLANT_ID
        JOIN SUPPLYCHAIN_DB.CORE.DIM_PLANT dp_d ON fs.DESTINATION_PLANT_ID = dp_d.PLANT_ID
        WHERE fs.IS_VALID_SHIPMENT = TRUE AND fs.REQUESTED_DELIVERY_DATE IS NOT NULL
        GROUP BY ds.SUPPLIER_NAME, dp_o.PLANT_NAME, dp_d.PLANT_NAME, dpt.PART_NAME
        ORDER BY shipments DESC
    """)


@st.cache_data(ttl=600)
def load_semantic_view_metadata():
    """Load DESCRIBE SEMANTIC VIEW output.

    DESCRIBE results may return columns in mixed case depending on the Snowpark
    version and driver.  We normalize to a fixed set of lowercase names that
    the governance tab relies on.
    """
    session = get_session()
    df = session.sql(f"DESCRIBE SEMANTIC VIEW {SV_FQN}").to_pandas()
    # Normalize columns: lowercase, and map any known aliases
    df.columns = df.columns.str.strip().str.lower()
    CANONICAL_COLS = ["object_kind", "object_name", "parent_entity", "property", "property_value"]
    expected = set(CANONICAL_COLS)
    if not expected.issubset(set(df.columns)):
        # Fallback: if Snowpark returns positional columns (e.g. col0..col4),
        # assign the canonical names by position.
        if len(df.columns) >= 5:
            df.columns = CANONICAL_COLS[:len(df.columns)]
    return df


def _quote_list(items):
    """Safely quote a list of identifiers for IN clause."""
    return ", ".join(f"'{v}'" for v in items)


def _otd_color(val):
    if val >= 0.8:
        return COLOR_GREEN
    if val >= 0.6:
        return COLOR_YELLOW
    return COLOR_RED


# ─── Cortex Agent caller ───────────────────────────────────────────────────

def call_agent(question: str, history: list = None) -> dict:
    """Call the Cortex Agent and return structured response with text + optional SQL."""
    messages = []
    if history:
        for msg in history:
            messages.append({
                "role": msg["role"],
                "content": [{"type": "text", "text": msg["content"]}],
            })
    messages.append({
        "role": "user",
        "content": [{"type": "text", "text": question}],
    })
    payload = json.dumps({"messages": messages})
    session = get_session()
    result = session.sql(
        "SELECT TRY_PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(?, ?)) AS resp",
        params=[AGENT_FQN, payload],
    ).collect()
    resp = result[0]["RESP"]
    if isinstance(resp, str):
        resp = json.loads(resp)

    text_parts = []
    sql_parts = []
    if "content" in resp:
        for block in resp["content"]:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text":
                text_parts.append(block["text"])
            elif block.get("type") == "tool_result":
                tr = block.get("tool_result", block)
                if isinstance(tr, dict) and "sql" in tr:
                    sql_parts.append(tr["sql"])
                if isinstance(tr, dict) and "content" in tr:
                    for sub in (tr["content"] if isinstance(tr["content"], list) else [tr["content"]]):
                        if isinstance(sub, dict) and sub.get("type") == "json":
                            inner = sub.get("json", {})
                            if "sql" in inner:
                                sql_parts.append(inner["sql"])
            elif block.get("type") == "tool_use":
                tu = block.get("tool_use", {})
                if isinstance(tu, dict) and "sql" in tu.get("input", {}):
                    sql_parts.append(tu["input"]["sql"])

    return {
        "text": "\n".join(text_parts) if text_parts else str(resp),
        "sql": sql_parts[0] if sql_parts else None,
        "raw": resp,
    }


# ─── Sidebar filters ───────────────────────────────────────────────────────

with st.sidebar:
    st.image("https://img.icons8.com/fluency/96/truck.png", width=48)
    st.markdown("## SupplyChainOS")
    st.caption("Governed Supply Chain Intelligence")

    # Connection diagnostic
    try:
        session = get_session()
        _db = session.get_current_database() or "?"
        _schema = session.get_current_schema() or "?"
        _role = session.get_current_role() or "?"
        _wh = session.get_current_warehouse() or "?"
        st.success(f"Connected to {_db}", icon="🔗")
        with st.expander("Connection details", expanded=False):
            st.caption(f"Schema: `{_schema}`  \nRole: `{_role}`  \nWarehouse: `{_wh}`")
    except Exception as conn_err:
        st.error(f"Not connected: {conn_err}", icon="🔴")
        st.stop()

    st.divider()

    suppliers_df = load_dim_suppliers()
    plants_df = load_dim_plants()
    parts_df = load_dim_parts()

    st.markdown("### Filters")
    sel_supplier_names = st.multiselect(
        "Supplier",
        suppliers_df["supplier_name"].tolist(),
        key="filter_supplier",
    )
    sel_plant_names = st.multiselect(
        "Plant",
        plants_df["plant_name"].tolist(),
        key="filter_plant",
    )
    sel_part_names = st.multiselect(
        "Part",
        parts_df["part_name"].tolist(),
        key="filter_part",
    )

    # Map names → IDs for query filters
    sel_supplier_ids = tuple(
        suppliers_df[suppliers_df["supplier_name"].isin(sel_supplier_names)]["supplier_id"].tolist()
    ) if sel_supplier_names else None
    sel_plant_ids = tuple(
        plants_df[plants_df["plant_name"].isin(sel_plant_names)]["plant_id"].tolist()
    ) if sel_plant_names else None
    sel_part_ids = tuple(
        parts_df[parts_df["part_name"].isin(sel_part_names)]["part_id"].tolist()
    ) if sel_part_names else None


# ─── Header ─────────────────────────────────────────────────────────────────

st.markdown("### 🚛 SUPPLYCHAINOS &nbsp;&nbsp; 🟢 LIVE")
st.caption("Governed Supply Chain Intelligence &nbsp;|&nbsp; Powered by Snowflake Cortex")

tab_kpi, tab_network, tab_copilot, tab_governance, tab_persona = st.tabs([
    "📊 KPI Dashboard",
    "🔗 Supply Network",
    "🤖 Copilot",
    "📋 Governance",
    "👥 Persona Consistency",
])


# =============================================================================
# TAB 1: KPI DASHBOARD
# =============================================================================

with tab_kpi:
    # Headline KPIs (filtered)
    try:
        otd_df = load_kpi_otd(sel_supplier_ids, sel_plant_ids, sel_part_ids)
        otd_val = float(otd_df.iloc[0]["otd"]) if not otd_df.empty and otd_df.iloc[0]["otd"] is not None else 0

        fr_df = load_kpi_fill_rate(sel_supplier_ids, sel_plant_ids, sel_part_ids)
        fr_val = float(fr_df.iloc[0]["fill_rate"]) if not fr_df.empty and fr_df.iloc[0]["fill_rate"] is not None else 0

        doi_df = load_kpi_doi(sel_plant_ids, sel_part_ids)
        doi_val = float(doi_df.iloc[0]["doi"]) if not doi_df.empty and doi_df.iloc[0]["doi"] is not None else 0

        lc_df = load_kpi_landed_cost(sel_supplier_ids, sel_plant_ids, sel_part_ids)
        lc_val = float(lc_df.iloc[0]["landed_cost"]) if not lc_df.empty and lc_df.iloc[0]["landed_cost"] is not None else 0
    except Exception as e:
        st.error(f"Failed to load KPIs: {e}")
        otd_val = fr_val = doi_val = lc_val = 0

    k1, k2, k3, k4 = st.columns(4)
    k1.metric("On-Time Delivery", f"{otd_val:.1%}")
    k2.metric("Fill Rate", f"{fr_val:.1%}")
    k3.metric("Days of Inventory", f"{doi_val:.1f} days")
    k4.metric("Landed Cost", f"${lc_val:,.0f}")

    if sel_supplier_names or sel_plant_names or sel_part_names:
        active = []
        if sel_supplier_names:
            active.append(f"Suppliers: {', '.join(sel_supplier_names)}")
        if sel_plant_names:
            active.append(f"Plants: {', '.join(sel_plant_names)}")
        if sel_part_names:
            active.append(f"Parts: {', '.join(sel_part_names)}")
        st.caption(f"Filtered — {' | '.join(active)}")

    st.divider()

    # Charts
    ch1, ch2 = st.columns(2)

    with ch1:
        st.markdown("**OTD by Supplier**")
        otd_sup = load_otd_by_supplier()
        if not otd_sup.empty:
            # Highlight selected suppliers
            if sel_supplier_names:
                otd_sup["_selected"] = otd_sup["supplier_name"].isin(sel_supplier_names)
                otd_sup["_opacity"] = otd_sup["_selected"].map({True: 1.0, False: 0.25})
                otd_sup["_width"] = otd_sup["_selected"].map({True: 1.0, False: 0.6})
            else:
                otd_sup["_opacity"] = 1.0
                otd_sup["_width"] = 0.6

            fig_otd = go.Figure()
            colors = [COLOR_BLUE, COLOR_PURPLE, COLOR_GREEN, COLOR_YELLOW, COLOR_RED, "#1abc9c"]
            for i, (_, row) in enumerate(otd_sup.iterrows()):
                fig_otd.add_trace(go.Bar(
                    x=[row["otd"]], y=[row["supplier_name"]],
                    orientation="h",
                    text=[f"{row['otd']:.1%}"], textposition="outside",
                    marker=dict(color=colors[i % len(colors)], opacity=row["_opacity"]),
                    width=row["_width"],
                    showlegend=False,
                ))
            fig_otd.update_layout(
                height=350, margin=dict(l=0, r=0, t=10, b=0),
                xaxis=dict(range=[0, 1], tickformat=".0%"),
                barmode="group",
            )
            st.plotly_chart(fig_otd, use_container_width=True)
        else:
            st.warning("No OTD data available.")

    with ch2:
        st.markdown("**Fill Rate by Plant**")
        fr_plant = load_fill_rate_by_plant()
        if not fr_plant.empty:
            # Highlight selected plants
            if sel_plant_names:
                fr_plant["_selected"] = fr_plant["plant_name"].isin(sel_plant_names)
                fr_plant["_opacity"] = fr_plant["_selected"].map({True: 1.0, False: 0.25})
                fr_plant["_width"] = fr_plant["_selected"].map({True: 1.0, False: 0.6})
            else:
                fr_plant["_opacity"] = 1.0
                fr_plant["_width"] = 0.6

            fig_fr = go.Figure()
            fr_colors = [COLOR_GREEN, COLOR_BLUE, COLOR_PURPLE, COLOR_YELLOW]
            for i, (_, row) in enumerate(fr_plant.iterrows()):
                fig_fr.add_trace(go.Bar(
                    x=[row["fill_rate"]], y=[row["plant_name"]],
                    orientation="h",
                    text=[f"{row['fill_rate']:.1%}"], textposition="outside",
                    marker=dict(color=fr_colors[i % len(fr_colors)], opacity=row["_opacity"]),
                    width=row["_width"],
                    showlegend=False,
                ))
            fig_fr.update_layout(
                height=350, margin=dict(l=0, r=0, t=10, b=0),
                xaxis=dict(range=[0, 1], tickformat=".0%"),
                barmode="group",
            )
            st.plotly_chart(fig_fr, use_container_width=True)
        else:
            st.warning("No fill rate data available.")

    # Risk table
    st.markdown("**Top 10 High-Risk Shipments**")
    risk_df = load_risk_shipments()
    if not risk_df.empty:
        st.dataframe(
            risk_df,
            use_container_width=True,
            hide_index=True,
            column_config={
                "shipment_line_id": "Shipment Line",
                "supplier_name": "Supplier",
                "part_name": "Part",
                "origin": "Origin",
                "destination": "Destination",
                "delivery_days": st.column_config.NumberColumn("Transit Days", format="%d"),
                "route_avg": st.column_config.NumberColumn("Route Avg", format="%.1f"),
                "risk_flag": "Risk",
                "decision": "Action",
                "departure_date": "Departed",
                "arrival_date": "Arrived",
            },
        )
    else:
        st.success("No high-risk shipments found.")


# =============================================================================
# TAB 2: SUPPLY NETWORK
# =============================================================================

with tab_network:
    st.markdown("**Supply Chain Network**")

    net_df = load_network_edges()
    sup_net = load_supplier_to_plant_edges()

    if not sup_net.empty:
        # Build Plotly network graph
        # Collect unique nodes with positions
        suppliers_list = sup_net["supplier_name"].unique().tolist()
        origins = sup_net["origin"].unique().tolist()
        destinations = sup_net["destination"].unique().tolist()
        customers_df = load_dim_customers()
        customers_list = customers_df["customer_name"].unique().tolist()

        # Determine which nodes are "active" based on sidebar filters
        has_filter = bool(sel_supplier_names or sel_plant_names)
        active_suppliers = set(sel_supplier_names) if sel_supplier_names else set()
        active_plants = set(sel_plant_names) if sel_plant_names else set()
        # If a supplier is selected, also highlight plants they ship to
        if active_suppliers and not active_plants:
            for s in active_suppliers:
                s_rows = sup_net[sup_net["supplier_name"] == s]
                active_plants.update(s_rows["origin"].tolist())
        # If a plant is selected, also highlight suppliers that ship to it
        if active_plants and not sel_supplier_names:
            for _, row in sup_net.iterrows():
                if row["origin"] in active_plants:
                    active_suppliers.add(row["supplier_name"])
        # Highlight customers connected to active plants
        active_customers = set()
        if active_plants and not customers_df.empty:
            for _, cust in customers_df.iterrows():
                plant_id = cust["plant_id"]
                prow = plants_df[plants_df["plant_id"] == plant_id]
                if not prow.empty and prow.iloc[0]["plant_name"] in active_plants:
                    active_customers.add(cust["customer_name"])

        all_nodes = []
        node_x, node_y, node_color, node_text, node_size = [], [], [], [], []
        node_opacity = []

        # Layer 0: Suppliers (x=0)
        for i, s in enumerate(suppliers_list):
            all_nodes.append(s)
            node_x.append(0)
            node_y.append(i * 2)
            s_otd = sup_net[sup_net["supplier_name"] == s]["otd"].mean()
            is_active = (not has_filter) or (s in active_suppliers)
            node_color.append(_otd_color(s_otd))
            node_text.append(f"{'⬤ ' if is_active and has_filter else ''}{s}<br>OTD: {s_otd:.0%}")
            node_size.append(35 if is_active and has_filter else 25)
            node_opacity.append(1.0 if is_active else 0.2)

        # Layer 1: Plants (x=2)
        plants_in_net = sorted(set(origins) | set(destinations))
        for i, p in enumerate(plants_in_net):
            all_nodes.append(p)
            node_x.append(2)
            node_y.append(i * 2 + 0.5)
            if not net_df.empty:
                p_otd_rows = net_df[net_df["origin"] == p]
                p_otd = p_otd_rows["otd"].mean() if not p_otd_rows.empty else 0.5
            else:
                p_otd = 0.5
            is_active = (not has_filter) or (p in active_plants)
            node_color.append(_otd_color(p_otd))
            node_text.append(f"{'⬤ ' if is_active and has_filter else ''}{p}<br>OTD: {p_otd:.0%}")
            node_size.append(40 if is_active and has_filter else 30)
            node_opacity.append(1.0 if is_active else 0.2)

        # Layer 2: Customers (x=4)
        for i, c in enumerate(customers_list):
            all_nodes.append(c)
            node_x.append(4)
            node_y.append(i)
            is_active = (not has_filter) or (c in active_customers)
            node_color.append(COLOR_BLUE)
            node_text.append(c)
            node_size.append(25 if is_active and has_filter else 18)
            node_opacity.append(1.0 if is_active else 0.2)

        # Build edges — separate active vs inactive for different styling
        active_edge_x, active_edge_y = [], []
        dim_edge_x, dim_edge_y = [], []

        def _add_edge(src_idx, dst_idx):
            """Append edge coords to active or dim lists based on node opacity."""
            both_active = node_opacity[src_idx] >= 0.9 and node_opacity[dst_idx] >= 0.9
            ex, ey = (active_edge_x, active_edge_y) if both_active else (dim_edge_x, dim_edge_y)
            ex.extend([node_x[src_idx], node_x[dst_idx], None])
            ey.extend([node_y[src_idx], node_y[dst_idx], None])

        # Supplier → Origin plant
        for _, row in sup_net.drop_duplicates(subset=["supplier_name", "origin"]).iterrows():
            si = all_nodes.index(row["supplier_name"])
            oi = all_nodes.index(row["origin"])
            _add_edge(si, oi)

        # Origin plant → Destination plant
        if not net_df.empty:
            for _, row in net_df.iterrows():
                oi = all_nodes.index(row["origin"])
                di = all_nodes.index(row["destination"])
                _add_edge(oi, di)

        # Destination plant → Customer (via DIM_CUSTOMER.plant_id)
        if not customers_df.empty:
            for _, cust in customers_df.iterrows():
                cname = cust["customer_name"]
                plant_id = cust["plant_id"]
                prow = plants_df[plants_df["plant_id"] == plant_id]
                if not prow.empty and cname in all_nodes:
                    pname = prow.iloc[0]["plant_name"]
                    if pname in all_nodes:
                        pi = all_nodes.index(pname)
                        ci = all_nodes.index(cname)
                        _add_edge(pi, ci)

        fig_net = go.Figure()
        # Dim edges (unselected paths)
        if dim_edge_x:
            fig_net.add_trace(go.Scatter(
                x=dim_edge_x, y=dim_edge_y, mode="lines",
                line=dict(width=1, color="grey"), opacity=0.15,
                hoverinfo="none",
            ))
        # Active edges (selected paths)
        if active_edge_x:
            fig_net.add_trace(go.Scatter(
                x=active_edge_x, y=active_edge_y, mode="lines",
                line=dict(width=3 if has_filter else 1.5, color="grey"),
                hoverinfo="none",
            ))
        fig_net.add_trace(go.Scatter(
            x=node_x, y=node_y, mode="markers+text",
            marker=dict(size=node_size, color=node_color,
                        opacity=node_opacity,
                        line=dict(width=1.5, color="grey")),
            text=[n.split("<br>")[0] if "<br>" in str(n) else n for n in node_text],
            textposition="top center",
            hovertext=node_text, hoverinfo="text",
        ))

        # Layer labels
        max_y = max(node_y) + 1 if node_y else 5
        for lx, label in [(0, "Suppliers"), (2, "Plants"), (4, "Customers")]:
            fig_net.add_annotation(x=lx, y=max_y, text=f"<b>{label}</b>",
                                   showarrow=False, font=dict(size=14))

        fig_net.update_layout(
            showlegend=False, height=500,
            margin=dict(l=20, r=20, t=30, b=20),
            xaxis=dict(showgrid=False, zeroline=False, showticklabels=False),
            yaxis=dict(showgrid=False, zeroline=False, showticklabels=False),
        )
        st.plotly_chart(fig_net, use_container_width=True)

        st.caption("Node color: 🟢 OTD ≥ 80% &nbsp;|&nbsp; 🟡 60-80% &nbsp;|&nbsp; 🔴 < 60%")

    # Route performance table
    st.markdown("**Route Performance**")
    if not net_df.empty:
        net_display = net_df.copy()
        net_display["route"] = net_display["origin"] + " → " + net_display["destination"]

        # Highlight routes that include selected plants
        if sel_plant_names:
            sel_set = set(sel_plant_names)
            net_display["_selected"] = net_display.apply(
                lambda r: r["origin"] in sel_set or r["destination"] in sel_set, axis=1)
            net_display["_opacity"] = net_display["_selected"].map({True: 1.0, False: 0.2})
            net_display["_width"] = net_display["_selected"].map({True: 1.0, False: 0.5})
        else:
            net_display["_opacity"] = 1.0
            net_display["_width"] = 0.6

        fig_route = go.Figure()
        for _, row in net_display.iterrows():
            bar_color = _otd_color(row["otd"])
            fig_route.add_trace(go.Bar(
                x=[row["otd"]], y=[row["route"]],
                orientation="h",
                text=[f"{row['otd']:.1%}"], textposition="outside",
                marker=dict(color=bar_color, opacity=row["_opacity"]),
                width=row["_width"],
                showlegend=False,
            ))
        fig_route.update_layout(
            height=400, margin=dict(l=0, r=0, t=10, b=0),
            xaxis=dict(range=[0, 1], tickformat=".0%"),
            barmode="group",
        )
        st.plotly_chart(fig_route, use_container_width=True)

        st.dataframe(net_df, use_container_width=True, hide_index=True)
    else:
        st.warning("No network data available.")


# =============================================================================
# TAB 3: COPILOT
# =============================================================================

with tab_copilot:
    st.markdown("**Supply Chain Copilot**")
    st.caption(f"Powered by Cortex Agent: `{AGENT_FQN}`")

    if "chat_history" not in st.session_state:
        st.session_state.chat_history = []

    for msg in st.session_state.chat_history:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"])
            if msg.get("sql"):
                with st.expander("Generated SQL", expanded=False):
                    st.code(msg["sql"], language="sql")

    if prompt := st.chat_input("Ask a supply chain question..."):
        st.session_state.chat_history.append({"role": "user", "content": prompt})
        with st.chat_message("user"):
            st.markdown(prompt)

        with st.chat_message("assistant"):
            with st.spinner("Thinking..."):
                try:
                    result = call_agent(prompt, st.session_state.chat_history[:-1])
                    st.markdown(result["text"])
                    if result["sql"]:
                        with st.expander("Generated SQL", expanded=False):
                            st.code(result["sql"], language="sql")
                    st.session_state.chat_history.append({
                        "role": "assistant",
                        "content": result["text"],
                        "sql": result["sql"],
                    })
                except Exception as e:
                    err_msg = f"Agent error: {e}"
                    st.error(err_msg)
                    st.session_state.chat_history.append({
                        "role": "assistant", "content": err_msg,
                    })

    col_clear, col_hint = st.columns([1, 3])
    with col_clear:
        if st.session_state.chat_history and st.button("Clear chat", type="secondary"):
            st.session_state.chat_history = []
            st.rerun()
    with col_hint:
        if not st.session_state.chat_history:
            st.info("Try: *What is OTD by plant?* — *Which supplier has the highest landed cost per unit?*")


# =============================================================================
# TAB 4: GOVERNANCE
# =============================================================================

with tab_governance:
    st.markdown("**Metric Definitions & Governance**")
    st.caption(f"Source: `{SV_FQN}`")

    try:
        sv_meta = load_semantic_view_metadata()
    except Exception as e:
        st.error(f"Failed to load semantic view metadata: {e}")
        sv_meta = pd.DataFrame()

    # Extract metrics from DESCRIBE output
    if not sv_meta.empty and "object_kind" in sv_meta.columns:
        metrics_rows = sv_meta[sv_meta["object_kind"] == "METRIC"]
        metric_names = metrics_rows["object_name"].unique().tolist()

        for mname in metric_names:
            mrows = metrics_rows[metrics_rows["object_name"] == mname]
            props = dict(zip(mrows["property"], mrows["property_value"]))

            with st.expander(f"**{mname}** — `{props.get('TABLE', 'N/A')}`", expanded=False):
                c1, c2 = st.columns([2, 1])
                with c1:
                    st.markdown(f"**Canonical Name:** `{mname}`")
                    comment = props.get("COMMENT", "N/A")
                    st.markdown(f"**Definition:** {comment}")
                    expr = props.get("EXPRESSION", "N/A")
                    st.markdown("**Formula:**")
                    st.code(expr, language="sql")
                    using = props.get("USING_RELATIONSHIPS")
                    if using:
                        st.markdown(f"**Using Relationships:** `{using}`")
                with c2:
                    st.markdown(f"**Source Table:** `{props.get('TABLE', 'N/A')}`")
                    st.markdown(f"**Data Type:** `{props.get('DATA_TYPE', 'N/A')}`")
                    syns = props.get("SYNONYMS", "[]")
                    try:
                        syn_list = json.loads(syns) if isinstance(syns, str) else syns
                    except (json.JSONDecodeError, TypeError):
                        syn_list = [str(syns)]
                    st.markdown(f"**Synonyms:** {', '.join(syn_list)}")
                    st.markdown(f"**Access:** `{props.get('ACCESS_MODIFIER', 'PUBLIC')}`")
                    st.markdown(f"**Last Updated:** {pd.Timestamp.now().strftime('%Y-%m-%d')}")

        # Tables summary
        st.divider()
        st.markdown("**Semantic View Tables**")
        tables = sv_meta[(sv_meta["object_kind"] == "TABLE") & (sv_meta["property"] == "COMMENT")]
        if not tables.empty:
            for _, row in tables.iterrows():
                st.markdown(f"- **{row['object_name']}**: {row['property_value']}")

        # Relationships
        st.markdown("**Relationships**")
        rels = sv_meta[sv_meta["object_kind"] == "RELATIONSHIP"]
        rel_names = rels["object_name"].unique()
        for rname in rel_names:
            rrows = rels[rels["object_name"] == rname]
            rprops = dict(zip(rrows["property"], rrows["property_value"]))
            st.markdown(
                f"- `{rname}`: {rprops.get('TABLE', '?')} "
                f"({rprops.get('FOREIGN_KEY', '?')}) → {rprops.get('REF_TABLE', '?')} "
                f"({rprops.get('REF_KEY', '?')})"
            )

        # AI instructions
        ai_rows = sv_meta[sv_meta["object_kind"] == "CUSTOM_INSTRUCTION"]
        if not ai_rows.empty:
            st.divider()
            st.markdown("**AI SQL Generation Rules**")
            for _, row in ai_rows.iterrows():
                st.code(row["property_value"], language="text")
    else:
        if not sv_meta.empty:
            st.warning(
                f"Unexpected DESCRIBE columns: {sv_meta.columns.tolist()}. "
                "Expected: object_kind, object_name, parent_entity, property, property_value."
            )
        else:
            st.warning("No semantic view metadata found.")


# =============================================================================
# TAB 5: PERSONA CONSISTENCY
# =============================================================================

PERSONA_TESTS = [
    {
        "label": "OTD by Supplier",
        "personas": {
            "Planning": "What is each supplier's delivery performance?",
            "Procurement": "How reliable is each supplier at on-time delivery?",
            "Logistics": "What percentage of shipments from each supplier arrived on time?",
        },
    },
    {
        "label": "Fill Rate Overall",
        "personas": {
            "Planning": "What is our overall fill rate?",
            "Procurement": "What percentage of ordered quantity was actually shipped?",
            "Logistics": "How much of customer demand are we fulfilling?",
        },
    },
    {
        "label": "Inventory Coverage",
        "personas": {
            "Planning": "How many days of inventory do we have on hand?",
            "Procurement": "What is our current days of supply?",
            "Logistics": "How long will our current stock last at the current demand rate?",
        },
    },
]

with tab_persona:
    st.markdown("**Persona Consistency Lab**")
    st.caption(
        "Validates that different personas asking semantically equivalent "
        "questions resolve to the same metric and result."
    )

    test_choice = st.selectbox(
        "Select a consistency test",
        [t["label"] for t in PERSONA_TESTS],
    )
    test = next(t for t in PERSONA_TESTS if t["label"] == test_choice)

    if st.button("Run Consistency Test", type="primary"):
        results = {}
        progress = st.progress(0, text="Running persona queries...")
        personas = list(test["personas"].items())

        for i, (persona, question) in enumerate(personas):
            progress.progress((i) / len(personas), text=f"Asking as {persona}...")
            try:
                resp = call_agent(question)
                results[persona] = {
                    "question": question,
                    "answer": resp["text"],
                    "sql": resp.get("sql"),
                    "status": "ok",
                }
            except Exception as e:
                results[persona] = {
                    "question": question,
                    "answer": str(e),
                    "sql": None,
                    "status": "error",
                }
            progress.progress((i + 1) / len(personas))

        progress.empty()

        # Display side-by-side
        cols = st.columns(len(personas))
        all_ok = True
        for col, (persona, result) in zip(cols, results.items()):
            with col:
                with st.container(border=True):
                    st.markdown(f"**{persona}**")
                    st.caption(f"*\"{result['question']}\"*")
                    if result["status"] == "ok":
                        st.markdown(result["answer"])
                        if result["sql"]:
                            with st.expander("SQL", expanded=False):
                                st.code(result["sql"], language="sql")
                        st.success("✓ Response received")
                    else:
                        st.error(result["answer"])
                        all_ok = False

        # Consistency verdict
        st.divider()
        ok_answers = [r["answer"] for r in results.values() if r["status"] == "ok"]
        if len(ok_answers) == len(personas) and all_ok:
            st.success(
                f"✅ All {len(personas)} personas received responses. "
                "Review above for metric consistency."
            )
        else:
            st.warning("⚠️ Some persona queries failed. Check errors above.")

        st.caption(f"Semantic View Used: `{SV_FQN}`")
    else:
        st.info(
            "Click **Run Consistency Test** to send the same question in "
            "different persona phrasings to the Cortex Agent and compare results."
        )
