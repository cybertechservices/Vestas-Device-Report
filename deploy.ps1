<#
.SYNOPSIS
    Bootstrap the Vestas Device Report tool on a fresh Windows machine.

.DESCRIPTION
    Place this script and a *.pat file (GitHub Personal Access Token) in the
    same folder, then run it. It will:
      1. Install Git via winget if missing.
      2. Clone the repo (or pull if it already exists).
      3. Remove the PAT from the stored remote URL after use.

    The repo is cloned to a sub-folder next to this script by default.
    Override with -TargetPath.

.PARAMETER TargetPath
    Where to clone the repo. Default: .\Vestas-Device-Report (next to this script).

.EXAMPLE
    .\deploy.ps1

.EXAMPLE
    .\deploy.ps1 -TargetPath "C:\Tools\Vestas-Device-Report"
#>

[CmdletBinding()]
param(
    [string]$TargetPath = (Join-Path $PSScriptRoot "Vestas-Device-Report")
)

$repoOwner  = "cybertechservices"
$repoName   = "Vestas-Device-Report"
$repoUrl    = "https://github.com/$repoOwner/$repoName.git"

function Write-Step  { param($msg) Write-Host "[INFO]    $msg" -ForegroundColor Cyan    }
function Write-Ok    { param($msg) Write-Host "[SUCCESS] $msg" -ForegroundColor Green   }
function Write-Fail  { param($msg) Write-Host "[ERROR]   $msg" -ForegroundColor Red     }
function Write-Warn  { param($msg) Write-Host "[WARN]    $msg" -ForegroundColor Yellow  }

Write-Host ""
Write-Host "===== VESTAS DEVICE REPORT — DEPLOY =====" -ForegroundColor Cyan
Write-Host ""

# ---------- 1. Read the .pat file -----------------------------------------
$patFile = Get-ChildItem -Path $PSScriptRoot -Filter "*.pat" -File |
           Sort-Object LastWriteTime -Descending |
           Select-Object -First 1

if (-not $patFile) {
    Write-Fail "No *.pat file found in $PSScriptRoot."
    Write-Fail "Copy your GitHub Personal Access Token file here and re-run."
    exit 1
}

$pat = (Get-Content -LiteralPath $patFile.FullName -Raw).Trim()
# Support key=value format (e.g. GITHUB_PAT=ghp_xxxx) as well as raw token
if ($pat -match '^[A-Za-z_]+=(.+)$') { $pat = $Matches[1].Trim() }

if ([string]::IsNullOrWhiteSpace($pat)) {
    Write-Fail "PAT file is empty: $($patFile.FullName)"
    exit 1
}
Write-Ok "PAT loaded from: $($patFile.Name)"

# ---------- 2. Git: install Portable Git if missing (no admin required) ----
$portableGitDir = Join-Path $env:LOCALAPPDATA "Programs\PortableGit"
$portableGitExe = Join-Path $portableGitDir "cmd\git.exe"

$gitVer = $null
try { $gitVer = (& git --version 2>$null) } catch { }

if ([string]::IsNullOrWhiteSpace($gitVer)) {
    # Check if we already installed Portable Git in a previous run
    if (Test-Path -LiteralPath $portableGitExe) {
        $env:Path = "$portableGitDir\cmd;$env:Path"
        try { $gitVer = (& git --version 2>$null) } catch { }
    }
}

