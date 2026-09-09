#!/usr/bin/env bash
#
# vectum E2E smoke test.
#
# Builds the erlang-shipment, starts a real HTTP destination (python3) on an
# ephemeral port, starts vectum with a temp config + temp SQLite DB, POSTs an
# event, and asserts end-to-end that:
#   - vectum answers /ready and accepts the POST with 202
#   - the destination received the envelope carrying x-event-id/idempotency-key
#   - the delivery row in SQLite is 'succeeded'
#   - /metrics reports deliveries_success_total >= 1
#
# Self-contained: requires only `gleam` and `python3` in PATH. Uses temp dirs,
# traps cleanup, and exits non-zero on any failure. Runnable locally.
#
# Note: runs via `gleam export erlang-shipment` + `entrypoint.sh run` (not the
# escript) because the esqlite NIF is only resolvable when priv/ dirs sit
# alongside the ebin dirs in the shipment layout.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- temp workspace ---------------------------------------------------------
WORK="$(mktemp -d)"
CONFIG="$WORK/router.toml"
DB="$WORK/router.db"
DEST_READY="$WORK/dest.ready"
DEST_LOG="$WORK/dest.log"
VECTUM_LOG="$WORK/vectum.log"

cleanup() {
  set +e
  if [[ -n "${VECTUM_PID:-}" ]] && kill -0 "$VECTUM_PID" 2>/dev/null; then
    kill -TERM "$VECTUM_PID" 2>/dev/null
    wait "$VECTUM_PID" 2>/dev/null
  fi
  if [[ -n "${DEST_PID:-}" ]] && kill -0 "$DEST_PID" 2>/dev/null; then
    kill "$DEST_PID" 2>/dev/null
    wait "$DEST_PID" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "E2E FAIL: $*" >&2
  echo "--- vectum.log ---" >&2
  tail -n 40 "$VECTUM_LOG" >&2 || true
  echo "--- dest.log ---" >&2
  tail -n 40 "$DEST_LOG" >&2 || true
  exit 1
}

# --- build ------------------------------------------------------------------
echo ">> gleam export erlang-shipment"
gleam export erlang-shipment >/dev/null
ENTRYPOINT="$ROOT/build/erlang-shipment/entrypoint.sh"

# --- ephemeral ports --------------------------------------------------------
# Pick free ports for both the destination and vectum.
DEST_PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
VECTUM_PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"

# --- HTTP destination (python3) ---------------------------------------------
# Responds 200 to POST, prints "ready" once listening, and echoes headers.
cat >"$WORK/dest.py" <<PY
import http.server
import json

CAPTURED = "$WORK/captured.json"
PORT = $DEST_PORT

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _handle(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace")
        rec = {
            "method": self.command,
            "path": self.path,
            "x-event-id": self.headers.get("x-event-id"),
            "idempotency-key": self.headers.get("idempotency-key"),
            "body": body,
        }
        with open(CAPTURED, "w") as f:
            json.dump(rec, f)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")
    do_POST = _handle
    do_GET = _handle

httpd = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H)
open("$DEST_READY", "w").write("ready")
print(f"destination listening on {PORT}", flush=True)
httpd.serve_forever()
PY

python3 "$WORK/dest.py" >>"$DEST_LOG" 2>&1 &
DEST_PID=$!

for _ in $(seq 1 100); do
  [[ -f "$DEST_READY" ]] && break
  sleep 0.05
done
[[ -f "$DEST_READY" ]] || fail "destination did not become ready"

# --- vectum config ----------------------------------------------------------
cat >"$CONFIG" <<TOML
[server]
host = "127.0.0.1"
port = $VECTUM_PORT
max_body_bytes = 1048576

[storage]
path = "$DB"

[[sources]]
name = "internal"
type_from_json = "type"

[[destinations]]
name = "echo"
type = "http"
url = "http://127.0.0.1:$DEST_PORT/events"

[[routes]]
name = "internal-all"
source = "internal"
event = "*"
destinations = ["echo"]

[delivery]
max_attempts = 8
timeout_ms = 5000
initial_backoff_ms = 100
max_backoff_ms = 2000
jitter = false
TOML

echo ">> starting vectum on 127.0.0.1:$VECTUM_PORT (config: $CONFIG)"
"$ENTRYPOINT" run run --config "$CONFIG" >>"$VECTUM_LOG" 2>&1 &
VECTUM_PID=$!

# --- wait for /ready --------------------------------------------------------
READY=0
for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$VECTUM_PORT/ready" >/dev/null 2>&1; then
    READY=1
    break
  fi
  kill -0 "$VECTUM_PID" 2>/dev/null || fail "vectum exited before /ready"
  sleep 0.05
done
[[ "$READY" -eq 1 ]] || fail "vectum never became ready"

echo ">> POST event"
RESP="$(curl -sS -o "$WORK/post.body" -w '%{http_code}' \
  -X POST "http://127.0.0.1:$VECTUM_PORT/events/internal" \
  -H 'Content-Type: application/json' \
  -d '{"type":"ping","payload":{"n":1}}')"
[[ "$RESP" == "202" ]] || fail "expected 202, got $RESP: $(cat "$WORK/post.body" 2>/dev/null)"
echo "   202 accepted"

# --- wait for destination delivery + succeeded row --------------------------
DELIVERED=0
for _ in $(seq 1 100); do
  if [[ -f "$WORK/captured.json" ]]; then
    DELIVERED=1
    break
  fi
  sleep 0.05
done
[[ "$DELIVERED" -eq 1 ]] || fail "destination never received the envelope"

echo ">> verifying destination capture"
python3 - "$WORK/captured.json" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["method"] == "POST", rec
assert rec["x-event-id"], "missing x-event-id header"
assert rec["idempotency-key"], "missing idempotency-key header"
assert rec["x-event-id"] == rec["idempotency-key"], "idempotency-key != x-event-id"
assert rec["body"], "empty body"
print(f"   destination got x-event-id={rec['x-event-id']}")
PY

echo ">> verifying SQLite delivery row is succeeded"
python3 - "$DB" "$WORK/captured.json" <<'PY'
import json, sqlite3, sys
db, captured = sys.argv[1], sys.argv[2]
rec = json.load(open(captured))
con = sqlite3.connect(db)
rows = con.execute(
    "select status from deliveries where event_id = ?",
    (rec["x-event-id"],),
).fetchall()
assert rows, f"no delivery row for event {rec['x-event-id']}"
assert all(r[0] == "succeeded" for r in rows), f"delivery not succeeded: {rows}"
print(f"   delivery row(s) succeeded: {rows}")
PY

echo ">> verifying /metrics"
python3 - "http://127.0.0.1:$VECTUM_PORT/metrics" <<'PY'
import re, sys, urllib.request
text = urllib.request.urlopen(sys.argv[1], timeout=5).read().decode()
m = re.search(r"^deliveries_success_total\s+(\d+)", text, re.M)
assert m, "deliveries_success_total not found in /metrics"
val = int(m.group(1))
assert val >= 1, f"deliveries_success_total={val} < 1"
print(f"   deliveries_success_total={val}")
PY

echo "E2E OK: event delivered, DB row succeeded, metrics incremented"
