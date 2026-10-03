# Runs only in the isolated cleanup worker. Scoop's core supplies configured
# app/cache paths; deletion never executes manifest hooks or follows links.

function Read-TidyMetadata {
    param([string] $Directory, [string] $Kind)
    foreach ($name in @("scoop-$Kind.json", "$Kind.json")) {
        $path = Join-Path $Directory $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
    }
    throw "Missing $Kind metadata in $Directory"
}

function Get-TidyCurrentVersion {
    param([string] $AppDirectory)
    $root = Get-Item -LiteralPath $AppDirectory -Force -ErrorAction Stop
    if (!$root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The app directory must be a regular directory.'
    }
    $AppDirectory = $root.FullName
    if (get_config NO_JUNCTION) {
        # Match Scoop's timestamp-based selection for NO_JUNCTION, but require
        # readable metadata rather than guessing when an installation is damaged.
        $candidates = foreach ($directory in Get-ChildItem -LiteralPath $AppDirectory -Directory -Force -ErrorAction Stop) {
            if ($directory.Name -eq 'current' -or $directory.Name -like '_*.old*' -or
                ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            $info = $null
            foreach ($name in @('scoop-install.json', 'install.json')) {
                $path = Join-Path $directory.FullName $name
                if (Test-Path -LiteralPath $path -PathType Leaf) { $info = Get-Item -LiteralPath $path -ErrorAction Stop; break }
            }
            if ($info) { [PSCustomObject]@{ Directory = $directory; Updated = $info.LastWriteTimeUtc } }
        }
        $candidates = @($candidates | Sort-Object Updated)
        if (!$candidates.Count) { throw 'No installation metadata identifies a current version.' }
        if ($candidates.Count -gt 1 -and $candidates[-1].Updated -eq $candidates[-2].Updated) {
            throw 'Installation timestamps do not identify a unique current version.'
        }
        $selected = $candidates[-1].Directory
        $null = Read-TidyMetadata -Directory $selected.FullName -Kind 'install'
        $manifest = Read-TidyMetadata -Directory $selected.FullName -Kind 'manifest'
        $version = [string]$manifest.version
        if ($version -ne $selected.Name -and !($version -eq 'nightly' -and $selected.Name -like 'nightly-*')) {
            throw 'The selected version directory and manifest disagree.'
        }
        $existingLink = $null
        try { $existingLink = Get-Item -LiteralPath (Join-Path $AppDirectory 'current') -Force -ErrorAction Stop }
        catch { if ($_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::ObjectNotFound) { throw } }
        if ($existingLink -and ($existingLink.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $target = [string]@($existingLink.Target)[0]
            if (![IO.Path]::IsPathRooted($target)) { $target = Join-Path $AppDirectory $target }
            if (![string]::Equals([IO.Path]::GetFullPath($target), $selected.FullName, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'NO_JUNCTION selection disagrees with the existing current link.'
            }
        }
        return $selected.Name
    }
    $currentPath = Join-Path $AppDirectory 'current'
    $current = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
    $manifest = Read-TidyMetadata -Directory $currentPath -Kind 'manifest'
    $version = [string]$manifest.version
    if ($version -notmatch '^[A-Za-z0-9_.+-]+$' -or $version -in @('.', '..', 'current')) {
        throw 'The current manifest has no valid version.'
    }
    if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $targets = @($current.Target)
        if ($targets.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$targets[0])) {
            throw 'The current link has no unambiguous target.'
        }
        $target = [string]$targets[0]
        if (![IO.Path]::IsPathRooted($target)) { $target = Join-Path $AppDirectory $target }
        $target = [IO.Path]::GetFullPath($target).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $parent = [IO.Path]::GetFullPath($AppDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if (![string]::Equals((Split-Path -Parent $target), $parent, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The current link points outside its app directory.'
        }
        $targetName = Split-Path -Leaf $target
        if ($version -eq 'nightly' -and $targetName -like 'nightly-*') { $version = $targetName }
        if ($version -ne $targetName) { throw 'The current link target and manifest version disagree.' }
    }
    $versionPath = Join-Path $AppDirectory $version
    $versionDirectory = Get-Item -LiteralPath $versionPath -Force -ErrorAction Stop
    if (!$versionDirectory.PSIsContainer -or ($versionDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The retained version must be a regular directory.'
    }
    return $version
}

function Remove-TidyTree {
    param([string] $Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        # Directory.Delete(path, false) removes the link itself, including Windows
        # junctions. Never use recursive Remove-Item on a reparse point in 5.1.
        if ($env:OS -eq 'Windows_NT' -and ($item.Attributes -band [IO.FileAttributes]::ReadOnly)) {
            & attrib.exe -R /L $item.FullName
            if ($LASTEXITCODE -ne 0) { throw "Could not clear link attributes: $Path" }
        }
        if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName, $false) }
        else { [IO.File]::Delete($item.FullName) }
        return
    }
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop) {
            Remove-TidyTree -Path $child.FullName
        }
    }
    # All children have been handled explicitly; this deletion is non-recursive.
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
}

