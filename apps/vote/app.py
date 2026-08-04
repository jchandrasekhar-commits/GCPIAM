"""Web Application A - the Vote frontend.

Presents a "GCP vs AWS" choice and pushes each vote onto a Redis (Memorystore)
list. A separate worker drains that list into Cloud SQL. This app never talks to
the database directly - Redis is the fast write path / cache.
"""
import json
import os
import random
import socket

import redis
from flask import Flask, g, make_response, render_template, request

from telemetry import setup_error_reporting, setup_profiler, setup_tracing

OPTION_A = os.getenv("OPTION_A", "GCP")
OPTION_B = os.getenv("OPTION_B", "AWS")
HOSTNAME = socket.gethostname()

app = Flask(__name__)

# Observability: distributed tracing (Cloud Trace), profiling, error reporting.
setup_tracing("vote", app)
setup_profiler("vote")
error_client = setup_error_reporting(app)


def get_redis():
    """Lazily create a per-request Redis client to Memorystore."""
    if not hasattr(g, "redis"):
        g.redis = redis.Redis(
            host=os.getenv("REDIS_HOST", "localhost"),
            port=int(os.getenv("REDIS_PORT", "6379")),
            db=0,
            socket_connect_timeout=5,
            socket_timeout=5,
        )
    return g.redis


# GCE Ingress does not strip the path prefix, so the LB forwards "/a" to this
# pod as "/a". Serve the vote page on both "/" and the "/a" prefix.
@app.route("/", methods=["GET", "POST"])
@app.route("/a", methods=["GET", "POST"])
def vote():
    voter_id = request.cookies.get("voter_id") or f"{random.getrandbits(64):x}"
    chosen = None
    error_msg = None
    if request.method == "POST":
        chosen = request.form.get("vote")
        if chosen:
            payload = json.dumps({"voter_id": voter_id, "vote": chosen})
            try:
                get_redis().rpush("votes", payload)
            except redis.RedisError:
                if error_client:
                    error_client.report_exception()
                chosen = None
                error_msg = "Vote service temporarily unavailable — please try again shortly."
    resp = make_response(
        render_template(
            "index.html",
            option_a=OPTION_A,
            option_b=OPTION_B,
            hostname=HOSTNAME,
            vote=chosen,
            error=error_msg,
        )
    )
    resp.set_cookie("voter_id", voter_id)
    return resp


@app.route("/healthz")
def healthz():
    """Liveness/readiness probe - intentionally does not depend on Redis."""
    return "ok", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
