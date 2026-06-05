# Vestas Report Generator — Requirements

**Version:** 1.4.0
**Last derived from code:** 2026-05-27
**Source of truth:** `Device-Reports.ps1`, `conf\conf.json`

This document is reverse-engineered from the working code. If the code and this document disagree, the code wins — open a PR to update this file.

---

## 1. Overview

Read-only PowerShell automation for the Vestas WPP-CONF API. Authenticates with credentials from `.env`, queries a configurable list of endpoints, and writes JSON + CSV reports under a dated output tree. One main interactive script (`Device -Reports.ps1`).

---

## 2. Functional Requirements

### FR1 — Configuration file
Load `conf\conf.json` with shape:
```json
{ "version": "x.y.z",
  "auth": { "url": "..." },
  "endpoints": [ { "name": "...", "slug": "...", "url": "...", "chain": "assetDetails" (optional) } ] }
```
Missing `auth.url` or empty `endpoints` is a fatal error (exit 1).

### FR2 — Credential file (`.env`)
Read `conf\.env` for `WPP_USERNAME` and `WPP_PASSWORD`. Supported syntax: `KEY=VALUE`, optional surrounding single/double quotes, `#`-comment lines, blank lines. Missing or empty values are a fatal error (exit 1).

### FR3 — Authentication (dual mode)
**Public-API context (default).** POST `{username, password}` JSON to `auth.url`. Extract bearer token from the response, checking these field names in order: `token, access_token, accessToken, jwt, id_token, bearer`. Fall back to `data.<field>` if not at the root. Authentication failure exits 2.

**Internal-API context (SAML 2.0 SP-initiated SSO, lazy).** When the chosen endpoint's URL host matches `conf.json` `internalAuth.host` (e.g. `wpp-conf.vestasext.net`), the script lazily performs a SAML SP-initiated login against the federated Identity Provider on first use:

1. **GET** `internalAuth.url` (e.g. `https://wpp-conf.vestasext.net/login`) — `Invoke-WebRequest` follows the 302 chain through `/saml2/login` to `https://wpp-idp.vestasext.net/login?SAMLRequest=<base64-deflated-XML>`.
2. **Parse** the IDP login form (`Get-HtmlForm`): extract the `action` URL, detect the username and password input field names dynamically, and capture **every** hidden input verbatim (`SAMLRequest`, `AuthState`, CSRF, etc.) so the round-trip preserves IDP-side state.
3. **POST** the form with `WPP_USERNAME`/`WPP_PASSWORD` plugged into the detected fields, all other inputs preserved.
4. **Parse** the IDP's response, which is an auto-submitting HTML form whose action is `https://<internalAuth.host>/saml2/acs` and whose hidden inputs include `SAMLResponse` (+ usually `RelayState`).
5. **POST** the SAML Response back to the SP's ACS endpoint. The SP validates the signature on its side, creates a session, and sets the `XSRF-TOKEN` + `laravel-session` cookies in the script's `WebRequestSession`.
6. **Scrape** the `<meta name="csrf-token" content="...">` value from a logged-in HTML page (the landed page after ACS, or `GET /` as fallback). Store as `X-CSRF-TOKEN` header for all subsequent AJAX calls.

Subsequent internal-API GETs send the session cookies plus headers `Accept: application/json, text/javascript, */*; q=0.01`, `X-CSRF-TOKEN: <token>`, `X-Requested-With: XMLHttpRequest`. The session is held in `$script:InternalSessionData` for the duration of the run; bearer-token endpoints continue to work in parallel.

The implementation does **no SAML crypto** — the SP signs and validates assertions internally. The PowerShell client only relays opaque form values.

On HTTP 401/419 from an internal-API call, the script logs that the session expired and notes a re-run will trigger a fresh SAML login (or to verify `.env` credentials if it persists), then exits 3.

### FR4 — Endpoint selection
Resolution precedence:
1. `-EndpointUrl <url>` parameter (custom URL, slug = `custom`).
2. `-EndpointIndex <n>` parameter (1-based into `conf.endpoints`).
3. Interactive menu (numbered list with name + URL, `[Q]` to quit).

