#Requires -Version 5.1
# Usage: scoop tidy <app> [options]
# Summary: Remove old app versions and cache, continuing after deletion failures
# Help: Remove old app versions; failures do not stop remaining removals.
# The current version and persisted data are retained. Uncertain metadata is skipped.
# Options:
#   -a, --all              Clean all local apps (include global apps with -g)
#   -g, --global           Select globally installed apps
#   -k, --cache            Remove obsolete cache and leftover partial downloads
#   --no-elevation-prompt  Skip global apps instead of offering UAC

# Parse raw arguments so Scoop-style short groups (-ak) and long options work in
# both PowerShell 5.1 and 7, without PowerShell parameter abbreviation conflicts.
$script:EntryPoint = $PSCommandPath
. "$PSScriptRoot/lib/common.ps1"
. "$PSScriptRoot/lib/commands.ps1"
$script:Operation = 'tidy'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
if ($args.Count -gt 0 -and $args[0] -eq '--internal-elevated-worker') {
    if ($args.Count -ne 3) { Write-Error 'Invalid elevated worker request.'; exit 2 }
    exit (Invoke-ElevatedWorkerMode -Payload $args[1] -OutputPath $args[2])
}
if ($args.Count -gt 0 -and $args[0] -eq '--internal-tidy-worker') {
    if ($args.Count -ne 3) { Write-Error 'Invalid tidy worker request.'; exit 2 }
    . "$PSScriptRoot/lib/tidy.ps1"
    exit (Invoke-TidyWorker -Payload $args[1] -OutputPath $args[2])
}
exit (Invoke-MaintenanceCommand -Operation 'tidy' -CommandArguments $args)
