[CmdletBinding()]
param(
    [string]$RemoteHost = "192.168.137.2",
    [string]$RemoteUser = "r",
    [string]$RemoteImageDirectory = "/home/r/Raspberry/Image",
    [string]$LocalDestinationDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

if ([string]::IsNullOrWhiteSpace($LocalDestinationDirectory)) {
    $LocalDestinationDirectory = Join-Path $RepositoryRoot "data\Image\raspberry_image"
}

if ($RemoteHost -notmatch '^[A-Za-z0-9.-]+$') {
    throw "RemoteHost contains unsupported characters: $RemoteHost"
}

if ($RemoteUser -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$') {
    throw "RemoteUser contains unsupported characters: $RemoteUser"
}

if ($RemoteImageDirectory -notmatch '^/[A-Za-z0-9._/-]+$') {
    throw "RemoteImageDirectory must be an absolute Linux path without spaces."
}

if (-not (Get-Command "scp" -ErrorAction SilentlyContinue)) {
    throw "Required command 'scp' was not found. Install the Windows OpenSSH Client first."
}

if (-not (Test-Path -LiteralPath $LocalDestinationDirectory -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $LocalDestinationDirectory -Force
}

$resolvedLocalDirectory = (Resolve-Path -LiteralPath $LocalDestinationDirectory).Path
$destination = "$RemoteUser@$RemoteHost"
$remoteSpec = "${destination}:$RemoteImageDirectory"
$remoteDirectoryName = ($RemoteImageDirectory.TrimEnd('/') -split '/')[-1]
if ([string]::IsNullOrWhiteSpace($remoteDirectoryName)) {
    throw "RemoteImageDirectory must identify a directory below the Linux root."
}
$sshStateDirectory = Join-Path $RepositoryRoot ".state\ssh"
$knownHostsFile = Join-Path $sshStateDirectory "known_hosts"
$sshOptions = @(
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "UserKnownHostsFile=$knownHostsFile"
)

if (-not (Test-Path -LiteralPath $sshStateDirectory -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $sshStateDirectory -Force
}

Write-Host "Source:      ${destination}:$RemoteImageDirectory"
Write-Host "Destination: $resolvedLocalDirectory"
Write-Host "Existing local files not present on the board will be kept."
Write-Host "Enter the SSH password when prompted."

# The board currently closes the SFTP subsystem used by modern scp, so use the
# legacy SCP transport. Download the complete remote directory into a unique
# staging directory first; this avoids Windows OpenSSH rejecting a '/.' source
# while still including hidden files and preserving nested directories.
$localParentDirectory = Split-Path -Parent $resolvedLocalDirectory
$stagingDirectory = Join-Path $localParentDirectory (
    ".raspberry_image_download_" + [guid]::NewGuid().ToString("N")
)
$stagedImageDirectory = Join-Path $stagingDirectory $remoteDirectoryName

$null = New-Item -ItemType Directory -Path $stagingDirectory
try {
    & scp -O @sshOptions -r $remoteSpec "$stagingDirectory\"
    if ($LASTEXITCODE -ne 0) {
        throw "Downloading the remote Image directory failed with exit code $LASTEXITCODE."
    }

    if (-not (Test-Path -LiteralPath $stagedImageDirectory -PathType Container)) {
        throw "The downloaded staging directory is missing: $stagedImageDirectory"
    }

    foreach ($item in Get-ChildItem -LiteralPath $stagedImageDirectory -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $resolvedLocalDirectory -Recurse -Force
    }
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
}

$localFileCount = @(
    Get-ChildItem -LiteralPath $resolvedLocalDirectory -File -Recurse -Force
).Count

Write-Host "Download completed successfully. Local files: $localFileCount" -ForegroundColor Green
