# Changelog

All notable changes to the Vestas Report Generator are recorded here.
Versioning: `x.y.z` — `y` = features, `z` = patches (per CLAUDE.md Working Rule #4).

## [1.5.5] — 2026-06-04

### Changed (team-review hardening of 1.5.2–1.5.4)
- **Closed the remaining hang gap (Solution Architect finding).** Three direct
  `Invoke-RestMethod -WebSession` calls bypassed the 1.5.2 default timeout: the
  internal-session initial query and — more importantly — the per-device
  `/get-ncm-device-subconfig` **paging loops** in both backup chains, which run
  hundreds of times per report and are the most likely place to stall. Added an
  explicit `-TimeoutSec 120` to all three so the whole chain now fails fast
  instead of hanging. (Inline timeout rather than a Get-RequestSplat refactor, to
  avoid disturbing the v1.4.1-protected paging logic.)
- **Sanitized retry-loop error logging (Security Manager finding).** The
  powerplant-name lookup retry now logs an HTTP status code / exception-type
  summary instead of the raw `$_.Exception.Message`, so a server response body
  can't leak into the log.
- **Retry only on transient stalls (Test Coverage finding).** The lookup retry
  now aborts immediately on a non-timeout error (4xx/5xx/auth) instead of
  pointlessly re-issuing a request that will fail identically; it still retries a
  genuine timeout/cancellation once.

### Added
- `tests/Test-GetRequestSplat.ps1` — a non-destructive unit check that extracts
  `Get-RequestSplat` via the PowerShell AST (without executing the script body)
  and asserts default `TimeoutSec=120` injection, caller override preservation,
  and base-key passthrough. Runs with no network/SSO. All three checks pass.

### Deferred (logged for a future version, per Test Coverage's own Priority-3 list)
- A `--strict-toggle` mode for `get-ncm-map.js` that exits non-zero if the NCM
  asset toggle can't be clicked (vs. today's loud WARN + continue).
- Per-endpoint HTTP timeout overrides in `conf.json` for any endpoint that
  legitimately needs more than 120s.

## [1.5.4] — 2026-06-04

### Fixed
- **Removed a false "MAY BE MISSING ASSETS" warning.** The v1.5.3 toggle fix
  worked (validated: NCM device count went **104 → 404** on the 06-04 monthly
  run), but the post-click verification re-read the toggle icon's CSS class and
  reported *"toggle still reads OFF … MAY BE MISSING ASSETS"* even though the
  list had expanded — the Vue panel re-renders when the toggle fires, so the
  class read is stale/unreliable. Replaced the icon-class check with an
  **effect-based check**: capture the `#ncm-devices` option count *before* the
  toggle and compare it *after*, logging the real delta
  (`Toggle expanded the asset list: 104 -> 404 device(s).`). A warning now fires
  only if the count genuinely fails to increase.

## [1.5.3] — 2026-06-04

### Fixed
- **NCM asset-list toggle click now works.** The v1.5.1 toggle click resolved the
  correct element (`<i class="fa fa-toggle-off ... unchecked">`) but every click
  was rejected with *"Element is not visible"* — even with `force: true` — because
  the toggle's panel is zero-box / CSS-hidden while the tab pane is inactive, so
  Playwright can't compute a hittable point. The map was still extracted at the
  **pre-toggle subset (104 devices)**. Fix: after the force-click attempt, fall
  back to a **native DOM dispatch** (`locator.evaluate(el => el.click())`), which
  ignores visibility and bubbles to the Vue/label handler. Added a post-click
  **state check** that re-reads the icon's class (`fa-toggle-on` / `checked`) so
  the log reports whether the toggle truly flipped ON (full list) or is still OFF
  (incomplete map) instead of assuming success. The toggle xpath is now a single
  named constant reused by both the click and the verification step.

## [1.5.2] — 2026-06-04

### Fixed
- **Backup chains could hang forever on the powerplant-name lookup.** The 06-03
  config-backup run stalled on `GET /powerplants?search=id:<id>` and had to be
  killed — the log ended mid-air because `Invoke-RestMethod` had **no timeout**
  and the process died before its `try/catch` could log anything. `Get-RequestSplat`
  now injects a default **`TimeoutSec = 120`** into every request splat (callers
  may still override via their own `TimeoutSec`), so a stalled connection fails
  fast with a logged error instead of blocking indefinitely.
