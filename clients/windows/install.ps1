[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CommunityServer,
    [switch]$ValidateOnly,
    [switch]$NoPathUpdate
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-TokenFleetPython {
    $candidates = @()
    if (Get-Command "py.exe" -ErrorAction SilentlyContinue) {
        $candidates += ,@("py.exe", "-3")
    }
    if (Get-Command "python.exe" -ErrorAction SilentlyContinue) {
        $candidates += ,@("python.exe")
    }
    foreach ($candidate in $candidates) {
        $command = $candidate[0]
        $prefix = @($candidate | Select-Object -Skip 1)
        try {
            $output = & $command @prefix -c "import pathlib,sys; assert sys.version_info >= (3,10); print(pathlib.Path(sys.executable).resolve())" 2>$null
            if ($LASTEXITCODE -eq 0 -and $output) {
                return [System.IO.Path]::GetFullPath(($output | Select-Object -Last 1).Trim())
            }
        }
        catch {
            continue
        }
    }
    throw "TokenFleet requires Python 3.10 or newer. Install it first with: winget install Python.Python.3.12"
}

if ($env:OS -ne "Windows_NT") {
    throw "This installer only supports Windows 10/11."
}
if (-not $env:LOCALAPPDATA) {
    throw "LOCALAPPDATA is unavailable."
}

$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$required = @(
    (Join-Path $sourceRoot "tokenfleet_cli.py"),
    (Join-Path $sourceRoot "tokenfleet"),
    (Join-Path $sourceRoot "uninstall.ps1")
)
foreach ($item in $required) {
    if (-not (Test-Path -LiteralPath $item)) {
        throw "Incomplete TokenFleet Windows source package."
    }
}

$python = Resolve-TokenFleetPython

$installRoot = Join-Path $env:LOCALAPPDATA "TokenFleet"
$configPath = Join-Path $installRoot "app\community.json"
$digestPath = Join-Path $installRoot "app\community.sha256"
$credentialPath = Join-Path $installRoot "data\credential.dpapi"
$preflight = @'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from tokenfleet.installation import validate_install_request
validate_install_request(
    sys.argv[2],
    config_path=Path(sys.argv[3]),
    digest_path=Path(sys.argv[4]),
    credential_path=Path(sys.argv[5]),
)
'@
& $python -B -c $preflight $sourceRoot $CommunityServer $configPath $digestPath $credentialPath 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "CommunityServer is invalid, differs from the existing installation, or the pinned configuration is damaged."
}
if ($ValidateOnly) {
    Write-Output "TokenFleet Windows installer validation passed."
    exit 0
}

$expectedParent = [System.IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
$resolvedRoot = [System.IO.Path]::GetFullPath($installRoot).TrimEnd('\')
if ((Split-Path -Parent $resolvedRoot) -ne $expectedParent -or (Split-Path -Leaf $resolvedRoot) -ne "TokenFleet") {
    throw "Refusing an unexpected installation target."
}

$appRoot = Join-Path $installRoot "app"
$binRoot = Join-Path $installRoot "bin"
$stagingRoot = Join-Path $installRoot (".install-staging-" + [guid]::NewGuid().ToString("N"))
$stagedApp = Join-Path $stagingRoot "app"
$oldApp = Join-Path $installRoot "app.previous"

New-Item -ItemType Directory -Force -Path $stagedApp | Out-Null
New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceRoot "tokenfleet") -Destination $stagedApp -Recurse -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "tokenfleet_cli.py") -Destination $stagedApp -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "uninstall.ps1") -Destination $stagedApp -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "README.md") -Destination $stagedApp -Force

$writeConfig = @'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from tokenfleet.installation import install_config_artifacts
config, digest = install_config_artifacts(sys.argv[2])
Path(sys.argv[3]).write_bytes(config)
Path(sys.argv[4]).write_bytes(digest)
'@
& $python -B -c $writeConfig $sourceRoot $CommunityServer (Join-Path $stagedApp "community.json") (Join-Path $stagedApp "community.sha256")
if ($LASTEXITCODE -ne 0) {
    throw "TokenFleet community configuration could not be staged."
}

& $python -m compileall -q $stagedApp
if ($LASTEXITCODE -ne 0) {
    throw "TokenFleet source validation failed."
}

try {
    if (Test-Path -LiteralPath $oldApp) {
        Remove-Item -LiteralPath $oldApp -Recurse -Force
    }
    if (Test-Path -LiteralPath $appRoot) {
        Move-Item -LiteralPath $appRoot -Destination $oldApp
    }
    Move-Item -LiteralPath $stagedApp -Destination $appRoot
    if (Test-Path -LiteralPath $oldApp) {
        Remove-Item -LiteralPath $oldApp -Recurse -Force
    }
}
catch {
    if (-not (Test-Path -LiteralPath $appRoot) -and (Test-Path -LiteralPath $oldApp)) {
        Move-Item -LiteralPath $oldApp -Destination $appRoot
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

$launcher = Join-Path $binRoot "tokenfleet.cmd"
$entrypoint = Join-Path $appRoot "tokenfleet_cli.py"
$launcherText = "@echo off`r`n`"$python`" `"$entrypoint`" %*`r`n"
[System.IO.File]::WriteAllText($launcher, $launcherText, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText((Join-Path $installRoot ".installed"), "source-install-v2`r`n", [System.Text.UTF8Encoding]::new($false))

if (-not $NoPathUpdate) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @($userPath -split ';' | Where-Object { $_ })
    if (-not ($parts | Where-Object { $_.TrimEnd('\') -ieq $binRoot.TrimEnd('\') })) {
        $updatedPath = (@($parts) + @($binRoot)) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $updatedPath, "User")
    }
    $env:Path = "$binRoot;$env:Path"
}

Write-Output "TokenFleet Windows client installed."
Write-Output "Open a new terminal, then run: tokenfleet connect"
Write-Output "The one-time code is requested with hidden input and is never placed in command history."
