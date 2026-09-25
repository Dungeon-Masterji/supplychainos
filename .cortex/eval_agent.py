"""
SupplyChainOS — Cortex Agent Evaluation Script

Loads 30 gold questions from EVAL.GOLD_QUESTIONS, runs each through the Cortex
Agent, compares agent results against gold SQL, and produces:
  1. evaluation_results.csv   — per-question detail
  2. evaluation_report.txt    — human-readable summary
  3. evaluation_failures.txt  — failing questions prioritised for fixing

Usage:
  SNOWFLAKE_DEFAULT_CONNECTION_NAME=GD04473 python3 eval_agent.py
"""

import csv
import json
import os
import re
import sys
import time
from datetime import datetime
from decimal import Decimal

import snowflake.connector

# ─── Config ─────────────────────────────────────────────────────────────────

AGENT_FQN = "SUPPLYCHAIN_DB.SEMANTIC.SUPPLYCHAINOS_AGENT"
TOLERANCE = 0.001  # 0.1 % relative tolerance for numeric comparison
AGENT_TIMEOUT = 120  # seconds per agent call


# ─── Connection ─────────────────────────────────────────────────────────────

def get_connection():
    conn_name = os.getenv("SNOWFLAKE_DEFAULT_CONNECTION_NAME")
    if not conn_name:
        sys.exit("Error: set SNOWFLAKE_DEFAULT_CONNECTION_NAME")
    return snowflake.connector.connect(connection_name=conn_name)


def run_sql(conn, sql):
    """Execute SQL, return list-of-dicts with lowercase keys."""
    cur = conn.cursor(snowflake.connector.DictCursor)
    try:
        cur.execute(sql)
        rows = cur.fetchall()
        return [{k.lower(): v for k, v in row.items()} for row in rows]
    finally:
        cur.close()


# ─── Agent caller ───────────────────────────────────────────────────────────

def call_agent(conn, question):
    """Call Cortex Agent via DATA_AGENT_RUN. Returns parsed response dict."""
    payload = json.dumps({
        "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}]
    })
    sql = "SELECT TRY_PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(%s, %s)) AS resp"
    cur = conn.cursor()
    try:
        cur.execute(sql, [AGENT_FQN, payload])
        row = cur.fetchone()
    finally:
        cur.close()
    resp = row[0]
    if isinstance(resp, str):
        resp = json.loads(resp)
    return resp


def extract_agent_output(resp):
    """Parse agent response → (text, logical_sql, physical_sql, result_data, result_cols)."""
    text_parts = []
    logical_sql = None
    physical_sql = None
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
            if tu.get("name") == "system_execute_sql":
                logical_sql = tu.get("input", {}).get("sql")

        elif btype == "tool_result":
            tr = block.get("tool_result", block)
            if not isinstance(tr, dict):
                continue
            if tr.get("name") != "system_execute_sql" or tr.get("status") != "success":
                continue
            for item in tr.get("content", []):
                if not isinstance(item, dict) or item.get("type") != "json":
                    continue
                inner = item.get("json", {})
                if "sql" in inner:
                    physical_sql = inner["sql"]
                rs = inner.get("result_set", {})
                if "data" in rs:
                    result_data = rs["data"]
                meta = rs.get("resultSetMetaData", {})
                if "rowType" in meta:
                    result_cols = [c["name"].lower() for c in meta["rowType"]]

    return {
        "text": "\n".join(text_parts),
        "logical_sql": logical_sql,
        "physical_sql": physical_sql,
        "result_data": result_data,
        "result_cols": result_cols,
    }


# ─── Comparison logic ──────────────────────────────────────────────────────

def to_number(v):
    """Try converting a value to float for comparison."""
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, Decimal):
        return float(v)
    if isinstance(v, str):
        v = v.strip().replace(",", "")
        try:
            return float(v)
        except ValueError:
            return None
    return None


def numbers_match(a, b, tol=TOLERANCE):
    """Compare two numbers within relative tolerance."""
    if a is None or b is None:
        return a is None and b is None
    if a == 0 and b == 0:
        return True
    if a == 0 or b == 0:
        return abs(a - b) < tol
    return abs(a - b) / max(abs(a), abs(b)) <= tol