### FR5 — Main endpoint query
HTTP GET with `Authorization: Bearer <token>`. No pre-flight permission check on the main endpoint (the JWT role-name may not match the API doc role label verbatim). Failures are caught, logged, and exit 3 with the server response body included.

### FR6 — JSON persistence
Save the parsed response to `<OutputFolder>\<endpoint-slug>\<YYYY-MM-DD>\Powerplants_<yyyyMMdd_HHmmss>.json` (UTF-8, depth 20). Folder is auto-created.

### FR7 — Default CSV export
Auto-detect response shape from the first item:
- Has `unknown_device[]` → `UnknownDevices_<stamp>.csv` (`PowerplantID, Name, Mac_Address, Ip_address, ARP_hostname`).
- Has `mac_address` or `ip_address` → `Devices_<stamp>.csv` (`PowerplantID, ID, Name, Alias, DeviceType, Manufacturer, Model, Mac_Address, Ip_address, ParentDevice, Loopback, VpnIp, Category, Monitored, UpdatedAt`).
- Otherwise: skip CSV, log WARN.

### FR8 — Chain modes (per-device fan-out)
When the chosen endpoint has a `chain` property, treat the primary response as a device list and fan out additional GETs per device. The following chain modes are supported:

**`chain: "assetDetails"`** — one sub-fetch per device:
1. Derive the API base from `auth.url` (strip `/public/auth`).
2. Pre-flight check the role `Get Asset Details` against `$script:UserRoles`. If denied, skip the loop and pad results with empty `asset_details`.
3. For each device with a non-empty `alias`, GET `/asset/details?search=device.alias:<URL-encoded alias>`. `device.id` is **not** a valid search key (unsupported per `api.doc.json`).
4. After the first 401 or 403, abort the rest of the loop and pad remaining devices.

**`chain: "assetConfigBackup"`** — NCM-centric configuration-backup report (last 3 config history entries per NCM device):
1. **Auth is delegated to Node + Playwright.** The internal Vue/SPA app renders the NCM device list client-side and federates auth through a separate IDP — neither of which PowerShell can drive reliably. The chain shells out to `tools/get-ncm-map.js` (headless Edge via Playwright) which performs the full SAML SSO, drives the UI flow (Power plant → List → search by name → View/edit), activates the NCM tab, and dumps the canonical `ncm_device_id ↔ hostname` map plus the browser's session cookies + CSRF token. `Import-BrowserCookies` then builds a `WebRequestSession` from those cookies so the subsequent per-device subconfig calls reuse the same session.
2. **Operator setup (one-time)**: install Node.js LTS, then from `tools/`: `npm install` and `npx playwright install msedge`. The PowerShell side detects a missing Node binary and surfaces a clear setup error.
3. **WPP context lookup table.** Each WPP device from the primary `/devices?powerplant_id=<id>` response is indexed under multiple candidate NCM-name forms so the CSV can carry WPP context (alias, ip) where there's a match:
   - Raw alias (catches `CIAS-HUB-9998-VES1-WAN1`)
   - Raw name
   - Name with country prefix stripped (`DE-SP-...` → `SP-...`)
   - Alias with `SUITCASE-WAN#` → `VES1-WAN#`
   - Alias with `SUITCASE-SW` → `VES1-CORE-SW1`
4. **Per NCM device** (iterating the parsed map): call `/get-ncm-device-subconfig` via `Build-NcmSubconfigUrl` (`data[ncm_device_id]`, `data[hostname]`, length=3) with the session headers. Client-side-sort the response by `received_at` desc and take top 3.
5. **Output**: `ConfigBackup_<stamp>.json` (full nested `{ncm_hostname, ncm_device_id, wpp_device, configs}` records) and `ConfigBackup_<stamp>.csv` with **`;` (semicolon) delimiter** per operator requirement. Columns:
   - NCM identity: `NCM_DeviceID; NCM_Hostname`
   - WPP context (best-effort): `WPP_DeviceID; WPP_Alias; WPP_IpAddr`
   - Per-config slot (1, 2 or 3 rows per NCM device): `ConfigSlot; ConfigID; NCMConfigurationID; Filename; Status; Current; ReceivedAt; LastConfigChangeAt; LastConfigChangeBy; BaseTemplate; GlobalOptions; BootSystem; ApprovalStatus`
   - Error/empty rows carry the diagnostic marker in `Status` (`<no combos discovered>`, `<no HAS CHANGES>`, `<subconfig error N>`, `<aborted>`, `<no NCM record for this WPP device>`).
