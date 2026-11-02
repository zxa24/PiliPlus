# AC1 mutation check (feature-logs/download-platforms design, AC1 「变异检查」).
#
# Each mutant in mutants.json is a small, deliberate regression of the
# bilibili download code; each must make at least one AC1 check fail. The
# patches are only ever applied in throwaway git worktrees under
# _tmp/mutants/, never to the checked-out lib/.
#
#   pwsh -NoProfile -File test/mutants/run.ps1 [-Commit <rev>] [-Phase 0|1a|1b|2]
#        [-Only M1,M15] [-Slot 1] [-Out <dir>] [-Baseline <dir>] [-NoSelfTest]
#        [-Flutter <flutter.bat>] [-Work <dir>] [-SelfTestAll] [-SelfTestTree <dir>]
#        [-NoUnit] [-AsrModels <dir>]
#   pwsh -NoProfile -File test/mutants/run.ps1 -Compare <baseDir>,<otherDir>
#   pwsh -NoProfile -File test/mutants/run.ps1 -Phase 2 -Union <dir>,<dir>
#        (the result folders of one commit's runs cover -Phase 2's ids)
#
# Unit / widget mutants (those with a `test`): they share ONE worktree,
# _tmp/mutants/unit/ on -Commit (packages resolved once). First each test
# file once on the unmutated tree (the control: control.<file>.test.jsonl);
# the mutants of a file that fails or hangs there are `error`, not run. Per
# mutant: `git apply` the patch, `flutter test --no-pub --concurrency=1 <its
# test file>`, then only the patch's own files are restored (`git checkout
# --` of the files it changed, `git clean` of the files it created); caught
# = a test fails (its name and the first line of the failure are recorded;
# a note says so when it is not the test mutants.json names as the
# catcher), survived = all pass, error = the patch does not apply, the code
# does not compile, or the run does not end within 20 min (not a catch).
#
# Self-test mutants (a `scenario` and no `test`; with -SelfTestAll also those
# a unit test catches first): only seen by the networked self tests.
# They share ONE worktree, _tmp/mutants/selftest/, built incrementally:
# first the unmutated build is
# run as the baseline (unless -Baseline gives reports of the same commit),
# then per mutant: apply -> `flutter build windows --debug` -> copy into the
# slot with .claude/test-slot.ps1 (this machine's firewall allows network
# access only from fixed exe paths) -> run the self test with a new profile
# -> compare its report with the baseline by AC1's must-match fields (and the
# list shots pixel by pixel) -> restore the patch's own files as above (the
# build output beside them stays). Caught = the report's pass is false or a
# must-match field differs; error = no readable report, or one without the
# scenario's own check (the app did not finish). In --download and
# --download-transcribe (AC1 重跑规则) a difference with a network retry in
# either report (a `retryWait` status or an `again in` line) is judged by a
# second run, both kept (<id>\rerun), the row noted "rerun (network retry)";
# the queue scenarios are never rerun. List shots are compared only at one
# size (the window opens on whichever screen Windows picks; the report has
# its devicePixelRatio and shotSize): a list-shot mutant whose only
# differences are shots of another size is "not compared" at first; after
# the mutants the unmutated tree is built (with -SelfTestTree: its final
# rebuild) and the list-shots self test run once more into
# <Out>\baseline-rescaled\, and those mutants are judged again against it
# (still "not compared" if its size differs too). Each list-shot row's note
# names the baseline it was judged against. Each profile's data is deleted
# after its run; the worktree and its build output at the end.
#
# A runner failure while one mutant runs (an exception) is that mutant's
# `error` row; the run goes on with the next one.
#
# -SelfTestTree <dir>: use an existing checkout of the same lib/ that already
# has a Windows debug build instead of a new worktree (no cold full build,
# the memory peak): baseline = an incremental build of it, each mutant
# restores only the files its patch touched, and at the end the tree is
# unmutated and rebuilt once, so its build matches its commit again.
#
# Both are checked before any mutant runs: -SelfTestTree's commit must have
# -Commit's lib/ and test/fixtures/ (and no changes there); a -Baseline's
# reports must pass, as a baseline built here must. A baseline built here
# gets a manifest.json (the commit, its lib/ and test/fixtures/ tree hashes);
# a -Baseline with one is refused when those trees differ from -Commit's, one
# without is used with a warning in results.md. results.json/.md start with
# the commit, the self-test tree's commit and run.ps1's own blob hash.
#
# -Compare <a>,<b> only compares two folders of self-test reports by the same
# rules (download.json, queue99.json, transcribe.json, listshots.json), e.g.
# two unmutated runs, to see that the comparison does not flag run-to-run
# noise.
#
# Memory (this machine is short of it): before every mutant, and before the
# baseline build, free physical memory must be at least -MinFreeMB; below it
# the run waits (polling every 30 s, logged) up to -MemoryWaitMinutes, then
# stops cleanly with the results so far (exit 3).
#
# A MUTANT.txt in a worktree says which patch is applied. An interrupted run
# leaves its worktree (_tmp/mutants/unit/ or _tmp/mutants/selftest/); the
# next run removes it before using the name.
# Results: <Out>/results.json and results.md, rewritten after every mutant,
# with each mutant's raw test log / self-test reports beside them.
#
# ================================================================ plans
# The runner serves two plans. Everything above describes the first, and
# it still works exactly so:
#   download    mutants.json (a bare array), scenarios download / queue99 /
#               transcribe / listshots, -Phase 0|1a|1b|2. The default plan.
#               -Phase 2 (stage 2 of the download platforms, its plan §6.3)
#               runs every mutant: both, 1a-only, 1b-only and 2-only. Every
#               download run first checks mutants.json (ids unique, phases
#               known); -Phase 2 with no -Only checks that it picked exactly
#               stage 1's 61 frozen ids and the ids each stage-2 commit
#               lists ($dlStage1 / $dlStage2), and -Union checks that the
#               result folders of a run stopped and resumed with -Only cover
#               the same ids together.
#   watch_page  wp-mutants.json, design feature-logs/watch-page-shell/
#               design.md §5 S0b 「runner 通用化」: -Plan watch_page.
#
#   pwsh -NoProfile -File test/mutants/run.ps1 -Plan watch_page [-Phase S0]
#        [-Only wp-R2a] [-Batch] [-Slot 1] [-Out <dir>] [-Baseline <dir>] [-DryRun]
#        [-PlanFile <wp-mutants.json>] ...
#   pwsh -NoProfile -File test/mutants/run.ps1 -Plan watch_page -Alternate
#        [-Parent <rev>] [-Commit <rev>] [-Passes 2] [-Checks id,id]
#        [-OnlySide parent|new] [-Slot 1] [-Slot2 2] [-Batch] [-DryRun]
#        [-Cleanup] [-Out <dir>]
#   pwsh -NoProfile -File test/mutants/run.ps1 [-Plan watch_page]
#        -Compare <dir>[,<dir>] [-Out <dir>] [-Checks id,id]
#   pwsh -NoProfile -File test/mutants/run.ps1 -CheckTestSide <parent>,<child>
#
# What a watch_page check is: one self-test run (one command line) whose
# report has a check object of a given name. Each check has a FIELD TABLE,
# test/mutants/wp_fields/<id>.json (schema below), instead of the download
# plan's hard-coded $checkNames and Compare-Scenario switch. The table says
# how to run the check, which report file and check name hold it, and for
# every field it compares: a path into the check object and a status:
#   must-same   compared (AC-S1 (a), AC-S0a, a mutant's noise)
#   unstable    recorded only: changes between unmutated runs (found with
#               -Compare's calibration mode), never compared, never a
#               mutant's expected field
# and, on must-same fields only, expectedFor: the mutants whose expected
# field it is (cross-checked against wp-mutants.json, so the two cannot
# drift apart). The report shape the self tests must produce for this is
# in test/mutants/WP_REPORT_SHAPE.md.
#
# Field table schema (JSON; files starting with "_" are not tables; a table
# with "example": true is skipped and listed as such):
#   id            = the file name without .json
#   check         the check object's "name" in the report's "checks"
#   report        the report's file name inside a pass folder
#   type          judging (pass decided by behaviour) | recording (pass =
#                 measured, the behaviour is in must-same fields)
#   batch         null | fullscreen | pip: covers a screen (u#4); in-app
#                 fullscreen is null, its maximised case is fullscreen.
#                 Required (a forgotten key would run a covering check
#                 outside a batch)
#   network       true for online checks: retries / risk control rerun
#   rerunOn       regex over a report's raw text that counts as a network
#                 retry or risk control (default $wpRerunDefault below)
#   run           { args: [...], prefs: ["k:type=v"...], planPrefs: true,
#                   profile: "fresh" | "snapshot:<dir>" (Restore-WpProfile:
#                   test/fixtures/watch_page/<name>), asr: false,
#                   minutes: 30 }  — args may use ${SHOTS} ${FIXTURES} ${OUT}
#                 planPrefs false = do not add wp-mutants.json's prefs (the
#                 S0a 核对 runs must be today's exact command lines).
#                 Tables sharing a report must name the same run: that
#                 command line runs once for all of them (-Alternate, the
#                 baselines, a mutant's catchers)
#   measured      "measured" (default: that path must be the boolean true;
#                 "true", 1 or [true] are not) or
#                 { "legacy": [paths] } for today's reports, which have no
#                 measured: every path present = the check got that far
#   preconditions [{ path, equals, extraRuns }]: a pass whose value is not
#                 `equals` is spoiled, rerun on the same commit, at most
#                 extraRuns per side; more spoiled = no result (--open-bili's
#                 played: true, design §5 S0a 「核对」)
#   display       path (from the report root, "@" prefix) of the window's
#                 display; reports on different displays are not compared
#                 (runner 补充⑦). Default "@display".
#   fields        [{ name, path, status, expectedFor?, type?, tolerance? }]
#                 path: "a.b[2].c" from the check object, "@a.b" from the
#                 report root; type "shot" = a PNG path or list of them,
#                 equal when at most `tolerance` pixels differ; an image
#                 that is not there or does not decode is not a value (①)
#   uiErrors      { status: must-same|unstable|none, path: "uiErrors",
#                   unstable: [keys], expectedFor: [mutant ids],
#                   optional: false }  the key missing from a report is ①
#                 无结果, except for a legacy table (measured.legacy: today's
#                 self test writes it only when there are errors) or
#                 optional true
#   evidence      the sensitivity evidence of AC-S1 「灵敏证据」 (a mutant id
#                 and its field), or null = 无灵敏证据
#
# A report folder (one per commit) is what -Alternate writes and -Compare
# reads: manifest.json (plan, commit, lib / fixtures / windowsRunner tree
# hashes, media hashes, root = the worktree the build was made in, runner =
# this script's blob) and pass1\, pass2\, ... each holding one report per
# check of that pass; runs.jsonl logs every run in the order it ran.
# pass.json in a pass folder ({ "checks": [ids] }, written by -Alternate
# before the pass) says which checks it ran: a pass that did not run a
# check is not that check's (so `-Checks <id>` reruns and batch runs into
# the same -Out leave the other rows alone); no pass.json = all of them.
#
# -Compare <a>,<b> (watch_page: chosen by -Plan, or when every folder's
# manifest says plan watch_page) has two modes, by the manifests:
#   calibration  one folder, or two of the same commit and trees: lists,
#                per check, every field (all leaves of the check object,
#                not only the table's) and uiErrorKey that differs between
#                the passes, and writes a suggested field table for each
#                check (a list of objects is walked by index, runs[0].end;
#                PNG leaves and shot fields are compared as images, with the
#                noise floor in pixels); judges nothing
#   parent/child one folder's commit is the other's parent: every field
#                table is judged by 「多份报告的判法」 ①-⑤ (design §5):
#                  ① a missing key or {"$unread": …} in any report -> 无结果
#                  ② table says unstable -> recorded only
#                  ③ the parent side's reports differ among themselves ->
#                    不稳定, listed in the 降级 column with both sides' values
#                  ④ parent constant, new side varies -> 需补跑 below 4
#                    reports a side, 不同（仅本步不稳） at 4
#                  ⑤ both constant: equal -> 相同; differ -> 需补跑 below 4
#                    a side, 不同 at 4
#                uiErrorKeys entry by entry (each key = "is this entry
#                there", judged by ②-⑤); a row is 不同 if any field is,
#                else 无结果 / 无法比较 / 需补跑 (in that order), else 相同
#                with its 降级 column. A pass (that ran the check) with no
#                report, no such check or measured not true makes the row
#                无结果 (rerun into a fresh folder pair, or remove that pass
#                on both sides). Values compare by canonical JSON: keys
#                sorted, numbers by value (1 = 1.0), dates as the text
#                written. Two manifests listing different media make every
#                row 无结果; worktree roots of different length make today's
#                string uiErrors 无法比较 (their 320-character cut moves).
#                -Compare launches nothing: a 需补跑 row names the runs to
#                add (an -Alternate command line appending passes).
#   The field tables must be HEAD's (committed with git add -f, unmodified)
#   unless -FieldTables names a folder; compare.json records each table's
#   blob and where it came from, and the origin map from the child commit
#   (or -OriginMap, with its blob).
#   anything else, or a folder without manifest.json, is refused.
# Results: <Out>\compare.json and compare.md when -Out is given, and a
# summary on the console. The download plan's -Compare is the one above.
#
# uiErrors -> uiErrorKeys (design §5 「uiErrors」): the report keeps the
# raw entries; the runner makes the keys. An entry is today's string
# (320-character text, " @ context", " :: info", " ## frames") or, from
# S0b on, an object {text, kind, widget, origin, context, frames}. Key =
# kind (first sentence, numbers removed) + widget type + where:
#   origin (or a file:///…dart:L read from today's text): repo-relative
#   file:line, the folder's manifest root stripped (a root with spaces or
#   %20 too; in today's text a line number that runs into the 320-character
#   cut, ":132" cut to ":13", is not read); between two commits
#     ① a file the step did not change: compared as it is
#     ② a changed file, line outside the changed blocks: the parent's line
#       moved through `git diff -U0 <parent> <child>`
#     ③ inside a changed block (either side): wp_origin_map.json (from the
#       child commit, or -OriginMap) row id + offset in the row ("id" only
#       for a row marked sameLength false); no row = 无法比较
#   no origin: kind + context + the first app frame (package:PiliPlus/… is
#     lib/…; same rules ①-③), marked weak; no frame: kind + context (weak);
#     today's text with nothing readable: kind + the text without numbers
#     (weak).
#   An entry one pass cannot place (③ without a row) makes every key with
#   its kind + widget 无法比较 on both sides: the same error placed in another
#   pass must not read as present / absent (不同). An unread uiErrors value
#   or entry is ① 无结果.
#
# Mutants (watch_page): an entry has catchers [{check, expected: [field
# names or "uiErrorKeys"]}]; caught = an expected field differs from the
# unmutated baseline (uiErrorKeys: an entry the baseline does not have).
# Any other must-same field differing is noise: rerun once; noise again is
# error, not caught. A report missing, unreadable, without its check or
# not measured is error (runner 补充①); so is an expected field missing or
# unread in either report (an image not there; uiErrors missing, unread or
# unplaceable). uiErrors lines go from the baseline to the mutant through
# the mutant's own patch: an error the patch only moved down a line is the
# same error; one inside the patch's changed lines is "PATCH:<file>" on
# either side. A network check (or one with uiErrorKeys the
# baseline lacks) whose report shows a retry / risk control, with any
# difference, is rerun once and judged by the rerun. A failing unmutated
# baseline is rerun once; failing again, that check's mutants are error
# and the run goes on (runner 补充②). "uncovered": "<why>" in an entry =
# 未覆盖: not run, listed. "pending": "<why>" = a mutant of a later step
# (S1b / S1c / S2, design §6.6 「落地」) whose patch and catchers are
# written in that step: it has a landing but no patch, location or
# catchers (any of them is refused); its landing must be one some phase of
# the plan's "phases" runs, other than S0 (today S1b, S1c, S2: a typo such
# as "S1B" is refused, not silently in no run); a run of another phase
# leaves it out, and a run of its own phase lists it "not written" (not
# caught: that run exits 1 until the step writes it).
# -PlanFile <file>: another watch_page plan (the offline self-test's); its
# patches are looked for beside it. Default test/mutants/wp-mutants.json.
#
# -Batch (watch_page; design 「批次场景开关」): by default checks with batch
# fullscreen or pip (their baselines, mutants and alternate runs) are
# SKIPPED; -Batch runs only those. Only inside a batch announced to the
# user beforehand (project CLAUDE.md 「会进全屏的自测」).
#
# -Alternate (runner 补充⑩): keeps two builds of the two commits in two
# worktrees, <Work>\wpA and <Work>\wpB (root paths of equal length, so
# paths baked into the debug builds truncate at the same place), installed
# in two slots (-Slot, -Slot2), and runs the unmutated checks parent, new,
# parent, new ... one pass at a time, each run with a new profile (or one
# restored from the table's snapshot). Reports go to <Out>\parent-<sha>\
# and <Out>\new-<sha>\ (one folder <Out>\<sha>\ when both are the same
# commit: the calibration runs); running again with the same -Out appends
# passes. Worktrees are kept for more passes (needed after a 需补跑) and
# removed with -Cleanup. -DryRun prints the run order and launches,
# builds and writes nothing.
# In the mutant mode -DryRun checks the plan (wp-mutants.json against
# the field tables, both ways), then lists the mutants -Phase / -Only /
# -Batch leave, each one's catchers, and every baseline's command line.
#
# -CheckTestSide <parent>,<child> (runner 补充④): the test side of S1 must
# be byte-identical: self_test.dart, self_test_probe.dart, the readings'
# self_test_watch.dart, run.ps1, wp_compare_selftest.ps1 and wp_fields/
# must each be in both commits
# (`git ls-tree`: an ignored file never committed has no diff to show) with
# the same blobs, every patch wp-mutants.json names must be there, and
# wp-mutants.json must be equal, case-sensitively, once each entry's
# "location" is dropped. Exit 1 when not. A side may be a folder laid out
# as the repository (the offline self-test's).
#
# The baseline manifest (both plans) also records windows/runner's tree
# (S0a changed flutter_window.cpp) and media hashes (ASR models for the
# transcribe scenario; wp-mutants.json "media" and table snapshots for
# watch_page); -SelfTestTree is checked for windows/runner too.
#
# -LoadOnly: dot-source the script for its functions only (the offline
# self-test of the comparison, wp_compare_selftest.ps1, does).
#
# COMMITTING: .gitignore has "test*" (line 152), so every file under test/
# is ignored: commit each file under test/mutants/ (run.ps1, wp-mutants.json,
# wp_fields/*.json, wp-*.patch, wp_origin_map.json, wp_compare_selftest.ps1,
# WP_REPORT_SHAPE.md) with `git add -f`. A plain `git add` leaves it out
# without a word, and then nothing frozen is frozen: -CheckTestSide refuses
# a frozen path that is not in both commits, and -Compare refuses field
# tables that are not HEAD's (without -FieldTables).
param(
    [string]$Commit = 'HEAD',
    # 0 / 1a / 1b: the download plan; S0 ... S2: watch_page (its manifest's
    # "phases")
    [ValidateSet('0', '1a', '1b', '2', 'S0', 'S1', 'S1b', 'S1c', 'S2')] [string]$Phase = '0',
    [string[]]$Only = @(),
    [ValidateRange(1, 3)] [int]$Slot = 1,
    [string]$Out = '',
    [string]$Baseline = '',
    [switch]$NoSelfTest,
    [string]$Flutter = '',
    [string[]]$Compare = @(),
    [int]$MinFreeMB = 4000,
    [int]$MemoryWaitMinutes = 10,
    [switch]$SelfTestAll,
    [string]$Work = '',
    [string]$SelfTestTree = '',
    [switch]$NoUnit,
    [string]$AsrModels = (Join-Path $env:APPDATA 'com.zxa24\LibrePili\selftest\asr'),
    # ---- watch_page (see "plans" above)
    [ValidateSet('', 'download', 'watch_page')] [string]$Plan = '',
    [switch]$Batch,
    [switch]$Alternate,
    [string]$Parent = '',
    [ValidateRange(1, 20)] [int]$Passes = 2,
    [string[]]$Checks = @(),
    [ValidateSet('', 'parent', 'new')] [string]$OnlySide = '',
    [ValidateRange(1, 3)] [int]$Slot2 = 0,
    [switch]$DryRun,
    [switch]$Cleanup,
    [string]$FieldTables = '',
    # the watch_page plan file (default test/mutants/wp-mutants.json beside
    # this script); its patches are looked for beside it. The offline
    # self-test passes a test plan here
    [string]$PlanFile = '',
    [string]$OriginMap = '',
    [string[]]$CheckTestSide = @(),
    [switch]$LoadOnly,
    # download plan, -Phase 2: result folders to check together (no run)
    [string[]]$Union = @()
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
# `pwsh -File` hands "a,b" over as one string
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Compare = @($Compare | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Checks = @($Checks | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$CheckTestSide = @($CheckTestSide | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

$here = $PSScriptRoot
$root = (git -C $here rev-parse --show-toplevel).Trim() -replace '/', '\'
# the main checkout (the slots and test-slot.ps1 live there, not in worktrees)
$common = (git -C $here rev-parse --path-format=absolute --git-common-dir).Trim() -replace '/', '\'
$main = Split-Path -Parent $common
$slotScript = Join-Path $main '.claude\test-slot.ps1'

$bvDownload = 'BV1CToXYMEDz'
$bvA = 'BV1LV411Q7np'; $bvB = 'BV1iw2YYCEv8'
$bvT = 'BV1fkaU6SE1F'

# ------------------------------------------------------------------ compare
$checkNames = @{ download = 'download'; queue99 = 'downloadQueue'; transcribe = 'downloadTranscribe'; listshots = 'downloadListShots' }

function J($v) { ConvertTo-Json -InputObject $v -Compress -Depth 50 }

function Get-Check($report, [string]$name) {
    if ($null -eq $report) { return $null }
    foreach ($c in @($report['checks'])) { if ($c['name'] -eq $name) { return $c } }
    return $null
}

function Read-Report([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try { Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable } catch { $null }
}

function Get-Field($map, [string]$key) {
    if ($null -eq $map) { return $null }
    # the comma keeps an array (also an empty or one-item one) as it is
    if ($map.Contains($key)) { return , $map[$key] }
    return $null
}

function Get-Lines($map, [string]$key) {
    $v = Get-Field $map $key
    if ($null -eq $v) { return , @() }
    return , @($v | Where-Object { $null -ne $_ } | ForEach-Object { "$_" })
}

# log lines -> their kinds: no time, no path, cids named, no numbers
function Get-LogKinds([string[]]$lines, [hashtable]$names) {
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $lines) {
        $s = $l -replace '^\d\d:\d\d:\d\d\.\d+ ', ''
        $s = $s -replace '[A-Za-z]:\\\S+', '<path>'
        foreach ($k in $names.Keys) { $s = $s.Replace("$k", $names[$k]) }
        $s = $s -replace '\d+(\.\d+)?', 'N'
        if ($out.Count -eq 0 -or $out[$out.Count - 1] -ne $s) { $out.Add($s) }
    }
    return , $out.ToArray()
}

function Get-PixelDiff([string]$a, [string]$b) {
    if (-not (Test-Path -LiteralPath $b)) { return 'missing' }
    if ((Get-FileHash -LiteralPath $a).Hash -eq (Get-FileHash -LiteralPath $b).Hash) { return 0 }
    if (-not ('MutantPixels' -as [type])) {
        # on .NET 9 and later Bitmap lives in System.Drawing.Common and its
        # interfaces in two System.Private.Windows assemblies (pwsh 7.6)
        $refs = @('System.Drawing.Common', 'System.Drawing.Primitives') + @(
            'System.Private.Windows.Core', 'System.Private.Windows.GdiPlus' | Where-Object {
                try { [void][System.Reflection.Assembly]::Load($_); $true } catch { $false }
            })
        Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class MutantPixels {
    static byte[] Read(string file, out int w, out int h) {
        using (var bmp = new Bitmap(file)) {
            w = bmp.Width; h = bmp.Height;
            var d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            var bytes = new byte[d.Stride * h];
            Marshal.Copy(d.Scan0, bytes, 0, bytes.Length);
            bmp.UnlockBits(d);
            return bytes;
        }
    }
    public static string Size(string file) {
        using (var bmp = new Bitmap(file)) return bmp.Width + "x" + bmp.Height;
    }
    public static long Diff(string a, string b) {
        int wa, ha, wb, hb;
        var x = Read(a, out wa, out ha);
        var y = Read(b, out wb, out hb);
        if (wa != wb || ha != hb) return -1;
        long n = 0;
        for (int i = 0; i < x.Length; i += 4)
            if (x[i] != y[i] || x[i + 1] != y[i + 1] || x[i + 2] != y[i + 2] || x[i + 3] != y[i + 3]) n++;
        return n;
    }
}
'@
    }
    $n = [MutantPixels]::Diff($a, $b)
    if ($n -lt 0) { return "size $([MutantPixels]::Size($a)) -> $([MutantPixels]::Size($b))" }
    return $n
}

# A shot of another size was taken at another screen scale (the window opens
# on whichever screen Windows picks: 1232x853 at 125 %, 1974x1369 at 200 %
# here), not changed by the mutant, so it is not compared. Such lines start
# with this and do not count as a catch.
$notCompared = 'not compared: '

# AC1's must-match fields of one scenario (design AC1 自测比较表, both builds
# with phase 0's fields). Returns the differences, the report's own failure
# first; empty = no difference.
function Compare-Scenario([string]$scenario, [string]$baseFile, [string]$mutFile) {
    $diffs = [System.Collections.Generic.List[string]]::new()
    $rb = Read-Report $baseFile; $rm = Read-Report $mutFile
    if ($null -eq $rb) { $diffs.Add("no baseline report $baseFile"); return , $diffs.ToArray() }
    if ($null -eq $rm) { $diffs.Add('no report (the self test did not finish)'); return , $diffs.ToArray() }
    $name = $checkNames[$scenario]
    $b = Get-Check $rb $name; $m = Get-Check $rm $name
    if ($null -eq $m) { $diffs.Add("no '$name' check in the report"); return , $diffs.ToArray() }
    if ($m['pass'] -ne $true) {
        $err = Get-Field $m 'error'
        $diffs.Add("pass: false$(if ($err) { " ($(("$err" -split "`n")[0]))" })")
    }
    $same = {
        param([string]$field, $x, $y)
        $jx = J $x; $jy = J $y
        if ($jx -ne $jy) {
            $sx = if ($jx.Length -gt 160) { $jx.Substring(0, 160) + '...' } else { $jx }
            $sy = if ($jy.Length -gt 160) { $jy.Substring(0, 160) + '...' } else { $jy }
            $diffs.Add("${field}: $sx -> $sy")
        }
    }
    switch ($scenario) {
        'download' {
            foreach ($f in 'quality', 'mergedExists', 'streamLeftovers', 'cleanedUp') { & $same $f (Get-Field $b $f) (Get-Field $m $f) }
            $eq = { param($c) (Get-Field $c 'entryJsonMergedPath') -eq (Get-Field $c 'mergedPath') }
            & $same 'entryJsonMergedPath == mergedPath' (& $eq $b) (& $eq $m)
            $rel = {
                param($c, $r)
                $p = Get-Field $c 'mergedPath'
                if ($null -eq $p) { return $null }
                [System.IO.Path]::GetRelativePath($r['downloadDir'], $p)
            }
            & $same 'mergedPath (relative to the download root)' (& $rel $b $rb) (& $rel $m $rm)
            foreach ($f in 'monotonic', 'final', 'savingExtrasAtCompletion', 'savingExtrasAfter', 'extrasPendingSaved') {
                & $same "progress.$f" (Get-Field (Get-Field $b 'progress') $f) (Get-Field (Get-Field $m 'progress') $f)
            }
            $names = {
                param($c)
                $ff = Get-Field $c 'folderFiles'
                if ($null -eq $ff) { return , @() }
                return , @($ff.Keys | Sort-Object)
            }
            & $same 'folderFiles names' (& $names $b) (& $names $m)
            foreach ($f in 'statusTransitions', 'entryJsonKeys', 'entryFields', 'exportFields', 'streamKey', 'mergedStreams') {
                & $same $f (Get-Field $b $f) (Get-Field $m $f)
            }
            & $same 'downloadLog' (Get-LogKinds (Get-Lines $b 'downloadLog') @{ "$($b['cid'])" = 'C' }) (Get-LogKinds (Get-Lines $m 'downloadLog') @{ "$($m['cid'])" = 'C' })
        }
        'queue99' {
            foreach ($f in 'damagedMerges', 'aAfterMerge', 'aStreamsAfterMerge', 'bInvisibleSeconds', 'aStatusTransitions', 'aExportFolderLeft', 'cidA', 'cidB') {
                & $same $f (Get-Field $b $f) (Get-Field $m $f)
            }
            $kinds = { param($c) Get-LogKinds (Get-Lines $c 'downloadLog') @{ "$($c['cidA'])" = 'A'; "$($c['cidB'])" = 'B' } }
            & $same 'downloadLog kinds' (& $kinds $b) (& $kinds $m)
            foreach ($msg in 'damaged streams removed', 'again in 10 s (1/3)', 'no more retries (merge)') {
                $cnt = { param($c) @((Get-Lines $c 'downloadLog') | Where-Object { $_.Contains($msg) }).Count }
                & $same "count '$msg'" (& $cnt $b) (& $cnt $m)
            }
            $cids = {
                param($c)
                $lead = "^($($c['cidA'])|$($c['cidB'])):"
                @((Get-Lines $c 'downloadLog') | Where-Object { ($_ -replace '^\d\d:\d\d:\d\d\.\d+ \[download\] ', '') -notmatch $lead }).Count -eq 0
            }
            & $same 'downloadLog lines start with <cid>:' (& $cids $b) (& $cids $m)
        }
        'transcribe' {
            $cb = Get-Field $b 'checks'; $cm = Get-Field $m 'checks'
            $keys = @(@(if ($cb) { $cb.Keys }) + @(if ($cm) { $cm.Keys }) | Select-Object -Unique)
            foreach ($k in $keys) { & $same "checks.$k" (Get-Field $cb $k) (Get-Field $cm $k) }
            foreach ($f in 'states', 'runningSeen', 'runningKeys', 'videoSeconds') { & $same $f (Get-Field $b $f) (Get-Field $m $f) }
            $ev = { param($c) , @((Get-Lines $c 'events') | ForEach-Object { $_ -replace '^\d\d:\d\d:\d\d\.\d+ ', '' }) }
            & $same 'events' (& $ev $b) (& $ev $m)
            $tl = { param($c) , @((Get-Lines $c 'timeline') | ForEach-Object { ($_ -split ': ', 2)[-1] }) }
            & $same 'timeline labels' (& $tl $b) (& $tl $m)
        }
        'listshots' {
            foreach ($f in 'entries', 'seasonBadge', 'entryMenu', 'groupMenu', 'searchHits') { & $same $f (Get-Field $b $f) (Get-Field $m $f) }
            $mutShots = @{}
            foreach ($s in (Get-Lines $m 'shots')) { $mutShots[[System.IO.Path]::GetFileName($s)] = $s }
            foreach ($s in (Get-Lines $b 'shots')) {
                $n = [System.IO.Path]::GetFileName($s)
                $d = if ($mutShots.ContainsKey($n)) { Get-PixelDiff $s $mutShots[$n] } else { 'missing' }
                if ("$d" -like 'size *') { $diffs.Add("${notCompared}shot ${n}: $d (another screen scale)") }
                elseif ("$d" -ne '0') { $diffs.Add("shot ${n}: $d differing pixels") }
            }
        }
    }
    return , $diffs.ToArray()
}

# ================================================================== watch_page
# The watch_page plan's comparison (design §5 「多份报告的判法」, 「uiErrors」,
# 「AC-S1 的比较」). -Compare and the mutant judge share these functions:
# AC-S1 (b) re-running every mutant through them is what proves that the
# comparison reports a changed field, so there is only one implementation
# (and it lives in this file because S1 must leave run.ps1 byte-identical).

$wpFieldsDir = if ($FieldTables) { $FieldTables } else { Join-Path $here 'wp_fields' }
$wpManifestFile = if ($PlanFile) { [System.IO.Path]::GetFullPath($PlanFile) } else { Join-Path $here 'wp-mutants.json' }
# a mutant's patch: beside its plan file (watch_page; test/mutants for the
# default plan) or beside this script (the download plan)
function Get-PatchDir { if ($script:wp) { Split-Path -Parent $wpManifestFile } else { $here } }
# a network retry or risk control in an online report: the download plan's
# retry words, the event log's "[captcha]" area (lines "HH:MM:SS.mmm
# [area] message"; only the risk check's captcha pages log there, not a
# word "captcha" anywhere), 验证码 / 风控, and B 站's risk-control codes -352
# / -412 as whole numbers (not -352.0, a coordinate, nor x-3520)
$wpRerunDefault = 'retryWait|again in|\[captcha\]|验证码|风控|(?<![\w.-])-(352|412)(?![\w.])'
# the reports' pass folders
$wpPassPattern = '^pass(\d+)$'
# at this many reports a side a difference is final (④ ⑤); below it, rerun
$wpFinal = 4
$wpMinimum = 2

# verdicts: the code (results.json) and the design's own word (compare.md)
$wpLabel = [ordered]@{
    same = '相同'; different = '不同'; differentNew = '不同（仅本步不稳）'
    rerun = '需补跑'; noResult = '无结果'; notComparable = '无法比较'
    unstable = '不稳定'; tableUnstable = '不稳定（表）'
}

# JSON text -> hashtables. Dates stay strings (-DateKind String): read as
# DateTime, two writings of one instant with different offsets compared
# equal, and a report's text is what is compared
function ConvertFrom-WpJsonText([string]$text) {
    return $text | ConvertFrom-Json -AsHashtable -DateKind String
}

function Read-WpJson([string]$file) {
    try { return ConvertFrom-WpJsonText (Get-Content -LiteralPath $file -Raw -Encoding utf8) }
    catch { throw "cannot read $file as JSON: $($_.Exception.Message)" }
}

# "a.b[2].c" from $obj; "@a.b" from $rootObj. Returns @{ found; value }:
# a key that is not there is not found, a key whose value is null is found
function Get-WpValue($obj, [string]$path, $rootObj = $null) {
    $cur = $obj
    if ($path.StartsWith('@')) { $cur = $rootObj; $path = $path.Substring(1) }
    if ($path -eq '') { return @{ found = ($null -ne $cur); value = $cur } }
    foreach ($seg in ($path -split '\.')) {
        if ($seg -notmatch '^(?<k>[^\[\]]*)(?<i>(\[\d+\])*)$') { return @{ found = $false; value = $null } }
        $k = $Matches['k']; $idx = $Matches['i']
        if ($k -ne '') {
            if ($cur -isnot [System.Collections.IDictionary] -or -not $cur.Contains($k)) { return @{ found = $false; value = $null } }
            $cur = $cur[$k]
        }
        foreach ($mi in [regex]::Matches($idx, '\[(\d+)\]')) {
            $i = [int]$mi.Groups[1].Value
            if ($cur -isnot [System.Collections.IList] -or $i -ge $cur.Count) { return @{ found = $false; value = $null } }
            $cur = $cur[$i]
        }
    }
    return @{ found = $true; value = $cur }
}

# key order and numbers made canonical, so two reports of the same value
# compare equal as text: keys sorted ordinally, a number by its value (1,
# 1.0 and 1e0 are all "1"; Dart writes a double 1 as 1.0, an int as 1)
function ConvertTo-WpCanon($v) {
    if ($null -eq $v) { return 'null' }
    if ($v -is [bool]) { return $(if ($v) { 'true' } else { 'false' }) }
    if ($v -is [double] -or $v -is [single] -or $v -is [decimal]) {
        $d = [double]$v
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return J "$d" }
        if ($d -eq [Math]::Floor($d) -and [Math]::Abs($d) -lt 1e15) { return ([long]$d).ToString([Globalization.CultureInfo]::InvariantCulture) }
        return $d.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($v -is [long] -or $v -is [int] -or $v -is [System.Numerics.BigInteger]) { return $v.ToString([Globalization.CultureInfo]::InvariantCulture) }
    if ($v -is [System.Collections.IDictionary]) {
        [string[]]$keys = @($v.Keys | ForEach-Object { "$_" })
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        return '{' + (($keys | ForEach-Object { (J $_) + ':' + (ConvertTo-WpCanon $v[$_]) }) -join ',') + '}'
    }
    if ($v -is [System.Collections.IList]) {
        return '[' + ((@($v) | ForEach-Object { ConvertTo-WpCanon $_ }) -join ',') + ']'
    }
    return J $v
}

# {"$unread": "<why>"} anywhere in a value: the accessor could not read it
function Test-WpUnread($v) {
    if ($v -is [System.Collections.IDictionary]) {
        if ($v.Contains('$unread')) { return $true }
        foreach ($k in @($v.Keys)) { if (Test-WpUnread $v[$k]) { return $true } }
        return $false
    }
    if ($v -is [System.Collections.IList]) {
        foreach ($x in @($v)) { if (Test-WpUnread $x) { return $true } }
    }
    return $false
}

function Format-WpShort([string]$s, [int]$max = 160) {
    if ($s.Length -gt $max) { return $s.Substring(0, $max) + '...' }
    return $s
}

# ------------------------------------------------------------------ watch_page: field tables
function Test-WpFieldTable($t, [string]$fileId) {
    $errs = [System.Collections.Generic.List[string]]::new()
    if ($t -isnot [System.Collections.IDictionary]) { $errs.Add('not an object'); return , $errs.ToArray() }
    if ($t['id'] -ne $fileId) { $errs.Add("id '$($t['id'])' is not the file name '$fileId'") }
    foreach ($k in 'check', 'report') { if (-not ($t[$k] -is [string] -and $t[$k])) { $errs.Add("no $k") } }
    if ($t['type'] -notin 'judging', 'recording') { $errs.Add("type must be judging or recording, not '$($t['type'])'") }
    # required, not defaulted: a table that forgot it would run outside a
    # batch even if it covers the screen (design 「批次场景开关」)
    if (-not $t.Contains('batch')) { $errs.Add('no batch: say null, fullscreen or pip') }
    elseif ($null -ne $t['batch'] -and $t['batch'] -notin 'fullscreen', 'pip') { $errs.Add("batch must be null, fullscreen or pip") }
    $names = @{}
    foreach ($f in @($t['fields'])) {
        if ($f -isnot [System.Collections.IDictionary] -or -not $f['name'] -or -not ($f['path'] -is [string])) { $errs.Add('a field without name or path'); continue }
        if ($names.ContainsKey($f['name'])) { $errs.Add("field $($f['name']) twice") }
        $names[$f['name']] = $true
        if ($f['name'] -eq 'uiErrorKeys') { $errs.Add('uiErrorKeys is the uiErrors entry, not a field') }
        if ($f['status'] -notin 'must-same', 'unstable') { $errs.Add("field $($f['name']): status must be must-same or unstable") }
        if ($f['status'] -eq 'unstable' -and @($f['expectedFor']).Where({ $_ }).Count) { $errs.Add("field $($f['name']) is unstable: it cannot be a mutant's expected field") }
        if ($f.Contains('type') -and $f['type'] -notin 'value', 'shot') { $errs.Add("field $($f['name']): type must be value or shot") }
    }
    if (-not $t.Contains('fields') -or @($t['fields']).Count -eq 0) { $errs.Add('no fields') }
    $u = $t['uiErrors']
    if ($null -ne $u -and $u['status'] -notin 'must-same', 'unstable', 'none') { $errs.Add('uiErrors.status must be must-same, unstable or none') }
    if ($null -ne $u -and $u.Contains('optional') -and $u['optional'] -isnot [bool]) { $errs.Add('uiErrors.optional must be true or false') }
    $pre = @($t['preconditions'] | Where-Object { $_ })
    foreach ($p in $pre) { if (-not $p['path'] -or -not $p.Contains('equals')) { $errs.Add('a precondition without path or equals') } }
    $run = $t['run']
    if ($null -ne $run) {
        if ($run['args'] -isnot [System.Collections.IList]) { $errs.Add('run.args must be a list') }
        $pf = "$($run['profile'])"
        if ($pf -and $pf -ne 'fresh' -and -not $pf.StartsWith('snapshot:')) { $errs.Add("run.profile must be fresh or snapshot:<dir>") }
    }
    return , $errs.ToArray()
}

function Get-WpFieldTables([string]$dir) {
    $tables = [ordered]@{}
    $examples = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter *.json -File | Sort-Object Name)) {
            if ($f.Name.StartsWith('_')) { continue }
            $t = Read-WpJson $f.FullName
            if ($t -is [System.Collections.IDictionary] -and $t['example'] -eq $true) { $examples.Add($f.BaseName); continue }
            $errs = Test-WpFieldTable $t $f.BaseName
            if ($errs.Count) { throw "field table $($f.FullName): $($errs -join '; ')" }
            $tables[$t['id']] = $t
        }
    }
    # tables sharing a report share one run: one command line writes that
    # file, so their run must be the same (Get-WpRunGroups runs it once)
    $byReport = @{}
    foreach ($t in $tables.Values) {
        $r = "$($t['report'])"
        $run = ConvertTo-WpCanon $t['run']
        if ($byReport.ContainsKey($r) -and $byReport[$r].run -cne $run) {
            throw "field tables $($byReport[$r].id) and $($t['id']) both read $r but name different runs: one command line writes one report"
        }
        if (-not $byReport.ContainsKey($r)) { $byReport[$r] = @{ id = $t['id']; run = $run } }
    }
    return @{ tables = $tables; examples = $examples.ToArray(); dir = $dir }
}

# the runs a set of tables needs: one per report file (tables sharing a
# report share its command line), in the tables' order
function Get-WpRunGroups($tables) {
    $groups = [ordered]@{}
    foreach ($t in @($tables | Where-Object { $_ })) {
        $k = "$($t['report'])"
        if (-not $groups.Contains($k)) { $groups[$k] = @{ key = $k; t = $t; tables = [System.Collections.Generic.List[object]]::new() } }
        $groups[$k].tables.Add($t)
    }
    return , @($groups.Values)
}

function Get-WpUiSpec($t) {
    $u = $t['uiErrors']
    $status = if ($null -ne $u -and $u['status']) { $u['status'] } else { 'must-same' }
    $path = if ($null -ne $u -and $u['path']) { $u['path'] } else { 'uiErrors' }
    $unstable = if ($null -ne $u) { @($u['unstable'] | Where-Object { $_ }) } else { @() }
    $expectedFor = if ($null -ne $u) { @($u['expectedFor'] | Where-Object { $_ }) } else { @() }
    # a missing uiErrors key reads as "no errors" only for today's reports
    # (measured.legacy: they write it only when there are some) or a table
    # that says so; from S0b on the key is always written, and its absence
    # is ① 无结果 (a broken writer would otherwise read as 相同)
    $m = $t['measured']
    $optional = ($m -is [System.Collections.IDictionary] -and $m.Contains('legacy')) -or ($null -ne $u -and $u['optional'] -eq $true)
    return @{ status = $status; path = $path; unstable = $unstable; expectedFor = $expectedFor; optional = $optional }
}

# ------------------------------------------------------------------ watch_page: report folders
function Get-WpRoot($manifest) {
    $r = "$($manifest['root'])"
    if (-not $r) { return '' }
    return ($r -replace '\\', '/').TrimEnd('/')
}

function Resolve-WpCommit([string]$rev, [string]$what) {
    $s = git -C $root rev-parse --verify --quiet "$rev^{commit}" 2>$null
    if ($LASTEXITCODE -or -not $s) { throw "$what`: $rev is not a commit of this repository" }
    return "$s".Trim()
}

# the trees a report folder's results depend on (both plans' manifests)
function Get-WpTrees([string]$sha) {
    [ordered]@{
        lib = (git -C $root rev-parse "${sha}:lib").Trim()
        fixtures = (git -C $root rev-parse "${sha}:test/fixtures").Trim()
        windowsRunner = (git -C $root rev-parse "${sha}:windows/runner").Trim()
    }
}

# A pass folder may say which checks it ran (pass.json, { "checks": [ids] },
# written by -Alternate before the pass runs): a pass that did not run a
# check is not that check's pass, so a rerun of one check (-Checks, a
# batch run into the same -Out) leaves the others' rows as they were. No
# pass.json = every check ran in it (hand-made folders).
function Get-WpPassDirs([string]$dir) {
    return , @(Get-ChildItem -LiteralPath $dir -Directory | Where-Object { $_.Name -match $wpPassPattern } |
            Sort-Object { [int]($_.Name -replace '^pass', '') } | ForEach-Object {
                $pj = Join-Path $_.FullName 'pass.json'
                $ch = if (Test-Path -LiteralPath $pj) { @((Read-WpJson $pj)['checks'] | ForEach-Object { "$_" }) } else { $null }
                @{ name = $_.Name; dir = $_.FullName; checks = $ch }
            })
}

function Test-WpPassRan($pass, $t) {
    return $null -eq $pass.checks -or $pass.checks -contains $t['id']
}

function Read-WpSide([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "-Compare: no folder $dir" }
    $dir = (Resolve-Path -LiteralPath $dir).Path
    $mf = Join-Path $dir 'manifest.json'
    if (-not (Test-Path -LiteralPath $mf)) {
        throw "-Compare: $dir has no manifest.json, so its commit is unknown (runner mode ⑩ writes one; design §5 「AC-S1 的比较」): refused"
    }
    $m = Read-WpJson $mf
    if ($m['plan'] -ne 'watch_page') { throw "-Compare: $mf is not a watch_page manifest (plan '$($m['plan'])')" }
    if (-not $m['commit']) { throw "-Compare: $mf names no commit" }
    $sha = Resolve-WpCommit $m['commit'] "the manifest of $dir"
    # a manifest that names a commit its trees do not match is wrong about
    # what was run
    $trees = Get-WpTrees $sha
    foreach ($k in $trees.Keys) {
        if ($m.Contains($k) -and $m[$k] -and $m[$k] -ne $trees[$k]) { throw "-Compare: $mf says $k $($m[$k]), but $sha's $k is $($trees[$k])" }
    }
    $passes = Get-WpPassDirs $dir
    if ($passes.Count -eq 0) { $passes = @(@{ name = '.'; dir = $dir }) }
    return @{ dir = $dir; manifest = $m; sha = $sha; trees = $trees; passes = $passes; root = (Get-WpRoot $m) }
}

function Test-WpParentOf([string]$parent, [string]$child) {
    $line = "$(git -C $root rev-list --parents -n 1 $child)".Trim()
    return @($line -split ' ' | Select-Object -Skip 1) -contains $parent
}

# ------------------------------------------------------------------ watch_page: origins
$script:wpPackage = $null
function Get-WpPackage {
    if ($null -eq $script:wpPackage) {
        $hit = Select-String -LiteralPath (Join-Path $root 'pubspec.yaml') -Pattern '^name:\s*(\S+)' | Select-Object -First 1
        $script:wpPackage = if ($hit) { $hit.Matches[0].Groups[1].Value } else { '' }
    }
    return $script:wpPackage
}

# a dart location in text: package:…, file:///X:/…, X:\…, or lib/… test/…
$wpLocPattern = '(?<p>package:[\w.]+/[^\s:()''"]+?\.dart|file:///[A-Za-z]:/[^\s:()''"]+?\.dart|[A-Za-z]:[\\/][^\s:()''"]+?\.dart|(?<![\w/])(?:lib|test)/[^\s:()''"]+?\.dart):(?<l>\d+)'

# -> @{ file; line; repo } (repo = a path inside this repository, made
# relative to it), or $null when the text holds no dart location. The
# worktree root is taken out of the text first, so a root with spaces in it
# (or %20 in a file:/// URI) still leaves lib/…:L to find. $cutAt: the text
# was cut at that length (today's 320 characters); a line number running
# into the cut may have lost digits (":132" cut to ":13") and is not read
function ConvertTo-WpLoc([string]$text, [string]$rootNorm, [int]$cutAt = -1) {
    if (-not $text) { return $null }
    $t = $text
    if ($rootNorm) {
        $t = $t -replace '\\', '/'
        foreach ($r in @($rootNorm, ($rootNorm -replace ' ', '%20')) | Select-Object -Unique) {
            $t = [regex]::Replace($t, '(file:///)?' + [regex]::Escape($r) + '/', '', 'IgnoreCase')
        }
    }
    $m = [regex]::Match($t, $wpLocPattern)
    if (-not $m.Success) { return $null }
    # where the cut lies in $t (the root taken out before it shortens it)
    if ($cutAt -gt 0 -and $text.Length -ge $cutAt -and $m.Index + $m.Length -ge $cutAt - ($text.Length - $t.Length)) { return $null }
    $p = $m.Groups['p'].Value; $line = [int]$m.Groups['l'].Value
    $pkg = Get-WpPackage
    if ($pkg -and $p.StartsWith("package:$pkg/")) { return @{ file = 'lib/' + $p.Substring("package:$pkg/".Length); line = $line; repo = $true } }
    if ($p.StartsWith('package:')) { return @{ file = $p; line = $line; repo = $false } }
    if ($p.StartsWith('file:///')) { $p = $p.Substring(8) }
    $p = $p -replace '\\', '/'
    if ($p -match '^(lib|test)/') { return @{ file = $p; line = $line; repo = $true } }
    if ($rootNorm -and $p.StartsWith("$rootNorm/", [StringComparison]::OrdinalIgnoreCase)) {
        return @{ file = $p.Substring($rootNorm.Length + 1); line = $line; repo = $true }
    }
    return @{ file = $p; line = $line; repo = $false }
}

# A structured origin ("lib/x.dart:132:11", "file:///C:/a b/wpA/lib/x.dart:
# 132", "C:\a b\wpA\lib\x.dart:132"): the whole string is the location, so
# spaces and %-escapes are part of the path
function ConvertTo-WpOrigin([string]$origin, [string]$rootNorm) {
    $o = $origin.Trim()
    if ($o.StartsWith('file:///')) { $o = [uri]::UnescapeDataString($o.Substring(8)) }
    $o = $o -replace '\\', '/'
    if ($o -notmatch '^(?<p>.+?\.dart):(?<l>\d+)(?::\d+)?$') { return $null }
    $p = $Matches['p']; $line = [int]$Matches['l']
    $pkg = Get-WpPackage
    if ($pkg -and $p.StartsWith("package:$pkg/")) { return @{ file = 'lib/' + $p.Substring("package:$pkg/".Length); line = $line; repo = $true } }
    if ($p.StartsWith('package:')) { return @{ file = $p; line = $line; repo = $false } }
    if ($p -match '^(lib|test)/') { return @{ file = $p; line = $line; repo = $true } }
    if ($rootNorm -and $p.StartsWith("$rootNorm/", [StringComparison]::OrdinalIgnoreCase)) {
        return @{ file = $p.Substring($rootNorm.Length + 1); line = $line; repo = $true }
    }
    return @{ file = $p; line = $line; repo = $false }
}

function Read-WpOriginMap([string]$childSha) {
    $rows = @()
    $from = ''
    if ($OriginMap) {
        $doc = Read-WpJson $OriginMap
        $from = $OriginMap
    } else {
        git -C $root cat-file -e "${childSha}:test/mutants/wp_origin_map.json" 2>$null
        if ($LASTEXITCODE) { return @{ rows = @(); from = "(none in $childSha)" } }
        $doc = ConvertFrom-WpJsonText ((git -C $root show "${childSha}:test/mutants/wp_origin_map.json") -join "`n")
        $from = "${childSha}:test/mutants/wp_origin_map.json"
    }
    foreach ($r in @($doc['rows'])) {
        foreach ($s in 'parent', 'child') {
            if (-not $r[$s] -or -not $r[$s]['file'] -or -not $r[$s]['start'] -or -not $r[$s]['end']) { throw "origin map $from`: row '$($r['id'])' has no $s file / start / end" }
        }
        $same = $r['sameLength'] -ne $false
        if ($same -and ($r['parent']['end'] - $r['parent']['start']) -ne ($r['child']['end'] - $r['child']['start'])) {
            throw "origin map $from`: row '$($r['id'])' is not marked sameLength false, but its two ranges differ in length"
        }
        $rows += , @{ id = "$($r['id'])"; parent = $r['parent']; child = $r['child']; sameLength = $same }
    }
    return @{ rows = $rows; from = $from }
}

function New-WpDiffContext([string]$parent, [string]$child) {
    $changed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($f in @(git -C $root diff --name-only --no-renames $parent $child)) { if ($f) { [void]$changed.Add("$f".Trim()) } }
    return @{ parent = $parent; child = $child; changed = $changed; hunks = @{}; map = (Read-WpOriginMap $child); patch = $false; rootsDiffer = $false }
}

# The changes a mutant's patch makes, as the -U0 hunks Get-WpLocToken
# reads: a baseline report is the "parent", the mutant's the "child", so an
# error the patch only moved (a line added above it) keeps its key. A
# location inside the patch's own changed lines has no map; it becomes
# "PATCH:<file>" on either side, so an error in the mutated lines is one
# key whether the baseline had it or not.
function Read-WpPatchContext([string]$patchFile) {
    $changed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $hunks = @{}
    $st = @{ file = $null; h = $null; o = 0; n = 0; inHunk = $false }
    $flush = {
        if ($null -ne $st.h) {
            $h = $st.h
            # -U0 style: an insertion is "after old line os", a deletion
            # "after new line ns"
            if ($h.oc -eq 0) { $h.os-- }
            if ($h.nc -eq 0) { $h.ns-- }
            if (-not $hunks.ContainsKey($st.file)) { $hunks[$st.file] = [System.Collections.Generic.List[object]]::new() }
            $hunks[$st.file].Add($h)
            [void]$changed.Add($st.file)
            $st.h = $null
        }
    }
    foreach ($l in @(Get-Content -LiteralPath $patchFile)) {
        if ($l -match '^diff --git a/(\S+) b/(\S+)') { . $flush; $st.file = $Matches[2]; $st.inHunk = $false; continue }
        if (-not $st.inHunk -and $l -match '^\+\+\+ b/(.+)$') { $st.file = $Matches[1].Trim(); continue }
        if (-not $st.inHunk -and $l -match '^(---|\+\+\+) ') { continue }
        if ($l -match '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@') {
            . $flush
            # a header count of 0 already means "after this line"
            $st.o = [int]$Matches[1] + $(if ($Matches[2] -eq '0') { 1 } else { 0 })
            $st.n = [int]$Matches[3] + $(if ($Matches[4] -eq '0') { 1 } else { 0 })
            $st.inHunk = $true; continue
        }
        if (-not $st.inHunk) { continue }
        $c = if ($l.Length) { $l[0] } else { ' ' }
        if ($c -eq '\') { continue }
        if ($c -eq '-' -or $c -eq '+') {
            if ($null -eq $st.h) { $st.h = @{ os = $st.o; oc = 0; ns = $st.n; nc = 0 } }
            if ($c -eq '-') { $st.h.oc++; $st.o++ } else { $st.h.nc++; $st.n++ }
        } else { . $flush; $st.o++; $st.n++ }
    }
    . $flush
    $cache = @{}
    foreach ($k in $hunks.Keys) { $cache[$k] = $hunks[$k].ToArray() }
    return @{ parent = 'baseline'; child = 'mutant'; changed = $changed; hunks = $cache; map = @{ rows = @(); from = "(the mutant's patch)" }; patch = $true; rootsDiffer = $false }
}

# `git diff -U0` hunks of one file: old start / count, new start / count
function Get-WpHunks($dctx, [string]$file) {
    if (-not $dctx.hunks.ContainsKey($file)) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($l in @(git -C $root diff -U0 --no-renames --no-color $dctx.parent $dctx.child -- $file)) {
            if ("$l" -match '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@') {
                $list.Add(@{
                        os = [int]$Matches[1]; oc = $(if ($Matches[2]) { [int]$Matches[2] } else { 1 })
                        ns = [int]$Matches[3]; nc = $(if ($Matches[4]) { [int]$Matches[4] } else { 1 })
                    })
            }
        }
        $dctx.hunks[$file] = $list.ToArray()
    }
    return , $dctx.hunks[$file]
}

# A location as compared between the two commits (design §5 「uiErrors」
# ①-③). -> @{ ok; token; why }
function Get-WpLocToken($loc, [string]$side, $dctx) {
    $plain = "F:$($loc.file):$($loc.line)"
    if (-not $loc.repo -or $null -eq $dctx -or -not $dctx.changed.Contains($loc.file)) { return @{ ok = $true; token = $plain } }
    $L = $loc.line
    $inBlock = $false; $shift = 0
    foreach ($h in (Get-WpHunks $dctx $loc.file)) {
        if ($side -eq 'parent') {
            if ($h.oc -gt 0 -and $L -ge $h.os -and $L -le $h.os + $h.oc - 1) { $inBlock = $true; break }
            $before = if ($h.oc -gt 0) { $h.os + $h.oc - 1 -lt $L } else { $h.os -lt $L }
            if ($before) { $shift += $h.nc - $h.oc }
        } elseif ($h.nc -gt 0 -and $L -ge $h.ns -and $L -le $h.ns + $h.nc - 1) { $inBlock = $true; break }
    }
    if (-not $inBlock) {
        if ($side -eq 'parent') { return @{ ok = $true; token = "F:$($loc.file):$($L + $shift)" } }
        return @{ ok = $true; token = $plain }
    }
    if ($dctx.patch) { return @{ ok = $true; token = "PATCH:$($loc.file)" } }
    $range = if ($side -eq 'parent') { 'parent' } else { 'child' }
    foreach ($r in $dctx.map.rows) {
        $g = $r[$range]
        if ($g['file'] -eq $loc.file -and $L -ge $g['start'] -and $L -le $g['end']) {
            if ($r.sameLength) { return @{ ok = $true; token = "M:$($r.id)+$($L - $g['start'])" } }
            return @{ ok = $true; token = "M:$($r.id)" }
        }
    }
    return @{ ok = $false; token = $plain; why = "$($loc.file):$L ($side side) is in a block the step changed, and no row of the origin map ($($dctx.map.from)) covers it" }
}

# the assertion's first sentence, numbers removed ("A RenderFlex overflowed
# by pixels on the right")
function Get-WpErrorKind([string]$text) {
    $t = $text -replace '^\s*\u2550+\u2561[^\u255e]*\u255e\u2550*\s*', ''
    $k = if ($t -match 'was thrown[^:]*:\s*(?<k>.+?)(?:\.\s|\.$| The relevant |$)') { $Matches['k'] } else { ($t -split '\.\s', 2)[0] }
    return (($k -replace '\d+(\.\d+)?', '') -replace '\s+', ' ').Trim()
}

function Remove-WpRoot([string]$text, [string]$rootNorm) {
    if (-not $rootNorm) { return $text }
    $t = $text -replace '\\', '/'
    $t = [regex]::Replace($t, '(file:///)?' + [regex]::Escape($rootNorm) + '/', '', 'IgnoreCase')
    return $t
}

# one uiErrors entry -> @{ ok; key; weak; why; prefix }. prefix = the key
# without its location: an entry that cannot be placed (ok false) blocks
# every key of that prefix from reading as present / absent (无法比较)
function Get-WpUiErrorKey($entry, [string]$rootNorm, [string]$side, $dctx) {
    $weak = $false; $where = $null
    if ($entry -is [System.Collections.IDictionary]) {
        if (Test-WpUnread $entry) { return @{ ok = $false; key = '?'; weak = $false; why = "an unread entry $(ConvertTo-WpCanon $entry)"; prefix = '?' } }
        $text = "$($entry['text'])"
        $kind = if ($entry['kind']) { (("$($entry['kind'])" -replace '\d+(\.\d+)?', '') -replace '\s+', ' ').Trim() } else { Get-WpErrorKind $text }
        $widget = "$($entry['widget'])"
        $context = "$($entry['context'])"
        $loc = if ($entry['origin']) { ConvertTo-WpOrigin "$($entry['origin'])" $rootNorm } else { $null }
        if ($entry['origin'] -and $null -eq $loc) {
            # "lib/x.dart:132" is matched; anything else is not an origin
            return @{ ok = $false; key = "$kind | $widget | ?"; weak = $false; why = "origin '$($entry['origin'])' is not a file:line"; prefix = "$kind | $widget" }
        }
        if ($null -eq $loc) {
            $weak = $true
            foreach ($fr in @($entry['frames'] | Where-Object { $_ })) { $loc = ConvertTo-WpLoc "$fr" $rootNorm; if ($loc) { break } }
            $where = $context
        }
        $fallback = $null
    } elseif ($entry -isnot [string]) {
        return @{ ok = $false; key = '?'; weak = $false; why = "an entry that is neither text nor an object: $(ConvertTo-WpCanon $entry)"; prefix = '?' }
    } else {
        $text = "$entry"
        $rest = $text; $frames = ''; $info = ''; $context = ''
        $i = $rest.LastIndexOf(' ## '); if ($i -ge 0) { $frames = $rest.Substring($i + 4); $rest = $rest.Substring(0, $i) }
        $i = $rest.IndexOf(' :: '); if ($i -ge 0) { $info = $rest.Substring($i + 4); $rest = $rest.Substring(0, $i) }
        $i = $rest.LastIndexOf(' @ '); if ($i -ge 0) { $context = $rest.Substring($i + 3); $rest = $rest.Substring(0, $i) }
        $kind = Get-WpErrorKind $rest
        $widget = if ("$rest $info" -match 'error-causing widget was:?\s+(?<w>[A-Za-z_$][\w$]*)') { $Matches['w'] } else { '' }
        if ($null -ne $dctx -and $dctx.rootsDiffer) {
            # the cut falls at 320 characters of a text holding the
            # worktree's absolute path: roots of different length cut it
            # in different places (design §5 S0a 「核对」)
            return @{ ok = $false; key = "$kind | $widget | ?"; weak = $false; why = 'the two folders'' worktree roots differ in length, so today''s 320-character texts are cut in different places'; prefix = "$kind | $widget" }
        }
        # today's entries carry no origin: the error-causing widget's
        # file:///…:L, when the 320-character cut left it in the text (and
        # did not cut into its line number)
        $loc = ConvertTo-WpLoc $rest $rootNorm 320
        if ($null -eq $loc) { $loc = ConvertTo-WpLoc $info $rootNorm }
        if ($null -eq $loc) {
            $weak = $true; $where = $context
            foreach ($fr in ($frames -split ' \| ')) { $loc = ConvertTo-WpLoc $fr $rootNorm; if ($loc) { break } }
        }
        $fallback = ((Remove-WpRoot $rest $rootNorm) -replace '\d+(\.\d+)?', '') -replace '\s+', ' '
    }
    if ($null -eq $loc) {
        if ($null -ne $fallback) { return @{ ok = $true; key = "$kind | $where | text:$($fallback.Trim())"; weak = $true; prefix = "$kind | $where" } }
        return @{ ok = $true; key = "$kind | $where"; weak = $true; prefix = "$kind | $where" }
    }
    $tok = Get-WpLocToken $loc $side $dctx
    $mid = if ($weak) { $where } else { $widget }
    return @{ ok = $tok.ok; key = "$kind | $mid | $($tok.token)"; weak = $weak; why = $tok['why']; prefix = "$kind | $mid" }
}

# ------------------------------------------------------------------ watch_page: one report
# The state of one pass of one check. -> @{ pass; file; state; why; check;
# report; raw }. state: ok | no report | unreadable | no check | not
# measured | precondition
function Get-WpPassState($t, [string]$passName, [string]$file) {
    $s = @{ pass = $passName; file = $file; state = 'ok'; why = ''; check = $null; report = $null; raw = '' }
    if (-not (Test-Path -LiteralPath $file)) { $s.state = 'no report'; $s.why = "no $($t['report'])"; return $s }
    $s.raw = Get-Content -LiteralPath $file -Raw -Encoding utf8
    try { $s.report = ConvertFrom-WpJsonText $s.raw } catch { $s.state = 'unreadable'; $s.why = "$file is not JSON"; return $s }
    $s.check = Get-Check $s.report $t['check']
    if ($null -eq $s.check) { $s.state = 'no check'; $s.why = "no '$($t['check'])' check in $($t['report'])"; return $s }
    $m = $t['measured']
    if ($m -is [System.Collections.IDictionary] -and $m.Contains('legacy')) {
        foreach ($p in @($m['legacy'])) {
            $v = Get-WpValue $s.check "$p" $s.report
            if (-not $v.found -or (Test-WpUnread $v.value)) { $s.state = 'not measured'; $s.why = "$p missing (today's report: the check did not get that far)"; return $s }
        }
    } else {
        $p = if ($m -is [string] -and $m) { $m } else { 'measured' }
        $v = Get-WpValue $s.check $p $s.report
        # the boolean true only: "true", 1 or [true] are not a measurement
        if (-not $v.found -or $v.value -isnot [bool] -or -not $v.value) { $s.state = 'not measured'; $s.why = "$p is $(if ($v.found) { ConvertTo-WpCanon $v.value } else { 'missing' })"; return $s }
    }
    foreach ($pc in @($t['preconditions'] | Where-Object { $_ })) {
        $v = Get-WpValue $s.check "$($pc['path'])" $s.report
        if (-not $v.found -or (ConvertTo-WpCanon $v.value) -ne (ConvertTo-WpCanon $pc['equals'])) {
            $s.state = 'precondition'; $s.why = "$($pc['path']) is $(if ($v.found) { ConvertTo-WpCanon $v.value } else { 'missing' }), not $(ConvertTo-WpCanon $pc['equals'])"; return $s
        }
    }
    return $s
}

# uiErrors of one ok pass -> @{ found; keys = ordered @{key -> weak};
# bad = [why]; blocked = [prefixes of entries that could not be placed] }.
# found false: missing (where the table does not allow it), unread, or not
# a list. $allowMissing: calibration lists whatever is there
function Get-WpPassUiKeys($t, $state, [string]$rootNorm, [string]$side, $dctx, [bool]$allowMissing = $false) {
    $spec = Get-WpUiSpec $t
    $v = Get-WpValue $state.check $spec.path $state.report
    $keys = [ordered]@{}; $bad = [System.Collections.Generic.List[string]]::new(); $blocked = [System.Collections.Generic.List[string]]::new()
    if (-not $v.found -or $null -eq $v.value) {
        # today's self test writes uiErrors only when there are some
        if ($spec.optional -or $allowMissing) { return @{ found = $true; keys = $keys; bad = @(); blocked = @() } }
        return @{ found = $false; keys = $keys; bad = @("no $($spec.path) (S0b reports always write it; a legacy table or uiErrors.optional allows its absence)"); blocked = @() }
    }
    if ($v.value -is [System.Collections.IDictionary] -and $v.value.Contains('$unread')) { return @{ found = $false; keys = $keys; bad = @("$($spec.path) unread: $(ConvertTo-WpCanon $v.value)"); blocked = @() } }
    if ($v.value -isnot [System.Collections.IList]) { return @{ found = $false; keys = $keys; bad = @("$($spec.path) is not a list"); blocked = @() } }
    foreach ($e in @($v.value)) {
        $k = Get-WpUiErrorKey $e $rootNorm $side $dctx
        if (-not $k.ok) { $bad.Add("$($k.key): $($k.why)"); if (-not $blocked.Contains($k.prefix)) { $blocked.Add($k.prefix) }; continue }
        if (-not $keys.Contains($k.key)) { $keys[$k.key] = $k.weak }
    }
    return @{ found = $true; keys = $keys; bad = $bad.ToArray(); blocked = $blocked.ToArray() }
}

function Get-WpKeyPrefix([string]$key) {
    $i = $key.LastIndexOf(' | ')
    return $(if ($i -ge 0) { $key.Substring(0, $i) } else { $key })
}

# A shot field's value -> the PNG files it names (a moved report folder
# still finds them beside the report)
function Get-WpShotFiles($value, [string]$reportFile) {
    $out = @()
    foreach ($p in @($value)) {
        $p = "$p"
        if (Test-Path -LiteralPath $p) { $out += $p; continue }
        $near = Join-Path (Split-Path -Parent $reportFile) ([System.IO.Path]::GetFileName($p))
        $deep = @(Get-ChildItem -LiteralPath (Split-Path -Parent $reportFile) -Recurse -File -Filter ([System.IO.Path]::GetFileName($p)) -ErrorAction SilentlyContinue | Select-Object -First 1)
        $out += $(if (Test-Path -LiteralPath $near) { $near } elseif ($deep.Count) { $deep[0].FullName } else { $p })
    }
    return , $out
}

# '' when every image a shot value names is there and decodes; else why
# not (an image that is not there is not a value: ① 无结果, not a class)
function Get-WpShotProblem($value, [string]$reportFile) {
    foreach ($f in (Get-WpShotFiles $value $reportFile)) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return "no image $f" }
        try {
            Add-Type -AssemblyName System.Drawing
            $img = [System.Drawing.Image]::FromFile($f); $img.Dispose()
        } catch { return "image $f cannot be read: $($_.Exception.Message)" }
    }
    return ''
}