def compare_single_value(gold_result, agent_data, agent_cols):
    """Compare when gold is a single-row result (dict with one key metric).

    Returns (match, variance_pct, notes).
    """
    if not agent_data or not agent_cols:
        return "Fail", None, "Agent returned no result data"

    # Gold is a dict like {"otd": 0.6981}
    if isinstance(gold_result, dict):
        gold_key = list(gold_result.keys())[0]
        gold_val = to_number(gold_result[gold_key])
        if gold_val is None:
            return "Fail", None, f"Gold value not numeric: {gold_result[gold_key]}"

        # Agent returns [[value]] — grab first cell
        if len(agent_data) >= 1 and len(agent_data[0]) >= 1:
            agent_val = to_number(agent_data[0][0])
            if agent_val is None:
                return "Fail", None, f"Agent value not numeric: {agent_data[0][0]}"
            if numbers_match(gold_val, agent_val):
                var = abs(gold_val - agent_val) / max(abs(gold_val), 1e-9) * 100
                return "Pass", round(var, 4), ""
            else:
                var = abs(gold_val - agent_val) / max(abs(gold_val), 1e-9) * 100
                return "Fail", round(var, 4), f"Gold={gold_val}, Agent={agent_val}"

    return "Fail", None, "Could not parse gold result for single-value comparison"


def compare_multi_row(gold_result, gold_count, agent_data, agent_cols):
    """Compare when gold is a list of dicts (multi-row result).

    Returns (match, variance_pct, notes).
    """
    if not agent_data or not agent_cols:
        return "Fail", None, "Agent returned no result data"

    agent_row_count = len(agent_data)

    # For complex multi-row results like Q020, just check row count
    if isinstance(gold_result, dict) and "rows" in gold_result:
        expected_rows = gold_result["rows"]
        if agent_row_count == expected_rows:
            return "Pass", 0, f"Row count match: {agent_row_count}"
        elif agent_row_count >= expected_rows * 0.8:
            return "Partial", None, f"Expected {expected_rows} rows, got {agent_row_count}"
        else:
            return "Fail", None, f"Expected {expected_rows} rows, got {agent_row_count}"

    if not isinstance(gold_result, list):
        return "Fail", None, f"Unexpected gold format: {type(gold_result).__name__}"

    # Step 1: row count check
    row_count_match = agent_row_count == gold_count
    notes = []

    if not row_count_match:
        notes.append(f"Row count: expected {gold_count}, got {agent_row_count}")

    # Step 2: find numeric values in gold and try to match them in agent output
    gold_numerics = []
    for grow in gold_result:
        for k, v in grow.items():
            n = to_number(v)
            if n is not None:
                gold_numerics.append(n)

    agent_numerics = []
    for arow in agent_data:
        for cell in arow:
            n = to_number(cell)
            if n is not None:
                agent_numerics.append(n)

    matched_values = 0
    for gn in gold_numerics:
        for an in agent_numerics:
            if numbers_match(gn, an):
                matched_values += 1
                break

    total_gold_numerics = len(gold_numerics)
    if total_gold_numerics == 0:
        if row_count_match:
            return "Pass", 0, "Row count matches; no numerics to compare"
        return "Partial" if agent_row_count > 0 else "Fail", None, "; ".join(notes)

    value_match_rate = matched_values / total_gold_numerics

    if row_count_match and value_match_rate >= 0.8:
        return "Pass", round((1 - value_match_rate) * 100, 2), "; ".join(notes) if notes else ""
    elif value_match_rate >= 0.5 or row_count_match:
        notes.append(f"Value match: {matched_values}/{total_gold_numerics}")
        return "Partial", round((1 - value_match_rate) * 100, 2), "; ".join(notes)
    else:
        notes.append(f"Value match: {matched_values}/{total_gold_numerics}")
        return "Fail", round((1 - value_match_rate) * 100, 2), "; ".join(notes)


def evaluate_question(gold_row, agent_resp_parsed):
    """Full comparison for one question. Returns (match, variance, notes)."""
    gold_result = gold_row["expected_result"]
    gold_count = gold_row["result_count"]

    # Parse the gold JSON
    if isinstance(gold_result, str):
        try:
            gold_result = json.loads(gold_result)
        except json.JSONDecodeError:
            return "Fail", None, f"Cannot parse gold JSON: {gold_result[:80]}"

    agent_data = agent_resp_parsed["result_data"]
    agent_cols = agent_resp_parsed["result_cols"]

    # Single-value question (gold_count == 1 and gold is a dict)
    if gold_count == 1 and isinstance(gold_result, dict) and "rows" not in gold_result:
        return compare_single_value(gold_result, agent_data, agent_cols)

    # Single-value wrapped in a list with one element
    if isinstance(gold_result, list) and len(gold_result) == 1 and gold_count == 1:
        return compare_single_value(gold_result[0], agent_data, agent_cols)

    # Multi-row
    return compare_multi_row(gold_result, gold_count, agent_data, agent_cols)


# ─── Category assignment ───────────────────────────────────────────────────

