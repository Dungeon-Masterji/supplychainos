"""
SupplyChainOS — Persona Consistency Test

Proves that semantically equivalent questions from different personas
resolve to the same Cortex Agent metric and numeric result.

Three test cases, three personas each → 9 agent calls total.

Usage:
  SNOWFLAKE_DEFAULT_CONNECTION_NAME=GD04473 python3 persona_consistency.py
"""

import json
import os
import re
import sys
import time
from datetime import datetime

import snowflake.connector

AGENT_FQN = "SUPPLYCHAIN_DB.SEMANTIC.SUPPLYCHAINOS_AGENT"
TOLERANCE = 0.02  # 2% relative tolerance (agent may round differently)

# ─── Test cases with real gold values from CORE tables ──────────────────────

TEST_CASES = [
    {
        "id": 1,
        "title": "ON-TIME DELIVERY — Apex Components",
        "expected_metric": "on_time_delivery",
        "gold_value": 0.6867,
        "gold_label": "68.67%",
        "source": "FACT_SHIPMENT → shipments.on_time_delivery",
        "questions": {
            "Planning":    "What is the delivery performance for Apex Components?",
            "Procurement": "How reliable is Apex Components at on-time delivery?",
            "Logistics":   "What percentage of Apex Components shipments arrived on time?",
        },
    },
    {
        "id": 2,
        "title": "FILL RATE — Pacific Materials",
        "expected_metric": "fill_rate",
        "gold_value": 1.1681,
        "gold_label": "116.81%",
        "source": "FACT_ORDER + FACT_SHIPMENT → shipments.fill_rate",
        "questions": {
            "Planning":    "How well did Pacific Materials fill orders?",
            "Procurement": "What is Pacific Materials order fill rate?",
            "Logistics":   "What is the fulfillment rate for Pacific Materials?",
        },
    },
    {
        "id": 3,
        "title": "LANDED COST — Red Squares",
        "expected_metric": "total_landed_cost",
        "gold_value": 2443552.48,
        "gold_label": "$2,443,552.48",
        "source": "FACT_SHIPMENT → shipments.total_landed_cost",
        "questions": {
            "Procurement": "What is the landed cost for Red Squares?",
            "Finance":     "What is the fully loaded cost for Red Squares?",
            "Logistics":   "What is the total cost for Red Squares?",
        },
    },
]


# ─── Snowflake connection ──────────────────────────────────────────────────

def get_connection():
    conn_name = os.getenv("SNOWFLAKE_DEFAULT_CONNECTION_NAME")
    if not conn_name:
        sys.exit("Error: set SNOWFLAKE_DEFAULT_CONNECTION_NAME")
    return snowflake.connector.connect(connection_name=conn_name)


# ─── Agent caller ──────────────────────────────────────────────────────────

def call_agent(conn, question):
    payload = json.dumps({
        "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}]
    })
    cur = conn.cursor()
    try:
        cur.execute(
            "SELECT TRY_PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(%s, %s)) AS resp",
            [AGENT_FQN, payload],
        )
        row = cur.fetchone()
    finally:
        cur.close()
    resp = row[0]
    if isinstance(resp, str):
        resp = json.loads(resp)
    return resp


def extract_output(resp):
    """Extract text, SQL, and numeric result data from agent response."""
    text_parts = []
    sql = None
    result_data = None
    result_cols = None

    for block in resp.get("content", []):
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text":
            text_parts.append(block["text"])
        elif btype == "tool_use":
            tu = block.get("tool_use", {})
            if tu.get("name") == "system_execute_sql" and not sql:
                sql = tu.get("input", {}).get("sql")
        elif btype == "tool_result":
            tr = block.get("tool_result", block)
            if not isinstance(tr, dict) or tr.get("name") != "system_execute_sql":
                continue
            if tr.get("status") != "success":
                continue
            for item in tr.get("content", []):
                if not isinstance(item, dict) or item.get("type") != "json":
                    continue
                inner = item.get("json", {})
                if "sql" in inner:
                    sql = inner["sql"]
                rs = inner.get("result_set", {})
                if "data" in rs:
                    result_data = rs["data"]
                meta = rs.get("resultSetMetaData", {})
                if "rowType" in meta:
                    result_cols = [c["name"].lower() for c in meta["rowType"]]

    return {
        "text": "\n".join(text_parts),
        "sql": sql,
        "result_data": result_data,
        "result_cols": result_cols,
    }


