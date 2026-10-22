[CmdletBinding()]
param(
    [string]$RemoteHost = "192.168.137.2",
    [string]$RemoteUser = "r",
    [string]$LocalImageDirectory,
    [string]$RemoteParentDirectory = "/home/r/Raspberry"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

if ([string]::IsNullOrWhiteSpace($LocalImageDirectory)) {
    $LocalImageDirectory = Join-Path $RepositoryRoot "data\Image"
}

function Assert-LastCommandSucceeded {
    param([Parameter(Mandatory)][string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

if ($RemoteHost -notmatch '^[A-Za-z0-9.-]+$') {
    throw "RemoteHost contains unsupported characters: $RemoteHost"
}

if ($RemoteUser -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$') {
    throw "RemoteUser contains unsupported characters: $RemoteUser"
}

if ($RemoteParentDirectory -notmatch '^/[A-Za-z0-9._/-]+$') {
    throw "RemoteParentDirectory must be an absolute Linux path without spaces."
}

foreach ($commandName in @("ssh", "scp")) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$commandName' was not found. Install the Windows OpenSSH Client first."
    }
}

if (-not (Test-Path -LiteralPath $LocalImageDirectory -PathType Container)) {
    throw "Local Image directory does not exist: $LocalImageDirectory"
}

$resolvedLocalDirectory = (Resolve-Path -LiteralPath $LocalImageDirectory).Path
$localDirectoryName = Split-Path -Leaf $resolvedLocalDirectory
if ($localDirectoryName -ne "Image") {
    throw "The source directory must be named 'Image'; resolved path: $resolvedLocalDirectory"
}

$localFileCount = @(
    Get-ChildItem -LiteralPath $resolvedLocalDirectory -File -Recurse -Force
).Count

$destination = "$RemoteUser@$RemoteHost"
$remoteImageDirectory = "$RemoteParentDirectory/Image"
$remoteParentArgument = "'$RemoteParentDirectory'"
$remoteSpec = "${destination}:$RemoteParentDirectory/"
$sshStateDirectory = Join-Path $RepositoryRoot ".state\ssh"
$knownHostsFile = Join-Path $sshStateDirectory "known_hosts"
$sshOptions = @(
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "UserKnownHostsFile=$knownHostsFile"
)

if (-not (Test-Path -LiteralPath $sshStateDirectory -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $sshStateDirectory
}

Write-Host "Source:      $resolvedLocalDirectory"
Write-Host "Destination: ${destination}:$remoteImageDirectory"
Write-Host "Files:       $localFileCount"
Write-Host "The SSH password may be requested for each remote command."

# Create the parent first. Copying the Image directory itself preserves hidden
# files and nested directories and results in <RemoteParentDirectory>/Image.
& ssh @sshOptions $destination "mkdir -p -- $remoteParentArgument"
Assert-LastCommandSucceeded -Operation "Creating the remote parent directory"

# This board currently closes the SFTP subsystem used by modern scp. Force the
# legacy SCP transport, which is supported by its SSH server.
& scp -O @sshOptions -r $resolvedLocalDirectory $remoteSpec
Assert-LastCommandSucceeded -Operation "Uploading the Image directory"

Write-Host "Upload completed successfully: ${destination}:$remoteImageDirectory" -ForegroundColor Green
