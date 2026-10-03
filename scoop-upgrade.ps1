#Requires -Version 5.1
# Usage: scoop upgrade <app> [options]
# Summary: Update apps or Scoop itself, continuing after app failures
# Help: With no app, synchronize Scoop and buckets. Use * or -a for all local apps.
# Each app update runs in its own process and failures do not stop the next app.
# Options:
#   -a, --all              Update all local apps (include global apps with -g)
#   -g, --global           Select globally installed apps
#   -f, --force            Force update, including version-pin resolution
#   -i, --independent      Do not install dependencies automatically
#   -k, --no-cache         Do not use the download cache
#   -s, --skip-hash-check  Disable hash verification explicitly
#   -q, --quiet            Pass quiet mode to Scoop
#   --no-elevation-prompt  Skip global apps instead of offering UAC

# Parse raw arguments so Scoop-style short groups (-ak) and long options work in
# both PowerShell 5.1 and 7, without PowerShell parameter abbreviation conflicts.
$script:EntryPoint = $PSCommandPath
. "$PSScriptRoot/lib/common.ps1"
. "$PSScriptRoot/lib/commands.ps1"
$script:Operation = 'upgrade'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
if ($args.Count -gt 0 -and $args[0] -eq '--internal-plan-worker') {
    if ($args.Count -ne 3) { Write-Error 'Invalid planning request.'; exit 2 }
    . "$PSScriptRoot/lib/plan.ps1"
    exit (Invoke-PreflightWorker -RequestPath $args[1] -OutputPath $args[2])
}
if ($args.Count -gt 0 -and $args[0] -eq '--internal-elevated-worker') {
    if ($args.Count -ne 3) { Write-Error 'Invalid elevated worker request.'; exit 2 }
    exit (Invoke-ElevatedWorkerMode -Payload $args[1] -OutputPath $args[2])
}

exit (Invoke-MaintenanceCommand -Operation 'upgrade' -CommandArguments $args)
