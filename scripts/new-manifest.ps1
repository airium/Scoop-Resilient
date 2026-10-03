#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v?[0-9][0-9A-Za-z.+_-]*$')]
    [string] $Version,

    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $License,

    [string] $OutputPath,

    [string] $ArchivePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot

if (!$Repository) {
    $remote = (& git -C $projectRoot config --get remote.origin.url) -join ''
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remote)) {
        throw "No origin remote is configured. Pass -Repository OWNER/Scoop-Resilient explicitly."
    }

    if ($remote.Trim() -notmatch 'github\.com[/:](?<owner>[A-Za-z0-9_.-]+)/(?<name>[A-Za-z0-9_.-]+?)(?:\.git)?/?$') {
        throw "Could not derive a GitHub repository from origin: $remote"
    }
    $Repository = "$($Matches.owner)/$($Matches.name)"
}

$normalizedVersion = $Version -replace '^v', ''
$tag = "v$normalizedVersion"
$homepage = "https://github.com/$Repository"
$downloadUrl = "$homepage/releases/download/$tag/scoop-resilient-$normalizedVersion.zip"
$autoupdateUrl = "$homepage/releases/download/v`$version/scoop-resilient-`$version.zip"
if (!$ArchivePath) {
    $ArchivePath = Join-Path $projectRoot "dist/scoop-resilient-$normalizedVersion.zip"
    & "$PSScriptRoot/build-release.ps1" -Version $normalizedVersion -OutputPath $ArchivePath
}
$hash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()

$manifest = [ordered]@{
    '$schema' = 'https://raw.githubusercontent.com/ScoopInstaller/Scoop/master/schema.json'
    version = $normalizedVersion
    description = 'Resilient Scoop update and cleanup commands'
    homepage = $homepage
    license = $License
    url = $downloadUrl
    hash = $hash
    bin = @('scoop-upgrade.ps1', 'scoop-tidy.ps1')
    checkver = [ordered]@{
        github = $homepage
    }
    autoupdate = [ordered]@{
        url = $autoupdateUrl
    }
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $projectRoot 'bucket/scoop-resilient.json'
} elseif (![IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $projectRoot $OutputPath
}

$outputDirectory = Split-Path -Parent $OutputPath
if (!(Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

$json = $manifest | ConvertTo-Json -Depth 5
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($OutputPath, "$json`n", $utf8NoBom)

Write-Host "Wrote $OutputPath" -ForegroundColor Green
Write-Host "SHA256: $hash"
