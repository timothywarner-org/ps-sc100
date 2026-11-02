#Requires -Version 7.0

<#
.SYNOPSIS
Runs the SC-100 Course 1, Module 3 workload template in your current landing zone: one template, two
landing zones, two answers.

.DESCRIPTION
The lab's whole claim is that NOTHING about the workload changes between the deployment that succeeds
and the deployment that's prevented. Only the subscription's management group changes. This script makes
that claim structurally true: every run deploys the SAME template file with the SAME parameters and the
SAME generated account name, and the only step that differs between the two runs is the management group
move.

    FIRST RUN    .\Invoke-C1M03Workload.ps1 -ShowTemplate
                 Your subscription should be in Online. Prints the template's resource block and its
                 SHA-256 fingerprint, then deploys it. Expect DEPLOYED: Online audits a public blob
                 endpoint instead of blocking it.

    SECOND RUN   .\Invoke-C1M03Workload.ps1 -MoveTo corp
                 Moves your subscription to Corp, then deploys the identical file. Expect PREVENTED,
                 with the policy's non-compliance message on its own line. Compare the fingerprint
                 with the first run.

    RESET        .\Invoke-C1M03Workload.ps1 -Reset
                 Moves the subscription back to Online and deletes the storage account the first run
                 created, so you can run the pair again from a clean start.

Deploy-C1M03LandingZones.ps1 has to have built the hierarchy first. In the course video this script is
named Invoke-M03Workload.ps1; it behaves the same way.

.PARAMETER MoveTo
Moves the subscription to this archetype, corp or online, BEFORE deploying. -MoveTo corp is the second run.

.PARAMETER Reset
Restores the starting state: subscription in Online, workload storage account deleted.

.PARAMETER ShowTemplate
Prints the workload template's resource block before deploying, so you've actually seen the file whose
unchangingness the second run depends on.

.PARAMETER SubscriptionId
Optional. Resolution order: this parameter, then the AZURE_SUBSCRIPTION_ID environment variable, then
your current Azure CLI subscription. It must be the subscription Deploy-C1M03LandingZones.ps1 governs.

.PARAMETER TenantId
Optional. Resolution order: this parameter, then AZURE_TENANT_ID. When either is set, the script refuses
to continue if the subscription belongs to a different tenant.

.PARAMETER ResourceGroupName
Where the workload lands. Created in an allowed region and tagged course=SC100-C1M03. Defaults to
rg-globomantics-storefront.

.PARAMETER Location
Region for the resource group. Must be on the allowed list, so the storage account is the only thing
either policy has an opinion about. Defaults to eastus2.

.PARAMETER ManagementGroupPrefix
Must match the prefix Deploy-C1M03LandingZones.ps1 used. Defaults to mg-globomantics.

.EXAMPLE
pwsh -NoProfile -File .\Invoke-C1M03Workload.ps1 -ShowTemplate
The first run, in Online. Expect DEPLOYED.

.EXAMPLE
pwsh -NoProfile -File .\Invoke-C1M03Workload.ps1 -MoveTo corp
The second run, after the move to Corp. Expect PREVENTED.

.EXAMPLE
pwsh -NoProfile -File .\Invoke-C1M03Workload.ps1 -Reset
Back to the starting state.

.NOTES
WHY AN UNEXPECTED SUCCESS COUNTS AS A FAILURE
    In Corp, a deployment that succeeds isn't a lucky break: it means the guardrail isn't working. The
    script deletes whatever landed and exits 1, so the lab never leaves an ungoverned resource behind.

EXIT CODES
    0  the expected outcome happened
    1  the WRONG outcome happened (deployed when it should have been prevented, or the reverse)
    2  something failed for a reason other than policy

COST
    One Standard_LRS storage account with no data in it, which costs very little. Reset or the Remove mode
    of Deploy-C1M03LandingZones.ps1 deletes it.
