# Offline self-test of run.ps1's watch_page comparison (design feature-logs/
# watch-page-shell/design.md §5 「AC-S1 的比较」, the seven 离线自检 ①-⑦,
# required by AC-S0 before -Compare judges anything).
#
#   pwsh -NoProfile -File test/mutants/wp_compare_selftest.ps1 [-Keep]
#        [-Runner <run.ps1>]
#
# -Runner: judge another copy of run.ps1 (default: the one beside this
# script). Running the cases against the runner from before a fix shows
# which of them that fix makes pass (each review-fix case is tagged with
# the finding's id, e.g. [cx1 cl2], audit-logs/wps-s0b/c1-review-*.md).
#
# Builds nothing and launches nothing: it writes small synthetic report
# folders (manifest.json + pass1\ ... with one report each) under
# _tmp\wp-compare-selftest\, runs `run.ps1 -Plan watch_page -Compare` on
# them with hand-written field tables (-FieldTables) and origin maps
# (-OriginMap), and asserts each verdict in compare.json. The two commits
# are real ones of this repository, a parent and its child (S0a: c69e319c8
# -> 3aa48432e), because the origin rules read `git diff -U0` between them;
# the line numbers below are lines that diff does / does not touch (each
# is checked against git first). The fake worktree roots C:/fake/wpA and
# C:/fake/wpB are equally long, as -Alternate's are.
#
# Beyond the design's seven: calibration mode, the two refusals, today's
# string uiErrors (root stripped, line moved through the diff), the
# precondition rerun, the -Alternate dry run (order, batch switch, nothing
# written), shot fields, -CheckTestSide, and the mutant judge (dot-sourced
# with -LoadOnly: the same Compare-WpMutant the mutant loop calls).
#
# Exit 0 when every case passes (the scratch folder is then deleted unless
# -Keep), 1 otherwise (the scratch folder is kept for a look).
param([switch]$Keep, [string]$Runner = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
# the verdicts are Chinese (the design's words): print them as UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$here = $PSScriptRoot
$runner = if ($Runner) { (Resolve-Path -LiteralPath $Runner).Path } else { Join-Path $here 'run.ps1' }
$root = (git -C $here rev-parse --show-toplevel).Trim() -replace '/', '\'
$P = 'c69e319c8ccc67f34700e49491cbefa789f55e68'
$C = '3aa48432e2c443433a63dd053e0f4a7c46bce1f3'
$GP = (git -C $root rev-parse "$P^").Trim()
$rootA = 'C:/fake/wpA'; $rootB = 'C:/fake/wpB'
$scratch = Join-Path $root '_tmp\wp-compare-selftest'

$results = [System.Collections.Generic.List[object]]::new()
function Check([string]$case, [bool]$ok, [string]$detail) {
    $results.Add([pscustomobject]@{ case = $case; ok = $ok; detail = $detail })
    '{0} {1}{2}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $case, $(if ($detail) { " — $detail" })
}

# ---------------------------------------------------------------- preconditions on the repository
# (not $c: PowerShell names are case-insensitive, $c is $C)
foreach ($commit in $P, $C) {
    git -C $root cat-file -e "$commit^{commit}" 2>$null
    if ($LASTEXITCODE) { throw "commit $commit is not in this repository: the self-test needs it" }
}
if (@("$(git -C $root rev-list --parents -n 1 $C)" -split ' ') -notcontains $P) { throw "$P is not the parent of $C" }
$changed = @(git -C $root diff --name-only --no-renames $P $C)
foreach ($f in 'lib/common/widgets/video_card/video_card_h.dart', 'lib/pages/home/view.dart') {
    if ($changed -contains $f) { throw "$f changed between $P and ${C}: cases ① and ⑦ need two unchanged files" }
}
$mainHunks = (git -C $root diff -U0 $P $C -- lib/main.dart) -join "`n"
$ctlHunks = (git -C $root diff -U0 $P $C -- lib/pages/video/controller.dart) -join "`n"
if ($mainHunks -notmatch '@@ -337 \+361 @@') { throw 'lib/main.dart: the hunk -337 +361 the cases use is not in the diff' }
if ($ctlHunks -notmatch '@@ -2995,0 \+2997,8 @@') { throw 'lib/pages/video/controller.dart: the hunk +2997,8 the cases use is not in the diff' }
# lib/main.dart:300 is outside the changed blocks; the hunks before it add
# 1 + 21 + 2 lines, so it is line 324 in the child
foreach ($h in '@@ -49,0 +50 @@', '@@ -157,0 +159,21 @@', '@@ -202,0 +225,2 @@') {
    if (-not $mainHunks.Contains($h)) { throw "lib/main.dart: hunk $h not in the diff" }
}

if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
New-Item -ItemType Directory -Force $scratch | Out-Null

function Get-Trees([string]$sha) {
    [ordered]@{
        lib = (git -C $root rev-parse "${sha}:lib").Trim()
        fixtures = (git -C $root rev-parse "${sha}:test/fixtures").Trim()
        windowsRunner = (git -C $root rev-parse "${sha}:windows/runner").Trim()
    }
}

function Write-Json($obj, [string]$file) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $file) | Out-Null
    ConvertTo-Json -InputObject $obj -Depth 30 | Set-Content -Encoding utf8 -LiteralPath $file
}

# a field table in its own folder; $over replaces top-level keys
function New-Table([string]$dir, [string]$id, $fields, [hashtable]$over = @{}) {
    $t = [ordered]@{
        id = $id; check = 'wpDemo'; report = 'wpDemo.json'; type = 'recording'; batch = $null; network = $false
        run = [ordered]@{ args = @('--wp-demo', '${OUT}'); planPrefs = $false; profile = 'fresh' }
        measured = 'measured'; fields = $fields; uiErrors = [ordered]@{ status = 'must-same' }; evidence = $null
    }
    foreach ($k in $over.Keys) { $t[$k] = $over[$k] }
    Write-Json $t (Join-Path $dir "$id.json")
}

function F([string]$name, [string]$status = 'must-same', [string]$path = '') {
    [ordered]@{ name = $name; path = $(if ($path) { $path } else { $name }); status = $status }
}

# a check object: measured, branch, noise, uiErrors (always written from
# S0b on; an empty list = no errors) (+ $extra)
function Chk([hashtable]$extra = @{}) {
    $c = [ordered]@{ name = 'wpDemo'; pass = $true; measured = $true; branch = 'landscape'; idx = 1; noise = (Get-Random); uiErrors = @() }
    foreach ($k in $extra.Keys) { $c[$k] = $extra[$k] }
    return $c
}

# one report folder: manifest + one pass per item ($null item = no report;
# 'nocheck' = a report without the check)
function New-Side([string]$dir, [string]$sha, [string]$wtRoot, [object[]]$checks, [int]$firstPass = 1) {
    $m = [ordered]@{ plan = 'watch_page'; commit = $sha }
    $tr = Get-Trees $sha
    foreach ($k in $tr.Keys) { $m[$k] = $tr[$k] }
    $m['root'] = $wtRoot -replace '/', '\'
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'manifest.json'))) { Write-Json $m (Join-Path $dir 'manifest.json') }
    $n = $firstPass
    foreach ($c in $checks) {
        $pd = Join-Path $dir "pass$n"
        New-Item -ItemType Directory -Force $pd | Out-Null
        if ($c -is [string] -and $c -eq 'nocheck') { Write-Json ([ordered]@{ checks = @([ordered]@{ name = 'other'; pass = $true }) }) (Join-Path $pd 'wpDemo.json') }
        elseif ($null -ne $c) { Write-Json ([ordered]@{ checks = @($c); display = [ordered]@{ resolution = '3840x2160'; dpi = 120 } }) (Join-Path $pd 'wpDemo.json') }
        $n++
    }
}

# run.ps1 -Compare; -> @{ code; out; json }
function Invoke-Compare([string[]]$dirs, [string]$tables, [string]$map = '', [string[]]$more = @()) {
    $out = Join-Path (Split-Path -Parent $dirs[0]) ("out-" + (Get-Random))
    $argv = @('-NoProfile', '-File', $runner, '-Plan', 'watch_page', '-Compare', ($dirs -join ','), '-FieldTables', $tables, '-Out', $out) + $more
    if ($map) { $argv += @('-OriginMap', $map) }
    $text = & pwsh @argv 2>&1 | Out-String
    $code = $LASTEXITCODE
    $json = if (Test-Path (Join-Path $out 'compare.json')) { Get-Content -Raw (Join-Path $out 'compare.json') | ConvertFrom-Json -AsHashtable } else { $null }
    return @{ code = $code; out = $text; json = $json; outDir = $out }
}

# an error message as one line: the console wraps a thrown error's text and
# colours it, so a phrase can be split over two lines
function Flat([string]$text) { (($text -replace "$([char]27)\[[0-9;]*m", '') -replace '[\s|]+', ' ') }

function Row($r, [string]$id) { @($r.json['rows'] | Where-Object { $_['id'] -eq $id })[0] }
function Fld($row, [string]$name) { @($row['fields'] | Where-Object { $_['name'] -eq $name })[0] }
# (the comma: one match must stay a list, not unroll into the hashtable)
function UiF($row, [string]$like) { , @($row['fields'] | Where-Object { $_['name'] -like "uiErrorKeys*$like*" }) }

# a pair of folders for one case: <case>\parent and <case>\new
function New-Case([string]$name) {
    $d = Join-Path $scratch $name
    New-Item -ItemType Directory -Force (Join-Path $d 'tables') | Out-Null
    return @{ dir = $d; tables = (Join-Path $d 'tables'); parent = (Join-Path $d 'parent'); new = (Join-Path $d 'new') }
}

function Ov($kind, $widget, $origin) { [ordered]@{ text = "$kind."; kind = $kind; widget = $widget; origin = $origin; context = 'during layout'; frames = @() } }
$rf = 'A RenderFlex overflowed by 13 pixels on the right'

