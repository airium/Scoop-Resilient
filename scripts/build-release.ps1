#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v?[0-9][0-9A-Za-z.+_-]*$')]
    [string] $Version,
    [string] $OutputPath
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$normalizedVersion = $Version -replace '^v', ''
if (!$OutputPath) { $OutputPath = Join-Path $projectRoot "dist/scoop-resilient-$normalizedVersion.zip" }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$directory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$files = @('scoop-upgrade.ps1', 'scoop-tidy.ps1', 'lib', 'README.md') | ForEach-Object { Join-Path $projectRoot $_ }
if (Test-Path -LiteralPath (Join-Path $projectRoot 'LICENSE')) { $files += Join-Path $projectRoot 'LICENSE' }
Compress-Archive -LiteralPath $files -DestinationPath $OutputPath -Force
Write-Host "Built $OutputPath"