- The powerplant-name lookup in **both** the `assetConfigBackup` and
  `monthlyBackupRate` chains is now wrapped in a **2-attempt retry** (3s backoff)
  so a single transient stall self-recovers without a manual re-run; a clean
  response (named or not) breaks immediately, and the existing
  "could not resolve powerplant name" abort still fires if both attempts fail.
  Applied inline to each chain (no shared-code refactor, per the 1.5.0 stance).

### Known gap
- The per-device `/get-ncm-device-subconfig` paging loops call `Invoke-RestMethod
  -WebSession` directly (not via `Get-RequestSplat`), so they remain uncapped by
  the new default timeout. Pre-existing; not addressed here.

## [1.5.1] — 2026-06-04

### Fixed
- **Backup reports were missing assets.** `tools/get-ncm-map.js` activated the NCM
  tab and then read the `#ncm-devices` `<select>` immediately, but the NCM panel
  renders with a collapsed/filtered default view that only carries a subset of
  assets. Added **STEP 3.5**: after the NCM tab activates and before reading the
  select, the extractor now clicks the panel's asset-list toggle (the `<i>` inside
  a `<label>`, located by the same NCM-panel xpath prefix as the tab) to reveal the
  full device list, then waits for `networkidle` so the re-rendered list settles
  before extraction. Fixes missing assets in **both** browser-fed backup chains —
  `assetConfigBackup` (Configuration Backup) and `monthlyBackupRate` — since both
  consume `Get-NcmDeviceMapViaBrowser`. No PowerShell changes were needed; the
  expanded device list flows through automatically.
- The toggle is addressed by a deep absolute xpath (icon + parent-`label`
  fallback). If it can't be clicked the step is **non-fatal**: it logs a loud WARN,
  saves `debug-no-ncm-toggle.png`, and continues so a run still completes — but the
  log makes clear the resulting map may be incomplete. (Reviewed and approved by
  Solution Architect + Code Reviewer; a generic page-wide checkbox fallback was
  deliberately rejected to avoid clicking unrelated controls.)

## [1.5.0] — 2026-06-01

### Added
- New chain mode **`monthlyBackupRate`** and menu endpoint *"Monthly Backup-Rate
  Report for DE-HeDreiht devices (previous month)"* (`conf\conf.json`, slug
  `monthly-backup-rate-powerplant-5750`, appended LAST so existing `-EndpointIndex`
  numbers are unchanged). For each NCM device it reports the **backup rate** for a
  calendar month: `RatePct = DistinctDaysWithBackup / DaysInMonth × 100` (capped at
  100%). A backup of **either** status (`IDENTICAL` or `HAS CHANGES`) counts — both
  are real backups. The raw `BackupCount` is reported alongside the distinct-day
  coverage so multiple-backups-per-day devices stay visible.
- New parameter **`-Month "yyyy-MM"`** (`[ValidatePattern]`-guarded). Default =
  the **previous calendar month relative to today**, computed via `DateTime`
  (`AddMonths(-1)` / `DaysInMonth`) so January correctly looks back to the prior
  December and leap-year Februaries use 29 days. Window is half-open
  `[firstOfMonth 00:00:00, firstOfNextMonth 00:00:00)`. Intended to run on the
  first days of the month (e.g. a Task Scheduler monthly trigger):
  `pwsh -NonInteractive -File Device-Reports.ps1 -EndpointIndex 8`.
- New row builder `New-BackupRateRow` and output `MonthlyBackupRate_<yyyy-MM>_<stamp>`
  (`.json` aggregate-only + `;`-delimited `.csv`). Columns: `NCM_DeviceID;
  NCM_Hostname; WPP_DeviceID; WPP_Alias; WPP_IpAddr; Month; BackupCount;
  DistinctDaysCovered; DaysInMonth; RatePct; FirstBackupAt; LastBackupAt; Note`.
  Every WPP device is represented; 0% / no-combos / error / aborted / no-NCM-record
  devices emit audit rows via the `Note` column.

