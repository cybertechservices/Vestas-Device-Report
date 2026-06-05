# Device-Report — Target Machine Deployment Runbook

Applies to **v1.3.2**. This is a step-by-step guide for installing and running
`Device-Reports.ps1` on a **fresh Windows 10/11 computer** from the deployment
ZIP. Follow it top to bottom.

---

## 0. TL;DR

**You only need Node.js/Playwright for menu option 6 (Configuration Backup).**
Everything else is pure PowerShell and needs *nothing installed*.

```powershell
# 1. Unzip to a folder, then in that folder:
Get-ChildItem -Recurse | Unblock-File          # clear the "downloaded from internet" flag
Copy-Item conf\.env.example conf\.env
notepad conf\.env                               # fill in WPP_USERNAME / WPP_PASSWORD

# 2a. Run it (interactive menu):
powershell -ExecutionPolicy Bypass -File .\Device-Reports.ps1

# 2b. (Only if you need option 6) install the browser stack first:
winget install OpenJS.NodeJS.LTS               # then restart the terminal
cd tools; npm install; npx playwright install msedge; cd ..
```

---

## 1. Decide which tier you need

| You want to run… | Tier | Extra install |
|---|---|---|
| Menu options **1–5** (unknown devices, devices, NCM, asset details, asset+NCM) | **A** | **None** — PowerShell only |
| Menu option **6** (Configuration Backup report) | **B** | Node.js + Playwright + Edge |

Option 6 is the only feature that drives a headless browser (for SAML SSO + the
Vue SPA). If you don't need it, skip every "Tier B" step below.

---

## 2. Prerequisites & pre-flight checks

Run these in a PowerShell window on the target machine:

```powershell
# Windows PowerShell 5.1 ships with Windows 10/11 — this should print 5.1 or higher
$PSVersionTable.PSVersion

# Tier B only:
node --version          # need v18+ (LTS). "not recognized" = not installed yet (see step 6)
(Get-Command msedge -ErrorAction SilentlyContinue) ; "Edge path:"; (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Edge\BLBeacon' -ErrorAction SilentlyContinue).version
```

**Network / firewall** — the machine must reach (HTTPS / 443):

| Host | Needed for |
|---|---|
| `prod.api.vestas.net` | Options 1–6 (public API auth + queries) |
| `wpp-conf.vestasext.net` | Internal app (option 6, and any internal-host endpoint) |
| `wpp-idp.vestasext.net` | SAML identity provider redirect (option 6) |

**Credentials** — you need a valid WPP-CONF `WPP_USERNAME` / `WPP_PASSWORD`.
Each operator/machine uses its **own** credentials; never copy a `.env` between
machines.

---

## 3. Copy and unpack the package

1. Copy `Device-Report-deploy-<stamp>.zip` to the target machine.
2. Unzip to a stable location, e.g. `C:\Tools\Device-Report`.
3. **Unblock the files** — Windows tags files extracted from a downloaded ZIP
   with a "Mark of the Web", which blocks `.ps1`/`.js` from running. Clear it:

   ```powershell
   cd C:\Tools\Device-Report
   Get-ChildItem -Recurse | Unblock-File
   ```

4. **Execution policy** — if scripts are blocked by policy, either run with a
   per-process bypass (used in the examples below):

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Device-Reports.ps1
   ```

   …or allow signed/local scripts for your user once:

   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

---

## 4. Configure credentials (both tiers)

```powershell
Copy-Item conf\.env.example conf\.env
notepad conf\.env
```

Set the two values (no quotes needed):

```
WPP_USERNAME=your-username
WPP_PASSWORD=your-password
```

`conf\.env` is git-ignored and must never be committed or shared. The script
logs only the password **length**, never the value.

---

## 5. Tier A — run it (PowerShell only, no install)

```powershell
powershell -ExecutionPolicy Bypass -File .\Device-Reports.ps1
```

You'll get the interactive menu:

```
======================================================
  Device-Reports.ps1   v1.3.2
======================================================
  Available API endpoints:

  [1] DE-HeDreiht - Powerplants with unknown devices
  [2] Devices for DE-HeDreiht
  [3] NCM Devices for DE-HeDreiht
  [4] Asset Details for DE-HeDreiht devices
  [5] Asset + NCM Details for DE-HeDreiht devices
  [6] Configuration Backup Report ...        <-- needs Tier B
  [Q] Quit
```

Pick a number (1–5 for Tier A). Results are written under:

```
Output\<endpoint-slug>\<YYYY-MM-DD>\   ← JSON + CSV (timestamped, never overwritten)
log\WPPConfQuery_<YYYY-MM-DD>.log      ← one log file per day
```

---

## 6. Tier B — extra setup for option 6 (Configuration Backup)

Only needed if you will run menu option 6.

```powershell
# 1. Install Node.js LTS, then CLOSE AND REOPEN the terminal (PATH refresh)
winget install OpenJS.NodeJS.LTS

# 2. Install the Node deps and the Edge browser channel
cd C:\Tools\Device-Report\tools
npm install
npx playwright install msedge
cd ..

