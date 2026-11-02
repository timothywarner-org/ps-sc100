<#
.SYNOPSIS
Read-only review of the Globomantics vendor Private Access setup, and of what else still reaches
the plant, in plain words.

.DESCRIPTION
This is the review from the SC-100 Course 3, Module 4 demo, "Scope vendor access with Microsoft
Entra Private Access". It prints these sections:

    WHO MAY CONNECT             the enterprise app, its assignment and its Conditional Access policy
    WHERE THE CONNECTION LANDS  the application segment and the connector that carries it
    WHAT ELSE REACHES THE PLANT the Azure network rules that still admit traffic to each line

WHY ONE SCREEN
    The design decision joins Microsoft Entra objects to Azure network rules. The portals split
    those across the Microsoft Entra admin center and two network security group pages; the
    comparison you need only exists when they sit side by side. Every value is read live.

WHAT IT CHANGES
    Nothing in Azure and nothing in Microsoft Entra. It prints no IDs, tokens or subscription
    names; the only address it prints is the lab's legacy VPN pool, which is the finding. Meaning
    is carried by words, never by color.

WHEN SOMETHING IS MISSING
    A missing lab object prints NOT FOUND on its row, and a warning names the step that creates
    it. The review never fills a gap with a default that would read as a real setting.

.PARAMETER SubscriptionId
Optional. The subscription you deployed the lab to. Defaults to your current Azure CLI
subscription (az account show).

.PARAMETER TenantId
Optional. The Microsoft Entra tenant you configured. Defaults to the tenant of your Azure CLI
sign-in.

.EXAMPLE
pwsh -NoProfile -File ./Show-C3M04PrivateAccess.ps1

.EXAMPLE
pwsh -NoProfile -File ./Show-C3M04PrivateAccess.ps1 -SubscriptionId <your-subscription-id>

.NOTES
PREREQUISITES
    PowerShell 7.4 or later; C3M04Common.ps1 in the same folder.
    Azure CLI, signed in with az login. Reader or better on rg-globomantics-c3m04.
    Microsoft.Graph.Authentication 2.28.0 or later:
        Install-Module Microsoft.Graph.Authentication -MinimumVersion 2.28.0 -Scope CurrentUser
    The Microsoft Entra account you used to build the lab (see Set-C3M04PrivateAccess.ps1 for
    the roles). The first run prompts you to sign in to Microsoft Graph.
    Microsoft Entra Private Access needs licensing in your tenant. Check the licensing section of
    "What is Global Secure Access?" on Microsoft Learn:
    https://learn.microsoft.com/entra/global-secure-access/overview-what-is-global-secure-access
    Build the lab first: Deploy-C3M04PlantNetwork.ps1 -Mode Deploy, then
    Set-C3M04PrivateAccess.ps1 -Mode Configure and -Mode Register.

COST
    This script creates nothing. The lab it reviews DOES create billable Azure resources (three
    VMs and their disks) that keep billing until you delete them.

CLEANUP
    Azure:
        az group delete --name rg-globomantics-c3m04 --yes --no-wait
    Microsoft Entra (Conditional Access policy, enterprise application with its segment and
    vendor assignment, vendor account, connector, connector group):
        pwsh -NoProfile -File ./Set-C3M04PrivateAccess.ps1 -Mode Remove
    README.md lists the manual commands for each object if you'd rather remove them by hand.
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'C3M04Common.ps1')

$context = Resolve-C3M04Context -SubscriptionId $SubscriptionId -TenantId $TenantId
$null = Connect-C3M04Graph -TenantId $context.TenantId
$e = Read-C3M04Entra

# The Azure half is read on its own so a missing resource group turns into a warning instead of
# hiding the Entra half of the review.
$a = $null
try { $a = Read-C3M04Azure -SubscriptionId $context.SubscriptionId }
catch { Write-Warning "Couldn't read the Azure half of the lab ($($_.Exception.Message)). Deploy it with Deploy-C3M04PlantNetwork.ps1 -Mode Deploy, or pass -SubscriptionId for the subscription you deployed to." }

