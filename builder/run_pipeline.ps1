param (
    [string]$Spec = "",
    [int]$AutoSelect = 0,
    [switch]$ResumeFromTaskB
)

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "   ARCHER INTERACTIVE CODE MANUFACTURING PIPELINE   " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# Recorded before anything else runs so Repair-IfTaskAWroteFileDirectly (below) can tell
# a file Task A just wrote THIS run from a stale one left over from a previous run.
$script:PipelineStartTime = Get-Date

# --- SPEC IDENTITY / INTEGRITY HELPERS ---
$StampStart = "<!-- ACTIVE SPEC MANIFEST"
$StampEnd   = "-->"

function Get-Sha256Hex {
    param([string]$Text)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hashBytes = $sha256.ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLower()
}

function Confirm-NotCollapsed {
    # Deterministic, cheap guard against a real prior bug: capturing a native command's
    # multi-line stdout into a variable splits it into an array of per-line strings, and
    # piping that straight into "Out-File -NoNewline" writes the elements back-to-back with
    # ZERO separator, silently collapsing an entire multi-line file into one unbroken line.
    # On a real run this produced a 90,617-byte file with 84 '//' line comments and ZERO
    # newline characters -- catastrophic for JavaScript specifically, since each '//' then
    # has no newline to terminate it and swallows everything after it to end-of-file. An
    # LLM-based audit (Task C) is not a reliable backstop for this: it reasons about code
    # semantically and can read right past a missing-newline defect without flagging it, as
    # happened on that run. This check doesn't depend on any model noticing anything -- it
    # just counts newline characters, so it can't miss this specific failure mode again.
    param([string]$Text, [string]$StageName, [string]$FilePath, [int]$MinNewlines = 20)
    $newlineCount = ([regex]::Matches($Text, "`n")).Count
    if ($newlineCount -lt $MinNewlines) {
        Write-Error "[ERROR] [$StageName] $FilePath has only $newlineCount newline character(s) for $($Text.Length) chars of content -- this is the exact signature of the prior line-collapse bug. A file this size should have far more line breaks than that. Aborting rather than writing/keeping a file that would corrupt every '//' line comment in it."
        exit 1
    }
}

# The three required sections, each delimited by a distinct open banner and close
# banner. IMPORTANT: for the Classic and Broadhead sections, the close banner's own
# text ("END [E] CLASSIC ADAPTER") contains the open banner's text ("[E] CLASSIC
# ADAPTER") as a literal substring -- a naive substring count of the open marker
# therefore ALWAYS reports 2 on a perfectly normal, single-copy file (one real open
# banner, plus one occurrence embedded inside its own close banner), which looks
# exactly like a true duplication but isn't one. Get-SectionBannerCounts below counts
# the close marker on its own (it never embeds inside anything else) and the open
# marker only where NOT immediately preceded by "END " (a negative lookbehind), so a
# clean single-copy file correctly reports Open=1/Close=1 for every section.
$script:MergedFileSections = @(
    @{ Open = "[C] SHARED CORE  (SHARED"; Close = "END [C] SHARED CORE" },
    @{ Open = "[E] CLASSIC ADAPTER";      Close = "END [E] CLASSIC ADAPTER" },
    @{ Open = "[F] BROADHEAD ADAPTER";    Close = "END [F] BROADHEAD ADAPTER" }
)

function Get-SectionBannerCounts {
    # CORRECTED 2026-10-25: the open-marker regex previously matched the marker text
    # ANYWHERE it appeared (other than right after "END "), including inside ordinary
    # prose. This produced a FALSE POSITIVE on the rff5 build (2026-10-25): its header
    # changelog accurately summarized the fix pass with a sentence like "Only [E] CLASSIC
    # ADAPTER changed; [C] SHARED CORE and [F] BROADHEAD ADAPTER are as delivered after
    # rff4's Task B pass." -- a correct, readable description, not a duplicated banner --
    # which the old regex counted as a second open occurrence (Open=2, Close=1), aborting
    # two back-to-back valid builds identically. A REAL open-banner marker only ever
    # appears as the first thing on its own line, after optional comment-decoration
    # characters (the " * " line-leader of the banner's ASCII box, or "/*"/"="); a prose
    # mention is always preceded by other words on the same line. Anchoring the match to
    # line-start (allowing only whitespace/"*"//"/"/"=" before the marker) accepts every
    # real banner and rejects a changelog sentence that merely names the section -- this
    # also makes the old "(?<!END )" lookbehind redundant (a close-banner line's content
    # right after its leading "/* ===" is "END ...", never the open marker itself, so it
    # can no longer be mismatched as an open occurrence either) but it's left in place
    # below as a harmless, cheap extra safeguard.
    #
    # CORRECTED AGAIN 2026-10-25 (same day, rff6 build): the line-start anchor alone isn't
    # enough -- plain prose wraps at whatever column the terminal/editor gives it, so a
    # changelog sentence can coincidentally place the marker text at the very start of a
    # WRAPPED line too, with nothing but leading spaces before it. This happened on rff6's
    # Task A output: "...[E] CLASSIC ADAPTER and\n   [F] BROADHEAD ADAPTER are byte-
    # identical to rff5." -- the wrap landed "[F] BROADHEAD ADAPTER" at column 1 (after
    # indentation), which the old anchor accepted as a real banner (OpenCount=2) on a
    # single, correctly-formed, non-duplicated file; confirmed by direct inspection of
    # task_a_raw_output.txt, which has exactly one real open banner (" * [F] BROADHEAD
    # ADAPTER  (NGRX WIDGET ONLY)", line 1057) and one real close banner (line 1198).
    # Every genuine banner line in every build this project has produced -- open or close,
    # all three sections -- carries a literal "*" in its leading decoration (either the
    # " * " continuation-line leader of a "/* ====\n * [TAG]" block, or the "/*" that opens
    # a single-line "/* === END [TAG] === */" banner); a prose line never does, because the
    # header's running text is plain-indented with no "*" leader at all. Requiring that "*"
    # to actually be present (not just allowed, as the old "[\s\*/=]*" let it be absent)
    # closes this gap without reopening the original rff5 false positive: a changelog
    # sentence can still start a wrapped line, but it is never preceded by a bare "*" there,
    # since prose in this file's header is never written in "* "-leader style.
    param([string]$Text)
    $results = @()
    foreach ($s in $script:MergedFileSections) {
        $closeCount = ([regex]::Matches($Text, [regex]::Escape($s.Close))).Count
        $openCount = ([regex]::Matches($Text, "(?m)^[\s/=]*\*[\s/=]*(?<!END )" + [regex]::Escape($s.Open))).Count
        $results += [PSCustomObject]@{ Open = $s.Open; Close = $s.Close; OpenCount = $openCount; CloseCount = $closeCount }
    }
    return $results
}