### Changed
- The monthly chain pages the NCM subconfig endpoint **newest-first only as far back
  as the start of the target month** (stops on the first row older than the window),
  so a device with years of daily backups costs ~1 request, not its whole history.
  Reuses the v1.4.1 paging guards (`recordsTotal` / short-page / hard page cap = 50).
  Backups are **de-duplicated by row id** across combos and overlapping pages so the
  rate cannot be inflated. The existing `assetConfigBackup` branch is untouched (no
  shared-code refactor) to protect the v1.4.1 fix.

### Security
- The monthly report carries **aggregate counts only** — `last_configuration_change_by`
  (a username) is deliberately excluded (CLAUDE.md rule 6, No PII), and the JSON output
  is built from computed summary objects (no raw API payload reaches disk). `-Month`
  is shape-validated and never flows into any URL (month filtering is client-side),
  and is parsed with `InvariantCulture` so locale cannot mis-bucket backups.

## [1.4.1] — 2026-06-01

### Fixed
- **Config-backup report missed `HAS CHANGES` rows that sat past the first page.**
  The `assetConfigBackup` chain fetched only the newest 50 backup rows per combo
  (`start=0&length=50`) and kept those with `status='HAS CHANGES'`. Devices whose
  configuration had not changed recently showed dozens of newest `IDENTICAL`
  backups on page 1, pushing their real `HAS CHANGES` entries onto an older page
  that was never requested — so they were reported as `<no HAS CHANGES>` with
  empty date columns despite having valid backups (17 devices reported by the PO;
  37 in the 2026-06-01 run). The server returns rows newest-first and reports the
  combo's total backup count via `recordsTotal`.

### Changed
- `Build-NcmSubconfigUrl` (`Device-Reports.ps1`): added a `$Start` parameter so the
  caller can request older DataTables pages (`&start={n}&length={n}`).
- Config-backup per-combo fetch now **pages backwards** newest-first, accumulating
  `HAS CHANGES` rows until it has `$configMaxSlots` (3) of them OR the combo's
  whole history (`recordsTotal`) is consumed. Healthy devices with a recent change
  still exit after a single request, so the 67 already-working devices are
  unaffected. Page size raised 50 → 100 (`$serverFetchWindow`). Termination is
  guarded three ways — `start >= recordsTotal`, a short/empty page, and a hard
  `$configMaxPages = 20` cap — so an all-`IDENTICAL` device (or a missing
  `recordsTotal`) cannot loop forever. Existing 401/419-abort and subconfig-error
  handling is preserved inside the paging loop.

## [1.4.0] — 2026-05-27

### Added
- New chain mode **`assetSoftware`** and menu endpoint *"Asset Software / Firmware
  for DE-HeDreiht devices"* (`conf\conf.json`, slug `asset-software-powerplant-5750`).
  Reuses the existing per-device `/asset/details` fan-out technique to capture
  **running software state** — OS, firmware, software/image version, serial — and
  writes `AssetSoftware_<stamp>.json` + `AssetSoftware_<stamp>.csv`
  (`Device-Reports.ps1`, new `elseif ($chainKind -eq "assetSoftware")` branch).
- **Defensive field resolution** (`$resolveField`): the `/asset/details` response
  shape is unverified (every observed sample is `null`), so OS/firmware/version
  columns are resolved by probing multiple candidate field-name spellings, with a
  one-level probe into `software`/`attributes`/`inventory`/`details` containers.
  Non-scalar matches are serialized to compact JSON so no `System.Object[]` lands
  in a CSV cell. A diagnostic `AssetFieldsSeen` column lists each record's
  top-level field names to reveal the real schema on the first live 200.