if ([string]::IsNullOrWhiteSpace($gitVer)) {
    Write-Step "Git not found — downloading Portable Git (no admin required)..."

    # Resolve the latest Portable Git release via the GitHub API
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -UseBasicParsing
    } catch {
        Write-Fail "Could not reach GitHub API to resolve Portable Git URL: $($_.Exception.Message)"
        exit 1
    }

    $asset = $release.assets |
             Where-Object { $_.name -match 'PortableGit-.*-64-bit\.7z\.exe$' } |
             Select-Object -First 1

    if (-not $asset) {
        Write-Fail "Could not find a PortableGit 64-bit asset in the latest release."
        exit 1
    }

    $tmpExe = Join-Path $env:TEMP "PortableGit-setup.exe"
    Write-Step "Downloading $($asset.name) ($([math]::Round($asset.size/1MB, 1)) MB)..."
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpExe -UseBasicParsing
    } catch {
        Write-Fail "Download failed: $($_.Exception.Message)"
        exit 1
    }

    Write-Step "Extracting to $portableGitDir ..."
    New-Item -ItemType Directory -Path $portableGitDir -Force | Out-Null
    & $tmpExe -o"$portableGitDir" -y | Out-Null
    Remove-Item -LiteralPath $tmpExe -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $portableGitExe)) {
        Write-Fail "Extraction finished but git.exe not found at $portableGitExe."
        exit 1
    }

    # Add to PATH for this session and persist for the user
    $env:Path = "$portableGitDir\cmd;$env:Path"
    $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike "*PortableGit*") {
        [System.Environment]::SetEnvironmentVariable('Path', "$portableGitDir\cmd;$userPath", 'User')
    }

    try { $gitVer = (& git --version 2>$null) } catch { }
    if ([string]::IsNullOrWhiteSpace($gitVer)) {
        Write-Fail "Portable Git extracted but still not usable — check $portableGitDir."
        exit 1
    }
    Write-Ok "Portable Git installed: $gitVer"
} else {
    Write-Ok "Git found: $gitVer"
}

# ---------- 3. Clone or pull -----------------------------------------------
$cloneUrl = "https://$pat@github.com/$repoOwner/$repoName.git"

if (Test-Path -LiteralPath (Join-Path $TargetPath ".git")) {
    Write-Step "Repo already exists at $TargetPath — pulling latest..."
    # Temporarily inject PAT into remote URL, pull, then restore clean URL
    & git -C $TargetPath remote set-url origin $cloneUrl
    & git -C $TargetPath pull --ff-only
    $pullExit = $LASTEXITCODE
    & git -C $TargetPath remote set-url origin $repoUrl   # always clean up PAT
    if ($pullExit -ne 0) {
        Write-Fail "git pull failed (exit $pullExit). Check the errors above."
        exit 1
    }
    Write-Ok "Repo updated."
} else {
    Write-Step "Cloning $repoUrl to $TargetPath ..."
    & git clone $cloneUrl $TargetPath
    $cloneExit = $LASTEXITCODE
    # Always remove PAT from stored remote URL, even if clone failed
    if (Test-Path -LiteralPath (Join-Path $TargetPath ".git")) {
        & git -C $TargetPath remote set-url origin $repoUrl
    }
    if ($cloneExit -ne 0) {
        Write-Fail "git clone failed (exit $cloneExit). Check the errors above."
        exit 1
    }
    Write-Ok "Repo cloned to $TargetPath"
}

# ---------- 4. Post-clone reminder -----------------------------------------
$envExample = Join-Path $TargetPath "conf\.env.example"
$envFile    = Join-Path $TargetPath "conf\.env"

Write-Host ""
Write-Host "===== NEXT STEPS =====" -ForegroundColor Cyan

if ((Test-Path $envExample) -and -not (Test-Path $envFile)) {
    Copy-Item -LiteralPath $envExample -Destination $envFile
    Write-Step "conf\.env created from example — open it and fill in your credentials:"
    Write-Step "  notepad `"$envFile`""
} elseif (Test-Path $envFile) {
    Write-Ok "conf\.env already exists."
} else {
    Write-Warn "conf\.env.example not found. Create conf\.env manually with WPP_USERNAME and WPP_PASSWORD."
}

Write-Host ""
Write-Ok "Done. Run the tool with:"
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$TargetPath\Device-Reports.ps1`"" -ForegroundColor White
Write-Host ""