function Confirm-NotDuplicated {
    # Deterministic, cheap guard against a second real prior bug: on the rpf1 run (2026-10-21),
    # Task A's "claude --print ..." invocation returned the ENTIRE generated file twice in one
    # stdout stream -- not a collapse (plenty of newlines, so Confirm-NotCollapsed above passed
    # clean) and not a Task B splice artifact (src/blueprint_merged.task_a.js, saved BEFORE Task
    # B ever touches the file, was already the full doubled size). So the duplication originates
    # in the Task A "claude --print" call itself, upstream of everything else in this script.
    # This check doesn't try to explain why the model/CLI emitted it twice -- it just confirms
    # each of the three sections' open AND close banners appears exactly once, which is true
    # for a clean single-copy file and false for a duplicated one. Catching this here (right
    # after Task A, before Task B ever reads the file) stops a doubled file from ever reaching
    # the CODEX review step, where it would also silently produce two "[F] BROADHEAD ADAPTER"
    # sections and corrupt the splice.
    #
    # CORRECTED 2026-10-22: the original version of this check counted each open marker as a
    # raw substring, which produces a FALSE POSITIVE of exactly 2 for the [E]/[F] sections on
    # every normal, correctly-formed file (see Get-SectionBannerCounts above for why). This
    # false positive blocked two back-to-back, perfectly valid record_finder builds before
    # being caught -- confirmed by running the old naive count against this project's own
    # already-deployed, known-correct Record Permissions Field Audit blueprint_merged.js,
    # which also reported the same "false" count of 2. Now counts open/close separately per
    # Get-SectionBannerCounts, which correctly reports 1/1 for both that known-good file and
    # the record_finder output that had been wrongly rejected.
    param([string]$Text, [string]$StageName, [string]$FilePath)
    $counts = Get-SectionBannerCounts -Text $Text
    foreach ($c in $counts) {
        if ($c.OpenCount -ne 1 -or $c.CloseCount -ne 1) {
            Write-Error "[ERROR] [$StageName] $FilePath has the open banner '$($c.Open)' $($c.OpenCount) time(s) and the close banner '$($c.Close)' $($c.CloseCount) time(s) -- expected exactly 1 of each. This is the exact signature of the 2026-10-21 rpf1 duplication bug (Task A's claude --print call returned the whole file twice in one stdout stream). Aborting rather than writing/keeping a file that would execute twice on one page and break the Task B banner splice."
            exit 1
        }
    }
}

function Repair-IfCleanDuplicate {
    # Added 2026-10-22, then corrected the same day once Confirm-NotDuplicated's own false-
    # positive bug was found and fixed above (see its comment) -- the true rpf1-style failure
    # (the whole file emitted twice, back to back) now shows up as every section's Open AND
    # Close both counting 2, per Get-SectionBannerCounts. This function tests that specific,
    # narrow hypothesis and ONLY auto-repairs when it holds exactly: find the second
    # occurrence of the shared-core open banner (the first banner either copy would contain),
    # split there, and require the two halves to be BYTE-IDENTICAL once trimmed. If they are,
    # the duplication really was "whole output, twice" and keeping just the first half is
    # provably safe. If they are not (or the counts don't form a clean 2/2 pattern on every
    # section), this makes NO change at all and leaves Confirm-NotDuplicated to abort exactly
    # as it always has -- this function only ever narrows the set of inputs that reach that
    # abort, it never weakens it.
    param([string]$Text, [string]$StageName)
    $counts = Get-SectionBannerCounts -Text $Text
    $allExactlyTwo = $true
    foreach ($c in $counts) {
        if ($c.OpenCount -ne 2 -or $c.CloseCount -ne 2) { $allExactlyTwo = $false }
    }
    if (-not $allExactlyTwo) { return $Text }

    $marker = $script:MergedFileSections[0].Open
    $firstIdx = $Text.IndexOf($marker)
    $secondIdx = $Text.IndexOf($marker, $firstIdx + $marker.Length)
    if ($firstIdx -lt 0 -or $secondIdx -lt 0) { return $Text }

    $firstHalf = $Text.Substring(0, $secondIdx).Trim()
    $secondHalf = $Text.Substring($secondIdx).Trim()
    if ($firstHalf -ceq $secondHalf) {
        Write-Warning "[REPAIR] [$StageName] Detected the whole-output-emitted-twice duplication bug (every section's open AND close banner appeared exactly 2 times, and the two halves are byte-identical once trimmed). Auto-repaired by keeping only the first copy -- no retry needed. Raw duplicated output is preserved at task_a_raw_output.txt for the record."
        return $firstHalf
    }
    Write-Warning "[REPAIR] [$StageName] Every section's open/close banners appeared exactly 2 times, but the two halves are NOT byte-identical -- this isn't the known clean-duplicate pattern, so no auto-repair was attempted. Falling through to Confirm-NotDuplicated's abort."
    return $Text
}

