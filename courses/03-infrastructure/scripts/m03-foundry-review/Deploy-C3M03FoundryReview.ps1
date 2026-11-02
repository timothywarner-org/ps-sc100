#Requires -Version 7.0

<#
.SYNOPSIS
Plans, deploys, or removes the Globomantics Foundry review lab for SC-100 Course 3, Module 3.

.DESCRIPTION
Builds the lab behind the demo "Evaluate a Foundry project against the AI controls" in your own
Azure subscription: one Foundry resource with a project, a model deployment carrying a custom
content filter, one storage account with two containers, and two workload identities (the
customer assistant and the ERP draft-order agent) whose data permissions differ on purpose.
iac\main.bicep is the only template source and documents every resource.

THE PLANTED GAP
    The customer assistant identity holds Storage Blob Data Contributor on the WHOLE storage
    account, so it can write draft orders that belong to the ERP draft-order agent. That
    over-broad permission is deliberate: it's the finding the review exists to surface. Don't
    fix it in the template; find it with Show-C3M03FoundryReview.ps1 first.

WHAT EACH MODE CHANGES
    Plan    Changes nothing. Compiles the template and runs what-if against the resource group.
    Deploy  Creates the resource group rg-globomantics-c3m03 (tagged course=SC100-C3M03) if
            it's missing, then deploys the template into it.
    Remove  Deletes that resource group and purges the soft-deleted Foundry resource.

SAFETY RAILS, each one a mistake this script refuses to make
    * Wrong subscription or tenant    -> pass -SubscriptionId or -TenantId and it stops before
                                         any write when your Azure CLI context doesn't match.
    * Someone else's resource group   -> refuses unless the group carries the course tag.
    * Not enough model quota          -> checks gpt-5-mini GlobalStandard quota before deploying.
    * Soft-deleted Foundry name clash -> Remove purges the account after the group is gone, so
                                         the next Deploy can reuse the deterministic name.
    * Deleting the wrong group        -> Remove re-reads the tag immediately before deleting.

.PARAMETER Mode
Plan (the default) runs what-if only and changes nothing. Deploy creates or converges the lab;
it's idempotent, so rerunning it changes nothing new. Remove deletes the course-tagged resource
group and purges the soft-deleted Foundry resource.

.PARAMETER SubscriptionId
Optional. The subscription to work in. Leave it out and the script uses your current Azure CLI
subscription (az account show). Supply it and every Azure CLI call is pinned to it.

.PARAMETER TenantId
Optional. The Microsoft Entra tenant you expect to be working in. Supply it and the script
refuses to continue when the subscription belongs to a different tenant.

.PARAMETER Location
Region for a new resource group. Defaults to eastus2. Pick a region where your subscription has
at least 10 units of gpt-5-mini GlobalStandard quota. When the resource group already exists,
the script uses the group's region instead, because that's where the template deploys.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C3M03FoundryReview.ps1 -Mode Plan
Compiles the template and shows what a deployment would change. Changes nothing.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C3M03FoundryReview.ps1 -Mode Deploy
Deploys the lab into your current Azure CLI subscription. Then run
.\Show-C3M03FoundryReview.ps1 to read the review.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C3M03FoundryReview.ps1 -Mode Deploy -SubscriptionId 00000000-0000-0000-0000-000000000000 -TenantId 00000000-0000-0000-0000-000000000000
Deploys into a named subscription and refuses to write if it isn't in the tenant you expect.
Replace the zeros with your own IDs.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C3M03FoundryReview.ps1 -Mode Remove
Deletes the lab and purges the soft-deleted Foundry resource. Run this when you're done.

.NOTES
PREREQUISITES
    * PowerShell 7 and the Azure CLI, signed in with az login. Install the Bicep CLI with
      az bicep install if you don't already have it.
    * Owner on the subscription, or Contributor plus User Access Administrator. The template
      creates role assignments as well as resources, and Contributor alone can't do that.
    * At least 10 units of gpt-5-mini GlobalStandard quota in the target region. The script
      checks before it deploys. Model availability varies by region and changes over time, so
      if the check fails, look up current availability on Microsoft Learn and pass -Location.

COST
    This lab creates billable Azure resources. There's no standing compute: the S0 Foundry
    resource and the GlobalStandard model deployment bill per token, and the review sends none.
    The storage account holds no data. Remove the lab as soon as you finish.

CLEANUP
    pwsh -NoProfile -File .\Deploy-C3M03FoundryReview.ps1 -Mode Remove

    Or by hand. Foundry resources are soft-deleted, so purge the account once the group delete
    finishes, or its name stays reserved:
    az group delete --name rg-globomantics-c3m03 --yes --no-wait
    az cognitiveservices account list-deleted -o table
    az cognitiveservices account purge --resource-group rg-globomantics-c3m03 --name <foundry-name> --location <region>
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Remove')]
    [string]$Mode = 'Plan',

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId,

    [ValidatePattern('^[a-z0-9]{3,40}$')]
    [string]$Location = 'eastus2'
)

$ErrorActionPreference = 'Stop'
$group = 'rg-globomantics-c3m03'
$tag = 'SC100-C3M03'
# The template ships beside this script, so the lab works from wherever you unzip it.
$template = Join-Path $PSScriptRoot 'iac' 'main.bicep'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'The Azure CLI (az) is not on your PATH. Install it, run az login, then rerun this script.'
}
if (-not (Test-Path -LiteralPath $template)) {
    throw "Template not found at $template. Keep the iac folder next to this script."
}