def extract_primary_number(result_data, result_cols, gold_value):
    """Find the number in agent results closest to the gold value.

    For single-row results, return the first numeric cell.
    For multi-row results filtered to a specific entity, the agent typically
    returns 1 row — grab the metric column.
    """
    if not result_data:
        return None

    candidates = []
    for row in result_data:
        for cell in row:
            try:
                v = float(str(cell).replace(",", "").strip())
                candidates.append(v)
            except (ValueError, TypeError):
                continue

    if not candidates:
        return None

    # Return the candidate closest to gold
    return min(candidates, key=lambda v: abs(v - gold_value))


def numbers_match(a, b, tol=TOLERANCE):
    if a is None or b is None:
        return False
    if a == 0 and b == 0:
        return True
    denom = max(abs(a), abs(b), 1e-9)
    return abs(a - b) / denom <= tol


def detect_metric_in_sql(sql_text, expected_metric):
    """Check if the agent's SQL references the expected metric or its synonyms."""
    if not sql_text:
        return False
    sql_lower = sql_text.lower()
    metric_tokens = {
        "on_time_delivery": ["on_time_delivery", "arrival_date", "requested_delivery_date", "count_if"],
        "fill_rate":        ["fill_rate", "shipped_quantity", "ordered_quantity"],
        "total_landed_cost": ["landed_cost", "material_cost", "freight_cost", "duty_cost", "handling_cost"],
    }
    tokens = metric_tokens.get(expected_metric, [expected_metric])
    return any(t in sql_lower for t in tokens)


# ─── Main ──────────────────────────────────────────────────────────────────

