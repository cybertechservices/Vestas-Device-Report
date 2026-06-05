<#
.SYNOPSIS
    Authenticates against the WPP-CONF API and queries powerplant information.

.DESCRIPTION
    Two-step workflow:
      1. POST credentials to /public/auth to obtain a bearer token.
      2. GET /powerplants with search and 'with' parameters, using the token.

    Credentials are loaded from a local .env file (key=value format) so they
    are NEVER hardcoded in the script. The .env file path defaults to the
    script directory but can be overridden.

    The script is read-only against the API (auth POST + powerplants GET).
    Output is written to a timestamped JSON file and a structured log file
    in the chosen output folder. No existing files are modified.

.PARAMETER EnvFile
    Path to the .env file containing WPP_USERNAME and WPP_PASSWORD.
    Defaults to ".\.env" relative to the script.

.PARAMETER ConfigFile
    Path to the JSON config file with version, auth url, and endpoint list.
    Defaults to ".\conf.json" relative to the script.

.PARAMETER EndpointIndex
    1-based index of the endpoint to query (skips the interactive menu).
    Default: 0 (show the menu).

.PARAMETER EndpointUrl
    Explicit endpoint URL. If supplied, overrides both the menu and conf.json.

.PARAMETER OutputFolder
    Folder for the JSON response and log file. Default: ".\Output".

.PARAMETER AuthUrl
    Authentication endpoint override. If not supplied, the value from conf.json is used.

.PARAMETER SkipCertificateCheck
    Bypass TLS validation (use only for lab/test endpoints with self-signed certs).

.EXAMPLE
    .\Device-Reports.ps1

.EXAMPLE
    .\Device-Reports.ps1 -EndpointIndex 2 -OutputFolder "C:\Temp\WPP"

.NOTES
    Author       : Generated for Eric
    Requires     : PowerShell 5.1+ (PowerShell 7+ recommended)
    Read-only    : Yes — only POST /auth and GET against the chosen endpoint are called.
    Rollback     : See ROLLBACK.md in the script folder.
#>

[CmdletBinding()]
param(
    [string]$EnvFile              = (Join-Path $PSScriptRoot "conf\.env"),
    [string]$ConfigFile           = (Join-Path $PSScriptRoot "conf\conf.json"),
    [int]   $EndpointIndex        = 0,
    [string]$EndpointUrl,
    [string]$OutputFolder         = (Join-Path $PSScriptRoot "Output"),
    [string]$LogFolder            = (Join-Path $PSScriptRoot "log"),
    [string]$AuthUrl,
    [ValidatePattern('^\d{4}-(0[1-9]|1[0-2])$')]
    [string]$Month,                # target month "yyyy-MM" for the monthlyBackupRate
                                   # chain; default = previous calendar month.
    [switch]$SkipCertificateCheck
)

#region ---------- Helpers ----------------------------------------------------

# Run timestamp for filenames; daily-rolled log path under $LogFolder.
$script:RunStamp = Get-Date -Format "yyyyMMdd_HHmmss"
if (-not (Test-Path -LiteralPath $LogFolder)) {
    New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
}
$script:LogPath = Join-Path $LogFolder ("WPPConfQuery_{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))

function Write-Log {
    <#
        Standard log line, indented two spaces under the current section header.
        Same text in console and file (file gets no ANSI color). DEBUG lines are
        emitted only when -Verbose or -Debug is passed.
    #>
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","DEBUG","SUCCESS")] [string]$Level = "INFO",
        [int]$IndentLevel = 1
    )
    $indent = '  ' * [Math]::Max($IndentLevel, 0)
    # Pad level tag to 9 chars so messages line up regardless of [INFO]/[ERROR]/[SUCCESS] width.
    $line   = "{0,-9} {1}{2}" -f ("[$Level]"), $indent, $Message

    $debugMode = ($VerbosePreference -ne 'SilentlyContinue') -or ($DebugPreference -ne 'SilentlyContinue')
    $emit      = $true
    if ($Level -eq "DEBUG" -and -not $debugMode) { $emit = $false }

    if ($emit) {
        switch ($Level) {
            "ERROR"   { Write-Host $line -ForegroundColor Red }
            "WARN"    { Write-Host $line -ForegroundColor Yellow }
            "SUCCESS" { Write-Host $line -ForegroundColor Green }
            "DEBUG"   { Write-Host $line -ForegroundColor DarkGray }
            default   { Write-Host $line }
        }
        if ($script:LogPath) {
            try { Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 } catch { }
        }
    }
}

function Write-LogSection {
    <#
        Section header. Unindented, no timestamp/level. Visible separator
        between phases (Information, Authentication, Query, etc.).
    #>
    param([Parameter(Mandatory)] [string]$Title)
    $line = "===== {0} =====" -f $Title.ToUpperInvariant()

    Write-Host ""
    Write-Host $line -ForegroundColor Cyan

    if ($script:LogPath) {
        try {
            Add-Content -Path $script:LogPath -Value ""    -Encoding UTF8
            Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
        } catch { }
    }
}

function ConvertTo-Slug {
    <#
        Lowercases, replaces runs of non-alphanumerics with '-', trims
        leading/trailing dashes. Returns 'default' if the result is empty.
    #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "default" }
    $s = ($Text.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($s)) { return "default" }
    return $s
}

function Import-Config {
    <#
        Loads conf.json. Throws if the file is missing or malformed.
        Expected shape:
          {
            "version": "x.y.z",
            "auth":      { "url": "https://..." },
            "endpoints": [ { "name": "...", "url": "https://..." }, ... ]
          }
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found at: $Path"
    }

    try {
        $cfg = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Failed to parse '$Path' as JSON: $($_.Exception.Message)"
    }

    if (-not $cfg.endpoints -or @($cfg.endpoints).Count -eq 0) {
        throw "Config '$Path' has no 'endpoints' entries."
    }
    if (-not $cfg.auth -or [string]::IsNullOrWhiteSpace($cfg.auth.url)) {
        throw "Config '$Path' is missing 'auth.url'."
    }
    return $cfg
}

function Show-EndpointMenu {
    <#
        Renders the script header + endpoint menu and returns the chosen
        endpoint object (with .name and .url). Returns $null if the user quits.
    #>
    param(
        [Parameter(Mandatory)] $Config
    )

    $endpoints = @($Config.endpoints)
    $version   = if ($Config.version) { $Config.version } else { "unknown" }

    while ($true) {
        Write-Host ""
        Write-Host "======================================================" -ForegroundColor Cyan
        Write-Host ("  Device-Reports.ps1   v{0}" -f $version)         -ForegroundColor Cyan
        Write-Host "======================================================" -ForegroundColor Cyan
        Write-Host "  Available API endpoints:" -ForegroundColor Cyan
        Write-Host ""

        for ($i = 0; $i -lt $endpoints.Count; $i++) {
            $ep = $endpoints[$i]
            Write-Host ("  [{0}] {1}" -f ($i + 1), $ep.name) -ForegroundColor White
            Write-Host ("      {0}"   -f $ep.url)            -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  [Q] Quit" -ForegroundColor White
        Write-Host "======================================================" -ForegroundColor Cyan

        $choice = Read-Host "Select an endpoint"
        if ([string]::IsNullOrWhiteSpace($choice)) { continue }
        if ($choice -match '^[Qq]') { return $null }

        [int]$n = 0
        if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $endpoints.Count) {
            return $endpoints[$n - 1]
        }
        Write-Host "Invalid selection. Try again." -ForegroundColor Yellow
    }
}

function Import-DotEnv {
    <#
        Reads a .env file and returns a hashtable of key/value pairs.
        Supports:
          - KEY=VALUE
          - Optional surrounding single or double quotes on the value
          - Lines beginning with # are ignored
          - Blank lines are ignored
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw ".env file not found at: $Path"
    }

    $vars = @{}
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        if ($line.StartsWith("#"))               { return }

        $eq = $line.IndexOf("=")
        if ($eq -lt 1) { return }   # malformed line, skip silently

        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim()

        # Strip surrounding quotes if present
        if ( ($val.StartsWith('"') -and $val.EndsWith('"')) -or
             ($val.StartsWith("'") -and $val.EndsWith("'")) ) {
            $val = $val.Substring(1, $val.Length - 2)
        }

        $vars[$key] = $val
    }
    return $vars
}

function Get-RequestSplat {
    <#
        Builds a splat hashtable for Invoke-RestMethod with optional
        SkipCertificateCheck (only on PS 6+).
    #>
    param([hashtable]$Base)

    $splat = @{} + $Base
    # Default network timeout so a stalled connection fails fast with a logged
    # error instead of blocking indefinitely. A missing timeout is what let the
    # v1.5.0 06-03 run hang forever on the powerplant-name lookup (the process
    # had to be killed before its try/catch could log anything). Callers may
    # override by passing their own TimeoutSec in $Base.
    if (-not $splat.ContainsKey('TimeoutSec')) { $splat['TimeoutSec'] = 120 }
    if ($SkipCertificateCheck) {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $splat["SkipCertificateCheck"] = $true
        } else {
            # PS 5.1 fallback: globally trust all certs for this session.
            # Do NOT use this in production unless you fully trust the network path.
            Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@ -ErrorAction SilentlyContinue
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll
        }
    }
    return $splat
}

function Get-JwtPayload {
    <#
        Decodes the payload (middle segment) of a JWT (header.payload.signature).
        Returns the parsed payload object, or $null on any failure.
    #>
    param([string]$Jwt)
    try {
        if ([string]::IsNullOrWhiteSpace($Jwt)) { return $null }
        $parts = $Jwt.Split('.')
        if ($parts.Count -lt 2)                  { return $null }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '='  }
        }
        $bytes = [Convert]::FromBase64String($payload)
        $json  = [System.Text.Encoding]::UTF8.GetString($bytes)
        return $json | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-RolesFromObject {
    <#
        Best-effort scan of an object for common role/permission/scope claim
        fields. Recurses into .data and .user. Returns a unique string array.
    #>
    param($Obj)
    $found = @()
    if ($null -eq $Obj) { return $found }
    try {
        # Vestas WPP-CONF JWT exposes the role list under "userRoles" as a JSON
        # object keyed by index, e.g. { "1": "Get Devices", "2": "..." }.
        # We accept arrays, dictionaries, and PSCustomObjects (object claims).
        foreach ($field in @("userRoles","userRole","user_roles","roles","permissions","scopes","authorities","groups")) {
            if ($Obj.PSObject.Properties.Name -contains $field -and $Obj.$field) {
                $val = $Obj.$field
                if ($val -is [System.Array]) {
                    $found += ($val | ForEach-Object { [string]$_ })
                } elseif ($val -is [string]) {
                    $found += [string]$val
                } elseif ($val -is [System.Collections.IDictionary]) {
                    $found += ($val.Values | ForEach-Object { [string]$_ })
                } else {
                    # PSCustomObject (object-style claim): take all property values.
                    try {
                        $found += ($val.PSObject.Properties | ForEach-Object { [string]$_.Value })
                    } catch {
                        $found += [string]$val
                    }
                }
            }
        }
        foreach ($nest in @("data","user")) {
            if ($Obj.PSObject.Properties.Name -contains $nest -and $Obj.$nest) {
                $found += (Get-RolesFromObject -Obj $Obj.$nest)
            }
        }
    } catch { }
    return ($found | Where-Object { $_ } | Sort-Object -Unique)
}

# URL-substring -> required role. Order: most specific patterns first.
# Sourced from api.doc.json "Role : <name>" markers.
$script:EndpointRoleMap = @(
    @{ pattern = "/asset/baseline/desired-states"; role = "Get Asset Baseline Desired States" }
    @{ pattern = "/asset/details";                 role = "Get Asset Details" }
    @{ pattern = "/asset/structured";              role = "Get Asset Structured" }
    @{ pattern = "/devices/without-credentials";   role = "Get Devices Without Creds" }
    @{ pattern = "/devices/acl";                   role = "Get Devices ACL" }
    @{ pattern = "/device/models";                 role = "Get Device Models" }
    @{ pattern = "/device/types";                  role = "Get Device Types" }
    @{ pattern = "/devices";                       role = "Get Devices" }
    @{ pattern = "/ncm/device/by-device-name";     role = "Get NCM By Device" }
    @{ pattern = "/ncm/device/by-sp-number";       role = "Get NCM By Sp number" }
    @{ pattern = "/ncm/devices";                   role = "Get NCM" }
    @{ pattern = "/powerplants";                   role = "Get Powerplants" }
    @{ pattern = "/integration-contract/snow";     role = "Get Snow Integration Contract" }
)

function Test-EndpointAllowed {
    <#
        Returns @{ Allowed, Required, Reason }.
        Allowed=$true if: URL has no mapped role, OR mapped role is in $UserRoles,
                          OR $UserRoles is empty (roles unknown -> permissive).
    #>
    param(
        [string]   $Url,
        [string[]] $UserRoles
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Url)) {
            return @{ Allowed = $true; Required = $null; Reason = "no URL provided" }
        }
        $required = $null
        foreach ($entry in $script:EndpointRoleMap) {
            if ($Url -like ("*" + $entry.pattern + "*")) {
                $required = $entry.role
                break
            }
        }
        if (-not $required) {
            return @{ Allowed = $true; Required = $null; Reason = "no role mapping for URL" }
        }
        if (-not $UserRoles -or $UserRoles.Count -eq 0) {
            return @{ Allowed = $true; Required = $required; Reason = "user roles unknown - proceeding without check" }
        }
        if ($UserRoles -contains $required) {
            return @{ Allowed = $true; Required = $required; Reason = "role granted" }
        }
        return @{ Allowed = $false; Required = $required; Reason = "user lacks role '$required'" }
    } catch {
        # Never block on a check error - degrade to permissive.
        return @{ Allowed = $true; Required = $null; Reason = "check failed: $($_.Exception.Message)" }
    }
}

function Get-HtmlForm {
    <#
        Parses the first <form> in $Html and returns @{
            Action    = <absolute URL>
            Method    = "GET" | "POST"
            Inputs    = ordered hashtable of name=value for every <input>
            UserField = name of the first text/email-style input (best guess)
            PassField = name of the first password-type input
        }
        Returns $null if no form found. Used to drive the SAML flow without
        hardcoding field names — every hidden field (SAMLRequest, CSRF,
        AuthState, etc.) round-trips back to the IDP unchanged.
    #>
    param(
        [Parameter(Mandatory)] [string] $Html,
        [Parameter(Mandatory)] [string] $BaseUrl
    )

    if (-not ($Html -match '(?si)<form\b([^>]*)>(.*?)</form>')) { return $null }
    $formAttrs = $Matches[1]
    $formInner = $Matches[2]

    $action = $BaseUrl
    if ($formAttrs -match 'action\s*=\s*["'']([^"'']*)["'']') {
        $rawAction = $Matches[1]
        if (-not [string]::IsNullOrWhiteSpace($rawAction)) {
            try { $action = [string](New-Object System.Uri([Uri]$BaseUrl, $rawAction)) }
            catch { $action = $rawAction }
        }
    }
    $method = "POST"
    if ($formAttrs -match 'method\s*=\s*["'']([^"'']+)["'']') {
        $method = $Matches[1].ToUpperInvariant()
    }

    $inputs    = [ordered]@{}
    $userField = $null
    $passField = $null
    foreach ($m in [regex]::Matches($formInner, '(?si)<input\b([^>]*?)/?>')) {
        $attrs = $m.Groups[1].Value
        $name  = if ($attrs -match 'name\s*=\s*["'']([^"'']*)["'']')  { $Matches[1] } else { $null }
        $value = if ($attrs -match 'value\s*=\s*["'']([^"'']*)["'']') { $Matches[1] } else { '' }
        $type  = if ($attrs -match 'type\s*=\s*["'']([^"'']+)["'']')  { $Matches[1].ToLowerInvariant() } else { 'text' }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $inputs[$name] = $value
        # Primary detection: standard input types.
        if ($type -eq 'password' -and -not $passField) { $passField = $name }
        elseif (($type -in @('text','email','tel')) -and -not $userField) { $userField = $name }
    }

    # Fallback: SPAs (Vue/Angular/React) often declare credential fields as
    # type="hidden" and bind visible inputs to them via v-model, so the
    # type-based heuristic misses them. Recover via common-name matching.
    if (-not $passField) {
        foreach ($candidate in @('password','_password','pwd','pass','passwd')) {
            if ($inputs.Contains($candidate)) { $passField = $candidate; break }
        }
    }
    if (-not $userField) {
        foreach ($candidate in @('username','_username','user','email','login','userid')) {
            if ($inputs.Contains($candidate)) { $userField = $candidate; break }
        }
    }

    return @{
        Action    = $action
        Method    = $method
        Inputs    = $inputs
        UserField = $userField
        PassField = $passField
    }
}

function Get-FinalUri {
    <#
        Returns the final URL from an Invoke-WebRequest response, tolerating
        the shape differences between PS 5.1 and PS 7+.
    #>
    param($Resp, [string]$Fallback)
    try { if ($Resp.BaseResponse.ResponseUri) { return [string]$Resp.BaseResponse.ResponseUri } } catch { }
    try { if ($Resp.BaseResponse.RequestMessage.RequestUri) { return [string]$Resp.BaseResponse.RequestMessage.RequestUri } } catch { }
    return $Fallback
}