function Repair-IfTaskAWroteFileDirectly {
    # Added 2026-10-30 (cob2 build): Task A runs as 'claude --print ... --dangerously-
    # skip-permissions', which gives it real file-write tools, not just a text-completion
    # call. On a large build (cob2's merged file was 186,073 bytes / ~85K tokens) Task A
    # judged the full file too large to return safely as plain printed text and instead
    # wrote it directly to disk -- at src/blueprint_merged_<buildId>.js, the matching
    # docs backup, AND src/blueprint_merged.js itself -- then printed a short prose note
    # explaining what it did and why, instead of the code. That note correctly fails the
    # banner check (every section's open/close counts came back 0/0, not 1/1 or the 2/2
    # "whole file twice" pattern Repair-IfCleanDuplicate above handles) because it
    # genuinely isn't the merged file. On that run the abort happened safely (the banner
    # check runs before the Out-File that would overwrite src/blueprint_merged.js), so the
    # good file Task A had already written survived untouched -- confirmed by direct
    # inspection: 186,073 bytes, exactly one correctly-ordered C/E/F banner set, matching
    # the active spec's cob2 revision. This function makes that recovery automatic instead
    # of requiring a human to notice and manually accept the file. It only ever substitutes
    # a file that independently, on its own content, satisfies the same 1/1 banner check
    # this function is guarding -- it does not weaken that check, it just also accepts
    # "the real output is already sitting on disk, freshly written" as a valid way to pass
    # it. If no such file is found, this makes NO change and leaves Confirm-NotDuplicated
    # to abort exactly as it always has.
    param([string]$Text, [string]$StageName)
    $counts = Get-SectionBannerCounts -Text $Text
    $alreadyValid = $true
    foreach ($c in $counts) {
        if ($c.OpenCount -ne 1 -or $c.CloseCount -ne 1) { $alreadyValid = $false }
    }
    if ($alreadyValid) { return $Text }

    $candidatePath = "src/blueprint_merged.js"
    if (-not (Test-Path $candidatePath)) { return $Text }

    $candidateInfo = Get-Item $candidatePath
    if ($candidateInfo.LastWriteTime -lt $script:PipelineStartTime) {
        # Pre-existing file from a previous run -- not evidence Task A wrote it just now.
        return $Text
    }

    $candidateText = (Get-Content -Raw -Encoding UTF8 -Path $candidatePath) -join ''
    $candidateCounts = Get-SectionBannerCounts -Text $candidateText
    $candidateValid = $true
    foreach ($c in $candidateCounts) {
        if ($c.OpenCount -ne 1 -or $c.CloseCount -ne 1) { $candidateValid = $false }
    }
    if (-not $candidateValid) { return $Text }

    Write-Warning "[REPAIR] [$StageName] Task A's printed reply doesn't look like the merged file (open/close banner counts weren't 1/1), but src/blueprint_merged.js was written after this pipeline run started and DOES satisfy that check on its own -- Task A most likely wrote the real output directly to disk (it has real file tools via --dangerously-skip-permissions) and printed an explanatory note instead because the file was too large to return as plain text safely. Using that file's on-disk content as Task A's output instead of aborting. Task A's printed note is preserved at task_a_raw_output.txt for the record."
    return $candidateText
}

function Write-ActiveSpec {
    param(
        [string]$SpecId,
        [string]$SourceFile,
        [string]$Body
    )
    $hash = Get-Sha256Hex -Text $Body
    $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"
    $stampLines = @(
        $StampStart
        "source_id: $SpecId"
        "source_file: $SourceFile"
        "sha256: $hash"
        "promoted_at: $timestamp"
        $StampEnd
        ""
    )
    $stamp = ($stampLines -join "`n") + "`n"
    Set-Content -Path ".\functional_spec.md" -Value ($stamp + $Body) -Encoding utf8 -NoNewline
    return $hash
}

function Get-ActiveSpecBody {
    # -join '' strips the hidden ETS NoteProperties (PSPath, ReadCount, etc.) that
    # Get-Content -Raw's returned object can carry on Windows PowerShell 5.1 -- see the
    # detailed note at the Task B merged-code read, where this exact decoration broke
    # ConvertTo-Json. Harmless here, cheap insurance if this body is ever JSON-serialized.
    $raw = (Get-Content -Raw -Encoding UTF8 -Path ".\functional_spec.md") -join ''
    $idx = $raw.IndexOf($StampEnd)
    if ($idx -lt 0) { return $raw }
    return $raw.Substring($idx + $StampEnd.Length).TrimStart("`r", "`n")
}

function Confirm-ActiveSpec {
    param([string]$ExpectedHash, [string]$StageName)
    if (-not (Test-Path ".\functional_spec.md")) {
        Write-Error "[ERROR] [$StageName] functional_spec.md is missing."
        exit 1
    }
    $raw = (Get-Content -Raw -Encoding UTF8 -Path ".\functional_spec.md") -join ''
    $stampEndIdx = $raw.IndexOf($StampEnd)
    if ($stampEndIdx -lt 0) {
        Write-Error "[ERROR] [$StageName] functional_spec.md has no spec stamp -- it was hand-edited or predates this mechanism. Re-run the promotion step (don't edit functional_spec.md directly; edit the blueprint in blueprints_library instead)."
        exit 1
    }
    $body = $raw.Substring($stampEndIdx + $StampEnd.Length).TrimStart("`r", "`n")
    $actualHash = Get-Sha256Hex -Text $body
    if ($actualHash -ne $ExpectedHash) {
        Write-Error "[ERROR] [$StageName] functional_spec.md has drifted from the promoted spec (sha256 mismatch). Aborting so a stale/wrong spec doesn't reach the downstream AI."
        exit 1
    }
    Write-Host ("[OK] [{0}] Active spec verified ({1}...)" -f $StageName, $actualHash.Substring(0, 12)) -ForegroundColor DarkGreen
}