# ================================================================ design ①
# same kind and widget type, origins in two different files the step did
# not change -> 不同 (4 reports a side: with 2, ⑤ says 需补跑)
$k = New-Case 'd1'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P $rootA @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/common/widgets/video_card/video_card_h.dart:132')) } })
New-Side $k.new $C $rootB @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/pages/home/view.dart:132')) } })
$r = Invoke-Compare @($k.parent, $k.new) $k.tables
$row = Row $r 'wpDemo'
$ui = UiF $row 'video_card_h.dart:132'
Check '① two unchanged files, same kind / widget -> 不同' ($row['verdict'] -eq 'different' -and $ui.Count -eq 1 -and $ui[0]['verdict'] -eq 'different') "row $($row['label']); $($ui | ForEach-Object { "$($_['name']) $($_['label'])" })"

# ================================================================ design ② ③
# a hand-written map moves the origin from lib/main.dart:337 (a parent-side
# changed block) to lib/pages/video/controller.dart:2997 (a child-side
# added block) -> 相同; the same pair without the map -> 无法比较
$k = New-Case 'd2'
New-Table $k.tables 'wpDemo' @((F 'branch'))
$map = Join-Path $k.dir 'map.json'
Write-Json ([ordered]@{ rows = @([ordered]@{ id = 'moved-1'; parent = [ordered]@{ file = 'lib/main.dart'; start = 337; end = 337 }; child = [ordered]@{ file = 'lib/pages/video/controller.dart'; start = 2997; end = 2997 }; sameLength = $true }) }) $map
New-Side $k.parent $P $rootA @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/main.dart:337')) } })
New-Side $k.new $C $rootB @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/pages/video/controller.dart:2997')) } })
$r = Invoke-Compare @($k.parent, $k.new) $k.tables $map
$row = Row $r 'wpDemo'
$ui = UiF $row 'M:moved-1+0'
Check '② origin moved by the map -> 相同' ($row['verdict'] -eq 'same' -and $ui.Count -eq 1 -and $ui[0]['verdict'] -eq 'same') "row $($row['label']); $(@($row['fields'] | ForEach-Object { "$($_['name']) $($_['label'])" }) -join '; ')"
$empty = Join-Path $k.dir 'empty-map.json'
Write-Json ([ordered]@{ rows = @() }) $empty
$r = Invoke-Compare @($k.parent, $k.new) $k.tables $empty
$row = Row $r 'wpDemo'
Check '③ the same pair without a map row -> 无法比较' ($row['verdict'] -eq 'notComparable' -and @($row['notComparable']).Count -ge 2) "row $($row['label']); $(@($row['notComparable'])[0])"

# ================================================================ design ④
$k = New-Case 'd4a'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P $rootA @((Chk), (Chk))
New-Side $k.new $C $rootB @((Chk), 'nocheck')
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check '④ one side lacks the check -> 无结果' ($row['verdict'] -eq 'noResult') "$($row['label']): $(@($row['reasons']) -join '; ')"
$k = New-Case 'd4b'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P $rootA @((Chk @{ measured = $false }), (Chk))
New-Side $k.new $C $rootB @((Chk), (Chk))
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check '④ one side measured: false -> 无结果' ($row['verdict'] -eq 'noResult') "$($row['label']): $(@($row['reasons']) -join '; ')"

# ================================================================ design ⑤
function Five([string]$case, [object[]]$pb, [object[]]$nb) {
    $k = New-Case $case
    New-Table $k.tables 'wpDemo' @((F 'branch'), (F 'noise' 'unstable'))
    New-Side $k.parent $P $rootA @($pb | ForEach-Object { Chk @{ branch = $_ } })
    New-Side $k.new $C $rootB @($nb | ForEach-Object { Chk @{ branch = $_ } })
    $row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
    return @{ k = $k; row = $row; f = (Fld $row 'branch') }
}
$x = Five 'd5a' @('a', 'a') @('b', 'b')
Check '⑤ 2 a side, each constant, differ -> 需补跑' ($x.row['verdict'] -eq 'rerun' -and $x.f['verdict'] -eq 'rerun' -and $null -ne $x.row['rerun']) "$($x.row['label']), branch $($x.f['label']), rerun +$($x.row['rerun']['add'])"
$x = Five 'd5b' @('a', 'a', 'a', 'a') @('b', 'b', 'b', 'b')
Check '⑤ 4 a side, each constant, differ -> 不同' ($x.row['verdict'] -eq 'different' -and $x.f['verdict'] -eq 'different') "$($x.row['label']), branch $($x.f['label'])"
$x = Five 'd5c' @('a', 'a') @('a', 'b')
Check '⑤ 2 a side, parent constant, new two values -> 需补跑 (not 不同)' ($x.row['verdict'] -eq 'rerun' -and $x.f['verdict'] -eq 'rerun') "$($x.row['label']), branch $($x.f['label'])"
# the 2 -> 4 path of ④: two more passes on each side of the same folders
New-Side $x.k.parent $P $rootA @((Chk @{ branch = 'a' }), (Chk @{ branch = 'a' })) 3
New-Side $x.k.new $C $rootB @((Chk @{ branch = 'b' }), (Chk @{ branch = 'a' })) 3
$row = Row (Invoke-Compare @($x.k.parent, $x.k.new) $x.k.tables) 'wpDemo'
$f = Fld $row 'branch'
Check '④ 2 -> 4: parent still constant, new still two values -> 不同（仅本步不稳）' ($f['verdict'] -eq 'differentNew' -and $row['verdict'] -eq 'different' -and @($row['downgraded']).Count -eq 0) "$($row['label']), branch $($f['label'])"
$y = Five 'd5e' @('a', 'a') @('a', 'b')
New-Side $y.k.parent $P $rootA @((Chk @{ branch = 'c' }), (Chk @{ branch = 'a' })) 3
New-Side $y.k.new $C $rootB @((Chk @{ branch = 'b' }), (Chk @{ branch = 'a' })) 3
$row = Row (Invoke-Compare @($y.k.parent, $y.k.new) $y.k.tables) 'wpDemo'
$f = Fld $row 'branch'
Check '④ 2 -> 4: the parent shows a second value -> 不稳定, in 降级' ($f['verdict'] -eq 'unstable' -and @($row['downgraded'] | Where-Object { $_['field'] -eq 'branch' }).Count -eq 1 -and $row['verdict'] -eq 'same') "$($row['label']), branch $($f['label']), 降级 $(@($row['downgraded']).Count)"
$x = Five 'd5f' @('a', 'b', 'a', 'a') @('a', 'a', 'a', 'a')
Check '⑤ parent 4 with two values -> 不稳定, in 降级' ($x.f['verdict'] -eq 'unstable' -and @($x.row['downgraded'] | Where-Object { $_['field'] -eq 'branch' }).Count -eq 1) "$($x.row['label']), branch $($x.f['label'])"
$x = Five 'd5g' @('a', 'a', 'a', 'a') @('a', 'a', 'a', 'a')
$fn = Fld $x.row 'noise'
Check '⑤ a field the table marks unstable differs -> not 不同, not in 降级' ($x.row['verdict'] -eq 'same' -and $fn['verdict'] -eq 'tableUnstable' -and @($x.row['downgraded']).Count -eq 0) "$($x.row['label']), noise $($fn['label'])"

# ================================================================ design ⑥
$k = New-Case 'd6a'
New-Table $k.tables 'wpDemo' @((F 'branch'), (F 'gone'))
New-Side $k.parent $P $rootA @((Chk), (Chk))
New-Side $k.new $C $rootB @((Chk), (Chk))
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check '⑥ a must-same key missing on both sides -> 无结果 (not 相同)' ($row['verdict'] -eq 'noResult' -and (Fld $row 'gone')['verdict'] -eq 'noResult') "$($row['label']), gone $((Fld $row 'gone')['label'])"
$k = New-Case 'd6b'
New-Table $k.tables 'wpDemo' @((F 'branch'), (F 'rect'))
New-Side $k.parent $P $rootA @((Chk @{ rect = @(0, 0, 10, 10) }), (Chk @{ rect = @(0, 0, 10, 10) }))
New-Side $k.new $C $rootB @((Chk @{ rect = [ordered]@{ '$unread' = 'pageRoute' } }), (Chk @{ rect = @(0, 0, 10, 10) }))
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check '⑥ one side {"$unread": …} -> 无结果' ($row['verdict'] -eq 'noResult' -and (Fld $row 'rect')['verdict'] -eq 'noResult') "$($row['label']), rect $((Fld $row 'rect')['label']): $((Fld $row 'rect')['note'])"

# ================================================================ design ⑦
function NoOrigin($frame) { [ordered]@{ text = 'Null check operator used on a null value'; kind = 'Null check operator used on a null value'; widget = ''; origin = $null; context = 'while dispatching notifications for ScrollController'; frames = @($frame) } }
$k = New-Case 'd7a'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P $rootA @(1..4 | ForEach-Object { Chk @{ uiErrors = @((NoOrigin '#0 _State.build (package:PiliPlus/pages/home/view.dart:40:7)')) } })
New-Side $k.new $C $rootB @(1..4 | ForEach-Object { Chk @{ uiErrors = @((NoOrigin '#0 _State.build (package:PiliPlus/pages/home/view.dart:40:7)')) } })
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
$ui = UiF $row 'home/view.dart:40'
Check '⑦ no origin, same kind / context / first app frame -> 相同, weak' ($row['verdict'] -eq 'same' -and $ui.Count -eq 1 -and $ui[0]['verdict'] -eq 'same' -and $ui[0]['note'] -eq 'weak') "row $($row['label']); $(@($ui | ForEach-Object { "$($_['name']) $($_['label']) $($_['note'])" }))"
$k = New-Case 'd7b'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P $rootA @(1..4 | ForEach-Object { Chk @{ uiErrors = @((NoOrigin '#0 _State.build (package:PiliPlus/pages/home/view.dart:40:7)')) } })
New-Side $k.new $C $rootB @(1..4 | ForEach-Object { Chk @{ uiErrors = @((NoOrigin '#0 _State.build (package:PiliPlus/common/widgets/video_card/video_card_h.dart:40:7)')) } })
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check '⑦ no origin, first app frames in two unchanged files -> 不同' ($row['verdict'] -eq 'different') "row $($row['label'])"

