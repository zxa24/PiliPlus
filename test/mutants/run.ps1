# AC1 mutation check (feature-logs/download-platforms design, AC1 「变异检查」).
#
# Each mutant in mutants.json is a small, deliberate regression of the
# bilibili download code; each must make at least one AC1 check fail. The
# patches are only ever applied in throwaway git worktrees under
# _tmp/mutants/, never to the checked-out lib/.
#
#   pwsh -NoProfile -File test/mutants/run.ps1 [-Commit <rev>] [-Phase 0|1a|1b]
#        [-Only M1,M15] [-Slot 1] [-Out <dir>] [-Baseline <dir>] [-NoSelfTest]
#        [-Flutter <flutter.bat>] [-Work <dir>] [-SelfTestAll]
#   pwsh -NoProfile -File test/mutants/run.ps1 -Compare <baseDir>,<otherDir>
#
# Unit / widget mutants (those with a `test`): they share ONE worktree,
# _tmp/mutants/unit/ on -Commit (packages resolved once). Per mutant: `git
# apply` the patch, `flutter test --no-pub --concurrency=1 <its test file>`,
# `git checkout -- .` (and `git clean` of files the patch created); caught =
# a test fails (its name and the first line of the failure are recorded),
# survived = all pass, error = the patch does not apply or the code does not
# compile (a patch bug, not a catch).
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
# list shots pixel by pixel) -> `git checkout -- .`. Caught = the report's
# pass is false or a must-match field differs. Each profile's data is deleted
# after its run; the worktree and its build output at the end.
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
    [string]$Work = ''
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
        Add-Type -ReferencedAssemblies System.Drawing, System.Drawing.Primitives -TypeDefinition @'
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
    if ($n -lt 0) { return 'size differs' }
    return $n
}

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
                if ("$d" -ne '0') { $diffs.Add("shot ${n}: $d differing pixels") }
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

function Save-Results {
    ConvertTo-Json -InputObject @($results) -Depth 10 | Set-Content -Encoding utf8 (Join-Path $Out 'results.json')
    $md = [System.Collections.Generic.List[string]]::new()
    $md.Add("# AC1 mutation check: $sha (phase $Phase)")
    if ($script:stopReason) { $md.Add(''); $md.Add("**$($script:stopReason)**") }
    $md.Add('')
    $md.Add("Started $($started.ToString('s')); $(@($results | Where-Object result -eq 'caught').Count) caught, " +
        "$(@($results | Where-Object result -eq 'survived').Count) survived, " +
        "$(@($results | Where-Object { $_.result -notin 'caught', 'survived' }).Count) other, of $($todo.Count).")
    $md.Add('')
    $md.Add('| id | change | location | expected check | kind | result | caught by | first failure line | s |')
    $md.Add('|---|---|---|---|---|---|---|---|---|')
    $esc = { param($s) ("$s" -replace '\|', '\|' -replace '\r?\n', ' ') }
    foreach ($r in $results) {
        $md.Add("| $($r.id) | $(& $esc $r.change) | $(& $esc $r.location) | $(& $esc $r.expected) | $($r.kind) | **$($r.result)** | $(& $esc $r.by) | $(& $esc $r.first) | $($r.seconds) |")
    }
    $md | Set-Content -Encoding utf8 (Join-Path $Out 'results.md')
}

