#!/usr/bin/env bash
# phased gate — the objective "done" check. Owns .phased/state.json transitions.
#
#   gate.sh              SubagentStop hook: run the build/test gate; block the
#                        phase subagent from returning until the gate is green.
#   gate.sh --backstop   Stop hook: keep the lead session from quitting while
#                        a phased run still has phases remaining.
#
# Hook contract: JSON on stdout is only honored on exit 0, so every path here
# prints its JSON (if any) and exits 0. Never exit non-zero.
set -u

MODE=gate
case "${1:-}" in
  --backstop) MODE=backstop ;;
  --worker-start) MODE=worker_start ;;
esac

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || INPUT='{}'

# Work from the project root.
[ -n "${CLAUDE_PROJECT_DIR:-}" ] && cd "$CLAUDE_PROJECT_DIR" 2>/dev/null

STATE=.phased/state.json

# Not a phased run in progress → stay out of the way entirely.
[ -f "$STATE" ] && [ -f .phased/active ] || exit 0

if ! command -v jq >/dev/null 2>&1; then
  # Can't parse hook input or edit state safely. Warn (gate mode) but never block.
  if [ "$MODE" = gate ]; then
    echo '{"systemMessage":"phased: jq not found — the gate cannot run. Install jq, or verify phases manually."}'
  fi
  exit 0
fi

# Small helpers: read from / atomically rewrite state.json.
squery() { jq -r "$1" "$STATE" 2>/dev/null; }
supdate() { jq "$@" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; }

# ------------------------------------------------------------ worker-start --
# SubagentStart: record in-phase fan-out workers (anything that isn't the
# orchestrator) so the statusline can show what the phase is working on.
# Display-only state; lost updates under heavy parallel spawn are fine.
if [ "$MODE" = worker_start ]; then
  AGENT=$(jq -r '.agent_type // empty' <<<"$INPUT")
  ID=$(jq -r '.agent_id // empty' <<<"$INPUT")
  if [ -n "$AGENT" ] && [ -n "$ID" ] && [[ "$AGENT" != *phase-orchestrator* ]]; then
    if supdate --arg id "$ID" --arg t "$AGENT" '.workers = ((.workers // []) + [{id: $id, type: $t}])' 2>/dev/null; then
      # Announce in the transcript so in-phase activity is visible on screen.
      CNT=$(squery '(.workers // []) | length')
      PH=$(squery '.current')
      jq -cn --arg m "⚙ Phase $PH · worker up: $AGENT ($CNT active)" '{systemMessage: $m}'
    fi
  fi
  exit 0
fi

# ---------------------------------------------------------------- backstop --
if [ "$MODE" = backstop ]; then
  # Infinite-loop guard: never re-block a continuation this hook caused.
  [ "$(jq -r '.stop_hook_active // false' <<<"$INPUT")" = "true" ] && exit 0
  # A failed phase means the run halted for manual review — let the lead stop.
  [ "$(squery '[.phases[] | select(.status=="failed")] | length')" -gt 0 ] 2>/dev/null && exit 0
  remaining=$(squery '[.phases[] | select(.status=="pending" or .status=="running")] | length')
  if [ "${remaining:-0}" -gt 0 ] 2>/dev/null; then
    jq -cn '{decision: "block", reason: "A phased run is still active with phases remaining (see .phased/state.json). Continue the /phased:run loop: spawn the phase-orchestrator subagent for the current phase. If the run is genuinely over, delete .phased/active first, then stop."}'
  fi
  exit 0
fi

# -------------------------------------------------------- gate (SubagentStop) --

# Only gate the phase-orchestrator. When the event identifies the agent, ignore
# stops from fan-out workers; when it doesn't, gate every subagent stop (safe:
# a redundant green gate is a no-op, see the pending note below for the rest).
AGENT=$(jq -r '.agent_type // .subagent_type // .agent_name // empty' <<<"$INPUT")
if [ -n "$AGENT" ] && [[ "$AGENT" != *phase-orchestrator* ]]; then
  # A fan-out worker finished — drop it from the live worker list, don't gate.
  ID=$(jq -r '.agent_id // empty' <<<"$INPUT")
  if [ -n "$ID" ]; then
    BEFORE=$(squery '(.workers // []) | length')
    supdate --arg id "$ID" '.workers = [(.workers // [])[] | select(.id != $id)]' 2>/dev/null
    AFTER=$(squery '(.workers // []) | length')
    if [ "${BEFORE:-0}" -gt 0 ] 2>/dev/null && [ "${AFTER:-1}" = 0 ]; then
      jq -cn --arg m "⚙ Phase $(squery '.current') · all workers finished" '{systemMessage: $m}'
    fi
  fi
  exit 0
