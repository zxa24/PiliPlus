# AC1 mutation check (feature-logs/download-platforms design, AC1 「变异检查」).
#
# Each mutant in mutants.json is a small, deliberate regression of the
# bilibili download code; each must make at least one AC1 check fail. The
# patches are only ever applied in throwaway git worktrees under
# _tmp/mutants/, never to the checked-out lib/.
#
#   pwsh -NoProfile -File test/mutants/run.ps1 [-Commit <rev>] [-Phase 0|1a|1b]
#        [-Only M1,M15] [-Slot 1] [-Out <dir>] [-Baseline <dir>] [-NoSelfTest]
#        [-Flutter <flutter.bat>] [-Work <dir>] [-SelfTestAll] [-SelfTestTree <dir>]
#        [-NoUnit] [-AsrModels <dir>]
#   pwsh -NoProfile -File test/mutants/run.ps1 -Compare <baseDir>,<otherDir>
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
param(
    [string]$Commit = 'HEAD',
    [ValidateSet('0', '1a', '1b')] [string]$Phase = '0',
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
    [string]$AsrModels = (Join-Path $env:APPDATA 'com.zxa24\LibrePili\selftest\asr')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
# `pwsh -File` hands "a,b" over as one string
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Compare = @($Compare | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

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
if (-not $Flutter) {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    $Flutter = if ($cmd) { $cmd.Source } else { '' }
    if (-not $Flutter) { throw 'flutter is not on PATH: pass -Flutter <path to flutter.bat>' }
}
$sha = (git -C $root rev-parse --verify "$Commit^{commit}").Trim()
if (-not $Out) { $Out = Join-Path $root "_tmp\mutants-results\$(Get-Date -Format yyyyMMdd-HHmmss)" }
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
# -Work: where the worktrees go. A short path when the checkout itself is
# deep: MSVC cannot open plugin headers past 260 characters (a build in
# .claude\worktrees\<agent>\_tmp\mutants\selftest reaches 263)
$work = if ($Work) { $Work } else { Join-Path $root '_tmp\mutants' }
New-Item -ItemType Directory -Force $work | Out-Null

$all = Get-Content -Raw (Join-Path $here 'mutants.json') | ConvertFrom-Json -AsHashtable
$phases = @{ '0' = @('both'); '1a' = @('both', '1a-only'); '1b' = @('1b-only') }[$Phase]
$todo = @($all | Where-Object {
        ($Only.Count -eq 0 -or $Only -contains $_['id']) -and (
            $phases -contains $_['phase'] -or
            # 1b: also the self-test items it touches (--download-transcribe)
            ($Phase -eq '1b' -and $_.Contains('scenario') -and $_['scenario'] -eq 'transcribe'))
    })

$results = [System.Collections.Generic.List[object]]::new()
$started = Get-Date

# what the results were taken on: the commit, the self-test tree's own
# commit (-SelfTestTree), and this script's blob
$header = [ordered]@{
    commit = $sha; phase = $Phase
    selfTestTree = $null
    runner = (git -C $root hash-object (Join-Path $here 'run.ps1')).Trim()
    baseline = $null
}
$warnings = [System.Collections.Generic.List[string]]::new()

function Save-Results {
    ConvertTo-Json -InputObject ([ordered]@{ header = $header; warnings = @($warnings); results = @($results) }) -Depth 10 |
        Set-Content -Encoding utf8 (Join-Path $Out 'results.json')
    $md = [System.Collections.Generic.List[string]]::new()
    $md.Add("# AC1 mutation check: $sha (phase $Phase)")
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

function New-Worktree([string]$dir, [switch]$Pub) {
    Remove-Worktree $dir
    git -C $root worktree add --detach $dir $sha 2>&1 | Out-Null
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
    $patch = Join-Path $here $m['patch']
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
    foreach ($l in Get-Content (Join-Path $here $m['patch'])) {
        if ($prev -eq '--- /dev/null' -and $l.StartsWith('+++ b/')) { $made += $l.Substring(6) }
        $prev = $l
    }
    return , $made
}

# the files [m]'s patch changes that exist before it (restored on reset)
function Get-ChangedFiles($m) {
    $made = Get-CreatedFiles $m
    return , @(Get-Content (Join-Path $here $m['patch']) | Where-Object { $_ -match '^diff --git a/(\S+) b/' } |
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

function Remove-Profile([string]$profileName) {
    foreach ($d in (Join-Path $env:APPDATA "com.zxa24\LibrePili\selftest-$profileName"),
        (Join-Path $env:TEMP "LibrePili\selftest-$profileName"),
        (Join-Path $env:TEMP "LibrePili\$profileName")) {
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
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

function Install-Slot([string]$dir) {
    $from = Join-Path $dir 'build\windows\x64\runner\Debug'
    $exe = & pwsh -NoProfile -File $slotScript -Slot $Slot -From $from
    if ($LASTEXITCODE) { throw "test-slot.ps1 failed: $exe" }
    return "$(@($exe)[-1])".Trim()
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
        if (git -C $dir status --porcelain -- lib) { throw "$dir has changes under lib/: not an unmutated tree" }
        if (-not (Test-Path (Join-Path $dir '.dart_tool\package_config.json'))) {
            Push-Location $dir
            try { & $Flutter pub get --offline 2>&1 | Out-Null } finally { Pop-Location }
        }
    }
    $script:stDir = $dir
    # flutter_inappwebview_windows installs NuGet packages at build time:
    # nuget as the main checkout's build found it, and the packages it
    # already has (then nothing is fetched)
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
    $script:built = 'none'
    $script:pendingRescale = [System.Collections.Generic.List[object]]::new()
    try {
        Invoke-SelfTestLoop $list $dir
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

# the trees a baseline's reports depend on: the app's code and the list
# shots' fixtures
function Get-BaselineManifest {
    [ordered]@{
        commit = $sha
        lib = (git -C $root rev-parse "${sha}:lib").Trim()
        fixtures = (git -C $root rev-parse "${sha}:test/fixtures").Trim()
    }
}

# before any mutant: -SelfTestTree must hold -Commit's lib/ and fixtures,
# and a -Baseline must pass and (by its manifest) be of the same trees
function Test-SelfTestInputs($list) {
    if ($SelfTestTree) {
        $tree = (Resolve-Path $SelfTestTree).Path
        $treeSha = (git -C $tree rev-parse HEAD).Trim()
        git -C $root diff --quiet $sha $treeSha -- lib test/fixtures 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 1) { throw "-SelfTestTree $tree is at $treeSha, whose lib/ or test/fixtures/ differ from $sha" }
        if ($LASTEXITCODE) { throw "-SelfTestTree ${tree}: cannot compare its commit $treeSha with $sha (git diff exit $LASTEXITCODE)" }
        if (git -C $tree status --porcelain -- lib test/fixtures) { throw "$tree has changes under lib/ or test/fixtures/: not an unmutated tree" }
        $header.selfTestTree = $treeSha
    }
    if ($Baseline) {
        foreach ($sc in @($list | ForEach-Object { $_['scenario'] } | Select-Object -Unique)) {
            $rep = Join-Path $Baseline "$sc.json"
            $c = Get-Check (Read-Report $rep) $checkNames[$sc]
            if ($null -eq $c -or $c['pass'] -ne $true) { throw "the -Baseline $sc report did not pass ($rep): no mutant can be judged against it" }
        }
        $file = Join-Path $Baseline 'manifest.json'
        if (Test-Path -LiteralPath $file) {
            $have = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
            $want = Get-BaselineManifest
            foreach ($k in 'lib', 'fixtures') {
                if ($have[$k] -ne $want[$k]) { throw "-Baseline $Baseline was taken on $($have['commit']), whose $k tree differs from ${sha}'s" }
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
        ConvertTo-Json -InputObject (Get-BaselineManifest) | Set-Content -Encoding utf8 (Join-Path $base 'manifest.json')
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
# ------------------------------------------------------------------ run
$st = @($todo | Where-Object { $_.Contains('scenario') -and ($SelfTestAll -or -not $_.Contains('test')) })
if ($NoSelfTest) { $st = @() }
if ($st.Count) { Test-SelfTestInputs $st }
"AC1 mutation check: $sha, phase $Phase, $($todo.Count) mutants -> $Out"
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
$sv = @($results | Where-Object { $_.result -ne 'caught' })
"done in $([int]((Get-Date) - $started).TotalMinutes) min: $($results.Count - $sv.Count) caught, $($sv.Count) not ($(($sv | ForEach-Object { "$($_.id) $($_.result)" }) -join ', '))"
if ($script:stopReason) {
    $script:stopReason
    Remove-Worktree (Join-Path $work 'unit')
    Remove-Worktree (Join-Path $work 'selftest')
    exit 3
}
if ($sv.Count) { exit 1 }
