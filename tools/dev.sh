#!/usr/bin/env bash
# Build, test, launch the game on loopback and join it with simulated gamepads.
set -euo pipefail
cd "$(dirname "$0")/.."

STATE="${RICOCHET_STATE_DIR:-$(mktemp -d)/ricochet}"
PORT="${RICOCHET_PORT:-8445}"
LOG="$STATE/game.log"

echo "==> building"
swift build

echo "==> game rules"
swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1

mkdir -p "$STATE"
echo "==> starting the game (loopback, auto-approve, state in $STATE)"
# --bind is not optional alongside --auto-approve: the game refuses to approve players
# automatically on an interface anyone else can reach.
./.build/debug/ricochet --port "$PORT" --state-dir "$STATE" --bind 127.0.0.1 --auto-approve \
  --log-level info > "$LOG" 2>&1 &
GAME=$!
trap 'kill $GAME 2>/dev/null || true' EXIT

for _ in $(seq 1 80); do
  if grep -q 'Pairing code:' "$LOG"; then break; fi
  sleep 0.25
done
CODE=$(grep -o 'Pairing code:  [0-9]*' "$LOG" | tail -1 | awk '{print $3}')
if [ -z "$CODE" ]; then echo "!! the game did not start"; cat "$LOG"; exit 1; fi

echo "==> three gamepads in one round (code $CODE)"
node tools/smoke.mjs --code "$CODE" --port "$PORT" --players 3
