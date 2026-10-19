#!/usr/bin/env bash
# End-to-end smoke test: dedicated server + an automated bot client, both headless.
# Asserts that the bot connects, targets, charges, hits and kills a monster, with no engine errors.
#
#   GODOT=/path/to/godot tests/smoke_test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
LOG_DIR="${LOG_DIR:-/tmp/thornhill-test}"
mkdir -p "$LOG_DIR"

echo "[smoke] import (registers assets and class_name scripts)"
timeout 180 "$GODOT" --headless --path . --import > "$LOG_DIR/import.log" 2>&1 || true

echo "[smoke] unit tests"
"$GODOT" --headless --path . --script tests/test_game_data.gd

echo "[smoke] self-test (lobby, combat rules, quests, vendor, cave, pathing, tagging, gear visuals)"
THORNHILL_VFX_TEST=1 timeout 90 "$GODOT" --headless --path . -- --host --selftest --autoquit=60 > "$LOG_DIR/selftest.log" 2>&1 || true
grep "\[selftest\]" "$LOG_DIR/selftest.log" | sed 's/^/  /'
if grep -q "\[selftest\] FAIL" "$LOG_DIR/selftest.log" || ! grep -q "\[selftest\] done" "$LOG_DIR/selftest.log"; then
  echo "[smoke] FAILED: self-test"; grep -iE "error" "$LOG_DIR/selftest.log" | head; exit 1
fi

echo "[smoke] starting server"
timeout 60 "$GODOT" --headless --path . -- --server --autoquit=28 > "$LOG_DIR/server.log" 2>&1 &
SERVER_PID=$!
sleep 3

echo "[smoke] starting bot client"
timeout 60 "$GODOT" --headless --path . -- --join=127.0.0.1 --bot --autoquit=24 > "$LOG_DIR/client.log" 2>&1 || true
wait $SERVER_PID || true

fail=0
expect() {
  if grep -q "$1" "$LOG_DIR/client.log"; then echo "  ok   $2"; else echo "  FAIL $2"; fail=1; fi
}
expect "Welcome to Thornhill, Bot" "client logged in, created a character and entered"
expect "Target: " "bot acquired a target"
expect "uses Charge on" "charge landed"
expect "Heroic Strike hits" "heroic strike dealt damage"
expect " dies\." "a monster died"
expect "You gain .* experience" "xp awarded"
expect "You receive loot" "loot dropped and picked up"
expect "Quest accepted: Boar Trouble" "quest accepted from npc"
expect "Boar Trouble: Thornhill Boar slain: " "quest kill objective tracked"
expect "You buy Tough Jerky" "bought food from vendor"
n=$(grep -o "interest: [0-9]*" "$LOG_DIR/client.log" | head -1 | grep -o "[0-9]*")
total=$(grep -o "spawned [0-9]* monsters" "$LOG_DIR/server.log" | grep -o "[0-9]*")
if [ -n "$n" ] && [ "$n" -ge 5 ] && [ "$n" -lt "${total:-0}" ]; then echo "  ok   interest management: $n of $total monsters replicated to the client"; else echo "  FAIL interest management ($n of $total monsters replicated)"; fail=1; fi

if grep -qiE "error|warning" "$LOG_DIR/server.log" "$LOG_DIR/client.log"; then
  echo "  FAIL engine errors/warnings in logs:"; grep -iE "error|warning" "$LOG_DIR/server.log" "$LOG_DIR/client.log"; fail=1
else
  echo "  ok   no engine errors or warnings"
fi

[ $fail -eq 0 ] && echo "[smoke] PASSED" || { echo "[smoke] FAILED (logs in $LOG_DIR)"; exit 1; }