# ================================================================ beyond the seven
# today's string entries (AC-S0a): the absolute file:/// path under each
# folder's own root, lib/main.dart:300 (parent) = :324 (child)
function Today([string]$rootPath, [int]$line) {
    "══╡ EXCEPTION CAUGHT BY RENDERING LIBRARY ╞═══ The following assertion was thrown during layout: A RenderFlex overflowed by 6.4 pixels on the right. The relevant error-causing widget was: Row Row:file:///$rootPath/lib/main.dart:${line}:11 @ during layout :: Consider applying a flex factor (e.g. using an Expanded widget) ## package:PiliPlus/main.dart 12:3"
}
$k = New-Case 'x-today'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P $rootA @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Today $rootA 300)) } })
New-Side $k.new $C $rootB @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Today $rootB 324)) } })
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
$ui = UiF $row 'main.dart:324'
Check 'today''s string uiErrors: root stripped, line moved through git diff -> 相同' ($row['verdict'] -eq 'same' -and $ui.Count -eq 1 -and $ui[0]['name'] -like '*A RenderFlex overflowed by pixels on the right | Row | F:lib/main.dart:324*') "$($row['label']); $(@($ui | ForEach-Object { $_['name'] }))"
$k2 = New-Case 'x-today-off'
New-Table $k2.tables 'wpDemo' @((F 'branch'))
New-Side $k2.parent $P $rootA @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Today $rootA 300)) } })
New-Side $k2.new $C $rootB @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Today $rootB 325)) } })
$row = Row (Invoke-Compare @($k2.parent, $k2.new) $k2.tables) 'wpDemo'
Check 'today''s string uiErrors one line off -> 不同' ($row['verdict'] -eq 'different') "$($row['label'])"
$k3 = New-Case 'x-today-block'
New-Table $k3.tables 'wpDemo' @((F 'branch'))
New-Side $k3.parent $P $rootA @((Chk @{ uiErrors = @((Today $rootA 337)) }), (Chk @{ uiErrors = @((Today $rootA 337)) }))
New-Side $k3.new $C $rootB @((Chk @{ uiErrors = @((Today $rootB 361)) }), (Chk @{ uiErrors = @((Today $rootB 361)) }))
$row = Row (Invoke-Compare @($k3.parent, $k3.new) $k3.tables $empty) 'wpDemo'
Check 'today''s string uiErrors in a changed block, no map -> 无法比较 (AC-S0a)' ($row['verdict'] -eq 'notComparable') "$($row['label'])"

# the precondition (--open-bili's played: true): one spoiled pass on the
# parent side -> 需补跑 on that commit only
$k = New-Case 'x-pre'
New-Table $k.tables 'wpDemo' @((F 'branch')) @{ preconditions = @([ordered]@{ path = 'played'; equals = $true; extraRuns = 2 }) }
New-Side $k.parent $P $rootA @((Chk @{ played = $true }), (Chk @{ played = $false }))
New-Side $k.new $C $rootB @((Chk @{ played = $true }), (Chk @{ played = $true }))
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check 'precondition failed once -> 需补跑 on the same commit, that side' ($row['verdict'] -eq 'rerun' -and $row['rerun']['kind'] -eq 'same-commit' -and $row['rerun']['side'] -eq 'parent') "$($row['label']); $($row['rerun']['command'])"
New-Side $k.parent $P $rootA @((Chk @{ played = $false }), (Chk @{ played = $false })) 3
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check 'precondition failed 3 times (2 reruns allowed) -> 无结果' ($row['verdict'] -eq 'noResult') "$($row['label'])"

# calibration: two folders of the same commit; noise varies, branch does not
$k = New-Case 'x-cal'
New-Table $k.tables 'wpDemo' @((F 'branch'), (F 'noise' 'unstable'))
New-Side (Join-Path $k.dir 'a') $C $rootA @((Chk), (Chk))
New-Side (Join-Path $k.dir 'b') $C $rootA @((Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/pages/home/view.dart:9')) }))
$r = Invoke-Compare @((Join-Path $k.dir 'a'), (Join-Path $k.dir 'b')) $k.tables
$cal = @($r.json['checks'])[0]
$sug = @(Get-Item -LiteralPath (Join-Path $r.outDir 'suggested-fields\wpDemo@wpDemo.json') -ErrorAction SilentlyContinue)
Check 'calibration (same commit): lists the varying fields and uiErrorKeys, judges nothing' ($r.json['mode'] -eq 'calibration' -and @($cal['varying'] | ForEach-Object { $_['path'] }) -contains 'noise' -and @($cal['varying'] | ForEach-Object { $_['path'] }) -notcontains 'branch' -and @($cal['uiErrorKeysVarying']).Count -eq 1 -and -not $r.json.Contains('rows') -and $sug.Count -eq 1) "varying $(@($cal['varying'] | ForEach-Object { $_['path'] }) -join ', '); uiErrorKeys $(@($cal['uiErrorKeysVarying']).Count); suggested table $($sug.Count)"

# refusals
$k = New-Case 'x-refuse'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P $rootA @((Chk), (Chk))
New-Item -ItemType Directory -Force (Join-Path $k.dir 'bare\pass1') | Out-Null
Write-Json ([ordered]@{ checks = @((Chk)) }) (Join-Path $k.dir 'bare\pass1\wpDemo.json')
$r = Invoke-Compare @($k.parent, (Join-Path $k.dir 'bare')) $k.tables
Check 'a folder without manifest.json is refused' ($r.code -ne 0 -and $r.out -match 'no manifest\.json' -and $null -eq $r.json) ($r.out.Trim() -split "`n" | Select-Object -Last 1)
New-Side (Join-Path $k.dir 'grand') $GP $rootB @((Chk), (Chk))
New-Side (Join-Path $k.dir 'child') $C $rootB @((Chk), (Chk))
$r = Invoke-Compare @((Join-Path $k.dir 'grand'), (Join-Path $k.dir 'child')) $k.tables
Check 'a grandparent and a child (not parent / child) are refused' ($r.code -ne 0 -and $r.out -match 'neither the same commit nor a parent' -and $null -eq $r.json) ($r.out.Trim() -split "`n" | Select-Object -Last 1)

# shot fields: two tiny PNGs the same, then one pixel different
Add-Type -AssemblyName System.Drawing
function Png([string]$file, [int]$px) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $file) | Out-Null
    $b = [System.Drawing.Bitmap]::new(4, 4)
    try {
        for ($i = 0; $i -lt 16; $i++) { $b.SetPixel($i % 4, [int][Math]::Floor($i / 4), $(if ($i -lt $px) { [System.Drawing.Color]::Red } else { [System.Drawing.Color]::White })) }
        $b.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $b.Dispose() }
}
$k = New-Case 'x-shot'
New-Table $k.tables 'wpDemo' @((F 'branch'), ([ordered]@{ name = 'shot'; path = 'shots'; status = 'must-same'; type = 'shot'; tolerance = 0 }))
New-Side $k.parent $P $rootA @(1..4 | ForEach-Object { Chk @{ shots = @('C:/elsewhere/a.png') } })
New-Side $k.new $C $rootB @(1..4 | ForEach-Object { Chk @{ shots = @('C:/elsewhere/a.png') } })
foreach ($s in $k.parent, $k.new) { 1..4 | ForEach-Object { Png (Join-Path $s "pass$_\wpDemo_shots\a.png") 2 } }
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
$same = (Fld $row 'shot')['verdict']
1..4 | ForEach-Object { Png (Join-Path $k.new "pass$_\wpDemo_shots\a.png") 3 }
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
$diff = (Fld $row 'shot')['verdict']
Check 'shot field: equal images -> 相同, one pixel more (tolerance 0) -> 不同 (found beside the moved report)' ($same -eq 'same' -and $diff -eq 'different') "$same / $diff"

# -Alternate -DryRun: order parent, new, parent, new; the batch switch;
# nothing written
$k = New-Case 'x-dry'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Table $k.tables 'wpFull' @((F 'branch')) @{ batch = 'fullscreen'; check = 'wpFull'; report = 'wpFull.json' }
$work = Join-Path $k.dir 'work'; $dout = Join-Path $k.dir 'out'
$text = & pwsh -NoProfile -File $runner -Plan watch_page -Alternate -DryRun -Parent $P -Commit $C -Passes 2 -FieldTables $k.tables -Work $work -Out $dout 2>&1 | Out-String
$lines = @($text -split "`r?`n" | Where-Object { $_ -match '^\s+\d+ pass\d+\s' })
$sides = @($lines | ForEach-Object { ($_ -split '\s+')[3] })
$lens = [regex]::Matches($text, 'root length (\d+)') | ForEach-Object { $_.Groups[1].Value }
Check '-Alternate -DryRun: parent, new, parent, new; equal roots; batch checks skipped; nothing written' (
    ($sides -join ',') -eq 'parent,new,parent,new' -and @($lens | Select-Object -Unique).Count -eq 1 -and $text -match 'skipped by the batch switch: wpFull' -and
    $text -notmatch '\bwpFull\s+new profile' -and -not (Test-Path $work) -and -not (Test-Path $dout) -and $text -match '--selftest --profile wp-parent-p1-wpDemo') "$($sides -join ','); root lengths $(@($lens) -join '/')"
