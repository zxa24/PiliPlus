param(
    [string]$Arg = '',
    # LibrePili: a local build (the user's own copy): only the version data
    # for --dart-define-from-file, written to -Out; pubspec.yaml and
    # GITHUB_ENV are left alone. Prints "name+code" for --build-name/-number.
    [switch]$Local,
    [string]$Out = 'pili_release.json'
)

try {
    $versionName = $null

    $versionCode = [int](git rev-list --count HEAD).Trim()

    $commitHash = (git rev-parse HEAD).Trim()

    foreach ($line in (Get-Content -Path 'pubspec.yaml' -Encoding UTF8)) {
        if ($line -match '^\s*version:\s*([\d\.]+)') {
            $versionName = $matches[1]
            break
        }
    }

    if ($null -eq $versionName) {
        throw 'version not found'
    }

    # LibrePili (user 2026-10-21, 「每次构建都加 0.0.1」, ②): past the release
    # tagged with pubspec's version, the patch grows by the commits since it
    # — 0.3.0 and 41 commits on is 0.3.41 — with nothing committed for it.
    # At the tag itself, or before the version has a tag (pubspec bumped for
    # the next release), pubspec's version as it is.
    $base = $versionName
    $since = git rev-list --count "refs/tags/$base..HEAD" 2>$null
    if ($LASTEXITCODE -eq 0 -and [int]$since -gt 0) {
        $parts = $base.Split('.')
        while ($parts.Count -lt 3) { $parts += '0' }
        $parts[2] = [string]([int]$parts[2] + [int]$since)
        $versionName = $parts[0..2] -join '.'
    }
    $global:LASTEXITCODE = 0

    if ($Arg -eq 'android') {
        $versionName += '-' + $commitHash.Substring(0, 9)
    }

    $buildTime = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds())

    $data = @{
        'pili.name' = $versionName
        'pili.code' = $versionCode
        'pili.hash' = $commitHash
        'pili.time' = $buildTime
    }

    $data | ConvertTo-Json -Compress | Out-File $Out -Encoding UTF8

    if ($Local) {
        # the name without the android suffix: --build-name takes x.y.z
        "$($versionName.Split('-')[0])+$versionCode"
        exit 0
    }

    $updatedContent = foreach ($line in (Get-Content -Path 'pubspec.yaml' -Encoding UTF8)) {
        if ($line -match '^\s*version:\s*([\d\.]+)') {
            "version: $versionName+$versionCode"
        }
        else {
            $line
        }
    }

    $updatedContent | Set-Content -Path 'pubspec.yaml' -Encoding UTF8

    Add-Content -Path $env:GITHUB_ENV -Value "version=$versionName+$versionCode"
}
catch {
    Write-Error "Prebuild Error: $($_.Exception.Message)"
    exit 1
}