function Add-Result($m, [string]$result, [string]$by, [string]$first, [datetime]$t0, $extra = $null) {
    $row = [ordered]@{
        id = $m['id']; change = $m['change']; location = $m['location']; expected = $m['catcher']
        kind = $m['kind']; result = $result; by = $by; first = $first
        seconds = [int]((Get-Date) - $t0).TotalSeconds
    }
    if ($extra) { $row['details'] = @($extra) }
    $results.Add([pscustomobject]$row)
    Save-Results
    '{0,-5} {1,-8} {2}' -f $m['id'], $result, $(if ($first) { $first } else { $by })
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

function Set-Mutant([string]$dir, $m) {
    Set-Content (Join-Path $dir 'MUTANT.txt') ("AC1 mutant $($m['id']) is applied here ($($m['patch'])): a run was " +
        "interrupted. Undo it with git -C `"$dir`" checkout -- . , or delete the worktree: " +
        "git worktree remove --force `"$dir`"")
}

function Reset-Mutant([string]$dir, $m) {
    git -C $dir checkout -- . 2>&1 | Out-Null
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
    foreach ($line in @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)) {
        if (-not "$line".StartsWith('{')) { continue }
        try { $e = $line | ConvertFrom-Json -AsHashtable } catch { continue }
        switch ($e['type']) {
            'testStart' { $names[$e['test']['id']] = $e['test']['name'] }
            'print' { $prints[$e['testID']] = "$($prints[$e['testID']])`n$($e['message'])" }
            'error' {
                $n = "$($names[$e['testID']])"
                if ($n -like 'loading *') { if (-not $loadErr) { $loadErr = $e['error'] } }
                elseif (-not $firstErr) { $firstErr = @{ name = $n; error = $e['error']; print = $prints[$e['testID']] } }
            }
            'done' { $done = $e['success'] }
        }
    }
    if ($null -eq $code) {
        return Add-Result $m 'caught' $m['test'] 'the test run did not end within 20 min' $t0
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
        return Add-Result $m 'caught' "$(Split-Path -Leaf $m['test']): $($firstErr.name)" $first $t0
    }
    if ($done -eq $true -and $code -eq 0) { return Add-Result $m 'survived' '' '' $t0 }
    return Add-Result $m 'error' '' "flutter test exit $code without a failing test (see $id.test.jsonl)" $t0
}

function Invoke-UnitMutants($list) {
    $dir = Join-Path $work 'unit'
    New-Worktree $dir
    foreach ($m in $list) {
        if (-not (Wait-Memory $m['id'])) { return }
        $t0 = Get-Date
        Set-Mutant $dir $m
        if (-not (Invoke-Patch $dir $m)) {
            Add-Result $m 'error' '' 'the patch does not apply' $t0
            Reset-Mutant $dir $m
            continue
        }
        try { Invoke-UnitTest $dir $m $t0 } finally { Reset-Mutant $dir $m }
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
    $profileName = "mut-$tag-$scenario-$(Get-Random -Maximum 99999)"
    $fixtures = Join-Path $script:stDir 'test\fixtures\download_list'
    $argv = @('--selftest', '--profile', $profileName, '--out', $report) + $(switch ($scenario) {
            'download' { @('--download', $bvDownload, '--dl-transcribe', 'off') }
            'queue99' { @('--download-queue', $bvA, $bvB, '--damage-times', '99', '--shots', $shots, '--dl-transcribe', 'off') }
            'transcribe' { @('--download-transcribe', $bvT) }
            'listshots' { @('--download-list-shots', $fixtures, '--shots', $shots, '--dl-transcribe', 'off') }
        })
    $argv = @($argv | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } })
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
    $script:stDir = Join-Path $work 'selftest'
    $dir = $script:stDir
    New-Worktree $dir -Pub
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
    if (Test-Path $packages) {
        $to = Join-Path $dir 'build\windows\x64'
        New-Item -ItemType Directory -Force $to | Out-Null
        Copy-Item -Recurse $packages $to
    }
    $scenarios = @($list | ForEach-Object { $_['scenario'] } | Select-Object -Unique)
    $base = $Baseline
    if (-not $base) {
        $base = Join-Path $Out 'baseline'
        if (-not (Wait-Memory 'the baseline build')) { return }
        $t0 = Get-Date
        if (-not (Invoke-Build $dir (Join-Path $Out 'baseline.build.log'))) { throw 'the unmutated build failed (baseline.build.log)' }
        "baseline build: $([int]((Get-Date) - $t0).TotalSeconds) s"
        $exe = Install-Slot $dir
        foreach ($sc in $scenarios) {
            $rep = Invoke-SelfTest $exe $sc $base 'base'
            $c = Get-Check (Read-Report $rep) $checkNames[$sc]
            $ok = $null -ne $c -and $c['pass'] -eq $true
            "baseline $sc pass=$ok"
            if (-not $ok) { throw "the baseline $sc self test did not pass ($rep): no mutant can be judged against it" }
        }
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
            if (-not (Invoke-Build $dir (Join-Path $Out "$id.build.log"))) {
                Add-Result $m 'error' '' "the build failed (see $id.build.log)" $t0
                continue
            }
            $exe = Install-Slot $dir
            $sc = $m['scenario']
            $rep = Invoke-SelfTest $exe $sc (Join-Path $Out $id) $id
            $diffs = Compare-Scenario $sc (Join-Path $base "$sc.json") $rep
            if ($diffs.Count) {
                Add-Result $m 'caught' "$($sc): $(($diffs[0] -split ':')[0])" $diffs[0] $t0 $diffs
            } else {
                Add-Result $m 'survived' '' '' $t0
            }
        } finally {
            Reset-Mutant $dir $m0
        }
    }
    Remove-Worktree $dir
}

# ------------------------------------------------------------------ run
"AC1 mutation check: $sha, phase $Phase, $($todo.Count) mutants -> $Out"
$tUnit = Get-Date
$unit = @($todo | Where-Object { $_.Contains('test') })
if ($unit.Count) {
    Invoke-UnitMutants $unit
    "unit part: $($unit.Count) mutants, $([int]((Get-Date) - $tUnit).TotalMinutes) min"
}
$st = @($todo | Where-Object { $_.Contains('scenario') -and ($SelfTestAll -or -not $_.Contains('test')) })
if ($NoSelfTest) { $st = @() }
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
