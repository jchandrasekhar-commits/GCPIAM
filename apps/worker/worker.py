"""Backend sync worker (3rd service).

Continuously drains votes from Redis (Memorystore) and persists an idempotent
per-voter tally into Cloud SQL (PostgreSQL). This is what keeps the results
page consistent: the vote app writes fast to Redis, the worker is the single
writer to the durable database, and the result app only reads from the DB.

Flow:  vote app -> Redis list "votes" -> [worker] -> Postgres table "votes"
"""
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import psycopg2
import redis

from telemetry import setup_error_reporting, setup_profiler, setup_tracing


# --- Liveness health server -------------------------------------------------
# _heartbeat[0] is updated on every BLPOP iteration (including idle timeouts).
# /healthz returns 503 when the loop has been silent for > 60 s, giving
# Kubernetes a reliable signal to restart a deadlocked pod.
_heartbeat: list[float] = [0.0]  # mutable singleton; avoids a global declaration


class _HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/healthz":
            age = time.time() - _heartbeat[0]
            if age < 60:
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"ok")
            else:
                self.send_response(503)
                self.end_headers()
                self.wfile.write(f"stale: {age:.0f}s since last loop iteration".encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *_) -> None:  # suppress HTTP access logs
        pass


def start_health_server(port: int = 8081) -> None:
    """Start a daemon-thread HTTP health server that does not block shutdown."""
    server = HTTPServer(("0.0.0.0", port), _HealthHandler)
    threading.Thread(target=server.serve_forever, daemon=True, name="health-srv").start()
    print(f"worker: health server listening on :{port}", flush=True)


def connect_redis():
    while True:
        try:
            client = redis.Redis(
                host=os.getenv("REDIS_HOST", "localhost"),
                port=int(os.getenv("REDIS_PORT", "6379")),
                db=0,
                socket_connect_timeout=5,
            )
            client.ping()
            print("worker: connected to redis", flush=True)
            return client
        except Exception as exc:  # noqa: BLE001 - retry on any connection error
            print(f"worker: waiting for redis ({exc})", flush=True)
            time.sleep(2)


def connect_db():
    while True:
        try:
            conn = psycopg2.connect(
                host=os.getenv("DB_HOST", "localhost"),
                port=int(os.getenv("DB_PORT", "5432")),
                dbname=os.getenv("DB_NAME", "webappb"),
                user=os.getenv("DB_USER", "webappb"),
                password=os.getenv("DB_PASSWORD", ""),
                connect_timeout=5,
            )
            print("worker: connected to postgres", flush=True)
            return conn
        except Exception as exc:  # noqa: BLE001 - retry on any connection error
            print(f"worker: waiting for postgres ({exc})", flush=True)
            time.sleep(2)


def ensure_schema(conn):
    with conn.cursor() as cur:
        cur.execute(
            "CREATE TABLE IF NOT EXISTS votes ("
            "  id VARCHAR(255) NOT NULL PRIMARY KEY,"
            "  vote VARCHAR(255) NOT NULL,"
            "  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()"
            ")"
        )
    conn.commit()


def process(conn, entry):
    """Upsert one voter's choice (one vote per voter_id)."""
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO votes (id, vote) VALUES (%s, %s) "
            "ON CONFLICT (id) DO UPDATE SET vote = EXCLUDED.vote, updated_at = NOW()",
            (entry["voter_id"], entry["vote"]),
        )
    conn.commit()


def main():
    # Observability: distributed tracing (Cloud Trace), profiling, error reporting.
    setup_tracing("worker")
    setup_profiler("worker")
    error_client = setup_error_reporting()

    start_health_server()

    r = connect_redis()
    conn = connect_db()
    ensure_schema(conn)
    print("worker: syncing redis -> postgres", flush=True)
    while True:
        item = r.blpop("votes", timeout=5)
        _heartbeat[0] = time.time()  # heartbeat on every iteration, including idle
        if item is None:
            continue
        try:
            process(conn, json.loads(item[1]))
        except Exception as exc:  # noqa: BLE001 - keep the loop alive on bad rows
            print(f"worker: error processing vote ({exc})", flush=True)
            if error_client is not None:
                try:
                    error_client.report_exception()
                except Exception:  # noqa: BLE001
                    pass
            conn.rollback()


if __name__ == "__main__":
    main()