#>
[CmdletBinding()]
param(
    [ValidateSet('corp', 'online')]
    [string]$MoveTo,

    [switch]$Reset,

    [switch]$ShowTemplate,

    [string]$SubscriptionId,

    [string]$TenantId,

    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$')]
    [string]$ResourceGroupName = 'rg-globomantics-storefront',

    [ValidatePattern('^[a-z0-9]{3,40}$')]
    [string]$Location = 'eastus2',

    [ValidatePattern('^[A-Za-z0-9._()-]{1,60}$')]
    [string]$ManagementGroupPrefix = 'mg-globomantics'
)

$ErrorActionPreference = 'Stop'
$courseTag = 'SC100-C1M03'
$guidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$corpMg = "$ManagementGroupPrefix-corp"
$onlineMg = "$ManagementGroupPrefix-online"
$templateFile = Join-Path $PSScriptRoot 'iac' 'workload-storage.bicep'

function Write-Beat {
    # The bracketed WORD carries the meaning, so a line reads the same in any terminal or a transcript.
    param([Parameter(Mandatory)][string]$Text, [ValidateSet('info', 'ok', 'fail', 'step')][string]$Kind = 'info')
    $tag = switch ($Kind) { 'ok' { '[OK]' } 'fail' { '[FAIL]' } 'step' { '[STEP]' } default { '[INFO]' } }
    Write-Host "$tag $Text"
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Beat 'The Azure CLI (az) isn''t on your PATH. Install it, run az login, then rerun this script.' 'fail'
    exit 2
}
if (-not (Test-Path -LiteralPath $templateFile)) {
    Write-Beat "The iac folder must sit next to this script and hold workload-storage.bicep: $templateFile" 'fail'
    exit 2
}

# Explicit parameter first, then the environment variable, then whatever az login selected.
$subId = if ($SubscriptionId) { $SubscriptionId } elseif ($env:AZURE_SUBSCRIPTION_ID) { $env:AZURE_SUBSCRIPTION_ID } else { $null }
$expectedTenant = if ($TenantId) { $TenantId } elseif ($env:AZURE_TENANT_ID) { $env:AZURE_TENANT_ID } else { $null }
foreach ($v in @($subId, $expectedTenant)) {
    if ($v -and $v -notmatch $guidPattern) { Write-Beat "'$v' isn't a GUID." 'fail'; exit 2 }
}
$accountJson = if ($subId) { az account show --subscription $subId --only-show-errors -o json } else { az account show --only-show-errors -o json }
if ($LASTEXITCODE -ne 0) { Write-Beat 'Not signed in. Run az login, then rerun this script.' 'fail'; exit 2 }
$account = ($accountJson -join "`n") | ConvertFrom-Json
if ($expectedTenant -and $account.tenantId -ne $expectedTenant) {
    Write-Beat "Subscription '$($account.name)' belongs to tenant $($account.tenantId), not $expectedTenant. Refusing to continue." 'fail'
    exit 2
}
# Pin every later call to the subscription just checked.
$subId = $account.id
Write-Beat "subscription : $($account.name)"

function Get-SubscriptionParentMg {
    # Which archetype the subscription sits in right now, read from the two archetype groups.
    foreach ($group in @($corpMg, $onlineMg)) {
        $json = az account management-group show --name $group --expand --only-show-errors -o json 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        $children = (($json -join "`n") | ConvertFrom-Json).children
        if ($children | Where-Object { $_.name -eq $subId }) { return $group }
    }
    return '(neither Corp nor Online)'
}

function Move-SubscriptionToArchetype {
    param([Parameter(Mandatory)][string]$TargetMg)
    Write-Beat "moving the subscription to $TargetMg" 'step'
    az account management-group subscription add --name $TargetMg --subscription $subId --only-show-errors -o none
    if ($LASTEXITCODE -ne 0) {
        Write-Beat 'the move failed, so nothing after it would mean anything. Has Deploy-C1M03LandingZones.ps1 built the hierarchy?' 'fail'
        exit 2
    }
    # After a move, new writes in the subscription are evaluated against the new parent's assignments
    # in real time, so there's no policy evaluation wait. The short pause covers Resource Manager's own
    # hierarchy cache.
    # https://learn.microsoft.com/azure/cloud-adoption-framework/ready/enterprise-scale/transition#move-subscriptions
    Start-Sleep -Seconds 10
    Write-Beat "subscription now under : $(Get-SubscriptionParentMg)"
}

