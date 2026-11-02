#Requires -Version 7.4

<#
.SYNOPSIS
Read-only: one table of the Globomantics servers, how each connects, and which Defender for
Servers plan each one actually carries.

.DESCRIPTION
The plan evidence for the SC-100 Course 3 Module 2 demo, "Read server coverage and plan fit in
Defender for Cloud". Defender for Cloud's inventory shows HOW a server is connected (Azure VM or
Azure Arc machine) at a glance, but the plan a single machine carries, and whether that plan is
set on the machine or inherited from the subscription, lives in Defender for Cloud's own pricing
API. This script reads that API once per machine and prints the answer in words.

It changes nothing. Every call is a read: one Azure Resource Graph query for the machines and
their tags, then one GET per machine for its plan. It prints no secrets, no subscription names
and no IDs, so you can share the output without exposing your environment. Meaning is carried
by words in every column, never by color.

If the estate doesn't match the demo's four servers, for example because glb-dc-file01 hasn't
connected to Azure Arc yet, the script warns you and still prints what exists. Run it again once
the missing server shows up.

.PARAMETER SubscriptionId
The subscription that holds the lab. When you leave it out, the script uses the Azure CLI's
current subscription (az account show --query id -o tsv).

.PARAMETER ResourceGroup
The estate the demo filters to. Defaults to rg-globomantics-c3m02.

.EXAMPLE
pwsh -NoProfile -File .\Show-C3M02ServerPlans.ps1
Prints the table for the lab in your current Azure CLI subscription.

.EXAMPLE
pwsh -NoProfile -File .\Show-C3M02ServerPlans.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000
Reads the lab in a specific subscription. Replace the zeros with your subscription ID.

.NOTES
Prerequisites
  * PowerShell 7.4 or later, and the Azure CLI signed in with az login. Built and checked with
    Azure CLI 2.85; run az upgrade if yours is older.
  * The Azure CLI resource-graph extension: az extension add --name resource-graph
  * Reader on the subscription is enough, because nothing here writes.
  * The lab, deployed by Deploy-C3M02ServerEstate.ps1 or Deploy-C3M02ServerEstate.cloudshell.sh.
    It depends on Microsoft Defender for Servers Plan 2 at subscription scope; see README.md.

Cost
  This script creates nothing and costs nothing. The lab it reads does create billable
  resources; see README.md.

Cleanup, for the lab this script reads
  az ad app delete --id (az ad app list --display-name sp-globomantics-c3m02-arc --query "[0].appId" -o tsv)
  az group delete --name rg-globomantics-c3m02 --yes --no-wait
  az group delete --name rg-globomantics-c3m02-host --yes --no-wait
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,
    [ValidatePattern('^[-\w\._\(\)]{1,90}$')]
    [string]$ResourceGroup = 'rg-globomantics-c3m02'
)

$ErrorActionPreference = 'Stop'

# az graph ships as a CLI extension. Without it, az either stops to offer an install or fails,
# and neither helps a script, so check first and name the exact fix.
$null = & az extension show --name resource-graph -o none --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'The Azure CLI resource-graph extension is missing. Run: az extension add --name resource-graph'
}

# Default to the subscription your Azure CLI already points at, so the script works in your
# subscription without editing. Pass -SubscriptionId to read a different one.
if (-not $SubscriptionId) {
    $cliSubscription = & az account show --query id -o tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $cliSubscription) {
        throw 'No Azure CLI sign-in found. Run az login, then rerun. Nothing was inferred.'
    }
    $SubscriptionId = "$cliSubscription".Trim()
}
$sub = $SubscriptionId.ToLowerInvariant()

# One Resource Graph read for the machines and their tags. Flattened to one line because az is a
# .cmd on Windows and cmd.exe cuts an argument at its first newline.
$query = "resources | where resourceGroup =~ '$($ResourceGroup.ToLowerInvariant())' " +
         "| where type in~ ('microsoft.compute/virtualmachines', 'microsoft.hybridcompute/machines') " +
         "| where tostring(tags.course) == 'SC100-C3M02' " +
         "| project id, name, type=tolower(type), dataClass=tostring(tags.dataClass), environment=tostring(tags.environment) " +
         "| order by name asc"
$raw = & az graph query -q $query --subscriptions $sub --first 100 -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Resource Graph read failed. Run az login, then rerun. Nothing was inferred.' }
$machines = @((($raw -join "`n") | ConvertFrom-Json).data)
if ($machines.Count -eq 0) {
    throw "No SC100-C3M02 machines in $ResourceGroup. Deploy the lab first (see README.md), then rerun."
}

# The demo compares exactly these four servers. A partial estate still prints, because what
# exists is still true, but you're told what's missing so a gap never reads as a finding.
$expected = @('glb-dc-file01', 'vm-glb-erp01', 'vm-glb-test01', 'vm-glb-web01')
$found = @($machines | ForEach-Object { $_.name })
$missing = @($expected | Where-Object { $_ -notin $found })
$extra = @($found | Where-Object { $_ -notin $expected })
$untagged = @($machines | Where-Object { -not $_.dataClass -or -not $_.environment } | ForEach-Object { $_.name })
if ($missing.Count -or $extra.Count -or $untagged.Count) {
    $detail = @()
    if ($missing.Count) { $detail += "missing: $($missing -join ', ')" }
    if ($extra.Count) { $detail += "not part of the lab: $($extra -join ', ')" }
    if ($untagged.Count) { $detail += "no dataClass or environment tag: $($untagged -join ', ')" }
    Write-Warning ("The estate doesn't match the demo's four servers ($($detail -join '; ')). " +
        'glb-dc-file01 appears a few minutes after its host VM boots and connects to Azure Arc. ' +
        'Showing what exists.')
}

$rows = foreach ($m in $machines) {
    $uri = "https://management.azure.com$($m.id)/providers/Microsoft.Security/pricings/virtualMachines?api-version=2024-01-01"
    $p = & az rest --method get --url $uri -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Plan read failed for $($m.name). Nothing was inferred." }
    $p = ($p -join "`n") | ConvertFrom-Json
    $plan = switch ("$($p.properties.pricingTier)/$($p.properties.subPlan)") {
        'Standard/P2' { 'Plan 2' }
        'Standard/P1' { 'Plan 1' }
        default       { 'No plan' }
    }
    [pscustomobject]@{
        Server        = $m.name
        'Connects as' = if ($m.type -eq 'microsoft.hybridcompute/machines') { 'Azure Arc machine' } else { 'Azure VM' }
        Plan          = $plan
        'Plan set'    = if ("$($p.properties.inherited)" -eq 'True') { 'inherited from subscription' } else { 'on this machine' }
        'Data class'  = $m.dataClass
        Environment   = $m.environment
    }
}

$rows | Format-Table -AutoSize | Out-String -Width 160 | Write-Host