- **Redaction pass** (`$redact`) over the full payload before it is written to
  disk (Working Rules #6/#7, No PII / secrets): values of properties whose name
  matches `pass(word)?|secret|community|credential|private_key|token|encryption|`
  `ftp_user|api_key|email` are masked `<redacted>`; secret-like names are masked
  `<redacted-key>` in `AssetFieldsSeen`.

### Security / Review
- Reviewed by the agent team before implementation. The Security Manager blocked
  an initial unbounded full-payload dump; resolved via the `$redact` denylist,
  masked `AssetFieldsSeen`, GET-only calls, a distinct output slug, and bearer
  headers that are never serialized. Recorded follow-up: once the real
  `/asset/details` schema is known, pin column names and move to a server-side
  `filter=` allowlist.

### Validated
- Offline harness (PS 5.1 **and** 7.6, NFR4) over the saved all-null fixture
  (308 device rows, all software columns null, stable column order) plus synthetic
  records: multi-record fan-out, nested-object serialization, all-fields-absent
  rows, empty-alias rows, redaction of `snmp_community`/`ftp_password`/`email`.
- No-regression: diff vs pre-edit backup shows **0 lines removed** — the three
  existing chains and the default-CSV path are byte-for-byte unchanged.

### Changed
- Version aligned to `1.4.0` across `conf\conf.json`, `CLAUDE.md`,
  `specs\requirements.md`. `requirements.md` FR8/FR9/§4/§7 document the new chain.

## [1.3.2] — 2026-05-27

### Docs
- Expanded `DEPLOYMENT.md` into a full target-machine deployment runbook: the
  Tier A / Tier B decision (Node/Playwright only needed for menu option 6),
  prerequisite + network checks, the Mark-of-the-Web `Unblock-File` step and
  execution-policy guidance, credential setup, first-run verification,
  unattended/scheduled-task setup via `-EndpointIndex`, a troubleshooting table
  keyed to the script's real exit codes, and uninstall steps.

## [1.3.1] — 2026-05-27

### Fixed
- Corrected the operator-facing script name: the interactive menu header and the
  `.SYNOPSIS`/`.EXAMPLE` block now read `Device-Reports.ps1` (was the stale
  `Get-UnknownDevices.ps1`) — `Device-Reports.ps1:43, :46, :186`.

### Removed
- Deleted the orphaned `Get-NcmDeviceMapFromPage` function (~107 lines, zero call
  sites — the config-backup chain uses the Node/Playwright extractor
  `Get-NcmDeviceMapViaBrowser`). `Build-NcmSubconfigUrl` was verified LIVE (called
  by the chain at `Device-Reports.ps1:2084`) and left intact.

### Docs
- `requirements.md` FR8 counters and status markers updated to match the code:
  `cfgNoCombos` / `cfgNoHasChanges` (was the pre-rewrite `cfgEmpty`), corrected
  the `Chain complete:` summary line and the `Status` diagnostic markers.

## [1.3.0] — 2026-05-27

### Removed
- Dropped the three `DIAGNOSTIC:` endpoints from `conf\conf.json` (former menu
  options 7, 8, 9): `diagnostic-ncm-bulk-pp5750`,
  `diagnostic-device-asset-status-5750`, `diagnostic-ncm-subconfig-36070`.
  These were development/debugging probes with no code references; removal is a
  pure-data change (menu and dispatch are driven by array position + the `chain`
  property, never by slug or fixed index). The menu now lists 6 endpoints.

### Housekeeping
- Purged leftover dev/debug clutter that must not be deployed: stale `*.bak-*`
  copies of the script/config/JS, `tools\debug-*.png` screenshots,
  `tools\test-cookies.json` (a replayable SAML session), `tools\test-map.json`,
  `tools\ncm-map.log`, `log\ncm-page-debug-*.html` (CSRF token + authed page
  dump), and the empty root `package-lock.json` stub.
- Aligned version across `conf\conf.json`, `CLAUDE.md`, and
  `specs\requirements.md` to `1.3.0` (previously drifted: 1.2.2 / 1.2.0 / 1.2.0).
- Added this `changelog.md` (Working Rule #5) and a `conf\.env.example` template.
- Added `DEPLOYMENT.md` with two-tier install instructions for moving the tool
  to another Windows computer.

### Notes / known follow-ups (not changed in this release)
- The interactive menu header and the script `.SYNOPSIS` still print the old
  name `Get-UnknownDevices.ps1` (`Device-Reports.ps1:186`, `:43`, `:46`); the
  real entry point is `Device-Reports.ps1`.
- `Get-NcmDeviceMapFromPage` (`Device-Reports.ps1:796`) is orphaned dead code —
  the config-backup chain now uses the Node/Playwright path.
- `requirements.md` FR8 still documents the pre-rewrite counter names
  (`cfgEmpty`) and status strings; the code uses
  `cfgNoCombos` / `cfgNoHasChanges`.
