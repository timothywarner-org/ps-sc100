<#
.SYNOPSIS
    Downloads Microsoft Learn's free SC-100 training (course SC-100T00) into .\corpus\
    for your personal study.

.DESCRIPTION
    The SC-100 training content belongs to Microsoft, changes whenever Microsoft revises
    the learning paths, and weighs in around 17 MB. This toolkit therefore never ships
    it: you download your own copy, it stays on your machine, and the toolkit's
    .gitignore keeps it out of any commit.

    This script drives the microsoft-courses-downloader tool
    (https://github.com/timothywarner-org/microsoft-courses-downloader), which calls the
    Microsoft Learn Catalog API, resolves course SC-100T00 to its four learning paths,
    fetches every module and unit concurrently, localizes the referenced images, and
    writes one Markdown file per module plus a combined _full.md per learning path.
    Every unit keeps a "Source:" line with its Learn URL, which is what makes every
    passage in your knowledge base citable.

    The first run clones the downloader into .cache\ inside this toolkit and gives it
    its own virtual environment. Re-running refreshes the corpus in place.

.PARAMETER DownloaderPath
    Where the downloader clone lives. Defaults to .cache\microsoft-courses-downloader
    inside this toolkit, resolved from the script's own location, so your working
    directory does not matter. Cloned automatically when missing.

.PARAMETER Branch
    The downloader branch to clone. The Markdown output this toolkit reads lives on
    this branch; the default is the one the toolkit was tested against.

.PARAMETER OutputPath
    Destination for the corpus. Defaults to the corpus\ folder of this toolkit.

.PARAMETER Concurrency
    Simultaneous in-flight HTTP requests. Microsoft Learn rate-limits aggressively;
    16 is comfortable from a single workstation. Lower it if you see HTTP 429 errors.

.EXAMPLE
    ./scripts/Get-SC100Corpus.ps1

    Clones the downloader on first run, then downloads the corpus into corpus\.

.EXAMPLE
    ./scripts/Get-SC100Corpus.ps1 -Concurrency 8 -WhatIf

    Shows what would happen, with reduced concurrency, without downloading anything.

.NOTES
    Author : Tim Warner
    Requires: PowerShell 5.1 or 7.x, Python 3.10+, and git (for the first-run clone).

    The corpus is Microsoft's copyrighted training content. Download it for your own
    study; do not commit it, publish it, or share the folder.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DownloaderPath = (Join-Path (Split-Path $PSScriptRoot -Parent) '.cache/microsoft-courses-downloader'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Branch = 'tim/local-customisations',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'corpus'),

    [Parameter()]
    [ValidateRange(1, 32)]
    [int]$Concurrency = 16
)

# Fail fast. A partially downloaded corpus is worse than no corpus, because it looks
# complete and silently under-reports coverage.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$CourseUrl = 'https://learn.microsoft.com/en-us/training/courses/sc-100t00'
$RepoUrl   = 'https://github.com/timothywarner-org/microsoft-courses-downloader.git'

function Write-Step {
    <#
        Progress reads consistently, and every status carries a WORD label. Color is
        never the only signal: a reader who cannot tell red from green, or a log file
        with no color at all, still knows what happened.
    #>
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[ STEP ] $Message"
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[  OK  ] $Message"
}

function Get-VenvPython {
    <#
        Returns the virtual environment's interpreter, or $null. Windows puts it under
        Scripts\, macOS and Linux under bin/. Testing both paths avoids $IsWindows,
        which does not exist on Windows PowerShell 5.1 and would throw under StrictMode.
    #>
    param([Parameter(Mandatory)][string]$Root)
    foreach ($candidate in @((Join-Path $Root '.venv/Scripts/python.exe'), (Join-Path $Root '.venv/bin/python'))) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

# --- 1. Locate or clone the downloader ------------------------------------
if (-not (Test-Path -LiteralPath $DownloaderPath)) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git is required for the first-run clone. Install git, or clone the downloader yourself and pass -DownloaderPath.'
    }
    Write-Step "Cloning the downloader ($Branch) into $DownloaderPath"
    if ($PSCmdlet.ShouldProcess($DownloaderPath, 'git clone')) {
        git clone --depth 1 --branch $Branch $RepoUrl $DownloaderPath
        if ($LASTEXITCODE -ne 0) { throw "git clone failed with exit code $LASTEXITCODE." }
    }
}
Write-Ok "Downloader: $DownloaderPath"