# one canonical value per report; shots are put into classes of images at
# most `tolerance` pixels apart, the class standing in for the value
function Get-WpValueClasses($f, $values, $files) {
    if ($f['type'] -ne 'shot') { return , @($values | ForEach-Object { ConvertTo-WpCanon $_ }) }
    $tol = if ($null -ne $f['tolerance']) { [long]$f['tolerance'] } else { 0 }
    $reps = [System.Collections.Generic.List[object]]::new()
    $labels = @()
    for ($i = 0; $i -lt $values.Count; $i++) {
        $imgs = Get-WpShotFiles $values[$i] $files[$i]
        $label = $null
        for ($r = 0; $r -lt $reps.Count -and -not $label; $r++) {
            $rep = $reps[$r]
            if ($rep.Count -ne $imgs.Count) { continue }
            $sameAll = $true
            for ($j = 0; $j -lt $imgs.Count; $j++) {
                if (-not (Test-Path -LiteralPath $imgs[$j]) -or -not (Test-Path -LiteralPath $rep[$j])) { $sameAll = $false; break }
                $d = Get-PixelDiff $rep[$j] $imgs[$j]
                if ("$d" -notmatch '^\d+$' -or [long]$d -gt $tol) { $sameAll = $false; break }
            }
            if ($sameAll) { $label = "shots#$r" }
        }
        if (-not $label) { $reps.Add($imgs); $label = "shots#$($reps.Count - 1)" }
        $labels += $label
    }
    return , $labels
}

