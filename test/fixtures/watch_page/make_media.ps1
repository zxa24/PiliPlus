# Makes the watch-page offline media (design feature-logs/watch-page-shell/
# design.md §5 S0b 「素材与前置条件」): the video files and covers the
# snapshots beside this script place into a profile (place.json). They are
# not in the repository; they go to the media folder media.json names
# ("root", %VAR% expanded; default %LOCALAPPDATA%\LibrePili-test-media\
# watch_page), outside the repository and outside lib/.
#
#   pwsh -NoProfile -File test/fixtures/watch_page/make_media.ps1
#        [-Root <folder>] [-Force] [-Update]
#
# Each file is made with fixed ffmpeg arguments (below; bit-exact flags,
# one thread) and its SHA-256 checked against media.json. A file already
# there with the recorded hash is kept (-Force makes it again). A hash
# that differs (another ffmpeg build can encode other bytes) is an error,
# exit 1: the runner's restore refuses such a file too, and report folders
# made with other media are not compared (their manifests' media differ).
# -Update records the new hashes and the ffmpeg version in media.json
# instead; commit that change (git add -f) with a note of why.
#
# ffmpeg: winget's Gyan.FFmpeg build (allowed through the machine's
# firewall; nothing here touches the network). ffprobe is not used.
param([string]$Root = '', [switch]$Force, [switch]$Update)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here = $PSScriptRoot
$manifestFile = Join-Path $here 'media.json'
$manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if (-not $Root) { $Root = [Environment]::ExpandEnvironmentVariables("$($manifest['root'])") }
New-Item -ItemType Directory -Force $Root | Out-Null
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$version = "$((& $ffmpeg -hide_banner -version)[0])".Trim()

# a 6 s clip: the moving test pattern (frame counter in it) and a 440 Hz
# tone, H.264 + AAC in MP4 with the index first, about 100 KB
function Get-ClipArgs([int]$w, [int]$h) {
    return @(
        '-f', 'lavfi', '-i', "testsrc2=size=${w}x${h}:rate=25:duration=6",
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=6',
        '-map', '0:v', '-map', '1:a',
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '32', '-pix_fmt', 'yuv420p',
        '-g', '50', '-threads', '1',
        '-c:a', 'aac', '-b:a', '48k', '-ac', '1',
        '-flags:v', '+bitexact', '-flags:a', '+bitexact', '-fflags', '+bitexact',
        '-map_metadata', '-1', '-movflags', '+faststart'
    )
}
# one frame of the same pattern, the size the list's 160x100 thumbnail
# decodes from
function Get-CoverArgs([int]$w, [int]$h) {
    return @(
        '-f', 'lavfi', '-i', "testsrc2=size=${w}x${h}:rate=1:duration=1",
        '-frames:v', '1', '-q:v', '5', '-pix_fmt', 'yuvj420p',
        '-flags:v', '+bitexact', '-fflags', '+bitexact', '-map_metadata', '-1'
    )
}
$specs = [ordered]@{
    'landscape.mp4'       = Get-ClipArgs 640 360
    'portrait.mp4'        = Get-ClipArgs 360 640
    'cover_landscape.jpg' = Get-CoverArgs 320 180
    'cover_portrait.jpg'  = Get-CoverArgs 180 320
}

$files = if ($manifest['files']) { $manifest['files'] } else { [ordered]@{} }
$bad = [System.Collections.Generic.List[string]]::new()
$changed = $false
foreach ($name in $specs.Keys) {
    $out = Join-Path $Root $name
    $want = if ($files.Contains($name)) { "$($files[$name]['sha256'])" } else { '' }
    $have = if (Test-Path -LiteralPath $out) { (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash } else { '' }
    if ($Force -or -not $have -or $have -ne $want) {
        # written beside, then moved: an interrupted run leaves no half file
        # under the final name
        $tmp = Join-Path $Root "$name.part$([IO.Path]::GetExtension($name))"
        & $ffmpeg -hide_banner -loglevel error -y @($specs[$name]) $tmp
        if ($LASTEXITCODE) { throw "ffmpeg failed for $name (exit $LASTEXITCODE)" }
        Move-Item -LiteralPath $tmp -Destination $out -Force
        $have = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash
    }
    $bytes = (Get-Item -LiteralPath $out).Length
    if ($have -ne $want) {
        if ($Update) {
            $files[$name] = [ordered]@{ sha256 = $have; bytes = $bytes }
            $changed = $true
        } else {
            $bad.Add("$name`: made $have, media.json records $(if ($want) { $want } else { 'nothing' })")
        }
    }
    Write-Host ("{0,-20} {1} {2,8} B {3}" -f $name, $have, $bytes, $(if ($have -eq $want) { 'ok' } elseif ($Update) { 'recorded' } else { 'DIFFERS' }))
}
if ($changed) {
    $manifest['files'] = $files
    $manifest['ffmpeg'] = $version
    $text = ($manifest | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n"
    [IO.File]::WriteAllText($manifestFile, $text, [Text.UTF8Encoding]::new($false))
    Write-Host "media.json updated ($version)"
}
Write-Host "media folder: $Root"
if ($bad.Count) {
    Write-Host "made with: $version; media.json: $($manifest['ffmpeg'])"
    $bad | ForEach-Object { Write-Host "  $_" }
    exit 1
}