# One wrapper for every Azure CLI call. It pins the subscription once one is known, asks for JSON,
# and throws on a non-zero exit, so a failed call can never hand back an empty result that looks
# like "nothing exists".
function Invoke-CourseAz {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $scoped = if ($SubscriptionId) { $Arguments + @('--subscription', $SubscriptionId) } else { $Arguments }
    $raw = & az @scoped --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI call failed: az $($Arguments[0..1] -join ' ')" }
    if ($raw) { ($raw -join "`n") | ConvertFrom-Json }
}

# Compile first and offline: a template error should stop the run before anything touches Azure.
$null = & az bicep build --file $template --stdout --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "The template didn't compile: $template" }

$account = Invoke-CourseAz @('account', 'show')
if ($TenantId -and $account.tenantId -ne $TenantId) {
    throw "Subscription '$($account.name)' belongs to tenant $($account.tenantId), not $TenantId. Refusing to continue."
}
# Pin every later call to the subscription just checked, even if the CLI default changes mid-run.
$SubscriptionId = $account.id
Write-Host "[CONTEXT] $($account.user.name) | $($account.name) | $Mode"

$exists = Invoke-CourseAz @('group', 'exists', '-n', $group)
if ($exists) {
    $current = Invoke-CourseAz @('group', 'show', '-n', $group)
    if ($current.tags.course -ne $tag) { throw "Ownership mismatch: $group exists but isn't tagged course=$tag. Refusing to touch it." }
    # The template deploys into the group's region, so quota has to be checked there.
    $Location = $current.location
}

if ($Mode -eq 'Remove') {
    if (-not $exists) { Write-Host "[PASS] $group is already absent"; return }
    # Capture the Foundry account names BEFORE the group goes, so they can be purged after.
    $accounts = @(Invoke-CourseAz @('cognitiveservices', 'account', 'list', '-g', $group))
    $recheck = Invoke-CourseAz @('group', 'show', '-n', $group)
    if ($recheck.tags.course -ne $tag) { throw 'Tag changed between checks; refusing to delete.' }
    # No --no-wait here: the purge below only works once the delete has finished and the
    # Foundry account is in the soft-deleted state. Expect this to take several minutes.
    Write-Host "[REMOVE] Deleting $group and waiting for it to finish..."
    $null = Invoke-CourseAz @('group', 'delete', '-n', $group, '--yes')
    foreach ($a in $accounts) {
        $null = Invoke-CourseAz @('cognitiveservices', 'account', 'purge', '-g', $group, '-n', $a.name, '-l', $a.location)
        Write-Host "[PASS] Purged soft-deleted Foundry account $($a.name)"
    }
    Write-Host "[PASS] $group removed"
    return
}

# Quota: the model deployment needs 10 units of gpt-5-mini GlobalStandard in the region. Checking
# up front turns a long failed deployment into a one-line answer.
$usage = @(Invoke-CourseAz @('cognitiveservices', 'usage', 'list', '-l', $Location))
$q = @($usage | Where-Object { $_.name.value -eq 'OpenAI.GlobalStandard.gpt-5-mini' })
$deployed = $exists -and @(Invoke-CourseAz @('cognitiveservices', 'account', 'list', '-g', $group)).Count -gt 0
if (-not $deployed -and ($q.Count -ne 1 -or ([int]$q[0].limit - [int]$q[0].currentValue) -lt 10)) {
    throw "Insufficient gpt-5-mini GlobalStandard quota in $Location. Rerun with -Location set to a region where your subscription has at least 10 free units."
}
if ($q.Count -eq 1) { Write-Host "[PASS] gpt-5-mini GlobalStandard quota in $($Location): $($q[0].currentValue)/$($q[0].limit) in use" }

if ($Mode -eq 'Deploy' -and -not $exists) {
    $null = Invoke-CourseAz @('group', 'create', '-n', $group, '-l', $Location, '--tags', "course=$tag", 'company=Globomantics', 'purpose=demo-fixture', 'teardown=after-course')
    Write-Host "[PASS] Created $group in $Location"
}
if ($Mode -eq 'Plan' -and -not $exists) {
    # what-if needs an existing group. Report that instead of creating one in a no-change mode.
    Write-Host "[PLAN] $group doesn't exist yet. Deploy creates it with the course tag; the template compiled cleanly."
    return
}

$action = if ($Mode -eq 'Plan') { 'what-if' } else { 'create' }
$arguments = @('deployment', 'group', $action, '-g', $group, '--name', 'c3m03-foundry-review', '--template-file', $template)
if ($Mode -eq 'Plan') { $arguments += '--no-pretty-print' }
$result = Invoke-CourseAz $arguments

if ($Mode -eq 'Deploy') {
    $o = $result.properties.outputs
    Write-Host "[RESULT] $($result.properties.provisioningState): $($o.foundryName.value), project $($o.projectName.value), deployment $($o.deploymentName.value), storage $($o.storageName.value)"
    Write-Host '[NEXT] Run .\Show-C3M03FoundryReview.ps1 to read the review.'
} else {
    $changes = @($result.changes)
    $summary = @($changes | Group-Object changeType | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '
    Write-Host "[PLAN] what-if: $summary"
    foreach ($c in $changes) {
        # Trim each resource ID to provider/type/name so the line fits the screen.
        Write-Host ('  {0,-10}{1}' -f $c.changeType, ($c.resourceId -split '/providers/', 2)[-1])
    }
}