# the distinct values, compared as exact text
function Get-WpDistinct([string[]]$values) {
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($v in $values) { if ($seen.Add($v)) { $out.Add($v) } }
    return , $out.ToArray()
}

# 「多份报告的判法」 ③-⑤ on one field whose every report has a value.
# $pv / $nv: canonical values of the parent / new side.
function Get-WpVerdict([string[]]$pv, [string[]]$nv) {
    $final = $pv.Count -ge $wpFinal -and $nv.Count -ge $wpFinal
    $pd = Get-WpDistinct $pv; $nd = Get-WpDistinct $nv
    if ($pd.Count -gt 1) { return 'unstable' }                                    # ③
    if ($nd.Count -gt 1) { return $(if ($final) { 'differentNew' } else { 'rerun' }) } # ④
    if ($pd[0] -ceq $nd[0]) { return 'same' }                                      # ⑤
    return $(if ($final) { 'different' } else { 'rerun' })
}

# One check (field table) over both sides' passes -> the row
function Compare-WpRow($t, $pSide, $nSide, $dctx) {
    $row = [ordered]@{
        id = $t['id']; check = $t['check']; report = $t['report']; verdict = ''; label = ''
        reasons = [System.Collections.Generic.List[string]]::new()
        fields = [System.Collections.Generic.List[object]]::new()
        downgraded = [System.Collections.Generic.List[object]]::new()
        notComparable = [System.Collections.Generic.List[string]]::new()
        rerun = $null; evidence = $(if ($t.Contains('evidence') -and $t['evidence']) { "$($t['evidence'])" } else { '无灵敏证据' })
        passes = @{ parent = @(); new = @() }
    }
    $states = @{}
    foreach ($side in @(@{ n = 'parent'; s = $pSide }, @{ n = 'new'; s = $nSide })) {
        # only the passes that ran this check (pass.json)
        $states[$side.n] = @($side.s.passes | Where-Object { Test-WpPassRan $_ $t } | ForEach-Object { Get-WpPassState $t $_.name (Join-Path $_.dir $t['report']) })
        $row.passes[$side.n] = @($states[$side.n] | ForEach-Object { "$($_.pass): $($_.state)$(if ($_.why) { " ($($_.why))" })" })
    }
    $finish = {
        param([string]$v)
        $row.verdict = $v; $row.label = $wpLabel[$v]
        return [pscustomobject]$row
    }
    if ($null -ne $dctx -and $dctx['inputsDiffer']) { $row.reasons.Add($dctx.inputsDiffer); return & $finish 'noResult' }
    # a pass that did not measure: 无结果, whatever the others say
    $dead = @(foreach ($n in 'parent', 'new') { $states[$n] | Where-Object { $_.state -in 'no report', 'unreadable', 'no check', 'not measured' } | ForEach-Object { "$n $($_.pass): $($_.state) ($($_.why))" } })
    if ($dead.Count) { $dead | ForEach-Object { $row.reasons.Add($_) }; return & $finish 'noResult' }
    $extra = 0
    foreach ($pc in @($t['preconditions'] | Where-Object { $_ })) { $e = if ($null -ne $pc['extraRuns']) { [int]$pc['extraRuns'] } else { 2 }; if ($e -gt $extra) { $extra = $e } }
    $use = @{}
    foreach ($n in 'parent', 'new') {
        $spoiled = @($states[$n] | Where-Object state -eq 'precondition')
        if ($spoiled.Count -gt $extra) {
            $row.reasons.Add("$n`: $($spoiled.Count) passes failed the precondition (at most $extra reruns): $(($spoiled | ForEach-Object { "$($_.pass) $($_.why)" }) -join '; ')")
            return & $finish 'noResult'
        }
        $use[$n] = @($states[$n] | Where-Object state -eq 'ok')
    }
    # runner 补充⑦: only runs on the same display are compared
    $dpath = if ($t.Contains('display') -and $t['display']) { "$($t['display'])" } else { '@display' }
    $disp = @(foreach ($n in 'parent', 'new') { $use[$n] | ForEach-Object { $v = Get-WpValue $_.check $dpath $_.report; if ($v.found) { ConvertTo-WpCanon $v.value } } }) | Select-Object -Unique
    if (@($disp).Count -gt 1) { $row.reasons.Add("the reports were taken on different displays: $($disp -join ' / ')"); return & $finish 'noResult' }
    foreach ($n in 'parent', 'new') {
        if ($use[$n].Count -lt $wpMinimum) {
            $short = $wpMinimum - $use[$n].Count
            $spoiledN = @($states[$n] | Where-Object state -eq 'precondition').Count
            if ($spoiledN) {
                $row.rerun = @{ kind = 'same-commit'; side = $n; add = $short; why = 'a pass failed the precondition: rerun the same command line on the same commit' }
            } else {
                $row.rerun = @{ kind = 'alternate'; side = 'both'; add = $short; why = "fewer than $wpMinimum reports on the $n side" }
            }
            $row.reasons.Add($row.rerun.why)
            return & $finish 'rerun'
        }
    }
    $roots = @{ parent = $pSide.root; new = $nSide.root }
    foreach ($f in @($t['fields'])) {
        $fr = [ordered]@{ name = $f['name']; path = $f['path']; status = $f['status']; verdict = ''; label = ''; parent = @(); new = @(); note = '' }
        $vals = @{}; $missing = @()
        foreach ($n in 'parent', 'new') {
            $vals[$n] = @(foreach ($s in $use[$n]) {
                    $v = Get-WpValue $s.check $f['path'] $s.report
                    if (-not $v.found) { $missing += "$n $($s.pass): missing" }
                    elseif (Test-WpUnread $v.value) { $missing += "$n $($s.pass): $(ConvertTo-WpCanon $v.value)" }
                    elseif ($f['type'] -eq 'shot' -and ($pr = Get-WpShotProblem $v.value $s.file)) { $missing += "$n $($s.pass): $pr" }
                    , $v.value
                })
        }
        $files = @{ parent = @($use['parent'] | ForEach-Object file); new = @($use['new'] | ForEach-Object file) }
        if ($missing.Count) {
            $fr.verdict = 'noResult'; $fr.note = $missing -join '; '
        } else {
            # one set of classes over both sides, so shot labels compare too
            $all = Get-WpValueClasses $f (@($vals['parent']) + @($vals['new'])) (@($files['parent']) + @($files['new']))
            $cp = [string[]]@($all | Select-Object -First $vals['parent'].Count)
            $cn = [string[]]@($all | Select-Object -Skip $vals['parent'].Count)
            $fr.parent = @($cp | ForEach-Object { Format-WpShort $_ })
            $fr.new = @($cn | ForEach-Object { Format-WpShort $_ })
            $fr.verdict = if ($f['status'] -eq 'unstable') { 'tableUnstable' } else { Get-WpVerdict $cp $cn }
        }
        $fr.label = $wpLabel[$fr.verdict]
        if ($fr.verdict -eq 'unstable') { $row.downgraded.Add([ordered]@{ field = $f['name']; parent = $fr.parent; new = $fr.new }) }
        $row.fields.Add([pscustomobject]$fr)
    }
    $spec = Get-WpUiSpec $t
    if ($spec.status -ne 'none') {
        $per = @{}
        $uiMissing = @()
        foreach ($n in 'parent', 'new') {
            $per[$n] = @(foreach ($s in $use[$n]) {
                    $k = Get-WpPassUiKeys $t $s $roots[$n] $n $dctx
                    if (-not $k.found) { $uiMissing += "$n $($s.pass): $($k.bad -join '; ')" }
                    foreach ($b in $k.bad) { if ($k.found) { $row.notComparable.Add("$n $($s.pass): $b") } }
                    , $k
                })
        }
        if ($uiMissing.Count) {
            $row.fields.Add([pscustomobject][ordered]@{ name = 'uiErrorKeys'; path = $spec.path; status = $spec.status; verdict = 'noResult'; label = $wpLabel['noResult']; parent = @(); new = @(); note = $uiMissing -join '; ' })
        } else {
            $all = [ordered]@{}
            foreach ($n in 'parent', 'new') { foreach ($k in $per[$n]) { foreach ($key in $k.keys.Keys) { $all[$key] = $k.keys[$key] } } }
            # an entry one pass could not place may be the same error as a
            # placed one in another pass: its prefix's keys are not
            # present / absent but 无法比较 (else one missing map row reads
            # as 不同)
            $blocked = @($per['parent'] + $per['new'] | ForEach-Object { $_.blocked } | Where-Object { $_ } | Select-Object -Unique)
            foreach ($key in $all.Keys) {
                $pv = [string[]]@($per['parent'] | ForEach-Object { if ($_.keys.Contains($key)) { 'present' } else { 'absent' } })
                $nv = [string[]]@($per['new'] | ForEach-Object { if ($_.keys.Contains($key)) { 'present' } else { 'absent' } })
                $v = if ($spec.status -eq 'unstable' -or $spec.unstable -contains $key) { 'tableUnstable' }
                elseif ($blocked -contains (Get-WpKeyPrefix $key)) { 'notComparable' }
                else { Get-WpVerdict $pv $nv }
                $fr = [ordered]@{ name = "uiErrorKeys[$key]"; path = $spec.path; status = $spec.status; verdict = $v; label = $wpLabel[$v]; parent = $pv; new = $nv; note = $(if ($all[$key]) { 'weak' } else { '' }) }
                if ($v -eq 'unstable') { $row.downgraded.Add([ordered]@{ field = "uiErrorKeys[$key]"; parent = $pv; new = $nv }) }
                $row.fields.Add([pscustomobject]$fr)
            }
        }
    }
    $vs = @($row.fields | ForEach-Object verdict)
    if ($vs -contains 'rerun') {
        $row.rerun = @{ kind = 'alternate'; side = 'both'; add = [Math]::Max(1, $wpFinal - [Math]::Min($use['parent'].Count, $use['new'].Count)); why = 'a field needs more reports (④ / ⑤): alternate, each side' }
    }
    if ($vs -contains 'different' -or $vs -contains 'differentNew') { return & $finish 'different' }
    if ($vs -contains 'noResult') { return & $finish 'noResult' }
    if ($row.notComparable.Count -or $vs -contains 'notComparable') { return & $finish 'notComparable' }
    if ($vs -contains 'rerun') { return & $finish 'rerun' }
    return & $finish 'same'
}