function Get-OwnedGroupState {
    # 'absent', 'ours', or 'foreign'. This script never writes into a resource group it didn't create.
    $exists = az group exists --name $ResourceGroupName --subscription $subId --only-show-errors -o tsv
    if ($exists -ne 'true') { return 'absent' }
    $tag = az group show --name $ResourceGroupName --subscription $subId --query 'tags.course' --only-show-errors -o tsv
    if ($tag -eq $courseTag) { return 'ours' }
    return 'foreign'
}

# ---------------------------------------------------------------------------
if ($Reset) {
    Write-Beat 'RESET: restoring the starting state' 'step'
    Move-SubscriptionToArchetype -TargetMg $onlineMg
    if ((Get-OwnedGroupState) -eq 'ours') {
        $existing = az storage account list --resource-group $ResourceGroupName --subscription $subId --query '[].name' --only-show-errors -o tsv
        foreach ($name in ($existing | Where-Object { $_ })) {
            Write-Beat "deleting $name" 'step'
            az storage account delete --name $name --resource-group $ResourceGroupName --subscription $subId --yes --only-show-errors -o none
        }
    }
    Write-Beat 'reset complete: subscription in Online, workload storage account removed' 'ok'
    exit 0
}

if ($MoveTo) {
    $target = if ($MoveTo -eq 'corp') { $corpMg } else { $onlineMg }
    Move-SubscriptionToArchetype -TargetMg $target
}

$archetype = Get-SubscriptionParentMg
if ($archetype -eq '(neither Corp nor Online)') {
    Write-Beat "the subscription isn't under $onlineMg or $corpMg. Run Deploy-C1M03LandingZones.ps1 -Mode Deploy -ConfirmSubscriptionMove first." 'fail'
    exit 2
}
$expectPrevented = ($archetype -eq $corpMg)
Write-Beat "landing zone : $archetype"
$expectation = if ($expectPrevented) { 'PREVENTED (Corp denies public blob access)' } else { 'DEPLOYED (Online audits it)' }
Write-Beat "expecting    : $expectation"

# THE FINGERPRINT. Printed on every run, so the claim that the template didn't change between runs is
# something you can CHECK rather than take on trust. Same hash both times is the proof.
$templateHash = (Get-FileHash -Path $templateFile -Algorithm SHA256).Hash
Write-Beat "template     : $(Split-Path $templateFile -Leaf)"
Write-Beat "sha256       : $templateHash"

if ($ShowTemplate) {
    # Comment lines are stripped so the resource block fits one screen. The file on disk keeps them.
    Write-Host ''
    Write-Host '  --- the workload template, resource block ---'
    $lines = Get-Content $templateFile
    $opening = $lines | Select-String -Pattern '^resource ' | Select-Object -First 1
    $start = $opening.LineNumber - 1
    $closing = $lines | Select-String -Pattern '^\}' | Where-Object { $_.LineNumber -gt $start } | Select-Object -First 1
    $end = $closing.LineNumber - 1
    $lines[$start..$end] | Where-Object { $_.Trim() -notmatch '^//' } | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
}

