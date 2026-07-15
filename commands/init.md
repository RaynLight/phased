---
description: Scaffold phases/ with a phase-doc template
argument-hint: [feature name]
---

Scaffold the phase-doc convention for this project. Feature name (optional): $ARGUMENTS

1. If `phases/` already contains `.md` files, do **nothing destructive**: list the existing files with their first headings, and remind the user that `/phased:run` executes them in order. Stop.
2. Otherwise create `phases/` and write `phases/phase-01.md` with exactly this template — if a feature name was given, use it as the short title:

```markdown
# Phase 1 — <short title>

## Goal
<what this phase delivers, in 1–3 sentences>

## Scope
- In scope: ...
- Out of scope: ...

## Steps
1. ...
2. ...

## Definition of Done
- [ ] `go build ./...` passes
- [ ] `go test ./...` passes
- [ ] <phase-specific acceptance checks>
```

3. Then tell the user, briefly: add more phases as `phase-02.md`, `phase-03.md`, … (zero-padded so they sort), keep a Definition of Done in each, and run `/phased:run` when ready. The gate defaults to `go build ./... && go test ./...` — override it with the `PHASED_GATE` env var (which takes precedence while set) or by editing `gate` in `.phased/state.json` after the run starts (see the plugin README for other stacks).
