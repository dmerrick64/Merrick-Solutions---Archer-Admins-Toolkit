# Archer Custom Code Pipeline — Build Pipeline Documentation

This document describes how `scripts/run_pipeline.ps1` turns a functional spec in
`blueprints_library/` into a reviewed, dual-UI (Classic + NGRX/Broadhead) Archer tool.
It is the reference for anyone (human or AI) picking up this repo cold.

## 1. Purpose

Every Admin Tools / DDE Utilities / End User tool in this repo is built the same way:
one functional spec goes in, one merged JavaScript file comes out, reviewed by three
independent AI passes plus a scripted set of deterministic guardrails before a human
ever live-tests it on the Archer NFR instance. The pipeline exists to catch the class of
failure that an LLM alone tends to miss — truncation, duplication, silent scope
creep — by pairing each AI step with a cheap, deterministic check that doesn't depend on
any model "noticing" anything.

## 2. Pipeline at a glance

```
blueprints_library/manifest.json  →  spec selected  →  functional_spec.md (hash-stamped)
        │
        ▼
 TASK A  Claude Opus (Claude Code CLI, --print)           → src/blueprint_merged.js
        builds ONE merged file: shared core + Classic adapter + Broadhead adapter
        │
        ▼
 TASK B  CODEX (OpenAI API, model gpt-6-luna)              → src/blueprint_merged.js (patched)
        reviews/corrects ONLY the [F] BROADHEAD ADAPTER section, spliced back in
        │
        ▼
 TASK C  Gemini 4 Argon (Google GenAI SDK, python)         → audit_report.txt
        independent quality-gate audit of the full merged file against the spec
        │
        ▼
 TASK D  Claude Sonnet (Claude Code CLI, --print)          → support_review_pane.md
        acts as the internal "Archer Support Reviewer" — practical-usability UAT
        │
        ▼
 TASK E  PowerShell Compress-Archive                       → dist/archer_output_package.zip
        zips blueprint_merged.js + docs/*.md + support_review_pane.md
        │
        ▼
 (manual, outside this script) live test on NFR, create/update Classic iView +
 NGRX dashboard/widget, wire the Admin Tools Launcher, deploy
```

Every build produces **one file** (`src/blueprint_merged.js`) containing a shared
business-logic core plus two adapters, not two separate Classic/Broadhead files. This
was a deliberate project-wide decision (see §4) so that both UIs always ship from a
single deployed artifact and can never silently drift apart.

## 3. Roles

| Task | Model / Tool | Invocation | Scope | Produces |
|---|---|---|---|---|
| A | Claude **Opus** | Claude Code CLI: `claude --model=opus --print "<prompt>" --dangerously-skip-permissions`, spec piped via stdin | Whole merged file (shared core + both adapters) | `src/blueprint_merged.js` |
| B | **CODEX** (OpenAI API, `gpt-6-luna`) | Direct REST call to `api.openai.com/v1/chat/completions` | Only the `[F] BROADHEAD ADAPTER` ... `END [F] BROADHEAD ADAPTER` section, extracted and sent alone | Corrected Broadhead section, spliced back into the same file |
| C | **Gemini 4 Argon** | `python scripts/run_gemini_audit.py`, Google GenAI SDK | Whole merged file + spec, read-only audit | `audit_report.txt` |
| D | Claude **Sonnet** | Claude Code CLI: `claude --model=sonnet --print "<prompt>" --dangerously-skip-permissions` | Whole merged file + spec, acting as "Archer Support Reviewer" persona | `support_review_pane.md` |
| E | PowerShell `Compress-Archive` | Native cmdlet, no AI | — | `dist/archer_output_package.zip` |

### Task A — Claude Opus, the builder

Runs via the `claude` CLI, not the API, so it inherits two things automatically just by
running in this directory:
- **`CLAUDE.md`** (Archer/NFR domain knowledge — API routes, NFR switching, test
  modules) is auto-loaded as context by the Claude Code CLI for any session started in
  this folder, Task A included. It is not referenced anywhere in `run_pipeline.ps1`
  itself — the CLI does this on its own.
- The **project's mandatory coding checklist** (hydration polling, `PageRequestManager`
  re-attachment, unbind-before-bind event idempotency, full IIFE + try/catch scope
  isolation) is restated explicitly inside Task A's system prompt in the script, so it
  applies even on machines/sessions where the project-level instructions aren't loaded.