# --- SPEC SELECTOR GATE (manifest-driven, not filesystem-order-driven) ---
$libraryPath  = ".\blueprints_library"
$manifestPath = "$libraryPath\manifest.json"
if (-not (Test-Path $libraryPath)) { mkdir $libraryPath | Out-Null }

if (-not (Test-Path $manifestPath)) {
    Write-Warning "[WARN] No manifest.json found -- bootstrapping one from *.md files in blueprints_library (ids derived from filenames). Review it and fix the titles/status."
    $autoEntries = Get-ChildItem -Path $libraryPath -Filter *.md | ForEach-Object {
        [ordered]@{
            id     = ($_.BaseName -replace '^spec_', '')
            file   = $_.Name
            title  = $_.BaseName
            status = "unreviewed"
        }
    }
    if ($autoEntries.Count -eq 0) {
        Set-Content -Path "$libraryPath\spec_placeholder.md" -Value "# ARCHER TOOL SPECIFICATION`n**Objective:** Baseline template" -Encoding utf8
        $autoEntries = @([ordered]@{ id = "placeholder"; file = "spec_placeholder.md"; title = "Baseline placeholder"; status = "draft" })
    }
    @{ specs = $autoEntries } | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding utf8
}

$manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json
$specs = @($manifest.specs)

if ($specs.Count -eq 0) {
    Write-Error "[ERROR] blueprints_library\manifest.json has no entries. Register a blueprint before building."
    exit 1
}

Write-Host "Available Archer tool blueprints:" -ForegroundColor White
for ($i = 0; $i -lt $specs.Count; $i++) {
    Write-Host ("  [{0}] {1}  (id: {2}, file: {3}, status: {4})" -f ($i + 1), $specs[$i].title, $specs[$i].id, $specs[$i].file, $specs[$i].status) -ForegroundColor Yellow
}

$chosen = $null
if ($Spec) {
    $chosen = $specs | Where-Object { $_.id -eq $Spec }
    if (-not $chosen) {
        Write-Error ("[ERROR] No blueprint with id '{0}' in manifest.json. Valid ids: {1}" -f $Spec, ($specs.id -join ', '))
        exit 1
    }
    Write-Host "[SELECTED] Selected by id: $Spec" -ForegroundColor Cyan
} elseif ($AutoSelect -gt 0) {
    Write-Warning "[WARN] -AutoSelect is numeric and order-dependent -- prefer -Spec <id> for anything unattended. Resolving index $AutoSelect against current manifest order."
    $idx = $AutoSelect - 1
    if ($idx -lt 0 -or $idx -ge $specs.Count) {
        Write-Error "[ERROR] Invalid -AutoSelect index: $AutoSelect"
        exit 1
    }
    $chosen = $specs[$idx]
} else {
    $selection = Read-Host "Type the blueprint number and press Enter"
    $idx = [int]$selection - 1
    if ($idx -lt 0 -or $idx -ge $specs.Count) {
        Write-Error "[ERROR] Invalid selection. Exiting pipeline runtime tracker."
        exit 1
    }
    $chosen = $specs[$idx]
}

$chosenFile = Join-Path $libraryPath $chosen.file
if (-not (Test-Path $chosenFile)) {
    Write-Error "[ERROR] Manifest points to '$($chosen.file)' but that file doesn't exist in blueprints_library."
    exit 1
}

$blueprintBody = (Get-Content -Raw -Encoding UTF8 -Path $chosenFile) -join ''
$activeHash = Write-ActiveSpec -SpecId $chosen.id -SourceFile $chosen.file -Body $blueprintBody
Confirm-ActiveSpec -ExpectedHash $activeHash -StageName "Promotion"
Write-Host ("[ACTIVE] Active Builder Slot loaded: {0}  [id: {1}, sha256: {2}...]" -f $chosen.title, $chosen.id, $activeHash.Substring(0, 12)) -ForegroundColor Green
Write-Host "----------------------------------------------------" -ForegroundColor Cyan

