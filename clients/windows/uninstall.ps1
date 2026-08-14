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

& schtasks.exe /Query /TN "TokenFleet Community Sync" 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    & schtasks.exe /Delete /TN "TokenFleet Community Sync" /F 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "TokenFleet scheduled task could not be removed."
    }
}

$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runValueName = "TokenFleet Community Sync"
$runValue = Get-ItemProperty -LiteralPath $runKey -Name $runValueName -ErrorAction SilentlyContinue
if ($null -ne $runValue) {
    Remove-ItemProperty -LiteralPath $runKey -Name $runValueName -ErrorAction Stop
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
Write-Output "TokenFleet Windows client, scheduled task, and startup entry removed. Server-side history is unchanged."