6. **Audit rows for WPP devices with no NCM record.** After the NCM loop, any WPP device whose id is not in the matched set is appended to the CSV with `Status = "<no NCM record for this WPP device>"`. The report therefore covers every WPP device in the powerplant, not only the NCM-enrolled subset.
7. **Counters / summary**: `cfgHits` (device with ≥1 `HAS CHANGES` config), `cfgNoCombos` (no `base_template`/`boot_system` combos discovered), `cfgNoHasChanges` (combos returned data but no `HAS CHANGES` rows), `cfgErrors` (non-2xx or `<aborted>`). Single summary line `Chain complete: ncm=N combos=C hits=H no_combos=X no_has_changes=Y error=Z | wpp_unmatched=U`.
8. **401/419 on the internal endpoint** aborts the remaining NCM iterations with `<aborted>` rows; re-running the script triggers a fresh SAML login.

**`chain: "monthlyBackupRate"`** — NCM-centric monthly backup-rate report (one row per device, for a single calendar month):
1. **Reuses the `assetConfigBackup` discovery + auth** (Playwright NCM map, `Import-BrowserCookies`, WPP context index) and `Build-NcmSubconfigUrl` paging. The `assetConfigBackup` branch itself is left unchanged.
2. **Target month**: parameter `-Month "yyyy-MM"` (`[ValidatePattern]` `^\d{4}-(0[1-9]|1[0-2])$`). Default = the **previous calendar month relative to today**, via `DateTime.AddMonths(-1)` (so a run on the 1st of January reports the prior December) and `DateTime.DaysInMonth` (leap-aware). Window is half-open `[firstOfMonth 00:00:00, firstOfNextMonth 00:00:00)`.
3. **Backup rate**: `RatePct = DistinctDaysWithBackup ÷ DaysInMonth × 100`, capped at 100%. A backup of **either** status (`IDENTICAL` or `HAS CHANGES`) counts. `received_at` is parsed with `[datetime]::ParseExact`/`TryParseExact` under `InvariantCulture`; unparseable timestamps are skipped (logged DEBUG).
4. **Per device/combo paging stops early**: the endpoint returns newest-first, so paging halts on the first row older than the window start (older rows are irrelevant). The v1.4.1 guards (`recordsTotal`, short/empty page, hard page cap = 50) bound the walk. Backups are **de-duplicated by row `id`** across combos and overlapping pages so the rate cannot be inflated.
5. **Output**: `MonthlyBackupRate_<yyyy-MM>_<stamp>.json` (aggregate-only objects — no raw payload, no usernames) and `MonthlyBackupRate_<yyyy-MM>_<stamp>.csv` (**`;` delimiter**). Columns: `NCM_DeviceID; NCM_Hostname; WPP_DeviceID; WPP_Alias; WPP_IpAddr; Month; BackupCount; DistinctDaysCovered; DaysInMonth; RatePct; FirstBackupAt; LastBackupAt; Note`.
6. **Every WPP device represented**: 0-backup devices emit `RatePct=0`; no-combos / `<subconfig error N>` / `<aborted>` / `<no backups in month>` / `<no NCM record for this WPP device>` are carried in the `Note` column.
7. **Scheduling**: the chain self-computes the previous month, so it runs unattended via `pwsh -NonInteractive -File Device-Reports.ps1 -EndpointIndex 8` on a Task Scheduler monthly (day-1) trigger. `-Month` is for re-runs/back-fill only.
8. **Summary line**: `Chain complete: month=YYYY-MM ncm=N with_backups=W zero=Z no_combos=X error=E | wpp_unmatched=U`.