if ($ResumeFromTaskB) {
    # Added 2026-10-30: lets a run resume at Task B against an already-verified-good
    # src/blueprint_merged.js without re-invoking Task A (a full Opus regeneration) --
    # for exactly the cob2 situation: Task A's real output was already confirmed correct
    # and complete on disk, but the pipeline aborted before reaching Task B because its
    # printed stdout reply (a short explanatory note, not code) failed the banner check.
    # Re-validates the existing file with the same checks a normal Task A pass would have
    # to pass, rather than trusting it blindly.
    Write-Host "[TASK A] -ResumeFromTaskB set -- skipping Task A and using the existing src/blueprint_merged.js as-is." -ForegroundColor Yellow
    if (-not (Test-Path "src/blueprint_merged.js") -or (Get-Item "src/blueprint_merged.js").Length -eq 0) {
        Write-Error "[ERROR] -ResumeFromTaskB was set but src/blueprint_merged.js is missing or empty. Nothing to resume from -- run without -ResumeFromTaskB first."
        exit 1
    }
    $existingMerged = (Get-Content -Raw -Encoding UTF8 -Path "src/blueprint_merged.js") -join ''
    Confirm-NotCollapsed -Text $existingMerged -StageName "Task A (resumed)" -FilePath "src/blueprint_merged.js"
    Confirm-NotDuplicated -Text $existingMerged -StageName "Task A (resumed)" -FilePath "src/blueprint_merged.js"
    Write-Host "[OK] Existing src/blueprint_merged.js passed the same checks a fresh Task A pass would have to pass. Resuming at Task B." -ForegroundColor Green
} else {
# --- TASK A: CLAUDE CODE (OPUS) MERGED BUILD (shared core + both transport adapters) ---
Write-Host "[TASK A] Calling Claude Code to generate the merged Classic+Broadhead script via File Input..." -ForegroundColor Yellow

Confirm-ActiveSpec -ExpectedHash $activeHash -StageName "Task A (Merged build)"
$systemPrompt = "You are an Elite Archer IRM Solutions Architect and Classic UI Engineer. Build this tool as a SINGLE merged file per the functional spec's architecture: one shared business-logic core (implemented once, not duplicated), a detectTransport() check for window.broadhead / a Broadhead meta tag, and two adapter implementations behind one common request interface -- a Classic adapter (same-origin frame-walking via parent.parent.ArcherApp.globals, bare `$.ajax`) and a Broadhead adapter (window.broadhead.fetch(...).awaitResponse(), with whatever response verification the spec calls for). Follow the project's mandatory coding checklist for both adapters: hydration polling before any top-level DOM query, Sys.WebForms.PageRequestManager.getInstance().add_endRequest() re-attachment for the Classic UI path, unbind-before-bind event idempotency, and full IIFE + try/catch scope isolation. Clearly comment/delimit where the shared core ends and each adapter begins so a downstream reviewer can scope changes to one adapter without touching the other. These section banners are a hard pipeline requirement with exact, fixed wording -- use these three literal tags verbatim, with no variation in wording, numbering, or brackets: an open banner containing the exact text `"[C] SHARED CORE  (SHARED`" and a close banner containing the exact text `"END [C] SHARED CORE`" around the shared core; an open banner containing the exact text `"[E] CLASSIC ADAPTER`" and a close banner containing the exact text `"END [E] CLASSIC ADAPTER`" around the Classic adapter; an open banner containing the exact text `"[F] BROADHEAD ADAPTER`" and a close banner containing the exact text `"END [F] BROADHEAD ADAPTER`" around the Broadhead adapter. Do not invent alternate numbering such as [1]/[2]/[3] or `"SECTION 1/2/3`", even if the functional spec below happens to use numbered section headings for its own content -- these three literal tags are independent of the spec's own section numbering and must appear exactly as given. STANDING DEPLOYMENT REQUIREMENT (every tool, every build, going forward): the tool must work from a single deployed artifact that covers both Classic and NGRX -- never assume the admin is in only one UI. Implement this by having each adapter self-report its own availability at runtime (the Classic adapter confirms it can actually reach parent.parent.ArcherApp.globals via the frame walk; the Broadhead adapter confirms window.broadhead and the Broadhead meta tag are present) and render the tool's entry point as two independently-gated controls -- a Classic control that mounts only when the Classic self-check passes, and an NGRX control that mounts only when the Broadhead self-check passes -- rather than a single UI that assumes one environment. In practice only one control will ever successfully self-check in a given deployment context, but the code must not hard-assume which. Treat this the same as the mandatory coding checklist items above: apply it even when the functional spec below does not call it out explicitly. The full functional specification is piped to you on stdin below -- read it and build exactly what it describes. Output a single, clean code file with absolutely no conversational preamble."
$specContent = Get-ActiveSpecBody

# Pipe the (often tens-of-thousands-of-characters) spec body to Claude Code via STDIN
# instead of embedding it inside a quoted command-line argument. Two separate Windows
# failure modes collide on a spec this size: (1) 'claude' on Windows commonly resolves to a
# .cmd shim that re-dispatches through cmd.exe, whose own command-line length cap (~8191
# chars) is far smaller than the ~24k-character spec body; (2) even under that cap, real
# spec markdown almost always contains double-quote characters, and PowerShell's escaping
# when quoting a single large argument for a native process is known to desync around
# embedded quotes, corrupting or truncating the call. Both produce a clean non-zero exit
# with no visible diagnostic -- exactly what showed up. Piping via stdin has neither limit
# and is the pattern Claude Code's own docs call out for processing piped content
# ("cat file | claude -p query"). Stderr is redirected to its own log file (not merged with
# stdout) so a real Claude Code diagnostic is captured without risking it getting written
# into the generated code file on a run that happens to also emit a stderr warning.
$taskAStderrLog = "task_a_stderr.log"
$taskAOutputLines = $specContent | claude --model=opus --print "$systemPrompt" --dangerously-skip-permissions 2> $taskAStderrLog
$taskAExitCode = $LASTEXITCODE
$taskAStderr = if (Test-Path $taskAStderrLog) { (Get-Content -Raw -Path $taskAStderrLog) -join '' } else { "" }

# CRITICAL: capturing a native command's stdout into a variable (as above) splits it into
# an ARRAY of one string per line -- the newline characters become array-element
# boundaries, not characters inside any element. Piping that array straight into
# "Out-File -NoNewline" (as this script did previously) writes the elements back-to-back
# with ZERO separator between them, silently collapsing an entire multi-line file into one
# unbroken line. This is a correctness-destroying bug for JavaScript specifically: every
# '//' line comment in the generated code then has no newline to terminate it, so it
# swallows everything after it to end-of-file. Confirmed on a real prior run: the written
# file had 84 '//' comments and ZERO newline characters in 90,617 bytes. Re-joining the
# array with explicit "`n" BEFORE writing restores the real line structure; Out-File then
# receives one single string, so -NoNewline only suppresses the harmless trailing newline,
# not the ones inside the content.
$taskAOutput = $taskAOutputLines -join "`n"

if ($taskAExitCode -ne 0) {
    Write-Error ("[ERROR] Claude Code compilation failed (exit code {0}).`n--- Claude Code stderr ({1}) ---`n{2}`n--- Claude Code stdout (if any) ---`n{3}" -f $taskAExitCode, $taskAStderrLog, $taskAStderr, $taskAOutput)
    exit $taskAExitCode
}

# Always preserve the raw, unmodified Task A output before any check or repair touches
# it -- added 2026-10-22. Previously a duplication-bug abort discarded $taskAOutput
# entirely with nothing written to disk, so there was never anything to inspect
# afterward. This file is overwritten every run; it's forensic/debug output, not a
# pipeline input, and is safe to ignore on a clean run.
$taskAOutput | Out-File -FilePath "task_a_raw_output.txt" -Encoding utf8 -NoNewline

Confirm-NotCollapsed -Text $taskAOutput -StageName "Task A" -FilePath "src/blueprint_merged.js"
$taskAOutput = Repair-IfCleanDuplicate -Text $taskAOutput -StageName "Task A"
$taskAOutput = Repair-IfTaskAWroteFileDirectly -Text $taskAOutput -StageName "Task A"
Confirm-NotDuplicated -Text $taskAOutput -StageName "Task A" -FilePath "src/blueprint_merged.js"

$taskAOutput | Out-File -FilePath "src/blueprint_merged.js" -Encoding utf8 -NoNewline

if (-not (Test-Path "src/blueprint_merged.js") -or (Get-Item "src/blueprint_merged.js").Length -eq 0) {
    Write-Error ("[ERROR] Claude Code exited successfully (code 0) but src/blueprint_merged.js is missing or empty.`n--- Claude Code stderr ({0}) ---`n{1}`n--- Claude Code stdout ---`n{2}" -f $taskAStderrLog, $taskAStderr, $taskAOutput)
    exit 1
}
Write-Host "[OK] Merged Classic+Broadhead blueprint successfully written to src/blueprint_merged.js" -ForegroundColor Green
}

# --- TASK B: CODEX API REVIEW (BROADHEAD ADAPTER ONLY) ---
Write-Host "[TASK B] Directing CODEX API to review the Broadhead adapter inside the merged file..." -ForegroundColor Yellow

if (-not (Test-Path "src/blueprint_merged.js")) {
    Write-Error "[ERROR] Missing merged blueprint file. Skipping Task B."
    exit 1
}

# Windows PowerShell 5.1's FileSystem provider silently attaches hidden ETS NoteProperties
# (PSPath, PSDrive, ReadCount, etc.) to the string object Get-Content -Raw returns. When
# that decorated object is piped through ConvertTo-Json, the serializer dumps ALL of its
# attached properties as a JSON object (e.g. {"value":"<code>", ...,"Drives":["C"],
# "ReadCount":1}) instead of the plain code text as a JSON string -- this, not a nesting-
# depth issue, is the actual, now-confirmed cause of the repeated "expected ... string ...
# but got an object instead" error from the API (confirmed by inspecting the real
# debug_task_b_request_body.json dump). "-join ''" forces a brand-new, undecorated
# [string] with none of that metadata attached, so ConvertTo-Json serializes it correctly.
$mergedCode = (Get-Content -Raw -Path "src/blueprint_merged.js") -join ''
if (-not $mergedCode) {
    Write-Error "[ERROR] src/blueprint_merged.js read back empty. Task A may not have produced content."
    exit 1
}

$apiKey = $env:OPENAI_API_KEY
if (-not $apiKey) {
    Write-Error "[ERROR] Missing OPENAI_API_KEY environment variable."
    exit 1
}

$headers = @{
    "Authorization" = "Bearer $apiKey"
}

# --- EXTRACT ONLY THE BROADHEAD ADAPTER SECTION (do not send the whole file) ---
# CODEX now runs on gpt-6-luna, whose output ceiling is 128,000 tokens -- 8x gpt-4o's old
# 16,384 cap, chosen specifically so this class of truncation can't recur even as specs
# grow. (gpt-4o's 16,384 cap was the confirmed cause of a real failure: a full-file
# round-trip cut off mid-line inside the Broadhead section, at almost exactly the
# 16,384-token mark, with later sections missing entirely -- caught by the Gemini audit,
# Task C.) Scoping the request to just the Broadhead section is kept anyway even with the
# much higher ceiling: it's still far cheaper per call, and it makes "don't touch anything
# else" a structural guarantee instead of relying on CODEX to echo a huge file back
# verbatim and correctly. Task A's own system prompt already requires clearly-delimited
# banner comments around each adapter
# ("* [F] BROADHEAD ADAPTER ... * END [F] BROADHEAD ADAPTER ..."), so extract just that
# section (about 3,900 tokens on a real run -- comfortably inside the cap), send only it,
# and splice the response back into the full file here in PowerShell. This also makes
# "don't touch anything else" a structural guarantee instead of relying on CODEX to echo
# the rest of a huge file back verbatim and correctly, which is itself an unnecessary risk.
$sectionStartTag = "[F] BROADHEAD ADAPTER"
$sectionEndTag = "END [F] BROADHEAD ADAPTER"

# CORRECTED 2026-10-25 (rff6 build): a plain IndexOf() substring search for the open-banner
# tag finds the FIRST occurrence of that text ANYWHERE in the file, including inside
# ordinary prose -- the exact same hazard already fixed for Get-SectionBannerCounts above
# (see its 2026-10-25 comments), but this call wasn't using that fix yet. rff6's own header
# changelog mentions "[F] BROADHEAD ADAPTER" in a plain sentence well BEFORE the real
# banner (".. [E] CLASSIC ADAPTER and\n   [F] BROADHEAD ADAPTER are byte-identical to
# rff5."), so IndexOf() landed on that prose line near the top of the file instead of the
# real banner far below it. LastIndexOf("/*", ...) then walked back to the file's very
# FIRST "/*" (the top header comment), so the "extracted" section sent to CODEX was
# actually 92,456 of 101,046 chars on the real failing run -- 91% of the whole file, not
# the ~8,700-char Broadhead-only section the system prompt told CODEX to expect. CODEX's
# reply (8,709 chars) was in fact approximately the right SIZE for the real section -- it
# only looked "implausibly short" because it was being compared against that bloated,
# wrongly-extracted 92,456-char input. Confirmed against both the failing rff6 raw output
# (old: 92,456 chars from file start; new: 8,676 chars, the real [F] block only) and the
# already-shipped rff5 file (old and new agree almost exactly there -- rff5's own prose
# mention happened to land close enough to its real banner not to matter -- which is why
# this went unnoticed until rff6's wording moved it earlier in the file). Reuses the same
# "*"-leader-anchored regex Get-SectionBannerCounts now uses, so this finds the real
# banner line only, never a prose mention of the same bracketed text.
$openBannerRegex = [regex]::new("(?m)^[\s/=]*\*[\s/=]*(?<!END )" + [regex]::Escape($sectionStartTag))
$openMatch = $openBannerRegex.Match($mergedCode)
if (-not $openMatch.Success) {
    Write-Error "[ERROR] Could not find the '$sectionStartTag' banner comment in src/blueprint_merged.js -- Task A may have changed its comment format. Not sending the whole file to CODEX (that reliably truncates); aborting Task B instead so this can be fixed deliberately."
    exit 1
}
$startTagIdx = $openMatch.Index
$blockStartIdx = $mergedCode.LastIndexOf("/*", $startTagIdx)
if ($blockStartIdx -lt 0) { $blockStartIdx = $startTagIdx }

$endTagIdx = $mergedCode.IndexOf($sectionEndTag, $startTagIdx)
if ($endTagIdx -lt 0) {
    Write-Error "[ERROR] Found '$sectionStartTag' but not '$sectionEndTag' in src/blueprint_merged.js. Aborting Task B rather than guessing where the section ends."
    exit 1
}
$blockEndIdx = $mergedCode.IndexOf("*/", $endTagIdx)
if ($blockEndIdx -lt 0) {
    Write-Error "[ERROR] Found '$sectionEndTag' but no closing '*/' after it in src/blueprint_merged.js. Aborting Task B."
    exit 1
}
$blockEndIdx = $blockEndIdx + 2   # include the closing "*/"

$broadheadSection = $mergedCode.Substring($blockStartIdx, $blockEndIdx - $blockStartIdx)
Write-Host ("[TASK B] Extracted Broadhead adapter section: {0} of {1} total chars (sending only this to CODEX)." -f $broadheadSection.Length, $mergedCode.Length) -ForegroundColor DarkGray

$systemPromptB = "You will receive ONLY the Broadhead/NGRX adapter section of a larger merged JavaScript file (the shared core and Classic adapter are NOT included and are not your concern). Review and, only if genuinely necessary, correct this section -- verify it correctly uses window.broadhead.fetch(...).awaitResponse(), never assumes same-origin access (the Widget iframe is sandboxed without allow-same-origin, so contentDocument/parent.ArcherApp-style access is never valid there), and matches whatever Broadhead-specific behavior (route allowlisting, response verification, logging) the functional spec calls for. Output ONLY this section back (the same banner comments plus the code between them), complete and not abridged, with absolutely no conversational preamble, no markdown code fences, and no explanation -- your entire response is spliced verbatim back into the larger file in place of what you received."

# Encode each content string to a JSON string literal on its OWN, rather than nesting it
# inside a hashtable-in-an-array-in-a-hashtable passed to ConvertTo-Json as a whole. A bare
# string piped through ConvertTo-Json is always a reliable, properly-escaped JSON string
# literal.
$systemContentJson = $systemPromptB | ConvertTo-Json -Compress
$userContentJson = $broadheadSection | ConvertTo-Json -Compress

# max_completion_tokens: newer OpenAI models (gpt-6-luna included) reject the legacy
# 'max_tokens' parameter outright (HTTP 400: "Unsupported parameter: 'max_tokens' is not
# supported with this model. Use 'max_completion_tokens' instead" -- confirmed on a real
# run). gpt-6-luna's hard ceiling is 128000 output tokens; the extracted section is ~3,900
# tokens on a real run, so 24000 leaves very generous headroom for CODEX's corrected
# version to grow well beyond that while still failing fast (via the finish_reason check
# below) if something is badly wrong, rather than silently hitting a ceiling again.
$bodyJson = '{"model":"gpt-6-luna","max_completion_tokens":24000,"messages":[{"role":"system","content":' + $systemContentJson + '},{"role":"user","content":' + $userContentJson + '}]}'

# DEBUG: dump the exact outgoing request body to disk before sending, so a failure can be
# diagnosed from the real bytes that were actually sent on this run, not re-derived from
# theory. Safe to delete this file or this block once Task B is confirmed reliable.
$bodyJson | Out-File -FilePath "debug_task_b_request_body.json" -Encoding utf8 -NoNewline
Write-Host "[DEBUG] Wrote outgoing request body to debug_task_b_request_body.json ($($bodyJson.Length) chars)" -ForegroundColor DarkGray

# Send as explicit UTF-8 bytes -- Invoke-RestMethod's default string encoding is the
# system codepage, not UTF-8, and will silently corrupt any non-ASCII character the
# generated code happens to contain (smart quotes, em dashes, etc. in comments).
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)

