<#
.SYNOPSIS
Shared, read-only helpers for the Globomantics Private Access lab (SC-100 Course 3, Module 4).

.DESCRIPTION
Show-C3M04PrivateAccess.ps1 dot-sources this file. It defines the lab's object names and the
functions that resolve your Azure CLI context, connect Microsoft Graph PowerShell, and read the
lab's Microsoft Entra objects and Azure network rules.

It changes nothing in Azure and nothing in Microsoft Entra. Dot-sourcing it only defines names.

WHY A SHARED FILE
    The review reads objects that two different scripts create. Keeping every name and every
    reader in one file means the review can't drift from what the build scripts made.

.EXAMPLE
. ./C3M04Common.ps1
$context = Resolve-C3M04Context
$null = Connect-C3M04Graph -TenantId $context.TenantId
Read-C3M04Entra | Format-List

Loads the helpers into your session so you can explore the lab's Entra objects interactively
after you've built the lab.

.NOTES
PREREQUISITES
    PowerShell 7.4 or later.
    Azure CLI, signed in with az login.
    Microsoft.Graph.Authentication 2.28.0 or later:
        Install-Module Microsoft.Graph.Authentication -MinimumVersion 2.28.0 -Scope CurrentUser
    Reading needs the same Microsoft Entra roles you used to build the lab (see
    Set-C3M04PrivateAccess.ps1) and Reader or better on the resource group in Azure.
    Microsoft Entra Private Access needs licensing in your tenant. Check the licensing section of
    "What is Global Secure Access?" on Microsoft Learn:
    https://learn.microsoft.com/entra/global-secure-access/overview-what-is-global-secure-access

COST
    This file creates nothing. The lab it reads DOES create billable Azure resources (three VMs
    and their disks); see Deploy-C3M04PlantNetwork.ps1. Delete the lab when you're done.

CLEANUP
    Azure:
        az group delete --name rg-globomantics-c3m04 --yes --no-wait
    Microsoft Entra (Conditional Access policy, enterprise application with its segment and
    vendor assignment, vendor account, connector, connector group):
        pwsh -NoProfile -File ./Set-C3M04PrivateAccess.ps1 -Mode Remove
    README.md lists the manual commands for each object if you'd rather remove them by hand.
#>
#Requires -Version 7.4

# The names every lab script creates and reads. Keep them as they are so your output matches
# the demo. Globomantics is fictional.
$C3M04 = @{
    Group          = 'rg-globomantics-c3m04'
    Tag            = 'SC100-C3M04'
    ConnectorGroup = 'cg-glb-c3m04-plant-a'
    ConnectorHost  = 'glb-pa-conn01'
    ConnectorVm    = 'vm-glb-pa-conn01'
    App            = 'Globomantics line A maintenance (C3M04)'
    Policy         = 'GLB C3M04: vendor line A maintenance requires MFA'
    UserPrefix     = 'glb-c3m04-vendor'
    Fqdn           = 'maintenance-line-a.globomantics.example'
    LegacyPool     = '172.16.50.0/24'
}
$C3M04Beta = 'https://graph.microsoft.com/beta'
$C3M04V1 = 'https://graph.microsoft.com/v1.0'

function Resolve-C3M04Context {
    <#
    .SYNOPSIS
    Returns the subscription and tenant the lab works in, taken from your Azure CLI sign-in.
    .DESCRIPTION
    Nothing here is hard-coded: the subscription is whatever az account show reports. Use
    -SubscriptionId to read a different subscription you're signed in to, and -TenantId when your
    Microsoft Entra tenant isn't the subscription's own tenant.
    #>
    [CmdletBinding()]
    param(
        [string]$SubscriptionId,
        [string]$TenantId
    )
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'The Azure CLI (az) is not on your PATH. Install it, run az login, then rerun.'
    }
    $azArgs = @('account', 'show', '--only-show-errors', '-o', 'json')
    if ($SubscriptionId) { $azArgs += @('--subscription', $SubscriptionId) }
    $raw = & az @azArgs
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        throw 'No usable Azure CLI sign-in. Run az login, then az account set --subscription <your subscription ID>, and rerun.'
    }
    $account = ($raw -join "`n") | ConvertFrom-Json
    [pscustomobject]@{
        SubscriptionId   = $account.id
        SubscriptionName = $account.name
        TenantId         = if ($TenantId) { $TenantId } else { $account.tenantId }
        User             = $account.user.name
    }
}

function Connect-C3M04Graph {
    <#
    .SYNOPSIS
    Connects Microsoft Graph PowerShell to your tenant with the review's scopes.
    .DESCRIPTION
    Reuses a session that's already on the right tenant with every scope, so a rerun doesn't
    prompt. Otherwise it opens the normal Microsoft sign-in.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
        [string]$TenantId,

        [string[]]$Scopes = @('Application.Read.All', 'Directory.Read.All', 'NetworkAccess.ReadWrite.All', 'Policy.Read.All')
    )
    Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.28.0 -ErrorAction Stop
    $ctx = Get-MgContext
    $missing = if ($ctx) { @($Scopes | Where-Object { $_ -notin $ctx.Scopes }) } else { $Scopes }
    if (-not $ctx -or $ctx.TenantId -ne $TenantId -or $missing) {
        Connect-MgGraph -TenantId $TenantId -Scopes $Scopes -NoWelcome -ErrorAction Stop
        $ctx = Get-MgContext
    }
    # An account from another tenant would read a different directory and report the lab as absent.
    if (-not $ctx -or $ctx.TenantId -ne $TenantId) {
        throw "Microsoft Graph is signed in to a different tenant than $TenantId. Run Disconnect-MgGraph, then rerun and sign in with an account from that tenant."
    }
    $ctx
}

