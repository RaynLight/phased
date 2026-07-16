---
description: Run all phase docs in phases/ sequentially — one fresh subagent per phase, gated by build + tests
---

You are the lead orchestrator for a phased run. Execute the phase documents in `phases/` strictly in order, one at a time. You never implement phase work yourself — each phase runs inside its own `phase-orchestrator` subagent. You never decide a phase passed — the SubagentStop gate hook runs the build/test gate and writes the verdict into `.phased/state.json`.

Stay cheap: you are a coordinator, not a reader. Never read project source files, and do not read phase docs in full — extract each doc's title and any `Mode:` line with a single shell command (`sed -n '1,5p'` or grep), nothing more. The orchestrator reads its own phase doc. The one exception is a `Mode: workflow` phase, where authoring the workflow script requires reading that doc.

## 1. Discover or resume

- If `.phased/state.json` exists and **every** phase is `passed`: check whether `phases/*.md` contains files not tracked in `state.json`. If so, append them as new `pending` entries (continuing `n`, updating `total`) and proceed with the loop; otherwise say the run is already complete and stop. Never rebuild or re-run existing entries.
- If it exists and any phase is not `passed`: **resume** — do not restart or re-run passed phases. If a phase is `failed`, reset it to `pending` with `attempts: 0` (the user re-running means: retry it).
- Only if there is no `.phased/state.json`, start fresh: glob `phases/*.md` and natural-sort the filenames. If `phases/` is missing or empty, tell the user to run `/phased:init` first, and stop. Then write `.phased/state.json` (create the `.phased/` directory):
  - `gate`: `$PHASED_GATE` if that env var is set, else `go build ./... && go test ./...`
  - `current`: 1 · `total`: number of phase files · `cap`: 6
  - `phases`: one entry per file, in order:
    `{ "n": <1-based index>, "file": "phases/<name>.md", "title": "<first '# ' heading, minus any 'Phase N —' prefix>", "status": "pending", "attempts": 0 }`
- Create the sentinel: `touch .phased/active` (the Stop backstop hook uses it).

## 2. Todos — the on-screen phase board

The task list is the user's live phase board in the TUI. Maintain it for the entire run with the task tools — `TaskCreate` / `TaskUpdate` (on older Claude Code versions the equivalent is `TodoWrite`; use whichever your session has). One of these is always available — never skip this step, even for one-phase runs.

- Create one task per phase up front. Pending phases: `Phase <n>: <title>`.
- When a phase starts, set its task to `in_progress` and retitle it `Phase <n>/<total>: <title>`. Only if the phase will fan out or run a workflow, append ` — fan-out` or ` — workflow`; plain phases get no mode tag.
- The moment a phase passes, mark its task completed AND retitle it `Phase <n>: <title> — $<cost> · <k> attempt(s)` — cost is `(end // last) - start` for that phase from `.phased/cost.json` (omit the `$` part if that file doesn't exist), `<k>` is `attempts + 1`. If the phase has no `end` yet, its cost is still settling (the statusline writes `end` on its next tick) — show it as `~$<cost>`, never as exact; if it has no cost.json entry at all, omit the `$` part.
- If a phase fails, retitle it `Phase <n>: <title> — ✗ failed after <attempts> attempts`.
- When resuming, create already-passed phases as completed, with their costs if recorded.

## 3. The loop

While any phase has status `pending` or `running`, take the lowest such `n`:

1. Update `.phased/state.json`: set that phase's `status` to `"running"` and `current` to `n` (use `jq` via Bash; write to a temp file and `mv` over). Mark its todo in_progress.
2. **Workflow-mode phases.** If the phase doc contains a `Mode: workflow` line (or explicitly requests a dynamic workflow) AND you have the Workflow tool (subagents don't — running it is your job, not the orchestrator's):
   - Update the phase's board row activeForm to `Phase <n>: <title> — workflow · <N> pieces`.
   - Author and run a Workflow script directly from the doc's independent pieces — one `agent()` per piece, run in parallel. Every agent prompt must carry that piece's full spec from the doc, the project's conventions, and "write the piece's test and make sure it passes". Skeleton:
     ```js
     export const meta = { name: 'phase-<n>', description: '<title>', phases: [{ title: 'Implement' }] }
     const out = await parallel([
       () => agent('<full spec of piece 1>', { label: '<piece 1>' }),
       // ... one thunk per piece
     ])
     return out.filter(Boolean)
     ```
   - When it returns, proceed to step 3 as usual, but add to the orchestrator's prompt: "A dynamic workflow already implemented these pieces: <one line per piece from the results>. Verify against the phase doc, integrate, and fix any gaps — do not reimplement what is already correct. The gate hook verifies when you finish."
   - If you don't have the Workflow tool, skip all of this and treat it as a normal phase (the orchestrator will fan out itself).
3. Spawn the **`phase-orchestrator`** subagent and **wait for it to finish** — never run phases in parallel. Its prompt must include:
   - the phase file path (the path only — never paste the doc's contents; the orchestrator reads it itself),
   - the effective gate command (`$PHASED_GATE` if set — it overrides everything — else `gate` from `state.json`),
   - your accumulated short summaries of all previous phases (this is the cross-phase thread),
   - the task id of this phase's board row (so the orchestrator can post live `⚙ <done>/<total> workers done` progress into its activeForm),
   - a reminder that if it fans out, it must board its workers as `└ ⚙ …` task rows (max 4 at once, rollup row for bigger batches) and delete each row when that worker returns.
4. When it returns, **re-read `.phased/state.json`** — the gate hook has updated it. Do not run the gate yourself; the hook enforces it so the result can be trusted.
   - `passed` → mark the task completed (with the cost/attempts retitle from §2). Then run TaskList and set any task whose subject starts with `└ ⚙` to status `deleted` — worker rows must never outlive their phase. Keep the subagent's summary, continue with the next phase.
   - `failed` → delete `.phased/active`, then report: which phase failed, after how many attempts, that the gate log is at `.phased/gate.log`, and that the user should review and re-run `/phased:run` to retry. Stop.
   - still `running` (the hook recorded no verdict — rare) → run the gate command once yourself via Bash. If it passes, set the phase to `passed`, advance `current`, and continue; if not, increment the phase's `attempts` in `state.json` yourself and spawn the orchestrator again for this same phase — and once `attempts` reaches `cap`, mark it `failed` and stop with the failure report instead of respawning.

## 4. Finish

When every phase is `passed`: delete `.phased/active`, mark all todos completed, and print a short summary — one line per phase (✓ title, attempts used, and its cost from `.phased/cost.json` if that file exists) plus the total count and total cost. Per-phase cost is `(end // last) - start`; a phase without `end` (usually the final one — the statusline stamps it a tick after the gate) gets `~$<cost>`, and the run total gets `~` too if any component did. Nothing else.
