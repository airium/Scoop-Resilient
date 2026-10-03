# Read-only preflight. One process loads Scoop once for the entire selection.
function Invoke-PreflightWorker {
    param([string] $RequestPath, [string] $OutputPath)
    $jobs = [System.Collections.Generic.List[object]]::new()
    $results = [System.Collections.Generic.List[object]]::new()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $script:Operation = [string]$request.Operation
        if ($script:Operation -notin @('upgrade', 'tidy')) { throw 'Invalid planning operation.' }
        if ($env:SCOOP_RESILIENT_TEST_WORKER_LOG) { Add-Content -LiteralPath $env:SCOOP_RESILIENT_TEST_WORKER_LOG -Value "preflight $script:Operation" }
        $core = [string]$request.CoreDirectory
        Set-StrictMode -Off
        . (Join-Path $core 'lib/core.ps1')
        $ErrorActionPreference = 'Stop'
        $partials = @()
        $cacheScans = 0
        if ($script:Operation -eq 'upgrade') {
            foreach ($library in @('buckets', 'versions', 'manifest')) {
                $path = Join-Path $core "lib/$library.ps1"
                if (Test-Path -LiteralPath $path -PathType Leaf) { . $path }
            }
            foreach ($target in @($request.Targets)) {
                if ($target.Name -notmatch '^[A-Za-z0-9_.-]+$' -or $target.Name -in @('.', '..', 'scoop')) { throw 'Invalid preflight app name.' }
                $run = $true
                if (!(Test-AppInfoFlag -Info ([string]$target.Info) -Flag 'Held package') -and '--force' -notin $request.Options) {
                    try {
                        # Remote/custom manifests are left to the isolated update
                        # worker; planning must not perform downloads or generate pins.
                        $info = install_info $target.Name (Select-CurrentVersion -AppName $target.Name -Global:$target.Global) $target.Global
                        if ($null -ne $info -and (!$info.url -or $info.url -notmatch '^(ht|f)tps?://|\\\\')) {
                            $status = app_status $target.Name $target.Global
                            if ($status.hold) {
                                [void]$results.Add((New-Outcome -Name $target.Name -Global:$target.Global -Status Skipped -Category Held -Reason 'The package is held.'))
                                $run = $false
                            } elseif ($status.installed -and !$status.failed -and !$status.removed -and
                                $status.version -and $status.latest_version -and !$status.outdated) {
                                [void]$results.Add((New-Outcome -Name $target.Name -Global:$target.Global -Status Current -Category Current -Reason 'The latest version is already installed.'))
                                $run = $false
                            }
                        }
                    } catch {
                        # Inconclusive status is not a reason to hide an update
                        # failure. Let the isolated app worker diagnose it.
                        $run = $true
                    }
                }
                if (Test-AppInfoFlag -Info ([string]$target.Info) -Flag 'Held package') {
                    [void]$results.Add((New-Outcome -Name $target.Name -Global:$target.Global -Status Skipped -Category Held -Reason 'The package is held.'))
                } elseif ($run) { [void]$jobs.Add($target) }
            }
        } else {
            . "$PSScriptRoot/tidy.ps1"
            $cacheIndex = @{}
            $cacheUnavailable = $false
            if ('--cache' -in $request.Options) {
                try {
                    if (Test-Path -LiteralPath $cachedir -PathType Container -ErrorAction Stop) {
                        $cacheScans = 1
                        if ($env:SCOOP_RESILIENT_TEST_WORKER_LOG) { Add-Content -LiteralPath $env:SCOOP_RESILIENT_TEST_WORKER_LOG -Value 'cache-scan' }
                        foreach ($file in Get-ChildItem -LiteralPath $cachedir -File -Force -ErrorAction Stop) {
                            if ($file.Name.EndsWith('.download', [StringComparison]::OrdinalIgnoreCase)) { $partials += $file.Name; continue }
                            $name = ($file.Name -split '#', 2)[0]
                            if (!$cacheIndex.ContainsKey($name)) { $cacheIndex[$name] = [System.Collections.Generic.List[string]]::new() }
                            [void]$cacheIndex[$name].Add($file.Name)
                        }
                    }
                } catch {
                    $cacheUnavailable = $true
                    [void]$results.Add((New-Outcome -Name 'Download cache' -Status Failed -Category Cache -Reason $_.Exception.Message -ExitCode 1))
                }
            }
            $current = @{}
            $cacheHandled = @{}
            foreach ($target in @($request.Targets)) {
                $name = [string]$target.Name
                $global = [bool]$target.Global
                if ($name -notmatch '^[A-Za-z0-9_.-]+$' -or $name -in @('.', '..', 'scoop')) { throw 'Invalid preflight app name.' }
                $key = "$global/$name"
                $directory = appdir $name $global
                if (!$current.ContainsKey($key)) {
                    try { $current[$key] = @{ Version = Get-TidyCurrentVersion $directory; Error = '' } }
                    catch { $current[$key] = @{ Version = ''; Error = $_.Exception.Message } }
                }
                if ($current[$key].Error) {
                    if ($global -and !(Test-IsAdministrator)) {
                        # An elevated worker may be able to read metadata that the
                        # original process cannot. Revalidate there before deletion.
                        [void]$jobs.Add([PSCustomObject]@{ Name = $name; Global = $global; CachePlanned = $false; CacheNames = @(); VersionsPlanned = $false; VersionNames = @() })
                    } else {
                        [void]$results.Add((New-Outcome -Name $name -Global:$global -Status Skipped -Category Metadata -Reason "Cleanup skipped: $($current[$key].Error)"))
                    }
                    continue
                }
                $needsWork = $false
                $versionsPlanned = $true
                $versionNames = @()
                try {
                    $versionNames = @(Get-ChildItem -LiteralPath $directory -Directory -Force -ErrorAction Stop |
                        Where-Object { $_.Name -ne 'current' -and $_.Name -ne $current[$key].Version } | ForEach-Object { $_.Name })
                    $needsWork = $versionNames.Count -gt 0
                } catch { $needsWork = $true; $versionsPlanned = $false }
                $cacheNames = @()
                $hasSkip = $false
                if (!$cacheUnavailable -and $cacheIndex.ContainsKey($name) -and !$cacheHandled.ContainsKey($name)) {
                    $cacheHandled[$name] = $true
                    $versions = @($current[$key].Version)
                    try {
                        $otherKey = "$(!$global)/$name"
                        $otherDirectory = appdir $name (!$global)
                        if (Test-Path -LiteralPath $otherDirectory -PathType Container -ErrorAction Stop) {
                            if (!$current.ContainsKey($otherKey)) {
                                try { $current[$otherKey] = @{ Version = Get-TidyCurrentVersion $otherDirectory; Error = '' } }
                                catch { $current[$otherKey] = @{ Version = ''; Error = $_.Exception.Message } }
                            }
                            if ($current[$otherKey].Error) { throw $current[$otherKey].Error }
                            $versions += $current[$otherKey].Version
                        }
                        foreach ($fileName in $cacheIndex[$name]) {
                            $keep = $false
                            foreach ($version in $versions) {
                                if ($fileName.StartsWith("$name#$version#", [StringComparison]::OrdinalIgnoreCase)) { $keep = $true; break }
                            }
                            if (!$keep) { $cacheNames += $fileName }
                        }
                    } catch {
                        $hasSkip = $true
                        [void]$results.Add((New-Outcome -Name "$name/cache" -Global:$global -Status Skipped -Category Metadata -Reason "Cache retained: $($_.Exception.Message)"))
                    }
                }
                if ($needsWork -or $cacheNames.Count) {
                    [void]$jobs.Add([PSCustomObject]@{ Name = $name; Global = $global; CachePlanned = $true; CacheNames = $cacheNames; VersionsPlanned = $versionsPlanned; VersionNames = $versionNames })
                } elseif (!$hasSkip) {
                    [void]$results.Add((New-Outcome -Name $name -Global:$global -Status Current -Category Clean -Reason 'No obsolete versions or selected cache files.'))
                }
            }
        }
        $timer.Stop()
        Write-JsonFile -Path $OutputPath -Value @{
            Success = $true; Jobs = [object[]]$jobs.ToArray(); Results = [object[]]$results.ToArray()
            PartialNames = [string[]]$partials
            Statistics = @{ Targets = @($request.Targets).Count; Jobs = $jobs.Count; CacheScans = $cacheScans; Milliseconds = $timer.ElapsedMilliseconds }
        }
        return 0
    } catch {
        Write-JsonFile -Path $OutputPath -Value @{ Success = $false; Error = $_.Exception.Message }
        return 2
    }
}
