---
description: Show a detailed dashboard of the current phased run
---

Read `.phased/state.json` in the project root, plus `.phased/cost.json` if it exists.

- If there is no state file: say there is no phased run here, and that `/phased:init` scaffolds phase docs and `/phased:run` starts a run. Stop.
- Otherwise print exactly this dashboard, nothing more:

```
phased · <feature, or the project dir name> · gate: <gate>

  ✓ Phase 1: <title>             $0.08 · 1 attempt
  ▶ Phase 2: <title>             $0.11 so far · running
      ⚙ general-purpose
      ⚙ general-purpose
  ⏳ Phase 3: <title>
  ⏳ Phase 4: <title>

<passed>/<total> passed · run cost $<total> · <run active | no run in progress>
```

Rules:
- Glyphs: `✓` passed, `▶` running, `⏳` pending, `✗` failed (failed lines end `— failed after <attempts> attempts`).
- Cost per phase comes from `.phased/cost.json`: `(end // last) - start` for that phase's key; show `$X so far` for the running phase, plain `$X` for finished ones; omit cost fields entirely if cost.json is missing. Run cost = sum over phases. A finished (passed/failed) phase with no `end` key is still settling — the statusline stamps `end` on its next tick — so show it as `~$X`, and prefix the run cost with `~` too. A phase with no entry in cost.json at all was never ticked: omit its cost, don't invent one.
- Attempts shown as `attempts + 1` attempt(s) for passed phases; omit for pending.
- The `⚙` lines list `state.json` `.workers[].type`, one per worker, indented under the running phase only (omit when empty).
- `run active` if `.phased/active` exists, else `no run in progress`.