$text = & pwsh -NoProfile -File $runner -Plan watch_page -Alternate -DryRun -Batch -Parent $P -Commit $C -Passes 1 -FieldTables $k.tables -Work $work -Out $dout 2>&1 | Out-String
$lines = @($text -split "`r?`n" | Where-Object { $_ -match '^\s+\d+ pass\d+\s' })
Check '-Alternate -DryRun -Batch: only the batch checks' ($lines.Count -eq 2 -and @($lines | Where-Object { $_ -match 'wpFull' }).Count -eq 2) "$($lines.Count) runs"
$text = & pwsh -NoProfile -File $runner -Plan watch_page -Alternate -DryRun -Parent $C -Commit $C -Passes 2 -FieldTables $k.tables -Work $work -Out $dout 2>&1 | Out-String
$lines = @($text -split "`r?`n" | Where-Object { $_ -match '^\s+\d+ pass\d+\s' })
Check '-Alternate -DryRun on one commit (calibration runs): one folder, one slot' ($lines.Count -eq 2 -and @($lines | Where-Object { $_ -match ' same ' }).Count -eq 2 -and $text -match 'one commit') "$($lines.Count) runs"

# -CheckTestSide on two real commits: S0a changed self_test_probe.dart
# (and neither commit has the frozen test files; the isolated cases on
# folders are below)
$text = & pwsh -NoProfile -File $runner -CheckTestSide "$P,$C" 2>&1 | Out-String
Check '-CheckTestSide on S0a (self_test_probe.dart changed) -> exit 1, and it names that file' ($LASTEXITCODE -eq 1 -and $text -match 'self_test_probe\.dart') (($text -split "`r?`n" | Where-Object { $_ -match 'self_test_probe' } | Select-Object -First 1))

# ================================================================ review fixes (audit-logs/wps-s0b/c1-review-*.md)
# Each case is tagged with the finding it guards; run against the runner
# before the fix (-Runner <copy>) it fails.
$P2 = 'c900b3cd4dedb8d9553bed7c139dcd2c634a9f46'; $C2 = '2e93ba7df2523e456666b94203149a092b573a12'
if (@("$(git -C $root rev-list --parents -n 1 $C2)" -split ' ') -notcontains $P2) { throw "$P2 is not the parent of $C2" }
$gee = 'lib/pages/login/geetest/geetest_webview_dialog.dart'
$geeHunks = (git -C $root diff -U0 $P2 $C2 -- $gee) -join "`n"
foreach ($h in '@@ -52 +53,6 @@', '@@ -76,7 +92,11 @@', '@@ -98,2 +117,0 @@', '@@ -289,3 +343,0 @@', '@@ -276 +306,21 @@') {
    if (-not $geeHunks.Contains($h)) { throw "${gee}: hunk $h not in the diff of $C2" }
}
$viewHunks = (git -C $root diff -U0 $P $C -- lib/pages/video/view.dart) -join "`n"
foreach ($h in '@@ -1624,9 +1666,12 @@', '@@ -1635,19 +1680,22 @@') {
    if (-not $viewHunks.Contains($h)) { throw "lib/pages/video/view.dart: hunk $h not in the diff of $C" }
}

# ---- [cx1 cl2] a shot whose image is not there is ① 无结果, not a class
$k = New-Case 'f-shot-missing'
New-Table $k.tables 'wpDemo' @((F 'branch'), ([ordered]@{ name = 'shot'; path = 'shots'; status = 'must-same'; type = 'shot'; tolerance = 0 }))
New-Side $k.parent $P $rootA @(1..4 | ForEach-Object { Chk @{ shots = @('C:/nowhere/gone.png') } })
New-Side $k.new $C $rootB @(1..4 | ForEach-Object { Chk @{ shots = @('C:/nowhere/gone.png') } })
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check '[cx1 cl2] shot images missing on both sides -> 无结果 (not 不稳定 / 相同)' ($row['verdict'] -eq 'noResult' -and (Fld $row 'shot')['verdict'] -eq 'noResult' -and @($row['downgraded']).Count -eq 0) "$($row['label']), shot $((Fld $row 'shot')['label'])"

# ---- [cx2 cl4] a pass of some checks (pass.json) leaves the others' rows alone; unequal counts
$k = New-Case 'f-scoped'
New-Table $k.tables 'wpA' @((F 'branch')) @{ check = 'wpA'; report = 'wpA.json' }
New-Table $k.tables 'wpB' @((F 'branch')) @{ check = 'wpB'; report = 'wpB.json' }
function SideAB([string]$dir, [string]$sha, [string]$rt, [string[]]$aBranches, [int]$bPasses) {
    New-Side $dir $sha $rt @()
    for ($i = 0; $i -lt $aBranches.Count; $i++) {
        $pd = Join-Path $dir "pass$($i + 1)"
        $ids = @('wpA'); if ($i -lt $bPasses) { $ids += 'wpB' }
        Write-Json ([ordered]@{ pass = $i + 1; checks = $ids }) (Join-Path $pd 'pass.json')
        Write-Json ([ordered]@{ checks = @((Chk @{ name = 'wpA'; branch = $aBranches[$i] })) }) (Join-Path $pd 'wpA.json')
        if ($i -lt $bPasses) { Write-Json ([ordered]@{ checks = @((Chk @{ name = 'wpB' })) }) (Join-Path $pd 'wpB.json') }
    }
}
SideAB $k.parent $P $rootA @('a', 'a', 'a', 'a') 2
SideAB $k.new $C $rootB @('a', 'b', 'a', 'a') 2
$r = Invoke-Compare @($k.parent, $k.new) $k.tables
$ra = Row $r 'wpA'; $rb = Row $r 'wpB'
Check '[cx2 cl4] pass3-4 ran only wpA (pass.json): wpB is judged on its 2 passes, not 无结果' ($rb['verdict'] -eq 'same' -and $ra['verdict'] -eq 'different' -and (Fld $ra 'branch')['verdict'] -eq 'differentNew') "wpA $($ra['label']), wpB $($rb['label'])"
$k = New-Case 'f-unequal'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P $rootA @(1..4 | ForEach-Object { Chk @{ branch = 'a' } })
New-Side $k.new $C $rootB @(1..2 | ForEach-Object { Chk @{ branch = 'b' } })
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check 'unequal pass counts (4 and 2), each constant, differ -> 需补跑 (final needs 4 on both sides)' ($row['verdict'] -eq 'rerun' -and (Fld $row 'branch')['verdict'] -eq 'rerun') "$($row['label'])"

# ---- [cl3] uiErrors missing: 无结果 unless the table is legacy (today's reports)
$k = New-Case 'f-ui-missing'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P $rootA @(1..2 | ForEach-Object { $cc = Chk; $cc.Remove('uiErrors'); $cc })
New-Side $k.new $C $rootB @(1..2 | ForEach-Object { $cc = Chk; $cc.Remove('uiErrors'); $cc })
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check '[cl3] uiErrors missing on both sides of an S0b table -> 无结果 (not 相同)' ($row['verdict'] -eq 'noResult' -and (Fld $row 'uiErrorKeys')['verdict'] -eq 'noResult') "$($row['label'])"
$k2 = New-Case 'f-ui-missing-legacy'
New-Table $k2.tables 'wpDemo' @((F 'branch')) @{ measured = [ordered]@{ legacy = @('branch') } }
New-Side $k2.parent $P $rootA @(1..2 | ForEach-Object { $cc = Chk; $cc.Remove('uiErrors'); $cc.Remove('measured'); $cc })
New-Side $k2.new $C $rootB @(1..2 | ForEach-Object { $cc = Chk; $cc.Remove('uiErrors'); $cc.Remove('measured'); $cc })
$row = Row (Invoke-Compare @($k2.parent, $k2.new) $k2.tables) 'wpDemo'
Check 'control: a legacy table (today''s reports) may omit uiErrors -> 相同' ($row['verdict'] -eq 'same') "$($row['label'])"

# ---- [cx5 cl11] numbers by value, dates as text
$k = New-Case 'f-numbers'
New-Table $k.tables 'wpDemo' @((F 'branch'), (F 'n'), (F 'when'))
New-Side $k.parent $P $rootA @(1..4 | ForEach-Object { Chk @{ n = [long]1; when = '2026-10-31T12:00:00+08:00' } })
New-Side $k.new $C $rootB @(1..4 | ForEach-Object { Chk @{ n = [double]1; when = '2026-10-31T13:00:00+09:00' } })
$raw = Get-Content -Raw (Join-Path $k.new 'pass1\wpDemo.json')
if ($raw -notmatch '"n":\s*1\.0') { throw 'the new side was meant to write n as 1.0' }
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check '[cx5] 1 (parent) and 1.0 (new) -> 相同' ((Fld $row 'n')['verdict'] -eq 'same') "n $((Fld $row 'n')['label'])"
Check '[cl11] the same instant written with two offsets -> 不同 (dates compared as text)' ((Fld $row 'when')['verdict'] -eq 'different') "when $((Fld $row 'when')['label'])"
$k = New-Case 'f-numbers-mixed'
New-Table $k.tables 'wpDemo' @((F 'branch'), (F 'n'))
New-Side $k.parent $P $rootA @(([long]1), ([double]1), ([long]1), ([double]1) | ForEach-Object { Chk @{ n = $_ } })
New-Side $k.new $C $rootB @(1..4 | ForEach-Object { Chk @{ n = [long]1 } })
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check '[cx5] parent [1, 1.0, 1, 1.0] -> 相同, not 不稳定' ((Fld $row 'n')['verdict'] -eq 'same' -and @($row['downgraded']).Count -eq 0) "n $((Fld $row 'n')['label'])"

# ---- [cx7] worktree roots with spaces
$rootSA = 'C:/some folder/wpA'; $rootSB = 'C:/some folder/wpB'
$k = New-Case 'f-spaces'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P $rootSA @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Ov $rf 'Row' 'file:///C:/some%20folder/wpA/lib/pages/home/view.dart:30:2'), (Today $rootSA 300)) } })
New-Side $k.new $C $rootSB @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Ov $rf 'Row' 'C:\some folder\wpB\lib\pages\home\view.dart:30'), (Today $rootSB 324)) } })
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
$ui = UiF $row 'home/view.dart:30'; $ui2 = UiF $row 'main.dart:324'
Check '[cx7] origins and today''s texts under a root with spaces -> placed, 相同' ($row['verdict'] -eq 'same' -and $ui.Count -eq 1 -and $ui2.Count -eq 1) "$($row['label']); $(@($row['fields'] | ForEach-Object { $_['name'] }) -join ' / ')"