# the leaves of a check object, as field-table paths. A list holding
# objects or lists is walked by index (runs[0].end), so a stable reading
# inside it is not hidden behind a timing next to it; a list of plain
# values (a rect, a role list) is one leaf
function Get-WpLeaves($obj, [string]$prefix, $into) {
    if ($obj -is [System.Collections.IDictionary] -and $obj.Count) {
        foreach ($k in @($obj.Keys)) {
            if ("$k" -match '[.\[\]@]') { continue }
            Get-WpLeaves $obj[$k] $(if ($prefix) { "$prefix.$k" } else { "$k" }) $into
        }
        return
    }
    if ($obj -is [System.Collections.IList] -and $prefix -and
        @($obj | Where-Object { $_ -is [System.Collections.IDictionary] -or $_ -is [System.Collections.IList] }).Count) {
        for ($i = 0; $i -lt $obj.Count; $i++) { Get-WpLeaves $obj[$i] "$prefix[$i]" $into }
        return
    }
    if ($prefix) { $into[$prefix] = $true }
}

# a leaf that names PNG files: compared as images, not as path text (the
# paths hold passN\ and differ in every run)
function Test-WpShotValue($v) {
    $xs = @($v)
    return $xs.Count -gt 0 -and @($xs | Where-Object { $_ -is [string] -and $_ -match '\.png$' }).Count -eq $xs.Count
}

# calibration mode: every folder is the same commit; list what changes
# between passes, per (report file, check name)
function Invoke-WpCalibration($sides, $tableSet) {
    $runs = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $sides) { foreach ($p in $s.passes) { $runs.Add(@{ side = $s; pass = $p; tag = "$([System.IO.Path]::GetFileName($s.dir))/$($p.name)" }) } }
    $groups = [ordered]@{}
    foreach ($r in $runs) {
        foreach ($f in @(Get-ChildItem -LiteralPath $r.pass.dir -Filter *.json -File | Where-Object Name -ne 'manifest.json')) {
            $rep = try { Read-WpJson $f.FullName } catch { $null }
            if ($rep -isnot [System.Collections.IDictionary]) { continue }
            foreach ($c in @($rep['checks'] | Where-Object { $_ -is [System.Collections.IDictionary] })) {
                $g = "$($f.Name)|$($c['name'])"
                if (-not $groups.Contains($g)) { $groups[$g] = [System.Collections.Generic.List[object]]::new() }
                $groups[$g].Add(@{ run = $r; report = $rep; check = $c; file = $f.FullName })
            }
        }
    }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $groups.Keys) {
        $items = $groups[$g]
        $file, $name = $g -split '\|', 2
        $table = @($tableSet.tables.Values | Where-Object { $_['report'] -eq $file -and $_['check'] -eq $name }) | Select-Object -First 1
        $leaves = [ordered]@{}
        foreach ($it in $items) { Get-WpLeaves $it.check '' $leaves }
        $varying = [System.Collections.Generic.List[object]]::new()
        $suggest = [System.Collections.Generic.List[object]]::new()
        foreach ($p in $leaves.Keys) {
            $inTable = if ($table) { @($table['fields'] | Where-Object { $_['path'] -eq $p }) | Select-Object -First 1 } else { $null }
            $raw = @($items | ForEach-Object { $v = Get-WpValue $_.check $p; , $(if ($v.found) { $v.value } else { $null }) })
            $isShot = ($inTable -and $inTable['type'] -eq 'shot') -or (@($raw | Where-Object { Test-WpShotValue $_ }).Count -eq $raw.Count -and $raw.Count)
            $noise = $null
            if ($isShot) {
                # the images themselves: one class per run at tolerance 0, and
                # the noise floor = the most pixels any run differs from the first
                $probs = @(for ($i = 0; $i -lt $items.Count; $i++) { Get-WpShotProblem $raw[$i] $items[$i].file })
                if (@($probs | Where-Object { $_ }).Count) { $vals = @($probs | ForEach-Object { if ($_) { "<$_>" } else { '<image>' } }) }
                else {
                    $f0 = @{ type = 'shot'; tolerance = 0 }
                    $vals = Get-WpValueClasses $f0 $raw @($items | ForEach-Object file)
                    $noise = 0
                    $first = Get-WpShotFiles $raw[0] $items[0].file
                    for ($i = 1; $i -lt $items.Count; $i++) {
                        $other = Get-WpShotFiles $raw[$i] $items[$i].file
                        if ($other.Count -ne $first.Count) { $noise = $null; break }
                        for ($j = 0; $j -lt $first.Count; $j++) {
                            $dpx = Get-PixelDiff $first[$j] $other[$j]
                            if ("$dpx" -notmatch '^\d+$') { $noise = $null; break }
                            if ([long]$dpx -gt $noise) { $noise = [long]$dpx }
                        }
                        if ($null -eq $noise) { break }
                    }
                }
            } else {
                $vals = @($items | ForEach-Object { $v = Get-WpValue $_.check $p; if ($v.found) { ConvertTo-WpCanon $v.value } else { '<missing>' } })
            }
            $d = Get-WpDistinct ([string[]]$vals)
            if ($d.Count -gt 1) {
                $varying.Add([ordered]@{
                        path = $p; values = @($vals | ForEach-Object { Format-WpShort $_ 80 })
                        table = $(if ($inTable) { "$($inTable['status'])" } else { '' })
                        noiseFloor = $noise
                    })
            }
            if ($p -notin 'name', 'pass', 'measured', 'uiErrors') {
                $sf = [ordered]@{ name = $p; path = $p; status = $(if ($d.Count -gt 1 -and -not ($isShot -and $null -ne $noise)) { 'unstable' } else { 'must-same' }) }
                # a shot field stays compared, within the noise the runs showed
                if ($isShot) { $sf['type'] = 'shot'; $sf['tolerance'] = $(if ($null -ne $noise) { $noise } else { 0 }) }
                $suggest.Add($sf)
            }
        }
        $uiVary = [System.Collections.Generic.List[string]]::new()
        $tmpT = if ($table) { $table } else { @{ check = $name } }
        $keySets = @(foreach ($it in $items) {
                $st = @{ check = $it.check; report = $it.report }
                , (Get-WpPassUiKeys $tmpT $st $it.run.side.root 'same' $null $true)
            })
        $allKeys = @($keySets | ForEach-Object { $_.keys.Keys } | Select-Object -Unique)
        foreach ($k in $allKeys) { if (@($keySets | Where-Object { -not $_.keys.Contains($k) }).Count) { $uiVary.Add($k) } }
        $out.Add([ordered]@{
                report = $file; check = $name; table = $(if ($table) { $table['id'] } else { '' })
                runs = @($items | ForEach-Object { $_.run.tag }); varying = $varying.ToArray(); uiErrorKeysVarying = $uiVary.ToArray()
                uiErrorKeys = $allKeys
                suggested = [ordered]@{ id = ''; check = $name; report = $file; type = 'recording'; batch = $null; network = $false; fields = $suggest.ToArray() }
            })
    }
    return , $out.ToArray()
}

# The field tables a comparison judges by, as git blobs. Without
# -FieldTables they must be the ones committed at HEAD (files under test/
# are git-ignored, `git add -f`): a table edited or never committed would
# judge by rules nobody can see later; compare.json records every blob
function Get-WpTableSource([string]$dir) {
    $files = @(if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -Filter *.json -File | Where-Object { -not $_.Name.StartsWith('_') } | Sort-Object Name })
    $blobs = [ordered]@{}
    foreach ($f in $files) { $blobs[$f.Name] = "$(git -C $root hash-object -- $f.FullName)".Trim() }
    $src = [ordered]@{ dir = $dir; blobs = $blobs; committed = $null }
    if ($FieldTables) { $src.committed = 'no: -FieldTables (a test or a draft; not a judgement to rely on)'; return $src }
    $rel = [System.IO.Path]::GetRelativePath($root, (Resolve-Path -LiteralPath $dir).Path) -replace '\\', '/'
    $head = (git -C $root rev-parse HEAD).Trim()
    $bad = @()
    foreach ($n in $blobs.Keys) {
        $c = "$(git -C $root rev-parse --verify --quiet "${head}:$rel/$n" 2>$null)".Trim()
        if (-not $c) { $bad += "$n is not committed" } elseif ($c -ne $blobs[$n]) { $bad += "$n differs from HEAD's" }
    }
    foreach ($n in @(git -C $root ls-tree --name-only "${head}:$rel" 2>$null)) {
        if ($n -match '\.json$' -and -not $n.StartsWith('_') -and -not $blobs.Contains($n)) { $bad += "$n is committed but not in the working tree" }
    }
    if ($bad.Count) { throw "-Compare: the field tables in $rel are not HEAD's ($($bad -join '; ')). Commit them first (files under test/ are git-ignored: git add -f), or pass -FieldTables for a draft" }
    $src.committed = "HEAD $head"
    return $src
}

# name -> git blob of each field table file (the results header records them)
function Get-WpTableBlobs([string]$dir) {
    $b = [ordered]@{}
    foreach ($f in @(if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -Filter *.json -File | Where-Object { -not $_.Name.StartsWith('_') } | Sort-Object Name })) {
        $b[$f.Name] = "$(git -C $root hash-object -- $f.FullName)".Trim()
    }
    return $b
}

function Invoke-WpCompare([string[]]$dirs) {
    if ($dirs.Count -lt 1 -or $dirs.Count -gt 2) { throw '-Compare <dir> | <parentDir>,<childDir>' }
    $sides = @($dirs | ForEach-Object { Read-WpSide $_ })
    $tableSource = Get-WpTableSource $wpFieldsDir
    $tableSet = Get-WpFieldTables $wpFieldsDir
    $mode = $null
    if ($sides.Count -eq 1) { $mode = 'calibration' }
    else {
        $a = $sides[0]; $b = $sides[1]
        $sameTrees = (ConvertTo-WpCanon $a.trees) -eq (ConvertTo-WpCanon $b.trees)
        if ($a.sha -eq $b.sha -and $sameTrees) { $mode = 'calibration' }
        elseif (Test-WpParentOf $a.sha $b.sha) { $mode = 'compare'; $pSide = $a; $nSide = $b }
        elseif (Test-WpParentOf $b.sha $a.sha) { $mode = 'compare'; $pSide = $b; $nSide = $a }
        else { throw "-Compare: $($a.dir) ($($a.sha)) and $($b.dir) ($($b.sha)) are neither the same commit nor a parent and its child: refused" }
    }
    $result = [ordered]@{
        mode = $mode; runner = (git -C $root hash-object (Join-Path $here 'run.ps1')).Trim()
        fieldTables = $tableSource
        examplesSkipped = $tableSet.examples
    }
    if ($mode -eq 'calibration') {
        $result['folders'] = @($sides | ForEach-Object { [ordered]@{ dir = $_.dir; commit = $_.sha; passes = @($_.passes | ForEach-Object name) } })
        $result['checks'] = Invoke-WpCalibration $sides $tableSet
        "watch_page -Compare, calibration: $($sides[0].sha) ($(@($sides | ForEach-Object { $_.passes.Count }) -join ' + ') passes)"
        foreach ($c in $result['checks']) {
            "$($c.report) / $($c.check)$(if ($c.table) { " (table $($c.table))" } else { ' (no field table)' }): $($c.runs.Count) runs, $($c.varying.Count) varying field(s), $($c.uiErrorKeysVarying.Count) varying uiErrorKey(s)"
            foreach ($v in $c.varying) { "  $($v.path)$(if ($v.table) { " [table: $($v.table)]" })$(if ($null -ne $v.noiseFloor) { " (images; noise floor $($v.noiseFloor) px)" }): $($v.values -join ' | ')" }
            foreach ($k in $c.uiErrorKeysVarying) { "  uiErrorKeys[$k]" }
        }
    } else {
        $dctx = New-WpDiffContext $pSide.sha $nSide.sha
        # the two sides must have read the same media (offline videos,
        # models); different media = different inputs, so no row is judged
        $mp = $pSide.manifest['media']; $mn = $nSide.manifest['media']
        if ($null -ne $mp -and $null -ne $mn -and (ConvertTo-WpCanon $mp) -cne (ConvertTo-WpCanon $mn)) {
            $dctx['inputsDiffer'] = "the two folders' manifests list different media (manifest.json media): not the same inputs"
        }
        # the 320-character cut of today's uiErrors texts depends on the
        # worktree root's length (runner 补充⑩ keeps them equal)
        if ($pSide.root -and $nSide.root -and $pSide.root.Length -ne $nSide.root.Length) { $dctx.rootsDiffer = $true }
        $result['parent'] = [ordered]@{ dir = $pSide.dir; commit = $pSide.sha; passes = @($pSide.passes | ForEach-Object name); root = $pSide.root }
        $result['new'] = [ordered]@{ dir = $nSide.dir; commit = $nSide.sha; passes = @($nSide.passes | ForEach-Object name); root = $nSide.root }
        $result['originMap'] = $dctx.map.from
        if ($OriginMap) { $result['originMapBlob'] = "$(git -C $root hash-object -- $OriginMap)".Trim() }
        if ($dctx['inputsDiffer']) { "warning: $($dctx.inputsDiffer)" }
        if ($dctx.rootsDiffer) { "warning: the worktree roots differ in length ($($pSide.root.Length), $($nSide.root.Length)): today's string uiErrors are not comparable" }
        $rows = [System.Collections.Generic.List[object]]::new()
        $sel = @($tableSet.tables.Values | Where-Object { $Checks.Count -eq 0 -or $Checks -contains $_['id'] })
        foreach ($t in $sel) { $rows.Add((Compare-WpRow $t $pSide $nSide $dctx)) }
        # report/check pairs present in the folders that no table describes
        $known = @{}; foreach ($t in $tableSet.tables.Values) { $known["$($t['report'])|$($t['check'])"] = $true }
        $loose = [System.Collections.Generic.List[string]]::new()
        foreach ($s in @($pSide, $nSide)) {
            foreach ($p in $s.passes) {
                foreach ($f in @(Get-ChildItem -LiteralPath $p.dir -Filter *.json -File | Where-Object Name -ne 'manifest.json')) {
                    $rep = try { Read-WpJson $f.FullName } catch { $null }
                    if ($rep -isnot [System.Collections.IDictionary]) { continue }
                    foreach ($c in @($rep['checks'] | Where-Object { $_ -is [System.Collections.IDictionary] })) {
                        $k = "$($f.Name)|$($c['name'])"
                        if (-not $known.ContainsKey($k) -and -not $loose.Contains($k)) { $loose.Add($k) }
                    }
                }
            }
        }
        $result['rows'] = $rows.ToArray()
        $result['withoutTable'] = $loose.ToArray()
        "watch_page -Compare, parent $($pSide.sha) ($($pSide.passes.Count) passes) -> new $($nSide.sha) ($($nSide.passes.Count) passes)"
        foreach ($r in $rows) {
            "$($r.id): $($r.label) ($($r.verdict))  [evidence: $($r.evidence)]"
            foreach ($x in $r.reasons) { "  - $x" }
            foreach ($f in @($r.fields | Where-Object { $_.verdict -ne 'same' -and $_.verdict -ne 'tableUnstable' })) {
                "  $($f.name): $($f.label)$(if ($f.note) { " — $($f.note)" })  parent: $($f.parent -join ' | ')  new: $($f.new -join ' | ')"
            }
            foreach ($d in $r.downgraded) { "  降级: $($d.field)  parent: $($d.parent -join ' | ')  new: $($d.new -join ' | ')" }
            foreach ($x in $r.notComparable) { "  无法比较: $x" }
            if ($r.rerun) {
                $cmd = if ($r.rerun.kind -eq 'alternate') {
                    "run.ps1 -Plan watch_page -Alternate -Parent $($pSide.sha.Substring(0, 9)) -Commit $($nSide.sha.Substring(0, 9)) -Checks $($r.id) -Passes $($r.rerun.add) -Out $(Split-Path -Parent $pSide.dir)"
                } else {
                    "run.ps1 -Plan watch_page -Alternate -Parent $($pSide.sha.Substring(0, 9)) -Commit $($nSide.sha.Substring(0, 9)) -Checks $($r.id) -OnlySide $($r.rerun.side) -Passes $($r.rerun.add) -Out $(Split-Path -Parent $pSide.dir)"
                }
                $r.rerun['command'] = $cmd
                "  需补跑: $($r.rerun.why) (+$($r.rerun.add) a side): $cmd"
            }
        }
        foreach ($k in $loose) { "no field table: $($k -replace '\|', ' / ')" }
    }
    if ($Out) {
        New-Item -ItemType Directory -Force $Out | Out-Null
        ConvertTo-Json -InputObject $result -Depth 20 | Set-Content -Encoding utf8 (Join-Path $Out 'compare.json')
        $md = [System.Collections.Generic.List[string]]::new()
        if ($mode -eq 'calibration') {
            $md.Add("# watch_page calibration: $($sides[0].sha)"); $md.Add('')
            $md.Add('| report | check | table | runs | varying fields | varying uiErrorKeys |'); $md.Add('|---|---|---|---|---|---|')
            foreach ($c in $result['checks']) {
                $md.Add("| $($c.report) | $($c.check) | $($c.table) | $($c.runs.Count) | $((@($c.varying | ForEach-Object path) -join ', ') -replace '\|', '\|') | $(($c.uiErrorKeysVarying -join ', ') -replace '\|', '\|') |")
            }
            $sdir = Join-Path $Out 'suggested-fields'
            New-Item -ItemType Directory -Force $sdir | Out-Null
            foreach ($c in $result['checks']) {
                $nm = ("$($c.check)@$([System.IO.Path]::GetFileNameWithoutExtension($c.report))" -replace '[^\w@.-]', '_')
                $c.suggested['id'] = $nm
                ConvertTo-Json -InputObject $c.suggested -Depth 10 | Set-Content -Encoding utf8 (Join-Path $sdir "$nm.json")
            }
        } else {
            $md.Add("# watch_page comparison: $($pSide.sha) -> $($nSide.sha)"); $md.Add('')
            $md.Add("run.ps1 blob $($result.runner); origin map $($result.originMap)"); $md.Add('')
            $md.Add('| check | result | not 相同 | 降级 | 灵敏证据 |'); $md.Add('|---|---|---|---|---|')
            $esc = { param($s) ("$s" -replace '\|', '\|' -replace '\r?\n', ' ') }
            foreach ($r in $result['rows']) {
                $bad = @($r.fields | Where-Object { $_.verdict -notin 'same', 'tableUnstable', 'unstable' } | ForEach-Object { "$($_.name): $($_.label)" }) + @($r.reasons) + @($r.notComparable | ForEach-Object { "无法比较 $_" })
                $dg = @($r.downgraded | ForEach-Object { "$($_.field) ($($_.parent -join '/') → $($_.new -join '/'))" })
                $md.Add("| $($r.id) | **$($r.label)** | $(& $esc ($bad -join '; ')) | $(& $esc ($dg -join '; ')) | $(& $esc $r.evidence) |")
            }
            foreach ($k in $result['withoutTable']) { $md.Add(''); $md.Add("No field table: $k") }
        }
        $md | Set-Content -Encoding utf8 (Join-Path $Out 'compare.md')
        "-> $(Join-Path $Out 'compare.json')"
    }
}

# ------------------------------------------------------------------ watch_page: one mutant against its baseline
# One report of the unmutated build against one of the mutant (a pair, not
# 「多份报告的判法」). -> @{ result = caught | noise | clean | error; first;
# by; expectedDiffs; noise; trigger }
function Compare-WpMutant($t, [string[]]$expected, [string]$baseFile, [string]$mutFile, [string]$baseRoot, [string]$mutRoot, [string]$patchFile = '') {
    $res = @{ result = ''; first = ''; by = ''; expectedDiffs = @(); noise = @(); trigger = $false }
    $b = Get-WpPassState $t 'baseline' $baseFile
    $m = Get-WpPassState $t 'mutant' $mutFile
    if ($m.state -ne 'ok') { $res.result = 'error'; $res.first = "the mutant's report: $($m.state)$(if ($m.why) { " ($($m.why))" })"; return $res }
    if ($b.state -ne 'ok') { $res.result = 'error'; $res.first = "the baseline report: $($b.state)$(if ($b.why) { " ($($b.why))" })"; return $res }
    $exp = [System.Collections.Generic.List[string]]::new(); $noise = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @($t['fields'] | Where-Object { $_['status'] -eq 'must-same' })) {
        $vb = Get-WpValue $b.check $f['path'] $b.report; $vm = Get-WpValue $m.check $f['path'] $m.report
        $isExp = $expected -contains $f['name']
        $unread = -not $vb.found -or -not $vm.found -or (Test-WpUnread $vb.value) -or (Test-WpUnread $vm.value)
        # an image that is not there is not a reading either
        if (-not $unread -and $f['type'] -eq 'shot') {
            $pb = Get-WpShotProblem $vb.value $baseFile; $pm = Get-WpShotProblem $vm.value $mutFile
            if ($pb -or $pm) {
                if ($isExp) { $res.result = 'error'; $res.first = "expected field $($f['name']): $(@($pb, $pm | Where-Object { $_ }) -join '; ')"; return $res }
                continue
            }
        }
        if ($unread) {
            if ($isExp) { $res.result = 'error'; $res.first = "expected field $($f['name']) missing or unread ($(if ($vb.found) { Format-WpShort (ConvertTo-WpCanon $vb.value) 60 } else { 'missing' }) -> $(if ($vm.found) { Format-WpShort (ConvertTo-WpCanon $vm.value) 60 } else { 'missing' }))"; return $res }
            if ($vb.found -ne $vm.found) { $noise.Add("$($f['name']): $(if ($vb.found) { 'present' } else { 'missing' }) -> $(if ($vm.found) { 'present' } else { 'missing' })") }
            continue
        }
        $cl = Get-WpValueClasses $f @(, $vb.value; , $vm.value) @($baseFile, $mutFile)
        if ($cl[0] -cne $cl[1]) {
            $line = "$($f['name']): $(Format-WpShort (ConvertTo-WpCanon $vb.value)) -> $(Format-WpShort (ConvertTo-WpCanon $vm.value))"
            if ($isExp) { $exp.Add($line) } else { $noise.Add($line) }
        }
    }
    $spec = Get-WpUiSpec $t
    if ($spec.status -eq 'must-same') {
        # baseline -> mutant lines through the patch's own hunks: an error
        # the patch only moves down a line is the same error
        $pctx = if ($patchFile -and (Test-Path -LiteralPath $patchFile)) { Read-WpPatchContext $patchFile } else { $null }
        $kb = Get-WpPassUiKeys $t $b $baseRoot 'parent' $pctx
        $km = Get-WpPassUiKeys $t $m $mutRoot 'new' $pctx
        $uiBad = @(@($kb, $km) | ForEach-Object { if (-not $_.found) { $_.bad } elseif ($_.bad.Count) { $_.bad } })
        if ($uiBad.Count) {
            # an unread or unplaceable reading proves nothing about a catch
            if ($expected -contains 'uiErrorKeys') { $res.result = 'error'; $res.first = "expected field uiErrorKeys not read: $($uiBad[0])"; return $res }
            $noise.Add("uiErrorKeys not read: $($uiBad[0])")
        }
        # only an entry the baseline does not have counts (design §5 「uiErrors」)
        $added = @($km.keys.Keys | Where-Object { -not $kb.keys.Contains($_) -and $spec.unstable -notcontains $_ })
        foreach ($k in $added) {
            $line = "uiErrorKeys: + $k"
            if ($expected -contains 'uiErrorKeys') { $exp.Add($line) } else { $noise.Add($line); $res.trigger = $true }
        }
    }
    if ($t['network'] -eq $true) {
        $rx = if ($t['rerunOn']) { "$($t['rerunOn'])" } else { $wpRerunDefault }
        if ($b.raw -match $rx -or $m.raw -match $rx) { $res.trigger = $true }
    }
    $res.expectedDiffs = $exp.ToArray(); $res.noise = $noise.ToArray()
    if ($exp.Count) { $res.result = 'caught'; $res.first = $exp[0]; $res.by = "$($t['id']): $(($exp[0] -split ':')[0])" }
    elseif ($noise.Count) { $res.result = 'noise'; $res.first = "only noise: $($noise[0])" }
    else { $res.result = 'clean' }
    return $res
}