# The resource group is created separately, in an allowed region, so the ONLY thing policy has to speak
# to is the storage account itself. One violation, one error.
switch (Get-OwnedGroupState) {
    'foreign' {
        Write-Beat "$ResourceGroupName exists but isn't tagged course=$courseTag. Pass a different -ResourceGroupName." 'fail'
        exit 2
    }
    'absent' {
        az group create --name $ResourceGroupName --location $Location --subscription $subId `
            --tags "course=$courseTag" 'company=Globomantics' 'purpose=course-lab' --only-show-errors -o none
        if ($LASTEXITCODE -ne 0) { Write-Beat 'couldn''t create the resource group' 'fail'; exit 2 }
    }
}

Write-Beat 'deploying the workload template (unchanged between runs)' 'step'
# Streams are captured SEPARATELY on purpose. Merging them with 2>&1 puts the CLI's "WARNING:" lines
# into the same string as the JSON payload, and ConvertFrom-Json then fails on the leading W. stdout
# carries the deployment JSON; stderr carries warnings AND the policy denial text.
$stderrFile = [System.IO.Path]::GetTempFileName()
$stdout = az deployment group create --resource-group $ResourceGroupName --subscription $subId `
    --name "c1m03-workload-$(Get-Date -Format 'yyyyMMdd-HHmmss')" --template-file $templateFile -o json 2>$stderrFile
$deployFailed = ($LASTEXITCODE -ne 0)
$stderrText = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw } else { '' }
Remove-Item $stderrFile -ErrorAction SilentlyContinue
$text = (($stdout -join "`n") + "`n" + $stderrText)

if ($deployFailed) {
    if ($text -match 'RequestDisallowedByPolicy') {
        Write-Host ''
        Write-Beat 'PREVENTED' 'ok'
        Write-Host '  error code   : RequestDisallowedByPolicy'

        # What Azure returns: the top-level message carries the assignment's non-compliance message,
        # and the assignment and definition arrive as RESOURCE IDs inside the error details, not as
        # display names. The readable part is the message the platform team wrote, and it names the fix.
        if ($text -match "Globomantics [A-Za-z]+ landing zone policy:[^'`"]+") {
            Write-Host "  message      : $($Matches[0])"
        }

        # Looked up from the hierarchy, and LABELLED as such, so nobody mistakes it for part of the error.
        $denying = az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/$archetype" --only-show-errors -o json 2>$null |
                   ConvertFrom-Json | Where-Object { $_.parameters.effect.value -eq 'Deny' } | Select-Object -First 1
        Write-Host ''
        Write-Host '  -- context, read from the hierarchy, NOT from the error text --'
        Write-Host "  landing zone : $archetype"
        if ($denying) { Write-Host "  assignment   : $($denying.displayName)" }
        Write-Host ''

        if (-not $expectPrevented) {
            Write-Beat "but the subscription is in $archetype, where this should have DEPLOYED" 'fail'
            exit 1
        }
        exit 0
    }

    Write-Beat 'the deployment failed for a reason OTHER than policy' 'fail'
    if ($text -match 'AADSTS50076') {
        Write-Beat 'Microsoft Entra wants multifactor authentication for this write. Sign in again with az login, or run this from Azure Cloud Shell.' 'fail'
    }
    Write-Host $text
    exit 2
}

# Deployment succeeded. Parse ONLY stdout, from the first brace, so a stray warning can never reach
# ConvertFrom-Json.
$json = ($stdout -join "`n")
$brace = $json.IndexOf('{')
$name = if ($brace -ge 0) {
    ($json.Substring($brace) | ConvertFrom-Json).properties.outputs.storageAccountName.value
}
else {
    # Never guess a name. If the payload is unreadable, ask Resource Manager directly.
    az storage account list --resource-group $ResourceGroupName --subscription $subId --query '[0].name' --only-show-errors -o tsv
}
Write-Host ''
Write-Beat 'DEPLOYED' 'ok'
Write-Host "  storage account   : $name"
Write-Host '  public blob access: allowed'
Write-Host "  landing zone      : $archetype"
Write-Host ''

if ($expectPrevented) {
    Write-Beat 'this should have been PREVENTED, which means the Corp guardrail isn''t working' 'fail'
    Write-Beat 'deleting the account that should never have landed' 'step'
    az storage account delete --name $name --resource-group $ResourceGroupName --subscription $subId --yes --only-show-errors -o none
    Write-Beat 'check: is the subscription really under Corp, is the Corp assignment enforced, and has it been five minutes since Deploy?' 'fail'
    exit 1
}
Write-Beat 'Online recorded it instead of blocking it. Now run .\Invoke-C1M03Workload.ps1 -MoveTo corp and compare the sha256 line.' 'info'
exit 0