function Get-C3M04Graph([string]$Uri) { Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop }

function Read-C3M04Entra {
    <#
    .SYNOPSIS
    Every Microsoft Entra object the demo reviews, in one structure. Absent objects are $null.
    #>
    [CmdletBinding()]
    param()
    $s = [ordered]@{}
    # The vendor account is created in your tenant's default domain, so its UPN is derived here.
    $domain = ((Get-C3M04Graph "$C3M04V1/organization").value[0].verifiedDomains | Where-Object isDefault).name
    $s.Upn = "$($C3M04.UserPrefix)@$domain"
    $s.Profile = @((Get-C3M04Graph "$C3M04Beta/networkAccess/forwardingProfiles?`$select=id,state,trafficForwardingType").value | Where-Object trafficForwardingType -eq 'private') | Select-Object -First 1
    $s.Group = @((Get-C3M04Graph "$C3M04Beta/onPremisesPublishingProfiles/applicationProxy/connectorGroups").value | Where-Object name -eq $C3M04.ConnectorGroup) | Select-Object -First 1
    $s.Members = if ($s.Group) { @((Get-C3M04Graph "$C3M04Beta/onPremisesPublishingProfiles/applicationProxy/connectorGroups/$($s.Group.id)/members").value) } else { @() }
    $s.App = @((Get-C3M04Graph "$C3M04Beta/applications?`$filter=displayName eq '$($C3M04.App)'&`$select=id,appId,displayName,tags").value) | Select-Object -First 1
    if ($s.App) {
        # onPremisesPublishing can't be selected in a list query, only on a single object.
        $s.Publishing = (Get-C3M04Graph "$C3M04Beta/applications/$($s.App.id)?`$select=onPremisesPublishing").onPremisesPublishing
        # A failed read is UNKNOWN, not evidence that a connector group is absent, so it throws.
        $s.AppGroup = Get-C3M04Graph "$C3M04Beta/applications/$($s.App.id)/connectorGroup"
        $s.Segments = @((Get-C3M04Graph "$C3M04Beta/applications/$($s.App.id)/onPremisesPublishing/segmentsConfiguration/microsoft.graph.ipSegmentConfiguration/applicationSegments").value)
        $s.Sp = @((Get-C3M04Graph "$C3M04V1/servicePrincipals?`$filter=appId eq '$($s.App.appId)'&`$select=id,appRoleAssignmentRequired").value) | Select-Object -First 1
        $s.Assigned = if ($s.Sp) { @((Get-C3M04Graph "$C3M04V1/servicePrincipals/$($s.Sp.id)/appRoleAssignedTo").value) } else { @() }
    }
    $s.User = @((Get-C3M04Graph "$C3M04V1/users?`$filter=userPrincipalName eq '$($s.Upn)'&`$select=id,displayName,accountEnabled").value) | Select-Object -First 1
    $s.Policy = @((Get-C3M04Graph "$C3M04V1/identity/conditionalAccess/policies").value | Where-Object displayName -eq $C3M04.Policy) | Select-Object -First 1
    [pscustomobject]$s
}

function Read-C3M04Azure {
    <#
    .SYNOPSIS
    The lab's network security groups and VM power states, read through Azure Resource Manager.
    .DESCRIPTION
    Uses az rest so the objects come back in ARM's own shape (properties.securityRules), which is
    what the review formats. Each URL carries a single query parameter on purpose: on Windows, az
    is a .cmd file, and cmd.exe would split a URL at an ampersand.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId
    )
    $rg = "/subscriptions/$SubscriptionId/resourceGroups/$($C3M04.Group)"
    function Arm([string]$Path) {
        $raw = & az rest --method get --url "https://management.azure.com$Path" --subscription $SubscriptionId -o json --only-show-errors 2>$null
        # The message drops the subscription segment so a failure never prints your subscription ID.
        if ($LASTEXITCODE -ne 0) { throw "Azure Resource Manager read failed: $($Path -replace '^/subscriptions/[^/]+', '')" }
        ($raw -join "`n") | ConvertFrom-Json
    }
    $nsgs = @((Arm "$rg/providers/Microsoft.Network/networkSecurityGroups?api-version=2024-05-01").value)
    $vms = @((Arm "$rg/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01").value)
    $power = foreach ($vm in $vms) {
        $iv = Arm "$($vm.id)/instanceView?api-version=2024-07-01"
        [pscustomobject]@{ Name = $vm.name; Power = (($iv.statuses | Where-Object code -like 'PowerState/*').code -replace 'PowerState/', '') }
    }
    [pscustomobject]@{ Nsgs = $nsgs; Power = @($power) }
}