# ---- [cl12] a line number cut at the 320-character point is not a line
function Cut320([string]$rootPath) {
    $tail = "Row:file:///$rootPath/lib/pages/home/view.dart:132:11"
    $head = 'A RenderFlex overflowed by 13 pixels on the right. The relevant error-causing widget was: Row '
    $pad = 'x' * (320 - $head.Length - $tail.Length + 4)
    $t = ($head + $pad + $tail).Substring(0, 320)
    if (-not $t.EndsWith('view.dart:13')) { throw "the cut text ends '$($t.Substring(300))'" }
    return "$t @ during layout"
}
$k = New-Case 'f-cut'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P $rootA @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Cut320 $rootA)) } })
New-Side $k.new $C $rootB @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Cut320 $rootB)) } })
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
$ui = @($row['fields'] | Where-Object { $_['name'] -like 'uiErrorKeys*' })
Check '[cl12] ":132" cut to ":13" at 320 characters -> not read as line 13 (weak text key)' ($ui.Count -eq 1 -and $ui[0]['name'] -notmatch 'view\.dart:13\b' -and $ui[0]['note'] -eq 'weak' -and $row['verdict'] -eq 'same') "$($ui | ForEach-Object { $_['name'] })"

# ---- [cl13a] measured must be the boolean true
$k = New-Case 'f-measured'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P $rootA @((Chk @{ measured = 'true' }), (Chk))
New-Side $k.new $C $rootB @((Chk @{ measured = 1 }), (Chk))
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check '[cl13a] measured "true" / 1 -> not measured, 无结果' ($row['verdict'] -eq 'noResult' -and @($row['reasons'] | Where-Object { $_ -match 'not measured' }).Count -eq 2) "$($row['label']): $(@($row['reasons']) -join '; ')"

# ---- [cl6] an entry one side cannot place makes the same prefix 无法比较, not 不同
$k = New-Case 'f-onesided'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P $rootA @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/main.dart:337')) } })
New-Side $k.new $C $rootB @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/pages/home/view.dart:5')) } })
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables $empty) 'wpDemo'
$ui = UiF $row 'home/view.dart:5'
Check '[cl6] parent entry unplaceable, new side placed -> 无法比较 (not 不同)' ($row['verdict'] -eq 'notComparable' -and $ui.Count -eq 1 -and $ui[0]['verdict'] -eq 'notComparable') "$($row['label']); $(@($ui | ForEach-Object { $_['label'] }))"

# ---- [cl13e] the two folders read different media -> 无结果; roots of different length -> today's texts 无法比较
$k = New-Case 'f-media'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P $rootA @((Chk), (Chk))
New-Side $k.new $C $rootB @((Chk), (Chk))
foreach ($pair in @(@($k.parent, 'aaa'), @($k.new, 'bbb'))) {
    $mf = Join-Path $pair[0] 'manifest.json'; $mm = Get-Content -Raw $mf | ConvertFrom-Json -AsHashtable
    $mm['media'] = [ordered]@{ 'c:\media|clip.mp4' = $pair[1] }; Write-Json $mm $mf
}
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check '[cl13e] different media in the two manifests -> 无结果' ($row['verdict'] -eq 'noResult' -and @($row['reasons'] | Where-Object { $_ -match 'media' }).Count -eq 1) "$($row['label'])"
$k = New-Case 'f-rootlen'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P 'C:/fake/wpA' @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Today 'C:/fake/wpA' 300)) } })
New-Side $k.new $C 'C:/fake/longer/wpB' @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Today 'C:/fake/longer/wpB' 324)) } })
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check '[cl13e] worktree roots of different length -> today''s 320-character texts 无法比较' ($row['verdict'] -eq 'notComparable') "$($row['label'])"

# ---- coverage: replacement and deletion hunks, a moved block with an offset, sameLength false, frames in changed files
$k = New-Case 'c-hunks'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P2 $rootA @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Ov $rf 'Row' "${gee}:200"), (Ov 'B' 'Col' "${gee}:292")) } })
New-Side $k.new $C2 $rootB @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Ov $rf 'Row' "${gee}:230"), (Ov 'B' 'Col' "${gee}:344")) } })
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables $empty) 'wpDemo'
Check 'hunks: after replacement (-52 +53,6, -76,7 +92,11) and deletion (-98,2 +117,0) hunks 200 -> 230; after -289,3 +343,0 292 -> 344 -> 相同' ($row['verdict'] -eq 'same' -and (UiF $row "${gee}:230").Count -eq 1 -and (UiF $row "${gee}:344").Count -eq 1) "$($row['label'])"
$k = New-Case 'c-hunks-del'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P2 $rootA @(1..2 | ForEach-Object { Chk @{ uiErrors = @((Ov $rf 'Row' "${gee}:99")) } })
New-Side $k.new $C2 $rootB @(1..2 | ForEach-Object { Chk @{ uiErrors = @() } })
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables $empty) 'wpDemo'
Check 'hunks: a parent line inside a deleted block (-98,2), no map -> 无法比较' ($row['verdict'] -eq 'notComparable') "$($row['label'])"
$k = New-Case 'c-moved'
New-Table $k.tables 'wpDemo' @((F 'branch'))
$map2 = Join-Path $k.dir 'map.json'
Write-Json ([ordered]@{ rows = @(
            [ordered]@{ id = 'blk'; parent = [ordered]@{ file = 'lib/pages/video/view.dart'; start = 1624; end = 1632 }; child = [ordered]@{ file = 'lib/pages/video/view.dart'; start = 1666; end = 1674 }; sameLength = $true },
            [ordered]@{ id = 'grown'; parent = [ordered]@{ file = 'lib/pages/video/view.dart'; start = 1635; end = 1653 }; child = [ordered]@{ file = 'lib/pages/video/view.dart'; start = 1680; end = 1701 }; sameLength = $false }) }) $map2
