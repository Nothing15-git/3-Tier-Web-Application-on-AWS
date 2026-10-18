"""
ha3tier Flask sample app.

Endpoints:
  GET  /            -> simple landing page with instance metadata
  GET  /health      -> health check (200 if DB reachable, else 503)
  GET  /visits      -> reads visit count from DB
  POST /visit       -> increments visit count, returns JSON
  GET  /api/info    -> JSON metadata about this instance and the region

Reads DB credentials from AWS Secrets Manager on startup.
"""
import json
import logging
import os
import socket
import time
from datetime import datetime, timezone

import boto3
import pymysql
from botocore.exceptions import ClientError
from flask import Flask, jsonify, request

REGION = os.environ.get("AWS_REGION", "us-east-1")
SECRET_NAME = os.environ.get("DB_SECRET_NAME", "ha3tier/db/master")
DB_PORT = int(os.environ.get("DB_PORT", "3306"))
DB_NAME = os.environ.get("DB_NAME", "appdb")

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ha3tier-app")

_cached_creds = None
_db_conn = None


def get_secret():
    """Fetch and cache DB credentials from Secrets Manager."""
    global _cached_creds
    if _cached_creds:
        return _cached_creds
    client = boto3.client("secretsmanager", region_name=REGION)
    try:
        resp = client.get_secret_value(SecretId=SECRET_NAME)
    except ClientError as e:
        log.error("Secrets Manager error: %s", e)
        raise
    secret = json.loads(resp["SecretString"])
    _cached_creds = {
        "username": secret.get("username") or secret.get("user"),
        "password": secret.get("password"),
        "host": secret.get("host"),
        "port": int(secret.get("port", DB_PORT)),
        "dbname": secret.get("dbname", DB_NAME),
    }
    log.info("Loaded DB credentials for %s@%s", _cached_creds["username"], _cached_creds["host"])
    return _cached_creds


def get_conn():
    """Return a live MySQL connection, reconnecting on failure."""
    global _db_conn
    creds = get_secret()
    if _db_conn is not None:
        try:
            _db_conn.ping(reconnect=True)
            return _db_conn
        except Exception:
            _db_conn = None
    _db_conn = pymysql.connect(
        host=creds["host"],
        port=creds["port"],
        user=creds["username"],
        password=creds["password"],
        database=creds["dbname"],
        connect_timeout=5,
        autocommit=True,
    )
    return _db_conn


def ensure_schema():
    """Create the visits table if it doesn't exist."""
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS visits (
                id INT AUTO_INCREMENT PRIMARY KEY,
                ts DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                path VARCHAR(255),
                user_agent VARCHAR(255)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """
        )
    log.info("Schema ensured (visits table)")


def instance_metadata():
    """Return basic info about this instance and the request."""
    return {
        "instance_id": socket.gethostname(),
        "instance_ip": request.host.split(":")[0] if request.host else None,
        "client_ip": request.headers.get("X-Forwarded-For", request.remote_addr),
        "az": os.environ.get("EC2_AZ", "unknown"),
        "region": REGION,
        "time_utc": datetime.now(timezone.utc).isoformat(),
    }


@app.route("/")
def index():
    info = instance_metadata()
    html = (
        "<!doctype html><html><head><title>ha3tier demo</title>"
        "<style>body{font-family:system-ui;margin:2rem;max-width:780px}"
        "code{background:#f4f4f4;padding:.1rem .3rem;border-radius:4px}</style>"
        "</head><body>"
        "<h1>HA 3-Tier Demo</h1>"
        f"<p>Hello from <code>{info['instance_id']}</code> in <code>{info['az']}</code>.</p>"
        "<ul>"
        "<li><a href='/health'>/health</a> &mdash; ALB health check</li>"
        "<li><a href='/visits'>/visits</a> &mdash; visit count from RDS</li>"
        "<li><a href='/api/info'>/api/info</a> &mdash; JSON metadata</li>"
        "<li>POST to <code>/visit</code> to record a visit</li>"
        "</ul>"
        "</body></html>"
    )
    return html


@app.route("/health")
def health():
    """Return 200 only if DB is reachable. Used by ALB health check."""
    try:
        conn = get_conn()
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
            cur.fetchone()
        return jsonify(status="ok", db="ok"), 200
    except Exception as e:
        log.warning("Health check failed: %s", e)
        return jsonify(status="degraded", db="down", error=str(e)), 503


@app.route("/visits")
def visits():
    try:
        conn = get_conn()
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM visits")
            (count,) = cur.fetchone()
        return jsonify(visits=count), 200
    except Exception as e:
        log.error("visits failed: %s", e)
        return jsonify(error="db_error", message=str(e)), 500


@app.route("/visit", methods=["POST"])
def visit():
    try:
        conn = get_conn()
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO visits (path, user_agent) VALUES (%s, %s)",
                ("/visit", request.headers.get("User-Agent", "")[:255]),
            )
            cur.execute("SELECT COUNT(*) FROM visits")
            (count,) = cur.fetchone()
        return jsonify(ok=True, total_visits=count), 200
    except Exception as e:
        log.error("visit failed: %s", e)
        return jsonify(ok=False, error=str(e)), 500


@app.route("/api/info")
def api_info():
    info = instance_metadata()
    try:
        conn = get_conn()
        with conn.cursor() as cur:
            cur.execute("SELECT VERSION()")
            (version,) = cur.fetchone()
        info["db_version"] = version
        info["db_reachable"] = True
    except Exception as e:
        info["db_reachable"] = False
        info["db_error"] = str(e)
    return jsonify(info)


if __name__ == "__main__":
    for attempt in range(1, 13):
        try:
            get_secret()
            ensure_schema()
            break
        except Exception as e:
            log.warning("Startup attempt %d failed: %s", attempt, e)
            time.sleep(5)
    app.run(host="0.0.0.0", port=80)
