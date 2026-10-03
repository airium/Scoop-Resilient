#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) "scoop-package-$PID-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $archive = Join-Path $temp 'scoop-resilient-0.1.0.zip'
    & "$project/scripts/build-release.ps1" -Version 0.1.0 -OutputPath $archive
    $manifestPath = Join-Path $temp 'manifest.json'
    & "$project/scripts/new-manifest.ps1" -Version 0.1.0 -Repository fixture/Scoop-Resilient -License MIT -ArchivePath $archive -OutputPath $manifestPath
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.hash -ne (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Manifest hash must match the uploaded archive.' }
    if (($manifest.bin -join ',') -ne 'scoop-upgrade.ps1,scoop-tidy.ps1') { throw 'Both commands must be shimmed.' }
    if ($manifest.url -ne 'https://github.com/fixture/Scoop-Resilient/releases/download/v0.1.0/scoop-resilient-0.1.0.zip') { throw 'Release asset URL is incorrect.' }
    $expanded = Join-Path $temp 'expanded'
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded
    foreach ($file in @('scoop-upgrade.ps1', 'scoop-tidy.ps1', 'lib/common.ps1', 'lib/commands.ps1', 'lib/tidy.ps1')) {
        if (!(Test-Path -LiteralPath (Join-Path $expanded $file))) { throw "Bundle is missing $file" }
    }
    foreach ($command in @('scoop-upgrade.ps1', 'scoop-tidy.ps1')) {
        $output = @(& (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $expanded $command) --help)
        if ($LASTEXITCODE -ne 0 -or ($output -join "`n") -notmatch 'Usage: scoop') { throw "Packaged $command cannot find its libraries." }
    }
    & "$PSScriptRoot/shims.ps1" -InstallDirectory $expanded -ManifestPath $manifestPath
    Write-Host 'Release bundle tests passed.' -ForegroundColor Green
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