**`chain: "assetDetailsAndNcm"`** — per-device asset call plus per-device NCM call, with derived NCM key:
1. **Why per-device for NCM:** prod's Kong gateway does not register the bulk `/api/v1/ncm/devices` route ("no Route matched"), the legacy `/api/v1/ncmdetails` path returns 404, and `/api/v1/devices?...&accessor=ncm` returns 500 Internal Server Error. The only NCM path that works on prod is per-device `/api/v1/ncm/device/by-device-name?device_name=<n>` (role: `Get NCM By Device`).
2. **NCM key derivation (`Resolve-NcmDeviceName` helper):** NCM stores devices under names like `SP-60423-VES1-WAN1` (powerplant SP number + sublocation + role), NOT the WPP `device.name` (which carries a `DE-` prefix) nor the customer `alias`. Rules:
   - WPP `name` matches `^DE-SP-` → NCM key = `name` minus leading 2-letter country prefix.
   - WPP `alias` ends with a sublocation tail (`VES#…`, `WTG#…`, `NRP#…`, `WNC#…`, `PMC#…`, `WAN#`) AND a powerplant SP number is known → NCM key = `<sp_number>-<matched tail>`.
   - Otherwise (NAT/CUSTOMER placeholders, per-site CIAS-SUITCASE devices that belong to their own SP numbers, etc.) → return `$null`, **skip the NCM call** for this device (counted as `skipped`, not as miss).
3. **Powerplant SP number lookup:** before the chain loop, one `GET /api/v1/powerplants?search=id:<powerplant_id>` resolves the powerplant's `sp_number` (e.g. `SP-60423`). Cached in `$ppSpNumber` for the duration of the run. If this lookup fails, non-plant-gear devices are skipped for NCM (the `DE-SP-` rule still works without it).
4. **Asset call:** same as `assetDetails` (per device, uses `device.alias`, role `Get Asset Details`). Asset and NCM fail independently.
5. **404 from NCM is "no record" — silent.** Four counters track outcomes: `ncmHits` (200 with a record), `ncmMisses` (no record returned — 404 or empty 200), `ncmSkipped` (no NCM-canonical name derivable), `ncmErrors` (anything else, e.g. 5xx). Summary line `NCM lookup: H hit(s), M miss(es) (not enrolled), S skipped (no NCM mapping), E error(s).` is logged after the loop.
6. **401/403 on NCM** aborts remaining NCM calls and logs once at ERROR. Non-404 errors log WARN with response body. Asset call retains its own 401/403 early-abort.
7. **`Verbose` mode** emits one DEBUG line per device showing the resolved NCM name (or `<skip>`), so the operator can validate the derivation rule against their fleet.

**`chain: "assetSoftware"`** — per-device asset call focused on **running software state** (OS, firmware, software/image version, serial). Reuses the `assetDetails` fan-out technique verbatim (alias-based `GET /asset/details?search=device.alias:<alias>`, role `Get Asset Details` pre-flight, FR12 early-abort on first 401/403), with two purpose-specific differences:

1. **Defensive field resolution.** The `/asset/details` 200 body shape is unverified (every observed response is `null`; the OpenAPI response schema is `{}`). Software columns are therefore resolved by a `$resolveField` helper that probes a list of candidate field-name spellings (PSObject property access is case-insensitive, so only distinct spellings are listed), first on the asset record and then one level into common container objects (`software`, `attributes`, `inventory`, `details`). Non-scalar matches are serialized to compact JSON so a CSV cell never contains `System.Object[]`. A diagnostic `AssetFieldsSeen` column lists the record's top-level field names so the first live 200 reveals the real schema for future column pinning.
2. **Redaction (No-PII, CLAUDE.md #6/#7).** The CMDB payload can carry secrets/PII (`snmp_community`, `ftp_password`, `encryption_password`, `email`, …). Before the aggregated JSON is written to disk, every record (device + asset_details) is passed through a recursive `$redact` pass that masks the **value** of any property whose **name** matches the denylist `pass(word)?|secret|community|credential|private_key|token|encryption|ftp_user|api_key|email` as `<redacted>`. Secret-like field **names** are likewise masked as `<redacted-key>` in `AssetFieldsSeen`. The CSV's resolved software columns (non-secret by definition) are taken from the unredacted record.

### FR9 — Chain output
**`chain: "assetDetails"`** writes `AssetDetails_<stamp>.json` (joined `{device, asset_details}` records, depth 30) and `AssetDetails_<stamp>.csv` (one row per asset record; one empty-asset row per device when nothing returned).

**`chain: "assetDetailsAndNcm"`** writes `AssetNcmDetails_<stamp>.json` (joined `{device, asset_details, ncm_details}` records, depth 50) and `AssetNcmDetails_<stamp>.csv` with the same device + asset columns as above plus five NCM columns sourced from the `NcmDevice` schema in `api.doc.json`: `NCM_Name`, `NCM_DeviceID`, `NCM_BaseTemplate`, `NCM_GlobalOptions`, `NCM_RegionalOptions`. The two `*_Options` fields are objects in the API response and are serialized to compact JSON strings for the CSV; full payload remains in the JSON file.

**`chain: "assetSoftware"`** writes `AssetSoftware_<stamp>.json` (joined `{device, asset_details}` records, depth 50, **redacted** per FR8) and `AssetSoftware_<stamp>.csv` (one row per asset record; one row per device when nothing returned). Columns: `DeviceID, DeviceName, DeviceAlias, PowerplantID, Mac_Address, Ip_address` (device identity, reused from FR9 above), `Manufacturer, Model` (from the device record), `OS, OS_Version, Firmware_Version, Software_Image, SerialNumber, AssetStatus, LastSeen` (resolved defensively; `null` when absent), and `AssetFieldsSeen` (the discovery diagnostic). The empty-asset row and the populated row share an identical column set/order (Export-Csv derives headers from the first row).

When any chain runs, the default device CSV (FR7) is skipped.

### FR10 — Permission discovery
After a successful auth:
1. Decode the JWT payload (base64url, strip-padding-tolerant).
2. Recursively scan the JWT payload + raw auth response for these claim names: `userRoles, userRole, user_roles, roles, permissions, scopes, authorities, groups`. Recurse into `data` and `user`.
3. Each claim may be a JSON array, a string, a dictionary, or an object whose property values are role names; all four shapes are flattened to a string array.
4. Empty discovery is non-fatal — log a WARN, dump the JWT and auth-response top-level keys for diagnosis, and proceed permissively.

### FR11 — Endpoint → role map
Static mapping of URL-substring to required role, sourced from `api.doc.json` "`Role :`" markers. Used by the chain pre-flight (FR8.3) and reusable for any other gated call. Order: most-specific patterns first.

### FR12 — Early-abort on first 401/403
In the chain loop, the first call returning 401 or 403 logs the status, server body, and aborts remaining calls with one ERROR line ("Aborting remaining N call(s)"). Each remaining device is added to results with `asset_details=$null` so the CSV/JSON shape stays consistent.

### FR13 — Sectioned log
Output is structured into sections, printed both to console (cyan) and the log file (plain):
1. `INFORMATION` — version, paths, endpoint metadata.
2. `AUTHENTICATION` — `.env` load + token request.
3. `PERMISSIONS` — discovered roles or claim-key dump.
4. `QUERY` — main endpoint call + JSON save + summary.
5. `CHAIN: ASSET DETAILS` — only when the chain runs.
6. `OUTPUT` — final CSV/JSON write summary.
7. `END`.

Section content lines use the format `[LEVEL]   <message>` (level padded to 9 chars, two-space indent under section). No timestamps in line bodies.

### FR14 — Daily log file
One log file per day at `log\WPPConfQuery_<YYYY-MM-DD>.log`. All runs that day append to the same file. The folder is auto-created.

### FR15 — Verbose gating
The QUERY-section per-item summary (`[N] id=X name=Y`) emits only when invoked with `-Verbose` or `-Debug`. Default runs are quiet for that block. DEBUG-level lines are also gated everywhere — both console and file.

**Exception (intentional):** the per-device chain line `[{i}/{total}] {alias} -> {N} asset record(s)` is logged at **INFO** so the operator sees one comprehensive, simple line per fetched device by default. Failure counterpart `[{i}/{total}] {alias} asset/details failed: {msg}` is logged at **WARN** in the same shape.

### FR16 — Console = log
Console output and log-file output contain the exact same text (modulo console color codes). No console-only or file-only side messages.

**Sanctioned console-only UI elements** (do not appear in the log file, by design):
- The interactive endpoint menu (`Show-EndpointMenu`).
- The chain progress gauge (`Write-Progress -Activity "Fetching asset details"`) — a transient gauge rendered to the host progress stream, dismissed via `Write-Progress -Completed` in a `finally` block.

---

## 3. Non-Functional Requirements

### NFR1 — Read-only against the API
Only `POST /public/auth` and `GET <endpoint>`. No PUT/PATCH/DELETE.

### NFR2 — No hardcoded secrets
Credentials live in `conf\.env`. The script must never print the password (only its character length, at DEBUG level).

### NFR3 — TLS 1.2 minimum
Force `[Net.ServicePointManager]::SecurityProtocol` to include TLS 1.2 for PS 5.1 environments. Failure to set is a WARN, not fatal.

### NFR4 — PowerShell version
Targets **PowerShell 5.1+**, with PowerShell 7+ recommended. Both code paths are present (PS 5.1 cert-trust shim, PS 7 `SkipCertificateCheck` parameter, PS 7 `$_.ErrorDetails.Message` body capture with PS 5.1 stream fallback).

### NFR5 — No file overwrites
JSON and CSV outputs are timestamped (`yyyyMMdd_HHmmss`) so concurrent runs and same-day reruns never overwrite. Existing files are never modified.

### NFR6 — Per-endpoint output isolation
Output is partitioned `<OutputFolder>\<endpoint-slug>\<YYYY-MM-DD>\` so per-endpoint result sets never mix.

### NFR7 — Try/catch coverage
Every external operation has `try`/`catch`: config load, `.env` parse, auth POST, JWT decode, role scan, main GET, response save, default CSV build, chain pre-check, per-device GET, chain JSON save, chain CSV build, log file write. Permission-check failures degrade to permissive, never fatal.

### NFR8 — Error body capture
On any HTTP failure, the script attempts to log the server response body. Captures from `$_.ErrorDetails.Message` (PowerShell 7) and falls back to `$_.Exception.Response.GetResponseStream()` (PowerShell 5.1).

### NFR9 — Permission check is non-blocking when claims are unknown
If `$script:UserRoles` is empty (claim not found), `Test-EndpointAllowed` returns `Allowed=$true` so the call still goes out. The catch block + early-abort (FR12) handle the actual 401 cleanly.

### NFR10 — URL safety
Device alias values may contain spaces and parentheses (e.g. `NAT Device(10.56.0.107)`). The chain URL-encodes the alias via `[System.Uri]::EscapeDataString` before concatenation.

### NFR11 — Logging concurrency tolerance
Log writes use `Add-Content -Encoding UTF8` inside a try/catch — a transiently locked log file does not crash the script.

### NFR12 — Deterministic exit codes
- `0` — success or user-cancelled at menu.
- `1` — config or `.env` load failure.
- `2` — authentication failure or token field not recognized.
- `3` — main endpoint GET failure.
- `4` — JSON output write failure.
- `5` — reserved for permission denial (currently unused on main path; was used by removed pre-flight check).

### NFR13 — Idempotence within a day
Re-running the same endpoint on the same day produces a new timestamped JSON+CSV pair side-by-side with prior runs and appends to the daily log. State on disk is purely additive.

---

## 4. Directory Layout

```
c:\Jobs\Scripts\Device-Report\
├── conf\
│   ├── .env                              (NFR2: WPP_USERNAME, WPP_PASSWORD)
│   └── conf.json                         (FR1: endpoints + auth URL)
├── log\
│   └── WPPConfQuery_<YYYY-MM-DD>.log     (FR14: appended across runs)
├── Output\
│   └── <endpoint-slug>\<YYYY-MM-DD>\
│       ├── Powerplants_<stamp>.json      (FR6)
│       ├── Devices_<stamp>.csv           (FR7)
│       ├── UnknownDevices_<stamp>.csv    (FR7)
│       ├── AssetDetails_<stamp>.json     (FR9)
│       ├── AssetDetails_<stamp>.csv      (FR9)
│       ├── AssetNcmDetails_<stamp>.json  (FR9, chain assetDetailsAndNcm)
│       ├── AssetNcmDetails_<stamp>.csv   (FR9, chain assetDetailsAndNcm)
│       ├── AssetSoftware_<stamp>.json    (FR9, chain assetSoftware — redacted)
│       └── AssetSoftware_<stamp>.csv     (FR9, chain assetSoftware)
├── specs\requirements.md                 (this file)
├── api.doc.json                          (Vestas WPP-CONF OpenAPI doc)
├── claude.md                             (project hub)
└── Device-Reports.ps1                    (main interactive script)
```

---

## 5. Script Parameters (`Device -Reports.ps1`)

| Parameter | Default | Purpose |
|---|---|---|
| `-EnvFile` | `conf\.env` | Path to credentials |
| `-ConfigFile` | `conf\conf.json` | Path to endpoint config |
| `-EndpointIndex` | `0` (menu) | 1-based index into `conf.endpoints` |
| `-EndpointUrl` | (none) | Bypass conf entirely with a custom URL |
| `-OutputFolder` | `Output\` | Output root |
| `-LogFolder` | `log\` | Daily log root |
| `-AuthUrl` | from conf.json | Override auth endpoint |
| `-SkipCertificateCheck` | `$false` | Bypass TLS validation (lab use only) |
| `-Verbose`, `-Debug` | off | Reveal DEBUG-level lines (FR15) |

---

## 6. Endpoint → Role Map (FR11)

| URL substring | Required role |
|---|---|
| `/asset/baseline/desired-states` | Get Asset Baseline Desired States |
| `/asset/details` | Get Asset Details |
| `/asset/structured` | Get Asset Structured |
| `/devices/without-credentials` | Get Devices Without Creds |
| `/devices/acl` | Get Devices ACL |
| `/device/models` | Get Device Models |
| `/device/types` | Get Device Types |
| `/devices` | Get Devices |
| `/ncm/device/by-device-name` | Get NCM By Device |
| `/ncm/device/by-sp-number` | Get NCM By Sp number |
| `/ncm/devices` | Get NCM |
| `/powerplants` | Get Powerplants |
| `/integration-contract/snow` | Get Snow Integration Contract |

Order is most-specific-first; the first match wins.

---

## 7. Known Limitations

- **`Get-AssetDetails.ps1` is functionally redundant** with the main script's `chain: assetDetails` mode and uses the unsupported `device.id` filter. It still exists at the user's request.
- **Asset-detail CSV columns are speculative** (`AssetID, AssetName, AssetType, Manufacturer, Model, SerialNumber, Status, UpdatedAt`) — derived without a successful sample response. The JSON output remains complete; only the CSV columns may need adjustment once a 200 response is observed.
- **`chain: "assetSoftware"` software columns are unverified.** No 200 from `/asset/details` has ever been observed, so the OS/firmware/version candidate-name lists in `$resolveField` are best-effort guesses. The chain degrades safely (empty software columns, full device context retained) and the `AssetFieldsSeen` diagnostic column is the instrument to close this gap: on the first live 200, inspect it to learn the real field names. **Follow-up:** once the real schema is known, pin the exact column names and switch to a server-side `filter=` allowlist on the `/asset/details` request so secrets/PII never reach the client (preferred over the current client-side `$redact` denylist, which is the interim No-PII control).
- **Role-name matching is exact** between the JWT `userRoles` claim and the role labels in `api.doc.json`. If the API rebrands a role label (e.g. "Get Devices" → "GetDevices"), the chain pre-flight may produce false positives. Early-abort on 401 (FR12) is the safety net.