function Add-TidyRemoval {
    param([string] $Path, [string] $Label, [string] $Category, [bool] $Global,
        [System.Collections.Generic.List[object]] $Results)
    try {
        Write-Host "Removing $Label..."
        Remove-TidyTree -Path $Path
        [void]$Results.Add((New-Outcome -Name $Label -Global:$Global -Status Completed -Category $Category -Reason 'Removed.'))
    } catch {
        [void]$Results.Add((New-Outcome -Name $Label -Global:$Global -Status Failed -Category $Category -Reason $_.Exception.Message -ExitCode 1))
        Write-Warning "Could not remove $Label. Continuing."
    }
}

function Get-TidyPlannedFile {
    param([string] $Directory, [string[]] $Names, [switch] $Directories)
    if ($null -eq $Names -or !$Names.Count) { return }
    foreach ($name in @($Names)) {
        if (!$name -or $name -in @('.', '..') -or $name.IndexOfAny([char[]]@('/', '\', ':')) -ge 0) {
            throw 'Invalid planned cleanup name.'
        }
        $path = Join-Path $Directory $name
        try {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ([bool]$item.PSIsContainer -ne [bool]$Directories) { throw "Planned cleanup item changed type: $name" }
            $item
        } catch {
            if ($_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::ObjectNotFound) { throw }
        }
    }
}

function Invoke-TidyApp {
    param($Request, [System.Collections.Generic.List[object]] $Results)
    $name = [string]$Request.Name
    $global = [bool]$Request.Global
    $appDirectory = appdir $name $global
    try { $version = Get-TidyCurrentVersion -AppDirectory $appDirectory }
    catch {
        [void]$Results.Add((New-Outcome -Name $name -Global:$global -Status Skipped -Category Metadata -Reason "Cleanup skipped: $($_.Exception.Message)"))
        return
    }
    $before = $Results.Count
    try {
        $directories = if ($Request.VersionsPlanned) {
            @(Get-TidyPlannedFile -Directory $appDirectory -Names @($Request.VersionNames) -Directories)
        } else { @(Get-ChildItem -LiteralPath $appDirectory -Directory -Force -ErrorAction Stop) }
        foreach ($directory in $directories) {
            if ($directory.Name -eq 'current' -or $directory.Name -eq $version) { continue }
            if ((Get-TidyCurrentVersion -AppDirectory $appDirectory) -ne $version) {
                throw 'The current version changed during cleanup; remaining versions were retained.'
            }
            Add-TidyRemoval -Path $directory.FullName -Label "$name/$($directory.Name)" -Category Version -Global:$global -Results $Results
        }
    } catch {
        [void]$Results.Add((New-Outcome -Name $name -Global:$global -Status Failed -Category Version -Reason $_.Exception.Message -ExitCode 1))
    }
    if ($Request.Cache -and (!$Request.CachePlanned -or @($Request.CacheNames).Count)) {
        # The download cache is shared by local and global installations. Retain
        # both active versions even when only one installation was selected.
        $retained = @($version)
        $cacheSafe = $true
        try {
            $retained += Get-TidyCurrentVersion -AppDirectory $appDirectory
            $other = appdir $name (!$global)
            if (Test-Path -LiteralPath $other -PathType Container) { $retained += Get-TidyCurrentVersion -AppDirectory $other }
        } catch {
            $cacheSafe = $false
            [void]$Results.Add((New-Outcome -Name "$name/cache" -Global:$global -Status Skipped -Category Metadata -Reason "Cache retained: $($_.Exception.Message)"))
        }
        if ($cacheSafe -and (Test-Path -LiteralPath $cachedir -PathType Container)) {
            try {
                $files = if ($Request.CachePlanned) {
                    @(Get-TidyPlannedFile -Directory $cachedir -Names @($Request.CacheNames))
                } else { @(Get-ChildItem -LiteralPath $cachedir -File -Force -ErrorAction Stop) }
                foreach ($file in $files) {
                    if (!$file.Name.StartsWith("$name#", [StringComparison]::OrdinalIgnoreCase)) { continue }
                    $keep = $false
                    foreach ($currentVersion in $retained) {
                        if ($file.Name.StartsWith("$name#$currentVersion#", [StringComparison]::OrdinalIgnoreCase)) { $keep = $true; break }
                    }
                    if (!$keep) { Add-TidyRemoval -Path $file.FullName -Label "$name/cache/$($file.Name)" -Category Cache -Global:$global -Results $Results }
                }
            } catch {
                [void]$Results.Add((New-Outcome -Name "$name/cache" -Global:$global -Status Failed -Category Cache -Reason $_.Exception.Message -ExitCode 1))
            }
        }
    }
    if ($Results.Count -eq $before) {
        [void]$Results.Add((New-Outcome -Name $name -Global:$global -Status Current -Category Clean -Reason 'No obsolete versions or selected cache files.'))
    }
}

function Invoke-TidyWorker {
    param([string] $RequestPath, [string] $OutputPath)
    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($env:SCOOP_RESILIENT_TEST_WORKER_LOG) {
            $kind = if ($request.PartialDownloads) { 'partial-downloads' } else { "$($request.Global)/$($request.Name)" }
            Add-Content -LiteralPath $env:SCOOP_RESILIENT_TEST_WORKER_LOG -Value "tidy $kind"
        }
        if (!$request.PartialDownloads -and ([string]$request.Name -notmatch '^[A-Za-z0-9_.-]+$' -or $request.Name -in @('.', '..', 'scoop'))) {
            throw 'Invalid cleanup app name.'
        }
        $corePath = Join-Path ([string]$request.CoreDirectory) 'lib/core.ps1'
        if (!(Test-Path -LiteralPath $corePath -PathType Leaf)) { throw 'Installed Scoop core.ps1 was not found.' }
        # Scoop's helpers expect strict mode off. Load only core (paths/config),
        # with no installer/download hooks, and keep it confined to this child.
        Set-StrictMode -Off
        . $corePath
        $ErrorActionPreference = 'Stop'
        if ($request.Global -and !(Test-IsAdministrator)) { throw 'Administrator rights are required for global cleanup.' }
        if ($request.PartialDownloads) {
            if (Test-Path -LiteralPath $cachedir -PathType Container) {
                $files = if ($request.PartialPlanned) {
                    @(Get-TidyPlannedFile -Directory $cachedir -Names @($request.PartialNames))
                } else { @(Get-ChildItem -LiteralPath $cachedir -File -Filter '*.download' -Force -ErrorAction Stop) }
                foreach ($file in $files) {
                    if (!$file.Name.EndsWith('.download', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid partial download job.' }
                    Add-TidyRemoval -Path $file.FullName -Label "Partial downloads/$($file.Name)" -Category Cache -Global:$false -Results $results
                }
            }
        } else { Invoke-TidyApp -Request $request -Results $results }
        Write-JsonFile -Path $OutputPath -Value @{ Success = $true; Results = [object[]]$results.ToArray() }
        return [int](@($results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0)
    } catch {
        Write-JsonFile -Path $OutputPath -Value @{ Success = $false; Error = $_.Exception.Message; Results = [object[]]$results.ToArray() }
        return 2
    }
}