# 3. Confirm
node --version
```

Microsoft Edge must be present (it is by default on Windows 11) — the extractor
drives Edge via Playwright's `msedge` channel. Now option 6 will work; if Node
is missing the script fails cleanly with:
`Node.js not found on PATH. Install Node.js LTS (winget install OpenJS.NodeJS.LTS), restart the terminal, then retry.`

---

## 7. First-run verification

After a successful run you should see, at the console and in the day's log:

- a `===== AUTHENTICATION =====` section ending in `Token retrieved` (Tier A) or
  `SAML login OK` (option 6),
- a `===== QUERY =====` section with `query succeeded`,
- a `===== OUTPUT =====` section with `CSV written: …` / `JSON saved: …`,
- new files under `Output\<slug>\<today>\`.

Quick check:

```powershell
Get-ChildItem -Recurse Output | Select-Object -Last 5 FullName, Length, LastWriteTime
Get-Content (Get-ChildItem log\*.log | Sort-Object LastWriteTime | Select-Object -Last 1).FullName -Tail 20
```

---

## 8. Unattended / scheduled daily runs (optional)

The project goal is daily reports. For unattended runs you **must** bypass the
menu with `-EndpointIndex <1-6>` (the interactive menu would otherwise wait for
input forever). Example — schedule option 6 daily at 06:00:

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Tools\Device-Report\Device-Reports.ps1" -EndpointIndex 6'
$trigger = New-ScheduledTaskTrigger -Daily -At 6:00am
Register-ScheduledTask -TaskName "WPP Config Backup" -Action $action -Trigger $trigger `
  -RunLevel Limited -Description "Daily WPP-CONF configuration backup report"
```

> `-EndpointIndex` is **1-based into the current menu** (1–6). If endpoints are
> added/removed in `conf\conf.json`, re-check the number. Run the script once
> interactively first to confirm the index maps to the report you expect.

Useful parameters (see `Get-Help .\Device-Reports.ps1 -Full`):

| Parameter | Purpose |
|---|---|
| `-EndpointIndex <n>` | Pick endpoint 1–6 without the menu (required for unattended) |
| `-OutputFolder <path>` | Change the output root (default `Output\`) |
| `-LogFolder <path>` | Change the log root (default `log\`) |
| `-Verbose` / `-Debug` | Reveal per-item DEBUG detail |
| `-SkipCertificateCheck` | Bypass TLS validation — **lab/test only**, never in production |

---

## 9. Troubleshooting

| Symptom | Exit code | Cause / fix |
|---|---|---|
| `…cannot be loaded because running scripts is disabled` | — | Execution policy. Use `-ExecutionPolicy Bypass` or `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` (step 3). |
| Script blocked / "publisher cannot be verified" | — | Mark of the Web. Run `Get-ChildItem -Recurse \| Unblock-File` (step 3). |
| `Config file not found` / `.env file not found` | **1** | Run from the install folder; ensure `conf\conf.json` and `conf\.env` exist (steps 3–4). |
| `WPP_USERNAME or WPP_PASSWORD missing/empty` | **1** | Fill in `conf\.env` (step 4). |
| `Authentication failed` / token not recognized | **2** | Wrong credentials, or no network path to `prod.api.vestas.net`. Verify `.env` and firewall (step 2). |
| `request failed` on the main query | **3** | Endpoint/network/role issue; the server response body is logged. For option 8/9-style internal hosts, check `wpp-conf`/`wpp-idp` egress. |
| Internal session `HTTP 401/419` (option 6) | **3** | SAML session expired/rejected — just re-run; if it persists, refresh `.env` credentials. |
| `Node.js not found on PATH` (option 6) | — | Do Tier B (step 6), then **restart the terminal**. |
| `npx playwright install msedge` fails | — | Ensure Edge is installed and the machine can reach Microsoft's download CDN; re-run from `tools\`. |
| TLS / handshake errors on old machines | — | Script forces TLS 1.2; ensure the OS isn't restricted to TLS 1.0/1.1. |

Exit codes: `0` success/cancelled · `1` config/.env load · `2` auth · `3` main
query · `4` JSON write.

---

## 10. What is NOT in the package (supply on the target)

Excluded by design for security/hygiene — recreate locally:

- `conf\.env` — live credentials (create from `conf\.env.example`).
- `tools\node_modules\` — run `npm install` (Tier B).
- Playwright browser binaries — run `npx playwright install msedge` (Tier B).
- `Output\`, `log\` — auto-created per run.
- Any `*.bak-*`, debug screenshots, session/cookie dumps.

---

## 11. Uninstall

Stop any scheduled task, then delete the folder:

```powershell
Unregister-ScheduledTask -TaskName "WPP Config Backup" -Confirm:$false   # if you created one
Remove-Item -Recurse -Force C:\Tools\Device-Report
```

Node.js (if you installed it only for this) can be removed with
`winget uninstall OpenJS.NodeJS.LTS`. Playwright browser binaries live in
`%LOCALAPPDATA%\ms-playwright` and can be deleted to reclaim space.
