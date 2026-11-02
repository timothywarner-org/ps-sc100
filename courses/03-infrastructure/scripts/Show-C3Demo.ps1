#Requires -Version 7.0

<#
.SYNOPSIS
Shows the Module 2, 3 or 4 demo review one screen at a time, the way it appears in the course.

.DESCRIPTION
In the videos I page through each module's review a screen at a time. This script does the same
thing with your lab: it runs that module's read-only review script once, splits the output on the
review's own section headers, and shows one screen per Enter press.

Every screen opens with the time Azure was read, in UTC. That stamp is there on purpose: a saved
or screenshotted screen can never be mistaken for a fresh read of your configuration.

Nothing in Azure or Microsoft Entra changes. The review scripts only read.

Module 1 has no script screens; its demo uses the attack path graph in the Microsoft Defender
portal. See m01-attack-path\README.md.

.PARAMETER Module
2, 3 or 4.

.PARAMETER NoPaging
Print every screen at once, without clearing the terminal or waiting for Enter. Handy when you
want to scroll back or pipe the output to a file.

.EXAMPLE
pwsh -NoProfile -File .\Show-C3Demo.ps1 -Module 3
Reads the Module 3 Foundry lab and shows the RESOURCE, MODEL DEPLOYMENT and WORKLOAD PERMISSIONS
screens one at a time.

.EXAMPLE
pwsh -NoProfile -File .\Show-C3Demo.ps1 -Module 4 -NoPaging
Prints all three Module 4 Private Access screens in one go.

.NOTES
Prerequisites: PowerShell 7, the Azure CLI signed in with az login, and that module's lab deployed
with its Deploy script. Each module folder's README lists the extra prerequisites for its review.
Keep the folder layout from the download, because this script finds each review by its path.

Cost: none beyond the lab you've already deployed. If the lab's VMs are stopped, run
.\Start-C3Lab.ps1 first.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet(2, 3, 4)]
    [int]$Module,

    [switch]$NoPaging
)

$ErrorActionPreference = 'Stop'

# Each review prints its screens under fixed headers. Splitting on those headers is what turns one
# Azure read into separate screens, so the patterns must match the review scripts exactly.
# Module 2's plan table is a single screen, so it has no pattern.
$config = @{
    2 = @{ Script = 'm02-server-coverage/Show-C3M02ServerPlans.ps1'; Pattern = $null; Screens = 1 }
    3 = @{ Script = 'm03-foundry-review/Show-C3M03FoundryReview.ps1'
           Pattern = '(?m)^(?=RESOURCE  |MODEL DEPLOYMENT  |WORKLOAD PERMISSIONS\s*$)'; Screens = 3 }
    4 = @{ Script = 'm04-private-access/Show-C3M04PrivateAccess.ps1'
           Pattern = '(?m)^(?=WHO MAY CONNECT\s*$|WHERE THE CONNECTION LANDS\s*$|WHAT ELSE REACHES THE PLANT)'; Screens = 3 }
}[$Module]

$review = Join-Path $PSScriptRoot $config.Script
if (-not (Test-Path -LiteralPath $review)) {
    throw "Can't find $($config.Script) next to this script. Keep the folder layout from the download."
}

Write-Host "Reading the Module $Module lab from Azure. This takes a few seconds."
# 6>&1 folds the review's Write-Host output (the information stream) into what we capture, so the
# whole review can be split into screens before anything is shown.
$captured = & $review 6>&1
$text = ($captured | ForEach-Object { $_.ToString() }) -join "`n"
$readAt = [DateTimeOffset]::UtcNow

# A typed array keeps a single screen as one element; PowerShell would otherwise unwrap it.
[string[]]$screens = if ($config.Pattern) {
    @([regex]::Split($text, $config.Pattern) | Select-Object -Skip 1)
} else {
    @($text)
}

# If your lab is partial, a review may print warnings instead of a header. Rather than stop, show
# everything it printed as one screen so you can see what's missing.
if ($screens.Count -ne $config.Screens -or @($screens | Where-Object { -not $_.Trim() }).Count) {
    Write-Warning "The review didn't print the usual $($config.Screens) screen(s); showing its full output instead."
    [string[]]$screens = @($text)
}

for ($i = 0; $i -lt $screens.Count; $i++) {
    if (-not $NoPaging) { Clear-Host }
    Write-Host "Globomantics | C3 M$Module | Azure configuration read $($readAt.ToString('yyyy-MM-dd HH:mm')) UTC"
    Write-Host ''
    Write-Host $screens[$i].Trim()
    if (-not $NoPaging -and $i -lt ($screens.Count - 1)) {
        $null = Read-Host 'Enter: next screen'
    }
}
