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

OPTION_A = os.getenv("OPTION_A", "GCP")
OPTION_B = os.getenv("OPTION_B", "AWS")
HOSTNAME = socket.gethostname()

app = Flask(__name__)


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


@app.route("/", methods=["GET", "POST"])
def vote():
    voter_id = request.cookies.get("voter_id") or f"{random.getrandbits(64):x}"
    chosen = None
    if request.method == "POST":
        chosen = request.form.get("vote")
        if chosen:
            payload = json.dumps({"voter_id": voter_id, "vote": chosen})
            get_redis().rpush("votes", payload)
    resp = make_response(
        render_template(
            "index.html",
            option_a=OPTION_A,
            option_b=OPTION_B,
            hostname=HOSTNAME,
            vote=chosen,
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