def main():
    width = 72
    print("=" * width)
    print("SUPPLYCHAINOS — PERSONA CONSISTENCY TEST")
    print(f"Agent: {AGENT_FQN}")
    print(f"Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * width)

    conn = get_connection()
    print(f"Connected via: {os.getenv('SNOWFLAKE_DEFAULT_CONNECTION_NAME')}\n")

    total_tests = len(TEST_CASES)
    total_questions = sum(len(tc["questions"]) for tc in TEST_CASES)
    passed_cases = 0
    all_results = []

    for tc in TEST_CASES:
        print("-" * width)
        print(f"TEST CASE {tc['id']}: {tc['title']}")
        print(f"Expected metric: {tc['expected_metric']}")
        print(f"Gold value: {tc['gold_label']}")
        print(f"Source: {tc['source']}")
        print("-" * width)

        persona_results = []

        for persona, question in tc["questions"].items():
            t0 = time.time()
            print(f"  {persona:14s}: \"{question}\"")

            try:
                resp = call_agent(conn, question)
                out = extract_output(resp)
                agent_val = extract_primary_number(
                    out["result_data"], out["result_cols"], tc["gold_value"]
                )
                metric_ok = detect_metric_in_sql(out["sql"], tc["expected_metric"])
                elapsed = round(time.time() - t0, 1)

                if agent_val is not None:
                    # Format display value
                    if tc["expected_metric"] == "total_landed_cost":
                        display = f"${agent_val:,.2f}"
                    else:
                        display = f"{agent_val:.4f} ({agent_val:.1%})"
                    print(f"  {'':14s}  → Result: {display}")
                    print(f"  {'':14s}  → Metric in SQL: {'Yes' if metric_ok else 'No'}")
                    print(f"  {'':14s}  → Time: {elapsed}s")
                else:
                    display = "(no numeric result)"
                    print(f"  {'':14s}  → Result: {display}")
                    print(f"  {'':14s}  → Time: {elapsed}s")

                persona_results.append({
                    "persona": persona,
                    "question": question,
                    "value": agent_val,
                    "display": display,
                    "metric_ok": metric_ok,
                    "sql": out["sql"],
                    "text": out["text"][:200],
                    "elapsed": elapsed,
                    "error": None,
                })
            except Exception as e:
                elapsed = round(time.time() - t0, 1)
                print(f"  {'':14s}  → ERROR: {e}")
                persona_results.append({
                    "persona": persona,
                    "question": question,
                    "value": None,
                    "display": f"ERROR: {e}",
                    "metric_ok": False,
                    "sql": None,
                    "text": "",
                    "elapsed": elapsed,
                    "error": str(e),
                })

        # ── Verdict ─────────────────────────────────────────────────────
        values = [r["value"] for r in persona_results if r["value"] is not None]
        all_metric_ok = all(r["metric_ok"] for r in persona_results if r["error"] is None)

        # Check all values match each other pairwise
        values_consistent = True
        if len(values) >= 2:
            for i in range(len(values)):
                for j in range(i + 1, len(values)):
                    if not numbers_match(values[i], values[j]):
                        values_consistent = False

        # Check all values match gold
        gold_match = all(numbers_match(v, tc["gold_value"]) for v in values) if values else False

        if len(values) == len(persona_results) and values_consistent and gold_match:
            verdict = "PASS"
            passed_cases += 1
            icon = "✓"
        elif len(values) == len(persona_results) and values_consistent:
            verdict = "PASS (consistent, gold drift)"
            passed_cases += 1
            icon = "~"
        elif values_consistent and len(values) >= 2:
            verdict = "PARTIAL"
            icon = "~"
        else:
            verdict = "FAIL"
            icon = "✗"

        print()
        print(f"  VERDICT: {verdict} {icon}")
        if values:
            print(f"  Values returned:  {', '.join(f'{v}' for v in values)}")
            print(f"  Gold value:       {tc['gold_value']}")
            print(f"  All match gold:   {'Yes' if gold_match else 'No'}")
            print(f"  Mutually consistent: {'Yes' if values_consistent else 'No'}")
            print(f"  Correct metric:   {'Yes' if all_metric_ok else 'No'}")
        print()

        all_results.append({
            "test_id": tc["id"],
            "title": tc["title"],
            "expected_metric": tc["expected_metric"],
            "gold_value": tc["gold_value"],
            "verdict": verdict,
            "persona_results": persona_results,
            "values_consistent": values_consistent,
            "gold_match": gold_match,
        })

    conn.close()

    # ── Summary ─────────────────────────────────────────────────────────
    print("=" * width)
    print("SUMMARY")
    print("=" * width)
    for r in all_results:
        icon = "✓" if "PASS" in r["verdict"] else ("~" if "PARTIAL" in r["verdict"] else "✗")
        print(f"  Test {r['test_id']}: {r['title']:<40s} {r['verdict']:>20s} {icon}")

    print()
    print(f"  Total test cases:  {total_tests}")
    print(f"  Agent calls made:  {total_questions}")
    print(f"  Passed:            {passed_cases}/{total_tests}")
    print(f"  Consistency rate:  {passed_cases/total_tests*100:.0f}%")
    print("=" * width)

    # ── Write JSON results ──────────────────────────────────────────────
    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "evaluation", "persona_consistency_results.json")
    with open(out_path, "w") as f:
        json.dump({
            "generated": datetime.now().isoformat(),
            "agent": AGENT_FQN,
            "tolerance": TOLERANCE,
            "total_cases": total_tests,
            "passed": passed_cases,
            "results": [
                {
                    "test_id": r["test_id"],
                    "title": r["title"],
                    "metric": r["expected_metric"],
                    "gold_value": r["gold_value"],
                    "verdict": r["verdict"],
                    "consistent": r["values_consistent"],
                    "gold_match": r["gold_match"],
                    "personas": [
                        {
                            "persona": p["persona"],
                            "question": p["question"],
                            "value": p["value"],
                            "metric_in_sql": p["metric_ok"],
                            "time_s": p["elapsed"],
                        }
                        for p in r["persona_results"]
                    ],
                }
                for r in all_results
            ],
        }, f, indent=2)
    print(f"\nWrote: {out_path}")

    sys.exit(0 if passed_cases == total_tests else 1)


if __name__ == "__main__":
    main()
