# Offline self-test of run.ps1's download-plan id checks (stage-2 plan
# feature-logs/download-platforms/phase2-plan.md §6.3; the review of 2a,
# audit-logs/dlplat-impl2/2a-review-*.md: "the counts can pass with a
# mutant missing").
#
#   pwsh -NoProfile -File test/mutants/dl_plan_selftest.ps1 [-Runner <run.ps1>]
#
# Builds and runs nothing: it dot-sources run.ps1 with -LoadOnly and calls
# Test-DownloadManifest / Test-DownloadPhase2 / Test-DownloadUnion on the
# repository's mutants.json and on copies of it changed one way each, and
# on synthetic result folders under _tmp\dl-plan-selftest\ (deleted after).
# Exit 0 when every case passes, 1 otherwise.
param([string]$Runner = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here = $PSScriptRoot
$runner = if ($Runner) { (Resolve-Path -LiteralPath $Runner).Path } else { Join-Path $here 'run.ps1' }
$repo = (git -C $here rev-parse --show-toplevel).Trim() -replace '/', '\'
$scratch = Join-Path $repo '_tmp\dl-plan-selftest'
$manifest = Join-Path $here 'mutants.json'

$results = [System.Collections.Generic.List[object]]::new()
function Check([string]$case, [bool]$ok, [string]$detail = '') {
    $results.Add([pscustomobject]@{ case = $case; ok = $ok })
    '{0} {1}{2}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $case, $(if ($detail) { " - $detail" })
}
# runs [block]; the case passes when it throws (and the message matches)
function Throws([string]$case, [scriptblock]$block, [string]$match) {
    try { & $block; Check $case $false 'did not throw' }
    catch { Check $case ("$($_.Exception.Message)" -match $match) "$($_.Exception.Message)" }
}
function Load { , @(Get-Content -Raw $manifest | ConvertFrom-Json -AsHashtable) }
function Picked($all) { , @($all | Where-Object { $script:dlPhases -contains $_['phase'] }) }
function Without($all, [string]$id) { , @($all | Where-Object { $_['id'] -ne $id }) }
function Entry([string]$id, [string]$phase) { [ordered]@{ id = $id; patch = "$id.patch"; phase = $phase } }

. $runner -LoadOnly

# ---------------------------------------------------------------- the manifest
$all = Load
try { Test-DownloadManifest $all; Check 'the repository manifest: ids unique, phases known' $true }
catch { Check 'the repository manifest: ids unique, phases known' $false "$($_.Exception.Message)" }
try { Test-DownloadPhase2 $all (Picked $all); Check 'the repository manifest: exactly the -Phase 2 ids' $true }
catch { Check 'the repository manifest: exactly the -Phase 2 ids' $false "$($_.Exception.Message)" }

Throws 'an id twice' { $a = Load; $a += Entry 'M2' 'both'; Test-DownloadManifest $a } 'M2 is there twice'
Throws 'a phase no one knows (a typo)' { $a = Load; $a += Entry 'P2-ZZ' '2only'; Test-DownloadManifest $a } "phase '2only'"
Throws 'a stage-1 mutant swapped for another of its phase (the counts stay)' {
    $a = Without (Load) 'M1'; $a += Entry 'M99' 'both'; Test-DownloadPhase2 $a (Picked $a)
} 'stage-1 M1 is not in mutants.json'
Throws 'a stage-1 mutant whose phase changed' {
    $a = Load; ($a | Where-Object { $_['id'] -eq 'M56' })['phase'] = 'both'; Test-DownloadPhase2 $a (Picked $a)
} 'M56 has phase both'
$last = @($script:dlStage2.Values)[-1][-1]
Throws "a stage-2 mutant a commit lists, missing ($last)" {
    $a = Without (Load) $last; Test-DownloadPhase2 $a (Picked $a)
} "$last is not in mutants.json"
Throws 'a stage-2 mutant no commit lists' {
    $a = Load; $a += Entry 'P2-ZZ' '2-only'; Test-DownloadPhase2 $a (Picked $a)
} 'picked P2-ZZ, which no commit lists'
Throws 'a mutant left out of what was picked' {
    $a = Load; Test-DownloadPhase2 $a (Without (Picked $a) 'M57a')
} 'did not pick M57a'

# ---------------------------------------------------------------- -Union
if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
function Folder([string]$name, [string[]]$ids, [string]$commit = 'abc', [string]$phase = '2', [string]$result = 'caught') {
    $d = Join-Path $scratch $name
    New-Item -ItemType Directory -Force $d | Out-Null
    $doc = [ordered]@{
        header = [ordered]@{ commit = $commit; phase = $phase }
        warnings = @()
        results = @($ids | ForEach-Object { [ordered]@{ id = $_; result = $result } })
    }
    ConvertTo-Json -InputObject $doc -Depth 5 | Set-Content -LiteralPath (Join-Path $d 'results.json') -Encoding utf8
    return $d
}
$ids = [string[]](Get-DownloadPhase2Ids)
$first = Folder 'u1' $ids[0..4]
$rest = Folder 'u2' $ids[5..($ids.Count - 1)]
try {
    $u = Test-DownloadUnion @($first, $rest)
    Check 'two folders that cover every id' ($u.covered -eq $ids.Count -and $u.caught -eq $ids.Count -and $u.missing.Count -eq 0)
} catch { Check 'two folders that cover every id' $false "$($_.Exception.Message)" }
$short = Folder 'u3' $ids[5..($ids.Count - 2)]
Throws 'two folders, one id in neither' { Test-DownloadUnion @($first, $short) } "missing $([regex]::Escape($ids[-1]))"
$otherCommit = Folder 'u4' $ids[5..($ids.Count - 1)] 'def'
Throws 'folders of two commits' { Test-DownloadUnion @($first, $otherCommit) } 'of 2 commits'
$phase1 = Folder 'u5' $ids[5..($ids.Count - 1)] 'abc' '1a'
Throws 'a folder of another phase' { Test-DownloadUnion @($first, $phase1) } 'is a -Phase 1a run'
$again = Folder 'u6' @($ids[0]) 'abc' '2' 'survived'
try {
    $u = Test-DownloadUnion @($first, $rest, $again)
    Check 'an id run twice: listed, the later folder counts' ($u.twice -contains $ids[0] -and $u.notCaught -contains $ids[0])
} catch { Check 'an id run twice: listed, the later folder counts' $false "$($_.Exception.Message)" }
Remove-Item -LiteralPath $scratch -Recurse -Force

$failed = @($results | Where-Object { -not $_.ok })
"$($results.Count - $failed.Count) of $($results.Count) cases pass"
exit $(if ($failed.Count) { 1 } else { 0 })
