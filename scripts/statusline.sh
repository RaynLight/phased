#!/usr/bin/env bash
# phased statusline — one line for the TUI status bar (one ▓ per passed phase):
#   phased ▓░░░░ 2/5 · API routes · running · ⚙2 general-purpose · $0.31 (run $1.12)
# Runs on every tick, so it stays cheap. Session JSON arrives on stdin but has
# no phase info; progress is read from .phased/state.json on disk.
# Cost: Claude Code exposes live session cost ONLY here (stdin .cost.total_cost_usd),
# so this script is also the cost recorder — sole writer of .phased/cost.json.
set -u

input=$(cat 2>/dev/null || true)

have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

dir=""
if [ "$have_jq" -eq 1 ] && [ -n "$input" ]; then
  dir=$(jq -r '.workspace.current_dir // .cwd // empty' <<<"$input" 2>/dev/null)
fi
[ -n "$dir" ] && [ -d "$dir" ] || dir=$PWD

state="$dir/.phased/state.json"
[ -f "$state" ] || exit 0

cur="" total="" passed_ct="" title="" status="" wcount="" wtype=""
if [ "$have_jq" -eq 1 ]; then
  # Unit-separator join, not @tsv: tab is IFS whitespace (empty fields collapse)
  # and @tsv escapes backslashes/tabs into literal \-sequences.
  IFS=$'\x1f' read -r cur total passed_ct title status wcount wtype < <(
    jq -r '. as $s
      | ([$s.phases[] | select(.n == $s.current)][0] // {}) as $p
      | ($s.workers // []) as $w
      | [$s.current, $s.total,
         ([$s.phases[] | select(.status == "passed")] | length),
         ($p.title // ""), ($p.status // "pending"),
         ($w | length),
         ($w | if length > 0 then .[length-1].type else "" end)]
      | map(tostring) | join("\u001f")' "$state" 2>/dev/null
  )
else
  # ponytail: crude fallback without jq — state.json is jq-pretty-printed, one key per line.
  cur=$(sed -n 's/.*"current"[^0-9]*\([0-9][0-9]*\).*/\1/p' "$state" | head -n1)
  total=$(sed -n 's/.*"total"[^0-9]*\([0-9][0-9]*\).*/\1/p' "$state" | head -n1)
  passed_ct=$(grep -c '"passed"' "$state" 2>/dev/null || true)
fi

case "$cur" in '' | *[!0-9]*) exit 0 ;; esac
case "$total" in '' | *[!0-9]* | 0) exit 0 ;; esac
case "$passed_ct" in '' | *[!0-9]*) passed_ct=0 ;; esac

# ---- per-phase cost, from the session cost in the statusline feed ----------
phase_cost="" run_cost="" usd=""
if [ "$have_jq" -eq 1 ] && [ -n "$input" ]; then
  usd=$(jq -r '.cost.total_cost_usd // empty' <<<"$input" 2>/dev/null)
fi
if [ -n "$usd" ]; then
  costfile="$dir/.phased/cost.json"
  [ -f "$costfile" ] || printf '{}' > "$costfile" 2>/dev/null
  costout=$(jq -r --arg n "$cur" --argjson usd "$usd" --arg st "$status" '
    .phases //= {}
    # Freeze the spend of phases that are no longer current — at this fresh
    # $usd, not the stale .last: the gate advances .current before this tick
    # runs, so the final-turn cost of the finished phase only surfaces here.
    # end = last would silently drop it from the phase and run totals.
    # max() guards a session-cost reset (usd below last).
    | .phases |= with_entries(
        if .key != $n and (.value.end // null) == null and (.value.last // null) != null
        then .value.end = ([.value.last, $usd] | max) else . end)
    | .phases[$n] //= {}
    # A current phase that is active again but has an end was resumed after a
    # failure — drop the stale end so the retry accrues and a repass re-stamps.
    | (if ($st != "passed" and $st != "failed") then del(.phases[$n].end) else . end)
    # Baseline at first sight of the phase; re-baseline if the session counter
    # reset — but never a finished phase (end still set after the del above):
    # a later session ticks this script with a near-zero usd, and rewriting the
    # frozen start would inflate end - start into nonsense.
    | (if (.phases[$n].start // null) == null
          or ((.phases[$n].end // null) == null and .phases[$n].start > $usd)
       then .phases[$n].start = $usd else . end)
    | (if ($st == "passed" or $st == "failed") and (.phases[$n].end // null) == null
       then .phases[$n].end = $usd
       elif ($st != "passed" and $st != "failed") then .phases[$n].last = $usd
       else . end)
    | . as $c
    | ([0, ($c.phases[$n] | ((.end // .last // .start) - .start))] | max) as $pc
    | ([$c.phases[] | ([0, ((.end // .last // .start) - .start)] | max)] | add // 0) as $rc
    | "\($pc)\u001f\($rc)", tojson' "$costfile" 2>/dev/null)
  if [ -n "$costout" ]; then
    IFS=$'\x1f' read -r phase_cost run_cost <<<"${costout%%$'\n'*}"
    printf '%s' "${costout#*$'\n'}" > "$costfile.tmp.$$" 2>/dev/null && mv "$costfile.tmp.$$" "$costfile" 2>/dev/null
    phase_cost=$(LC_ALL=C printf '%.2f' "$phase_cost" 2>/dev/null || printf '%s' "$phase_cost")
    run_cost=$(LC_ALL=C printf '%.2f' "$run_cost" 2>/dev/null || printf '%s' "$run_cost")
  fi
fi

width=$total
[ "$width" -gt 10 ] && width=10
filled=$((width * passed_ct / total))
[ "$filled" -gt "$width" ] && filled=$width

bar="" i=0
while [ "$i" -lt "$width" ]; do
  if [ "$i" -lt "$filled" ]; then bar="${bar}▓"; else bar="${bar}░"; fi
  i=$((i + 1))
done

reset=$'\033[0m'
case "$status" in
  running) color=$'\033[33m' ;;
  passed)  color=$'\033[32m' ;;
  failed)  color=$'\033[31m' ;;
  *)       color="" reset="" ;;
esac

line="phased $bar $cur/$total"
[ -n "$title" ] && line="$line · $title"
[ -n "$status" ] && line="$line · ${color}${status}${reset}"
# In-phase fan-out workers, tracked by the SubagentStart/Stop hooks; the gate
# clears the list at every phase boundary, so this collapses automatically.
case "$wcount" in '' | *[!0-9]*) wcount=0 ;; esac
[ "$wcount" -gt 0 ] && line="$line · ⚙${wcount} ${wtype:-worker}"
[ -n "$phase_cost" ] && line="$line · \$${phase_cost} (run \$${run_cost})"
printf '%s\n' "$line"