function Connect-SamlSession {
    <#
        Performs SAML 2.0 SP-initiated SSO against wpp-conf.vestasext.net.

        Flow (browser-equivalent):
          1. GET <StartUrl> -> follow redirects to wpp-idp.vestasext.net/login?SAMLRequest=...
          2. Parse the IDP login form; fill in user/pass by detected field names;
             preserve all hidden inputs (CSRF, AuthState, SAMLRequest, etc.).
          3. POST credentials to the form's action URL.
          4. The IDP responds with HTML containing an auto-posting form whose
             action is wpp-conf.vestasext.net/saml2/acs and whose hidden inputs
             include SAMLResponse + RelayState.
          5. POST those values to /saml2/acs -> SP validates, sets session cookies,
             and redirects to the home page.
          6. GET one logged-in page to scrape the X-CSRF-TOKEN meta value for AJAX.

        Returns @{
            Session   = <WebRequestSession with session cookies>
            CsrfToken = <40-char X-CSRF-TOKEN value for AJAX headers>
        }
        Throws with a clear message on any failure.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
        Justification='Password sourced from .env at runtime, sent over HTTPS to the IDP form; identical risk profile to the existing public-API auth flow.')]
    param(
        [Parameter(Mandatory)] [string] $StartUrl,
        [Parameter(Mandatory)] [string] $Username,
        [Parameter(Mandatory)] [string] $Password
    )

    # Step 1: SP-initiated start. Invoke-WebRequest follows the 302 chain to the IDP login.
    $session = $null
    $resp1 = Invoke-WebRequest -Uri $StartUrl -SessionVariable session -UseBasicParsing -MaximumRedirection 10
    $url1  = Get-FinalUri -Resp $resp1 -Fallback $StartUrl

    # Step 2: parse the IDP login form.
    $idpHtml   = [string]$resp1.Content
    $loginForm = Get-HtmlForm -Html $idpHtml -BaseUrl $url1
    if (-not $loginForm) {
        # Dump enough of the HTML to confirm SPA vs server-rendered.
        $snippet = $idpHtml.Substring(0, [Math]::Min(2000, $idpHtml.Length))
        Write-Log ("IDP page (no <form> found): first 2000 chars below.") "ERROR"
        Write-Log $snippet "ERROR"
        throw "Could not find a login form on the IDP page (landed at $url1, HTML $($idpHtml.Length) bytes)."
    }
    if (-not $loginForm.UserField -or -not $loginForm.PassField) {
        # Diagnostic: tell the operator exactly which fields ARE present so we
        # can either widen the regex or pivot to a SPA strategy.
        $fieldList = if ($loginForm.Inputs.Count -gt 0) { ($loginForm.Inputs.Keys -join ', ') } else { '<none>' }
        Write-Log ("IDP form (action={0}): {1} input(s) found, names: {2}" -f $loginForm.Action, $loginForm.Inputs.Count, $fieldList) "ERROR"
        $snippet = $idpHtml.Substring(0, [Math]::Min(2000, $idpHtml.Length))
        Write-Log "First 2000 chars of IDP login HTML (so we can fix the parser):" "ERROR"
        Write-Log $snippet "ERROR"
        throw "Could not identify username/password inputs in the IDP login form (action=$($loginForm.Action)). See HTML dump above."
    }
    Write-Log ("IDP login form: action={0} user-field={1} pass-field={2} extra-fields={3}" `
        -f $loginForm.Action, $loginForm.UserField, $loginForm.PassField, ($loginForm.Inputs.Keys -join ',')) "DEBUG"

    # Step 3: fill credentials, preserve every other hidden input, POST.
    $body = @{}
    foreach ($k in $loginForm.Inputs.Keys) { $body[$k] = $loginForm.Inputs[$k] }
    $body[$loginForm.UserField] = $Username
    $body[$loginForm.PassField] = $Password

    try {
        $resp2 = Invoke-WebRequest -Uri $loginForm.Action -Method $loginForm.Method -Body $body `
                    -WebSession $session -UseBasicParsing -MaximumRedirection 10
    } catch {
        $sc = $null; $errBody = $null
        try { if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode } } catch { }
        try {
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $errBody = [string]$_.ErrorDetails.Message
            } elseif ($_.Exception.Response -and $_.Exception.Response.PSObject.Methods.Name -contains "GetResponseStream") {
                $stream  = $_.Exception.Response.GetResponseStream()
                $reader  = New-Object System.IO.StreamReader($stream)
                $errBody = $reader.ReadToEnd()
            }
        } catch { }
        $msg = "IDP credential POST to $($loginForm.Action) failed (status $sc): $($_.Exception.Message)"
        if ($errBody) { $msg = $msg + " | body: $errBody" }
        throw $msg
    }
    $url2 = Get-FinalUri -Resp $resp2 -Fallback $loginForm.Action

    # Step 4: response must contain an auto-posting form with SAMLResponse.
    $samlForm = Get-HtmlForm -Html ([string]$resp2.Content) -BaseUrl $url2
    if (-not $samlForm) {
        throw "IDP returned no auto-post form after credential submit (landed at $url2). Credentials likely rejected."
    }
    if (-not $samlForm.Inputs.Contains('SAMLResponse')) {
        throw "IDP response form is missing SAMLResponse — credentials rejected or the form changed shape (action=$($samlForm.Action))."
    }
    Write-Log ("SAML response form: action={0} fields={1}" -f $samlForm.Action, ($samlForm.Inputs.Keys -join ',')) "DEBUG"

    # Step 5: POST the SAMLResponse + RelayState to the SP's ACS.
    $body2 = @{}
    foreach ($k in $samlForm.Inputs.Keys) { $body2[$k] = $samlForm.Inputs[$k] }
    $resp3 = Invoke-WebRequest -Uri $samlForm.Action -Method $samlForm.Method -Body $body2 `
                -WebSession $session -UseBasicParsing -MaximumRedirection 10

    # Step 6: scrape X-CSRF-TOKEN meta value for AJAX. Try the landed page first;
    # fall back to GET / on the internal host if that page lacks the meta tag.
    $internalHostName = ([Uri]$samlForm.Action).Host
    $csrf = $null
    foreach ($html in @([string]$resp3.Content, $null)) {
        if (-not $html) {
            try {
                $r = Invoke-WebRequest -Uri ("https://{0}/" -f $internalHostName) `
                        -WebSession $session -UseBasicParsing -MaximumRedirection 10
                $html = [string]$r.Content
            } catch { continue }
        }
        if ($html -match 'name=["'']csrf-token["''][^>]*?content=["'']([^"'']+)["'']') {
            $csrf = $Matches[1]; break
        }
        if ($html -match 'content=["'']([^"'']+)["''][^>]*?name=["'']csrf-token["'']') {
            $csrf = $Matches[1]; break
        }
    }
    if ([string]::IsNullOrWhiteSpace($csrf)) {
        throw "Logged in but could not find the X-CSRF-TOKEN meta value on any post-login page."
    }

    return @{ Session = $session; CsrfToken = $csrf }
}

function Initialize-InternalSession {
    <#
        Lazy idempotent wrapper around Connect-SamlSession. Populates
        $script:InternalSessionData on success. Logs a single section header
        and a SUCCESS line with the cookie names and CSRF token length.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
        Justification='Pass-through to Connect-SamlSession; see suppression there.')]
    param(
        [Parameter(Mandatory)] [string] $StartUrl,
        [Parameter(Mandatory)] [string] $Username,
        [Parameter(Mandatory)] [string] $Password
    )
    if ($script:InternalSessionData) { return }

    Write-LogSection "INTERNAL-API AUTH"
    Write-Log ("SAML SSO via {0} ..." -f $StartUrl) "INFO"
    try {
        $auth = Connect-SamlSession -StartUrl $StartUrl -Username $Username -Password $Password
        $internalHostName = ([Uri]$StartUrl).Host
        $cookieNames = @($auth.Session.Cookies.GetCookies("https://$internalHostName") | ForEach-Object { $_.Name }) -join ', '
        $script:InternalSessionData = @{
            Session = $auth.Session
            Headers = @{
                "Accept"           = "application/json, text/javascript, */*; q=0.01"
                "X-CSRF-TOKEN"     = $auth.CsrfToken
                "X-Requested-With" = "XMLHttpRequest"
                # Same-origin Referer — some DataTables endpoints reject XHR without it.
                "Referer"          = "https://$internalHostName/"
            }
        }
        Write-Log ("SAML login OK — cookies: [{0}]; X-CSRF-TOKEN length: {1}" -f $cookieNames, $auth.CsrfToken.Length) "SUCCESS"
    } catch {
        Write-Log ("SAML login failed: {0}" -f $_.Exception.Message) "ERROR"
        throw
    }
}

function Get-NcmDeviceMapViaBrowser {
    <#
        Shells out to tools/get-ncm-map.js (Node + Playwright) to extract the
        ncm_device_id <-> hostname map for a powerplant from the internal SPA.
        Playwright handles the SAML SSO + Vue rendering that PowerShell can't.

        With combo discovery enabled (the default), each device also carries
        the distinct (base_template, boot_system_bootflash) pairs the app
        exposes for it — these are the Level-2 filters needed to drill into the
        Level-3 config history endpoint.

        Returns @{
            Devices    = @(
                [pscustomobject]@{
                    NcmDeviceId = <int>;
                    Hostname    = <string>;
                    Combos      = @( [pscustomobject]@{ BaseTemplate=''; BootSystem='' }, ... )
                },
                ...
            )
            CookieFile = <path to JSON with cookies + CSRF for session reuse>
        }
    #>
    param(
        [Parameter(Mandatory)] [int]    $PowerplantId,
        [Parameter(Mandatory)] [string] $SearchName,
        [switch]                         $SkipComboProbe
    )

    $toolsDir   = Join-Path $PSScriptRoot 'tools'
    $jsScript   = Join-Path $toolsDir 'get-ncm-map.js'
    $stamp      = $script:RunStamp
    $mapFile    = Join-Path $env:TEMP ("ncm-map-{0}.json"    -f $stamp)
    $cookieFile = Join-Path $env:TEMP ("ncm-cookies-{0}.json" -f $stamp)

    if (-not (Test-Path -LiteralPath $jsScript)) {
        throw "Browser extractor not found at $jsScript. From PowerShell: cd $toolsDir; npm install; npx playwright install msedge"
    }

    # Verify Node.js is installed.
    $nodeVer = $null
    try { $nodeVer = (& node --version 2>$null) } catch { }
    if ([string]::IsNullOrWhiteSpace($nodeVer)) {
        throw "Node.js not found on PATH. Install Node.js LTS (winget install OpenJS.NodeJS.LTS), restart the terminal, then retry."
    }

    Write-Log ("Invoking Playwright extractor (node {0}): powerplant={1}, search='{2}'" -f $nodeVer.Trim(), $PowerplantId, $SearchName) "INFO"
    Push-Location $toolsDir
    try {
        # Run headless; Playwright logs to stderr — bridge into our Write-Log.
        $nodeArgs = @(
            $jsScript,
            '--powerplant',  $PowerplantId.ToString(),
            '--search-name', $SearchName,
            '--out-file',    $mapFile,
            '--cookie-file', $cookieFile
        )
        if ($SkipComboProbe) { $nodeArgs += '--skip-combo-probe' }
        & node @nodeArgs 2>&1 | ForEach-Object {
            $line = [string]$_
            if ([string]::IsNullOrWhiteSpace($line)) { return }
            if ($line -match '^\[ncm-map\]') { Write-Log $line "INFO" }
            else                              { Write-Log $line "DEBUG" }
        }
        if ($LASTEXITCODE -ne 0) {
            throw "get-ncm-map.js exited with code $LASTEXITCODE — see lines above."
        }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path -LiteralPath $mapFile)) {
        throw "Extractor reported success but did not produce $mapFile."
    }

    $jsonItems = Get-Content -LiteralPath $mapFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $devices = New-Object System.Collections.Generic.List[object]
    $totalCombos = 0
    foreach ($item in @($jsonItems)) {
        if (-not $item.hostname -or -not $item.ncm_device_id) { continue }
        $combos = New-Object System.Collections.Generic.List[object]
        if ($item.PSObject.Properties.Name -contains 'combos' -and $item.combos) {
            foreach ($cb in @($item.combos)) {
                $bt = if ($cb.PSObject.Properties.Name -contains 'base_template' -and $null -ne $cb.base_template) { [string]$cb.base_template } else { '' }
                $bs = if ($cb.PSObject.Properties.Name -contains 'boot_system_bootflash' -and $null -ne $cb.boot_system_bootflash) { [string]$cb.boot_system_bootflash } else { '' }
                [void]$combos.Add([pscustomobject]@{ BaseTemplate = $bt; BootSystem = $bs })
                $totalCombos++
            }
        }
        [void]$devices.Add([pscustomobject]@{
            NcmDeviceId = [int]$item.ncm_device_id
            Hostname    = [string]$item.hostname
            Combos      = $combos.ToArray()
        })
    }
    Write-Log ("Browser extractor returned {0} NCM device(s); {1} combo(s) total." -f $devices.Count, $totalCombos) "SUCCESS"

    return @{ Devices = $devices.ToArray(); CookieFile = $cookieFile }
}

function Import-BrowserCookies {
    <#
        Reads the cookies + CSRF token dumped by get-ncm-map.js and builds a
        Microsoft.PowerShell.Commands.WebRequestSession with the same cookies,
        ready to use with Invoke-RestMethod -WebSession.

        Returns the same shape as Initialize-InternalSession's output:
        @{ Session = <WebRequestSession>; Headers = <hashtable> }
    #>
    param(
        [Parameter(Mandatory)] [string] $CookieFile
    )
    if (-not (Test-Path -LiteralPath $CookieFile)) {
        throw "Cookie file not found at $CookieFile."
    }

    $data = Get-Content -LiteralPath $CookieFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $data -or -not $data.cookies) {
        throw "Cookie file $CookieFile is empty or malformed."
    }

    $ws = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $imported = 0
    foreach ($c in $data.cookies) {
        try {
            # Playwright cookie domains can start with '.' — System.Net.Cookie wants that stripped.
            $domain = [string]$c.domain
            if ($domain.StartsWith('.')) { $domain = $domain.Substring(1) }
            $path   = if ($c.path) { [string]$c.path } else { '/' }
            $cookie = New-Object System.Net.Cookie([string]$c.name, [string]$c.value, $path, $domain)
            if ($c.secure)   { $cookie.Secure   = $true }
            if ($c.httpOnly) { $cookie.HttpOnly = $true }
            $ws.Cookies.Add($cookie)
            $imported++
        } catch {
            Write-Log ("Could not import cookie {0} for {1}: {2}" -f $c.name, $c.domain, $_.Exception.Message) "DEBUG"
        }
    }
    $csrfToken = [string]$data.csrfToken
    Write-Log ("Imported {0} browser cookie(s); X-CSRF-TOKEN length: {1}" -f $imported, $csrfToken.Length) "SUCCESS"

    return @{
        Session = $ws
        Headers = @{
            "Accept"           = "application/json, text/javascript, */*; q=0.01"
            "X-CSRF-TOKEN"     = $csrfToken
            "X-Requested-With" = "XMLHttpRequest"
            "Referer"          = "https://wpp-conf.vestasext.net/"
        }
    }
}