fi

N=$(squery '[.phases[] | select(.status=="running")][0].n // empty')
[ -n "$N" ] || exit 0   # nothing in flight

TITLE=$(jq -r --argjson n "$N" '[.phases[] | select(.n == $n)][0].title // ""' "$STATE")
ATTEMPTS=$(jq -r --argjson n "$N" '[.phases[] | select(.n == $n)][0].attempts // 0' "$STATE")
CAP=$(squery '.cap // 6')

# Gate command precedence: PHASED_GATE env → state.json .gate → Go default.
GATE_CMD=${PHASED_GATE:-}
[ -n "$GATE_CMD" ] || GATE_CMD=$(squery '.gate // empty')
[ -n "$GATE_CMD" ] || GATE_CMD="go build ./... && go test ./..."

# Project-scoped log: a shared /tmp path gets clobbered by other runs, and an
# unwritable one would turn a passing gate into a failure at the redirection.
LOG=.phased/gate.log

# Phase spend so far, recorded by statusline.sh into cost.json (empty if the
# statusline isn't configured — it is the only place Claude Code exposes cost).
phase_cost() {
  [ -f .phased/cost.json ] || return 0
  jq -r --arg n "$N" '(.phases[$n] // {}) as $p
    | (($p.last // $p.end // $p.start // 0) - ($p.start // 0))
    | if . > 0.005 then " (~$\(. * 100 | round / 100))" else "" end' .phased/cost.json 2>/dev/null
}

# ponytail: no lock around the gate; state writes are atomic (tmp+mv) and
# concurrent SubagentStops are rare — add a mkdir lock if double-runs ever bite.
if bash -c "$GATE_CMD" >"$LOG" 2>&1; then
  COST=$(phase_cost)
  NEXT=$(jq -r --argjson n "$N" '[.phases[] | select(.n > $n and .status=="pending")] | sort_by(.n) | .[0].n // empty' "$STATE")
  if [ -n "$NEXT" ]; then
    NEXT_TITLE=$(jq -r --argjson n "$NEXT" '[.phases[] | select(.n == $n)][0].title // ""' "$STATE")
    # The next phase stays "pending" here; the run loop flips it to "running"
    # when it actually spawns the orchestrator. That way a stray SubagentStop
    # between phases can never gate (and vacuously pass) work that hasn't started.
    supdate --argjson n "$N" --argjson next "$NEXT" \
      '.phases |= map(if .n == $n then .status = "passed" else . end) | .current = $next | .workers = []'
    jq -cn --arg m "✅ Phase $N ($TITLE) passed build + tests$COST → next: Phase $NEXT ($NEXT_TITLE)" '{systemMessage: $m}'
  else
    supdate --argjson n "$N" '.phases |= map(if .n == $n then .status = "passed" else . end) | .workers = []'
    jq -cn --arg m "✅ Phase $N ($TITLE) passed build + tests$COST — all phases complete" '{systemMessage: $m}'
  fi
  exit 0
fi

# Gate failed.
ATTEMPTS=$((ATTEMPTS + 1))
if ! supdate --argjson n "$N" --argjson a "$ATTEMPTS" '.phases |= map(if .n == $n then .attempts = $a else . end) | .workers = []'; then
  # Can't persist the retry counter → blocking would loop forever. Let it return.
  jq -cn --arg m "phased: could not write .phased/state.json — gate not enforced this stop. Fix permissions and re-run /phased:run." '{systemMessage: $m}'
  exit 0
fi

if [ "$ATTEMPTS" -lt "$CAP" ]; then
  TAIL=$(tail -n 40 "$LOG" 2>/dev/null)
  jq -cn --arg r "Phase $N ($TITLE) gate failed (attempt $ATTEMPTS/$CAP). Gate command: $GATE_CMD

You may not finish until the gate passes. Fix these failures, re-run the gate yourself to confirm, then finish:

$TAIL" '{decision: "block", reason: $r}'
else
  supdate --argjson n "$N" '.phases |= map(if .n == $n then .status = "failed" else . end)'
  COST=$(phase_cost)
  jq -cn --arg m "✗ Phase $N ($TITLE) failed the gate after $ATTEMPTS attempts$COST — halting for manual review (full log: $LOG)" '{systemMessage: $m}'
fi
exit 0
