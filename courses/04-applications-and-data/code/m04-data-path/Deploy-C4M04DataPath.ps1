#Requires -Version 7.0

<#
.SYNOPSIS
Plans, deploys, reads, or removes the customer assistant's storage account lab for SC-100 Course 4, Module 4.

.DESCRIPTION
Builds the storage account behind the demo "Audit the customer assistant's data path" in your own
Azure subscription, and turns on Microsoft Defender for Storage for that one account. Then it reads
back the same settings the demo reads, so you can make a keep-or-change call on each one.
iac\main.bicep is the only template source and documents every property.

WHAT EACH MODE CHANGES
    Plan    Changes nothing. Compiles the template and runs what-if against the resource group.
    Deploy  Creates the resource group rg-globomantics-c4m04 (tagged course=SC100-C4M04) if it's
            missing, deploys the template, then turns on Defender for Storage for this account only,
            with on-upload malware scanning capped at -MalwareScanCapGB a month and sensitive data
            threat detection on. Safe to rerun: both steps converge.
    Show    Changes nothing. Two reads, the same two the demo runs:
              the account   Shared Key, minimum TLS, public blob access, public network access, and
                            infrastructure encryption
              Defender      enabled, malware scanning on upload, and sensitive data threat detection
            It never prints a key.
    Remove  Turns Defender for Storage off for the account, then deletes the resource group.

SAFETY RAILS, each one a mistake this script refuses to make
    * Wrong subscription or tenant    -> pass -SubscriptionId or -TenantId and it stops before any
                                         write when your Azure CLI context doesn't match.
    * Someone else's resource group   -> refuses unless the group carries the course tag.
    * Billing every storage account   -> Defender goes on at the ACCOUNT level, never the subscription,
                                         and Show warns you if your subscription's plan already covers
                                         every account.
    * Deleting the wrong group        -> Remove re-reads the tag immediately before deleting.

.PARAMETER Mode
Plan (the default), Deploy, Show, or Remove.

.PARAMETER SubscriptionId
Optional. The subscription to work in. Leave it out and the script uses your current Azure CLI
subscription (az account show). Supply it and every call is pinned to it.

.PARAMETER TenantId
Optional. The Microsoft Entra tenant you expect to be working in. Supply it and the script refuses to
continue when the subscription belongs to a different tenant.

.PARAMETER Location
Region for a new resource group. Defaults to eastus2. When the group already exists, the script uses
the group's region instead.

.PARAMETER MalwareScanCapGB
Monthly malware-scanning cap for the account, in GB. Default 10. The account holds no data, so it never
scans anything unless you upload files.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C4M04DataPath.ps1 -Mode Plan
Compiles the template and shows what a deployment would change. Changes nothing.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C4M04DataPath.ps1 -Mode Deploy
Deploys the account and turns on Defender for Storage for it alone.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C4M04DataPath.ps1 -Mode Show
Reads the five account settings and the Defender for Storage settings.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C4M04DataPath.ps1 -Mode Remove
Turns Defender off for the account and deletes the lab. Run this when you're done.

.NOTES
PREREQUISITES
    * PowerShell 7 and the Azure CLI, signed in with az login. Install the Bicep CLI with
      az bicep install if you don't already have it.
    * Contributor on the subscription, plus permission to write Microsoft Defender for Cloud settings
      (Security Admin, or Owner).

COST
    This lab creates billable Azure resources. The empty storage account costs pennies. Defender for
    Storage bills per protected account per month, prorated by the hour, and malware scanning bills
    per GB scanned, which an empty account never triggers. Check the Microsoft Defender for Cloud
    pricing page for your region, and remove the lab when you finish.

TIMING
    Defender for Storage can take up to 24 hours to start protecting a new account. The settings read
    back right away, so Show is accurate as soon as Deploy finishes.

CLEANUP
    pwsh -NoProfile -File .\Deploy-C4M04DataPath.ps1 -Mode Remove

    Or by hand. Deleting the account ends its Defender for Storage billing with it:
    az group delete --name rg-globomantics-c4m04 --yes
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Show', 'Remove')]
    [string]$Mode = 'Plan',

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId,

    [ValidatePattern('^[a-z0-9]{3,40}$')]
    [string]$Location = 'eastus2',

    [ValidateRange(1, 10000)][int]$MalwareScanCapGB = 10
)

