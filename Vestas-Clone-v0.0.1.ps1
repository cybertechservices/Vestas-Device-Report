<#
.SYNOPSIS
    Clone v0.1.0 — clones (or updates) the 3 Vestas GitHub repos onto
    a target machine using PAT-only auth. All GitHub interactions go
    through the REST API or git HTTPS with the supplied PAT. No gh CLI
    dependency.

.PARAMETER PatFile
    Path to a file containing the PAT (token text only, whitespace
    trimmed). MANDATORY.

.PARAMETER Destination
    Parent directory under which each repo will be cloned as a
    subfolder. Default: 'C:\Jobs\Scripts'.

.PARAMETER UseOriginalNames
    If set, clones into folders matching the ORIGINAL local layout
    on the source machine (Device-Report, DailyChecks,
    get-installed-Software) instead of the canonical repo names
    (Vestas-Device-Report, etc.).

.PARAMETER WhatIfMode
    Dry run. All API calls happen for real; clone/fetch/pull skipped.

.PARAMETER Force
    Skip the interactive YES prompt.

.NOTES
    Version  : 0.1.0
    Date     : 2026-06-05

    Pre-reqs : git on PATH; PAT with at least Contents: Read on the
               three repos.

    Backup   : This script never deletes or overwrites local files.
               If a target folder exists and is NOT a git checkout of
               the expected remote, it is skipped with a clear error.

    Rollback : Newly cloned folders can be deleted manually. Updated
               folders: if a `git pull --ff-only` succeeded, the
               reflog under .git/logs lets you reset to the previous
               HEAD (git reset --hard ORIG_HEAD).

    PAT handling:
      - PAT is NOT written to .git/config.
      - PAT is NOT embedded in the remote URL.
      - PAT IS briefly present in the git process command line during
        clone/fetch/pull (same as push v0.2.0/v0.3.0).
      - After this script runs, the cloned repos have plain HTTPS
        remotes with no embedded credentials. Future `git pull` will
        need either a credential helper or PAT-injecting wrappers.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$PatFile,
    [string]$Destination = 'C:\Jobs\Scripts',
    [switch]$UseOriginalNames,
    [switch]$WhatIfMode,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# === CONFIG ===
$user = 'cybertechservices'
$projects = [ordered]@{
    'Device-Report'          = 'Vestas-Device-Report'
    'DailyChecks'            = 'Vestas-DailyChecks'
    'get-installed-Software' = 'Vestas-get-installed-Software'
}

# === Logging ===
$logDir = 'C:\Temp\Vestas-Clone-Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDir "clone-$stamp.log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'o'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
    Add-Content -Path $logFile -Value $line
}