$missing = @(
    if (-not $e.App)    { "enterprise app '$($C3M04.App)'" }
    if (-not $e.Policy) { "Conditional Access policy '$($C3M04.Policy)'" }
    if (-not $e.Group)  { "connector group '$($C3M04.ConnectorGroup)'" }
)
if ($missing) {
    Write-Warning ('Not found in this tenant: ' + ($missing -join '; ') + '. Run Set-C3M04PrivateAccess.ps1 -Mode Configure. Those rows print NOT FOUND below.')
}
# A stopped connector host is the usual reason the connector reads inactive, so name the fix.
$connectorHost = if ($a) { $a.Power | Where-Object Name -eq $C3M04.ConnectorVm }
if ($connectorHost -and $connectorHost.Power -ne 'running') {
    Write-Warning "$($C3M04.ConnectorVm) is $($connectorHost.Power), so its connector reads inactive. The lab VMs stop every night at 23:00 Central. Start it with: az vm start --resource-group $($C3M04.Group) --name $($C3M04.ConnectorVm)"
}

$notFound = 'NOT FOUND'
$assignedNames = @($e.Assigned | ForEach-Object principalDisplayName)
$state = switch ($e.Policy.state) {
    'enabled'                           { 'On' }
    'enabledForReportingButNotEnforced' { 'Report-only (not enforcing)' }
    default                             { 'Off' }
}
$grant = (($e.Policy.grantControls.builtInControls | ForEach-Object { if ($_ -eq 'mfa') { 'require multifactor authentication' } else { $_ } }) -join ', ')
$conns = if ($e.Members) { ($e.Members | ForEach-Object { "$($_.machineName): $($_.status)" }) -join ', ' } else { 'none registered yet' }

Write-Host ''
Write-Host 'Globomantics line A vendor access: Private Access review (read-only)'
Write-Host ''
Write-Host 'WHO MAY CONNECT'
Write-Host ('  {0,-25}{1}' -f 'Enterprise application', $(if ($e.App) { $e.App.displayName } else { $notFound }))
Write-Host ('  {0,-25}{1}' -f 'Assignment required', $(if (-not $e.Sp) { $notFound } elseif ($e.Sp.appRoleAssignmentRequired) { 'Yes' } else { 'No: anyone in the tenant' }))
Write-Host ('  {0,-25}{1}' -f 'Assigned', $(if (-not $e.Sp) { $notFound } elseif ($assignedNames) { ($assignedNames -join ', ') + " ($($assignedNames.Count) assignment)" } else { 'nobody' }))
Write-Host ('  {0,-25}{1}' -f 'Conditional Access', $(if ($e.Policy) { "$state; grant: $grant" } else { $notFound }))
Write-Host ''
Write-Host 'WHERE THE CONNECTION LANDS'
if ($e.Segments) {
    foreach ($seg in $e.Segments) {
        Write-Host ('  {0,-25}{1}  {2} {3}' -f 'Application segment', $seg.destinationHost, $seg.protocol.ToUpper(), (($seg.ports | ForEach-Object { ($_ -split '-')[0] }) -join ', '))
    }
} else {
    Write-Host ('  {0,-25}{1}' -f 'Application segment', $(if ($e.App) { 'none configured' } else { $notFound }))
}
Write-Host ('  {0,-25}{1}' -f 'Connector group', $(if ($e.Group) { $e.Group.name } else { $notFound }))
Write-Host ('  {0,-25}{1}' -f 'Connectors', $conns)
Write-Host ''
Write-Host 'WHAT ELSE REACHES THE PLANT (Azure network rules, inbound)'
if (-not $a) {
    Write-Host '  Not readable; see the warning above.'
    return
}
$lineOf = @{ 'nsg-glb-line-a' = 'line A'; 'nsg-glb-line-b' = 'line B' }
$rows = foreach ($n in $a.Nsgs | Where-Object { $lineOf.ContainsKey($_.name) }) {
    foreach ($r in $n.properties.securityRules | Where-Object { $_.properties.access -eq 'Allow' -and $_.properties.direction -eq 'Inbound' }) {
        $p = $r.properties
        $from = switch ($p.sourceAddressPrefix) {
            $C3M04.LegacyPool { "legacy vendor VPN pool $($C3M04.LegacyPool)" }
            '10.40.1.0/24'    { 'plant management subnet (connector)' }
            default           { $p.sourceAddressPrefix }
        }
        $ports = @($p.destinationPortRange) + @($p.destinationPortRanges) | Where-Object { $_ } | Sort-Object { [int]$_ }
        [pscustomobject]@{ Rule = $r.name; 'Allows from' = $from; To = $lineOf[$n.name]; Ports = ($ports -join ', ') }
    }
}
if ($rows) {
    $rows | Sort-Object To, Rule | Format-Table -AutoSize | Out-String -Width 160 | Write-Host
} else {
    Write-Host '  No inbound allow rules found on nsg-glb-line-a or nsg-glb-line-b.'
}