$ErrorActionPreference = 'Stop'
$group = 'rg-globomantics-c4m04'
$tag = 'SC100-C4M04'
# The account-level Defender for Storage settings API, as Microsoft's REST enablement page documents it.
$defenderApi = '2025-07-01-preview'
$template = Join-Path $PSScriptRoot 'iac' 'main.bicep'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'The Azure CLI (az) is not on your PATH. Install it, run az login, then rerun this script.'
}
if (-not (Test-Path -LiteralPath $template)) {
    throw "Template not found at $template. Keep the iac folder next to this script."
}

# One wrapper for every Azure CLI call: pinned subscription, JSON out, and a throw on failure, so a
# failed call can never look like "nothing exists".
function Invoke-CourseAz {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $scoped = if ($SubscriptionId) { $Arguments + @('--subscription', $SubscriptionId) } else { $Arguments }
    $raw = & az @scoped --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI call failed: az $($Arguments[0..1] -join ' ')" }
    if ($raw) { ($raw -join "`n") | ConvertFrom-Json }
}

# The Defender settings live at an ARM path, called through Invoke-WebRequest rather than az rest,
# because on Windows az is a .cmd file and cmd.exe re-parses special characters in its arguments.
function Invoke-Arm {
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('GET', 'PUT')][string]$Method = 'GET', $Body, [switch]$AllowNotFound)
    $token = (Invoke-CourseAz @('account', 'get-access-token', '--resource', 'https://management.azure.com/')).accessToken
    $request = @{ Uri = "https://management.azure.com${Path}?api-version=$defenderApi"; Method = $Method; SkipHttpErrorCheck = $true
                  Headers = @{ Authorization = "Bearer $token" }; TimeoutSec = 60 }
    if ($Body) { $request.Body = ($Body | ConvertTo-Json -Depth 6); $request.ContentType = 'application/json' }
    $resp = Invoke-WebRequest @request
    if ($resp.StatusCode -eq 404 -and $AllowNotFound) { return $null }
    if ($resp.StatusCode -ge 400) { throw "ARM $Method $Path returned $($resp.StatusCode): $($resp.Content)" }
    if ($resp.Content) { return $resp.Content | ConvertFrom-Json }
}

function Set-DefenderForAccount {
    param([Parameter(Mandatory)][string]$AccountId, [Parameter(Mandatory)][bool]$Enabled)
    # overrideSubscriptionLevelSettings makes this account's settings stick whatever the subscription says.
    $props = [ordered]@{ isEnabled = $Enabled; overrideSubscriptionLevelSettings = $true }
    if ($Enabled) {
        $props.malwareScanning = @{ onUpload = @{ isEnabled = $true; capGBPerMonth = $MalwareScanCapGB } }
        $props.sensitiveDataDiscovery = @{ isEnabled = $true }
    }
    $null = Invoke-Arm -Path "$AccountId/providers/Microsoft.Security/defenderForStorageSettings/current" -Method PUT -Body @{ properties = $props }
}

# Compile first and offline: a template error should stop the run before anything touches Azure.
$null = & az bicep build --file $template --stdout --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "The template didn't compile: $template" }

$account = Invoke-CourseAz @('account', 'show')
if ($TenantId -and $account.tenantId -ne $TenantId) {
    throw "Subscription '$($account.name)' belongs to tenant $($account.tenantId), not $TenantId. Refusing to continue."
}
$SubscriptionId = $account.id
Write-Host "[CONTEXT] $($account.user.name) | $($account.name) | $Mode"

$exists = Invoke-CourseAz @('group', 'exists', '-n', $group)
if ($exists) {
    $current = Invoke-CourseAz @('group', 'show', '-n', $group)
    if ($current.tags.course -ne $tag) { throw "Ownership mismatch: $group exists but isn't tagged course=$tag. Refusing to touch it." }
    $Location = $current.location
}

function Get-LabAccount {
    return @(Invoke-CourseAz @('storage', 'account', 'list', '-g', $group)) | Where-Object { $_ -and $_.name -like 'stglbc4m04*' } | Select-Object -First 1
}