# One catcher of one mutant: run the check ($runCheck: (dir, tag) -> the
# report's path), judge it; noise, or a catch next to a network retry /
# new uiErrors, is judged by one rerun (both kept). The mutant loop passes
# a run of the app; the offline self-test passes prepared reports.
function Invoke-WpCatcher($t, [string[]]$exp, [string]$baseFile, [string]$baseRoot, [string]$mutRoot, [string]$patchFile, [scriptblock]$runCheck, [string]$dir, [string]$tag) {
    $rep = & $runCheck $dir $tag
    $r = Compare-WpMutant $t $exp $baseFile $rep $baseRoot $mutRoot $patchFile
    $note = ''
    # a run that crashed before its report and was run again says so
    $crash = @(Get-WpCrashNote $rep | Where-Object { $_ })
    if ($r.result -eq 'noise' -or ($r.trigger -and $r.result -eq 'caught')) {
        $why = if ($r.result -eq 'noise') { "noise: $($r.noise[0])" } else { 'a network retry or new uiErrors next to the catch' }
        $rep2 = & $runCheck (Join-Path $dir 'rerun') "$tag-rerun"
        $r = Compare-WpMutant $t $exp $baseFile $rep2 $baseRoot $mutRoot $patchFile
        $note = "rerun ($why): $(Split-Path -Parent $rep), then $(Split-Path -Parent $rep2)"
        $crash += @(Get-WpCrashNote $rep2 | Where-Object { $_ } | ForEach-Object { "rerun: $_" })
    }
    if ($crash.Count) { $note = (@($note) + $crash | Where-Object { $_ }) -join '; ' }
    $r['note'] = $note
    return $r
}

# the catchers' results -> the mutant's row: caught by the first catch;
# else error when any catcher errored or showed only noise (after its
# rerun: noise twice is not a catch); else survived
function Resolve-WpMutantResult($rows) {
    $rows = @($rows)
    $details = @($rows | ForEach-Object { "$($_.result): $($_.first)$(if ($_['note']) { " [$($_['note'])]" })" })
    $c = @($rows | Where-Object { $_.result -eq 'caught' })
    if ($c.Count) { return @{ result = 'caught'; by = $c[0].by; first = $c[0].first; note = "$($c[0]['note'])"; details = $details } }
    $e = @($rows | Where-Object { $_.result -in 'error', 'noise' })
    if ($e.Count) { return @{ result = 'error'; by = ''; first = $e[0].first; note = "$($e[0]['note'])"; details = $details } }
    return @{ result = 'survived'; by = ''; first = ''; note = (@($rows | ForEach-Object { $_['note'] } | Where-Object { $_ }) -join '; '); details = $details }
}

# ------------------------------------------------------------------ watch_page: the plan file
# wp-mutants.json: { plan, phases: {<-Phase>: [landing...]}, defaultPhase,
# prefs: ["k:type=v"...] written into every run whose table does not say
# planPrefs false, media: [paths outside the repository the runs read],
# mutants: [...] } — an entry with "example": true is skipped
function Read-WpPlan {
    if (-not (Test-Path -LiteralPath $wpManifestFile)) { throw "no $wpManifestFile" }
    $doc = Read-WpJson $wpManifestFile
    if ($doc -isnot [System.Collections.IDictionary] -or $doc['plan'] -ne 'watch_page') { throw "$wpManifestFile is not a watch_page manifest (plan watch_page)" }
    if ($doc['phases'] -isnot [System.Collections.IDictionary]) { throw "$wpManifestFile has no phases" }
    $mutants = [System.Collections.Generic.List[object]]::new()
    $examples = [System.Collections.Generic.List[string]]::new()
    foreach ($m in @($doc['mutants'] | Where-Object { $_ })) {
        if ($m['example'] -eq $true) { $examples.Add("$($m['id'])"); continue }
        $mutants.Add($m)
    }
    $media = @($doc['media'] | Where-Object { $_ } | ForEach-Object {
            $x = [Environment]::ExpandEnvironmentVariables("$_") -replace '\$\{AsrModels\}', $AsrModels
            if ([System.IO.Path]::IsPathRooted($x)) { $x } else { Join-Path $root $x }
        })
    return @{
        phases = $doc['phases']; defaultPhase = $(if ($doc['defaultPhase']) { "$($doc['defaultPhase'])" } else { 'S0' })
        prefs = @($doc['prefs'] | Where-Object { $_ }); media = $media
        mutants = $mutants.ToArray(); examples = $examples.ToArray()
    }
}

# the manifest's entries against the field tables, both ways: a mutant's
# expected field must be a must-same field of its check that names the
# mutant in expectedFor, and every expectedFor must be some mutant's
function Test-WpPlanMutants($list, $tableSet, $allMutants, $phases = $null) {
    # the landings a pending entry may have: those some phase runs, but S0
    # (S0b writes every S0 mutant); a typo would be in no phase's run
    $laterLandings = @(if ($phases) { foreach ($k in $phases.Keys) { @($phases[$k]) } }) | Where-Object { $_ -and "$_" -cne 'S0' } | Select-Object -Unique
    $errs = [System.Collections.Generic.List[string]]::new()
    $ids = @{}
    foreach ($m in $allMutants) {
        $id = "$($m['id'])"
        if ($ids.ContainsKey($id)) { $errs.Add("$id twice") }
        $ids[$id] = $m
        if ($id -notmatch '^wp-') { $errs.Add("$id`: watch_page ids start with wp- (design 「变异编号」)") }
        if ($m.Contains('uncovered')) { continue }
        if ($m.Contains('pending')) {
            # a later step's mutant, written there (see the header)
            if (-not $m['landing']) { $errs.Add("$id`: no landing (the step it is written in)") }
            elseif ("$($m['landing'])" -ceq 'S0') { $errs.Add("$id`: an S0 mutant cannot be pending (S0b writes them all)") }
            elseif ($laterLandings -cnotcontains "$($m['landing'])") { $errs.Add("$id`: pending landing '$($m['landing'])' is not one a phase runs, but S0 ($($laterLandings -join ', '))") }
            foreach ($k in 'patch', 'location', 'catchers') { if ($m.Contains($k)) { $errs.Add("$id`: a pending entry has no $k yet") } }
            continue
        }
        if ("$($m['patch'])" -notmatch '^wp-.+\.patch$') { $errs.Add("$id`: patch '$($m['patch'])' must be wp-<id>.patch") }
        elseif (-not (Test-Path -LiteralPath (Join-Path (Get-PatchDir) $m['patch']))) { $errs.Add("$id`: no $($m['patch'])") }
        if (-not $m['landing']) { $errs.Add("$id`: no landing (the step it is written in)") }
        if (-not $m.Contains('catchers') -and -not $m.Contains('test')) { $errs.Add("$id`: neither catchers nor test") }
        foreach ($c in @($m['catchers'] | Where-Object { $_ })) {
            $t = $tableSet.tables[$c['check']]
            if ($null -eq $t) { $errs.Add("$id`: no field table '$($c['check'])'"); continue }
            if (@($c['expected'] | Where-Object { $_ }).Count -eq 0) { $errs.Add("$id`: catcher $($c['check']) names no expected field") }
            foreach ($e in @($c['expected'] | Where-Object { $_ })) {
                if ($e -eq 'uiErrorKeys') {
                    $u = Get-WpUiSpec $t
                    if ($u.status -ne 'must-same') { $errs.Add("$id`: uiErrorKeys is not must-same in $($t['id'])") }
                    elseif ($u.expectedFor -notcontains $id) { $errs.Add("$id`: $($t['id']) uiErrors.expectedFor does not name it") }
                    continue
                }
                $f = @($t['fields'] | Where-Object { $_['name'] -eq $e }) | Select-Object -First 1
                if ($null -eq $f) { $errs.Add("$id`: $($t['id']) has no field '$e'") }
                elseif ($f['status'] -ne 'must-same') { $errs.Add("$id`: $($t['id']).$e is $($f['status']), not must-same") }
                elseif (@($f['expectedFor']) -notcontains $id) { $errs.Add("$id`: $($t['id']).$e does not name it in expectedFor") }
            }
        }
    }
    foreach ($t in $tableSet.tables.Values) {
        $pairs = @(foreach ($f in @($t['fields'])) { foreach ($x in @($f['expectedFor'] | Where-Object { $_ })) { @{ m = $x; f = $f['name'] } } }) +
        @(foreach ($x in (Get-WpUiSpec $t).expectedFor) { @{ m = $x; f = 'uiErrorKeys' } })
        foreach ($pr in $pairs) {
            $m = $ids[$pr.m]
            $named = $null -ne $m -and @($m['catchers'] | Where-Object { $_ -and $_['check'] -eq $t['id'] -and @($_['expected']) -contains $pr.f }).Count
            if (-not $named) { $errs.Add("$($t['id']).$($pr.f) names $($pr.m) in expectedFor, but that mutant does not expect it") }
        }
    }
    if ($errs.Count) { throw "wp-mutants.json / wp_fields: $($errs -join '; ')" }
}