function Build-NcmSubconfigUrl {
    <#
        Builds the full DataTables query-string URL for
        /get-ncm-device-subconfig. The server requires every column to declare
        the full DataTables shape (data, name, searchable, orderable,
        search[value], search[regex]) plus top-level search/length/start
        plus the per-device data[*] context. Anything less returns 500.

        Returns a full URL (no body required — this is a GET).
    #>
    param(
        [Parameter(Mandatory)] [string] $InternalBase,        # e.g. https://wpp-conf.vestasext.net
        [Parameter(Mandatory)] [int]    $NcmDeviceId,
        [string] $Hostname     = '',
        [string] $BaseTemplate = '',
        [string] $BootSystem   = '',
        [int]    $Length       = 3,
        [int]    $Start        = 0
    )

    # The 10 columns the DataTables grid declares. Index 9 is a placeholder
    # ("actions" cell) that the server still expects in the request shape.
    $columns = @(
        'id', 'ncm_device_id', 'ncm_configuration_id', 'hostname',
        'filename', 'status', 'received_at',
        'last_configuration_change_at', 'last_configuration_change_by', '9'
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$InternalBase/get-ncm-device-subconfig?draw=1")
    for ($i = 0; $i -lt $columns.Count; $i++) {
        [void]$sb.AppendFormat('&columns%5B{0}%5D%5Bdata%5D={1}',                  $i, $columns[$i])
        [void]$sb.AppendFormat('&columns%5B{0}%5D%5Bname%5D=',                     $i)
        [void]$sb.AppendFormat('&columns%5B{0}%5D%5Bsearchable%5D=true',           $i)
        [void]$sb.AppendFormat('&columns%5B{0}%5D%5Borderable%5D=false',           $i)
        [void]$sb.AppendFormat('&columns%5B{0}%5D%5Bsearch%5D%5Bvalue%5D=',        $i)
        [void]$sb.AppendFormat('&columns%5B{0}%5D%5Bsearch%5D%5Bregex%5D=false',   $i)
    }
    # Paging: $Start (DataTables offset) lets the caller walk older pages.
    # The server returns rows newest-first by default, so start=0 is the most
    # recent page; start=$Length is the next-oldest page, and so on.
    [void]$sb.AppendFormat('&start={0}&length={1}', $Start, $Length)
    [void]$sb.Append('&search%5Bvalue%5D=&search%5Bregex%5D=false')
    # Always send ncm_device_id + hostname. base_template/boot_system_bootflash
    # are sent ONLY when we have real values — sending them empty triggers an
    # exact-equality filter on the server (= empty string) which silently
    # filters out almost all configs. Omitting the keys entirely should make
    # the server skip those filters and return all configs for the device.
    [void]$sb.AppendFormat('&data%5Bncm_device_id%5D={0}', $NcmDeviceId)
    [void]$sb.AppendFormat('&data%5Bhostname%5D={0}',     [Uri]::EscapeDataString($Hostname))
    # base_template and boot_system_bootflash MUST both be sent whenever
    # base_template is provided -- omitting boot_system_bootflash while sending
    # base_template causes the server to return 500. Sending both as empty
    # strings is fine (matches the page's default Configurations filter).
    [void]$sb.AppendFormat('&data%5Bbase_template%5D={0}',         [Uri]::EscapeDataString($BaseTemplate))
    [void]$sb.AppendFormat('&data%5Bboot_system_bootflash%5D={0}', [Uri]::EscapeDataString($BootSystem))
    return $sb.ToString()
}

function New-ConfigBackupWideRow {
    <#
        Builds ONE wide-format CSV row for the Configuration Backup chain.
        Produces a 17-column [pscustomobject] in a stable order:
            NCM_DeviceID, NCM_Hostname,
            WPP_DeviceID, WPP_Alias, WPP_IpAddr,
            Status, BaseTemplate, BootSystem,
            ReceivedAt_1, LastConfigChangeAt_1, LastConfigChangeBy_1,
            ReceivedAt_2, LastConfigChangeAt_2, LastConfigChangeBy_2,
            ReceivedAt_3, LastConfigChangeAt_3, LastConfigChangeBy_3.

        $Slots is an array (0..3) of records exposing .received_at,
        .last_configuration_change_at, .last_configuration_change_by. Missing
        slots are emitted as empty strings (NOT $null) so Export-Csv produces
        empty cells consistently.
    #>
    param(
        [int]    $NcmDeviceId   = 0,
        [string] $NcmHostname   = '',
        $WppDevice              = $null,
        [string] $Status        = '',
        [string] $BaseTemplate  = '',
        [string] $BootSystem    = '',
        [array]  $Slots         = @()
    )

    # WPP_* fields — empty strings when no matching WPP device.
    $wppId    = ''
    $wppAlias = ''
    $wppIp    = ''
    if ($WppDevice) {
        if ($WppDevice.PSObject.Properties.Name -contains 'id'         -and $null -ne $WppDevice.id)         { $wppId    = [string]$WppDevice.id }
        if ($WppDevice.PSObject.Properties.Name -contains 'alias'      -and $null -ne $WppDevice.alias)      { $wppAlias = [string]$WppDevice.alias }
        if ($WppDevice.PSObject.Properties.Name -contains 'ip_address' -and $null -ne $WppDevice.ip_address) { $wppIp    = [string]$WppDevice.ip_address }
    }

    # NCM_DeviceID: emit '' when caller passes 0 (the sentinel for "unmatched WPP / no NCM").
    $ncmIdStr = if ($NcmDeviceId -gt 0) { [string]$NcmDeviceId } else { '' }

    # Extract slot fields with safe fallbacks. Empty string for missing/null.
    $rxAt1 = ''; $rxBy1 = ''; $rxRc1 = ''
    $rxAt2 = ''; $rxBy2 = ''; $rxRc2 = ''
    $rxAt3 = ''; $rxBy3 = ''; $rxRc3 = ''

    if ($null -ne $Slots -and $Slots.Count -ge 1 -and $null -ne $Slots[0]) {
        $r = $Slots[0]
        if ($r.PSObject.Properties.Name -contains 'received_at'                  -and $null -ne $r.received_at)                  { $rxRc1 = [string]$r.received_at }
        if ($r.PSObject.Properties.Name -contains 'last_configuration_change_at' -and $null -ne $r.last_configuration_change_at) { $rxAt1 = [string]$r.last_configuration_change_at }
        if ($r.PSObject.Properties.Name -contains 'last_configuration_change_by' -and $null -ne $r.last_configuration_change_by) { $rxBy1 = [string]$r.last_configuration_change_by }
    }
    if ($null -ne $Slots -and $Slots.Count -ge 2 -and $null -ne $Slots[1]) {
        $r = $Slots[1]
        if ($r.PSObject.Properties.Name -contains 'received_at'                  -and $null -ne $r.received_at)                  { $rxRc2 = [string]$r.received_at }
        if ($r.PSObject.Properties.Name -contains 'last_configuration_change_at' -and $null -ne $r.last_configuration_change_at) { $rxAt2 = [string]$r.last_configuration_change_at }
        if ($r.PSObject.Properties.Name -contains 'last_configuration_change_by' -and $null -ne $r.last_configuration_change_by) { $rxBy2 = [string]$r.last_configuration_change_by }
    }
    if ($null -ne $Slots -and $Slots.Count -ge 3 -and $null -ne $Slots[2]) {
        $r = $Slots[2]
        if ($r.PSObject.Properties.Name -contains 'received_at'                  -and $null -ne $r.received_at)                  { $rxRc3 = [string]$r.received_at }
        if ($r.PSObject.Properties.Name -contains 'last_configuration_change_at' -and $null -ne $r.last_configuration_change_at) { $rxAt3 = [string]$r.last_configuration_change_at }
        if ($r.PSObject.Properties.Name -contains 'last_configuration_change_by' -and $null -ne $r.last_configuration_change_by) { $rxBy3 = [string]$r.last_configuration_change_by }
    }

    return [pscustomobject][ordered]@{
        NCM_DeviceID         = $ncmIdStr
        NCM_Hostname         = $NcmHostname
        WPP_DeviceID         = $wppId
        WPP_Alias            = $wppAlias
        WPP_IpAddr           = $wppIp
        Status               = $Status
        BaseTemplate         = $BaseTemplate
        BootSystem           = $BootSystem
        ReceivedAt_1         = $rxRc1
        LastConfigChangeAt_1 = $rxAt1
        LastConfigChangeBy_1 = $rxBy1
        ReceivedAt_2         = $rxRc2
        LastConfigChangeAt_2 = $rxAt2
        LastConfigChangeBy_2 = $rxBy2
        ReceivedAt_3         = $rxRc3
        LastConfigChangeAt_3 = $rxAt3
        LastConfigChangeBy_3 = $rxBy3
    }
}

function New-BackupRateRow {
    <#
        Builds ONE wide CSV row for the Monthly Backup-Rate chain. Emits empty
        strings (NOT $null) for blank cells so Export-Csv produces consistent
        columns. Deliberately carries ONLY aggregate counts — no per-backup
        identity fields (e.g. last_configuration_change_by usernames), per
        CLAUDE.md rule 6 (No PII). RatePct is formatted with InvariantCulture
        so the ';'-delimited CSV stays machine-parseable on any host locale.
    #>
    param(
        [int]    $NcmDeviceId    = 0,
        [string] $NcmHostname    = '',
        $WppDevice               = $null,
        [string] $Month          = '',
        [int]    $BackupCount    = 0,
        [int]    $DistinctDays   = 0,
        [int]    $DaysInMonth    = 0,
        [double] $RatePct        = 0,
        [string] $FirstBackupAt  = '',
        [string] $LastBackupAt   = '',
        [string] $Note           = ''
    )

    $wppId = ''; $wppAlias = ''; $wppIp = ''
    if ($WppDevice) {
        if ($WppDevice.PSObject.Properties.Name -contains 'id'         -and $null -ne $WppDevice.id)         { $wppId    = [string]$WppDevice.id }
        if ($WppDevice.PSObject.Properties.Name -contains 'alias'      -and $null -ne $WppDevice.alias)      { $wppAlias = [string]$WppDevice.alias }
        if ($WppDevice.PSObject.Properties.Name -contains 'ip_address' -and $null -ne $WppDevice.ip_address) { $wppIp    = [string]$WppDevice.ip_address }
    }
    $ncmIdStr = if ($NcmDeviceId -gt 0) { [string]$NcmDeviceId } else { '' }

    return [pscustomobject][ordered]@{
        NCM_DeviceID        = $ncmIdStr
        NCM_Hostname        = $NcmHostname
        WPP_DeviceID        = $wppId
        WPP_Alias           = $wppAlias
        WPP_IpAddr          = $wppIp
        Month               = $Month
        BackupCount         = $BackupCount
        DistinctDaysCovered = $DistinctDays
        DaysInMonth         = $DaysInMonth
        RatePct             = ('{0:0.0}' -f $RatePct)
        FirstBackupAt       = $FirstBackupAt
        LastBackupAt        = $LastBackupAt
        Note                = $Note
    }
}

function Resolve-NcmDeviceName {
    <#
        Derives the NCM-canonical device_name for a WPP device, when one
        can be inferred. NCM stores devices under names like SP-60423-VES1-WAN1
        (powerplant SP number + sublocation + role) — not under the WPP
        country-prefixed name (DE-SP-60423-...) nor the customer alias
        (DE-HeDreiht-..., CIAS-HUB-9998-...).

        Rules:
          - Plant gear (name like 'DE-SP-...')      -> strip the 2-letter country prefix.
          - Devices whose alias ends in a sublocation tail (VES#, WTG#, NRP#,
            WNC#, PMC#, WAN#) and we know the powerplant SP number -> prepend SP.
          - Anything else (NAT/CUSTOMER placeholders, per-site CIAS suitcases
            that live under their OWN SP number, etc.) -> return $null so the
            caller can skip cleanly instead of producing a 404.
    #>
    param(
        [Parameter(Mandatory)] $Dev,
        [string] $SpNumber
    )
    try {
        $devName  = [string]$Dev.name
        $devAlias = [string]$Dev.alias

        # Exclude per-site Comm-In-A-Suitcase devices: each CIAS-####-SUITCASE-*
        # belongs to its OWN sp_number (the suitcase site), not this powerplant's.
        # Mapping them to $SpNumber would produce false positives (e.g. every
        # CIAS-####-SUITCASE-WAN1 collapses onto a single SP-60423-WAN1 collision).
        if ($devName -match 'SUITCASE' -or $devAlias -match 'SUITCASE') {
            return $null
        }

        if ($devName -like 'DE-SP-*') {
            return ($devName -replace '^[A-Z]{2}-','')
        }
        if (-not [string]::IsNullOrWhiteSpace($SpNumber) -and
            $devAlias -match '-(VES\d.*|WTG\d+.*|NRP\d+.*|WNC\d+.*|PMC\d+.*|WAN\d+)$') {
            return ('{0}-{1}' -f $SpNumber, $Matches[1])
        }
        return $null
    } catch {
        return $null
    }
}

function Invoke-ToolsSetup {
    <#
        Ensures the Node.js tooling under .\tools\ is ready to run.
        Runs automatically on first use or after a fresh git clone.
        Exits the script with a clear, actionable message on unrecoverable failure.
    #>
    $toolsDir    = Join-Path $PSScriptRoot 'tools'
    $nodeModules = Join-Path $toolsDir 'node_modules'
    $playwrightPkg = Join-Path $nodeModules 'playwright'

    Write-LogSection "TOOLS SETUP"

    # 1 — Node.js must be on PATH
    $nodeVer = $null
    try { $nodeVer = (& node --version 2>$null) } catch { }
    if ([string]::IsNullOrWhiteSpace($nodeVer)) {
        Write-Log "Node.js not found on PATH." "ERROR"
        Write-Log "Install Node.js LTS and restart the terminal:" "INFO"
        Write-Log "  winget install OpenJS.NodeJS.LTS" "INFO"
        exit 1
    }
    Write-Log ("Node.js {0} found." -f $nodeVer.Trim()) "SUCCESS"

    # 2 — npm packages (playwright, minimist, dotenv)
    if (-not (Test-Path -LiteralPath $playwrightPkg)) {
        Write-Log "npm packages missing — running 'npm install' in tools\ ..." "INFO"
        Push-Location $toolsDir
        try {
            & npm install 2>&1 | ForEach-Object {
                $line = [string]$_
                if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Log $line "DEBUG" }
            }
        } finally {
            Pop-Location
        }
        if (-not (Test-Path -LiteralPath $playwrightPkg)) {
            Write-Log "'npm install' completed but playwright package still missing. Check errors above." "ERROR"
            exit 1
        }
        Write-Log "npm packages installed successfully." "SUCCESS"
    } else {
        Write-Log "npm packages already installed." "SUCCESS"
    }

    # 3 — Microsoft Edge must be present (used by get-ncm-map.js via channel:'msedge')
    $edgePath = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    if (-not (Test-Path -LiteralPath $edgePath)) {
        Write-Log "Microsoft Edge not found at: $edgePath" "WARN"
        Write-Log "The browser extractor requires Edge. Install it from https://microsoft.com/edge" "WARN"
    } else {
        Write-Log "Microsoft Edge found." "SUCCESS"
    }
}

#endregion

#region ---------- Setup ------------------------------------------------------

Invoke-ToolsSetup

# ---- Load config and resolve auth + chosen endpoint --------------------------
try {
    $config = Import-Config -Path $ConfigFile
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# AuthUrl: explicit param wins, otherwise fall back to conf.json
if ([string]::IsNullOrWhiteSpace($AuthUrl)) {
    $AuthUrl = $config.auth.url
}

# Resolve which endpoint to query. Precedence:
#   1. -EndpointUrl (explicit URL)
#   2. -EndpointIndex (1-based into conf.endpoints)
#   3. Interactive menu
$chosenEndpoint = $null
if (-not [string]::IsNullOrWhiteSpace($EndpointUrl)) {
    $chosenEndpoint = [pscustomobject]@{ name = "Custom (-EndpointUrl)"; slug = "custom"; url = $EndpointUrl }
}
elseif ($EndpointIndex -ge 1 -and $EndpointIndex -le @($config.endpoints).Count) {
    $chosenEndpoint = $config.endpoints[$EndpointIndex - 1]
}
else {
    $chosenEndpoint = Show-EndpointMenu -Config $config
    if (-not $chosenEndpoint) {
        Write-Host "No endpoint selected. Exiting." -ForegroundColor Yellow
        exit 0
    }
}

$queryUrl = $chosenEndpoint.url

# ---- Build per-endpoint, per-day output folder -------------------------------
# Layout: <OutputRoot>\<endpoint-slug>\<YYYY-MM-DD>\
$endpointSlug = $null
if ($chosenEndpoint.PSObject.Properties.Name -contains "slug" -and $chosenEndpoint.slug) {
    $endpointSlug = ConvertTo-Slug -Text $chosenEndpoint.slug
}
if ([string]::IsNullOrWhiteSpace($endpointSlug)) {
    $endpointSlug = ConvertTo-Slug -Text $chosenEndpoint.name
}

$dayStamp     = Get-Date -Format "yyyy-MM-dd"
$OutputRoot   = $OutputFolder
$OutputFolder = Join-Path (Join-Path $OutputRoot $endpointSlug) $dayStamp

if (-not (Test-Path -LiteralPath $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

Write-LogSection "INFORMATION"
Write-Log ("Version  : {0}" -f $config.version) "INFO"
Write-Log "Script   : $($MyInvocation.MyCommand.Path)" "INFO"
Write-Log "Config   : $ConfigFile" "INFO"
Write-Log "EnvFile  : $EnvFile"    "INFO"
Write-Log ("Endpoint : {0}" -f $chosenEndpoint.name) "INFO"
Write-Log ("URL      : {0}" -f $queryUrl)            "INFO"
Write-Log ("Output   : {0}" -f $OutputFolder)        "INFO"

# Force TLS 1.2 for older Windows / PS 5.1 environments
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Log "Could not set TLS 1.2: $($_.Exception.Message)" "WARN"
}

#endregion

#region ---------- Load credentials ------------------------------------------

Write-LogSection "AUTHENTICATION"

try {
    $envVars = Import-DotEnv -Path $EnvFile
} catch {
    Write-Log $_.Exception.Message "ERROR"
    Write-Log "Create a .env file (see .env.example). Aborting." "ERROR"
    exit 1
}

$username = $envVars["WPP_USERNAME"]
$password = $envVars["WPP_PASSWORD"]

if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
    Write-Log "WPP_USERNAME or WPP_PASSWORD missing/empty in $EnvFile" "ERROR"
    exit 1
}

Write-Log "Loaded credentials for user '$username' from .env" "INFO"
Write-Log ("Password length: {0} chars (value not logged)" -f $password.Length) "DEBUG"

#endregion

#region ---------- Step 1: Authenticate --------------------------------------

Write-Log "Requesting auth token from $AuthUrl ..." "INFO"

# Build body as { "username": "...", "password": "..." } — exactly matching the API spec.
# ConvertTo-Json handles any special characters in the password (!, @, $, ", \, etc.) safely.
$authBody = [ordered]@{
    username = $username
    password = $password
} | ConvertTo-Json -Compress

# Sanity check: log that body was built and its size, but never the body itself.
Write-Log ("Auth body built (JSON, {0} bytes)" -f $authBody.Length) "DEBUG"

$authHeaders = @{
    "Accept"       = "application/json"
    "Content-Type" = "application/json"
}

$token = $null
try {
    $authSplat = Get-RequestSplat -Base @{
        Method      = "POST"
        Uri         = $AuthUrl
        Headers     = $authHeaders
        Body        = $authBody
        ErrorAction = "Stop"
    }

    $authResponse = Invoke-RestMethod @authSplat

    # Token field name varies between APIs — check the most common ones.
    $tokenCandidates = @("token","access_token","accessToken","jwt","id_token","bearer")
    foreach ($field in $tokenCandidates) {
        if ($authResponse.PSObject.Properties.Name -contains $field -and $authResponse.$field) {
            $token = $authResponse.$field
            Write-Log "Token retrieved (field: $field, length: $($token.Length))" "SUCCESS"
            break
        }
    }

    # Some APIs nest the token under .data.token
    if (-not $token -and $authResponse.PSObject.Properties.Name -contains "data") {
        foreach ($field in $tokenCandidates) {
            if ($authResponse.data.PSObject.Properties.Name -contains $field -and $authResponse.data.$field) {
                $token = $authResponse.data.$field
                Write-Log "Token retrieved (field: data.$field, length: $($token.Length))" "SUCCESS"
                break
            }
        }
    }

    if (-not $token) {
        Write-Log "Auth response did not contain a recognizable token field." "ERROR"
        Write-Log "Response keys: $(@($authResponse.PSObject.Properties.Name) -join ', ')" "ERROR"
        Write-Log "Adjust the script's `$tokenCandidates` list to match the actual field name." "ERROR"
        exit 2
    }
}
catch {
    Write-Log "Authentication failed: $($_.Exception.Message)" "ERROR"
    if ($_.Exception.Response) {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $errBody = $reader.ReadToEnd()
            Write-Log "Server response body: $errBody" "ERROR"
        } catch { }
    }
    exit 2
}

#endregion

#region ---------- Step 1b: Discover user roles -------------------------------

Write-LogSection "PERMISSIONS"

# Decode JWT + scan auth response for roles. Used to short-circuit calls that
# would 401 due to missing role, instead of spamming the API.
$script:UserRoles = @()
try {
    $rolesFromJwt  = @()
    $rolesFromAuth = @()
    $jwtPayload    = $null
    try {
        $jwtPayload   = Get-JwtPayload -Jwt $token
        $rolesFromJwt = Get-RolesFromObject -Obj $jwtPayload
    } catch {
        Write-Log "JWT decode failed: $($_.Exception.Message)" "DEBUG"
    }
    try {
        $rolesFromAuth = Get-RolesFromObject -Obj $authResponse
    } catch {
        Write-Log "Auth-response role scan failed: $($_.Exception.Message)" "DEBUG"
    }

    $script:UserRoles = (@($rolesFromJwt) + @($rolesFromAuth)) | Where-Object { $_ } | Sort-Object -Unique

    if ($script:UserRoles.Count -gt 0) {
        Write-Log ("User roles detected ({0}):" -f $script:UserRoles.Count) "INFO"
        foreach ($roleName in $script:UserRoles) {
            Write-Log $roleName "INFO" 2
        }
    } else {
        # Diagnostic: dump top-level keys so we can extend Get-RolesFromObject to the right claim.
        try {
            if ($jwtPayload) {
                $jwtKeys = @($jwtPayload.PSObject.Properties.Name) -join ', '
                Write-Log ("JWT payload top-level keys: {0}" -f $jwtKeys) "WARN"
            } else {
                Write-Log "JWT payload could not be decoded (token may not be a JWT)." "WARN"
            }
            if ($authResponse) {
                $authKeys = @($authResponse.PSObject.Properties.Name) -join ', '
                Write-Log ("Auth response top-level keys: {0}" -f $authKeys) "WARN"
            }
        } catch {
            Write-Log "Failed to dump JWT/auth keys: $($_.Exception.Message)" "DEBUG"
        }
        Write-Log "Could not determine user roles from JWT or auth response - permission checks will be permissive (calls still attempted)." "WARN"
    }
} catch {
    Write-Log "Role discovery failed: $($_.Exception.Message)" "WARN"
}

#endregion

#region ---------- Step 2: Query selected endpoint ---------------------------

# $queryUrl was resolved from -EndpointUrl, -EndpointIndex, or the menu in Setup.
# No pre-flight permission check on the main endpoint: the role-name in the JWT
# claim ('userRoles') may not match the role label in api.doc.json verbatim, so
# a strict pre-check would wrongly block calls the user IS allowed to make.
# Just attempt the call; the catch block handles any 401 cleanly.

Write-LogSection "QUERY"
Write-Log "Querying endpoint: $queryUrl" "INFO"

$ppHeaders = @{
    "Accept"        = "application/json"
    "Authorization" = "Bearer $token"
}

# Hostname-based auth routing:
#   - wpp-conf.vestasext.net (Laravel web app) -> session-based, lazy login.
#   - everything else -> bearer token (existing behaviour).
$internalHost = $null
if ($config.PSObject.Properties.Name -contains "internalAuth" -and $config.internalAuth -and $config.internalAuth.host) {
    $internalHost = [string]$config.internalAuth.host
}
$useInternalSession = $false
try {
    $uri = [System.Uri]$queryUrl
    if ($internalHost -and ($uri.Host -ieq $internalHost)) {
        $useInternalSession = $true
    }
} catch { }

try {
    if ($useInternalSession) {
        $startUrl = [string]$config.internalAuth.url
        Initialize-InternalSession -StartUrl $startUrl -Username $username -Password $password
        $ppResponse = Invoke-RestMethod -Uri $queryUrl -WebSession $script:InternalSessionData.Session `
                        -Headers $script:InternalSessionData.Headers -ErrorAction Stop -TimeoutSec 120
    }
    else {
        $ppSplat = Get-RequestSplat -Base @{
            Method      = "GET"
            Uri         = $queryUrl
            Headers     = $ppHeaders
            ErrorAction = "Stop"
        }
        $ppResponse = Invoke-RestMethod @ppSplat
    }
    Write-Log "Powerplants query succeeded." "SUCCESS"
}
catch {
    Write-Log "Powerplants request failed: $($_.Exception.Message)" "ERROR"
    # PS 7 stashes the response body on $_.ErrorDetails.Message; PS 5.1 needs
    # the stream read. Mirror the chain catches so Kong 404s etc. are visible.
    $sc = $null; $errBody = $null
    try {
        if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode }
    } catch { }
    try {
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $errBody = [string]$_.ErrorDetails.Message
        } elseif ($_.Exception.Response -and $_.Exception.Response.PSObject.Methods.Name -contains "GetResponseStream") {
            $stream  = $_.Exception.Response.GetResponseStream()
            $reader  = New-Object System.IO.StreamReader($stream)
            $errBody = $reader.ReadToEnd()
        }
    } catch { }
    if ($errBody) { Write-Log "Server response body: $errBody" "ERROR" }

    # Internal-API 401/419 → SAML session has expired or was rejected. The
    # script re-runs Connect-SamlSession on the next invocation; nothing for
    # the operator to do manually unless creds in .env are stale.
    if ($useInternalSession -and ($sc -eq 401 -or $sc -eq 419)) {
        Write-Log "Internal session expired or rejected (HTTP $sc). Re-running the script will trigger a fresh SAML login." "ERROR"
        Write-Log "If this persists, verify WPP_USERNAME / WPP_PASSWORD in conf\.env are current." "ERROR"
    }
    exit 3
}

#endregion

#region ---------- Persist + summarize ---------------------------------------

$outFile = Join-Path $OutputFolder ("Powerplants_{0}.json" -f $script:RunStamp)
try {
    $ppResponse | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $outFile -Encoding UTF8
    Write-Log "Response saved to: $outFile" "SUCCESS"
}
catch {
    Write-Log "Failed to write JSON output: $($_.Exception.Message)" "ERROR"
    exit 4
}

# Quick summary so the operator can see results without opening the JSON
try {
    $items = @()
    if ($ppResponse -is [System.Array])                        { $items = $ppResponse }
    elseif ($ppResponse.PSObject.Properties.Name -contains "data" -and $ppResponse.data) {
        $items = @($ppResponse.data)
    } else { $items = @($ppResponse) }

    Write-Log ("Result count: {0}" -f $items.Count) "INFO"

    # Per-item summary is verbose noise — only show with -Verbose / -Debug.
    $i = 0
    foreach ($item in $items) {
        $i++
        $name = $item.name
        $id   = $item.id
        Write-Log ("[{0}] id={1} name={2}" -f $i, $id, $name) "DEBUG"
        if ($i -ge 10) { Write-Log "... (truncated, see JSON file)" "DEBUG"; break }
    }
}
catch {
    Write-Log "Summary rendering skipped: $($_.Exception.Message)" "DEBUG"
}

#endregion

#region ---------- Optional chain: /asset/details per device ------------------

# Triggered when the chosen conf.json entry has "chain": "assetDetails".
# The primary URL must return a device list; we then call /asset/details once
# per device.id, aggregate, and emit AssetDetails_<stamp>.json + .csv.
# When this runs, the default device CSV export below is skipped.

$script:ChainHandled = $false
$chainKind = $null
if ($chosenEndpoint.PSObject.Properties.Name -contains "chain") {
    $chainKind = [string]$chosenEndpoint.chain
}

if ($chainKind -eq "assetDetails") {
    Write-LogSection "CHAIN: ASSET DETAILS"
    Write-Log "Chain enabled — fanning out per device.alias." "INFO"

    # Normalize the primary response into an array of device records.
    $deviceItems = @()
    if ($ppResponse.PSObject.Properties.Name -contains "data" -and $ppResponse.data) {
        $deviceItems = @($ppResponse.data)
    } elseif ($ppResponse -is [System.Array]) {
        $deviceItems = $ppResponse
    } else {
        $deviceItems = @($ppResponse)
    }

    $apiBase = ($AuthUrl -replace '/public/auth/?$','').TrimEnd('/')
    Write-Log ("API base: {0}  Devices to enrich: {1}" -f $apiBase, $deviceItems.Count) "INFO"

    $chainResults = New-Object System.Collections.Generic.List[object]
    $chainOk = 0; $chainFail = 0; $i = 0

    # Pre-flight check ONCE for /asset/details (vs N x 401 per device).
    $chainCheck = Test-EndpointAllowed -Url "$apiBase/asset/details" -UserRoles $script:UserRoles
    if (-not $chainCheck.Allowed) {
        Write-Log ("Chain SKIPPED: required role '{0}' not granted to '{1}'. Avoids {2} x 401 per-device call." -f $chainCheck.Required, $username, $deviceItems.Count) "ERROR"
        Write-Log "AssetDetails CSV will still be written from the device list, with empty asset columns." "WARN"
        try {
            foreach ($dev in $deviceItems) {
                $chainResults.Add([pscustomobject]@{ device = $dev; asset_details = $null })
            }
        } catch {
            Write-Log "Failed to build empty chain results: $($_.Exception.Message)" "ERROR"
        }
        # Skip the per-device HTTP loop entirely; existing JSON/CSV writers below
        # consume $chainResults and produce a consistently shaped output.
        $skipChainLoop = $true
    } else {
        $skipChainLoop = $false
        if ($chainCheck.Required) {
            Write-Log ("Chain permission check OK (role: {0})" -f $chainCheck.Required) "DEBUG"
        }
    }

    # Per api.doc.json /asset/details: searchable fields are device.alias and device.name
    # (device.id is NOT supported and produces a 401). Use alias as the documented join key.
    if (-not $skipChainLoop) {
    $abortChainOn401 = $false
    $progressActivity = "Fetching asset details"
    try {
    foreach ($dev in $deviceItems) {
        $i++

        $devId    = $dev.id
        $devAlias = $dev.alias

        # Console-only progress gauge. Not written to log.
        $pct = if ($deviceItems.Count -gt 0) {
            [int](($i / $deviceItems.Count) * 100)
        } else { 0 }
        Write-Progress -Activity $progressActivity `
            -Status ("{0}/{1}  {2}" -f $i, $deviceItems.Count, $devAlias) `
            -PercentComplete $pct

        # Early-abort: once we've seen one 401, all subsequent calls will 401 too.
        # Pad remaining devices with empty asset_details so JSON/CSV stay shaped.
        if ($abortChainOn401) {
            $chainResults.Add([pscustomobject]@{ device = $dev; asset_details = $null })
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string]$devAlias)) {
            Write-Log ("[{0}/{1}] device id={2} has no 'alias' — skipping (search key unavailable)" -f $i, $deviceItems.Count, $devId) "WARN"
            $chainFail++
            $chainResults.Add([pscustomobject]@{ device = $dev; asset_details = $null })
            continue
        }

        # URL-encode the alias in case it contains spaces or other reserved chars.
        $aliasEnc   = [System.Uri]::EscapeDataString([string]$devAlias)
        $detailsUrl = "{0}/asset/details?search=device.alias:{1}" -f $apiBase, $aliasEnc
        try {
            $adSplat = Get-RequestSplat -Base @{
                Method      = "GET"
                Uri         = $detailsUrl
                Headers     = $ppHeaders
                ErrorAction = "Stop"
            }
            $adResponse = Invoke-RestMethod @adSplat

            $assetDetails = @()
            if ($adResponse.PSObject.Properties.Name -contains "data" -and $adResponse.data) {
                $assetDetails = @($adResponse.data)
            } elseif ($adResponse -is [System.Array]) {
                $assetDetails = $adResponse
            } else {
                $assetDetails = @($adResponse)
            }
            $chainOk++
            Write-Log ("[{0}/{1}] {2} -> {3} asset record(s)" -f $i, $deviceItems.Count, $devAlias, $assetDetails.Count) "INFO"
            $chainResults.Add([pscustomobject]@{ device = $dev; asset_details = $assetDetails })
        }
        catch {
            $chainFail++

            # Determine HTTP status code (PS 7 vs 5.1).
            $statusCode = $null
            try {
                if ($_.Exception.PSObject.Properties.Name -contains "Response" -and $_.Exception.Response) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }
            } catch { }

            # Capture response body. PS 7 surfaces it on $_.ErrorDetails.Message;
            # PS 5.1 requires reading the response stream.
            $body = $null
            try {
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                    $body = [string]$_.ErrorDetails.Message
                } elseif ($_.Exception.Response -and $_.Exception.Response.PSObject.Methods.Name -contains "GetResponseStream") {
                    $stream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body   = $reader.ReadToEnd()
                }
            } catch { }

            Write-Log ("[{0}/{1}] {2} asset/details failed: {3}" -f $i, $deviceItems.Count, $devAlias, $_.Exception.Message) "WARN"
            if ($body) { Write-Log ("    response body: {0}" -f $body) "WARN" }

            $chainResults.Add([pscustomobject]@{ device = $dev; asset_details = $null })

            if ($statusCode -eq 401 -or $statusCode -eq 403) {
                $remaining = $deviceItems.Count - $i
                Write-Log ("First {0} hit. Aborting remaining {1} call(s) — same auth context will produce identical failures. Likely missing role 'Get Asset Details'." -f $statusCode, $remaining) "ERROR"
                $abortChainOn401 = $true
            }
        }
    }
    }
    finally {
        # Ensure the gauge is dismissed even if the loop body throws (Ctrl-C, etc.).
        Write-Progress -Activity $progressActivity -Completed
    }
    }

    Write-Log ("Chain complete: ok={0} failed={1} total={2}" -f $chainOk, $chainFail, $deviceItems.Count) "INFO"

    Write-LogSection "OUTPUT"

    # Save aggregated JSON
    $chainJson = Join-Path $OutputFolder ("AssetDetails_{0}.json" -f $script:RunStamp)
    try {
        $chainResults | ConvertTo-Json -Depth 30 | Out-File -LiteralPath $chainJson -Encoding UTF8
        Write-Log "Chain JSON saved: $chainJson" "SUCCESS"
    } catch {
        Write-Log "Failed to write chain JSON: $($_.Exception.Message)" "ERROR"
    }

    # Build CSV: one row per asset record (or one empty-asset row per device if none returned).
    $csvRows = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $chainResults) {
        $dev = $entry.device
        $ads = @($entry.asset_details)

        if ($ads.Count -eq 0) {
            $csvRows.Add([pscustomobject][ordered]@{
                DeviceID     = $dev.id
                DeviceName   = $dev.name
                DeviceAlias  = $dev.alias
                PowerplantID = $dev.powerplant_id
                Mac_Address  = $dev.mac_address
                Ip_address   = $dev.ip_address
                AssetID      = $null
                AssetName    = $null
                AssetType    = $null
                Manufacturer = $null
                Model        = $null
                SerialNumber = $null
                Status       = $null
                UpdatedAt    = $null
            })
            continue
        }

        foreach ($a in $ads) {
            $csvRows.Add([pscustomobject][ordered]@{
                DeviceID     = $dev.id
                DeviceName   = $dev.name
                DeviceAlias  = $dev.alias
                PowerplantID = $dev.powerplant_id
                Mac_Address  = $dev.mac_address
                Ip_address   = $dev.ip_address
                AssetID      = $a.id
                AssetName    = $a.name
                AssetType    = $a.type
                Manufacturer = $a.manufacturer
                Model        = $a.model
                SerialNumber = $a.serial_number
                Status       = $a.status
                UpdatedAt    = $a.updated_at
            })
        }
    }

    if ($csvRows.Count -gt 0) {
        $csvFile = Join-Path $OutputFolder ("AssetDetails_{0}.csv" -f $script:RunStamp)
        $csvRows | Export-Csv -LiteralPath $csvFile -NoTypeInformation -Encoding UTF8
        Write-Log ("CSV written: {0} ({1} row(s))" -f $csvFile, $csvRows.Count) "SUCCESS"
    } else {
        Write-Log "No rows to write — CSV not created." "WARN"
    }

    $script:ChainHandled = $true
}
elseif ($chainKind -eq "assetDetailsAndNcm") {
    # Per-device /asset/details (alias-based) AND per-device /ncm/device/by-device-name.
    # Why per-device NCM and not bulk or accessor?
    #   * /api/v1/ncm/devices       -> Kong "no Route matched" (404) on prod.
    #   * /api/v1/devices?...&accessor=ncm -> 500 Internal Server Error on prod.
    # Per-device /ncm/device/by-device-name is the only NCM path that prod's
    # gateway accepts. 404 from that route is the legitimate "no NCM record"
    # response (NCM is a sparse subset of devices) — logged silently and
    # summarised at the end so the log stays clean.
    # Output per row: { device, asset_details, ncm_details }.

    Write-LogSection "CHAIN: ASSET + NCM DETAILS"
    Write-Log "Chain enabled — per-device /asset/details + per-device /ncm/device/by-device-name." "INFO"

    # Normalize the primary response into an array of device records.
    $deviceItems = @()
    if ($ppResponse.PSObject.Properties.Name -contains "data" -and $ppResponse.data) {
        $deviceItems = @($ppResponse.data)
    } elseif ($ppResponse -is [System.Array]) {
        $deviceItems = $ppResponse
    } else {
        $deviceItems = @($ppResponse)
    }

    $apiBase = ($AuthUrl -replace '/public/auth/?$','').TrimEnd('/')
    Write-Log ("API base: {0}  Devices to enrich: {1}" -f $apiBase, $deviceItems.Count) "INFO"

    $chainResults = New-Object System.Collections.Generic.List[object]
    $chainOk = 0; $chainFail = 0; $i = 0

    # ----- Asset + NCM pre-flight -----
    $assetCheck = Test-EndpointAllowed -Url "$apiBase/asset/details"             -UserRoles $script:UserRoles
    $ncmCheck   = Test-EndpointAllowed -Url "$apiBase/ncm/device/by-device-name" -UserRoles $script:UserRoles
    $abortAsset = -not $assetCheck.Allowed
    $abortNcm   = -not $ncmCheck.Allowed
    if ($abortAsset) {
        Write-Log ("Skipping /asset/details — user lacks role '{0}'." -f $assetCheck.Required) "ERROR"
    }
    if ($abortNcm) {
        Write-Log ("Skipping /ncm/device/by-device-name — user lacks role '{0}'." -f $ncmCheck.Required) "ERROR"
    }

    # NCM lookup counters (final summary line, not per-device).
    $ncmHits      = 0   # 200 OK with an NCM record
    $ncmMisses    = 0   # 404 — device is not enrolled in NCM (normal)
    $ncmErrors    = 0   # any other failure (logged WARN)
    $ncmSkipped   = 0   # no NCM-canonical name could be derived from the WPP record

    # ----- Resolve the powerplant SP number once (cached for the loop) -----
    # NCM names embed the powerplant's sp_number (e.g. SP-60423-VES1-WAN1).
    # The device record's embedded powerplant sub-object only carries id+shortcode,
    # so a one-shot /powerplants lookup is required. Falls back to $null on any failure;
    # downstream Resolve-NcmDeviceName degrades gracefully (skips non-DE-SP devices).
    $ppSpNumber = $null
    try {
        $ppId = $null
        foreach ($d in $deviceItems) {
            if ($d.powerplant -and $d.powerplant.id) { $ppId = $d.powerplant.id; break }
            if ($d.powerplant_id)                    { $ppId = $d.powerplant_id; break }
        }
        if ($ppId) {
            $ppLookupUrl = "{0}/powerplants?search=id:{1}" -f $apiBase, $ppId
            $ppSplat = Get-RequestSplat -Base @{
                Method = "GET"; Uri = $ppLookupUrl; Headers = $ppHeaders; ErrorAction = "Stop"
            }
            $ppResp = Invoke-RestMethod @ppSplat
            $ppItems = @()
            if ($ppResp.PSObject.Properties.Name -contains "data" -and $ppResp.data) {
                $ppItems = @($ppResp.data)
            } else { $ppItems = @($ppResp) }
            if ($ppItems.Count -gt 0 -and $ppItems[0].PSObject.Properties.Name -contains "sp_number") {
                $ppSpNumber = [string]$ppItems[0].sp_number
            }
        }
        if ($ppSpNumber) {
            Write-Log ("Powerplant SP number: {0}" -f $ppSpNumber) "INFO"
        } else {
            Write-Log "Could not resolve powerplant SP number — non-plant-gear devices will be skipped for NCM." "WARN"
        }
    } catch {
        Write-Log ("Powerplant lookup failed: {0}" -f $_.Exception.Message) "WARN"
    }

    $progressActivity = "Fetching asset details"
    try {
    foreach ($dev in $deviceItems) {
        $i++

        $devAlias = $dev.alias
        $devName  = $dev.name

        # Per-iteration outcome flag for asset call.
        $assetSucceeded = $false

        $pct = if ($deviceItems.Count -gt 0) {
            [int](($i / $deviceItems.Count) * 100)
        } else { 0 }
        Write-Progress -Activity $progressActivity `
            -Status ("{0}/{1}  {2}" -f $i, $deviceItems.Count, $devAlias) `
            -PercentComplete $pct

        # ----- Asset details (per-device, by alias) -----
        $assetDetails = $null
        if (-not $abortAsset -and -not [string]::IsNullOrWhiteSpace([string]$devAlias)) {
            $aliasEnc   = [System.Uri]::EscapeDataString([string]$devAlias)
            $detailsUrl = "{0}/asset/details?search=device.alias:{1}" -f $apiBase, $aliasEnc
            try {
                $adSplat = Get-RequestSplat -Base @{
                    Method = "GET"; Uri = $detailsUrl; Headers = $ppHeaders; ErrorAction = "Stop"
                }
                $adResp = Invoke-RestMethod @adSplat
                if ($adResp.PSObject.Properties.Name -contains "data" -and $adResp.data) {
                    $assetDetails = @($adResp.data)
                } elseif ($adResp -is [System.Array]) {
                    $assetDetails = $adResp
                } else {
                    $assetDetails = @($adResp)
                }
                $assetSucceeded = $true
            }
            catch {
                $sc = $null; $body = $null
                try {
                    if ($_.Exception.PSObject.Properties.Name -contains "Response" -and $_.Exception.Response) {
                        $sc = [int]$_.Exception.Response.StatusCode
                    }
                } catch { }
                try {
                    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                        $body = [string]$_.ErrorDetails.Message
                    } elseif ($_.Exception.Response -and $_.Exception.Response.PSObject.Methods.Name -contains "GetResponseStream") {
                        # PS 5.1 fallback (NFR8).
                        $stream = $_.Exception.Response.GetResponseStream()
                        $reader = New-Object System.IO.StreamReader($stream)
                        $body   = $reader.ReadToEnd()
                    }
                } catch { }
                Write-Log ("[{0}/{1}] {2} asset/details failed: {3}" -f $i, $deviceItems.Count, $devAlias, $_.Exception.Message) "WARN"
                if ($body) { Write-Log ("    response body: {0}" -f $body) "WARN" }
                if ($sc -eq 401 -or $sc -eq 403) {
                    Write-Log ("First {0} on /asset/details. Aborting remaining asset call(s)." -f $sc) "ERROR"
                    $abortAsset = $true
                }
            }
        }

        # ----- NCM details (per-device by device_name) -----
        # NCM stores devices under SP-<n>-<sublocation>-<role> (e.g. SP-60423-VES1-WAN1),
        # not under WPP's DE-prefixed name or customer alias. Resolve-NcmDeviceName
        # derives the right key from $dev.name / $dev.alias + $ppSpNumber.
        # If it returns $null (NAT/CUSTOMER/CIAS-SUITCASE/etc.), skip the NCM call.
        # 404 here is "no NCM record" — logged silently and summarised after the loop.
        # 401/403 aborts remaining NCM calls.
        $ncmDetails = $null
        $ncmQueryName = Resolve-NcmDeviceName -Dev $dev -SpNumber $ppSpNumber
        $ncmResolved  = if ($ncmQueryName) { $ncmQueryName } else { '<skip>' }
        Write-Log ("[{0}/{1}] {2} NCM name resolution: name='{3}' alias='{4}' -> '{5}'" `
            -f $i, $deviceItems.Count, $devAlias, $devName, $devAlias, $ncmResolved) "DEBUG"

        if ($abortNcm) {
            # NCM was disabled mid-loop after a 401/403 — count remaining
            # devices as skipped so the summary totals reconcile.
            $ncmSkipped++
        }
        elseif ([string]::IsNullOrWhiteSpace($ncmQueryName)) {
            # No NCM-canonical name derivable for this device (NAT, CUSTOMER,
            # per-site CIAS-SUITCASE, or any other non-plant-gear shape).
            $ncmSkipped++
        }
        else {
            $nameEnc = [System.Uri]::EscapeDataString([string]$ncmQueryName)
            $ncmUrl  = "{0}/ncm/device/by-device-name?device_name={1}" -f $apiBase, $nameEnc
            try {
                $ncSplat = Get-RequestSplat -Base @{
                    Method = "GET"; Uri = $ncmUrl; Headers = $ppHeaders; ErrorAction = "Stop"
                }
                $ncResp = Invoke-RestMethod @ncSplat
                if ($ncResp.PSObject.Properties.Name -contains "data" -and $ncResp.data) {
                    $ncmDetails = $ncResp.data
                } else {
                    $ncmDetails = $ncResp
                }
                if ($ncmDetails) { $ncmHits++ } else { $ncmMisses++ }
            }
            catch {
                $sc = $null; $body = $null
                try {
                    if ($_.Exception.PSObject.Properties.Name -contains "Response" -and $_.Exception.Response) {
                        $sc = [int]$_.Exception.Response.StatusCode
                    }
                } catch { }
                if ($sc -eq 404) {
                    # Expected for non-NCM-enrolled devices — silent miss.
                    $ncmMisses++
                }
                else {
                    $ncmErrors++
                    try {
                        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                            $body = [string]$_.ErrorDetails.Message
                        } elseif ($_.Exception.Response -and $_.Exception.Response.PSObject.Methods.Name -contains "GetResponseStream") {
                            # PS 5.1 fallback (NFR8).
                            $stream = $_.Exception.Response.GetResponseStream()
                            $reader = New-Object System.IO.StreamReader($stream)
                            $body   = $reader.ReadToEnd()
                        }
                    } catch { }
                    Write-Log ("[{0}/{1}] {2} ncm/by-device-name failed ({3}): {4}" -f $i, $deviceItems.Count, $devAlias, $sc, $_.Exception.Message) "WARN"
                    if ($body) { Write-Log ("    response body: {0}" -f $body) "WARN" }
                    if ($sc -eq 401 -or $sc -eq 403) {
                        Write-Log ("First {0} on /ncm. Aborting remaining NCM call(s)." -f $sc) "ERROR"
                        $abortNcm = $true
                    }
                }
            }
        }

        $assetCount = @($assetDetails).Count
        $ncmFlag    = if ($ncmDetails) { "yes" } else { "no" }
        # Per-device tally: ok if asset succeeded OR a matching NCM record was found.
        if ($assetSucceeded -or $ncmDetails) { $chainOk++ } else { $chainFail++ }
        Write-Log ("[{0}/{1}] {2} -> {3} asset record(s), ncm={4}" -f $i, $deviceItems.Count, $devAlias, $assetCount, $ncmFlag) "INFO"

        $chainResults.Add([pscustomobject]@{
            device        = $dev
            asset_details = $assetDetails
            ncm_details   = $ncmDetails
        })
    }
    }
    finally {
        Write-Progress -Activity $progressActivity -Completed
    }

    Write-Log ("Chain complete: ok={0} failed={1} total={2}" -f $chainOk, $chainFail, $deviceItems.Count) "INFO"
    Write-Log ("NCM lookup: {0} hit(s), {1} miss(es) (not enrolled), {2} skipped (no NCM mapping), {3} error(s)." -f $ncmHits, $ncmMisses, $ncmSkipped, $ncmErrors) "INFO"

    Write-LogSection "OUTPUT"

    # Aggregated JSON
    $chainJson = Join-Path $OutputFolder ("AssetNcmDetails_{0}.json" -f $script:RunStamp)
    try {
        $chainResults | ConvertTo-Json -Depth 50 | Out-File -LiteralPath $chainJson -Encoding UTF8
        Write-Log "Chain JSON saved: $chainJson" "SUCCESS"
    } catch {
        Write-Log "Failed to write chain JSON: $($_.Exception.Message)" "ERROR"
    }

    # CSV — device + asset fields + NCM key scalars. Full NCM payload stays in JSON.
    $getProp = {
        param($o, $name)
        if ($null -eq $o) { return $null }
        try {
            if ($o.PSObject.Properties.Name -contains $name) { return $o.$name }
        } catch { }
        return $null
    }

    # CSV NCM columns sourced from the NcmDevice schema in api.doc.json:
    # device_id, base_template, name, global_options, regional_options.
    # The two _options fields are objects — serialize to compact JSON so the
    # CSV stays one-row-per-asset. Full payload remains in the JSON output.
    $csvRows = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $chainResults) {
        $dev = $entry.device
        $ads = @($entry.asset_details)
        $ncm = $entry.ncm_details

        $ncmBaseTemplate    = & $getProp $ncm 'base_template'
        $ncmDeviceId        = & $getProp $ncm 'device_id'
        $ncmName            = & $getProp $ncm 'name'
        $ncmGlobalOptionsObj   = & $getProp $ncm 'global_options'
        $ncmRegionalOptionsObj = & $getProp $ncm 'regional_options'
        $ncmGlobalOptions   = if ($null -ne $ncmGlobalOptionsObj)   { ($ncmGlobalOptionsObj   | ConvertTo-Json -Compress -Depth 10) } else { $null }
        $ncmRegionalOptions = if ($null -ne $ncmRegionalOptionsObj) { ($ncmRegionalOptionsObj | ConvertTo-Json -Compress -Depth 10) } else { $null }

        if ($ads.Count -eq 0) {
            $csvRows.Add([pscustomobject][ordered]@{
                DeviceID            = $dev.id
                DeviceName          = $dev.name
                DeviceAlias         = $dev.alias
                PowerplantID        = $dev.powerplant_id
                Mac_Address         = $dev.mac_address
                Ip_address          = $dev.ip_address
                AssetID             = $null
                AssetName           = $null
                AssetType           = $null
                Manufacturer        = $null
                Model               = $null
                SerialNumber        = $null
                Status              = $null
                UpdatedAt           = $null
                NCM_Name            = $ncmName
                NCM_DeviceID        = $ncmDeviceId
                NCM_BaseTemplate    = $ncmBaseTemplate
                NCM_GlobalOptions   = $ncmGlobalOptions
                NCM_RegionalOptions = $ncmRegionalOptions
            })
            continue
        }
        foreach ($a in $ads) {
            $csvRows.Add([pscustomobject][ordered]@{
                DeviceID            = $dev.id
                DeviceName          = $dev.name
                DeviceAlias         = $dev.alias
                PowerplantID        = $dev.powerplant_id
                Mac_Address         = $dev.mac_address
                Ip_address          = $dev.ip_address
                AssetID             = $a.id
                AssetName           = $a.name
                AssetType           = $a.type
                Manufacturer        = $a.manufacturer
                Model               = $a.model
                SerialNumber        = $a.serial_number
                Status              = $a.status
                UpdatedAt           = $a.updated_at
                NCM_Name            = $ncmName
                NCM_DeviceID        = $ncmDeviceId
                NCM_BaseTemplate    = $ncmBaseTemplate
                NCM_GlobalOptions   = $ncmGlobalOptions
                NCM_RegionalOptions = $ncmRegionalOptions
            })
        }
    }

    if ($csvRows.Count -gt 0) {
        $csvFile = Join-Path $OutputFolder ("AssetNcmDetails_{0}.csv" -f $script:RunStamp)
        $csvRows | Export-Csv -LiteralPath $csvFile -NoTypeInformation -Encoding UTF8
        Write-Log ("CSV written: {0} ({1} row(s))" -f $csvFile, $csvRows.Count) "SUCCESS"
    } else {
        Write-Log "No rows to write — CSV not created." "WARN"
    }

    $script:ChainHandled = $true
}
elseif ($chainKind -eq "assetConfigBackup") {
    # NCM-centric configuration backup report.
    # Flow:
    #   1. SAML SSO (lazy via Initialize-InternalSession).
    #   2. GET /powerplant/<id>?edit=1 from the internal app and parse the
    #      embedded <select id="ncm-devices"> — that select is the canonical
    #      mapping from ncm_device_id -> NCM hostname for the powerplant.
    #   3. For each NCM device in the map, call /get-ncm-device-subconfig
    #      (DataTables, last 3 by received_at desc).
    #   4. Best-effort match each NCM hostname back to a WPP device record
    #      (by exact alias, DE- stripped name, or SUITCASE->VES1 rewrite)
    #      so the CSV can carry WPP context (ip, alias) alongside config data.
    # Output: ConfigBackup_<stamp>.json + ConfigBackup_<stamp>.csv (';' delimited).
    #
    # The public-API /ncm/device/by-device-name path is NOT used — it 404s
    # for every device on prod because that namespace is disjoint from NCM's
    # actual records.

    Write-LogSection "CHAIN: CONFIG BACKUP"
    Write-Log "Chain enabled — NCM-map from powerplant page + per-device last-3 config history." "INFO"

    # Normalize device list.
    $deviceItems = @()
    if ($ppResponse.PSObject.Properties.Name -contains "data" -and $ppResponse.data) {
        $deviceItems = @($ppResponse.data)
    } elseif ($ppResponse -is [System.Array]) {
        $deviceItems = $ppResponse
    } else {
        $deviceItems = @($ppResponse)
    }

    $apiBase = ($AuthUrl -replace '/public/auth/?$','').TrimEnd('/')
    $internalBase = $null
    try {
        if ($config.PSObject.Properties.Name -contains "internalAuth" -and $config.internalAuth -and $config.internalAuth.host) {
            $internalBase = 'https://{0}' -f [string]$config.internalAuth.host
        }
    } catch { }
    if (-not $internalBase) {
        Write-Log "config.internalAuth.host not set — cannot reach the internal API. Aborting chain." "ERROR"
        $script:ChainHandled = $true
        return
    }
    Write-Log ("API base: {0}  Internal base: {1}  WPP devices loaded: {2}" -f $apiBase, $internalBase, $deviceItems.Count) "INFO"

    # Powerplant id (needed for /powerplant/<id>) and name (for the UI search).
    $ppId = $null
    foreach ($d in $deviceItems) {
        if ($d.powerplant -and $d.powerplant.id) { $ppId = $d.powerplant.id; break }
        if ($d.powerplant_id)                    { $ppId = $d.powerplant_id; break }
    }
    if (-not $ppId) {
        Write-Log "Could not resolve a powerplant id from the device list. Aborting chain." "ERROR"
        $script:ChainHandled = $true
        return
    }

    # Powerplant name (e.g. "DE-HeDreiht") — needed by the Playwright extractor
    # to fill the UI search box. Look it up via the public API.
    $ppName = $null
    $ppLookupUrl = "{0}/powerplants?search=id:{1}" -f $apiBase, $ppId
    # Retry the name lookup so a single transient network stall self-recovers.
    # Get-RequestSplat now sets a default TimeoutSec, so a hung connection fails
    # fast (instead of blocking forever as it did on the v1.5.0 06-03 run) and
    # this loop gets a second attempt before the chain aborts cleanly below.
    for ($ppAttempt = 1; $ppAttempt -le 2; $ppAttempt++) {
        try {
            $ppSplat = Get-RequestSplat -Base @{
                Method = "GET"; Uri = $ppLookupUrl; Headers = $ppHeaders; ErrorAction = "Stop"
            }
            $ppDetail = Invoke-RestMethod @ppSplat
            $ppItems = @()
            if ($ppDetail.PSObject.Properties.Name -contains "data" -and $ppDetail.data) {
                $ppItems = @($ppDetail.data)
            } else { $ppItems = @($ppDetail) }
            if ($ppItems.Count -gt 0 -and $ppItems[0].PSObject.Properties.Name -contains "name") {
                $ppName = [string]$ppItems[0].name
            }
            break  # clean response (named or not) — retrying won't change it
        } catch {
            # Log a sanitized summary (HTTP status code or exception type), NOT the
            # raw Exception.Message, which can echo a server response body.
            $status = $null
            try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { }
            $summary = if ($status) { "HTTP $status" } else { $_.Exception.GetType().Name }
            Write-Log ("Powerplant name lookup attempt {0}/2 failed: {1}" -f $ppAttempt, $summary) "WARN"
            # Only a timeout/transient stall is worth retrying. A 4xx/5xx/auth
            # error will fail identically, so abort the retry early.
            $isTransient = ([string]$_.Exception.Message) -match '(?i)tim(e|ed)\s*out|cancell?ed'
            if (-not $isTransient) {
                Write-Log "Lookup error is not a transient stall — not retrying." "WARN"
                break
            }
            if ($ppAttempt -lt 2) { Start-Sleep -Seconds 3 }
        }
    }
    if (-not $ppName) {
        Write-Log ("Could not resolve powerplant name for id={0}. Cannot drive the UI search. Aborting chain." -f $ppId) "ERROR"
        $script:ChainHandled = $true
        return
    }
    Write-Log ("Powerplant: id={0}, name={1}" -f $ppId, $ppName) "INFO"

    # Use the Playwright extractor: it drives the full SAML login + UI flow,
    # then dumps both the ncm_device_id map AND the session cookies. Hostname
    # auth flow + Vue render are entirely owned by the browser. With the
    # combo-probe pass enabled (default), it also discovers each device's
    # (base_template, boot_system_bootflash) groupings so we can drill down to
    # the actual config history records (the endpoint filters by exact match
    # on those keys, so without them the response is empty for most devices).
    Write-LogSection "INTERNAL-API AUTH"
    $ncmDevices = $null
    try {
        $extracted = Get-NcmDeviceMapViaBrowser -PowerplantId $ppId -SearchName $ppName
        $ncmDevices = @($extracted.Devices)
        # Build the WebRequestSession from the browser's cookies — replaces
        # what Initialize-InternalSession used to provide. The per-device
        # subconfig fan-out below uses these cookies directly.
        $script:InternalSessionData = Import-BrowserCookies -CookieFile $extracted.CookieFile
    } catch {
        Write-Log ("Cannot proceed with config-backup chain: {0}" -f $_.Exception.Message) "ERROR"
        $script:ChainHandled = $true
        return
    }
    if (-not $ncmDevices -or $ncmDevices.Count -eq 0) {
        Write-Log "NCM device list is empty — nothing to report." "WARN"
    }

    Write-LogSection "CHAIN: CONFIG BACKUP (continued)"

    # Build a best-effort lookup index from candidate NCM-style names back to
    # WPP device records, so the CSV can carry WPP context (alias, ip) per row.
    # Candidates per WPP device:
    #   1. Raw alias                              (matches CIAS-HUB-9998-VES1-WAN1)
    #   2. Raw name                               (matches CIAS-####-VES1-WAN1)
    #   3. Name with DE- prefix stripped          (DE-SP-... → SP-...)
    #   4. SUITCASE-WAN# → VES1-WAN#              (CIAS-####-SUITCASE-WAN1 → CIAS-####-VES1-WAN1)
    #   5. SUITCASE-SW → VES1-CORE-SW1            (CIAS-####-SUITCASE-SW → CIAS-####-VES1-CORE-SW1)
    $wppByNcmName = @{}
    foreach ($d in $deviceItems) {
        $cands = New-Object System.Collections.Generic.List[string]
        if ($d.alias) { [void]$cands.Add([string]$d.alias) }
        if ($d.name)  { [void]$cands.Add([string]$d.name) }
        if ($d.name -like 'DE-SP-*') { [void]$cands.Add(($d.name -replace '^[A-Z]{2}-','')) }
        if ($d.alias -match '^(.+)-SUITCASE-(WAN\d+)$') {
            [void]$cands.Add(($d.alias -replace '-SUITCASE-(WAN\d+)$', '-VES1-$1'))
        }
        if ($d.alias -match '^(.+)-SUITCASE-SW$') {
            [void]$cands.Add(($d.alias -replace '-SUITCASE-SW$', '-VES1-CORE-SW1'))
        }
        foreach ($c in $cands) {
            if (-not [string]::IsNullOrWhiteSpace($c) -and -not $wppByNcmName.ContainsKey($c)) {
                $wppByNcmName[$c] = $d
            }
        }
    }

    # Per-NCM-device fan-out.
    #
    # Three-level data model: device -> combo -> config history. We iterate
    # device x combo, request a window of recent records per combo, then
    # filter to status='HAS CHANGES' (per user requirement) and take the last
    # $configMaxSlots. The server returns rows newest-first and reports the
    # combo's total backup count (recordsTotal). A device whose recent backups
    # are all IDENTICAL can still have HAS CHANGES on an older page, so we PAGE
    # backwards ($serverFetchWindow rows at a time) until we have collected
    # $configMaxSlots HAS CHANGES OR we have consumed the whole history.
    # Devices with no combos OR no HAS CHANGES rows still emit an audit row.
    $configMaxSlots     = 3
    $serverFetchWindow  = 100   # rows per page ("Show 100 entries")
    $configMaxPages     = 20    # hard cap: never fetch more than this many
                                # pages per combo (guards against a server that
                                # ignores 'start' or omits recordsTotal).
    $chainResults = New-Object System.Collections.Generic.List[object]
    $csvRows      = New-Object System.Collections.Generic.List[object]
    $cfgHits = 0; $cfgErrors = 0; $cfgNoCombos = 0; $cfgNoHasChanges = 0; $i = 0
    $totalCombosSeen = 0
    $abortCfg = $false
    $progressActivity = "Fetching configuration backups"
    $ncmTotal = $ncmDevices.Count

    try {
    foreach ($dev in $ncmDevices) {
        $i++
        $ncmHostname = [string]$dev.Hostname
        $ncmDeviceId = [int]$dev.NcmDeviceId
        $combos      = @($dev.Combos)
        $comboCount  = $combos.Count
        $totalCombosSeen += $comboCount

        $pct = if ($ncmTotal -gt 0) { [int](($i / $ncmTotal) * 100) } else { 0 }
        Write-Progress -Activity $progressActivity `
            -Status ("{0}/{1}  {2} ({3} combos)" -f $i, $ncmTotal, $ncmHostname, $comboCount) `
            -PercentComplete $pct

        # Match to a WPP device if possible (best-effort context, not required).
        $wppDev = $null
        if ($wppByNcmName.ContainsKey($ncmHostname)) { $wppDev = $wppByNcmName[$ncmHostname] }

        # Per-device aggregation state. We accumulate HAS CHANGES across all
        # combos, then decide which single wide row to emit at the end.
        $allConfigsForDevice = New-Object System.Collections.Generic.List[object]
        $firstErrorCode      = $null
        $firstErrorBaseTpl   = ''
        $firstErrorBootSys   = ''
        $firstComboBaseTpl   = ''
        $firstComboBootSys   = ''

        if ($abortCfg) {
            # Skip all combo calls for this device; row emission decision below.
        }
        elseif ($comboCount -eq 0) {
            # Skip combo iteration; row emission decision below.
        }
        else {
            $cIdx = 0
            foreach ($combo in $combos) {
                $cIdx++
                $baseTpl  = if ($combo.BaseTemplate) { [string]$combo.BaseTemplate } else { '' }
                $bootSys  = if ($combo.BootSystem)   { [string]$combo.BootSystem   } else { '' }
                if ($cIdx -eq 1) {
                    $firstComboBaseTpl = $baseTpl
                    $firstComboBootSys = $bootSys
                }

                $configs = @()
                try {
                    # Page newest-first until we have $configMaxSlots HAS CHANGES
                    # for this combo OR we have walked the whole history. Healthy
                    # devices (HAS CHANGES on page 1) exit after a single request.
                    $pageStart  = 0
                    $recordsTot = $null    # learned from the FIRST page only
                    $pageGuard  = 0
                    $pageRows   = @()
                    $comboHits  = New-Object System.Collections.Generic.List[object]
                    do {
                        $pageGuard++
                        $cfgUrl = Build-NcmSubconfigUrl -InternalBase $internalBase `
                                    -NcmDeviceId   $ncmDeviceId `
                                    -Hostname      $ncmHostname `
                                    -BaseTemplate  $baseTpl `
                                    -BootSystem    $bootSys `
                                    -Length        $serverFetchWindow `
                                    -Start         $pageStart
                        $cfgResp = Invoke-RestMethod -Uri $cfgUrl `
                                    -WebSession $script:InternalSessionData.Session `
                                    -Headers    $script:InternalSessionData.Headers `
                                    -ErrorAction Stop `
                                    -TimeoutSec  120
                        if ($null -eq $recordsTot) {
                            $recordsTot = if ($cfgResp.PSObject.Properties.Name -contains 'recordsTotal') {
                                              [int]$cfgResp.recordsTotal
                                          } else { 0 }
                        }
                        $pageRows = @()
                        if ($cfgResp.PSObject.Properties.Name -contains "data" -and $cfgResp.data) {
                            $pageRows = @($cfgResp.data)
                            # Filter to HAS CHANGES per user requirement. Keep ALL
                            # hits from this page (we top-3 across all combos later).
                            foreach ($r in ($pageRows | Where-Object { $_.status -eq 'HAS CHANGES' })) {
                                [void]$comboHits.Add($r)
                            }
                        }
                        $pageStart += $serverFetchWindow
                    } while (
                        $comboHits.Count -lt $configMaxSlots          -and  # need more hits
                        $pageRows.Count  -ge $serverFetchWindow        -and  # full page => more may exist (short/empty page = last page)
                        ($recordsTot -le 0 -or $pageStart -lt $recordsTot) -and  # not past the known total
                        $pageGuard -lt $configMaxPages                       # hard safety cap
                    )
                    $configs = @($comboHits | Sort-Object -Property received_at -Descending)
                    if ($pageGuard -gt 1) {
                        Write-Log ("    {0} (bt='{1}' bs='{2}') paged {3} page(s), recordsTotal={4}, hasChanges={5}" `
                            -f $ncmHostname, $baseTpl, $bootSys, $pageGuard, $recordsTot, $comboHits.Count) "DEBUG"
                    }
                } catch {
                    $sc = $null; $body = $null
                    try { if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode } } catch { }
                    try {
                        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                            $body = [string]$_.ErrorDetails.Message
                        } elseif ($_.Exception.Response -and $_.Exception.Response.PSObject.Methods.Name -contains "GetResponseStream") {
                            $stream = $_.Exception.Response.GetResponseStream()
                            $reader = New-Object System.IO.StreamReader($stream)
                            $body   = $reader.ReadToEnd()
                        }
                    } catch { }
                    Write-Log ("[{0}/{1}] {2} (combo bt='{3}' bs='{4}') get-ncm-device-subconfig failed ({5}): {6}" `
                        -f $i, $ncmTotal, $ncmHostname, $baseTpl, $bootSys, $sc, $_.Exception.Message) "WARN"
                    if ($body) { Write-Log ("    response body: {0}" -f $body) "WARN" }
                    if ($sc -eq 401 -or $sc -eq 419) {
                        Write-Log "Internal session rejected mid-loop. Aborting remaining config calls." "ERROR"
                        $abortCfg = $true
                    }
                    if ($null -eq $firstErrorCode) {
                        $firstErrorCode    = $sc
                        $firstErrorBaseTpl = $baseTpl
                        $firstErrorBootSys = $bootSys
                    }
                    if ($abortCfg) { break }
                    continue
                }

                foreach ($c in $configs) { [void]$allConfigsForDevice.Add($c) }
            }
        }

        # ---- Row-emission decision (priority order):
        #   1. abort      -> <aborted>
        #   2. any error  -> <subconfig error N>
        #   3. no combos  -> <no combos discovered>
        #   4. no HAS CHG -> <no HAS CHANGES>
        #   5. success    -> HAS CHANGES (top 3 by received_at desc)
        if ($abortCfg -and $null -eq $firstErrorCode) {
            # Aborted before any combo call for this device produced an error
            # (e.g. abort flag set by a PREVIOUS device). Emit <aborted>.
            $cfgErrors++
            $csvRows.Add((New-ConfigBackupWideRow `
                -NcmDeviceId  $ncmDeviceId `
                -NcmHostname  $ncmHostname `
                -WppDevice    $wppDev `
                -Status       '<aborted>' `
                -BaseTemplate '' `
                -BootSystem   '' `
                -Slots        @()))
            $chainResults.Add([pscustomobject]@{ ncm_hostname = $ncmHostname; ncm_device_id = $ncmDeviceId; wpp_device = $wppDev; combos = $combos; configs = @() })
        }
        elseif ($null -ne $firstErrorCode) {
            # At least one combo errored. Emit one row carrying the first error
            # code seen and the BaseTemplate/BootSystem of that combo.
            $cfgErrors++
            $csvRows.Add((New-ConfigBackupWideRow `
                -NcmDeviceId  $ncmDeviceId `
                -NcmHostname  $ncmHostname `
                -WppDevice    $wppDev `
                -Status       ('<subconfig error ' + $firstErrorCode + '>') `
                -BaseTemplate $firstErrorBaseTpl `
                -BootSystem   $firstErrorBootSys `
                -Slots        @()))
            $chainResults.Add([pscustomobject]@{ ncm_hostname = $ncmHostname; ncm_device_id = $ncmDeviceId; wpp_device = $wppDev; combos = $combos; configs = $allConfigsForDevice.ToArray() })
        }
        elseif ($comboCount -eq 0) {
            # No combos discovered at all (empty base_template list).
            $cfgNoCombos++
            $csvRows.Add((New-ConfigBackupWideRow `
                -NcmDeviceId  $ncmDeviceId `
                -NcmHostname  $ncmHostname `
                -WppDevice    $wppDev `
                -Status       '<no combos discovered>' `
                -BaseTemplate '' `
                -BootSystem   '' `
                -Slots        @()))
            $chainResults.Add([pscustomobject]@{ ncm_hostname = $ncmHostname; ncm_device_id = $ncmDeviceId; wpp_device = $wppDev; combos = @(); configs = @() })
            Write-Log ("[{0}/{1}] {2} (0 combos) -> 0 config(s)" -f $i, $ncmTotal, $ncmHostname) "INFO"
        }
        elseif ($allConfigsForDevice.Count -eq 0) {
            # Combos returned data but no HAS CHANGES rows anywhere.
            $cfgNoHasChanges++
            $csvRows.Add((New-ConfigBackupWideRow `
                -NcmDeviceId  $ncmDeviceId `
                -NcmHostname  $ncmHostname `
                -WppDevice    $wppDev `
                -Status       '<no HAS CHANGES>' `
                -BaseTemplate $firstComboBaseTpl `
                -BootSystem   $firstComboBootSys `
                -Slots        @()))
            $chainResults.Add([pscustomobject]@{
                ncm_hostname  = $ncmHostname
                ncm_device_id = $ncmDeviceId
                wpp_device    = $wppDev
                combos        = $combos
                configs       = @()
            })
            Write-Log ("[{0}/{1}] {2} ({3} combos) -> 0 config(s)" -f $i, $ncmTotal, $ncmHostname, $comboCount) "INFO"
        }
        else {
            # Success: take top $configMaxSlots HAS CHANGES across all combos.
            $cfgHits++
            $topConfigs = @($allConfigsForDevice |
                                Sort-Object -Property received_at -Descending |
                                Select-Object -First $configMaxSlots)
            # Row BaseTemplate/BootSystem: prefer the top record's own values,
            # fall back to the combo used for the first hit.
            $rowBaseTpl = $firstComboBaseTpl
            $rowBootSys = $firstComboBootSys
            $top = $topConfigs[0]
            if ($top -and $top.PSObject.Properties.Name -contains 'base_template'         -and $top.base_template)         { $rowBaseTpl = [string]$top.base_template }
            if ($top -and $top.PSObject.Properties.Name -contains 'boot_system_bootflash' -and $top.boot_system_bootflash) { $rowBootSys = [string]$top.boot_system_bootflash }

            $csvRows.Add((New-ConfigBackupWideRow `
                -NcmDeviceId  $ncmDeviceId `
                -NcmHostname  $ncmHostname `
                -WppDevice    $wppDev `
                -Status       'HAS CHANGES' `
                -BaseTemplate $rowBaseTpl `
                -BootSystem   $rowBootSys `
                -Slots        $topConfigs))
            $chainResults.Add([pscustomobject]@{
                ncm_hostname  = $ncmHostname
                ncm_device_id = $ncmDeviceId
                wpp_device    = $wppDev
                combos        = $combos
                configs       = $allConfigsForDevice.ToArray()
            })
            Write-Log ("[{0}/{1}] {2} ({3} combos) -> {4} config(s)" -f $i, $ncmTotal, $ncmHostname, $comboCount, $allConfigsForDevice.Count) "INFO"
        }
    }
    }
    finally {
        Write-Progress -Activity $progressActivity -Completed
    }

    # WPP devices with no NCM record in the powerplant page are absent from
    # $ncmMap. Surface them as audit rows so the report shows EVERY WPP device.
    $matchedWppIds = New-Object System.Collections.Generic.HashSet[object]
    foreach ($cr in $chainResults) {
        if ($cr.wpp_device -and $cr.wpp_device.id) { [void]$matchedWppIds.Add($cr.wpp_device.id) }
    }
    $unmatchedWpp = 0
    foreach ($d in $deviceItems) {
        if ($d.id -and $matchedWppIds.Contains($d.id)) { continue }
        $unmatchedWpp++
        $csvRows.Add((New-ConfigBackupWideRow `
            -NcmDeviceId  0 `
            -NcmHostname  '' `
            -WppDevice    $d `
            -Status       '<no NCM record for this WPP device>' `
            -BaseTemplate '' `
            -BootSystem   '' `
            -Slots        @()))
    }

    Write-Log ("Chain complete: ncm={0} combos={1} hits={2} no_combos={3} no_has_changes={4} error={5} | wpp_unmatched={6}" `
        -f $ncmTotal, $totalCombosSeen, $cfgHits, $cfgNoCombos, $cfgNoHasChanges, $cfgErrors, $unmatchedWpp) "INFO"

    Write-LogSection "OUTPUT"

    # JSON: full nested {device, ncm_device, configs}.
    $jsonPath = Join-Path $OutputFolder ("ConfigBackup_{0}.json" -f $script:RunStamp)
    try {
        $chainResults | ConvertTo-Json -Depth 30 | Out-File -LiteralPath $jsonPath -Encoding UTF8
        Write-Log "JSON saved: $jsonPath" "SUCCESS"
    } catch {
        Write-Log ("Failed to write JSON: {0}" -f $_.Exception.Message) "ERROR"
    }

    # CSV with semicolon delimiter per user requirement.
    if ($csvRows.Count -gt 0) {
        $csvPath = Join-Path $OutputFolder ("ConfigBackup_{0}.csv" -f $script:RunStamp)
        try {
            $csvRows | Export-Csv -LiteralPath $csvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8
            Write-Log ("CSV written: {0} ({1} row(s), ';' delimiter)" -f $csvPath, $csvRows.Count) "SUCCESS"
        } catch {
            Write-Log ("Failed to write CSV: {0}" -f $_.Exception.Message) "ERROR"
        }
    } else {
        Write-Log "No rows to write — CSV not created." "WARN"
    }

    $script:ChainHandled = $true
}
elseif ($chainKind -eq "monthlyBackupRate") {
    # Monthly Backup-Rate report (NCM-centric).
    #
    # For each NCM device, count the backups taken in the PREVIOUS calendar
    # month (status IDENTICAL *or* HAS CHANGES — both are real backups) and
    # express coverage as:
    #       RatePct = DistinctDaysWithBackup / DaysInMonth * 100   (cap 100%)
    # The raw BackupCount is reported alongside for visibility.
    #
    # Reuses the same NCM-map discovery + per-device/combo subconfig paging as
    # the assetConfigBackup chain, with three differences:
    #   1. Pages newest-first only as far back as the START of the target month
    #      (older rows are irrelevant) — typically 1-2 requests per combo.
    #   2. Counts BOTH statuses (not HAS-CHANGES-only).
    #   3. De-duplicates rows by id across combos/pages so the rate cannot be
    #      inflated by overlaps.
    #
    # Window: previous calendar month relative to today, or -Month "yyyy-MM".
    # Run on 2026-06-01 with no -Month  ->  covers May 2026.

    Write-LogSection "CHAIN: MONTHLY BACKUP RATE"

    # ---- Resolve the target-month window -------------------------------------
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [string]::IsNullOrWhiteSpace($Month)) {
        # -Month is already shape-validated by [ValidatePattern] on the param.
        $monthStart = [datetime]::ParseExact($Month + '-01', 'yyyy-MM-dd', $invariant)
    } else {
        $today      = (Get-Date).Date
        $thisMonth1 = [datetime]::new($today.Year, $today.Month, 1, 0, 0, 0)
        $monthStart = $thisMonth1.AddMonths(-1)   # robust across Jan->prior-Dec
    }
    $monthEnd    = $monthStart.AddMonths(1)        # half-open upper bound (exclusive)
    $daysInMonth = [datetime]::DaysInMonth($monthStart.Year, $monthStart.Month)
    $monthLabel  = '{0:0000}-{1:00}' -f $monthStart.Year, $monthStart.Month
    Write-Log ("Target month: {0}  window [{1:yyyy-MM-dd HH:mm:ss} .. {2:yyyy-MM-dd HH:mm:ss})  daysInMonth={3}" `
        -f $monthLabel, $monthStart, $monthEnd, $daysInMonth) "INFO"

    # ---- Normalize device list & resolve powerplant (mirrors assetConfigBackup) --
    $deviceItems = @()
    if ($ppResponse.PSObject.Properties.Name -contains "data" -and $ppResponse.data) {
        $deviceItems = @($ppResponse.data)
    } elseif ($ppResponse -is [System.Array]) {
        $deviceItems = $ppResponse
    } else {
        $deviceItems = @($ppResponse)
    }

    $apiBase = ($AuthUrl -replace '/public/auth/?$','').TrimEnd('/')
    $internalBase = $null
    try {
        if ($config.PSObject.Properties.Name -contains "internalAuth" -and $config.internalAuth -and $config.internalAuth.host) {
            $internalBase = 'https://{0}' -f [string]$config.internalAuth.host
        }
    } catch { }
    if (-not $internalBase) {
        Write-Log "config.internalAuth.host not set — cannot reach the internal API. Aborting chain." "ERROR"
        $script:ChainHandled = $true
        return
    }
    Write-Log ("API base: {0}  Internal base: {1}  WPP devices loaded: {2}" -f $apiBase, $internalBase, $deviceItems.Count) "INFO"

    $ppId = $null
    foreach ($d in $deviceItems) {
        if ($d.powerplant -and $d.powerplant.id) { $ppId = $d.powerplant.id; break }
        if ($d.powerplant_id)                    { $ppId = $d.powerplant_id; break }
    }
    if (-not $ppId) {
        Write-Log "Could not resolve a powerplant id from the device list. Aborting chain." "ERROR"
        $script:ChainHandled = $true
        return
    }

    $ppName = $null
    $ppLookupUrl = "{0}/powerplants?search=id:{1}" -f $apiBase, $ppId
    # Retry the name lookup so a single transient network stall self-recovers.
    # Get-RequestSplat now sets a default TimeoutSec, so a hung connection fails
    # fast (instead of blocking forever as it did on the v1.5.0 06-03 run) and
    # this loop gets a second attempt before the chain aborts cleanly below.
    for ($ppAttempt = 1; $ppAttempt -le 2; $ppAttempt++) {
        try {
            $ppSplat = Get-RequestSplat -Base @{
                Method = "GET"; Uri = $ppLookupUrl; Headers = $ppHeaders; ErrorAction = "Stop"
            }
            $ppDetail = Invoke-RestMethod @ppSplat
            $ppItems = @()
            if ($ppDetail.PSObject.Properties.Name -contains "data" -and $ppDetail.data) {
                $ppItems = @($ppDetail.data)
            } else { $ppItems = @($ppDetail) }
            if ($ppItems.Count -gt 0 -and $ppItems[0].PSObject.Properties.Name -contains "name") {
                $ppName = [string]$ppItems[0].name
            }
            break  # clean response (named or not) — retrying won't change it
        } catch {
            # Log a sanitized summary (HTTP status code or exception type), NOT the
            # raw Exception.Message, which can echo a server response body.
            $status = $null
            try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { }
            $summary = if ($status) { "HTTP $status" } else { $_.Exception.GetType().Name }
            Write-Log ("Powerplant name lookup attempt {0}/2 failed: {1}" -f $ppAttempt, $summary) "WARN"
            # Only a timeout/transient stall is worth retrying. A 4xx/5xx/auth
            # error will fail identically, so abort the retry early.
            $isTransient = ([string]$_.Exception.Message) -match '(?i)tim(e|ed)\s*out|cancell?ed'
            if (-not $isTransient) {
                Write-Log "Lookup error is not a transient stall — not retrying." "WARN"
                break
            }
            if ($ppAttempt -lt 2) { Start-Sleep -Seconds 3 }
        }
    }
    if (-not $ppName) {
        Write-Log ("Could not resolve powerplant name for id={0}. Cannot drive the UI search. Aborting chain." -f $ppId) "ERROR"
        $script:ChainHandled = $true
        return
    }
    Write-Log ("Powerplant: id={0}, name={1}" -f $ppId, $ppName) "INFO"

    Write-LogSection "INTERNAL-API AUTH"
    $ncmDevices = $null
    try {
        $extracted = Get-NcmDeviceMapViaBrowser -PowerplantId $ppId -SearchName $ppName
        $ncmDevices = @($extracted.Devices)
        $script:InternalSessionData = Import-BrowserCookies -CookieFile $extracted.CookieFile
    } catch {
        Write-Log ("Cannot proceed with monthly-backup-rate chain: {0}" -f $_.Exception.Message) "ERROR"
        $script:ChainHandled = $true
        return
    }
    if (-not $ncmDevices -or $ncmDevices.Count -eq 0) {
        Write-Log "NCM device list is empty — nothing to report." "WARN"
    }

    Write-LogSection "CHAIN: MONTHLY BACKUP RATE (continued)"

    # Best-effort WPP context index (same candidate rules as assetConfigBackup).
    $wppByNcmName = @{}
    foreach ($d in $deviceItems) {
        $cands = New-Object System.Collections.Generic.List[string]
        if ($d.alias) { [void]$cands.Add([string]$d.alias) }
        if ($d.name)  { [void]$cands.Add([string]$d.name) }
        if ($d.name -like 'DE-SP-*') { [void]$cands.Add(($d.name -replace '^[A-Z]{2}-','')) }
        if ($d.alias -match '^(.+)-SUITCASE-(WAN\d+)$') {
            [void]$cands.Add(($d.alias -replace '-SUITCASE-(WAN\d+)$', '-VES1-$1'))
        }
        if ($d.alias -match '^(.+)-SUITCASE-SW$') {
            [void]$cands.Add(($d.alias -replace '-SUITCASE-SW$', '-VES1-CORE-SW1'))
        }
        foreach ($c in $cands) {
            if (-not [string]::IsNullOrWhiteSpace($c) -and -not $wppByNcmName.ContainsKey($c)) {
                $wppByNcmName[$c] = $d
            }
        }
    }

    # ---- Per-NCM-device fan-out: count in-window backups across combos -------
    $serverFetchWindow = 100   # rows per page
    $maxPages          = 50    # hard cap per combo (a busy device may have many
                               # same-month rows before we cross the window start)
    $rateResults   = New-Object System.Collections.Generic.List[object]
    $csvRows       = New-Object System.Collections.Generic.List[object]
    $matchedWppIds = New-Object System.Collections.Generic.HashSet[object]
    $sumWith = 0; $sumZero = 0; $sumErrors = 0; $sumNoCombos = 0
    $i = 0; $abortRate = $false
    $ncmTotal = $ncmDevices.Count
    $progressActivity = "Computing monthly backup rate"

    try {
    foreach ($dev in $ncmDevices) {
        $i++
        $ncmHostname = [string]$dev.Hostname
        $ncmDeviceId = [int]$dev.NcmDeviceId
        $combos      = @($dev.Combos)
        $comboCount  = $combos.Count

        $pct = if ($ncmTotal -gt 0) { [int](($i / $ncmTotal) * 100) } else { 0 }
        Write-Progress -Activity $progressActivity `
            -Status ("{0}/{1}  {2}" -f $i, $ncmTotal, $ncmHostname) -PercentComplete $pct

        $wppDev = $null
        if ($wppByNcmName.ContainsKey($ncmHostname)) { $wppDev = $wppByNcmName[$ncmHostname] }
        if ($wppDev -and $wppDev.id) { [void]$matchedWppIds.Add($wppDev.id) }

        # Per-device aggregation: distinct in-window backup ids and distinct days.
        $seenIds        = New-Object System.Collections.Generic.HashSet[string]
        $daySet         = New-Object System.Collections.Generic.HashSet[string]
        $backupCount    = 0
        $firstAt        = $null
        $lastAt         = $null
        $firstErrorCode = $null

        if ($abortRate -or $comboCount -eq 0) {
            # Skip combo calls; row emission decision below.
        }
        else {
            foreach ($combo in $combos) {
                $baseTpl = if ($combo.BaseTemplate) { [string]$combo.BaseTemplate } else { '' }
                $bootSys = if ($combo.BootSystem)   { [string]$combo.BootSystem   } else { '' }
                try {
                    $pageStart    = 0
                    $recordsTot   = $null
                    $pageGuard    = 0
                    $pageRows     = @()
                    $reachedOlder = $false
                    do {
                        $pageGuard++
                        $cfgUrl = Build-NcmSubconfigUrl -InternalBase $internalBase `
                                    -NcmDeviceId   $ncmDeviceId `
                                    -Hostname      $ncmHostname `
                                    -BaseTemplate  $baseTpl `
                                    -BootSystem    $bootSys `
                                    -Length        $serverFetchWindow `
                                    -Start         $pageStart
                        $cfgResp = Invoke-RestMethod -Uri $cfgUrl `
                                    -WebSession $script:InternalSessionData.Session `
                                    -Headers    $script:InternalSessionData.Headers `
                                    -ErrorAction Stop `
                                    -TimeoutSec  120
                        if ($null -eq $recordsTot) {
                            $recordsTot = if ($cfgResp.PSObject.Properties.Name -contains 'recordsTotal') {
                                              [int]$cfgResp.recordsTotal
                                          } else { 0 }
                        }
                        $pageRows = @()
                        if ($cfgResp.PSObject.Properties.Name -contains "data" -and $cfgResp.data) {
                            $pageRows = @($cfgResp.data)
                            foreach ($r in $pageRows) {
                                $raw = [string]$r.received_at
                                if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                                $rx = [datetime]::MinValue
                                if (-not [datetime]::TryParseExact($raw, 'yyyy-MM-dd HH:mm:ss', $invariant,
                                        [System.Globalization.DateTimeStyles]::None, [ref]$rx)) {
                                    Write-Log ("    {0}: unparseable received_at '{1}' — skipped" -f $ncmHostname, $raw) "DEBUG"
                                    continue
                                }
                                if ($rx -lt $monthStart) { $reachedOlder = $true; continue }  # older than window -> stop after this page
                                if ($rx -ge $monthEnd)   { continue }                         # newer than window -> skip, keep paging
                                $st = [string]$r.status
                                if ($st -ne 'IDENTICAL' -and $st -ne 'HAS CHANGES') { continue }
                                # De-dup by row id (across combos & overlapping pages).
                                $idKey = if ($r.PSObject.Properties.Name -contains 'id' -and $null -ne $r.id) {
                                             'id:' + [string]$r.id
                                         } else {
                                             'rx:' + $ncmDeviceId.ToString() + '|' + $raw
                                         }
                                if (-not $seenIds.Add($idKey)) { continue }
                                $backupCount++
                                [void]$daySet.Add($rx.ToString('yyyy-MM-dd', $invariant))
                                if ($null -eq $firstAt -or $rx -lt $firstAt) { $firstAt = $rx }
                                if ($null -eq $lastAt  -or $rx -gt $lastAt)  { $lastAt  = $rx }
                            }
                        }
                        $pageStart += $serverFetchWindow
                    } while (
                        -not $reachedOlder                                 -and  # primary stop: crossed window start (rows are newest-first)
                        $pageRows.Count -ge $serverFetchWindow              -and  # short/empty page = last page
                        ($recordsTot -le 0 -or $pageStart -lt $recordsTot) -and  # not past known total
                        $pageGuard -lt $maxPages                                 # hard safety cap
                    )
                    if ($pageGuard -gt 1) {
                        Write-Log ("    {0} (bt='{1}' bs='{2}') paged {3} page(s), recordsTotal={4}" `
                            -f $ncmHostname, $baseTpl, $bootSys, $pageGuard, $recordsTot) "DEBUG"
                    }
                } catch {
                    $sc = $null
                    try { if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode } } catch { }
                    Write-Log ("[{0}/{1}] {2} (combo bt='{3}' bs='{4}') get-ncm-device-subconfig failed ({5}): {6}" `
                        -f $i, $ncmTotal, $ncmHostname, $baseTpl, $bootSys, $sc, $_.Exception.Message) "WARN"
                    if ($sc -eq 401 -or $sc -eq 419) {
                        Write-Log "Internal session rejected mid-loop. Aborting remaining config calls." "ERROR"
                        $abortRate = $true
                    }
                    if ($null -eq $firstErrorCode) { $firstErrorCode = $sc }
                    if ($abortRate) { break }
                    continue
                }
            }
        }

        # ---- Row emission --------------------------------------------------
        $distinctDays = $daySet.Count
        $ratePct = if ($daysInMonth -gt 0) { [math]::Round(($distinctDays / $daysInMonth) * 100, 1) } else { 0 }
        if ($ratePct -gt 100) { $ratePct = 100 }   # distinct-day metric is naturally <=100; defensive cap

        $note = ''
        if     ($abortRate -and $null -eq $firstErrorCode) { $note = '<aborted>'; $sumErrors++ }
        elseif ($null -ne $firstErrorCode)                 { $note = ('<subconfig error ' + $firstErrorCode + '>'); $sumErrors++ }
        elseif ($comboCount -eq 0)                         { $note = '<no combos discovered>'; $sumNoCombos++ }
        elseif ($backupCount -eq 0)                        { $note = '<no backups in month>'; $sumZero++ }
        else                                               { $sumWith++ }

        $firstStr = if ($firstAt) { $firstAt.ToString('yyyy-MM-dd HH:mm:ss', $invariant) } else { '' }
        $lastStr  = if ($lastAt)  { $lastAt.ToString('yyyy-MM-dd HH:mm:ss', $invariant) }  else { '' }

        $csvRows.Add((New-BackupRateRow `
            -NcmDeviceId   $ncmDeviceId `
            -NcmHostname   $ncmHostname `
            -WppDevice     $wppDev `
            -Month         $monthLabel `
            -BackupCount   $backupCount `
            -DistinctDays  $distinctDays `
            -DaysInMonth   $daysInMonth `
            -RatePct       $ratePct `
            -FirstBackupAt $firstStr `
            -LastBackupAt  $lastStr `
            -Note          $note))

        # JSON carries ONLY aggregate fields (no raw payload / no usernames).
        $rateResults.Add([pscustomobject]@{
            ncm_device_id   = $ncmDeviceId
            ncm_hostname    = $ncmHostname
            wpp_alias       = $(if ($wppDev -and $wppDev.alias) { [string]$wppDev.alias } else { '' })
            month           = $monthLabel
            backup_count    = $backupCount
            distinct_days   = $distinctDays
            days_in_month   = $daysInMonth
            rate_pct        = $ratePct
            first_backup_at = $firstStr
            last_backup_at  = $lastStr
            note            = $note
        })

        Write-Log ("[{0}/{1}] {2} -> {3} backup(s), {4}/{5} days = {6}%{7}" `
            -f $i, $ncmTotal, $ncmHostname, $backupCount, $distinctDays, $daysInMonth, $ratePct, `
               $(if ($note) { " $note" } else { '' })) "INFO"
    }
    }
    finally {
        Write-Progress -Activity $progressActivity -Completed
    }

    # WPP devices with no NCM record -> audit rows (every WPP device represented).
    $unmatchedWpp = 0
    foreach ($d in $deviceItems) {
        if ($d.id -and $matchedWppIds.Contains($d.id)) { continue }
        $unmatchedWpp++
        $csvRows.Add((New-BackupRateRow `
            -NcmDeviceId  0 `
            -NcmHostname  '' `
            -WppDevice    $d `
            -Month        $monthLabel `
            -DaysInMonth  $daysInMonth `
            -Note         '<no NCM record for this WPP device>'))
    }

    Write-Log ("Chain complete: month={0} ncm={1} with_backups={2} zero={3} no_combos={4} error={5} | wpp_unmatched={6}" `
        -f $monthLabel, $ncmTotal, $sumWith, $sumZero, $sumNoCombos, $sumErrors, $unmatchedWpp) "INFO"

    Write-LogSection "OUTPUT"

    $jsonPath = Join-Path $OutputFolder ("MonthlyBackupRate_{0}_{1}.json" -f $monthLabel, $script:RunStamp)
    try {
        $rateResults | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $jsonPath -Encoding UTF8
        Write-Log "JSON saved: $jsonPath" "SUCCESS"
    } catch {
        Write-Log ("Failed to write JSON: {0}" -f $_.Exception.Message) "ERROR"
    }

    if ($csvRows.Count -gt 0) {
        $csvPath = Join-Path $OutputFolder ("MonthlyBackupRate_{0}_{1}.csv" -f $monthLabel, $script:RunStamp)
        try {
            $csvRows | Export-Csv -LiteralPath $csvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8
            Write-Log ("CSV written: {0} ({1} row(s), ';' delimiter)" -f $csvPath, $csvRows.Count) "SUCCESS"
        } catch {
            Write-Log ("Failed to write CSV: {0}" -f $_.Exception.Message) "ERROR"
        }
    } else {
        Write-Log "No rows to write — CSV not created." "WARN"
    }

    $script:ChainHandled = $true
}
elseif ($chainKind -eq "assetSoftware") {
    # Per-device /asset/details (alias-based) focused on RUNNING software state:
    # OS, firmware, software/image version, serial. Same fan-out technique as the
    # "assetDetails" chain. Two differences from that chain:
    #   1) Field names in the /asset/details 200 body are UNKNOWN (every sample to
    #      date is null), so software columns are resolved DEFENSIVELY by probing
    #      multiple candidate spellings, and an AssetFieldsSeen diagnostic column
    #      reveals the real schema on the first live 200.
    #   2) The CMDB payload can carry secrets/PII (snmp_community, ftp_password,
    #      encryption_password, email...). Per CLAUDE.md rules 6/7 (No PII / secrets
    #      only in .env), the full JSON payload is passed through a redaction pass
    #      ($redact) before it is written to disk, and secret-like field NAMES are
    #      masked in AssetFieldsSeen.
    Write-LogSection "CHAIN: ASSET SOFTWARE"
    Write-Log "Chain enabled — fanning out per device.alias for running software state." "INFO"

    # Normalize the primary response into an array of device records.
    $deviceItems = @()
    if ($ppResponse.PSObject.Properties.Name -contains "data" -and $ppResponse.data) {
        $deviceItems = @($ppResponse.data)
    } elseif ($ppResponse -is [System.Array]) {
        $deviceItems = $ppResponse
    } else {
        $deviceItems = @($ppResponse)
    }

    $apiBase = ($AuthUrl -replace '/public/auth/?$','').TrimEnd('/')
    Write-Log ("API base: {0}  Devices to enrich: {1}" -f $apiBase, $deviceItems.Count) "INFO"

    # --- Local helpers (branch-scoped; only assigned when this branch runs) ----

    # Single-name, case-insensitive, null-safe property getter (mirrors $getProp
    # in the assetDetailsAndNcm branch). PSObject property access is itself
    # case-insensitive, so candidate lists only need distinct spellings.
    $getOne = {
        param($o, $name)
        if ($null -eq $o) { return $null }
        try { if ($o.PSObject.Properties.Name -contains $name) { return $o.$name } } catch { }
        return $null
    }

    # Reduce any value to a CSV-safe scalar. Objects/arrays are serialized to
    # compact JSON (same approach as the NCM *_Options columns) so a cell never
    # contains the literal "System.Object[]". Whitespace strings -> $null.
    $scalarize = {
        param($v)
        if ($null -eq $v) { return $null }
        if ($v -is [string])    { if ([string]::IsNullOrWhiteSpace($v)) { return $null } else { return $v } }
        if ($v -is [ValueType]) { return $v }
        try { return ($v | ConvertTo-Json -Compress -Depth 10) } catch { return [string]$v }
    }

    # Resolve a logical field from an asset record by trying candidate spellings,
    # first on the record itself, then one level into common container objects.
    $resolveField = {
        param($o, [string[]]$candidates)
        if ($null -eq $o) { return $null }
        $scopes = @($o)
        foreach ($c in @('software','attributes','inventory','details')) {
            $sub = & $getOne $o $c
            if ($null -ne $sub) {
                if ($sub -is [System.Array]) { if (@($sub).Count -gt 0) { $scopes += ,(@($sub)[0]) } }
                else { $scopes += ,$sub }
            }
        }
        foreach ($scope in $scopes) {
            foreach ($name in $candidates) {
                $s = & $scalarize (& $getOne $scope $name)
                if ($null -ne $s) { return $s }
            }
        }
        return $null
    }

    # Secret/PII key denylist. Applied to redaction and to AssetFieldsSeen.
    $secretKey = '(?i)pass(word)?|secret|community|credential|private[_-]?key|token|encryption|^ftp_user$|api[_-]?key|email'

    # Recursive redaction: mask values whose KEY matches $secretKey; recurse into
    # nested objects/arrays. Rebuilds objects so the original (used for CSV
    # resolution of non-secret software fields) is left untouched.
    $redact = {
        param($o)
        if ($null -eq $o) { return $null }
        if ($o -is [string] -or $o -is [ValueType]) { return $o }
        if ($o -is [System.Collections.IDictionary]) {
            $out = [ordered]@{}
            foreach ($k in @($o.Keys)) {
                if ([string]$k -match $secretKey) { $out[[string]$k] = "<redacted>" }
                else { $out[[string]$k] = (& $redact $o[$k]) }
            }
            return [pscustomobject]$out
        }
        if ($o -is [System.Collections.IEnumerable]) {
            $arr = @(); foreach ($item in $o) { $arr += (& $redact $item) }
            return ,$arr
        }
        if ($o.PSObject -and $o.PSObject.Properties) {
            $out = [ordered]@{}
            foreach ($p in $o.PSObject.Properties) {
                if ($p.Name -match $secretKey) { $out[$p.Name] = "<redacted>" }
                else { $out[$p.Name] = (& $redact $p.Value) }
            }
            return [pscustomobject]$out
        }
        return $o
    }

    # Diagnostic: '|'-joined top-level field names of an asset record, with
    # secret-like names masked and the list bounded so a huge nested tree of
    # collector data cannot bloat the cell.
    $fieldsSeen = {
        param($o)
        if ($null -eq $o) { return $null }
        try {
            $names = @($o.PSObject.Properties.Name)
            $masked = foreach ($n in $names) { if ($n -match $secretKey) { "<redacted-key>" } else { $n } }
            return ((@($masked) | Select-Object -First 40) -join '|')
        } catch { return $null }
    }

    # Candidate spellings per logical column (case handled by the getter).
    $cOS       = @('os','operating_system','os_name','platform','sw_type')
    $cOSVer    = @('os_version','osVersion','software_version','sw_version','version','running_version','ios_version','image_version')
    $cFirmware = @('firmware','firmware_version','fw_version','firmwareVersion')
    $cImage    = @('image','software_image','running_image','ios','feature_set')
    $cSerial   = @('serial_number','serialNumber','serial','sn','sca_serialnum')
    $cStatus   = @('status','state')
    $cLastSeen = @('last_seen','collector_last_run_date','last_inventory_at','updated_at')

    $chainResults = New-Object System.Collections.Generic.List[object]
    $chainOk = 0; $chainFail = 0; $i = 0

    # Pre-flight check ONCE for /asset/details (role already mapped: Get Asset Details).
    $chainCheck = Test-EndpointAllowed -Url "$apiBase/asset/details" -UserRoles $script:UserRoles
    if (-not $chainCheck.Allowed) {
        Write-Log ("Chain SKIPPED: required role '{0}' not granted to '{1}'. Avoids {2} x 401 per-device call." -f $chainCheck.Required, $username, $deviceItems.Count) "ERROR"
        Write-Log "AssetSoftware CSV will still be written from the device list, with empty software columns." "WARN"
        try {
            foreach ($dev in $deviceItems) {
                $chainResults.Add([pscustomobject]@{ device = $dev; asset_details = $null })
            }
        } catch {
            Write-Log "Failed to build empty chain results: $($_.Exception.Message)" "ERROR"
        }
        $skipChainLoop = $true
    } else {
        $skipChainLoop = $false
        if ($chainCheck.Required) {
            Write-Log ("Chain permission check OK (role: {0})" -f $chainCheck.Required) "DEBUG"
        }
    }

    if (-not $skipChainLoop) {
    $abortChainOn401 = $false
    $progressActivity = "Fetching asset software"
    try {
    foreach ($dev in $deviceItems) {
        $i++

        $devId    = $dev.id
        $devAlias = $dev.alias

        # Console-only progress gauge. Not written to log.
        $pct = if ($deviceItems.Count -gt 0) {
            [int](($i / $deviceItems.Count) * 100)
        } else { 0 }
        Write-Progress -Activity $progressActivity `
            -Status ("{0}/{1}  {2}" -f $i, $deviceItems.Count, $devAlias) `
            -PercentComplete $pct

        # Early-abort: once we've seen one 401, all subsequent calls will 401 too.
        if ($abortChainOn401) {
            $chainResults.Add([pscustomobject]@{ device = $dev; asset_details = $null })
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string]$devAlias)) {
            Write-Log ("[{0}/{1}] device id={2} has no 'alias' — skipping (search key unavailable)" -f $i, $deviceItems.Count, $devId) "WARN"
            $chainFail++
            $chainResults.Add([pscustomobject]@{ device = $dev; asset_details = $null })
            continue
        }

        $aliasEnc   = [System.Uri]::EscapeDataString([string]$devAlias)
        $detailsUrl = "{0}/asset/details?search=device.alias:{1}" -f $apiBase, $aliasEnc
        try {
            $adSplat = Get-RequestSplat -Base @{
                Method      = "GET"
                Uri         = $detailsUrl
                Headers     = $ppHeaders
                ErrorAction = "Stop"
            }
            $adResponse = Invoke-RestMethod @adSplat

            $assetDetails = @()
            if ($adResponse.PSObject.Properties.Name -contains "data" -and $adResponse.data) {
                $assetDetails = @($adResponse.data)
            } elseif ($adResponse -is [System.Array]) {
                $assetDetails = $adResponse
            } else {
                $assetDetails = @($adResponse)
            }
            $chainOk++
            Write-Log ("[{0}/{1}] {2} -> {3} asset record(s)" -f $i, $deviceItems.Count, $devAlias, $assetDetails.Count) "INFO"
            $chainResults.Add([pscustomobject]@{ device = $dev; asset_details = $assetDetails })
        }
        catch {
            $chainFail++

            $statusCode = $null
            try {
                if ($_.Exception.PSObject.Properties.Name -contains "Response" -and $_.Exception.Response) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }
            } catch { }

            $body = $null
            try {
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                    $body = [string]$_.ErrorDetails.Message
                } elseif ($_.Exception.Response -and $_.Exception.Response.PSObject.Methods.Name -contains "GetResponseStream") {
                    $stream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body   = $reader.ReadToEnd()
                }
            } catch { }

            Write-Log ("[{0}/{1}] {2} asset/details failed: {3}" -f $i, $deviceItems.Count, $devAlias, $_.Exception.Message) "WARN"
            if ($body) { Write-Log ("    response body: {0}" -f $body) "WARN" }

            $chainResults.Add([pscustomobject]@{ device = $dev; asset_details = $null })

            if ($statusCode -eq 401 -or $statusCode -eq 403) {
                $remaining = $deviceItems.Count - $i
                Write-Log ("First {0} hit. Aborting remaining {1} call(s) — same auth context will produce identical failures. Likely missing role 'Get Asset Details'." -f $statusCode, $remaining) "ERROR"
                $abortChainOn401 = $true
            }
        }
    }
    }
    finally {
        Write-Progress -Activity $progressActivity -Completed
    }
    }

    Write-Log ("Chain complete: ok={0} failed={1} total={2}" -f $chainOk, $chainFail, $deviceItems.Count) "INFO"

    Write-LogSection "OUTPUT"

    # Save aggregated JSON — REDACTED (secrets/PII masked) before writing to disk.
    $chainJson = Join-Path $OutputFolder ("AssetSoftware_{0}.json" -f $script:RunStamp)
    try {
        $redactedResults = New-Object System.Collections.Generic.List[object]
        foreach ($entry in $chainResults) {
            try { $redactedResults.Add((& $redact $entry)) }
            catch {
                Write-Log "Redaction failed for one record; substituting placeholder. $($_.Exception.Message)" "WARN"
                $redactedResults.Add([pscustomobject]@{ device = (& $redact $entry.device); asset_details = "<redaction-error>" })
            }
        }
        $redactedResults | ConvertTo-Json -Depth 50 | Out-File -LiteralPath $chainJson -Encoding UTF8
        Write-Log "Chain JSON saved (redacted): $chainJson" "SUCCESS"
    } catch {
        Write-Log "Failed to write chain JSON: $($_.Exception.Message)" "ERROR"
    }

    # CSV — device identity + resolved software columns + discovery diagnostic.
    # The empty-asset row and the populated row MUST share identical [ordered]
    # keys/order: Export-Csv derives headers from the first object only.
    $csvRows = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $chainResults) {
        $dev = $entry.device
        $ads = @($entry.asset_details)

        if ($ads.Count -eq 0) {
            $csvRows.Add([pscustomobject][ordered]@{
                DeviceID         = $dev.id
                DeviceName       = $dev.name
                DeviceAlias      = $dev.alias
                PowerplantID     = $dev.powerplant_id
                Mac_Address      = $dev.mac_address
                Ip_address       = $dev.ip_address
                Manufacturer     = $dev.manufacturer
                Model            = $dev.model
                OS               = $null
                OS_Version       = $null
                Firmware_Version = $null
                Software_Image   = $null
                SerialNumber     = $null
                AssetStatus      = $null
                LastSeen         = $null
                AssetFieldsSeen  = $null
            })
            continue
        }

        foreach ($a in $ads) {
            $csvRows.Add([pscustomobject][ordered]@{
                DeviceID         = $dev.id
                DeviceName       = $dev.name
                DeviceAlias      = $dev.alias
                PowerplantID     = $dev.powerplant_id
                Mac_Address      = $dev.mac_address
                Ip_address       = $dev.ip_address
                Manufacturer     = $dev.manufacturer
                Model            = $dev.model
                OS               = (& $resolveField $a $cOS)
                OS_Version       = (& $resolveField $a $cOSVer)
                Firmware_Version = (& $resolveField $a $cFirmware)
                Software_Image   = (& $resolveField $a $cImage)
                SerialNumber     = (& $resolveField $a $cSerial)
                AssetStatus      = (& $resolveField $a $cStatus)
                LastSeen         = (& $resolveField $a $cLastSeen)
                AssetFieldsSeen  = (& $fieldsSeen $a)
            })
        }
    }

    if ($csvRows.Count -gt 0) {
        $csvFile = Join-Path $OutputFolder ("AssetSoftware_{0}.csv" -f $script:RunStamp)
        $csvRows | Export-Csv -LiteralPath $csvFile -NoTypeInformation -Encoding UTF8
        Write-Log ("CSV written: {0} ({1} row(s))" -f $csvFile, $csvRows.Count) "SUCCESS"
    } else {
        Write-Log "No rows to write — CSV not created." "WARN"
    }

    $script:ChainHandled = $true
}

#endregion

#region ---------- Export devices to CSV -------------------------------------

# Two response shapes are supported:
#   A) /powerplants?...with=unknownDevice  -> array of powerplants, each with unknown_device[]
#      -> CSV: UnknownDevices_<stamp>.csv  (PowerplantID, Name, Mac_Address, Ip_address, ARP_hostname)
#   B) /devices?...                        -> array of device records directly
#      -> CSV: Devices_<stamp>.csv         (full device fields)
# Detection is by inspecting the first item's properties.

try {
    if ($script:ChainHandled) {
        Write-Log "Chain handled output — skipping default device CSV export." "DEBUG"
    }
    else {

    Write-LogSection "OUTPUT"

    # Normalize response into an array regardless of wrapping.
    $items = @()
    if ($ppResponse.PSObject.Properties.Name -contains "data" -and $ppResponse.data) {
        $items = @($ppResponse.data)
    } elseif ($ppResponse -is [System.Array]) {
        $items = $ppResponse
    } else {
        $items = @($ppResponse)
    }

    $csvRows = New-Object System.Collections.Generic.List[object]
    $csvKind = $null

    if ($items.Count -gt 0) {
        $first = $items[0]
        $names = @($first.PSObject.Properties.Name)
        $hasUnknownDevice = $names -contains "unknown_device"
        $looksLikeDevice  = ($names -contains "mac_address") -or ($names -contains "ip_address")

        if ($hasUnknownDevice) {
            $csvKind = "UnknownDevices"
            foreach ($pp in $items) {
                $ppId = $pp.id
                $devices = @()
                if ($pp.unknown_device) { $devices = @($pp.unknown_device) }

                if ($devices.Count -eq 0) {
                    Write-Log ("Powerplant id={0} has no unknown_device entries." -f $ppId) "INFO"
                    continue
                }

                foreach ($dev in $devices) {
                    $row = [ordered]@{
                        PowerplantID = $dev.powerplant_id
                        Name         = $dev.name
                        Mac_Address  = $dev.mac_address
                        Ip_address   = $dev.ip_address
                        ARP_hostname = $dev.arp_hostname
                    }
                    if ([string]::IsNullOrWhiteSpace([string]$row.PowerplantID)) {
                        $row.PowerplantID = $ppId
                    }
                    $csvRows.Add([pscustomobject]$row)
                }
            }
        }
        elseif ($looksLikeDevice) {
            $csvKind = "Devices"
            foreach ($dev in $items) {
                $row = [ordered]@{
                    PowerplantID  = $dev.powerplant_id
                    ID            = $dev.id
                    Name          = $dev.name
                    Alias         = $dev.alias
                    DeviceType    = $dev.device_type
                    Manufacturer  = $dev.manufacturer
                    Model         = $dev.model
                    Mac_Address   = $dev.mac_address
                    Ip_address    = $dev.ip_address
                    ParentDevice  = $dev.parent_device
                    Loopback      = $dev.loopback
                    VpnIp         = $dev.vpn_ip
                    Category      = $dev.category
                    Monitored     = $dev.monitored
                    UpdatedAt     = $dev.updated_at
                }
                $csvRows.Add([pscustomobject]$row)
            }
        }
        else {
            Write-Log "Response items have neither 'unknown_device' nor device fields (mac_address/ip_address) — skipping CSV." "WARN"
        }
    }

    if ($csvKind -and $csvRows.Count -gt 0) {
        $csvFile = Join-Path $OutputFolder ("{0}_{1}.csv" -f $csvKind, $script:RunStamp)
        $csvRows | Export-Csv -LiteralPath $csvFile -NoTypeInformation -Encoding UTF8
        Write-Log ("CSV written: {0} ({1} row(s))" -f $csvFile, $csvRows.Count) "SUCCESS"
    }
    elseif ($csvKind) {
        Write-Log "No rows to write — CSV not created." "WARN"
    }
    }
}
catch {
    Write-Log "Failed to build/write CSV: $($_.Exception.Message)" "ERROR"
    # Non-fatal: the JSON output is already saved, so we don't change the exit code.
}

#endregion

Write-LogSection "END"