try {
    $response = Invoke-RestMethod -Uri "https://api.openai.com/v1/chat/completions" -Method Post -Headers $headers -ContentType "application/json; charset=utf-8" -Body $bodyBytes -ErrorAction Stop
} catch {
    # Windows PowerShell 5.1 usually populates ErrorDetails.Message with the response
    # body already -- try that first, since Invoke-RestMethod may have consumed the
    # underlying response stream already (a second manual read of it comes back empty).
    $errBody = $_.ErrorDetails.Message
    if (-not $errBody -and $_.Exception.Response) {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $stream.Position = 0
            $reader = New-Object System.IO.StreamReader($stream)
            $errBody = $reader.ReadToEnd()
        } catch {}
    }
    if (-not $errBody) { $errBody = "(no response body captured)" }
    Write-Error "[ERROR] CODEX API call failed: $($_.Exception.Message)`n--- Response body ---`n$errBody"
    exit 1
}

# finish_reason == "length" means the response was cut off by the token limit -- a silent
# truncation exactly like the one that caused the earlier failure. Treat it as a hard
# error instead of accepting a partial section, even though max_tokens above gives it
# generous headroom not to happen again.
$finishReason = $response.choices[0].finish_reason
if ($finishReason -eq "length") {
    Write-Error "[ERROR] CODEX's response was truncated (finish_reason=length) -- it ran out of output tokens before finishing the Broadhead section. Leaving src/blueprint_merged.js as Task A produced it. Raw (truncated) response was:`n$($response.choices[0].message.content)"
    exit 1
}