function Invoke-GhApi {
    param([string]$Path, [hashtable]$Headers, [string]$Method = 'GET')
    $uri = "https://api.github.com/$Path"
    try {
        $r = Invoke-WebRequest -Uri $uri -Method $Method -Headers $Headers `
            -UseBasicParsing -ErrorAction Stop
        $json = $null
        if ($r.Content) { try { $json = $r.Content | ConvertFrom-Json } catch { } }
        return [pscustomobject]@{ Ok=$true; Status=[int]$r.StatusCode; Json=$json; Error=$null }
    } catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        return [pscustomobject]@{ Ok=$false; Status=$status; Json=$null; Error=$_.Exception.Message }
    }
}

Write-Log '=== Vestas clone v0.1.0 started ==='
Write-Log ("Destination={0} ; UseOriginalNames={1} ; WhatIfMode={2} ; Force={3}" -f `
    $Destination, $UseOriginalNames.IsPresent, $WhatIfMode.IsPresent, $Force.IsPresent)
Write-Log "Log file: $logFile"

# === 0. git availability ===
try { $gitVersion = (git --version) 2>&1 | Out-String } catch { Write-Log 'git not found on PATH' 'ERROR'; throw }
Write-Log ('git: ' + $gitVersion.Trim())

# === 1. Load PAT ===
if (-not (Test-Path -LiteralPath $PatFile -PathType Leaf)) {
    throw "PAT file not found: $PatFile"
}
$patRaw = Get-Content -LiteralPath $PatFile -Raw -ErrorAction Stop
$pat    = $patRaw.Trim()
if ([string]::IsNullOrWhiteSpace($pat)) { throw "PAT file is empty: $PatFile" }
Write-Log ("PAT loaded from {0} (length={1})" -f $PatFile, $pat.Length)

$bytes      = [System.Text.Encoding]::UTF8.GetBytes("x-access-token:$pat")
$b64        = [Convert]::ToBase64String($bytes)
$basicHdr   = "AUTHORIZATION: basic $b64"
$bearerHdr  = "Bearer $pat"
$apiHeaders = @{
    Authorization          = $bearerHdr
    Accept                 = 'application/vnd.github+json'
    'User-Agent'           = 'Vestas-Clone/0.1.0'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$patAuthArgs = @('-c', 'credential.helper=', '-c', "http.extraheader=$basicHdr")

# === 2. PAT identity ===
$me = Invoke-GhApi -Path 'user' -Headers $apiHeaders
if (-not $me.Ok) { throw "GET /user failed (HTTP $($me.Status)): $($me.Error)" }
Write-Log ("Authenticated as: {0} (id={1})" -f $me.Json.login, $me.Json.id)

# === 3. Destination directory ===
if (-not (Test-Path $Destination)) {
    if ($WhatIfMode) {
        Write-Log "[WhatIf] Would create destination: $Destination"
    } else {
        Write-Log "Creating destination: $Destination"
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
} else {
    Write-Log "Destination exists: $Destination"
}

# === 4. Pre-flight: each repo via REST ===
Write-Log 'Pre-flight: verifying remote repos via REST'
$plan = [ordered]@{}
foreach ($local in $projects.Keys) {
    $repoName  = $projects[$local]
    $full      = "$user/$repoName"
    $folderName = if ($UseOriginalNames) { $local } else { $repoName }
    $targetDir = Join-Path $Destination $folderName
    $expectedRemote = "https://github.com/$user/$repoName.git"

    $r = Invoke-GhApi -Path "repos/$full" -Headers $apiHeaders
    if (-not $r.Ok) {
        Write-Log ("  {0} -> HTTP {1}: {2}" -f $full, $r.Status, $r.Error) 'ERROR'
        $plan[$full] = [pscustomobject]@{
            Repo = $full; Local = $local; Folder = $folderName
            TargetDir = $targetDir; Remote = $expectedRemote
            Action = 'SKIP'; Reason = "API HTTP $($r.Status)"
        }
        continue
    }
    $info = $r.Json
    if ($info.archived) {
        Write-Log ("  {0} is archived - will skip" -f $full) 'WARN'
        $plan[$full] = [pscustomobject]@{
            Repo = $full; Local = $local; Folder = $folderName
            TargetDir = $targetDir; Remote = $expectedRemote
            Action = 'SKIP'; Reason = 'ARCHIVED'
        }
        continue
    }

    # Decide action: CLONE / UPDATE / CONFLICT
    $action = $null
    $reason = ''
    if (-not (Test-Path -LiteralPath $targetDir)) {
        $action = 'CLONE'
    } else {
        $gitDir = Join-Path $targetDir '.git'
        if (-not (Test-Path -LiteralPath $gitDir)) {
            $action = 'SKIP'
            $reason = 'TARGET_EXISTS_BUT_NOT_A_REPO'
        } else {
            # Read existing remote URL
            Push-Location $targetDir
            try {
                $existingRemote = (& git remote get-url origin) 2>$null
            } finally { Pop-Location }
            if ($LASTEXITCODE -ne 0 -or -not $existingRemote) {
                $action = 'SKIP'
                $reason = 'NO_ORIGIN_REMOTE'
            } elseif (($existingRemote.Trim().TrimEnd('/')) -ine ($expectedRemote.Trim().TrimEnd('/')) -and `
                      ($existingRemote.Trim().TrimEnd('/')) -ine ($expectedRemote.Replace('.git','').Trim().TrimEnd('/'))) {
                $action = 'SKIP'
                $reason = "REMOTE_MISMATCH (origin=$existingRemote)"
            } else {
                $action = 'UPDATE'
            }
        }
    }

    Write-Log ("  {0} -> {1} ({2}) [{3}{4}]" -f $full, $targetDir, $expectedRemote, $action, `
        $(if ($reason) { " : $reason" } else { '' }))

    $plan[$full] = [pscustomobject]@{
        Repo = $full; Local = $local; Folder = $folderName
        TargetDir = $targetDir; Remote = $expectedRemote
        Action = $action; Reason = $reason
    }
}

# === 5. Confirmation ===
if (-not $Force -and -not $WhatIfMode) {
    Write-Host ''
    Write-Host 'Plan:' -ForegroundColor Yellow
    foreach ($p in $plan.Values) {
        $color = switch ($p.Action) {
            'CLONE'  { 'Green' }
            'UPDATE' { 'Cyan' }
            'SKIP'   { 'DarkGray' }
        }
        $line = '  [{0,-6}] {1,-55} -> {2}' -f $p.Action, $p.Repo, $p.TargetDir
        if ($p.Reason) { $line += '  ({0})' -f $p.Reason }
        Write-Host $line -ForegroundColor $color
    }
    Write-Host ''
    Write-Host 'Existing files in non-git folders will NOT be touched.' -ForegroundColor Green
    Write-Host ''
    $confirm = Read-Host "Type 'YES' to proceed"
    if ($confirm -ne 'YES') {
        Write-Log 'User aborted at confirmation prompt.' 'WARN'
        return
    }
}

# === 6. Per-repo execution ===
$results = New-Object System.Collections.Generic.List[object]
foreach ($p in $plan.Values) {
    Write-Log "--- $($p.Repo) : action=$($p.Action) ---"

    if ($p.Action -eq 'SKIP') {
        Write-Log ("  Skipping ({0})" -f $p.Reason) 'WARN'
        $results.Add([pscustomobject]@{ Repo=$p.Repo; Status='SKIPPED'; Reason=$p.Reason })
        continue
    }

    try {
        if ($p.Action -eq 'CLONE') {
            if ($WhatIfMode) {
                Write-Log "  [WhatIf] git clone $($p.Remote) $($p.TargetDir)"
            } else {
                Write-Log ("  git clone {0} {1} (with PAT auth - header redacted)" -f $p.Remote, $p.TargetDir)
                $cloneArgs = @() + $patAuthArgs + @('clone', $p.Remote, $p.TargetDir)
                & git @cloneArgs 2>&1 | ForEach-Object { Write-Log "    git: $_" }
                if ($LASTEXITCODE -ne 0) {
                    throw "git clone failed (exit $LASTEXITCODE)"
                }
            }
            $results.Add([pscustomobject]@{ Repo=$p.Repo; Status='CLONED'; Reason='' })
        }
        elseif ($p.Action -eq 'UPDATE') {
            if ($WhatIfMode) {
                Write-Log "  [WhatIf] git fetch ; git pull --ff-only  (in $($p.TargetDir))"
            } else {
                Push-Location $p.TargetDir
                try {
                    Write-Log "  git fetch (with PAT auth - header redacted)"
                    $fetchArgs = @() + $patAuthArgs + @('fetch', '--prune', 'origin')
                    & git @fetchArgs 2>&1 | ForEach-Object { Write-Log "    git: $_" }
                    if ($LASTEXITCODE -ne 0) { throw "git fetch failed (exit $LASTEXITCODE)" }

                    # Check for local modifications before pull
                    $status = (& git status --porcelain) 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "git status failed" }
                    if ($status) {
                        Write-Log "  Local working tree has changes - skipping pull to avoid clobbering:" 'WARN'
                        $status -split "`r?`n" | ForEach-Object { if ($_) { Write-Log "    $_" 'WARN' } }
                        throw "Local working tree dirty; resolve manually then re-run."
                    }

                    Write-Log "  git pull --ff-only (with PAT auth - header redacted)"
                    $pullArgs = @() + $patAuthArgs + @('pull', '--ff-only')
                    & git @pullArgs 2>&1 | ForEach-Object { Write-Log "    git: $_" }
                    if ($LASTEXITCODE -ne 0) {
                        throw "git pull --ff-only failed (exit $LASTEXITCODE) - branch may have diverged"
                    }
                } finally { Pop-Location }
            }
            $results.Add([pscustomobject]@{ Repo=$p.Repo; Status='UPDATED'; Reason='' })
        }

        Write-Log "  SUCCESS"
    }
    catch {
        Write-Log ("  FAILED: {0}" -f $_.Exception.Message) 'ERROR'
        $results.Add([pscustomobject]@{ Repo=$p.Repo; Status='FAILED'; Reason=$_.Exception.Message })
    }
}

# === 7. Final verification ===
if (-not $WhatIfMode) {
    Write-Log 'Final verification'
    foreach ($p in $plan.Values) {
        if (-not (Test-Path -LiteralPath (Join-Path $p.TargetDir '.git'))) { continue }
        Push-Location $p.TargetDir
        try {
            $branch = (& git rev-parse --abbrev-ref HEAD) 2>$null
            $sha    = (& git rev-parse --short HEAD) 2>$null
            $count  = (& git rev-list --count HEAD) 2>$null
            Write-Log ("  {0} -> branch={1} HEAD={2} commits={3}" -f $p.Repo, $branch, $sha, $count)
        } finally { Pop-Location }
    }
}

# === 8. Summary ===
Write-Log '=== Summary ==='
foreach ($r in $results) {
    $level = if ($r.Status -eq 'FAILED') { 'ERROR' }
             elseif ($r.Status -eq 'SKIPPED') { 'WARN' }
             else { 'INFO' }
    Write-Log ('  {0,-55}  {1,-8}  {2}' -f $r.Repo, $r.Status, $r.Reason) $level
}
Write-Log '=== Clone v0.1.0 complete ==='
Write-Log "Log file: $logFile"

Write-Host ''
Write-Host 'Local paths:' -ForegroundColor Cyan
foreach ($p in $plan.Values) {
    $color = switch (($results | Where-Object { $_.Repo -eq $p.Repo }).Status) {
        'CLONED'  { 'Green' }
        'UPDATED' { 'Cyan' }
        'FAILED'  { 'Red' }
        default   { 'Yellow' }
    }
    Write-Host ('  {0}' -f $p.TargetDir) -ForegroundColor $color
}

# Best-effort scrub
$pat = $null; $patRaw = $null
$bytes = $null; $b64 = $null
$basicHdr = $null; $bearerHdr = $null
$apiHeaders = $null; $patAuthArgs = $null