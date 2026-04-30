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

function Add-DefaultBinToSessionPath {
    param([string]$InstallDir)

    if (-not (Test-DirectoryOnPath -Directory $InstallDir)) {
        if ([string]::IsNullOrEmpty($env:Path)) {
            $env:Path = $InstallDir
        } else {
            $env:Path = "$InstallDir;$env:Path"
        }

        $script:PathNote = $InstallDir
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

    return @{
        InstallDir = $installDir
        BuildEipsPath = $buildEipsPath
    }
}

$PathNote = $null
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
        Add-DefaultBinToSessionPath -InstallDir $DefaultInstallDir
        Say "Using existing build-eips at $BuildEipsPath"
    } else {
        $BuildEipsPath = Install-BuildEips -InstallDir $DefaultInstallDir -BuildEipsPath $DefaultBuildEipsPath
        Add-DefaultBinToSessionPath -InstallDir $DefaultInstallDir
    }
}

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

if ($null -ne $PathNote) {
    Say ""
    Say 'Updated PATH for this PowerShell session only:'
    Say "  $PathNote"
    Say "To make this permanent, add that directory to your user Path in Windows Environment Variables."
}

Say ""
Say "Next commands:"
Say ("  cd {0}" -f (ConvertTo-PowerShellQuotedPath -Path $ThemeRoot))
Say ("  build-eips -C {0} serve" -f (ConvertTo-PowerShellQuotedPath -Path $ActiveRepoRoot))
Say ("  build-eips -C {0} check" -f (ConvertTo-PowerShellQuotedPath -Path $ActiveRepoRoot))
Say ("  build-eips -C {0} workspace doctor" -f (ConvertTo-PowerShellQuotedPath -Path $ActiveRepoRoot))