# media a set of checks' runs read: the plan's list and the tables'
# snapshots' placed media (hashed into the report folders' manifests)
function Get-WpMedia($plan, $tables) {
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($x in @($plan.media)) { if (-not $out.Contains($x)) { $out.Add($x) } }
    foreach ($t in @($tables | Where-Object { $_ -and $null -ne $_['run'] })) {
        $pf = "$($t['run']['profile'])"
        if ($pf.StartsWith('snapshot:')) {
            $x = $pf.Substring(9); if (-not [System.IO.Path]::IsPathRooted($x)) { $x = Join-Path $root $x }
            # a snapshot under test/fixtures is pinned by the manifest's
            # fixtures tree (git's, the same whatever line endings the
            # checkout has; hashing its files would differ between an LF
            # and a CRLF checkout of one commit); one elsewhere is hashed
            $fx = [System.IO.Path]::GetFullPath((Join-Path $root 'test\fixtures')).TrimEnd('\') + '\'
            $inFixtures = [System.IO.Path]::GetFullPath($x).StartsWith($fx, [System.StringComparison]::OrdinalIgnoreCase)
            if (-not $inFixtures -and -not $out.Contains($x)) { $out.Add($x) }
            # and the source media its place.json puts into the profile (the
            # files as made, not the records rewritten into the profile)
            foreach ($m in (Get-WpPlacedMedia $x)) { if (-not $out.Contains($m.source)) { $out.Add($m.source) } }
        }
        if ($t['run']['asr'] -eq $true -and -not $out.Contains($AsrModels)) { $out.Add($AsrModels) }
    }
    return , $out.ToArray()
}

# ------------------------------------------------------------------ watch_page: profile snapshots
# A snapshot folder (test/fixtures/watch_page/<name>, design §5 S0b 素材):
#   appdata\  -> %APPDATA%\com.zxa24\LibrePili\selftest-<profile>\
#   temp\     -> %TEMP%\LibrePili\selftest-<profile>\
#               (a snapshot with neither is all appdata)
#   place.json  { media: "<media.json, relative to place.json>",
#                 place: [{ file, to }] }: files of the media folder (not
#               in the repository) copied to <to> (relative to the snapshot:
#               appdata/... or temp/...), each checked against media.json's
#               sha256 first. media.json: { root (%VAR% expanded), files:
#               { <file>: { sha256 } } }; make_media.ps1 beside it makes them.
# In every .json copied, ${PROFILE_APPDATA} and ${PROFILE_TEMP} become the
# two folders (download records keep the absolute merged_path, design v7
# wp6#13). The manifest hashes the source media (and a snapshot folder
# outside test/fixtures; one under it is pinned by the fixtures tree), never
# the rewritten copies.

# the media a snapshot places: [{ source, to, sha256 }] (empty without
# place.json)
function Get-WpPlacedMedia([string]$src) {
    $placeFile = Join-Path $src 'place.json'
    if (-not (Test-Path -LiteralPath $placeFile)) { return , @() }
    $place = Get-Content -LiteralPath $placeFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $mediaFile = [System.IO.Path]::GetFullPath((Join-Path $src "$($place['media'])"))
    if (-not (Test-Path -LiteralPath $mediaFile)) { throw "$placeFile names media $mediaFile, which is not there" }
    $media = Get-Content -LiteralPath $mediaFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $mediaRoot = [Environment]::ExpandEnvironmentVariables("$($media['root'])")
    if (-not [System.IO.Path]::IsPathRooted($mediaRoot)) { $mediaRoot = Join-Path (Split-Path -Parent $mediaFile) $mediaRoot }
    $out = foreach ($p in @($place['place'])) {
        $name = "$($p['file'])"
        if (-not $media['files'] -or -not $media['files'].Contains($name)) { throw "$placeFile places $name, which $mediaFile does not list" }
        @{ source = (Join-Path $mediaRoot $name); to = "$($p['to'])"; sha256 = "$($media['files'][$name]['sha256'])"; maker = (Join-Path (Split-Path -Parent $mediaFile) 'make_media.ps1') }
    }
    return , @($out)
}

# restores snapshot folder $src into profile $profileName (see above);
# returns the profile's appdata folder. The profile's folders are emptied
# first: a run starts from the snapshot and nothing else.
function Restore-WpProfile([string]$src, [string]$profileName) {
    if (-not [System.IO.Path]::IsPathRooted($src)) { $src = Join-Path $root $src }
    if (-not (Test-Path -LiteralPath $src -PathType Container)) { throw "no snapshot folder $src" }
    $placed = Get-WpPlacedMedia $src
    # every media file checked before anything is written
    foreach ($m in $placed) {
        if (-not (Test-Path -LiteralPath $m.source -PathType Leaf)) { throw "snapshot $src`: no media file $($m.source) (make it: pwsh -NoProfile -File `"$($m.maker)`")" }
        $h = (Get-FileHash -LiteralPath $m.source -Algorithm SHA256).Hash
        if ($h -ne $m.sha256) { throw "snapshot $src`: $($m.source) has SHA-256 $h, media.json records $($m.sha256) (another ffmpeg build? see make_media.ps1)" }
    }
    $appdata = Join-Path $env:APPDATA "com.zxa24\LibrePili\selftest-$profileName"
    $temp = Join-Path $env:TEMP "LibrePili\selftest-$profileName"
    foreach ($d in $appdata, $temp) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
    $pairs = if ((Test-Path -LiteralPath (Join-Path $src 'appdata')) -or (Test-Path -LiteralPath (Join-Path $src 'temp'))) {
        @(@{ from = (Join-Path $src 'appdata'); to = $appdata }, @{ from = (Join-Path $src 'temp'); to = $temp })
    } else { @(@{ from = $src; to = $appdata }) }
    foreach ($pr in $pairs) {
        if (-not (Test-Path -LiteralPath $pr.from)) { continue }
        New-Item -ItemType Directory -Force $pr.to | Out-Null
        # item by item with -LiteralPath: export folders are named like
        # "<title> [360P 流畅]", and [ ] are wildcards to -Path
        foreach ($f in @(Get-ChildItem -LiteralPath $pr.from -Recurse -File)) {
            if ($pr.from -eq $src -and $f.Name -eq 'place.json' -and $f.DirectoryName -eq $src) { continue }
            $to = Join-Path $pr.to ([System.IO.Path]::GetRelativePath($pr.from, $f.FullName))
            New-Item -ItemType Directory -Force (Split-Path -Parent $to) | Out-Null
            Copy-Item -LiteralPath $f.FullName -Destination $to -Force
        }
        foreach ($j in @(Get-ChildItem -LiteralPath $pr.to -Recurse -File -Filter *.json)) {
            $text = Get-Content -LiteralPath $j.FullName -Raw -Encoding utf8
            if ($text -notmatch '\$\{PROFILE_(APPDATA|TEMP)\}') { continue }
            $text = $text.Replace('${PROFILE_APPDATA}', ($appdata -replace '\\', '\\')).Replace('${PROFILE_TEMP}', ($temp -replace '\\', '\\'))
            Set-Content -LiteralPath $j.FullName -Value $text -Encoding utf8 -NoNewline
        }
    }
    foreach ($m in $placed) {
        $rel = $m.to -replace '/', '\'
        $to = if ($rel.StartsWith('appdata\')) { Join-Path $appdata $rel.Substring(8) }
        elseif ($rel.StartsWith('temp\')) { Join-Path $temp $rel.Substring(5) }
        else { throw "snapshot $src`: place.json 'to' must start with appdata/ or temp/, not $($m.to)" }
        New-Item -ItemType Directory -Force (Split-Path -Parent $to) | Out-Null
        Copy-Item -LiteralPath $m.source -Destination $to -Force
    }
    return $appdata
}

# the media keys of $want that $have lacks or hashes otherwise (empty =
# $have covers $want: a baseline may have read more media than this run)
function Test-WpMediaCovers($have, $want) {
    return , @($want.Keys | Where-Object { -not $have.Contains($_) -or "$($have[$_])" -cne "$($want[$_])" })
}

# the batch switch (design 「批次场景开关」): fullscreen and pip are skipped
# unless -Batch, and -Batch runs only them
function Test-WpInBatch($t) {
    $b = if ($t.Contains('batch')) { "$($t['batch'])" } else { '' }
    $covers = $b -in 'fullscreen', 'pip'
    return $(if ($Batch) { $covers } else { -not $covers })
}

function Remove-Profile([string]$profileName) {
    foreach ($d in (Join-Path $env:APPDATA "com.zxa24\LibrePili\selftest-$profileName"),
        (Join-Path $env:TEMP "LibrePili\selftest-$profileName"),
        (Join-Path $env:TEMP "LibrePili\$profileName")) {
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# the command line of one check's run (field table "run"): the prefs of the
# plan (unless planPrefs false) and the table's, by key, the table's last
function Get-WpRunArgs($t, $plan, [string]$profileName, [string]$report, [string]$shots, [string]$tree, [string]$dir) {
    $run = $t['run']
    if ($null -eq $run) { throw "field table $($t['id']) has no run: it cannot be launched" }
    $argv = [System.Collections.Generic.List[string]]::new()
    foreach ($a in '--selftest', '--profile', $profileName, '--out', $report) { $argv.Add($a) }
    $prefs = [ordered]@{}
    if ($run['planPrefs'] -ne $false) { foreach ($p in @($plan.prefs)) { $prefs[("$p" -split ':', 2)[0]] = "$p" } }
    foreach ($p in @($run['prefs'] | Where-Object { $_ })) { $prefs[("$p" -split ':', 2)[0]] = "$p" }
    foreach ($p in $prefs.Values) { $argv.Add('--pref'); $argv.Add($p) }
    $fixtures = Join-Path $tree 'test\fixtures'
    foreach ($a in @($run['args'])) { $argv.Add("$a".Replace('${SHOTS}', $shots).Replace('${FIXTURES}', $fixtures).Replace('${OUT}', $dir)) }
    return , $argv.ToArray()
}

# "snapshot:<dir>": the profile's data restored from it before the run
# (Restore-WpProfile: the folders, place.json's media, ${PROFILE_APPDATA}
# and ${PROFILE_TEMP} in every .json copied)
function Restore-WpSnapshot($t, [string]$profileName) {
    $spec = "$($t['run']['profile'])"
    if (-not $spec.StartsWith('snapshot:')) { return }
    try { Restore-WpProfile $spec.Substring(9) $profileName | Out-Null }
    catch { throw "field table $($t['id']): $($_.Exception.Message)" }
}

# A debug build's media_kit keeps a pointer in
# %TEMP%\com.alexmercerind.media_kit.NativeReferenceHolder.<pid> (for hot
# restart) and never deletes the file; a later process that gets the same
# pid reads the dead process's pointer and crashes, exit 0xC0000005 in its
# first seconds (native_reference_holder.dart:41-57; all 36 such crashes of
# 2026-11-01 had a file of their pid written before they started). Before
# each launch the files of processes that are gone are deleted; a running
# process's file is left alone.
function Clear-MediaKitHolders {
    $live = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($p in Get-Process) { [void]$live.Add($p.Id) }
    Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'com.alexmercerind.media_kit.NativeReferenceHolder.*' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.(\d+)$' -and -not $live.Contains([int]$Matches[1]) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# runs one check from a slot's exe; returns the report path. Same rules as
# Invoke-SelfTest: a new profile per run, deleted afterwards. A process
# that ends abnormally (an exit code other than the self test's own 0 / 1,
# not a timeout of ours) before writing its report is run once more with
# the same command line and a new profile (the startup crash above, seen
# in 5-16 % of launches before the cleanup, S0b parts 3a and 5): both
# attempts go into <report>.crash.json, which the mutant rows and
# runs.jsonl report; a second crash leaves no report, and the run is
# `error` (runner 补充①). Baselines, mutants and -Alternate all run here.
$script:wpLaunch = {
    param([string]$exe, [string[]]$argv, [int]$minutes)
    Clear-MediaKitHolders
    $p = Start-Process -FilePath $exe -ArgumentList $argv -PassThru
    $timedOut = $false
    if (-not $p.WaitForExit($minutes * 60000)) {
        # ours: started just above
        $timedOut = $true
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        $p.WaitForExit(30000) | Out-Null
    }
    return @{ exit = $p.ExitCode; timedOut = $timedOut }
}
$script:wpCrashPause = 2
# before the rerun after a crash (kept from before the cause above was
# found; the rerun gets a new pid, which is what helps)
$script:wpCrashRetryPause = 10
function Invoke-WpSelfTest([string]$exe, $t, $plan, [string]$dir, [string]$tag, [string]$tree) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    $report = Join-Path $dir $t['report']
    $shots = Join-Path $dir "$($t['id'])_shots"
    # an earlier run's report here would pass for this run's
    foreach ($old in $report, "$report.progress", "$report.crash.json", $shots) {
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
    }
    $crashes = [System.Collections.Generic.List[object]]::new()
    foreach ($attempt in 1, 2) {
        $profileName = "wp-$tag-$($t['id'])-$(Get-Random -Maximum 99999)"
        $argv = Get-WpRunArgs $t $plan $profileName $report $shots $tree $dir
        $argv = @($argv | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } })
        Restore-WpSnapshot $t $profileName
        if ($t['run']['asr'] -eq $true) {
            # recognition models live per profile (appSupportDir/selftest-<name>/asr)
            if (-not (Test-Path (Join-Path $AsrModels 'silero-vad'))) { throw "no ASR models in $AsrModels (-AsrModels)" }
            $into = Join-Path $env:APPDATA "com.zxa24\LibrePili\selftest-$profileName"
            New-Item -ItemType Directory -Force $into | Out-Null
            Copy-Item -Recurse $AsrModels (Join-Path $into 'asr')
        }
        $minutes = if ($t['run']['minutes']) { [int]$t['run']['minutes'] } else { 30 }
        $t0 = Get-Date
        $r = & $script:wpLaunch $exe $argv $minutes
        Start-Sleep -Seconds $script:wpCrashPause
        Remove-Profile $profileName
        $crashed = -not $r.timedOut -and $r.exit -notin 0, 1 -and -not (Test-Path -LiteralPath $report)
        if (-not $crashed) { break }
        $crashes.Add([ordered]@{ attempt = $attempt; exit = $r.exit; seconds = [int]((Get-Date) - $t0).TotalSeconds; profile = $profileName })
        Write-Host "  $($t['id']) ($tag): the process ended with exit $($r.exit) before writing its report (attempt $attempt)$(if ($attempt -eq 1) { '; run once more' })"
        foreach ($old in "$report.progress", $shots) { if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force } }
        if ($attempt -eq 1) { Start-Sleep -Seconds $script:wpCrashRetryPause }
    }
    if ($crashes.Count) {
        ConvertTo-Json -Depth 4 -InputObject ([ordered]@{ check = $t['id']; crashes = $crashes.ToArray(); report = (Test-Path -LiteralPath $report) }) |
            Set-Content -Encoding utf8 "$report.crash.json"
    }
    return $report
}

# what <report>.crash.json says of a run, as a row's note ('' = no crash)
function Get-WpCrashNote([string]$report) {
    $f = "$report.crash.json"
    if (-not $report -or -not (Test-Path -LiteralPath $f)) { return '' }
    $c = Read-WpJson $f
    $exits = @($c['crashes'] | ForEach-Object { "exit $($_['exit'])" }) -join ', '
    $n = @($c['crashes']).Count
    return $(if ($c['report']) { "crashed once before its report ($exits), the rerun wrote it" } else { "crashed $n times before its report ($exits): no report" })
}

# ------------------------------------------------------- download plan: its ids
# The download plan's mutants as they must be (stage-2 plan §6.3, the review
# of 2a): stage 1's 61 with their phases, frozen as they were at 57cf441a5,
# and the stage-2 ids each of its commits adds (all '2-only'), commit by
# commit. -Phase 2 runs exactly these; a commit that adds mutants adds its
# row here. Every download run first checks mutants.json itself: ids unique,
# every phase one of $dlPhases.
$script:dlPhases = @('both', '1a-only', '1b-only', '2-only')
$script:dlStage1 = [ordered]@{
    'M1' = 'both'; 'M2' = 'both'; 'M3' = 'both'; 'M4' = 'both'; 'M5' = 'both'; 'M6' = 'both'
    'M7' = 'both'; 'M8' = 'both'; 'M9' = 'both'; 'M10' = 'both'; 'M11' = 'both'; 'M12' = 'both'
    'M13' = 'both'; 'M14' = 'both'; 'M14b' = 'both'; 'M15' = 'both'; 'M16' = 'both'; 'M17' = 'both'
    'M18' = 'both'; 'M19' = 'both'; 'M20' = 'both'; 'M21' = 'both'; 'M22' = 'both'; 'M23' = 'both'
    'M24' = 'both'; 'M25' = 'both'; 'M26' = 'both'; 'M27' = 'both'; 'M28' = 'both'; 'M29' = 'both'
    'M30' = 'both'; 'M31' = 'both'; 'M32' = 'both'; 'M33' = 'both'; 'M34' = 'both'; 'M35' = 'both'
    'M36' = 'both'; 'M37' = 'both'; 'M38' = 'both'; 'M39' = 'both'; 'M40' = 'both'; 'M41' = 'both'
    'M42' = 'both'; 'M43' = 'both'; 'M44' = 'both'; 'M45' = 'both'; 'M46' = 'both'; 'M47' = 'both'
    'M48' = 'both'; 'M49' = 'both'; 'M50' = 'both'; 'M51' = 'both'; 'M52' = 'both'; 'M53' = 'both'
    'M54' = 'both'; 'M55' = 'both'; 'M56' = '1b-only'; 'M57a' = '1a-only'; 'M57b' = '1a-only'; 'M58' = 'both'
    'M59' = 'both'
}
$script:dlStage2 = [ordered]@{
    '2a' = @('P2-S1', 'P2-S2', 'P2-S4', 'P2-S7', 'P2-F12', 'P2-H6', 'P2-H7', 'P2-H8', 'P2-E1', 'P2-E2', 'P2-E3')
    '2b' = @('P2-F1', 'P2-D1', 'P2-D2', 'P2-D3', 'P2-D4', 'P2-D5', 'P2-D6', 'P2-D7', 'P2-D8', 'P2-L1', 'P2-L2', 'P2-L3', 'P2-L8', 'P2-L9', 'P2-L13', 'P2-L14')
    '2c' = @('P2-R1', 'P2-R2', 'P2-R3', 'P2-R4', 'P2-R5', 'P2-R10', 'P2-R12', 'P2-R17', 'P2-R18', 'P2-Q1')
    '2bc-fix' = @('P2-D9', 'P2-D10', 'P2-D11')
    '4320' = @('P2-Q2')
    '2d' = @('P2-T1', 'P2-T2', 'P2-T3', 'P2-T4', 'P2-T5', 'P2-T6', 'P2-T7', 'P2-T8', 'P2-T9', 'P2-T10', 'P2-T11', 'P2-T12', 'P2-T13', 'P2-T14', 'P2-T16', 'P2-T17', 'P2-T18')
    '2e' = @('P2-S3', 'P2-S5', 'P2-S6', 'P2-S8', 'P2-S9', 'P2-S10', 'P2-R13', 'P2-H1', 'P2-H2', 'P2-H3', 'P2-H4', 'P2-H5', 'P2-F2', 'P2-F3', 'P2-F4', 'P2-F5', 'P2-F6', 'P2-F7', 'P2-F8', 'P2-F9', 'P2-F10', 'P2-F11', 'P2-R6', 'P2-R7', 'P2-R8', 'P2-R9', 'P2-R11', 'P2-R14', 'P2-R15', 'P2-R16', 'P2-T15', 'P2-L5', 'P2-X1', 'P2-X2')
    '2d-fix' = @('P2-T19', 'P2-T20', 'P2-T21', 'P2-T22', 'P2-T23', 'P2-T24', 'P2-T25', 'P2-T26', 'P2-T27')
    '2e-fix' = @('P2-S11', 'P2-S12', 'P2-T28', 'P2-H9', 'P2-R19', 'P2-R20', 'P2-R21', 'P2-R22', 'P2-R23', 'P2-R24', 'P2-R25')
}

# ids unique, phases known: throws on the first that is not
function Test-DownloadManifest($all) {
    $seen = @{}
    foreach ($m in @($all)) {
        $id = "$($m['id'])"
        if (-not $id) { throw 'mutants.json: an entry with no id' }
        if ($seen.ContainsKey($id)) { throw "mutants.json: id $id is there twice" }
        $seen[$id] = $true
        if ($script:dlPhases -notcontains "$($m['phase'])") { throw "mutants.json: $id has phase '$($m['phase'])', not one of $($script:dlPhases -join ', ')" }
    }
}

# the ids -Phase 2 must run, in order
function Get-DownloadPhase2Ids {
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $script:dlStage1.Keys) { $ids.Add($id) }
    foreach ($c in $script:dlStage2.Keys) { foreach ($id in $script:dlStage2[$c]) { $ids.Add($id) } }
    return , $ids
}

# mutants.json against the frozen stage-1 ids and the stage-2 rows, and
# [picked] (what -Phase 2 selected) against both: throws listing what differs
function Test-DownloadPhase2($all, $picked) {
    $byId = @{}
    foreach ($m in @($all)) { $byId["$($m['id'])"] = $m }
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $script:dlStage1.Keys) {
        if (-not $byId.ContainsKey($id)) { $problems.Add("stage-1 $id is not in mutants.json") }
        elseif ("$($byId[$id]['phase'])" -ne $script:dlStage1[$id]) { $problems.Add("stage-1 $id has phase $($byId[$id]['phase']), not $($script:dlStage1[$id])") }
    }
    foreach ($c in $script:dlStage2.Keys) {
        foreach ($id in $script:dlStage2[$c]) {
            if (-not $byId.ContainsKey($id)) { $problems.Add("$c's $id is not in mutants.json") }
            elseif ("$($byId[$id]['phase'])" -ne '2-only') { $problems.Add("$c's $id has phase $($byId[$id]['phase']), not 2-only") }
        }
    }
    $expected = Get-DownloadPhase2Ids
    $ids = @($picked | ForEach-Object { "$($_['id'])" })
    foreach ($id in $expected) { if ($ids -notcontains $id) { $problems.Add("-Phase 2 did not pick $id") } }
    foreach ($id in $ids) { if ($expected -notcontains $id) { $problems.Add("-Phase 2 picked $id, which no commit lists") } }
    if ($problems.Count) { throw "-Phase 2: $($problems -join '; ')" }
}

# -Union: the result folders of one commit's runs (a full run stopped and
# resumed with -Only) together cover exactly -Phase 2's ids. Returns a
# summary; throws when the folders are of different commits or phases, or
# their ids are not exactly the expected ones
function Test-DownloadUnion([string[]]$dirs) {
    $expected = Get-DownloadPhase2Ids
    $rows = [ordered]@{}
    $commits = @{}
    foreach ($d in $dirs) {
        $f = Join-Path $d 'results.json'
        if (-not (Test-Path -LiteralPath $f)) { throw "-Union: no results.json in $d" }
        $r = Get-Content -Raw -LiteralPath $f | ConvertFrom-Json -AsHashtable
        $commits["$($r['header']['commit'])"] = $true
        if ("$($r['header']['phase'])" -ne '2') { throw "-Union: $d is a -Phase $($r['header']['phase']) run" }
        foreach ($x in @($r['results'])) {
            $id = "$($x['id'])"
            if (-not $rows.Contains($id)) { $rows[$id] = [System.Collections.Generic.List[object]]::new() }
            $rows[$id].Add([ordered]@{ dir = $d; result = "$($x['result'])" })
        }
    }
    if ($commits.Count -ne 1) { throw "-Union: the folders are of $($commits.Count) commits ($(@($commits.Keys) -join ', '))" }
    $missing = @($expected | Where-Object { -not $rows.Contains($_) })
    $extra = @($rows.Keys | Where-Object { $expected -notcontains $_ })
    $twice = @($rows.Keys | Where-Object { $rows[$_].Count -gt 1 })
    # a mutant run in two folders: its last row (the later folder) counts
    $final = [ordered]@{}
    foreach ($id in $rows.Keys) { $final[$id] = $rows[$id][$rows[$id].Count - 1].result }
    $summary = [ordered]@{
        commit = @($commits.Keys)[0]; expected = $expected.Count; covered = $rows.Count
        caught = @($final.Values | Where-Object { $_ -eq 'caught' }).Count
        notCaught = @($final.Keys | Where-Object { $final[$_] -ne 'caught' })
        missing = $missing; extra = $extra; twice = $twice
    }
    if ($missing.Count -or $extra.Count) { throw "-Union: missing $($missing -join ', '); not expected $($extra -join ', ')" }
    return $summary
}

if ($LoadOnly) { return }

# which plan: -Plan, else watch_page when every -Compare folder says so
$planName = $Plan
if (-not $planName) {
    $planName = 'download'
    if ($Compare.Count -gt 0) {
        $wp = @($Compare | Where-Object {
                $mf = Join-Path $_ 'manifest.json'
                (Test-Path -LiteralPath $mf) -and ($(try { (Read-WpJson $mf)['plan'] } catch { '' }) -eq 'watch_page')
            })
        if ($wp.Count -eq $Compare.Count) { $planName = 'watch_page' }
    }
    if ($Alternate) { $planName = 'watch_page' }
}
$script:wp = $planName -eq 'watch_page'

if ($CheckTestSide.Count -gt 0) {
    if ($CheckTestSide.Count -ne 2) { throw '-CheckTestSide <parent>,<child>' }
    $frozen = 'lib/utils/self_test.dart', 'lib/utils/self_test_probe.dart', 'lib/utils/self_test_watch.dart', 'test/mutants/run.ps1', 'test/mutants/wp_compare_selftest.ps1', 'test/mutants/wp_fields'
    # a side is a commit, or (the offline self-test) a folder laid out as
    # the repository; either way: path -> git blob id of every frozen file,
    # and every file under test/mutants
    $read = {
        param([string]$spec)
        $side = @{ label = $spec; files = @{}; mutantsDir = @{}; manifest = $null }
        if (Test-Path -LiteralPath $spec -PathType Container) {
            $base = (Resolve-Path -LiteralPath $spec).Path
            foreach ($f in @(Get-ChildItem -LiteralPath $base -Recurse -File)) {
                $rel = [System.IO.Path]::GetRelativePath($base, $f.FullName) -replace '\\', '/'
                $blob = "$(git -C $root hash-object -- $f.FullName)".Trim()
                if ($rel.StartsWith('test/mutants/')) { $side.mutantsDir[$rel] = $blob }
                foreach ($p in $frozen) { if ($rel -eq $p -or $rel.StartsWith("$p/")) { $side.files[$rel] = $blob } }
            }
            $mf = Join-Path $base 'test\mutants\wp-mutants.json'
            if (Test-Path -LiteralPath $mf) { $side.manifest = Get-Content -LiteralPath $mf -Raw -Encoding utf8 }
        } else {
            $c = Resolve-WpCommit $spec '-CheckTestSide'
            $side.label = $c
            foreach ($l in @(git -C $root ls-tree -r $c -- @frozen 'test/mutants')) {
                if ("$l" -match '^\d+ blob ([0-9a-f]+)\t(.+)$') {
                    $rel = $Matches[2]
                    if ($rel.StartsWith('test/mutants/')) { $side.mutantsDir[$rel] = $Matches[1] }
                    foreach ($p in $frozen) { if ($rel -eq $p -or $rel.StartsWith("$p/")) { $side.files[$rel] = $Matches[1] } }
                }
            }
            git -C $root cat-file -e "${c}:test/mutants/wp-mutants.json" 2>$null
            if (-not $LASTEXITCODE) { $side.manifest = (git -C $root show "${c}:test/mutants/wp-mutants.json") -join "`n" }
        }
        return $side
    }
    $sa = & $read $CheckTestSide[0]; $sb = & $read $CheckTestSide[1]
    $ok = $true
    "frozen test side, $($sa.label) -> $($sb.label): $($frozen -join ' ')"
    # each frozen path must be in both: files under test/ are git-ignored
    # (.gitignore "test*"), so one committed without `git add -f` is simply
    # absent, and an absent file has no diff
    foreach ($s in $sa, $sb) {
        foreach ($p in $frozen) {
            if (-not @($s.files.Keys | Where-Object { $_ -eq $p -or $_.StartsWith("$p/") }).Count) { "  missing in $($s.label): $p (files under test/ need git add -f)"; $ok = $false }
        }
    }
    foreach ($k in @(@($sa.files.Keys) + @($sb.files.Keys) | Select-Object -Unique | Sort-Object)) {
        if ($sa.files[$k] -cne $sb.files[$k]) { "  changed: $k ($(if ($sa.files.ContainsKey($k)) { $sa.files[$k].Substring(0, 9) } else { 'absent' }) -> $(if ($sb.files.ContainsKey($k)) { $sb.files[$k].Substring(0, 9) } else { 'absent' }))"; $ok = $false }
    }
    if ($ok) { '  every frozen file byte-identical' }
    if (-not (Test-Path -LiteralPath $CheckTestSide[0] -PathType Container) -and -not (Test-Path -LiteralPath $CheckTestSide[1] -PathType Container)) {
        "git diff --stat $($sa.label)..$($sb.label) -- $($frozen -join ' '):"
        $stat = @(git -C $root diff --stat $sa.label $sb.label -- @frozen)
        if ($stat.Count) { $stat | ForEach-Object { "  $_" } } else { '  (empty)' }
    }
    $man = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $sa, $sb) {
        if (-not $s.manifest) { $man.Add(''); continue }
        $doc = ConvertFrom-WpJsonText $s.manifest
        foreach ($e in @($doc['mutants'])) {
            if ($e -isnot [System.Collections.IDictionary]) { continue }
            # S1 rewrites patches it must ship: each patch named is there
            if ($e['patch'] -and $e['example'] -ne $true -and -not $s.mutantsDir.ContainsKey("test/mutants/$($e['patch'])")) { "  missing in $($s.label): test/mutants/$($e['patch']) (named by $($e['id']))"; $ok = $false }
            $e.Remove('location')
        }
        $man.Add((ConvertTo-WpCanon $doc))
    }
    if (-not $man[0] -or -not $man[1]) { 'wp-mutants.json: missing on one side'; $ok = $false }
    # ordinal: a changed capital letter is a change
    elseif ($man[0] -cne $man[1]) { 'wp-mutants.json: differs beyond the entries'' "location"'; $ok = $false }
    else { 'wp-mutants.json: equal once "location" is dropped' }
    if (-not $sb.mutantsDir.ContainsKey('test/mutants/wp_origin_map.json')) { "note: $($sb.label) has no test/mutants/wp_origin_map.json: every uiErrors location in a moved block will be 无法比较" }
    if (-not $ok) { exit 1 }
    return
}

if ($Compare.Count -gt 0 -and $script:wp) {
    Invoke-WpCompare $Compare
    return
}

if ($Compare.Count -gt 0) {
    if ($Compare.Count -ne 2) { throw '-Compare <baseDir>,<otherDir>' }
    foreach ($sc in 'download', 'queue99', 'transcribe', 'listshots') {
        $fa = Join-Path $Compare[0] "$sc.json"; $fb = Join-Path $Compare[1] "$sc.json"
        if (-not (Test-Path $fa) -or -not (Test-Path $fb)) { "${sc}: (no report on one side)"; continue }
        $d = Compare-Scenario $sc $fa $fb
        "${sc}: $(if ($d.Count) { "$($d.Count) difference(s)" } else { 'same' })"
        $d | ForEach-Object { "  $_" }
    }
    return
}

# ------------------------------------------------------------------ setup
# a dry run (-Alternate, or watch_page's mutant mode) builds and launches
# nothing, so needs no flutter
$dry = $DryRun -and ($Alternate -or $script:wp)
if (-not $Flutter -and -not $dry) {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    $Flutter = if ($cmd) { $cmd.Source } else { '' }
    if (-not $Flutter) { throw 'flutter is not on PATH: pass -Flutter <path to flutter.bat>' }
}
$sha = (git -C $root rev-parse --verify "$Commit^{commit}").Trim()
if (-not $Out) {
    $Out = if ($Alternate) { Join-Path $root "_tmp\wp-runs\$(Get-Date -Format yyyyMMdd-HHmmss)" }
    else { Join-Path $root "_tmp\mutants-results\$(Get-Date -Format yyyyMMdd-HHmmss)" }
}
# -Union reads result folders only: nothing is made
if (-not $dry -and -not $Union.Count) {
    New-Item -ItemType Directory -Force $Out | Out-Null
    $Out = (Resolve-Path $Out).Path
}
# -Work: where the worktrees go. A short path when the checkout itself is
# deep: MSVC cannot open plugin headers past 260 characters (a build in
# .claude\worktrees\<agent>\_tmp\mutants\selftest reaches 263)
$work = if ($Work) { $Work } else { Join-Path $root '_tmp\mutants' }
if (-not $dry -and -not $Union.Count) { New-Item -ItemType Directory -Force $work | Out-Null }

if (-not $script:wp) {
    if ($Phase -notin '0', '1a', '1b', '2') { throw "-Phase $Phase is a watch_page phase; the download plan has 0, 1a, 1b and 2" }
    $all = Get-Content -Raw (Join-Path $here 'mutants.json') | ConvertFrom-Json -AsHashtable
    Test-DownloadManifest $all
    $phases = @{ '0' = @('both'); '1a' = @('both', '1a-only'); '1b' = @('1b-only'); '2' = @('both', '1a-only', '1b-only', '2-only') }[$Phase]
    $todo = @($all | Where-Object {
            ($Only.Count -eq 0 -or $Only -contains $_['id']) -and (
                $phases -contains $_['phase'] -or
                # 1b: also the self-test items it touches (--download-transcribe)
                ($Phase -eq '1b' -and $_.Contains('scenario') -and $_['scenario'] -eq 'transcribe'))
        })
    if ($Phase -eq '2') {
        # stage 2 runs all of them (its plan §6.3, review X7: the first -Phase
        # 2 left out 1a-only and 1b-only): exactly the frozen stage-1 ids and
        # the ids its commits list
        $everything = @($all | Where-Object { $phases -contains $_['phase'] })
        if ($Only.Count -eq 0) { Test-DownloadPhase2 $all $todo } else { Test-DownloadPhase2 $all $everything }
        if ($Union.Count) {
            $u = Test-DownloadUnion $Union
            "-Union: $($u.covered) of $($u.expected) mutants covered, $($u.caught) caught, at $($u.commit)" +
            $(if ($u.notCaught.Count) { "; not caught: $($u.notCaught -join ', ')" }) +
            $(if ($u.twice.Count) { "; run twice (the later folder counts): $($u.twice -join ', ')" })
            return
        }
    } elseif ($Union.Count) { throw '-Union is for -Phase 2' }
} else {
    $wpPlan = Read-WpPlan
    if (-not $PSBoundParameters.ContainsKey('Phase')) { $Phase = $wpPlan.defaultPhase }
    if (-not $wpPlan.phases.Contains($Phase)) { throw "-Phase $Phase is not one of wp-mutants.json's phases ($(@($wpPlan.phases.Keys) -join ', '))" }
    $phases = @($wpPlan.phases[$Phase])
    $wpTables = Get-WpFieldTables $wpFieldsDir
    # the whole plan is checked as written, before anything is filtered.
    # -Alternate runs no mutant: when its field tables are not the
    # repository's test/mutants/wp_fields (a test's or a draft's, by
    # -FieldTables) the plan's catchers name tables that are not there, so
    # the plan is not checked against them; on test/mutants/wp_fields,
    # named by -FieldTables or not, it is
    $full = { param([string]$p) $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p).TrimEnd([char[]]'\/') }
    $ownTables = (& $full $wpFieldsDir) -eq (& $full (Join-Path $here 'wp_fields'))
    $foreignAlternate = $Alternate -and -not $ownTables
    if (-not $foreignAlternate) { Test-WpPlanMutants $wpPlan.mutants $wpTables $wpPlan.mutants $wpPlan.phases }
    $wpSkipped = [System.Collections.Generic.List[string]]::new()
    # (-Alternate runs no mutant: its list stays empty)
    $todo = @(foreach ($m in $(if ($Alternate) { @() } else { $wpPlan.mutants })) {
            if ($Only.Count -and $Only -notcontains $m['id']) { continue }
            if ($phases -notcontains $m['landing']) { continue }
            # this run's entry is a copy: the batch switch narrows its
            # catchers, never the plan's own (a mutant with a fullscreen and
            # an in-app catcher keeps both in wp-mutants.json)
            $e = [ordered]@{}
            foreach ($k in $m.Keys) { $e[$k] = $m[$k] }
            if ($e.Contains('catchers')) {
                # the batch switch: a mutant runs with the catchers in this
                # batch; none left = not in this run at all
                $keep = @($e['catchers'] | Where-Object { Test-WpInBatch $wpTables.tables[$_['check']] })
                if ($keep.Count -eq 0) { $wpSkipped.Add("$($e['id']) (its checks are $(if ($Batch) { 'not in a batch' } else { 'in a batch: -Batch' }))"); continue }
                $e['catchers'] = $keep
            }
            $e
        })
}

$results = [System.Collections.Generic.List[object]]::new()
$started = Get-Date

# what the results were taken on: the commit, the self-test tree's own
# commit (-SelfTestTree), and this script's blob
$header = [ordered]@{
    commit = $sha; phase = $Phase
    plan = $planName; batch = $(if ($script:wp) { [bool]$Batch } else { $null })
    selfTestTree = $null
    runner = (git -C $root hash-object (Join-Path $here 'run.ps1')).Trim()
    baseline = $null
}
$warnings = [System.Collections.Generic.List[string]]::new()
if ($script:wp -and -not $dry) { $header['fieldTables'] = Get-WpTableBlobs $wpFieldsDir }

function Save-Results {
    ConvertTo-Json -InputObject ([ordered]@{ header = $header; warnings = @($warnings); results = @($results) }) -Depth 10 |
        Set-Content -Encoding utf8 (Join-Path $Out 'results.json')
    $md = [System.Collections.Generic.List[string]]::new()
    $md.Add("# $(if ($script:wp) { 'watch_page' } else { 'AC1' }) mutation check: $sha (phase $Phase)")
    $md.Add('')
    $md.Add("run.ps1 blob $($header.runner)$(if ($header.selfTestTree) { "; self-test tree $SelfTestTree at $($header.selfTestTree)" })" +
        "$(if ($header.baseline) { "; baseline $($header.baseline)" })")
    foreach ($w in $warnings) { $md.Add(''); $md.Add("Warning: $w") }
    if ($script:stopReason) { $md.Add(''); $md.Add("**$($script:stopReason)**") }
    $md.Add('')
    $md.Add("Started $($started.ToString('s')); $(@($results | Where-Object result -eq 'caught').Count) caught, " +
        "$(@($results | Where-Object result -eq 'survived').Count) survived, " +
        "$(@($results | Where-Object { $_.result -notin 'caught', 'survived' }).Count) other, of $($todo.Count).")
    $md.Add('')
    $md.Add('| id | change | location | expected check | kind | result | caught by | first failure line | note | s |')
    $md.Add('|---|---|---|---|---|---|---|---|---|---|')
    $esc = { param($s) ("$s" -replace '\|', '\|' -replace '\r?\n', ' ') }
    foreach ($r in $results) {
        $md.Add("| $($r.id) | $(& $esc $r.change) | $(& $esc $r.location) | $(& $esc $r.expected) | $($r.kind) | **$($r.result)** | $(& $esc $r.by) | $(& $esc $r.first) | $(& $esc $r.note) | $($r.seconds) |")
    }
    $md | Set-Content -Encoding utf8 (Join-Path $Out 'results.md')
}

function New-ResultRow($m, [string]$result, [string]$by, [string]$first, [datetime]$t0, $extra, [string]$note) {
    $row = [ordered]@{
        id = $m['id']; change = $m['change']; location = $m['location']; expected = $m['catcher']
        kind = $m['kind']; result = $result; by = $by; first = $first; note = $note
        seconds = [int]((Get-Date) - $t0).TotalSeconds
    }
    if ($extra) { $row['details'] = @($extra) }
    return [pscustomobject]$row
}

function Add-Result($m, [string]$result, [string]$by, [string]$first, [datetime]$t0, $extra = $null, [string]$note = '') {
    $results.Add((New-ResultRow $m $result $by $first $t0 $extra $note))
    Save-Results
    '{0,-5} {1,-8} {2}' -f $m['id'], $result, $(if ($first) { $first } else { $by })
}

# rewrites row [index] (a mutant judged again, against another baseline)
function Set-Result([int]$index, $m, [string]$result, [string]$by, [string]$first, [datetime]$t0, $extra = $null, [string]$note = '') {
    $results[$index] = New-ResultRow $m $result $by $first $t0 $extra $note
    Save-Results
    '{0,-5} {1,-8} {2} (judged again)' -f $m['id'], $result, $(if ($first) { $first } else { $by })
}

function Remove-Worktree([string]$dir) {
    if (Test-Path -LiteralPath $dir) {
        git -C $root worktree remove --force $dir 2>&1 | Out-Null
        # a build's paths can pass 260 characters; the plugin symlinks are
        # removed, not followed
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath "\\?\$((Resolve-Path -LiteralPath $dir).Path)" -Recurse -Force -ErrorAction SilentlyContinue }
    }
    git -C $root worktree prune 2>&1 | Out-Null
}

