# TokenFleet Windows 10/11 client

> **Experimental source candidate:** cross-platform automation passes, but this
> client has not completed real Windows 10/11 E2E for DPAPI, Task Scheduler,
> upgrade, uninstall, or production sync. The current Mac beta does not promise
> Windows production readiness. The commands below are for technical preview
> and later hardware validation only.

This is the source-distributed Windows participant client for the private
TokenFleet community. It does not use WeChat, a member login, or an AI-provider
account. An administrator creates the participant nickname on the server and
issues a separate one-time code for every device.

## Supported in v1

- Native Codex JSONL under `%USERPROFILE%\.codex\sessions`.
- Native Claude Code JSONL under `%USERPROFILE%\.claude\projects`.
- Exact daily `date × tool × model` aggregates using the existing TeamSync v1
  HMAC contract. If a relevant local record cannot be safely attributed, the
  affected Claude Code aggregate is withheld instead of being reported as exact.
- Independent installation UUID and server credential per Windows device, so
  several computers add to the same participant without sharing an AI account.
- Current-user Windows DPAPI storage. The device secret is never written or
  logged in plaintext and is not put in Windows roaming settings.
- A Task Scheduler job every six hours, plus `status`, `preview`, `sync`,
  `open-rank`, and `uninstall` commands.

CC Switch is deliberately **not collected in Windows v1**. Its proxy database
can overlap the native Codex/Claude JSONL. Uploading both before the same
cross-source deduplication has been proven would over-count usage.

## Install from a reviewed source checkout

Prerequisite: Windows 10/11 and Python 3.10 or newer. Python can be installed
from an ordinary terminal if it is absent:

```powershell
winget install Python.Python.3.12
```

Download or clone the reviewed TokenFleet release, enter its root, and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\clients\windows\install.ps1 `
  -CommunityServer https://<community-domain>
```

The installer validates and pins that canonical HTTPS origin in a non-secret,
integrity-checked installation file, copies only this client to
`%LOCALAPPDATA%\TokenFleet`, adds its
`bin` directory to the current user's `PATH`, and does not read Codex or Claude
credentials. Re-running the installer must supply the same origin; changing it
requires uninstalling first. `-ValidateOnly` checks the origin and upgrade
compatibility without writing installation files. Open a new terminal after installation.

## Connect each device

```powershell
tokenfleet connect
```

The command asks for the one-time code with hidden input. There is intentionally
no `--server` or `--code` argument, so neither the destination nor code can be
changed at enrollment time or left in PowerShell history/process arguments. Run
the command separately on every computer with a new
code generated for the same nickname.

## Everyday commands

```powershell
tokenfleet preview
tokenfleet status
tokenfleet sync
tokenfleet open-rank
```

`preview` and `status` never print prompt text, response text, code, source
paths, AI account IDs, enrollment codes, or the device secret. `open-rank`
opens only `<connected HTTPS origin>/rank` without credentials in the URL.

## Uninstall

```powershell
tokenfleet uninstall --yes
```

This removes the scheduled task, local state, DPAPI ciphertext, installed files,
and the user PATH entry. It does not touch `.codex`, `.claude`, TokenStep,
OpenToken, or server-side history. Ask an administrator to disable the old
device if immediate server-side revocation is required.