New-Side $k.parent $P $rootA @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/pages/video/view.dart:1626'), (Ov 'B' 'Col' 'lib/pages/video/view.dart:1640')) } })
New-Side $k.new $C $rootB @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/pages/video/view.dart:1668'), (Ov 'B' 'Col' 'lib/pages/video/view.dart:1690')) } })
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables $map2) 'wpDemo'
Check 'map: a 9-line row, offset 2 on both sides -> M:blk+2, 相同; a sameLength false row, offsets 5 and 10 -> M:grown, 相同' ($row['verdict'] -eq 'same' -and (UiF $row 'M:blk+2').Count -eq 1 -and @($row['fields'] | Where-Object { $_['name'] -match '\| M:grown\]$' }).Count -eq 1) "$(@($row['fields'] | ForEach-Object { $_['name'] }) -join ' / ')"
New-Side (Join-Path $k.dir 'new2') $C $rootB @(1..4 | ForEach-Object { Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/pages/video/view.dart:1669')) } })
$row = Row (Invoke-Compare @($k.parent, (Join-Path $k.dir 'new2')) $k.tables $map2) 'wpDemo'
Check 'map: offset 2 on one side, 3 on the other -> 不同' ($row['verdict'] -eq 'different' -and (UiF $row 'M:blk+3').Count -eq 1) "$($row['label'])"
$k = New-Case 'c-frames'
New-Table $k.tables 'wpDemo' @((F 'branch'))
New-Side $k.parent $P $rootA @(1..4 | ForEach-Object { Chk @{ uiErrors = @((NoOrigin '#1 main (package:PiliPlus/main.dart:300:5)')) } })
New-Side $k.new $C $rootB @(1..4 | ForEach-Object { Chk @{ uiErrors = @((NoOrigin '#1 main (package:PiliPlus/main.dart:324:5)')) } })
$row = Row (Invoke-Compare @($k.parent, $k.new) $k.tables) 'wpDemo'
Check '⑦ in a changed file: the first app frame moved through the diff (300 -> 324) -> 相同, weak' ($row['verdict'] -eq 'same' -and (UiF $row 'main.dart:324').Count -eq 1) "$($row['label'])"
New-Side (Join-Path $k.dir 'new2') $C $rootB @(1..4 | ForEach-Object { Chk @{ uiErrors = @((NoOrigin '#1 main (package:PiliPlus/main.dart:361:5)')) } })
New-Side (Join-Path $k.dir 'par2') $P $rootA @(1..4 | ForEach-Object { Chk @{ uiErrors = @((NoOrigin '#1 main (package:PiliPlus/main.dart:337:5)')) } })
$row = Row (Invoke-Compare @((Join-Path $k.dir 'par2'), (Join-Path $k.dir 'new2')) $k.tables $empty) 'wpDemo'
Check '⑦ in a changed file: the first app frame inside a changed block, no map -> 无法比较' ($row['verdict'] -eq 'notComparable') "$($row['label'])"

# ---- [cx8 cl8] calibration: lists of objects walked by index; shots compared as images
$k = New-Case 'f-cal'
New-Table $k.tables 'wpDemo' @((F 'branch'))
$calA = Join-Path $k.dir 'a'
New-Side $calA $C $rootA @((Chk @{ runs = @([ordered]@{ end = 'x'; ms = 10 }); shots = @("$calA/pass1/wpDemo_shots/s.png"); shots2 = @("$calA/pass1/wpDemo_shots/t.png") }),
    (Chk @{ runs = @([ordered]@{ end = 'x'; ms = 12 }); shots = @("$calA/pass2/wpDemo_shots/s.png"); shots2 = @("$calA/pass2/wpDemo_shots/t.png") }))
Png (Join-Path $calA 'pass1\wpDemo_shots\s.png') 2; Png (Join-Path $calA 'pass2\wpDemo_shots\s.png') 2
Png (Join-Path $calA 'pass1\wpDemo_shots\t.png') 2; Png (Join-Path $calA 'pass2\wpDemo_shots\t.png') 3
$r = Invoke-Compare @($calA) $k.tables
$cal = @($r.json['checks'])[0]
$vary = @($cal['varying'] | ForEach-Object { $_['path'] })
$sug = Get-Content -Raw (Join-Path $r.outDir 'suggested-fields\wpDemo@wpDemo.json') | ConvertFrom-Json -AsHashtable
$sEnd = @($sug['fields'] | Where-Object { $_['path'] -eq 'runs[0].end' }); $sShot = @($sug['fields'] | Where-Object { $_['path'] -eq 'shots' }); $sShot2 = @($sug['fields'] | Where-Object { $_['path'] -eq 'shots2' })
Check '[cx8] calibration walks a list of objects: runs[0].ms varies, runs[0].end is suggested must-same' ($vary -contains 'runs[0].ms' -and $vary -notcontains 'runs' -and $vary -notcontains 'runs[0].end' -and $sEnd.Count -eq 1 -and $sEnd[0]['status'] -eq 'must-same') "varying: $($vary -join ', ')"
Check '[cl8] calibration compares shots as images: equal images at different paths do not vary; 1 px apart -> noise floor 1, suggested shot tolerance 1' ($vary -notcontains 'shots' -and $sShot.Count -eq 1 -and $sShot[0]['type'] -eq 'shot' -and $sShot[0]['status'] -eq 'must-same' -and $vary -contains 'shots2' -and $sShot2[0]['tolerance'] -eq 1 -and $sShot2[0]['status'] -eq 'must-same') "varying: $($vary -join ', '); shots2 tolerance $($sShot2 | ForEach-Object { $_['tolerance'] })"

# ---- [cl5] tables sharing one report: one run, not one per table; different runs refused
$k = New-Case 'f-group'
New-Table $k.tables 'wpX' @((F 'branch')) @{ check = 'wpX'; report = 'shared.json' }
New-Table $k.tables 'wpY' @((F 'branch')) @{ check = 'wpY'; report = 'shared.json' }
$text = & pwsh -NoProfile -File $runner -Plan watch_page -Alternate -DryRun -Parent $P -Commit $C -Passes 1 -FieldTables $k.tables -Work (Join-Path $k.dir 'w') -Out (Join-Path $k.dir 'o') 2>&1 | Out-String
$lines = @($text -split "`r?`n" | Where-Object { $_ -match '^\s+\d+ pass\d+\s' })
Check '[cl5] two tables reading one report -> one run per side and pass (wpX+wpY)' ($lines.Count -eq 2 -and @($lines | Where-Object { $_ -match 'wpX\+wpY' }).Count -eq 2) "$($lines.Count) runs"
$k = New-Case 'f-group-bad'
New-Table $k.tables 'wpX' @((F 'branch')) @{ check = 'wpX'; report = 'shared.json' }
New-Table $k.tables 'wpY' @((F 'branch')) @{ check = 'wpY'; report = 'shared.json'; run = [ordered]@{ args = @('--other'); planPrefs = $false; profile = 'fresh' } }
$text = & pwsh -NoProfile -File $runner -Plan watch_page -Alternate -DryRun -Parent $P -Commit $C -Passes 1 -FieldTables $k.tables -Work (Join-Path $k.dir 'w') -Out (Join-Path $k.dir 'o') 2>&1 | Out-String
Check '[cl5] two tables reading one report with different runs -> refused' ($LASTEXITCODE -ne 0 -and (Flat $text) -match 'name different runs') (($text -split "`r?`n" | Where-Object { $_ -match 'different runs' } | Select-Object -First 1))

# ---- [cl13c] batch is required in every table
$k = New-Case 'f-batch-key'
New-Table $k.tables 'wpDemo' @((F 'branch'))
$tf = Join-Path $k.tables 'wpDemo.json'; $tt = Get-Content -Raw $tf | ConvertFrom-Json -AsHashtable; $tt.Remove('batch'); Write-Json $tt $tf
New-Side $k.parent $P $rootA @((Chk), (Chk)); New-Side $k.new $C $rootB @((Chk), (Chk))
$r = Invoke-Compare @($k.parent, $k.new) $k.tables
Check '[cl13c] a table without "batch" -> refused' ($r.code -ne 0 -and (Flat $r.out) -match 'no batch: say null') (($r.out -split "`r?`n" | Where-Object { $_ -match 'no batch' } | Select-Object -First 1))

# ---- a scratch copy of the runner: its own wp-mutants.json, wp_fields\ and patch
function New-RunnerCopy([string]$name) {
    $d = Join-Path $scratch "$name\m"
    New-Item -ItemType Directory -Force (Join-Path $d 'wp_fields') | Out-Null
    Copy-Item -LiteralPath $runner (Join-Path $d 'run.ps1')
    return $d
}

# ---- [cx4 cl1] the batch switch narrows a copy: a mutant with an in-app and a fullscreen catcher
$m = New-RunnerCopy 'f-batch-copy'
New-Table (Join-Path $m 'wp_fields') 'inapp' @([ordered]@{ name = 'branch'; path = 'branch'; status = 'must-same'; expectedFor = @('wp-demo') }) @{ check = 'inapp'; report = 'inapp.json' }
New-Table (Join-Path $m 'wp_fields') 'full' @([ordered]@{ name = 'x'; path = 'x'; status = 'must-same'; expectedFor = @('wp-demo') }) @{ check = 'full'; report = 'full.json'; batch = 'fullscreen' }
Set-Content -LiteralPath (Join-Path $m 'wp-demo.patch') -Value 'diff --git a/lib/x.dart b/lib/x.dart' -Encoding utf8
Write-Json ([ordered]@{ plan = 'watch_page'; phases = [ordered]@{ S0 = @('S0') }; defaultPhase = 'S0'; prefs = @(); media = @()
        mutants = @([ordered]@{ id = 'wp-demo'; patch = 'wp-demo.patch'; location = 'lib/x.dart:1'; change = 'demo'; landing = 'S0'; kind = 'selftest'; catcher = 'both'
                catchers = @([ordered]@{ check = 'inapp'; expected = @('branch') }, [ordered]@{ check = 'full'; expected = @('x') }) })
    }) (Join-Path $m 'wp-mutants.json')
$outs = @()
foreach ($b in @(@(), @('-Batch'))) {
    $text = & pwsh -NoProfile -File (Join-Path $m 'run.ps1') -Plan watch_page -NoUnit -NoSelfTest -Flutter x -Out (Join-Path $m "out$($b.Count)") -Work (Join-Path $m 'w') @b 2>&1 | Out-String
    $outs += @{ code = $LASTEXITCODE; text = $text }
}
Check '[cx4 cl1] a mutant with an in-app and a fullscreen catcher: the default run and -Batch both start (no "does not expect it")' ($outs[0].code -eq 0 -and $outs[1].code -eq 0 -and ($outs[0].text + $outs[1].text) -notmatch 'does not expect it') "exit $($outs[0].code) / $($outs[1].code)$(if (($outs[0].text + $outs[1].text) -match 'does not expect it') { ': does not expect it' })"

# ---- [cl9] -Compare refuses field tables that are not HEAD's (no -FieldTables)
$m = New-RunnerCopy 'f-committed'
New-Table (Join-Path $m 'wp_fields') 'wpDemo' @((F 'branch'))
$kc = New-Case 'f-committed-data'
New-Side $kc.parent $P $rootA @((Chk), (Chk)); New-Side $kc.new $C $rootB @((Chk), (Chk))
$text = & pwsh -NoProfile -File (Join-Path $m 'run.ps1') -Plan watch_page -Compare "$($kc.parent),$($kc.new)" 2>&1 | Out-String
Check '[cl9] -Compare with field tables not committed at HEAD (and no -FieldTables) -> refused, names git add -f' ($LASTEXITCODE -ne 0 -and (Flat $text) -match 'not HEAD.s.*git add -f') (($text -split "`r?`n" | Where-Object { $_ -match 'git add -f' } | Select-Object -First 1) -replace '^.{0,40}\|\s*', '')

# ---- [cx6 cl9 cl10] -CheckTestSide on two folders laid out as the repository
function New-TestSide([string]$dir) {
    foreach ($f in 'lib/utils/self_test.dart', 'lib/utils/self_test_probe.dart', 'lib/utils/self_test_watch.dart', 'test/mutants/run.ps1', 'test/mutants/wp_compare_selftest.ps1', 'test/mutants/wp_fields/t.json', 'test/mutants/wp-a.patch') {
        $p = Join-Path $dir $f; New-Item -ItemType Directory -Force (Split-Path -Parent $p) | Out-Null
        Set-Content -LiteralPath $p -Value "content of $f" -Encoding utf8 -NoNewline
    }
    Write-Json ([ordered]@{ plan = 'watch_page'; mutants = @([ordered]@{ id = 'wp-a'; patch = 'wp-a.patch'; location = 'lib/a.dart:1'; change = 'Demo' }) }) (Join-Path $dir 'test/mutants/wp-mutants.json')
}
function Invoke-TestSide([string]$name, [scriptblock]$mutate) {
    $a = Join-Path $scratch "ts-$name\a"; $b = Join-Path $scratch "ts-$name\b"
    New-TestSide $a; New-TestSide $b
    & $mutate $b
    $text = & pwsh -NoProfile -File $runner -CheckTestSide "$a,$b" 2>&1 | Out-String
    return @{ code = $LASTEXITCODE; text = $text }
}
$x = Invoke-TestSide 'control' { param($b)
    # S1 may rewrite a patch and its location, nothing else
    Set-Content -LiteralPath (Join-Path $b 'test/mutants/wp-a.patch') -Value 'rewritten' -Encoding utf8 -NoNewline
    $mf = Join-Path $b 'test/mutants/wp-mutants.json'; $mm = Get-Content -Raw $mf | ConvertFrom-Json -AsHashtable
    $mm['mutants'][0]['location'] = 'lib/shell.dart:9'; Write-Json $mm $mf }
Check '[cx9] -CheckTestSide control: only a patch and its location changed -> exit 0' ($x.code -eq 0) "exit $($x.code)"
$x = Invoke-TestSide 'selftest' { param($b) Set-Content -LiteralPath (Join-Path $b 'test/mutants/wp_compare_selftest.ps1') -Value 'changed' -Encoding utf8 -NoNewline }
Check '[cx6 cl10] -CheckTestSide: wp_compare_selftest.ps1 changed -> exit 1' ($x.code -eq 1 -and $x.text -match 'changed: test/mutants/wp_compare_selftest\.ps1') "exit $($x.code)"
$x = Invoke-TestSide 'watch' { param($b) Set-Content -LiteralPath (Join-Path $b 'lib/utils/self_test_watch.dart') -Value 'changed' -Encoding utf8 -NoNewline }
Check '[c3a11] -CheckTestSide: the readings'' self_test_watch.dart changed -> exit 1' ($x.code -eq 1 -and $x.text -match 'changed: lib/utils/self_test_watch\.dart') "exit $($x.code)"
$x = Invoke-TestSide 'table' { param($b) Set-Content -LiteralPath (Join-Path $b 'test/mutants/wp_fields/t.json') -Value 'changed' -Encoding utf8 -NoNewline }
Check '-CheckTestSide: a field table changed -> exit 1' ($x.code -eq 1 -and $x.text -match 'changed: test/mutants/wp_fields/t\.json') "exit $($x.code)"
$x = Invoke-TestSide 'case' { param($b)
    $mf = Join-Path $b 'test/mutants/wp-mutants.json'; $mm = Get-Content -Raw $mf | ConvertFrom-Json -AsHashtable
    $mm['mutants'][0]['change'] = 'demo'; Write-Json $mm $mf }
Check '[cx6] -CheckTestSide: a manifest string changed only in case -> exit 1' ($x.code -eq 1 -and $x.text -match 'differs beyond') "exit $($x.code)"
$x = Invoke-TestSide 'missing' { param($b) Remove-Item -LiteralPath (Join-Path $b 'test/mutants/wp_fields') -Recurse -Force }
Check '[cl9] -CheckTestSide: wp_fields/ missing on one side (an ignored file never committed) -> exit 1' ($x.code -eq 1 -and $x.text -match 'missing in .*test/mutants/wp_fields') "exit $($x.code)"
$x = Invoke-TestSide 'patch' { param($b) Remove-Item -LiteralPath (Join-Path $b 'test/mutants/wp-a.patch') }
Check '[cl9] -CheckTestSide: a patch the manifest names is missing -> exit 1' ($x.code -eq 1 -and $x.text -match 'missing in .*wp-a\.patch') "exit $($x.code)"

# ================================================================ the mutant judge (dot-sourced)
. $runner -LoadOnly -Plan watch_page
$k = New-Case 'x-mut'
$t = [ordered]@{ id = 'wpDemo'; check = 'wpDemo'; report = 'wpDemo.json'; type = 'recording'; batch = $null; network = $true; measured = 'measured'
    fields = @((F 'branch'), (F 'idx'), (F 'noise' 'unstable')); uiErrors = [ordered]@{ status = 'must-same' } }
$t = $t | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
function Rep([string]$name, $c, [string]$extraText = '') {
    $f = Join-Path $k.dir "$name.json"
    $doc = [ordered]@{ checks = @($c) }
    if ($extraText) { $doc['eventLog'] = @($extraText) }
    Write-Json $doc $f
    return $f
}
$base = Rep 'base' (Chk)
$j1 = Compare-WpMutant $t @('branch') $base (Rep 'm1' (Chk @{ branch = 'portrait' })) $rootA $rootA
$j2 = Compare-WpMutant $t @('branch') $base (Rep 'm2' (Chk @{ idx = 0 })) $rootA $rootA
$j3 = Compare-WpMutant $t @('branch') $base (Rep 'm3' (Chk)) $rootA $rootA
$j4 = Compare-WpMutant $t @('branch') $base (Rep 'm4' (Chk @{ measured = $false; branch = 'portrait' })) $rootA $rootA
$j5 = Compare-WpMutant $t @('branch') $base (Rep 'm5' (Chk @{ branch = [ordered]@{ '$unread' = 'pageRoute' } })) $rootA $rootA
$j6 = Compare-WpMutant $t @('uiErrorKeys') $base (Rep 'm6' (Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/pages/home/view.dart:1')) })) $rootA $rootA
$j7 = Compare-WpMutant $t @('branch') $base (Rep 'm7' (Chk @{ branch = 'portrait' }) 'download: again in 10 s (1/3)') $rootA $rootA
$j8 = Compare-WpMutant $t @('branch') $base (Rep 'm8' (Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/pages/home/view.dart:1')) })) $rootA $rootA
Check 'mutant: the expected field differs -> caught' ($j1.result -eq 'caught' -and -not $j1.trigger) "$($j1.result): $($j1.first)"
Check 'mutant: only another must-same field differs -> noise (rerun, then error)' ($j2.result -eq 'noise') "$($j2.result): $($j2.first)"
Check 'mutant: no difference (an unstable field aside) -> clean (survived)' ($j3.result -eq 'clean') $j3.result
Check 'mutant: the mutant''s report not measured -> error (runner 补充①)' ($j4.result -eq 'error') "$($j4.result): $($j4.first)"
Check 'mutant: the expected field unread -> error, not caught' ($j5.result -eq 'error') "$($j5.result): $($j5.first)"
Check 'mutant: uiErrorKeys expected, a new entry -> caught' ($j6.result -eq 'caught') "$($j6.result): $($j6.first)"
Check 'mutant: caught next to a network retry -> caught with the rerun trigger' ($j7.result -eq 'caught' -and $j7.trigger) "$($j7.result), trigger $($j7.trigger)"
Check 'mutant: a new uiErrors entry it does not expect -> noise, rerun trigger' ($j8.result -eq 'noise' -and $j8.trigger) "$($j8.result), trigger $($j8.trigger)"


# ---- review fixes in the mutant judge (dot-sourced functions)
# [cx3] an unread or malformed uiErrors reading proves no catch
$base0 = Rep 'ui-base-unread' (Chk @{ uiErrors = [ordered]@{ '$unread' = 'failed' } })
$jA = Compare-WpMutant $t @('uiErrorKeys') $base0 (Rep 'ui-mut-one' (Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/pages/home/view.dart:1')) })) $rootA $rootA
Check '[cx3] uiErrorKeys expected, the baseline''s uiErrors {"$unread"} -> error, not caught' ($jA.result -eq 'error') "$($jA.result): $($jA.first)"
$base1 = Rep 'ui-base-entry' (Chk @{ uiErrors = @([ordered]@{ '$unread' = 'entry' }) })
$jB = Compare-WpMutant $t @('uiErrorKeys') $base1 (Rep 'ui-mut-two' (Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/pages/home/view.dart:1')) })) $rootA $rootA
Check '[cx3] uiErrorKeys expected, an unread entry in the baseline''s list -> error' ($jB.result -eq 'error') "$($jB.result): $($jB.first)"
$c2 = Chk; $c2.Remove('uiErrors'); $base2 = Rep 'ui-base-none' $c2
$jC = Compare-WpMutant $t @('uiErrorKeys') $base2 (Rep 'ui-mut-three' (Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/pages/home/view.dart:1')) })) $rootA $rootA
Check '[cx3 cl3] uiErrorKeys expected, the baseline has no uiErrors key (an S0b table) -> error' ($jC.result -eq 'error') "$($jC.result): $($jC.first)"

# [cx1 cl2] an expected shot whose image is not there -> error, not caught
$ts = [ordered]@{ id = 'wpShot'; check = 'wpDemo'; report = 'wpDemo.json'; type = 'recording'; batch = $null; network = $false; measured = 'measured'
    fields = @([ordered]@{ name = 'shot'; path = 'shots'; status = 'must-same'; type = 'shot'; tolerance = 0 }); uiErrors = [ordered]@{ status = 'must-same' } } | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
Png (Join-Path $k.dir 'present.png') 2
$jD = Compare-WpMutant $ts @('shot') (Rep 'shot-base' (Chk @{ shots = @((Join-Path $k.dir 'present.png')) })) (Rep 'shot-mut' (Chk @{ shots = @('C:/nowhere/missing.png') })) $rootA $rootA
Check '[cx1 cl2] mutant: expected shot, the mutant''s image missing -> error, not caught' ($jD.result -eq 'error') "$($jD.result): $($jD.first)"

# [cl7] baseline -> mutant lines through the mutant's own patch
$patch = Join-Path $k.dir 'wp-demo.patch'
Set-Content -LiteralPath $patch -Encoding utf8 -Value @(
    'diff --git a/lib/pages/video/view.dart b/lib/pages/video/view.dart', '--- a/lib/pages/video/view.dart', '+++ b/lib/pages/video/view.dart',
    '@@ -100,6 +100,7 @@ class X', ' a', ' b', ' c', '+inserted', ' d', ' e', ' f')
$bUi = Rep 'p-base' (Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/pages/video/view.dart:1200')) })
$mMoved = Rep 'p-moved' (Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/pages/video/view.dart:1201')) })
$jE = Compare-WpMutant $t @('uiErrorKeys') $bUi $mMoved $rootA $rootA $patch
$jF = Compare-WpMutant $t @('uiErrorKeys') $bUi $mMoved $rootA $rootA
$jG = Compare-WpMutant $t @('uiErrorKeys') $bUi (Rep 'p-new' (Chk @{ uiErrors = @((Ov $rf 'Row' 'lib/pages/video/view.dart:1201'), (Ov 'B' 'Col' 'lib/pages/video/view.dart:103')) })) $rootA $rootA $patch
Check '[cl7] the patch adds a line above the baseline''s error (1200 -> 1201): the same error, not a catch' ($jE.result -eq 'clean') "$($jE.result) (without the patch: $($jF.result))"
Check '[cl7] control: without the patch the moved error reads as new (the case is not vacuous)' ($jF.result -eq 'caught') $jF.result
Check '[cl7] an error on the patch''s own added line -> a new key (PATCH:…), caught' ($jG.result -eq 'caught' -and $jG.first -match 'PATCH:lib/pages/video/view\.dart') "$($jG.result): $($jG.first)"

# [cl13b] the rerun regex: the [captcha] area and whole -352 / -412 only
$jH = Compare-WpMutant $t @('branch') $base (Rep 'rx-1' (Chk @{ branch = 'portrait' }) '12:00:01.000 [webview] click DIV.captcha-box; seek -352.0; x-3520') $rootA $rootA
$jI = Compare-WpMutant $t @('branch') $base (Rep 'rx-2' (Chk @{ branch = 'portrait' }) '12:00:00.000 [captcha] risk sdk: loaded') $rootA $rootA
$jJ = Compare-WpMutant $t @('branch') $base (Rep 'rx-3' (Chk @{ branch = 'portrait' }) '12:00:00.000 [http] search refused: code -352') $rootA $rootA
Check '[cl13b] "captcha" in a class name, -352.0 and x-3520 -> no rerun trigger' ($jH.result -eq 'caught' -and -not $jH.trigger) "trigger $($jH.trigger)"
Check '[cl13b] a [captcha] event-log line, or code -352 -> rerun trigger' ($jI.trigger -and $jJ.trigger) "$($jI.trigger) / $($jJ.trigger)"

# [cl13d] a -Baseline that read more media than this run covers it
# (a runner without the function: the cases below fail, they do not stop
# the run, so -Runner <an older copy> still lists every case)
if (-not (Get-Command Test-WpMediaCovers -ErrorAction SilentlyContinue)) {
    Check '[cl13d] -Baseline media: a superset covers; a changed hash does not' $false 'no Test-WpMediaCovers in this runner'
} else {
$cov1 = Test-WpMediaCovers ([ordered]@{ 'a|x' = '1'; 'b|y' = '2' }) ([ordered]@{ 'a|x' = '1' })
$cov2 = Test-WpMediaCovers ([ordered]@{ 'a|x' = '1' }) ([ordered]@{ 'a|x' = '9' })
Check '[cl13d] -Baseline media: a superset covers; a changed hash does not' ($cov1.Count -eq 0 -and $cov2.Count -eq 1) "$($cov1.Count) / $($cov2.Count)"
}

# [cx9] the mutant loop's catcher: noise -> rerun -> error, driven by prepared reports
$cx9 = @('[cx9] mutant loop: noise, then noise again on the rerun -> error (not survived, not caught)', '[cx9] mutant loop: noise, then the expected field on the rerun -> caught',
    '[cx9] mutant loop: a catch next to a network retry, clean on the rerun -> survived', '[cx9] mutant loop: a clean catch -> caught, no rerun', '[cx9] two catchers, one errored, one caught -> caught')
if (-not (Get-Command Invoke-WpCatcher -ErrorAction SilentlyContinue)) {
    foreach ($n in $cx9) { Check $n $false 'no Invoke-WpCatcher in this runner (the loop could not be driven without the app)' }
} else {
$q = @{ files = [System.Collections.Generic.Queue[string]]::new(); calls = 0 }
$fake = { param([string]$runDir, [string]$runTag) $q.calls++; return $q.files.Dequeue() }
$rNoise = Rep 'q-noise' (Chk @{ idx = 0 }); $rCaught = Rep 'q-caught' (Chk @{ branch = 'portrait' })
$rTrig = Rep 'q-trig' (Chk @{ branch = 'portrait' }) 'download: again in 10 s (1/3)'; $rClean = Rep 'q-clean' (Chk)
function Drive([string[]]$files, [string[]]$exp = @('branch')) {
    $q.files.Clear(); $q.calls = 0; foreach ($f in $files) { $q.files.Enqueue($f) }
    $c = Invoke-WpCatcher $t $exp $base $rootA $rootA '' $fake (Join-Path $k.dir 'drive') 'wp-x'
    return @{ catcher = $c; row = (Resolve-WpMutantResult @($c)); calls = $q.calls }
}
$d1 = Drive @($rNoise, $rNoise)
Check '[cx9] mutant loop: noise, then noise again on the rerun -> error (not survived, not caught)' ($d1.calls -eq 2 -and $d1.row.result -eq 'error' -and $d1.catcher['note'] -match '^rerun \(noise') "calls $($d1.calls), $($d1.row.result): $($d1.row.first)"
$d2 = Drive @($rNoise, $rCaught)
Check '[cx9] mutant loop: noise, then the expected field on the rerun -> caught' ($d2.calls -eq 2 -and $d2.row.result -eq 'caught') "calls $($d2.calls), $($d2.row.result)"
$d3 = Drive @($rTrig, $rClean)
Check '[cx9] mutant loop: a catch next to a network retry, clean on the rerun -> survived' ($d3.calls -eq 2 -and $d3.row.result -eq 'survived') "calls $($d3.calls), $($d3.row.result)"
$d4 = Drive @($rCaught)
Check '[cx9] mutant loop: a clean catch -> caught, no rerun' ($d4.calls -eq 1 -and $d4.row.result -eq 'caught') "calls $($d4.calls), $($d4.row.result)"
$d5 = Resolve-WpMutantResult @(@{ result = 'error'; by = ''; first = 'baseline did not pass'; note = '' }, $d4.catcher)
Check '[cx9] two catchers, one errored, one caught -> caught' ($d5.result -eq 'caught') $d5.result
}

# [c3a12] a process that ends abnormally before writing its report is run
# once more (the startup crash, exit 0xC0000005); a second crash leaves no
# report (error, runner 补充①); a crash is in the row's note
$c12 = @('[c3a12] a crash before the report, then a report -> one rerun, the report used, the crash recorded',
    '[c3a12] two crashes -> two launches only, no report, both recorded', '[c3a12] exit 1 without a report (not a crash) -> not rerun',
    '[c3a12] a crashed-then-rerun report in the mutant loop -> its row''s note says so')
if (-not (Get-Command Get-WpCrashNote -ErrorAction SilentlyContinue)) {
    foreach ($n in $c12) { Check $n $false 'no Get-WpCrashNote in this runner (no crash rerun)' }
} else {
$kc = New-Case 'x-crash'
$tr = [ordered]@{ id = 'wpCrash'; check = 'wpDemo'; report = 'wpCrash.json'; type = 'recording'; batch = $null; network = $false; measured = 'measured'
    run = [ordered]@{ args = @('--wp-open', 'offline:cid:1'); prefs = @(); planPrefs = $true; profile = 'fresh'; asr = $false; minutes = 1 }
    fields = @((F 'branch')); uiErrors = [ordered]@{ status = 'must-same' } } | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
$planStub = @{ prefs = @() }
$lq = @{ plan = [System.Collections.Generic.Queue[object]]::new(); calls = 0 }
$script:wpCrashPause = 0; $script:wpCrashRetryPause = 0
$script:wpLaunch = {
    param([string]$exe, [string[]]$argv, [int]$minutes)
    $lq.calls++
    $step = $lq.plan.Dequeue()
    if ($step -eq 'report') {
        $out = $argv[[array]::IndexOf($argv, '--out') + 1].Trim('"')
        Write-Json ([ordered]@{ checks = @((Chk)) }) $out
        return @{ exit = 0; timedOut = $false }
    }
    return @{ exit = [int]$step; timedOut = $false }
}
function Launch([object[]]$steps, [string]$name) {
    $lq.plan.Clear(); $lq.calls = 0; foreach ($x in $steps) { $lq.plan.Enqueue($x) }
    $rep = Invoke-WpSelfTest 'C:/fake/LibrePili.exe' $tr $planStub (Join-Path $kc.dir $name) 'crash' $root
    return @{ rep = $rep; calls = $lq.calls; there = (Test-Path -LiteralPath $rep); note = (Get-WpCrashNote $rep)
        sidecar = $(if (Test-Path -LiteralPath "$rep.crash.json") { Read-WpJson "$rep.crash.json" } else { $null }) }
}
$e1 = Launch @(-1073741819, 'report') 'once'
Check $c12[0] ($e1.calls -eq 2 -and $e1.there -and @($e1.sidecar['crashes']).Count -eq 1 -and $e1.note -match '^crashed once') "calls $($e1.calls), report $($e1.there), note: $($e1.note)"
$e2 = Launch @(-1073741819, -1073741819, 'report') 'twice'
Check $c12[1] ($e2.calls -eq 2 -and -not $e2.there -and @($e2.sidecar['crashes']).Count -eq 2 -and $e2.note -match 'crashed 2 times') "calls $($e2.calls), report $($e2.there), note: $($e2.note)"
$e3 = Launch @(1, 'report') 'exit1'
Check $c12[2] ($e3.calls -eq 1 -and -not $e3.there -and $null -eq $e3.sidecar) "calls $($e3.calls), sidecar $($null -ne $e3.sidecar)"
# the same Invoke-WpSelfTest under the mutant loop's catcher: the crash note in the row
$crashRun = { param([string]$runDir, [string]$runTag) $lq.plan.Clear(); $lq.calls = 0; $lq.plan.Enqueue(-1073741819); $lq.plan.Enqueue('report'); return Invoke-WpSelfTest 'C:/fake/LibrePili.exe' $tr $planStub $runDir $runTag $root }
$cr = Invoke-WpCatcher $tr @('branch') $e1.rep $rootA $rootA '' $crashRun (Join-Path $kc.dir 'catch') 'wp-crash'
Check $c12[3] ($cr['note'] -match 'crashed once') "$($cr.result), note: $($cr['note'])"
}

# ================================================================ summary
$bad = @($results | Where-Object { -not $_.ok })
''
"$($results.Count - $bad.Count) of $($results.Count) cases pass"
if ($bad.Count) {
    "FAILED: $(@($bad | ForEach-Object case) -join '; ')"
    "scratch kept: $scratch"
    exit 1
}
if ($Keep) { "scratch kept: $scratch" } else { Remove-Item -LiteralPath $scratch -Recurse -Force }
exit 0