switch ($Mode) {
    'Remove' {
        if (-not $exists) { Write-Host "[PASS] $group is already absent"; return }
        $acct = Get-LabAccount
        if ($acct) {
            Set-DefenderForAccount -AccountId $acct.id -Enabled $false
            Write-Host "[PASS] Defender for Storage turned off for $($acct.name)"
        }
        $recheck = Invoke-CourseAz @('group', 'show', '-n', $group)
        if ($recheck.tags.course -ne $tag) { throw 'Tag changed between checks; refusing to delete.' }
        Write-Host "[REMOVE] Deleting $group and waiting for it to finish..."
        $null = Invoke-CourseAz @('group', 'delete', '-n', $group, '--yes')
        Write-Host "[PASS] $group removed. Check Cost Management tomorrow to confirm the charges stopped."
        return
    }
    'Plan' {
        if (-not $exists) {
            Write-Host "[PLAN] $group doesn't exist yet. Deploy creates it with the course tag; the template compiled cleanly."
            return
        }
        $result = Invoke-CourseAz @('deployment', 'group', 'what-if', '-g', $group, '--name', 'c4m04-data-path', '--template-file', $template, '--no-pretty-print')
        $changes = @($result.changes)
        Write-Host "[PLAN] what-if: $(@($changes | Group-Object changeType | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ')"
        foreach ($c in $changes) { Write-Host ('  {0,-10}{1}' -f $c.changeType, ($c.resourceId -split '/providers/', 2)[-1]) }
        return
    }
    'Deploy' {
        if (-not $exists) {
            $null = Invoke-CourseAz @('group', 'create', '-n', $group, '-l', $Location, '--tags', "course=$tag", 'company=Globomantics', 'purpose=course-lab', 'teardown=after-course')
            Write-Host "[PASS] Created $group in $Location"
        }
        $result = Invoke-CourseAz @('deployment', 'group', 'create', '-g', $group, '--name', 'c4m04-data-path', '--template-file', $template)
        $id = $result.properties.outputs.storageId.value
        Write-Host "[PASS] Storage account $($result.properties.outputs.storageName.value) deployed"
        Set-DefenderForAccount -AccountId $id -Enabled $true
        Write-Host "[PASS] Defender for Storage on for this account only, malware scanning capped at $MalwareScanCapGB GB a month"
        Write-Host '[NEXT] Run -Mode Show. Defender can take up to 24 hours to start protecting the account.'
        return
    }
}

# ------------------------------------------------------------------ Show
if (-not $exists) { throw "$group doesn't exist yet. Run -Mode Deploy first." }
$acct = Get-LabAccount
if (-not $acct) { throw 'No lab storage account in the group. Run -Mode Deploy again; it converges.' }

# Read one: the same query the demo runs, so the field names match what you saw on screen.
$read = Invoke-CourseAz @('storage', 'account', 'show', '-n', $acct.name, '-g', $group, '--query',
    '{sharedKey:allowSharedKeyAccess, minTls:minimumTlsVersion, publicBlob:allowBlobPublicAccess, publicNetwork:publicNetworkAccess, infraEncryption:encryption.requireInfrastructureEncryption}')
Write-Host ''
Write-Host "THE ACCOUNT: $($acct.name)"
Write-Host "  sharedKey        $($read.sharedKey)   (false: only Entra ID or a user delegation SAS gets in)"
Write-Host "  minTls           $($read.minTls)"
Write-Host "  publicBlob       $($read.publicBlob)   (governs anonymous reads only)"
Write-Host "  publicNetwork    $($read.publicNetwork)   (Enabled: the account still listens on the internet)"
Write-Host "  infraEncryption  $(if ($null -eq $read.infraEncryption) { 'not set' } else { $read.infraEncryption })   (set only at creation)"

# Read two: Defender for Storage on this one account.
$def = Invoke-Arm -Path "$($acct.id)/providers/Microsoft.Security/defenderForStorageSettings/current" -AllowNotFound
$p = $def.properties
Write-Host ''
Write-Host 'DEFENDER FOR STORAGE on this account'
Write-Host "  enabled          $([bool]$p.isEnabled)"
Write-Host "  malwareScanning  $([bool]$p.malwareScanning.onUpload.isEnabled)"
Write-Host "  sensitiveData    $([bool]$p.sensitiveDataDiscovery.isEnabled)"

$plan = Invoke-CourseAz @('security', 'pricing', 'show', '-n', 'StorageAccounts')
if ($plan.pricingTier -eq 'Standard') {
    Write-Host ''
    Write-Host 'NOTE: Defender for Storage is on at the SUBSCRIPTION level here, so every storage account in this subscription is already billed, not only this one.'
}
Write-Host ''
Write-Host 'Make a keep-or-change call on every value before you read the course answer.'