function New-Worktree([string]$dir, [switch]$Pub, [string]$at = '') {
    Remove-Worktree $dir
    $rev = if ($at) { $at } else { $sha }
    git -C $root worktree add --detach $dir $rev 2>&1 | Out-Null
    if ($LASTEXITCODE) { throw "git worktree add $dir failed" }
    # packages: the checkout's resolution when the lock file is the same,
    # else resolved from the pub cache. A build (-Pub) needs pub get itself:
    # it also writes the plugin registration (windows/flutter/generated_*)
    $lockSame = -not $Pub -and (Test-Path (Join-Path $root '.dart_tool\package_config.json')) -and
        ((Get-FileHash (Join-Path $root 'pubspec.lock')).Hash -eq (Get-FileHash (Join-Path $dir 'pubspec.lock')).Hash)
    if ($lockSame) {
        New-Item -ItemType Directory -Force (Join-Path $dir '.dart_tool') | Out-Null
        foreach ($f in 'package_config.json', 'package_graph.json') {
            $src = Join-Path $root ".dart_tool\$f"
            if (Test-Path $src) { Copy-Item $src (Join-Path $dir '.dart_tool') }
        }
    } else {
        Push-Location $dir
        try { & $Flutter pub get --offline 2>&1 | Out-Null } finally { Pop-Location }
        if ($LASTEXITCODE) { throw "flutter pub get failed in $dir" }
    }
}

function Invoke-Patch([string]$dir, $m) {
    $patch = Join-Path (Get-PatchDir) $m['patch']
    git -C $dir apply $patch 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
}

# runs a command with a time limit; the whole process tree is ended on
# timeout. Returns the exit code, or $null on timeout.
function Invoke-Limited([string]$file, [string[]]$argv, [string]$dir, [string]$log, [int]$minutes) {
    $p = Start-Process -FilePath $file -ArgumentList $argv -WorkingDirectory $dir -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $p.Handle | Out-Null
    if (-not $p.WaitForExit($minutes * 60000)) {
        taskkill /T /F /PID $p.Id 2>&1 | Out-Null
        return $null
    }
    return $p.ExitCode
}

# ------------------------------------------------------------------ memory
$script:stopReason = $null
$memoryLog = Join-Path $Out 'memory.log'

# true once free physical memory is at least -MinFreeMB; waits (polling every
# 30 s, logged) up to -MemoryWaitMinutes, then false and the run stops
function Wait-Memory([string]$before) {
    $since = Get-Date
    while ($true) {
        $free = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024)
        if ($free -ge $MinFreeMB) {
            if ((Get-Date) - $since -gt [timespan]::FromSeconds(1)) {
                $line = "$(Get-Date -Format s) $before`: $free MB free after waiting $([int]((Get-Date) - $since).TotalSeconds) s"
                Add-Content -Encoding utf8 $memoryLog $line
                $line | Out-Host
            }
            return $true
        }
        $line = "$(Get-Date -Format s) $before`: $free MB free (< $MinFreeMB), waiting"
        Add-Content -Encoding utf8 $memoryLog $line
        $line | Out-Host
        if (((Get-Date) - $since).TotalMinutes -ge $MemoryWaitMinutes) {
            $script:stopReason = "stopped before $before`: free memory stayed below $MinFreeMB MB for $MemoryWaitMinutes min"
            Add-Content -Encoding utf8 $memoryLog $script:stopReason
            return $false
        }
        Start-Sleep -Seconds 30
    }
}

# ------------------------------------------------------------------ shared worktree
# the files [m]'s patch creates (`--- /dev/null`): removed again on reset
function Get-CreatedFiles($m) {
    $prev = ''
    $made = @()
    foreach ($l in Get-Content (Join-Path (Get-PatchDir) $m['patch'])) {
        if ($prev -eq '--- /dev/null' -and $l.StartsWith('+++ b/')) { $made += $l.Substring(6) }
        $prev = $l
    }
    return , $made
}

# the files [m]'s patch changes that exist before it (restored on reset)
function Get-ChangedFiles($m) {
    $made = Get-CreatedFiles $m
    return , @(Get-Content (Join-Path (Get-PatchDir) $m['patch']) | Where-Object { $_ -match '^diff --git a/(\S+) b/' } |
            ForEach-Object { $Matches[1] } | Where-Object { $made -notcontains $_ } | Select-Object -Unique)
}

function Set-Mutant([string]$dir, $m) {
    $files = (Get-ChangedFiles $m) -join ' '
    Set-Content (Join-Path $dir 'MUTANT.txt') ("AC1 mutant $($m['id']) is applied here ($($m['patch'])): a run was " +
        "interrupted. Undo it with: git -C `"$dir`" checkout -- $files ; then delete this file.")
}

# restores only what the patch touched (a build dir beside it stays)
function Reset-Mutant([string]$dir, $m) {
    $changed = Get-ChangedFiles $m
    if ($changed.Count) { git -C $dir checkout -- @changed 2>&1 | Out-Null }
    $made = Get-CreatedFiles $m
    if ($made.Count) { git -C $dir clean -fd -- @made 2>&1 | Out-Null }
    Remove-Item (Join-Path $dir 'MUTANT.txt') -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------ unit / widget
function Invoke-UnitTest([string]$dir, $m, [datetime]$t0) {
    $id = $m['id']
    $log = Join-Path $Out "$id.test.jsonl"
    $code = Invoke-Limited $Flutter @('test', '--no-pub', '--concurrency=1', '--reporter', 'json', $m['test']) $dir $log 20
    $names = @{}; $prints = @{}; $firstErr = $null; $loadErr = $null; $done = $null
    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)) {
        if (-not "$line".StartsWith('{')) { continue }
        try { $e = $line | ConvertFrom-Json -AsHashtable } catch { continue }
        switch ($e['type']) {
            'testStart' { $names[$e['test']['id']] = $e['test']['name'] }
            'print' { $prints[$e['testID']] = "$($prints[$e['testID']])`n$($e['message'])" }
            'error' {
                $n = "$($names[$e['testID']])"
                if ($n -like 'loading *') { if (-not $loadErr) { $loadErr = $e['error'] } }
                else {
                    if (-not $failed.Contains($n)) { $failed.Add($n) }
                    if (-not $firstErr) { $firstErr = @{ name = $n; error = $e['error']; print = $prints[$e['testID']] } }
                }
            }
            'done' { $done = $e['success'] }
        }
    }
    # a hang is not a failing check: it may be the runner's or the machine's
    if ($null -eq $code) {
        return Add-Result $m 'error' '' 'the test run did not end within 20 min' $t0
    }
    if ($loadErr) {
        return Add-Result $m 'error' '' "does not compile / load: $((("$loadErr" -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1))" $t0
    }
    if ($firstErr) {
        $text = "$($firstErr.error)"
        # widget tests print the failure above a generic error
        if ($text.StartsWith('Test failed. See exception logs above.') -and $firstErr.print) {
            $lines = @("$($firstErr.print)" -split "`n")
            $i = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match '^The following .* was thrown' })
            if ($i -ge 0 -and $i + 1 -lt $lines.Count) { $text = $lines[$i + 1] }
        }
        $nonEmpty = @($text -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
        $first = if ($nonEmpty.Count) { $nonEmpty[0] } else { '' }
        # "Expected: [" says nothing on its own: with the next lines
        if ($first -match '[\[{(]$' -and $nonEmpty.Count -gt 1) {
            $which = $nonEmpty | Where-Object { $_.StartsWith('Which:') } | Select-Object -First 1
            $first = if ($which) { "$first … $which" } else { ($nonEmpty | Select-Object -First 3) -join ' ' }
        }
        # mutants.json names the test meant to catch it ("<file>: <name>"):
        # caught by another one says the catcher (or its name) has drifted
        $expected = "$($m['catcher'])" -replace "^$([regex]::Escape((Split-Path -Leaf $m['test']))): ", ''
        $note = if ($failed.Contains($expected)) { '' } else { "the expected catcher did not fail; failing: $($failed -join ' / ')" }
        return Add-Result $m 'caught' "$(Split-Path -Leaf $m['test']): $($firstErr.name)" $first $t0 $null $note
    }
    if ($done -eq $true -and $code -eq 0) { return Add-Result $m 'survived' '' '' $t0 }
    return Add-Result $m 'error' '' "flutter test exit $code without a failing test (see $id.test.jsonl)" $t0
}

function Invoke-UnitMutants($list) {
    $dir = Join-Path $work 'unit'
    New-Worktree $dir
    # the control: each test file once on the unmutated tree. A file that
    # fails (or hangs) there would "catch" every mutant of it
    $broken = @{}
    foreach ($test in @($list | ForEach-Object { $_['test'] } | Select-Object -Unique)) {
        if (-not (Wait-Memory "the unmutated $test")) { return }
        $log = Join-Path $Out "control.$([System.IO.Path]::GetFileNameWithoutExtension($test)).test.jsonl"
        $code = Invoke-Limited $Flutter @('test', '--no-pub', '--concurrency=1', '--reporter', 'json', $test) $dir $log 20
        "control $test`: $(if ($null -eq $code) { 'did not end within 20 min' } elseif ($code) { "exit $code" } else { 'passes' })"
        if ($code -ne 0) { $broken[$test] = Split-Path -Leaf $log }
    }
    foreach ($m in $list) {
        if ($broken.ContainsKey($m['test'])) {
            Add-Result $m 'error' '' "its test file fails unmutated (see $($broken[$m['test']]))" (Get-Date)
            continue
        }
        if (-not (Wait-Memory $m['id'])) { return }
        $t0 = Get-Date
        Set-Mutant $dir $m
        if (-not (Invoke-Patch $dir $m)) {
            Add-Result $m 'error' '' 'the patch does not apply' $t0
            Reset-Mutant $dir $m
            continue
        }
        # one mutant's runner failure is its row, not the end of the run
        try { Invoke-UnitTest $dir $m $t0 }
        catch { Add-Result $m 'error' '' "the runner failed: $($_.Exception.Message)" $t0 }
        finally { Reset-Mutant $dir $m }
    }
    Remove-Worktree $dir
}

# ------------------------------------------------------------------ self tests
function Invoke-Build([string]$dir, [string]$log) {
    $code = Invoke-Limited $Flutter @('build', 'windows', '--debug', '--no-pub') $dir $log 60
    return ($code -eq 0) -and (Test-Path (Join-Path $dir 'build\windows\x64\runner\Debug\LibrePili.exe'))
}

# runs one self test from the slot; returns the report path
function Invoke-SelfTest([string]$exe, [string]$scenario, [string]$dir, [string]$tag) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    $report = Join-Path $dir "$scenario.json"
    $shots = Join-Path $dir "${scenario}_shots"
    # an earlier run's report here (a reused -Out) would pass for this run's
    # when the app ends without writing one: missing must read as missing
    foreach ($old in $report, "$report.progress", $shots) {
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
    }
    $profileName = "mut-$tag-$scenario-$(Get-Random -Maximum 99999)"
    $fixtures = Join-Path $script:stDir 'test\fixtures\download_list'
    $argv = @('--selftest', '--profile', $profileName, '--out', $report) + $(switch ($scenario) {
            'download' { @('--download', $bvDownload, '--dl-transcribe', 'off') }
            'queue99' { @('--download-queue', $bvA, $bvB, '--damage-times', '99', '--shots', $shots, '--dl-transcribe', 'off') }
            'transcribe' { @('--download-transcribe', $bvT) }
            'listshots' { @('--download-list-shots', $fixtures, '--shots', $shots, '--dl-transcribe', 'off') }
        })
    $argv = @($argv | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } })
    if ($scenario -eq 'transcribe') {
        # a new profile has no recognition models (they live per profile,
        # appSupportDir/selftest-<name>/asr): a copy of the self tests' own
        if (-not (Test-Path (Join-Path $AsrModels 'silero-vad'))) { throw "no ASR models in $AsrModels (-AsrModels)" }
        $into = Join-Path $env:APPDATA "com.zxa24\LibrePili\selftest-$profileName"
        New-Item -ItemType Directory -Force $into | Out-Null
        Copy-Item -Recurse $AsrModels (Join-Path $into 'asr')
    }
    Clear-MediaKitHolders
    $p = Start-Process -FilePath $exe -ArgumentList $argv -PassThru
    if (-not $p.WaitForExit(30 * 60000)) {
        # ours: started just above
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        $p.WaitForExit(30000) | Out-Null
    }
    Start-Sleep -Seconds 2
    Remove-Profile $profileName
    return $report
}

function Install-Slot([string]$dir, [int]$slotNo = $Slot) {
    $from = Join-Path $dir 'build\windows\x64\runner\Debug'
    $exe = & pwsh -NoProfile -File $slotScript -Slot $slotNo -From $from
    if ($LASTEXITCODE) { throw "test-slot.ps1 failed: $exe" }
    return "$(@($exe)[-1])".Trim()
}

# flutter_inappwebview_windows installs NuGet packages at build time:
# nuget as the main checkout's build found it, and the packages it already
# has (then nothing is fetched); $own = a worktree made here
function Initialize-BuildTree([string]$dir, [bool]$own) {
    if (-not (Get-Command nuget -ErrorAction SilentlyContinue)) {
        $cache = Join-Path $main 'build\windows\x64\CMakeCache.txt'
        $hit = if (Test-Path $cache) { Select-String -Path $cache -Pattern '^NUGET:FILEPATH=(.+)$' | Select-Object -First 1 }
        $nuget = if ($hit) { $hit.Matches[0].Groups[1].Value } else { $null }
        if ($nuget -and (Test-Path $nuget)) { $env:PATH = "$(Split-Path $nuget);$env:PATH" }
    }
    $packages = Join-Path $main 'build\windows\x64\packages'
    $to = Join-Path $dir 'build\windows\x64'
    if ($own -and (Test-Path $packages) -and -not (Test-Path (Join-Path $to 'packages'))) {
        New-Item -ItemType Directory -Force $to | Out-Null
        Copy-Item -Recurse $packages $to
    }
}

function Invoke-SelfTestMutants($list) {
    # -SelfTestTree: an existing, unmutated checkout of the same lib/ with a
    # finished Windows build — only incremental builds then, and the tree is
    # left as found (unmutated, rebuilt)
    $own = -not $SelfTestTree
    if ($own) {
        $dir = Join-Path $work 'selftest'
        New-Worktree $dir -Pub
    } else {
        $dir = (Resolve-Path $SelfTestTree).Path
        if (git -C $dir status --porcelain -- lib windows/runner) { throw "$dir has changes under lib/ or windows/runner/: not an unmutated tree" }
        if (-not (Test-Path (Join-Path $dir '.dart_tool\package_config.json'))) {
            Push-Location $dir
            try { & $Flutter pub get --offline 2>&1 | Out-Null } finally { Pop-Location }
        }
    }
    $script:stDir = $dir
    Initialize-BuildTree $dir $own
    $script:built = 'none'
    $script:pendingRescale = [System.Collections.Generic.List[object]]::new()
    try {
        if ($script:wp) { Invoke-WpSelfTestLoop $list $dir }
        else { Invoke-SelfTestLoop $list $dir }
        if ($script:pendingRescale.Count -and -not $script:stopReason) { Invoke-RescaledBaseline $dir }
    } finally {
        if (-not $own) {
            # back to the tree as found: unmutated, and its build matching it
            if ($script:built -ne 'unmutated') {
                if (Wait-Memory 'the final rebuild of the unmutated tree') {
                    $t0 = Get-Date
                    $ok = Invoke-Build $dir (Join-Path $Out 'final.build.log')
                    if ($ok) { $script:built = 'unmutated' }
                    "final rebuild of the unmutated tree: $(if ($ok) { 'ok' } else { 'FAILED' }), $([int]((Get-Date) - $t0).TotalSeconds) s"
                }
            }
            $left = git -C $dir status --porcelain -- lib
            "self-test tree: lib $(if ($left) { "NOT clean: $left" } else { 'unmutated' }); its build: $($script:built)"
        }
    }
    if ($own) { Remove-Worktree $dir }
}

# the trees a baseline's reports depend on: the app's code, the list shots'
# fixtures, windows/runner (the self-test window channel, changed in S0a),
# and the media outside the repository the runs use (design §5 「基线清单」)
function Get-BaselineManifest([string[]]$media = @()) {
    $m = [ordered]@{
        commit = $sha
        lib = (git -C $root rev-parse "${sha}:lib").Trim()
        fixtures = (git -C $root rev-parse "${sha}:test/fixtures").Trim()
        windowsRunner = (git -C $root rev-parse "${sha}:windows/runner").Trim()
    }
    if ($script:wp) { $m['plan'] = 'watch_page' }
    if ($media.Count) { $m['media'] = Get-MediaHashes $media }
    return $m
}

# every file under each path (a file or a folder) -> its SHA-256, keyed by
# "<path as given>|<relative file>"
function Get-MediaHashes([string[]]$paths) {
    $out = [ordered]@{}
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p)) { $out["$p|"] = 'missing'; continue }
        $base = (Resolve-Path -LiteralPath $p).Path
        $files = if (Test-Path -LiteralPath $base -PathType Leaf) { @(Get-Item -LiteralPath $base) } else { @(Get-ChildItem -LiteralPath $base -Recurse -File | Sort-Object FullName) }
        foreach ($f in $files) {
            $rel = if ($f.FullName -eq $base) { '' } else { [System.IO.Path]::GetRelativePath($base, $f.FullName) -replace '\\', '/' }
            # keyed by the resolved path: the same folder typed another way
            # (relative, other case) is the same media
            $out["$($base.ToLowerInvariant())|$rel"] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        }
    }
    return $out
}

# the media a list of mutants' runs read: the transcribe scenario's ASR
# models (download plan); wp-mutants.json "media" and the snapshots of the
# checks' tables (watch_page)
function Get-RunMedia($list) {
    if (-not $script:wp) {
        return , @(if (@($list | Where-Object { $_['scenario'] -eq 'transcribe' }).Count) { $AsrModels })
    }
    return , (Get-WpMedia $wpPlan @($list | ForEach-Object { $_['catchers'] } | ForEach-Object { $wpTables.tables[$_['check']] }))
}

# before any mutant: -SelfTestTree must hold -Commit's lib/ and fixtures,
# and a -Baseline must pass and (by its manifest) be of the same trees
function Test-SelfTestInputs($list) {
    if ($SelfTestTree) {
        $tree = (Resolve-Path $SelfTestTree).Path
        $treeSha = (git -C $tree rev-parse HEAD).Trim()
        git -C $root diff --quiet $sha $treeSha -- lib test/fixtures windows/runner 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 1) { throw "-SelfTestTree $tree is at $treeSha, whose lib/, test/fixtures/ or windows/runner/ differ from $sha" }
        if ($LASTEXITCODE) { throw "-SelfTestTree ${tree}: cannot compare its commit $treeSha with $sha (git diff exit $LASTEXITCODE)" }
        if (git -C $tree status --porcelain -- lib test/fixtures windows/runner) { throw "$tree has changes under lib/, test/fixtures/ or windows/runner/: not an unmutated tree" }
        $header.selfTestTree = $treeSha
    }
    if ($Baseline) {
        if ($script:wp) {
            # a watch_page baseline that fails is not refused here: its
            # mutants are error and the run goes on (runner 补充②)
        } else {
            foreach ($sc in @($list | ForEach-Object { $_['scenario'] } | Select-Object -Unique)) {
                $rep = Join-Path $Baseline "$sc.json"
                $c = Get-Check (Read-Report $rep) $checkNames[$sc]
                if ($null -eq $c -or $c['pass'] -ne $true) { throw "the -Baseline $sc report did not pass ($rep): no mutant can be judged against it" }
            }
        }
        $file = Join-Path $Baseline 'manifest.json'
        if (Test-Path -LiteralPath $file) {
            $have = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
            $want = Get-BaselineManifest (Get-RunMedia $list)
            foreach ($k in 'lib', 'fixtures') {
                if ($have[$k] -ne $want[$k]) { throw "-Baseline $Baseline was taken on $($have['commit']), whose $k tree differs from ${sha}'s" }
            }
            # added later (design §5 「基线清单」): an older manifest without
            # them is used with a warning, as one without a manifest is
            if ($have.Contains('windowsRunner')) {
                if ($have['windowsRunner'] -ne $want['windowsRunner']) { throw "-Baseline $Baseline was taken on $($have['commit']), whose windows/runner tree differs from ${sha}'s" }
            } else { $warnings.Add("-Baseline $Baseline's manifest has no windows/runner tree: not checked") }
            if ($want.Contains('media')) {
                if ($have.Contains('media')) {
                    # every file this run reads, with the same hash; a baseline
                    # that also read other media (an -Alternate folder with
                    # more checks) is fine
                    $diff = Test-WpMediaCovers $have['media'] $want['media']
                    if ($diff.Count) { throw "-Baseline $Baseline was taken with other media (ASR models, files outside the repository) than this run's: $($diff[0])" }
                } else { $warnings.Add("-Baseline $Baseline's manifest has no media hashes: not checked") }
            }
            $header.baseline = "$Baseline (given; taken on $($have['commit']))"
        } else {
            $warnings.Add("-Baseline $Baseline has no manifest.json: not checked against $sha")
            $header.baseline = "$Baseline (given; no manifest)"
        }
    }
}

# design AC1 重跑规则: a networked download can retry by chance, so in these
# scenarios a difference next to a network retry (a `retryWait` status or an
# `again in` line in either report) is judged by a second run. The queue
# scenarios retry on purpose and are never rerun; --open-offline is listed
# for when the runner runs it
$rerunScenarios = @('download', 'transcribe', 'openOffline')

