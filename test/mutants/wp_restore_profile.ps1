# Restores a watch-page profile snapshot by hand, with the same function
# the runner uses before a check's run (run.ps1 Restore-WpProfile): for the
# AC-S0a 核对 runs (design §5 S0a), a manual self-test, or a look at what a
# check starts from.
#
#   pwsh -NoProfile -File test/mutants/wp_restore_profile.ps1
#        -Snapshot test/fixtures/watch_page/landscape -Profile <name>
#
# Then run the app from a slot with `--selftest --profile <name> ...`, and
# afterwards delete %APPDATA%\com.zxa24\LibrePili\selftest-<name> and
# %TEMP%\LibrePili\selftest-<name>. The profile's two folders are emptied
# first. The media must be made first (test/fixtures/watch_page/
# make_media.ps1); a missing file or one with another SHA-256 is refused.
param(
    [Parameter(Mandatory)][string]$Snapshot,
    [Parameter(Mandatory)][string]$Profile
)
$ErrorActionPreference = 'Stop'
if ($Profile -notmatch '^[A-Za-z0-9_.-]+$') { throw "-Profile: letters, digits, _ . - only (it names a folder), not '$Profile'" }
. (Join-Path $PSScriptRoot 'run.ps1') -LoadOnly
$appdata = Restore-WpProfile $Snapshot $Profile
Write-Host "restored $Snapshot into $appdata"
Get-ChildItem -LiteralPath $appdata -Recurse -File | ForEach-Object { Write-Host "  $([System.IO.Path]::GetRelativePath($appdata, $_.FullName))" }
