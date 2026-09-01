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
$dashboardPidPath = Join-Path $installRoot "data\local-dashboard.pid"
if (Test-Path -LiteralPath $dashboardPidPath) {
    $dashboardPidText = [System.IO.File]::ReadAllText($dashboardPidPath).Trim()
    $dashboardPid = 0
    if ([int]::TryParse($dashboardPidText, [ref]$dashboardPid) -and $dashboardPid -gt 0) {
        $dashboardProcess = Get-Process -Id $dashboardPid -ErrorAction SilentlyContinue
        $expectedRuntime = [System.IO.Path]::GetFullPath((Join-Path $installRoot "runtime\Scripts\python.exe"))
        if ($null -ne $dashboardProcess) {
            try {
                $processPath = [System.IO.Path]::GetFullPath($dashboardProcess.Path)
                if ($processPath -ieq $expectedRuntime) {
                    Stop-Process -Id $dashboardPid -Force -ErrorAction Stop
                }
            }
            catch {
                throw "TokenFleet local statistics service could not be stopped safely."
            }
        }
    }
}
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$remaining = @(
    $userPath -split ';' |
        Where-Object { $_ -and $_.TrimEnd('\') -ine $binRoot.TrimEnd('\') }
)
[Environment]::SetEnvironmentVariable("Path", ($remaining -join ';'), "User")

foreach ($shortcutPath in @(
    (Join-Path ([Environment]::GetFolderPath("Desktop")) "TokenFleet.lnk"),
    (Join-Path ([Environment]::GetFolderPath("Programs")) "TokenFleet.lnk")
)) {
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
}

if ($FromClient) {
    Start-Sleep -Seconds 3
}
$deleteError = $null
for ($attempt = 1; $attempt -le 3 -and (Test-Path -LiteralPath $installRoot); $attempt++) {
    try {
        Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction Stop
        $deleteError = $null
    }
    catch {
        $deleteError = $_
        if ($attempt -lt 3) {
            Start-Sleep -Seconds 2
        }
    }
}
if (Test-Path -LiteralPath $installRoot) {
    throw "TokenFleet client files could not be removed after 3 attempts: $deleteError"
}
Write-Output "TokenFleet Windows client removed. Server-side history is unchanged."