$reviewedSection = ($response.choices[0].message.content) -join ''

if (-not $reviewedSection -or $reviewedSection.Trim().Length -lt ($broadheadSection.Length * 0.3)) {
    Write-Error "[ERROR] CODEX's reviewed Broadhead section looked empty or implausibly short (got $($reviewedSection.Trim().Length) chars vs $($broadheadSection.Length) chars sent). Leaving src/blueprint_merged.js as Task A produced it."
    exit 1
}

Copy-Item "src/blueprint_merged.js" "src/blueprint_merged.task_a.js" -Force

# Splice: replace ONLY the exact substring that was sent out, inside the full merged file.
# Everything before and after it is guaranteed untouched -- not dependent on CODEX having
# echoed it back correctly, because it was never sent in the first place.
$fullReviewedCode = $mergedCode.Substring(0, $blockStartIdx) + $reviewedSection + $mergedCode.Substring($blockEndIdx)
Confirm-NotCollapsed -Text $fullReviewedCode -StageName "Task B" -FilePath "src/blueprint_merged.js"
Confirm-NotDuplicated -Text $fullReviewedCode -StageName "Task B" -FilePath "src/blueprint_merged.js"
$fullReviewedCode | Out-File -FilePath "src/blueprint_merged.js" -Encoding utf8 -NoNewline
Write-Host "[OK] Broadhead adapter section reviewed and spliced back in; src/blueprint_merged.js updated in place (pre-review copy saved as src/blueprint_merged.task_a.js)." -ForegroundColor Green