def categorize(qid, question_text, expected_metric):
    """Assign question to evaluation category."""
    qnum = int(qid[1:])
    if qnum <= 5:
        return "simple_metric"
    if qnum <= 10:
        return "dimension_breakdown"
    if qnum <= 15:
        return "ranking_filter"
    if qnum <= 20:
        return "temporal"
    if qnum <= 25:
        return "cross_metric"
    return "synonym_rephrase"


# ─── Main ──────────────────────────────────────────────────────────────────

def main():
    print("=" * 70)
    print("SupplyChainOS — Cortex Agent Evaluation")
    print(f"Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 70)

    conn = get_connection()
    print(f"Connected via: {os.getenv('SNOWFLAKE_DEFAULT_CONNECTION_NAME')}")

    # Load gold questions
    questions = run_sql(conn, "SELECT * FROM SUPPLYCHAIN_DB.EVAL.GOLD_QUESTIONS ORDER BY QUESTION_ID")
    print(f"Loaded {len(questions)} gold questions\n")

    results = []
    category_stats = {}

    for i, q in enumerate(questions):
        qid = q["question_id"]
        qtext = q["question_text"]
        gold_sql = q["gold_sql"]
        expected_metric = q["expected_metric"]
        expected_result = q["expected_result"]
        result_count = int(q["result_count"])
        notes_col = q.get("notes", "")
        category = categorize(qid, qtext, expected_metric)

        print(f"[{i+1:2d}/30] {qid}: {qtext[:60]}...", flush=True)

        # ── Step A: Execute gold SQL ────────────────────────────────────
        try:
            gold_rows = run_sql(conn, gold_sql)
            gold_result_str = json.dumps(gold_rows, default=str)
        except Exception as e:
            gold_result_str = f"ERROR: {e}"
            gold_rows = []

        # ── Step B: Call Cortex Agent ───────────────────────────────────
        cortex_sql = ""
        cortex_result_str = ""
        agent_text = ""
        t0 = time.time()
        try:
            resp = call_agent(conn, qtext)
            agent_out = extract_agent_output(resp)
            agent_text = agent_out["text"]
            cortex_sql = agent_out["physical_sql"] or agent_out["logical_sql"] or ""
            if agent_out["result_data"] is not None:
                cortex_result_str = json.dumps(agent_out["result_data"], default=str)
            else:
                cortex_result_str = "(no structured data)"
            agent_time = round(time.time() - t0, 1)
        except Exception as e:
            agent_out = {"result_data": None, "result_cols": None,
                         "text": "", "logical_sql": None, "physical_sql": None}
            cortex_result_str = f"ERROR: {e}"
            agent_time = round(time.time() - t0, 1)

        # ── Step C: Compare ─────────────────────────────────────────────
        match, variance, eval_notes = evaluate_question(
            {"expected_result": expected_result, "result_count": result_count},
            agent_out,
        )

        # ── Step D: Metric identity check ──────────────────────────────
        metric_found = False
        for metric_name in expected_metric.split("+"):
            mn = metric_name.strip().lower()
            sql_lower = cortex_sql.lower()
            text_lower = agent_text.lower()
            if mn in sql_lower or mn.replace("_", " ") in text_lower:
                metric_found = True
                break
        if not metric_found and match == "Pass":
            eval_notes = (eval_notes + "; " if eval_notes else "") + "Metric name not found in agent SQL/text"
            match = "Partial"

        status_icon = {"Pass": "PASS", "Partial": "PART", "Fail": "FAIL"}[match]
        print(f"         → {status_icon}  ({agent_time}s)", flush=True)

        # Track category stats
        if category not in category_stats:
            category_stats[category] = {"total": 0, "pass": 0, "partial": 0, "fail": 0}
        category_stats[category]["total"] += 1
        category_stats[category][match.lower()] += 1

        results.append({
            "question_id": qid,
            "question_text": qtext,
            "category": category,
            "expected_metric": expected_metric,
            "gold_result": expected_result if isinstance(expected_result, str) else json.dumps(expected_result, default=str),
            "cortex_result": cortex_result_str[:2000],
            "cortex_sql_generated": cortex_sql[:2000],
            "match": match,
            "variance": variance if variance is not None else "",
            "notes": eval_notes,
            "agent_time_s": agent_time,
        })

    conn.close()

    # ─── Output files ───────────────────────────────────────────────────

    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "evaluation")

    # 1. CSV
    csv_path = os.path.join(out_dir, "evaluation_results.csv")
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "question_id", "question_text", "category", "expected_metric",
            "gold_result", "cortex_result", "cortex_sql_generated",
            "match", "variance", "notes", "agent_time_s",
        ])
        writer.writeheader()
        writer.writerows(results)
    print(f"\nWrote: {csv_path}")

    # Compute summary
    total = len(results)
    passed = sum(1 for r in results if r["match"] == "Pass")
    partial = sum(1 for r in results if r["match"] == "Partial")
    failed = sum(1 for r in results if r["match"] == "Fail")
    accuracy = passed / total * 100 if total else 0
    pass_partial = (passed + partial) / total * 100 if total else 0
    avg_time = sum(r["agent_time_s"] for r in results) / total if total else 0

    # 2. Report
    report_path = os.path.join(out_dir, "evaluation_report.txt")
    with open(report_path, "w") as f:
        f.write("=" * 70 + "\n")
        f.write("SUPPLYCHAINOS — CORTEX AGENT EVALUATION REPORT\n")
        f.write(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"Agent: {AGENT_FQN}\n")
        f.write("=" * 70 + "\n\n")

        f.write("SUMMARY\n")
        f.write("-" * 40 + "\n")
        f.write(f"Total questions:     {total}\n")
        f.write(f"Passed:              {passed}\n")
        f.write(f"Partial:             {partial}\n")
        f.write(f"Failed:              {failed}\n")
        f.write(f"Strict accuracy:     {accuracy:.1f}% ({passed}/{total})\n")
        f.write(f"Lenient accuracy:    {pass_partial:.1f}% ({passed + partial}/{total})\n")
        f.write(f"Avg agent time:      {avg_time:.1f}s\n\n")

        f.write("CATEGORY BREAKDOWN\n")
        f.write("-" * 40 + "\n")
        f.write(f"{'Category':<22} {'Total':>5} {'Pass':>5} {'Part':>5} {'Fail':>5} {'Acc%':>6}\n")
        for cat in ["simple_metric", "dimension_breakdown", "ranking_filter",
                     "temporal", "cross_metric", "synonym_rephrase"]:
            s = category_stats.get(cat, {"total": 0, "pass": 0, "partial": 0, "fail": 0})
            acc = s["pass"] / s["total"] * 100 if s["total"] else 0
            f.write(f"{cat:<22} {s['total']:>5} {s['pass']:>5} {s['partial']:>5} {s['fail']:>5} {acc:>5.1f}%\n")
        f.write("\n")

        f.write("PER-QUESTION RESULTS\n")
        f.write("-" * 40 + "\n")
        for r in results:
            icon = {"Pass": "[PASS]", "Partial": "[PART]", "Fail": "[FAIL]"}[r["match"]]
            f.write(f"{r['question_id']} {icon} {r['question_text'][:55]}\n")
            if r["variance"] != "":
                f.write(f"       Variance: {r['variance']}%\n")
            if r["notes"]:
                f.write(f"       Notes: {r['notes']}\n")

    print(f"Wrote: {report_path}")

    # 3. Failures log
    failures = [r for r in results if r["match"] in ("Fail", "Partial")]
    fail_path = os.path.join(out_dir, "evaluation_failures.txt")
    with open(fail_path, "w") as f:
        f.write("SUPPLYCHAINOS — FAILING QUESTIONS (prioritised)\n")
        f.write(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"Total failures: {len(failures)} ({failed} Fail + {partial} Partial)\n")
        f.write("=" * 70 + "\n\n")

        # Sort: Fail first, then Partial; within each group by question_id
        failures.sort(key=lambda r: (0 if r["match"] == "Fail" else 1, r["question_id"]))

        for r in failures:
            icon = "[FAIL]" if r["match"] == "Fail" else "[PART]"
            f.write(f"{icon} {r['question_id']}: {r['question_text']}\n")
            f.write(f"  Category: {r['category']}\n")
            f.write(f"  Expected metric: {r['expected_metric']}\n")
            if r["notes"]:
                f.write(f"  Issue: {r['notes']}\n")
            if r["variance"] != "":
                f.write(f"  Variance: {r['variance']}%\n")
            f.write(f"  Gold result: {r['gold_result'][:200]}\n")
            f.write(f"  Agent result: {r['cortex_result'][:200]}\n")
            if r["cortex_sql_generated"]:
                f.write(f"  Agent SQL: {r['cortex_sql_generated'][:200]}\n")
            f.write("\n")

    print(f"Wrote: {fail_path}")

    # Console summary
    print("\n" + "=" * 70)
    print(f"RESULT: {passed}/{total} Pass, {partial} Partial, {failed} Fail")
    print(f"Strict accuracy:  {accuracy:.1f}%")
    print(f"Lenient accuracy: {pass_partial:.1f}%")
    print("=" * 70)


if __name__ == "__main__":
    main()