function Test-NetworkRetry([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    return (Get-Content -LiteralPath $file -Raw) -match 'retryWait|again in'
}

# why a mutant's self-test report cannot be judged: none, unreadable, or
# without the scenario's own check (the run did not get that far); $null
# when it can. Not a failing check: the app may have crashed or hung for
# reasons of its own
function Test-SelfTestReport([string]$file, [string]$scenario) {
    $r = Read-Report $file
    if ($null -eq $r) { return "no readable report (the self test did not finish): $file" }
    if ($null -eq (Get-Check $r $checkNames[$scenario])) { return "no '$($checkNames[$scenario])' check in the report: $file" }
    return $null
}

# A list-shot mutant whose shots differ from the baseline's only in size
# (the window opened at another screen scale) stays "not compared" unless a
# baseline at its scale can be had. The build is mutated while the mutants
# run, so that baseline is taken once, after them, from the unmutated tree
# (every mutant restores its files): built here unless the tree's build is
# already the unmutated one, then the list-shots self test into
# <Out>\baseline-rescaled\ and each such mutant's saved report judged again
# against it (caught / survived / still "not compared" if the sizes still
# differ). The row's note names the baseline it was judged against.
function Invoke-RescaledBaseline([string]$dir) {
    $base = Join-Path $Out 'baseline-rescaled'
    if ($script:built -ne 'unmutated') {
        if (-not (Wait-Memory 'the unmutated build for a rescaled baseline')) { return }
        $script:built = 'unknown (building the unmutated tree)'
        if (-not (Invoke-Build $dir (Join-Path $Out 'baseline-rescaled.build.log'))) {
            "unmutated build for the rescaled baseline FAILED (baseline-rescaled.build.log)"
            return
        }
        $script:built = 'unmutated'
    }
    $exe = Install-Slot $dir
    $rep = Invoke-SelfTest $exe 'listshots' $base 'base-rescaled'
    $c = Get-Check (Read-Report $rep) $checkNames['listshots']
    if ($null -eq $c -or $c['pass'] -ne $true) {
        "the rescaled listshots baseline did not pass ($rep): the 'not compared' rows stay"
        return
    }
    $size = { param($f) Get-Field (Get-Check (Read-Report $f) $checkNames['listshots']) 'shotSize' }
    "rescaled baseline: shots $(& $size $rep)"
    foreach ($p in $script:pendingRescale) {
        $m = $p.m
        $diffs = Compare-Scenario 'listshots' $rep $p.report
        $real = @($diffs | Where-Object { -not $_.StartsWith($notCompared) })
        $note = "baseline: $base (shots $(& $size $rep); this mutant's $(& $size $p.report)); the first baseline's were another size"
        if ($real.Count) {
            Set-Result $p.index $m 'caught' "listshots: $(($real[0] -split ':')[0])" $real[0] $p.t0 $diffs $note
        } elseif ($diffs.Count) {
            Set-Result $p.index $m 'not compared' '' $diffs[0] $p.t0 $diffs $note
        } else {
            Set-Result $p.index $m 'survived' '' '' $p.t0 $null $note
        }
    }
}

function Invoke-SelfTestLoop($list, [string]$dir) {
    $scenarios = @($list | ForEach-Object { $_['scenario'] } | Select-Object -Unique)
    $base = $Baseline
    if (-not $base) {
        $base = Join-Path $Out 'baseline'
        if (-not (Wait-Memory 'the baseline build')) { return }
        $t0 = Get-Date
        if (-not (Invoke-Build $dir (Join-Path $Out 'baseline.build.log'))) { throw 'the unmutated build failed (baseline.build.log)' }
        $script:built = 'unmutated'
        "baseline build: $([int]((Get-Date) - $t0).TotalSeconds) s"
        $exe = Install-Slot $dir
        foreach ($sc in $scenarios) {
            $rep = Invoke-SelfTest $exe $sc $base 'base'
            $c = Get-Check (Read-Report $rep) $checkNames[$sc]
            $ok = $null -ne $c -and $c['pass'] -eq $true
            "baseline $sc pass=$ok"
            if (-not $ok) { throw "the baseline $sc self test did not pass ($rep): no mutant can be judged against it" }
        }
        # read by a later -Baseline of this folder
        ConvertTo-Json -InputObject (Get-BaselineManifest (Get-RunMedia $list)) -Depth 5 | Set-Content -Encoding utf8 (Join-Path $base 'manifest.json')
        $header.baseline = "$base (built here)"
        Save-Results
        "baseline: $([int]((Get-Date) - $t0).TotalSeconds) s"
    }
    foreach ($m0 in $list) {
        # a mutant a unit test catches first, run here too (-SelfTestAll):
        # its row is <id>/selftest, judged by its self-test catcher
        $m = @{} + $m0
        if ($m0.Contains('test')) {
            $m['id'] = "$($m0['id'])/selftest"
            if ($m0.Contains('selftestCatcher')) { $m['catcher'] = $m0['selftestCatcher'] }
        }
        $m['kind'] = 'selftest'
        if (-not (Wait-Memory $m['id'])) { return }
        $t0 = Get-Date
        $id = $m0['id']
        Set-Mutant $dir $m0
        if (-not (Invoke-Patch $dir $m0)) {
            Add-Result $m 'error' '' 'the patch does not apply' $t0
            Reset-Mutant $dir $m0
            continue
        }
        try {
            $script:built = "unknown (building $id)"
            if (-not (Invoke-Build $dir (Join-Path $Out "$id.build.log"))) {
                Add-Result $m 'error' '' "the build failed (see $id.build.log)" $t0
                continue
            }
            $script:built = "mutant $id"
            $exe = Install-Slot $dir
            $sc = $m['scenario']
            $rep = Invoke-SelfTest $exe $sc (Join-Path $Out $id) $id
            # no report is not a failing check: the app may have crashed or
            # hung for reasons of its own (the build, the slot, the network)
            if ($bad = Test-SelfTestReport $rep $sc) {
                Add-Result $m 'error' '' $bad $t0
                continue
            }
            $diffs = Compare-Scenario $sc (Join-Path $base "$sc.json") $rep
            $real = @($diffs | Where-Object { -not $_.StartsWith($notCompared) })
            $note = if ($sc -eq 'listshots') { "baseline: $base" } else { '' }
            if ($real.Count -and $rerunScenarios -contains $sc -and
                ((Test-NetworkRetry (Join-Path $base "$sc.json")) -or (Test-NetworkRetry $rep))) {
                # judged by the second run; both reports are kept
                $rep2 = Invoke-SelfTest $exe $sc (Join-Path $Out "$id\rerun") "$id-rerun"
                $note = "rerun (network retry): $(Split-Path -Parent $rep), then $(Split-Path -Parent $rep2); the first run's: $($real[0])"
                if ($bad = Test-SelfTestReport $rep2 $sc) {
                    Add-Result $m 'error' '' "the rerun: $bad" $t0 $diffs $note
                    continue
                }
                $diffs = Compare-Scenario $sc (Join-Path $base "$sc.json") $rep2
                $real = @($diffs | Where-Object { -not $_.StartsWith($notCompared) })
            }
            if ($real.Count) {
                Add-Result $m 'caught' "$($sc): $(($real[0] -split ':')[0])" $real[0] $t0 $diffs $note
            } elseif ($diffs.Count) {
                # only shots that could not be compared: neither caught nor
                # survived, until a baseline at the same scale is had (after
                # the loop, Invoke-RescaledBaseline)
                $script:pendingRescale.Add(@{ index = $results.Count; m = $m; report = $rep; t0 = $t0 })
                Add-Result $m 'not compared' '' $diffs[0] $t0 $diffs $note
            } else {
                Add-Result $m 'survived' '' '' $t0 $null $note
            }
        } catch {
            # one mutant's runner failure (the slot, a comparison) is its row
            Add-Result $m 'error' '' "the runner failed: $($_.Exception.Message)" $t0
        } finally {
            Reset-Mutant $dir $m0
        }
    }
}
# ------------------------------------------------------------------ watch_page: runs
# an unmutated report a mutant can be judged against: measured, and for a
# judging check pass true (a recording check's pass is measured)
function Test-WpBaselinePass($t, [string]$file) {
    $s = Get-WpPassState $t 'baseline' $file
    if ($s.state -ne 'ok') { return @{ ok = $false; why = "$($s.state)$(if ($s.why) { " ($($s.why))" })" } }
    if ($t['type'] -eq 'judging' -and $s.check['pass'] -ne $true) { return @{ ok = $false; why = "pass is $(ConvertTo-WpCanon $s.check['pass'])" } }
    return @{ ok = $true; why = '' }
}

function Invoke-WpSelfTestLoop($list, [string]$dir) {
    $needed = [System.Collections.Generic.List[string]]::new()
    foreach ($m in $list) { foreach ($c in @($m['catchers'])) { if (-not $needed.Contains($c['check'])) { $needed.Add($c['check']) } } }
    # one run per report file (tables sharing a report share its run)
    $groups = Get-WpRunGroups @($needed | ForEach-Object { $wpTables.tables[$_] })
    $lpTree = $dir
    $dirRoot = ($dir -replace '\\', '/').TrimEnd('/')
    $lpExe = $null
    $baseFiles = @{}; $broken = @{}
    if ($Baseline) {
        $base = (Resolve-Path -LiteralPath $Baseline).Path
        $bm = Join-Path $base 'manifest.json'
        $baseRoot = if (Test-Path -LiteralPath $bm) { Get-WpRoot (Read-WpJson $bm) } else { '' }
        if (-not $baseRoot) { $warnings.Add("-Baseline $Baseline names no root: uiErrors paths in its reports are not made relative") }
        foreach ($id in $needed) {
            $t = $wpTables.tables[$id]
            $f = Join-Path $base $t['report']
            if (-not (Test-Path -LiteralPath $f)) { $f = Join-Path $base "pass1\$($t['report'])" }
            $ok = Test-WpBaselinePass $t $f
            if (-not $ok.ok) { $broken[$id] = "the -Baseline report did not pass: $($ok.why)" }
            $baseFiles[$id] = $f
            "baseline $id`: $(if ($ok.ok) { 'ok' } else { $ok.why })"
        }
    } else {
        $base = Join-Path $Out 'baseline'
        $baseRoot = $dirRoot
        if (-not (Wait-Memory 'the baseline build')) { return }
        $t0 = Get-Date
        if (-not (Invoke-Build $dir (Join-Path $Out 'baseline.build.log'))) { throw 'the unmutated build failed (baseline.build.log)' }
        $script:built = 'unmutated'
        "baseline build: $([int]((Get-Date) - $t0).TotalSeconds) s"
        $lpExe = Install-Slot $dir
        foreach ($g in $groups) {
            $f = Invoke-WpSelfTest $lpExe $g.t $wpPlan $base 'base' $dir
            $fails = @($g.tables | Where-Object { -not (Test-WpBaselinePass $_ $f).ok })
            $f2 = $null
            # runner 补充②: an unmutated report that fails is rerun once (a
            # network failure, risk control); failing again, that check's
            # mutants are error and the run goes on
            if ($fails.Count) { $f2 = Invoke-WpSelfTest $lpExe $g.t $wpPlan (Join-Path $base 'rerun') 'base-rerun' $dir }
            foreach ($t in $g.tables) {
                $ok = Test-WpBaselinePass $t $f
                $baseFiles[$t['id']] = $f
                if (-not $ok.ok) {
                    $ok2 = Test-WpBaselinePass $t $f2
                    if ($ok2.ok) { $baseFiles[$t['id']] = $f2; $ok = $ok2 } else { $broken[$t['id']] = "the baseline did not pass twice: $($ok.why); $($ok2.why)" }
                }
                $cn = @((Get-WpCrashNote $f), $(if ($f2) { Get-WpCrashNote $f2 }) | Where-Object { $_ }) -join '; '
                "baseline $($t['id'])`: $(if ($ok.ok) { 'ok' } else { $broken[$t['id']] })$(if ($cn) { " [$cn]" })"
            }
        }
        $man = Get-BaselineManifest (Get-RunMedia $list)
        $man['root'] = (Resolve-Path -LiteralPath $dir).Path
        ConvertTo-Json -InputObject $man -Depth 5 | Set-Content -Encoding utf8 (Join-Path $base 'manifest.json')
        $header.baseline = "$base (built here)"
        Save-Results
    }
    foreach ($m in $list) {
        $id = $m['id']
        if (-not (Wait-Memory $id)) { return }
        $t0 = Get-Date
        Set-Mutant $dir $m
        if (-not (Invoke-Patch $dir $m)) {
            Add-Result $m 'error' '' 'the patch does not apply' $t0
            Reset-Mutant $dir $m
            continue
        }
        try {
            $script:built = "unknown (building $id)"
            if (-not (Invoke-Build $dir (Join-Path $Out "$id.build.log"))) {
                Add-Result $m 'error' '' "the build failed (see $id.build.log)" $t0
                continue
            }
            $script:built = "mutant $id"
            $lpExe = Install-Slot $dir
            $lpPatch = Join-Path (Get-PatchDir) $m['patch']
            # a catcher whose report another catcher already ran reuses it
            # (one command line, one run); reruns are always new runs
            $lpCache = @{}
            $rows = [System.Collections.Generic.List[object]]::new()
            foreach ($c in @($m['catchers'])) {
                $lpT = $wpTables.tables[$c['check']]
                $exp = [string[]]@($c['expected'])
                if ($broken.ContainsKey($lpT['id'])) { $rows.Add(@{ result = 'error'; by = ''; first = "$($lpT['id']): $($broken[$lpT['id']])"; note = '' }); continue }
                # read through dynamic scope by Invoke-WpCatcher (names
                # prefixed lp so its own parameters do not hide them)
                $run = {
                    param([string]$runDir, [string]$runTag)
                    $k = "$($lpT['report'])"
                    if ($runTag -notlike '*-rerun' -and $lpCache.ContainsKey($k)) { return $lpCache[$k] }
                    $r = Invoke-WpSelfTest $lpExe $lpT $wpPlan $runDir $runTag $lpTree
                    if ($runTag -notlike '*-rerun') { $lpCache[$k] = $r }
                    return $r
                }
                $r = Invoke-WpCatcher $lpT $exp $baseFiles[$lpT['id']] $baseRoot $dirRoot $lpPatch $run (Join-Path $Out "$id\$($lpT['id'])") $id
                $rows.Add($r)
                if ($r.result -eq 'caught') { break }
            }
            $v = Resolve-WpMutantResult $rows
            Add-Result $m $v.result $v.by $v.first $t0 $v.details $v.note
        } catch {
            Add-Result $m 'error' '' "the runner failed: $($_.Exception.Message)" $t0
        } finally {
            Reset-Mutant $dir $m
        }
    }
}

# runner 补充⑩: the unmutated checks on two commits, alternating
function Invoke-WpAlternate {
    if ($Plan -eq 'download') { throw '-Alternate is a watch_page mode' }
    $plan = Read-WpPlan
    $tset = Get-WpFieldTables $wpFieldsDir
    foreach ($c in $Checks) { if (-not $tset.tables.Contains($c)) { throw "-Checks: no field table $c in $wpFieldsDir" } }
    $sel = @($tset.tables.Values | Where-Object { ($Checks.Count -eq 0 -or $Checks -contains $_['id']) -and (Test-WpInBatch $_) })
    $off = @($tset.tables.Values | Where-Object { ($Checks.Count -eq 0 -or $Checks -contains $_['id']) -and -not (Test-WpInBatch $_) })
    if ($sel.Count -eq 0) { throw "-Alternate: no field table to run in $($tset.dir)$(if ($off.Count) { " ($($off.Count) are $(if ($Batch) { 'not in a batch' } else { 'in a batch: -Batch' }))" })$(if ($tset.examples.Count) { "; examples skipped: $($tset.examples -join ', ')" })" }
    $noRun = @($sel | Where-Object { $null -eq $_['run'] })
    if ($noRun.Count) { throw "-Alternate: $(@($noRun | ForEach-Object { $_['id'] }) -join ', ') have no run" }
    $newSha = $sha
    $parentSha = Resolve-WpCommit $(if ($Parent) { $Parent } else { "$Commit^" }) '-Parent'
    $same = $parentSha -eq $newSha
    $slotB = if ($Slot2) { $Slot2 } else { ($Slot % 3) + 1 }
    if (-not $same -and $slotB -eq $Slot) { throw "-Slot2 must differ from -Slot ($Slot): each build has its own slot" }
    $wtA = Join-Path $work 'wpA'; $wtB = Join-Path $work 'wpB'
    # a debug build bakes its source paths in; uiErrors texts are cut at 320
    # characters, so the two roots must be equally long for the cut to fall
    # in the same place (design §5 S0a 「核对」)
    if ($wtA.Length -ne $wtB.Length) { throw "worktree roots of different length: $wtA, $wtB" }
    $sides = if ($same) {
        @(@{ tag = 'same'; sha = $newSha; wt = $wtA; slot = $Slot; out = (Join-Path $Out $newSha.Substring(0, 9)) })
    } else {
        @(@{ tag = 'parent'; sha = $parentSha; wt = $wtA; slot = $Slot; out = (Join-Path $Out "parent-$($parentSha.Substring(0, 9))") },
            @{ tag = 'new'; sha = $newSha; wt = $wtB; slot = $slotB; out = (Join-Path $Out "new-$($newSha.Substring(0, 9))") })
    }
    if ($OnlySide) {
        if ($same) { throw '-OnlySide: both sides are the same commit' }
        $sides = @($sides | Where-Object tag -eq $OnlySide)
    }
    foreach ($sd in $sides) {
        $sd.next = 1
        $mf = Join-Path $sd.out 'manifest.json'
        if (Test-Path -LiteralPath $mf) {
            $have = Read-WpJson $mf
            if ($have['commit'] -ne $sd.sha) { throw "$($sd.out) holds reports of $($have['commit']), not $($sd.sha)" }
            $last = @(Get-WpPassDirs $sd.out | ForEach-Object { [int]($_.name -replace '^pass', '') }) | Sort-Object | Select-Object -Last 1
            if ($last) { $sd.next = $last + 1 }
        }
    }
    if ($sides.Count -eq 2 -and $sides[0].next -ne $sides[1].next) {
        "warning: the two folders have $($sides[0].next - 1) and $($sides[1].next - 1) passes: the new passes do not pair up"
    }
    # one run per report file: tables sharing a report share its command
    # line (a covering check would otherwise cover the screen once per table)
    $groups = Get-WpRunGroups $sel
    $order = [System.Collections.Generic.List[object]]::new()
    for ($k = 0; $k -lt $Passes; $k++) {
        foreach ($sd in $sides) { foreach ($g in $groups) { $order.Add(@{ n = $order.Count + 1; side = $sd; pass = $sd.next + $k; t = $g.t; g = $g; ids = (@($g.tables | ForEach-Object { $_['id'] }) -join '+') }) } }
    }
    "watch_page alternate$(if ($DryRun) { ' (dry run: nothing is built, launched or written)' }): $(if ($same) { "one commit $newSha (calibration runs)" } else { "parent $parentSha, new $newSha" })"
    foreach ($sd in $sides) { "  $($sd.tag): worktree $($sd.wt) (root length $($sd.wt.Length)), slot $($sd.slot), reports $($sd.out) from pass$($sd.next)" }
    "  $($sel.Count) check(s): $(@($sel | ForEach-Object { $_['id'] }) -join ', ')$(if ($off.Count) { "; skipped by the batch switch: $(@($off | ForEach-Object { $_['id'] }) -join ', ')" })"
    "  $($order.Count) runs, in this order:"
    foreach ($o in $order) {
        $pf = if ("$($o.t['run']['profile'])".StartsWith('snapshot:')) { "$($o.t['run']['profile'])" } else { 'new profile' }
        $pdir = Join-Path $o.side.out "pass$($o.pass)"
        $argv = Get-WpRunArgs $o.t $plan "wp-$($o.side.tag)-p$($o.pass)-$($o.t['id'])-N" (Join-Path $pdir $o.t['report']) (Join-Path $pdir "$($o.t['id'])_shots") $o.side.wt $pdir
        '  {0,4} pass{1,-3} {2,-6} {3,-28} {4}: {5}' -f $o.n, $o.pass, $o.side.tag, $o.ids, $pf, ($argv -join ' ')
    }
    if ($DryRun) { return }

    foreach ($sd in $sides) {
        $reuse = $false
        if (Test-Path -LiteralPath $sd.wt) {
            $head = "$(git -C $sd.wt rev-parse HEAD 2>$null)".Trim()
            $dirty = git -C $sd.wt status --porcelain -- lib windows/runner test/fixtures
            $reuse = $head -eq $sd.sha -and -not $dirty -and (Test-Path (Join-Path $sd.wt 'build\windows\x64\runner\Debug\LibrePili.exe'))
        }
        if ($reuse) { "$($sd.tag): reusing the build in $($sd.wt) (alternate runs do not rebuild)" }
        else {
            New-Worktree $sd.wt -Pub -at $sd.sha
            Initialize-BuildTree $sd.wt $true
            if (-not (Wait-Memory "the $($sd.tag) build")) { $script:stopReason; exit 3 }
            $t0 = Get-Date
            if (-not (Invoke-Build $sd.wt (Join-Path $Out "build-$($sd.tag).log"))) { throw "the $($sd.tag) build failed (build-$($sd.tag).log); the worktree $($sd.wt) is kept" }
            "$($sd.tag) build: $([int]((Get-Date) - $t0).TotalSeconds) s"
        }
        $sd.exe = Install-Slot $sd.wt $sd.slot
        New-Item -ItemType Directory -Force $sd.out | Out-Null
        $trees = Get-WpTrees $sd.sha
        $man = [ordered]@{ plan = 'watch_page'; commit = $sd.sha }
        foreach ($k in $trees.Keys) { $man[$k] = $trees[$k] }
        $man['media'] = Get-MediaHashes (Get-WpMedia $plan $sel)
        $man['root'] = (Resolve-Path -LiteralPath $sd.wt).Path
        $man['runner'] = (git -C $root hash-object (Join-Path $here 'run.ps1')).Trim()
        $man['slot'] = $sd.slot
        $mf = Join-Path $sd.out 'manifest.json'
        if (Test-Path -LiteralPath $mf) {
            $have = Read-WpJson $mf
            if ((ConvertTo-WpCanon $have['media']) -ne (ConvertTo-WpCanon $man['media'])) { throw "$($sd.out): the media differ from the earlier passes' (manifest.json): use a new -Out" }
            if ($have['root'] -ne $man['root']) { throw "$($sd.out): the earlier passes were built in $($have['root']), these in $($man['root'])" }
        } else {
            ConvertTo-Json -InputObject $man -Depth 5 | Set-Content -Encoding utf8 $mf
        }
    }
    $started = @{}
    foreach ($o in $order) {
        if (-not (Wait-Memory "run $($o.n) ($($o.side.tag) pass$($o.pass) $($o.ids))")) { break }
        $t0 = Get-Date
        $pdir = Join-Path $o.side.out "pass$($o.pass)"
        $pk = "$($o.side.tag)|$($o.pass)"
        if (-not $started.ContainsKey($pk)) {
            # before the pass runs: the checks it is meant to hold, so a
            # pass of some checks (a rerun with -Checks, a batch) is not
            # read as the others' missing reports (Get-WpPassDirs)
            New-Item -ItemType Directory -Force $pdir | Out-Null
            ConvertTo-Json -InputObject ([ordered]@{ pass = $o.pass; checks = @($sel | ForEach-Object { $_['id'] }); started = $t0.ToString('s') }) |
                Set-Content -Encoding utf8 (Join-Path $pdir 'pass.json')
            $started[$pk] = $true
        }
        $rep = Invoke-WpSelfTest $o.side.exe $o.t $plan $pdir "$($o.side.tag)-p$($o.pass)" $o.side.wt
        $cn = Get-WpCrashNote $rep
        foreach ($t in $o.g.tables) {
            $st = Get-WpPassState $t "pass$($o.pass)" $rep
            # written run by run: an interrupted batch keeps what it ran
            ConvertTo-Json -Compress -InputObject ([ordered]@{
                    n = $o.n; side = $o.side.tag; commit = $o.side.sha; pass = $o.pass; check = $t['id']; report = $rep
                    state = $st.state; why = $st.why; started = $t0.ToString('s'); seconds = [int]((Get-Date) - $t0).TotalSeconds
                    crash = $(if ($cn) { $cn } else { $null })
                }) | Add-Content -Encoding utf8 (Join-Path $o.side.out 'runs.jsonl')
            '{0,4} pass{1,-3} {2,-6} {3,-28} {4}' -f $o.n, $o.pass, $o.side.tag, $t['id'], "$($st.state)$(if ($st.why) { " ($($st.why))" })$(if ($cn) { " [$cn]" })"
        }
    }
    if ($sides.Count -eq 2) { "next: run.ps1 -Plan watch_page -Compare $($sides[0].out),$($sides[1].out) -Out <dir>" }
    elseif ($same) { "next: run.ps1 -Plan watch_page -Compare $($sides[0].out) -Out <dir>   (calibration)" }
    if ($Cleanup) { foreach ($sd in $sides) { Remove-Worktree $sd.wt } }
    else { "worktrees kept for more passes: $(@($sides | ForEach-Object wt) -join ', ') (-Cleanup removes them)" }
    if ($script:stopReason) { $script:stopReason; exit 3 }
}

# ------------------------------------------------------------------ run
if ($Alternate) {
    Invoke-WpAlternate
    return
}
if ($script:wp) {
    # 未覆盖 entries are listed, not run (AC-S0)
    foreach ($m in @($todo | Where-Object { $_.Contains('uncovered') })) {
        if ($DryRun) { "$($m['id']) not covered: $($m['uncovered'])" } else { Add-Result $m 'not covered' '' "$($m['uncovered'])" (Get-Date) }
    }
    $todo = @($todo | Where-Object { -not $_.Contains('uncovered') })
    # a later step's mutant in its own phase, not written yet (see the header)
    foreach ($m in @($todo | Where-Object { $_.Contains('pending') })) {
        $why = "lands in $($m['landing']): $($m['pending'])"
        if ($DryRun) { "$($m['id']) not written: $why" } else { Add-Result $m 'not written' '' $why (Get-Date) }
    }
    $todo = @($todo | Where-Object { -not $_.Contains('pending') })
    if ($wpSkipped.Count) { "skipped by the batch switch: $($wpSkipped -join ', ')" }
    if ($wpPlan.examples.Count) { "example entries skipped: $($wpPlan.examples -join ', ')" }
    if ($DryRun) {
        # -DryRun: the plan as checked and narrowed by -Phase / -Only /
        # -Batch, each mutant's catchers and each baseline's command line;
        # nothing is built, launched or written
        "watch_page mutation check (dry run: nothing is built, launched or written): $sha, phase $Phase, $($todo.Count) mutants"
        $need = [ordered]@{}
        foreach ($m in $todo) {
            $cs = @(foreach ($c in @($m['catchers'])) { $need[$c['check']] = $true; "$($c['check']) [$(@($c['expected']) -join ', ')]" })
            '  {0,-8} {1,-5} {2,-44} {3}' -f $m['id'], $m['landing'], $m['location'], ($cs -join '; ')
        }
        # tables sharing a report share one run (one command line)
        $runs = [ordered]@{}
        foreach ($id in $need.Keys) {
            $t = $wpTables.tables[$id]
            if (-not $runs.Contains($t['report'])) { $runs[$t['report']] = [System.Collections.Generic.List[string]]::new() }
            $runs[$t['report']].Add($id)
        }
        "baselines: $($runs.Count) unmutated runs for $($need.Count) tables$(if ($Baseline) { " (from -Baseline $Baseline when its reports are there)" })"
        foreach ($rep in $runs.Keys) {
            $t = $wpTables.tables[$runs[$rep][0]]
            $pf = if ("$($t['run']['profile'])".StartsWith('snapshot:')) { "$($t['run']['profile'])" } else { 'new profile' }
            $argv = Get-WpRunArgs $t $wpPlan "wp-baseline-$($t['id'])" (Join-Path '<dir>' $rep) (Join-Path '<dir>' "$($t['id'])_shots") $root '<dir>'
            '  {0,-28} {1}{2}: {3}' -f ($runs[$rep] -join ','), "$(if ($t['batch']) { "[$($t['batch'])] " })", $pf, ($argv -join ' ')
        }
        return
    }
}
# (the outer @(): an if's value of an empty list is $null, which StrictMode
# then refuses .Count on, e.g. a phase whose entries are all pending)
$st = @(if ($script:wp) { @($todo | Where-Object { $_.Contains('catchers') }) }
    else { @($todo | Where-Object { $_.Contains('scenario') -and ($SelfTestAll -or -not $_.Contains('test')) }) })
if ($NoSelfTest) { $st = @() }
if ($st.Count) { Test-SelfTestInputs $st }
"$(if ($script:wp) { 'watch_page' } else { 'AC1' }) mutation check: $sha, phase $Phase, $($todo.Count) mutants -> $Out"
"run.ps1 blob $($header.runner)$(if ($header.selfTestTree) { "; self-test tree at $($header.selfTestTree)" })"
$warnings | ForEach-Object { "warning: $_" }
Save-Results
$tUnit = Get-Date
$unit = @($todo | Where-Object { $_.Contains('test') })
if ($unit.Count -and -not $NoUnit) {
    Invoke-UnitMutants $unit
    "unit part: $($unit.Count) mutants, $([int]((Get-Date) - $tUnit).TotalMinutes) min"
}
if ($st.Count -and -not $script:stopReason) {
    $tSt = Get-Date
    Invoke-SelfTestMutants $st
    "self-test part: $($st.Count) mutants, $([int]((Get-Date) - $tSt).TotalMinutes) min"
}
Save-Results
# 未覆盖 is neither caught nor survived (AC-S0): listed, not a failure
$sv = @($results | Where-Object { $_.result -ne 'caught' -and $_.result -ne 'not covered' })
"done in $([int]((Get-Date) - $started).TotalMinutes) min: $(@($results | Where-Object { $_.result -eq 'caught' }).Count) caught, $($sv.Count) not ($(($sv | ForEach-Object { "$($_.id) $($_.result)" }) -join ', '))"
if ($script:stopReason) {
    $script:stopReason
    Remove-Worktree (Join-Path $work 'unit')
    Remove-Worktree (Join-Path $work 'selftest')
    exit 3
}
if ($sv.Count) { exit 1 }