# --- TASK C: GEMINI 4 ARGON QUALITY AUDIT ---
Write-Host "[TASK C] Initiating Gemini 4 Argon Quality Audit Gate..." -ForegroundColor Yellow
python .\scripts\run_gemini_audit.py
Write-Host "[OK] Quality Gate completed. Check audit_report.txt for details." -ForegroundColor Green

# --- TASK D: CLAUDE SONNET UAT AUDIT ---
Write-Host "[TASK D] Handing components to Claude Support Reviewer for UAT..." -ForegroundColor Yellow
Confirm-ActiveSpec -ExpectedHash $activeHash -StageName "Task D (UAT review)"
$uatPrompt = "Read functional_spec.md and src/blueprint_merged.js (a single file containing a shared core plus a Classic adapter and a Broadhead adapter). Act strictly as the internal Archer Support Reviewer persona. Evaluate practical usability and PRINT your 6-part report directly as your response -- do not use a file tool to write it to support_review_pane.md or any other path; this orchestration script captures your printed response and writes it to support_review_pane.md itself, and a direct file write from you races against that and can leave the real file empty or stub text. As part of that review, specifically confirm the standing dual-UI requirement: the tool's entry point must render as two independently self-gated Classic/NGRX controls (each adapter confirming its own environment before mounting), not a single UI that assumes one environment -- flag it as a finding if either adapter's control is not properly self-gated or if the two controls are not independent of each other."
claude --model=sonnet --print "$uatPrompt" --dangerously-skip-permissions > support_review_pane.md

# Guard against the exact failure seen on a real run (rm2, 2026-10-30): the model used its
# own file-write tool to put the real report at support_review_pane.md despite the prompt
# asking it to print instead (left in place above too, for older/other models that may not
# respect it), racing against this redirect's already-open file handle. That produced an
# empty-looking support_review_pane.md holding only the model's own explanation of the
# conflict, with the real 6-part report sitting under a sibling filename instead. Detect
# that signature (a short file, well under what a real 6-part report runs) and fail loudly
# rather than silently shipping a stub as if it were the real review.
$reviewText = (Get-Content -Raw -Encoding UTF8 -Path "support_review_pane.md") -join ''
if (-not $reviewText -or $reviewText.Trim().Length -lt 1000) {
    Write-Error "[ERROR] [Task D (UAT review)] support_review_pane.md is suspiciously short ($($reviewText.Trim().Length) chars) -- likely the model wrote the real report to a sibling file instead of printing it (check for a support_review_pane.<spec-id-ish>.md file nearby and copy it over this one if so). Not treating this short file as the real review."
    exit 1
}
Write-Host "[OK] Support Reviewer evaluation complete." -ForegroundColor Green

# --- TASK E: COMPRESS ONLY TEXT/HTML AND CODE BINARIES (.ZIP) ---
Write-Host "[TASK E] Packaging finalized output assets..." -ForegroundColor Yellow
if (-not (Test-Path "dist")) {
    New-Item -ItemType Directory -Path "dist" | Out-Null
}
try {
    Compress-Archive -Path "src\blueprint_merged.js", "docs\*.md", "support_review_pane.md" -DestinationPath "dist\archer_output_package.zip" -Force -ErrorAction Stop
} catch {
    Write-Error "[ERROR] [Task E] Compress-Archive failed: $($_.Exception.Message). Not printing a success message for a package that wasn't actually written."
    exit 1
}
if (-not (Test-Path "dist\archer_output_package.zip")) {
    Write-Error "[ERROR] [Task E] dist\archer_output_package.zip is missing after Compress-Archive reported success. Aborting rather than claiming a deliverable exists when it doesn't."
    exit 1
}
Write-Host "[DONE] Orchestration complete! Clean deliverables zipped at dist\archer_output_package.zip" -ForegroundColor Cyan
