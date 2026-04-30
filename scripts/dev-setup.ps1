param(
    [switch]$Template,
    [switch]$PlatformDev
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Say {
    param([string]$Message)

    Write-Host $Message
}

function Die {
    param([string]$Message)

    throw "error: $Message"
}

function ConvertTo-NormalizedDirectoryPath {
    param([string]$Directory)

    $trimmed = $Directory.Trim('"')
    $trimChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

    try {
        return ([System.IO.Path]::GetFullPath($trimmed)).TrimEnd($trimChars)
    } catch {
        return $trimmed.TrimEnd($trimChars)
    }
}

function Test-DirectoryOnPath {
    param([string]$Directory)

    if ([string]::IsNullOrWhiteSpace($env:Path)) {
        return $false
    }

    $target = ConvertTo-NormalizedDirectoryPath -Directory $Directory
    foreach ($entry in ($env:Path -split ";")) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }

        $candidate = ConvertTo-NormalizedDirectoryPath -Directory $entry
        if ([string]::Equals($candidate, $target, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Add-PathNote {
    param([string]$InstallDir)

    $target = ConvertTo-NormalizedDirectoryPath -Directory $InstallDir
    foreach ($pathNote in $script:PathNotes) {
        $candidate = ConvertTo-NormalizedDirectoryPath -Directory $pathNote
        if ([string]::Equals($candidate, $target, [System.StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }

    $script:PathNotes += $InstallDir
}

function Move-DirectoryToFrontOfSessionPath {
    param([string]$InstallDir)

    $target = ConvertTo-NormalizedDirectoryPath -Directory $InstallDir
    $remainingEntries = @()

    if (-not [string]::IsNullOrWhiteSpace($env:Path)) {
        foreach ($entry in ($env:Path -split ";")) {
            if ([string]::IsNullOrWhiteSpace($entry)) {
                continue
            }

            $candidate = ConvertTo-NormalizedDirectoryPath -Directory $entry
            if ([string]::Equals($candidate, $target, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $remainingEntries += $entry
        }
    }

    $newEntries = @($InstallDir)
    if ($remainingEntries.Count -gt 0) {
        $newEntries += $remainingEntries
    }

    $updatedPath = [string]::Join(";", $newEntries)
    if (-not [string]::Equals($env:Path, $updatedPath, [System.StringComparison]::Ordinal)) {
        $env:Path = $updatedPath

        Add-PathNote -InstallDir $InstallDir
    }
}

function Find-BuildEipsOnPath {
    foreach ($commandName in @("build-eips", "build-eips.exe")) {
        $commands = @(Get-Command -Name $commandName -CommandType Application -ErrorAction SilentlyContinue)
        if ($commands.Count -gt 0) {
            return $commands[0].Source
        }
    }

    return $null
}

function Find-ZolaOnPath {
    foreach ($commandName in @("zola", "zola.exe")) {
        $commands = @(Get-Command -Name $commandName -CommandType Application -ErrorAction SilentlyContinue)
        if ($commands.Count -gt 0) {
            return $commands[0].Source
        }
    }

    return $null
}

function Assert-InstallDirWritable {
    param([string]$InstallDir)

    $probePath = $null

    try {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        $probeName = ".build-eips-write-test-{0}.tmp" -f ([System.Guid]::NewGuid().ToString("N"))
        $probePath = Join-Path -Path $InstallDir -ChildPath $probeName
        [System.IO.File]::WriteAllText($probePath, "")
        Remove-Item -LiteralPath $probePath -Force
        $probePath = $null
    } catch {
        Die ("install directory cannot be created or written ({0}): {1}" -f $InstallDir, $_.Exception.Message)
    } finally {
        if (($null -ne $probePath) -and (Test-Path -LiteralPath $probePath)) {
            Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-ReleaseDownload {
    param(
        [string]$Url,
        [string]$Destination
    )

    $previousProgressPreference = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    } catch {
        Die ("failed to download {0}: {1}" -f $Url, $_.Exception.Message)
    } finally {
        $ProgressPreference = $previousProgressPreference
    }
}

function Test-AsciiHexHash {
    param([string]$Hash)

    return $Hash -match "^[0-9a-fA-F]{64}$"
}

function Assert-ArchiveChecksum {
    param(
        [string]$ArchivePath,
        [string]$SidecarPath,
        [string]$ArchiveName
    )

    if (-not (Test-Path -LiteralPath $SidecarPath -PathType Leaf)) {
        Die "missing checksum sidecar: $SidecarPath"
    }

    $sidecarText = [System.IO.File]::ReadAllText($SidecarPath)
    $checksumLines = @($sidecarText -split "\r?\n" | Where-Object { $_.Trim().Length -gt 0 })
    if ($checksumLines.Count -ne 1) {
        Die "checksum sidecar must contain exactly one checksum line"
    }

    $fields = @($checksumLines[0].Trim() -split "\s+")
    if ($fields.Count -ne 2) {
        Die "checksum sidecar must contain only a hash and archive filename"
    }

    $expectedHash = $fields[0].ToLowerInvariant()
    $expectedName = $fields[1]

    if (-not (Test-AsciiHexHash -Hash $expectedHash)) {
        Die "checksum sidecar hash must be 64 hex characters"
    }
    if ($expectedName -match '[/\\]') {
        Die "checksum sidecar filename must be a basename"
    }
    if ($expectedName -ne $ArchiveName) {
        Die ("checksum sidecar filename '{0}' does not match '{1}'" -f $expectedName, $ArchiveName)
    }

    $actualHash = (Get-FileHash -Algorithm SHA256 -Path $ArchivePath).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        Die "checksum mismatch for $ArchiveName"
    }
}

function Assert-FileSha256 {
    param(
        [string]$ArchivePath,
        [string]$ExpectedHash,
        [string]$ArchiveName
    )

    $actualHash = (Get-FileHash -Algorithm SHA256 -Path $ArchivePath).Hash.ToLowerInvariant()
    if ($actualHash -ne $ExpectedHash.ToLowerInvariant()) {
        Die "checksum mismatch for $ArchiveName"
    }
}

function Install-BuildEips {
    param(
        [string]$InstallDir,
        [string]$BuildEipsPath
    )

    $archiveName = "build-eips-windows.zip"
    $releaseBaseUrl = "https://github.com/eips-wg/preprocessor/releases/latest/download"
    $tmpRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("build-eips-" + [System.Guid]::NewGuid().ToString("N"))
    $archivePath = Join-Path -Path $tmpRoot -ChildPath $archiveName
    $sidecarPath = Join-Path -Path $tmpRoot -ChildPath "$archiveName.sha256"
    $extractDir = Join-Path -Path $tmpRoot -ChildPath "extract"

    try {
        Assert-InstallDirWritable -InstallDir $InstallDir

        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        Say "Installing build-eips from $releaseBaseUrl/$archiveName"
        Invoke-ReleaseDownload -Url "$releaseBaseUrl/$archiveName" -Destination $archivePath
        Invoke-ReleaseDownload -Url "$releaseBaseUrl/$archiveName.sha256" -Destination $sidecarPath
        Assert-ArchiveChecksum -ArchivePath $archivePath -SidecarPath $sidecarPath -ArchiveName $archiveName

        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force

        $extractedBuildEips = Join-Path -Path $extractDir -ChildPath "build-eips.exe"
        if (-not (Test-Path -LiteralPath $extractedBuildEips -PathType Leaf)) {
            Die "release archive did not contain expected build-eips.exe"
        }

        try {
            Move-Item -LiteralPath $extractedBuildEips -Destination $BuildEipsPath -Force
        } catch {
            Die ("build-eips.exe is in use. Close any running build-eips process and re-run this script. Details: {0}" -f $_.Exception.Message)
        }

        return $BuildEipsPath
    } catch {
        Die ("failed to install build-eips: {0}" -f $_.Exception.Message)
    } finally {
        if (Test-Path -LiteralPath $tmpRoot) {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ZolaReleaseAsset {
    $architecture = $env:PROCESSOR_ARCHITECTURE
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = "unknown"
    }
    if (($architecture -eq "x86") -and (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432))) {
        $architecture = $env:PROCESSOR_ARCHITEW6432
    }

    switch ($architecture.ToUpperInvariant()) {
        "AMD64" {
            return @{
                ArchiveName = "zola-v0.22.1-x86_64-pc-windows-msvc.zip"
                Hash = "2c8b368f5abdf2b2478748f9549a761fd6599238e18948eccb76a7cae51f5dc1"
            }
        }
        default {
            Die "Unsupported platform Windows/$architecture for automatic Zola install. Install Zola 0.22.1 manually from https://github.com/getzola/zola/releases and ensure it is on PATH."
        }
    }
}

function Install-Zola {
    param(
        [string]$InstallDir,
        [string]$ZolaPath
    )

    $asset = Get-ZolaReleaseAsset
    $archiveName = $asset.ArchiveName
    $archiveHash = $asset.Hash
    $releaseBaseUrl = "https://github.com/getzola/zola/releases/download/v0.22.1"
    $tmpRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("zola-" + [System.Guid]::NewGuid().ToString("N"))
    $archivePath = Join-Path -Path $tmpRoot -ChildPath $archiveName
    $extractDir = Join-Path -Path $tmpRoot -ChildPath "extract"

    try {
        Assert-InstallDirWritable -InstallDir $InstallDir

        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        Say "Installing zola 0.22.1 from $releaseBaseUrl/$archiveName"
        Invoke-ReleaseDownload -Url "$releaseBaseUrl/$archiveName" -Destination $archivePath
        Assert-FileSha256 -ArchivePath $archivePath -ExpectedHash $archiveHash -ArchiveName $archiveName

        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force

        $extractedZola = Join-Path -Path $extractDir -ChildPath "zola.exe"
        if (-not (Test-Path -LiteralPath $extractedZola -PathType Leaf)) {
            Die "zola release archive did not contain expected zola.exe"
        }

        try {
            Move-Item -LiteralPath $extractedZola -Destination $ZolaPath -Force
        } catch {
            Die ("zola.exe is in use. Close any running zola process and re-run this script. Details: {0}" -f $_.Exception.Message)
        }

        return $ZolaPath
    } catch {
        Die ("failed to install zola: {0}" -f $_.Exception.Message)
    } finally {
        if (Test-Path -LiteralPath $tmpRoot) {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ZolaVersionInfo {
    param([string]$ZolaPath)

    try {
        $output = & $ZolaPath --version 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
    } catch {
        return $null
    }

    $fields = @(($output -join " ") -split "\s+" | Where-Object { $_.Length -gt 0 })
    if ($fields.Count -lt 2) {
        return $null
    }

    $versionToken = $fields[1]
    if ($versionToken -notmatch "^([0-9]+)\.([0-9]+)\.([0-9]+)(.*)$") {
        return $null
    }

    return @{
        VersionToken = $versionToken
        Version = [version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3])
        Suffix = $Matches[4]
    }
}

function Get-ZolaVersionRelation {
    param([hashtable]$VersionInfo)

    $minimumVersion = [version]"0.22.1"
    if ($VersionInfo.Version -lt $minimumVersion) {
        return "below"
    }
    if ($VersionInfo.Version -gt $minimumVersion) {
        return "newer"
    }
    if (-not [string]::IsNullOrEmpty($VersionInfo.Suffix)) {
        return "below"
    }

    return "equal"
}

function Install-PinnedZola {
    $defaultPaths = Get-DefaultInstallPaths
    $installedZola = Install-Zola -InstallDir $defaultPaths.InstallDir -ZolaPath $defaultPaths.ZolaPath
    Move-DirectoryToFrontOfSessionPath -InstallDir $defaultPaths.InstallDir

    return $installedZola
}

function Initialize-Zola {
    $zolaPath = Find-ZolaOnPath
    if ($null -eq $zolaPath) {
        $defaultPaths = Get-DefaultInstallPaths
        if (Test-Path -LiteralPath $defaultPaths.ZolaPath -PathType Leaf) {
            $zolaPath = $defaultPaths.ZolaPath
            Move-DirectoryToFrontOfSessionPath -InstallDir $defaultPaths.InstallDir
        }
    }

    if ($null -eq $zolaPath) {
        return (Install-PinnedZola)
    }

    $versionInfo = Get-ZolaVersionInfo -ZolaPath $zolaPath
    if ($null -eq $versionInfo) {
        Say "Found zola with unparseable version output. Installing zola 0.22.1."
        return (Install-PinnedZola)
    }

    $relation = Get-ZolaVersionRelation -VersionInfo $versionInfo
    switch ($relation) {
        "below" {
            Say ("Found zola {0} below supported 0.22.1. Installing zola 0.22.1." -f $versionInfo.VersionToken)
            return (Install-PinnedZola)
        }
        "equal" {
            Say ("Using existing zola {0} at {1}" -f $versionInfo.VersionToken, $zolaPath)
            return $zolaPath
        }
        "newer" {
            Say ("Found zola {0}. build-eips is tested with zola 0.22.1 or newer. Continuing with the installed version." -f $versionInfo.VersionToken)
            return $zolaPath
        }
    }
}

function Resolve-ActiveRepoRoot {
    param(
        [string]$InvocationDir,
        [string]$WorkspaceRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($env:ACTIVE_REPO_ROOT)) {
        if ([System.IO.Path]::IsPathRooted($env:ACTIVE_REPO_ROOT)) {
            $activeRepoCandidate = $env:ACTIVE_REPO_ROOT
        } else {
            $activeRepoCandidate = Join-Path -Path $InvocationDir -ChildPath $env:ACTIVE_REPO_ROOT
        }
    } else {
        $activeRepoCandidate = Join-Path -Path $WorkspaceRoot -ChildPath "EIPs"
    }

    try {
        $resolved = (Resolve-Path -LiteralPath $activeRepoCandidate).ProviderPath
    } catch {
        Die "theme local setup needs an active proposal repo checkout such as EIPs at $activeRepoCandidate"
    }

    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        Die "theme local setup needs an active proposal repo checkout such as EIPs at $activeRepoCandidate"
    }

    return $resolved
}

function ConvertTo-PowerShellQuotedPath {
    param([string]$Path)

    return "'{0}'" -f ($Path -replace "'", "''")
}

function Get-DefaultInstallPaths {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Die "LOCALAPPDATA is not set; cannot determine the user-local install directory"
    }

    $installDir = Join-Path -Path (Join-Path -Path $env:LOCALAPPDATA -ChildPath "build-eips") -ChildPath "bin"
    $buildEipsPath = Join-Path -Path $installDir -ChildPath "build-eips.exe"
    $zolaPath = Join-Path -Path $installDir -ChildPath "zola.exe"

    return @{
        InstallDir = $installDir
        BuildEipsPath = $buildEipsPath
        ZolaPath = $zolaPath
    }
}

$PathNotes = @()
$WorkspaceFlags = @()
if ($Template) {
    $WorkspaceFlags += "--template"
}
if ($PlatformDev) {
    $WorkspaceFlags += "--platform-dev"
}

$InvocationDir = (Get-Location).ProviderPath
$ScriptDir = (Resolve-Path -LiteralPath $PSScriptRoot).ProviderPath
$ThemeRoot = (Resolve-Path -LiteralPath (Split-Path -Path $ScriptDir -Parent)).ProviderPath
$WorkspaceRoot = (Resolve-Path -LiteralPath (Split-Path -Path $ThemeRoot -Parent)).ProviderPath
$ActiveRepoRoot = Resolve-ActiveRepoRoot -InvocationDir $InvocationDir -WorkspaceRoot $WorkspaceRoot

$BuildEipsPath = Find-BuildEipsOnPath
if ($null -ne $BuildEipsPath) {
    Say "Using existing build-eips at $BuildEipsPath"
} else {
    $defaultPaths = Get-DefaultInstallPaths
    $DefaultInstallDir = $defaultPaths.InstallDir
    $DefaultBuildEipsPath = $defaultPaths.BuildEipsPath

    if (Test-Path -LiteralPath $DefaultBuildEipsPath -PathType Leaf) {
        $BuildEipsPath = $DefaultBuildEipsPath
        Move-DirectoryToFrontOfSessionPath -InstallDir $DefaultInstallDir
        Say "Using existing build-eips at $BuildEipsPath"
    } else {
        $BuildEipsPath = Install-BuildEips -InstallDir $DefaultInstallDir -BuildEipsPath $DefaultBuildEipsPath
        Move-DirectoryToFrontOfSessionPath -InstallDir $DefaultInstallDir
    }
}

$ZolaPath = Initialize-Zola

Say "Theme repo: $ThemeRoot"
Say "Workspace root: $WorkspaceRoot"
Say "Active proposal repo: $ActiveRepoRoot"
Say "If PowerShell blocks this script, run:"
Say "  powershell -ExecutionPolicy Bypass -File .\scripts\dev-setup.ps1"

Say "Bootstrapping workspace at $WorkspaceRoot"
& $BuildEipsPath -C $ActiveRepoRoot workspace init $WorkspaceRoot @WorkspaceFlags
$WorkspaceInitExitCode = $LASTEXITCODE
if ($WorkspaceInitExitCode -ne 0) {
    Die "workspace init failed with exit code $WorkspaceInitExitCode"
}

Say "Running workspace doctor"
& $BuildEipsPath -C $ActiveRepoRoot workspace doctor
$WorkspaceDoctorExitCode = $LASTEXITCODE
if ($WorkspaceDoctorExitCode -ne 0) {
    Say "Warning: workspace doctor reported issues above. Fix them before relying on direct build-eips commands."
}

$WorkspaceDocPath = Join-Path -Path $WorkspaceRoot -ChildPath "WORKSPACE.md"
Say ""
if (Test-Path -LiteralPath $WorkspaceDocPath -PathType Leaf) {
    Say "Workspace docs: $WorkspaceDocPath (../WORKSPACE.md from this repo)"
} else {
    Say "Warning: workspace docs were not found at $WorkspaceDocPath after workspace init"
}

if ($PathNotes.Count -gt 0) {
    Say ""
    Say 'Updated PATH for this PowerShell session only:'
    foreach ($pathNote in $PathNotes) {
        Say "  $pathNote"
    }
    Say "To make this permanent, add the listed directory or directories to your user Path in Windows Environment Variables."
}

Say ""
Say "Next commands:"
Say ("  cd {0}" -f (ConvertTo-PowerShellQuotedPath -Path $ThemeRoot))
Say ("  build-eips -C {0} serve" -f (ConvertTo-PowerShellQuotedPath -Path $ActiveRepoRoot))
Say ("  build-eips -C {0} check" -f (ConvertTo-PowerShellQuotedPath -Path $ActiveRepoRoot))
Say ("  build-eips -C {0} workspace doctor" -f (ConvertTo-PowerShellQuotedPath -Path $ActiveRepoRoot))