# --- 2. Give the downloader its own virtual environment -------------------
# Its dependencies (httpx, beautifulsoup4, markdownify, requests) stay inside its own
# .venv, so they never collide with the toolkit's environment or your system Python.
$python = $null
if (Test-Path -LiteralPath $DownloaderPath) {
    $python = Get-VenvPython -Root $DownloaderPath
}
if (-not $python) {
    # Deliberately not using the null-conditional operator (?.) here: it is PowerShell
    # 7+ only, and this script is documented as 5.1-compatible.
    $basePython = $null
    foreach ($name in 'python3', 'python') {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { $basePython = $cmd.Source; break }
    }
    if (-not $basePython) { throw 'No Python interpreter found. Install Python 3.10 or later.' }

    Write-Step "Creating the downloader's virtual environment with $basePython"
    if ($PSCmdlet.ShouldProcess($DownloaderPath, 'create .venv and install requirements')) {
        & $basePython -m venv (Join-Path $DownloaderPath '.venv')
        if ($LASTEXITCODE -ne 0) { throw "python -m venv failed with exit code $LASTEXITCODE." }
        $python = Get-VenvPython -Root $DownloaderPath
        & $python -m pip install --quiet --requirement (Join-Path $DownloaderPath 'requirements.txt')
        if ($LASTEXITCODE -ne 0) { throw "pip install failed with exit code $LASTEXITCODE." }
    }
}
if ($python) { Write-Ok "Python: $python" }

# --- 3. Fetch -------------------------------------------------------------
if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Windows consoles default to a legacy code page that cannot encode the downloader's
# progress glyphs. Setting these keeps redirected output clean as well.
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8       = '1'

Write-Step "Fetching SC-100T00 into $OutputPath (concurrency $Concurrency)"
if ($PSCmdlet.ShouldProcess($CourseUrl, 'download course')) {
    Push-Location $DownloaderPath
    try {
        & $python 'main.py' $CourseUrl --output $OutputPath --concurrency $Concurrency
        if ($LASTEXITCODE -ne 0) { throw "Downloader exited with code $LASTEXITCODE." }
    }
    finally {
        Pop-Location
    }
}

# --- 4. Verify ------------------------------------------------------------
# Nothing was downloaded under -WhatIf, so there is nothing to verify. Without this
# guard the verification block throws on a dry run, which makes -WhatIf look like a
# failure rather than a preview.
if ($WhatIfPreference) {
    Write-Host '[ STEP ] -WhatIf specified; download skipped, so verification is skipped too.'
    return
}

# Assert the shape of what landed rather than trusting the exit code. SC-100T00 ships as
# four learning paths; anything else means Microsoft restructured the course.
$corpusRoot = Join-Path $OutputPath 'Microsoft Cybersecurity Architect'
if (-not (Test-Path -LiteralPath $corpusRoot)) {
    throw "Expected corpus root not found: $corpusRoot"
}

$paths   = @(Get-ChildItem -LiteralPath $corpusRoot -Directory)
$modules = @(Get-ChildItem -LiteralPath $corpusRoot -Recurse -Filter '*.md' |
             Where-Object { $_.Name -ne '_full.md' })
$units   = ($modules | ForEach-Object {
                ([regex]::Matches((Get-Content -LiteralPath $_.FullName -Raw), '(?m)^## \d+\.\s')).Count
            } | Measure-Object -Sum).Sum

Write-Host ''
Write-Host '--- corpus summary ---'
Write-Host ("Learning paths : {0}" -f $paths.Count)
Write-Host ("Modules        : {0}" -f $modules.Count)
Write-Host ("Units          : {0}" -f $units)
Write-Host ("Size           : {0:N1} MB" -f ((Get-ChildItem -LiteralPath $corpusRoot -Recurse -File |
                                              Measure-Object Length -Sum).Sum / 1MB))

if ($paths.Count -ne 4) {
    Write-Host "[ WARN ] Expected 4 learning paths, found $($paths.Count). Microsoft may have restructured SC-100T00; check the exam study guide before you rely on coverage numbers."
}
else {
    Write-Ok 'Corpus shape matches the four SC-100T00 learning paths.'
}

Write-Host ''
Write-Host 'Next: python tools/chunk_learn.py'
