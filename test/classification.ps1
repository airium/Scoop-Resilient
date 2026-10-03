#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/common.ps1')
$cases = @(
    @{ Name = 'inline admin'; Text = 'Checking hash... OK.', 'Running pre_uninstall script... ERROR clash-verge-rev requires admin rights to update'; Status = 'Failed'; Category = 'Elevation' },
    @{ Name = 'admin nonzero'; Code = 1; Text = 'Running pre_uninstall script... ERROR app requires admin rights to update'; Status = 'Failed'; Category = 'Elevation' },
    @{ Name = 'administrator privileges'; Text = 'Running hook... ERROR This operation requires administrator privileges'; Status = 'Failed'; Category = 'Elevation' },
    @{ Name = 'permission'; Text = 'Running installer... ERROR Access is denied.'; Status = 'Failed'; Category = 'Permission' },
    @{ Name = 'hash'; Text = 'Checking hash... ERROR Hash check failed!'; Status = 'Failed'; Category = 'Hash' },
    @{ Name = 'download'; Text = 'Downloading... ERROR The remote server returned an error: (404) Not Found.'; Status = 'Failed'; Category = 'Download' },
    @{ Name = 'manifest'; Text = 'Loading manifest... ERROR No manifest available for app.', 'app: 1.0 (latest version)'; Status = 'Failed'; Category = 'Manifest' },
    @{ Name = 'architecture'; Text = "Installing... ERROR app doesn't support current architecture!"; Status = 'Failed'; Category = 'Architecture' },
    @{ Name = 'extraction'; Text = 'Extracting... ERROR Failed to extract files from app.zip'; Status = 'Failed'; Category = 'Extraction' },
    @{ Name = 'installer'; Text = 'Running installer... ERROR Installation aborted.'; Status = 'Failed'; Category = 'Installer' },
    @{ Name = 'locked'; Text = 'Unlinking... ERROR Folder in use'; Status = 'Failed'; Category = 'InUse' },
    @{ Name = 'bare aborted'; Text = 'Installation aborted.'; Status = 'Failed'; Category = 'Installer' },
    @{ Name = 'unknown inline'; Text = 'Running hook... ERROR custom hook refused the operation'; Status = 'Failed'; Category = 'Unknown' },
    @{ Name = 'running'; Text = 'ERROR The following instances are still running. Close them and try again.', 'Running process detected, skip updating.'; Status = 'Skipped'; Category = 'Running' },
    @{ Name = 'running with failure'; Text = 'ERROR The following instances are still running. Close them and try again.', 'Running process detected, skip updating.', 'ERROR requires admin rights'; Status = 'Failed'; Category = 'Elevation' },
    @{ Name = 'ignore running warning'; Text = 'WARN The following instances are still running. Scoop is configured to ignore this condition.', 'Installed successfully!'; Status = 'Completed'; Category = 'Success' },
    @{ Name = 'admin warning'; Text = 'WARN Installer added a directory (requires admin permission).', 'Installed successfully!'; Status = 'Completed'; Category = 'Success' },
    @{ Name = 'download recovery'; Text = 'WARN Download failed! (Error 404)', 'Fallback to default downloader...', 'Installed successfully!'; Status = 'Completed'; Category = 'Success' },
    @{ Name = 'positive hash'; Text = 'Checking expected hash SHA256... OK.', 'Installed successfully!'; Status = 'Completed'; Category = 'Success' },
    @{ Name = 'error prose'; Text = 'Installer completed without an error.', 'Installed successfully!'; Status = 'Completed'; Category = 'Success' },
    @{ Name = 'lowercase error'; Text = 'Running hook... error: access denied'; Status = 'Failed'; Category = 'Permission' },
    @{ Name = 'version 404'; Text = 'Updating app 404 -> 405', 'Installed successfully!'; Status = 'Completed'; Category = 'Success' },
    @{ Name = 'current'; Text = 'app: 1.0 (latest version)'; Status = 'Current'; Category = 'Current' },
    @{ Name = 'nonzero unknown'; Code = 23; Text = 'Unexpected termination.'; Status = 'Failed'; Category = 'Unknown' }
)
foreach ($case in $cases) {
    $code = if ($case.ContainsKey('Code')) { $case.Code } else { 0 }
    $result = ConvertTo-AppOutcome -Name app -CommandResult ([PSCustomObject]@{ ExitCode = $code; Output = [string[]]$case.Text })
    if ($result.Status -ne $case.Status -or $result.Category -ne $case.Category) {
        throw "$($case.Name): expected $($case.Status)/$($case.Category), got $($result.Status)/$($result.Category): $($result.Reason)"
    }
    if ($case.Name -eq 'inline admin' -and $result.Reason -ne 'ERROR clash-verge-rev requires admin rights to update') {
        throw 'Inline hook error should retain the original useful diagnostic.'
    }
}
Write-Host "$($cases.Count) output classification regressions passed." -ForegroundColor Green
