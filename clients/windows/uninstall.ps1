[CmdletBinding()]
param(
    [switch]$FromClient,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($env:OS -ne "Windows_NT" -or -not $env:LOCALAPPDATA) {
    throw "This uninstaller only supports Windows 10/11."
}
if (-not $FromClient -and -not $Yes) {
    throw "Re-run with -Yes to remove TokenFleet's local client, DPAPI ciphertext, and scheduled task."
}

$installRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "TokenFleet")).TrimEnd('\')
$expectedParent = [System.IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
if ((Split-Path -Parent $installRoot) -ne $expectedParent -or (Split-Path -Leaf $installRoot) -ne "TokenFleet") {
    throw "Refusing an unexpected uninstall target."
}

$scheduledTask = Get-ScheduledTask -TaskName "TokenFleet Community Sync" -ErrorAction SilentlyContinue
if ($null -ne $scheduledTask) {
    Unregister-ScheduledTask -InputObject $scheduledTask -Confirm:$false -ErrorAction Stop
}

$binRoot = Join-Path $installRoot "bin"
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$remaining = @(
    $userPath -split ';' |
        Where-Object { $_ -and $_.TrimEnd('\') -ine $binRoot.TrimEnd('\') }
)
[Environment]::SetEnvironmentVariable("Path", ($remaining -join ';'), "User")

if ($FromClient) {
    Start-Sleep -Seconds 3
}
if (Test-Path -LiteralPath $installRoot) {
    Remove-Item -LiteralPath $installRoot -Recurse -Force
}
Write-Output "TokenFleet Windows client removed. Server-side history is unchanged."
