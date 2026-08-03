"""Web Application B - the Results frontend.

Reads the durable vote tally from Cloud SQL (PostgreSQL) and renders it. It is
read-only: it never touches Redis and never writes to the DB. The worker keeps
the DB in sync, so this page always reflects committed votes.
"""
import os

import psycopg2
from flask import Flask, jsonify, render_template

OPTION_A = os.getenv("OPTION_A", "GCP")
OPTION_B = os.getenv("OPTION_B", "AWS")

app = Flask(__name__)


def get_conn():
    return psycopg2.connect(
        host=os.getenv("DB_HOST", "localhost"),
        port=int(os.getenv("DB_PORT", "5432")),
        dbname=os.getenv("DB_NAME", "webappb"),
        user=os.getenv("DB_USER", "webappb"),
        password=os.getenv("DB_PASSWORD", ""),
        connect_timeout=5,
    )


def tally():
    counts = {"a": 0, "b": 0}
    try:
        conn = get_conn()
        with conn, conn.cursor() as cur:
            cur.execute("SELECT vote, COUNT(id) FROM votes GROUP BY vote")
            for vote, count in cur.fetchall():
                if vote == OPTION_A:
                    counts["a"] = count
                elif vote == OPTION_B:
                    counts["b"] = count
        conn.close()
    except Exception as exc:  # noqa: BLE001 - show zeros if the DB is unreachable
        print(f"result: db error ({exc})", flush=True)
    return counts


# GCE Ingress does not strip the path prefix, so the LB forwards "/b" to this
# pod as "/b". Serve the results page on both "/" and the "/b" prefix.
@app.route("/")
@app.route("/b")
def index():
    counts = tally()
    total = counts["a"] + counts["b"]
    pct_a = (counts["a"] / total * 100) if total else 50
    pct_b = (counts["b"] / total * 100) if total else 50
    return render_template(
        "index.html",
        option_a=OPTION_A,
        option_b=OPTION_B,
        a=counts["a"],
        b=counts["b"],
        pct_a=round(pct_a, 1),
        pct_b=round(pct_b, 1),
        total=total,
    )


@app.route("/api/results")
def api_results():
    return jsonify(tally())


@app.route("/healthz")
def healthz():
    """Liveness/readiness probe - intentionally does not depend on the DB."""
    return "ok", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