Task A's system prompt (verbatim, from `run_pipeline.ps1`) requires:
- One shared business-logic core, implemented once, never duplicated between adapters.
- A `detectTransport()` check (`window.broadhead` / a Broadhead meta tag) choosing
  between a Classic adapter (`parent.parent.ArcherApp.globals`, bare `$.ajax`) and a
  Broadhead adapter (`window.broadhead.fetch(...).awaitResponse()`).
- Three literal, fixed-wording section banners — `[C] SHARED CORE`, `[E] CLASSIC
  ADAPTER`, `[F] BROADHEAD ADAPTER` (each with a matching `END [...]` close banner) —
  used verbatim, never renumbered as `[1]/[2]/[3]` even if the spec itself uses numbered
  headings. Every downstream check (Task B's extraction, the duplication guards) depends
  on these exact strings.
- The standing **dual self-gating requirement**: the tool's entry point must render as
  two independently-gated controls (a Classic control that mounts only when the Classic
  adapter's own self-check passes, an NGRX control that mounts only when the Broadhead
  adapter's self-check passes), never a single UI that assumes one environment — applied
  even when the spec doesn't call it out.
- No conversational preamble — a single clean code file only.

### Task B — CODEX, the Broadhead-only reviewer

"CODEX" here is the OpenAI API (`gpt-6-luna`) called directly via
`Invoke-RestMethod`, **not** a `codex` CLI. `AGENTS.md` in the repo root documents
CODEX's persona and compliance checklist for human reference, but it is **not read by
the pipeline at runtime** — the actual system prompt CODEX receives is the shorter
string hardcoded at `run_pipeline.ps1` line 537. Keep `AGENTS.md` and that inline prompt
in sync by hand if either changes.

Why CODEX only ever sees the Broadhead section, never the whole file:
- The pipeline previously sent the full merged file and asked CODEX to echo all of it
  back with only the Broadhead section changed. `gpt-4o`'s 16,384-output-token ceiling
  made that reliably truncate mid-file on real builds.
- Even after moving to `gpt-6-luna` (128,000-token ceiling, 8x headroom), the scoped
  extraction is kept: it's cheaper per call, and "don't touch anything else" becomes a
  **structural** guarantee — the script splices CODEX's reply back into the exact
  substring it extracted, so nothing outside that substring can be touched regardless of
  what CODEX returns.
- CODEX's compliance checklist (`AGENTS.md` / the inline prompt) forbids any
  same-origin/parent-window assumption (`window.parent`, `contentDocument`, etc.) because
  the Broadhead widget iframe is sandboxed without `allow-same-origin` — that's a real
  platform constraint, not a style preference.

### Task C — Gemini 4 Argon, the independent quality gate

`scripts/run_gemini_audit.py` reads `functional_spec.md` and `src/blueprint_merged.js`,
and asks Gemini to check three things, in order:
1. **Shared-core consistency** — do both adapters delegate to the same shared logic
   rather than reimplementing it independently?
2. **Broadhead isolation** — does the Broadhead section avoid `window.parent` /
   `contentDocument` / any same-origin assumption, routing everything through
   `window.broadhead` messaging instead? (The Classic section is expected to use
   `parent.parent.ArcherApp.globals` — that's correct there and not flagged.)
3. **Classic guardrail audit** — error handling, IIFE wrapping, `add_endRequest`
   lifecycle hooks in the Classic section.

This is the only task that reads the *whole* file and is explicitly asked to compare the
two adapters against each other, which is why it runs independently of (after) Task B
rather than folded into it.

### Task D — Claude Sonnet, the Support Reviewer (UAT)

Runs the same way Task A does (Claude Code CLI, same working directory, so `CLAUDE.md`
context applies here too) but as a distinct persona: the **internal Archer Support
Reviewer**, evaluating practical usability rather than code correctness. It's explicitly
told to confirm the dual-UI self-gating requirement itself as part of its review, and to
flag it as a finding if the two controls aren't properly independent. Its report is a
fixed 6-part structure (see `support_review_pane.md` for the live template):
1. Overall verdict
2. Dual-UI requirement: Classic/NGRX self-gating
3. Admin walkthrough: what a user will experience
4. Failure modes and support burden
5. Wording and clarity issues
6. Recommendations before deploy

The prompt explicitly tells the model to **print** its report rather than write the file
itself, because a model using its own file-write tool races the script's own output
redirect and can leave `support_review_pane.md` empty or stubbed (see §7).

### Task E — packaging

Plain PowerShell, no AI. Zips `src/blueprint_merged.js`, every `docs/*.md`, and
`support_review_pane.md` into `dist/archer_output_package.zip`. Fails loudly (rather
than reporting success) if the zip doesn't actually land on disk afterward.

## 4. Key decisions and why

| Decision | Why |
|---|---|
| **One merged file**, not separate Classic/Broadhead files | Both UIs must always ship from a single deployed artifact so they can't drift apart; this is now a standing requirement applied to every tool regardless of what the spec says. |
| **CODEX reviews only the Broadhead section** | History of silent truncation at `gpt-4o`'s 16,384-token ceiling; scoping the request also makes "don't touch the rest" structural rather than CODEX's responsibility to get right. |
| **Spec piped via stdin to `claude`**, not passed as a CLI argument | Two Windows failure modes: `claude.cmd`'s shim re-dispatches through `cmd.exe` (~8,191-char command-line cap, far below a ~24k-char spec), and PowerShell's own argument-quoting desyncs around embedded double quotes in markdown. Piping has neither limit and matches Claude Code's own documented stdin pattern. |
| **Manifest-driven spec selection** (`blueprints_library/manifest.json`), not "just pick the newest file in the folder" | Makes `-Spec <id>` stable and explicit, independent of file-creation order or renames; auto-bootstraps from `*.md` files if the manifest is ever missing. |
| **`functional_spec.md` is SHA-256-stamped** (`<!-- ACTIVE SPEC MANIFEST ... -->` header) at promotion time, and re-verified before Tasks A and D | Stops a stale or hand-edited spec from silently reaching a downstream AI — if the file on disk doesn't hash-match what was promoted, the pipeline aborts rather than building against drifted instructions. |
| **CODEX's system prompt is hardcoded in the script**, while `AGENTS.md` documents the same persona for humans | `AGENTS.md` predates (and is more detailed than) the current scoped-extraction approach and is not re-read by the script — it's reference material, kept for a human/future-AI reader, not a live config file. Treat the inline prompt at `run_pipeline.ps1:537` as the source of truth; update `AGENTS.md` by hand if it changes. |
| **`-ResumeFromTaskB` switch** | Added after a real build (`cob2`) where Task A's real output was already correctly written to `src/blueprint_merged.js` on disk (Task A has real file-write tools via `--dangerously-skip-permissions`, and chose to write directly rather than print a ~186KB file), but its *printed* reply was a short explanatory note that failed the banner check. `-ResumeFromTaskB` re-validates the existing file with the same checks a fresh Task A pass would have to pass, then continues from Task B — it never trusts the on-disk file blindly. |
| **Task D is told to print, not write its own file** | A model using its own file-write tool races the script's `> support_review_pane.md` redirect; this has actually produced an empty/stub file in a real run (`rm2`). The script also defends this with a length check (see §7). |

## 5. `scripts/run_pipeline.ps1` — step-by-step

1. **Spec selector gate.** Reads `blueprints_library/manifest.json` (bootstraps one from
   `*.md` filenames if missing). Resolves the chosen spec from `-Spec <id>` (preferred),
   `-AutoSelect <n>` (numeric, order-dependent — warned against for unattended use), or
   an interactive numbered prompt if neither is given.
2. **Promote + stamp.** Copies the chosen blueprint's body into `functional_spec.md`
   with a SHA-256 hash stamp, then immediately re-reads and re-hashes it to confirm
   nothing changed in transit (`Write-ActiveSpec` / `Confirm-ActiveSpec`).
3. **Task A** (skipped if `-ResumeFromTaskB`). Calls Opus via stdin, captures stdout
   (re-joined with real newlines — see §7), writes the raw, unrepaired output to
   `task_a_raw_output.txt`, runs the collapse/duplication guards and repair functions,
   then writes `src/blueprint_merged.js`.
4. **Task B.** Re-reads `src/blueprint_merged.js` as a single undecorated string (see
   §7 for why), extracts exactly the `[F] BROADHEAD ADAPTER` block by regex, POSTs it
   alone to `gpt-6-luna`, checks `finish_reason` and response length, then splices the
   reviewed section back into the exact substring it came from. The pre-review copy is
   saved as `src/blueprint_merged.task_a.js`.
5. **Task C.** Shells out to `python .\scripts\run_gemini_audit.py`, which writes
   `audit_report.txt`.
6. **Task D.** Calls Sonnet via the same CLI pattern, redirecting stdout straight to
   `support_review_pane.md`, then checks the file is long enough to be a real report.
7. **Task E.** Zips the deliverables to `dist\archer_output_package.zip`, verifying the
   zip actually exists afterward.

Any failed step calls `Write-Error` with the specific diagnosis and `exit 1` /
`exit $taskAExitCode` — the script is designed to abort loudly rather than continue with
a partially-good file.

## 6. How to run it

- **Normal use:** double-click the `Start_Build.bat` desktop shortcut. It `cd`s into the
  repo and runs:
  ```
  powershell -ExecutionPolicy Bypass -File ".\scripts\run_pipeline.ps1" -Spec <id>
  ```
  The `-Spec` id is hardcoded in `Start_Build.bat` and must be updated by hand to point
  at whichever blueprint is being built next (standing workflow step: update this as
  part of wrapping up each whiteboarding/spec-writing pass).
- **Manual / ad hoc:**
  ```
  .\scripts\run_pipeline.ps1 -Spec <id>                 # build a specific blueprint
  .\scripts\run_pipeline.ps1                             # interactive numbered menu
  .\scripts\run_pipeline.ps1 -AutoSelect <n>             # numeric index (order-dependent, not for unattended use)
  .\scripts\run_pipeline.ps1 -Spec <id> -ResumeFromTaskB # skip Task A, re-validate and reuse the existing src/blueprint_merged.js
  ```
- **Registering a new blueprint:** add an entry (`id`, `file`, `title`, `status`) to
  `blueprints_library/manifest.json` and drop the spec markdown at that `file` path in
  `blueprints_library/`.
- `claudecode.json` at the repo root holds a `Build` command string
  (`PowerShell ... -Spec dde_synchronization`) for editor/IDE integration — it is a
  convenience shortcut for one specific spec id and is **not** read by
  `run_pipeline.ps1` or `Start_Build.bat`; update it separately if kept.

## 7. Sanity checks and guardrails

Every one of these exists because of a specific, real failure on a prior build — they
are deterministic (string/count-based), not model-based, so they can't be talked past by
a plausible-sounding but wrong LLM response.

| Check | Catches | Real incident it traces to |
|---|---|---|
| `Confirm-NotCollapsed` | A multi-line file collapsed into one line with zero newlines (every `//` comment then swallows the rest of the file) | A 90,617-byte file with 84 `//` comments and 0 newlines, caused by capturing native stdout into a PowerShell array and piping it to `Out-File` with no re-join |
| `Get-SectionBannerCounts` / `Confirm-NotDuplicated` | The three required section banners not appearing exactly once each | Task A's `claude --print` call returning the entire file **twice** in one stdout stream (`rpf1`, 2026-10-21) |
| → banner-counting regex corrected twice | False-positive duplication aborts on a perfectly valid file whose own changelog prose happened to mention a banner's bracketed text | Two back-to-back valid builds (`rff5`, `rff6`) wrongly rejected before the regex was anchored to real banner lines only (leading `*` decoration, not just any line start) |
| `Repair-IfCleanDuplicate` | The specific "whole output emitted twice, byte-identical halves" pattern | Narrowly auto-repairs only that exact signature; anything else falls through to the abort above unchanged |
| `Repair-IfTaskAWroteFileDirectly` | Task A writing the real file straight to disk (it has file tools via `--dangerously-skip-permissions`) and printing an explanatory note instead of code, when the output is too large to return safely as text | `cob2` build, 186,073-byte file |
| Spec hash stamp (`Write-ActiveSpec` / `Confirm-ActiveSpec`) | `functional_spec.md` hand-edited or drifted between promotion and use | Structural safeguard against a stale/wrong spec silently reaching Task A or D |
| Banner-anchored regex reused for Task B's section extraction | Extracting 91% of the file (header-to-first-`/*`) instead of just the Broadhead section, because a plain `IndexOf()` matched a changelog sentence before the real banner | `rff6` build — CODEX's reply looked "implausibly short" only because the wrongly-extracted input was 10x too large |
| `finish_reason == "length"` check (Task B) | CODEX's reply silently truncated by the token ceiling | Pre-`gpt-6-luna` truncation at the `gpt-4o` 16,384-token ceiling, caught by Task C's Gemini audit after the fact |
| Reviewed-section length check (`< 30%` of input) | An empty or implausibly short CODEX reply | Defensive, same incident class as above |
| `ConvertTo-Json` via `-join ''` re-stringing | PowerShell 5.1's hidden ETS NoteProperties on `Get-Content -Raw` output serializing as a JSON object instead of a plain string, breaking the Task B API request body | Repeated "expected string but got object" errors from the OpenAI API, confirmed via `debug_task_b_request_body.json` |
| UTF-8 byte encoding for the Task B request body | System-codepage corruption of smart quotes/em dashes in generated code comments | `Invoke-RestMethod`'s default string encoding is not UTF-8 |
| `support_review_pane.md` length check (`< 1000` chars) | Task D's model using its own file-write tool and racing the script's output redirect, leaving a stub | `rm2` build, 2026-10-30 |
| `dist\archer_output_package.zip` existence check after `Compress-Archive` | Claiming a deliverable exists when the zip step actually failed | Defensive — fails loudly instead of printing a success banner for a missing file |

Debug/forensic artifacts left on disk after every run (safe to ignore on a clean build,
useful when one fails): `task_a_raw_output.txt`, `task_a_stderr.log`,
`debug_task_b_request_body.json`.

## 8. Generated artifacts — where output lands

| Path | What it is |
|---|---|
| `functional_spec.md` | The currently-promoted spec, hash-stamped |
| `src/blueprint_merged.js` | The final merged, reviewed tool (shared core + Classic adapter + Broadhead adapter) |
| `src/blueprint_merged.task_a.js` | Snapshot of Task A's output *before* Task B's Broadhead-section review |
| `task_a_raw_output.txt` | Task A's raw, unmodified stdout, before any repair/guard touches it |
| `task_a_stderr.log` | Task A's stderr (kept separate from stdout so a diagnostic can't land inside the generated code) |
| `debug_task_b_request_body.json` | The exact JSON body sent to the OpenAI API for Task B |
| `audit_report.txt` | Gemini's Task C quality-gate report |
| `support_review_pane.md` | Sonnet's Task D 6-part Support Reviewer report |
| `dist/archer_output_package.zip` | Final packaged deliverable (code + docs + review) |

None of these steps deploy anything to Archer. Live NFR testing, Classic iView / NGRX
dashboard+widget creation, and Admin Tools Launcher wiring are deliberate, separate,
interactive steps done by hand (sometimes with Claude driving the browser live) after a
clean pipeline run — not part of `run_pipeline.ps1`.

## 9. Required tooling outside the AI roles

To run this pipeline on a given machine, the following must be present/configured —
none of it is an AI model, all of it is a hard prerequisite:

- **Windows PowerShell 5.1** (the script relies on its specific `Get-Content -Raw`/
  `ConvertTo-Json`/encoding quirks — several guardrails exist *because* of 5.1-specific
  behavior, not despite it).
- **Claude Code CLI** (`claude`) installed and authenticated, with access to both the
  Opus and Sonnet models (`--model=opus`, `--model=sonnet`) and `--dangerously-skip-permissions` available.
- **Python 3** with the `google-genai` package installed, for `scripts/run_gemini_audit.py`.
- **`OPENAI_API_KEY`** environment variable — used directly by `run_pipeline.ps1` for
  the Task B REST call to `api.openai.com`.
- **`GEMINI_API_KEY`** environment variable — read implicitly by the `google-genai`
  client in `run_gemini_audit.py`.
- Network access to `api.openai.com` and the Google GenAI API endpoint.
- Git, for committing the repo (`.git` at the repo root).

## 10. What this pipeline deliberately does not do

- It does not deploy to Archer. Deployment (pasting into the Global iViews admin UI, the
  `IViews/Update` API, or an NGRX widget's Properties panel) is a manual/interactive step
  after a clean build.
- It does not create or wire the Classic iView, NGRX dashboard/widget shells, or the
  Admin Tools Launcher entry for a new tool — those are created by hand (or by Claude
  driving the Admin UI live) and then referenced by id in the spec/manifest.
- It does not live-test against the NFR instance. That is a separate, explicitly
  decided-against-automating step, done interactively after each pipeline run, looping
  back to a blueprint edit + re-run if live testing finds something.
