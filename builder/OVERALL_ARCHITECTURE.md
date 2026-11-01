# Archer Custom Code Pipeline — Overall Architecture

`BUILD_PIPELINE.md` in this folder documents the middle box only — the scripted
`run_pipeline.ps1` run itself. This document frames that box inside the full, recurring
workflow it sits in: a human-and-AI whiteboarding stage before it, and a live
implementation/testing stage after it, closed into a loop by an ongoing review step that
decides what gets built next.

## Summary

Each tool in this toolkit moves through three stages, with a different role doing the
work at each one:

1. **Pre-build (whiteboarding).** Claude Sonnet 5, run at **High** reasoning effort,
   acts as the whiteboarding assistant. It talks the tool idea through with the user
   interactively, then writes the finished result as a functional spec file in
   `blueprints_library/`, registers it in `manifest.json`, and points
   `Start_Build.bat`'s `-Spec` argument at it.
2. **The build pipeline.** `run_pipeline.ps1` takes that spec and runs it through five
   scripted tasks — Opus build, CODEX Broadhead-only review, Gemini quality audit,
   Sonnet UAT/Support Review, and packaging — with no human step in between. This is the
   one deterministic, repeatable box in the workflow; see `BUILD_PIPELINE.md` for its
   full internals.
3. **Post-build (live implementation and testing).** Claude takes the pipeline's
   reviewed output and drives the Archer NFR instance live, under its own dedicated NFR
   account, to create or update the Classic iView and NGRX dashboard/widget shells,
   deploy `blueprint_merged.js` to both hosts (byte-verified), wire the Admin Tools
   Launcher entry, and live-test the tool on both hosts against real NFR data — the
   thing the pipeline itself never does.

Closing the loop: rather than automating live testing into the pipeline, this project
deliberately keeps a human-paced review step after Stage 3. The pipeline's own written
output (`audit_report.txt`, `support_review_pane.md`) is read together with whatever
live testing on NFR actually found, and that decides what happens next — a real defect
sends the same tool back to Stage 2 (fix the blueprint, rebuild under the next build id,
e.g. `rff5` → `rff6`); a clean, confirmed tool sends the project back to Stage 1 to
whiteboard the next one. This is what keeps the pipeline "always running" — it is never
really finished with one tool before the next is already being whiteboarded.

## Diagram

```
┌────────────────────────────────────────────────────────────────────────┐
│ STAGE 1 — PRE-BUILD                                                     │
│ Role: Claude Sonnet 5 (High reasoning effort) — Whiteboarding Assistant │
│                                                                          │
│  • Talks through a new tool idea with the user, interactively          │
│  • Writes the finished functional spec to blueprints_library/          │
│  • Registers it in blueprints_library/manifest.json                    │
│  • Points Start_Build.bat's -Spec argument at it                       │
└──────────────────────────────────┬───────────────────────────────────-─┘
                                    │  functional spec, ready to build
                                    ▼
┌──────────────────────────────────────────────────────────────────────-─┐
│ STAGE 2 — THE BUILD PIPELINE  (run_pipeline.ps1 — see BUILD_PIPELINE.md)│
│ Role: scripted, deterministic orchestration — no human in the loop     │
│                                                                          │
│   Task A  Claude Opus          →  builds the merged file               │
│   Task B  CODEX (gpt-6-luna)   →  reviews the Broadhead section only   │
│   Task C  Gemini 4 Argon       →  independent quality-gate audit       │
│   Task D  Claude Sonnet        →  Support Reviewer / UAT report        │
│   Task E  Compress-Archive     →  packages the deliverable             │
└──────────────────────────────────┬────────────────────────────────────┘
                                    │  reviewed blueprint_merged.js +
                                    │  audit_report.txt + support_review_pane.md
                                    ▼
┌──────────────────────────────────────────────────────────────────────-─┐
│ STAGE 3 — POST-BUILD                                                    │
│ Role: Claude, driving the browser live on the NFR instance             │
│                                                                          │
│  • Creates/updates the Classic iView + NGRX dashboard/widget shells     │
│  • Deploys blueprint_merged.js to both hosts, byte-verifies it          │
│  • Wires the Admin Tools Launcher entry                                │
│  • Live-tests the tool on both Classic and NGRX against real NFR data  │
└──────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
                 REVIEW & DECIDE THE NEXT STEP   (ongoing loop)
   Read the pipeline's own output (audit_report.txt, support_review_pane.md)
   together with what live-testing on NFR found, and decide:

     → real defect found:   fix the blueprint spec, re-run the pipeline
                             (same tool, next build id)  ───────▶  back to STAGE 2

     → clean + confirmed:   whiteboard the next tool    ───────▶  back to STAGE 1
```
