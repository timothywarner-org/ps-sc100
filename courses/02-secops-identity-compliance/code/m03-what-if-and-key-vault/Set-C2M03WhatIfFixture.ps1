#Requires -Version 7.2

<#
.SYNOPSIS
Plans, deploys, or removes the Microsoft Entra objects the SC-100 Course 2, Module 3 What If
evaluation needs.

.DESCRIPTION
The first half of the Module 3 demo, "Prove what the estate actually decides", asks a question a
policy blade can't answer: when a Globomantics contractor signs in to the ERP gateway, which
Conditional Access policies apply? Reading GLB-SC100-CA-04's exclusion list tells you what one policy
says. The What If evaluation tells you what the whole estate decides, and it needs no sign-in traffic,
so it works on a quiet test tenant. That evaluation needs objects this lab creates:

    * GLB-SC100-Contractors, GLB-SC100-ServiceDesk and GLB-SC100-Plant-Operators: security groups.
    * GLB-SC100-CA-04 Require MFA for all users - strict: report-only, excluding those three groups.
      That exclusion list is the planted defect.
    * GLB-SC100-Contractor-01: a cloud user INSIDE GLB-SC100-Contractors. An exclusion group with no
      members excludes nobody, so without this user the evaluation would contradict the lesson.
    * GLB-SC100-ERP-Gateway: an app registration and its service principal. What If matches on an
      application ID, and an app with no service principal never appears in the target picker.

It builds on the Module 2 lab: GLB-SC100-CA-01, the all-users MFA policy, must already exist, because
the point of the evaluation is that CA-01 still covers the contractor while CA-04 doesn't.

THIS CHANGES A MICROSOFT ENTRA TENANT. Run it only in a test tenant you control, never in production.

THE CONTRACTOR ACCOUNT NEVER SIGNS IN. It exists so an object ID can be handed to a policy
evaluation. Its random password is generated, never printed and never stored, and it gets no license.

WHAT EACH MODE CHANGES
    Plan    Changes nothing and signs in to nothing. Prints what Deploy would create.
    Deploy  Creates whatever is missing, verifies the contractor's membership by reading it back, and
            never overwrites a lab policy that has drifted. Safe to rerun.
    Remove  Deletes CA-04 while it's still report-only, then the contractor, the ERP gateway app
            (which removes its service principal) and the three groups. Each object must carry the
            lab marker. CA-01 to CA-03 belong to the Module 2 lab and stay.

DELEGATED SCOPES, requested per mode and nothing more
    Deploy  User.Read, Policy.Read.All, Policy.ReadWrite.ConditionalAccess, Group.ReadWrite.All,
            Application.ReadWrite.All, User.ReadWrite.All
    Remove  the same set

.PARAMETER Mode
Plan (the default), Deploy, or Remove.

.PARAMETER TenantId
Optional. The tenant to sign in to. Defaults to AZURE_TENANT_ID when that's set, then to your home
tenant. The script prints the tenant name before it changes anything.

.EXAMPLE
pwsh -NoProfile -File .\Set-C2M03WhatIfFixture.ps1 -Mode Deploy
Creates the groups, CA-04, the contractor and the ERP gateway in your test tenant.

.EXAMPLE
pwsh -NoProfile -File .\Set-C2M03WhatIfFixture.ps1 -Mode Remove
Deletes only the objects this script created.

.NOTES
ROLES: Conditional Access Administrator, Groups Administrator, Application Administrator and User
Administrator, or Global Administrator in a test tenant. Activate them before you run Deploy;
activating one after a failure means signing in and consenting again.
LICENSING: Microsoft Entra ID P1 for Conditional Access.

The What If tool:          https://learn.microsoft.com/entra/identity/conditional-access/what-if-tool
The evaluate API:          https://learn.microsoft.com/graph/api/conditionalaccessroot-evaluate
Target resources in CA:    https://learn.microsoft.com/entra/identity/conditional-access/concept-conditional-access-cloud-apps
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Remove')]
    [string]$Mode = 'Plan',

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'shared' 'C2.Graph.ps1')

$groupNames = @('GLB-SC100-Contractors', 'GLB-SC100-ServiceDesk', 'GLB-SC100-Plant-Operators')
$excludedGroup = 'GLB-SC100-Contractors'
$appName = 'GLB-SC100-ERP-Gateway'
$contractorName = 'GLB-SC100-Contractor-01'
$contractorNick = 'glb-sc100-contractor-01'
$scopes = @('Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess', 'Group.ReadWrite.All', 'Application.ReadWrite.All', 'User.ReadWrite.All')

if ($Mode -eq 'Plan') {
    Write-Host '[PLAN] No sign-in and no changes. Deploy creates, in your test tenant:'
    Write-Host "[PLAN]   three security groups: $($groupNames -join ', ')"
    Write-Host "[PLAN]   $($script:C2PolicyNames.CA04), report-only, excluding those groups"
    Write-Host "[PLAN]   cloud user $contractorName ($contractorNick@<your default domain>), no license, random unprinted password"
    Write-Host "[PLAN]   membership: $contractorName in $excludedGroup"
    Write-Host "[PLAN]   app registration and service principal $appName, single tenant, no credentials, no API permissions"
    Write-Host "[PLAN] It requires $($script:C2PolicyNames.CA01) from the Module 2 lab. CA-04's body, with placeholder group IDs:"
    $placeholders = @('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003')
    Get-C2CaPolicies -ExcludedGroupIds $placeholders | Where-Object { $_.displayName -eq $script:C2PolicyNames.CA04 } | ConvertTo-Json -Depth 20
    return
}

$tenant = Connect-C2Graph -Scopes $scopes -TenantId $TenantId
$upn = "$contractorNick@$($tenant.DefaultDomain)"
$policies = @(Get-C2GraphCollection 'v1.0/identity/conditionalAccess/policies')

if ($Mode -eq 'Remove') {
    Remove-C2LabPolicy -Policies $policies -Name $script:C2PolicyNames.CA04
    # Re-read: if CA-04 survived because it was switched on, deleting its groups would leave it pointing at nothing.
    $ca04Left = Find-C2NamedObject @(Get-C2GraphCollection 'v1.0/identity/conditionalAccess/policies') $script:C2PolicyNames.CA04

    $user = @(Get-C2GraphCollection ('v1.0/users?$select=id,userPrincipalName,companyName&$filter=' + [uri]::EscapeDataString("userPrincipalName eq '$upn'")))[0]
    if (-not $user) { Write-Host "[OK] user $upn is already gone" }
    elseif ($user.companyName -ne $script:C2Marker) { Write-Host "[WARN] $upn exists but doesn't carry the lab marker. Left in place." }
    else { Remove-C2GraphObject -Uri "$script:C2UsersPath/$($user.id)" -Label "user $upn" }

    $app = Find-C2NamedObject @(Get-C2GraphCollection 'v1.0/applications?$select=id,appId,displayName,notes') $appName
    if (-not $app) { Write-Host "[OK] app $appName is already gone" }
    elseif ("$($app.notes)" -notlike "$script:C2Marker*") { Write-Host "[WARN] $appName exists but doesn't carry the lab marker. Left in place." }
    else { Remove-C2GraphObject -Uri "v1.0/applications/$($app.id)" -Label "app registration $appName and its service principal" }

    if ($ca04Left) {
        Write-Host "[WARN] CA-04 still exists, so its three groups were left in place. Delete CA-04 by hand, then rerun Remove."
    }
    else {
        $groups = @(Get-C2GraphCollection 'v1.0/groups?$select=id,displayName,description')
        foreach ($name in $groupNames) {
            $g = Find-C2NamedObject $groups $name
            if (-not $g) { Write-Host "[OK] group $name is already gone" }
            elseif ("$($g.description)" -notlike "$script:C2Marker*") { Write-Host "[WARN] $name exists but doesn't carry the lab marker. Left in place." }
            else { Remove-C2GraphObject -Uri "v1.0/groups/$($g.id)" -Label "group $name" }
        }
    }
    Write-Host '[DONE] A deleted user or app registration stays restorable for 30 days. Restore it rather than'
    Write-Host '       rerunning Deploy the same day, because the soft-deleted user still holds its sign-in name.'
    return
}

# ------------------------------------------------------------------ Deploy
if (-not (Find-C2NamedObject $policies $script:C2PolicyNames.CA01)) {
    throw "$($script:C2PolicyNames.CA01) doesn't exist. Run the Module 2 lab first: ..\m02-agent-conditional-access\Set-C2M02AgentAccess.ps1 -Mode Deploy"
}

# 1. The groups. The marker in the description is how a rerun, and Remove, tell our group from a
#    namesake somebody else created.
$groups = @(Get-C2GraphCollection 'v1.0/groups?$select=id,displayName,description,securityEnabled,mailEnabled')
$groupIds = foreach ($name in $groupNames) {
    $g = Find-C2NamedObject $groups $name
    if ($g) {
        if ("$($g.description)" -notlike "$script:C2Marker*" -or -not $g.securityEnabled -or $g.mailEnabled) { throw "Group '$name' exists but isn't the lab's group. Inspect object $($g.id) before rerunning." }
        Write-Host "[EXISTS] group $name"
    }
    else {
        $g = Invoke-C2Graph -Method POST -Uri 'v1.0/groups' -Body @{
            displayName     = $name
            description     = "$script:C2Marker A Conditional Access exclusion in the Module 3 estate."
            mailEnabled     = $false
            mailNickname    = ($name.ToLowerInvariant() -replace '[^a-z0-9]', '')
            securityEnabled = $true
        }
        Write-Host "[CREATED] group $name"
    }
    if (-not $g.id) { throw "Graph returned no ID for $name; inspect the tenant before retrying." }
    $g.id
}

# 2. CA-04, report-only, excluding the three groups.
$body = Get-C2CaPolicies -ExcludedGroupIds @($groupIds) | Where-Object { $_.displayName -eq $script:C2PolicyNames.CA04 }
$policy = Find-C2NamedObject $policies $body.displayName
if ($policy) { Assert-C2Policy $policy $body; Write-Host "[EXISTS] $($body.displayName)" }
else { $policy = Invoke-C2Graph -Method POST -Uri 'v1.0/identity/conditionalAccess/policies' -Body $body; Write-Host "[CREATED] $($body.displayName)" }
if (-not $policy.id) { throw 'Graph returned no policy ID; inspect the tenant before retrying.' }
Assert-C2Policy (Invoke-C2GraphReadback -Uri "v1.0/identity/conditionalAccess/policies/$($policy.id)") $body
Write-Host "[OK] $($body.displayName) is report-only and excludes the three groups"

# 3. The resource. What If matches on the application ID, so the app needs a service principal.
$app = Find-C2NamedObject @(Get-C2GraphCollection 'v1.0/applications?$select=id,appId,displayName,notes') $appName
if ($app) {
    if ("$($app.notes)" -notlike "$script:C2Marker*") { throw "An app named '$appName' exists but isn't the lab's. Inspect object $($app.id) before rerunning." }
    Write-Host "[EXISTS] app registration $appName"
}
else {
    $app = Invoke-C2Graph -Method POST -Uri 'v1.0/applications' -Body @{
        displayName    = $appName
        signInAudience = 'AzureADMyOrg'
        notes          = "$script:C2Marker The What If target resource for Module 3. No credentials, no API permissions, never signed in to."
    }
    Write-Host "[CREATED] app registration $appName"
}
if (-not $app.appId) { throw 'Graph returned no application ID; inspect the tenant before retrying.' }
$sp = @(Get-C2GraphCollection ('v1.0/servicePrincipals?$select=id,appId,displayName&$filter=' + [uri]::EscapeDataString("appId eq '$($app.appId)'")))[0]
if ($sp) { Write-Host '[EXISTS] service principal for the ERP gateway' }
else {
    # Without a service principal the app is invisible to the What If target picker.
    $sp = Invoke-C2Graph -Method POST -Uri 'v1.0/servicePrincipals' -Body @{ appId = $app.appId }
    Write-Host '[CREATED] service principal for the ERP gateway'
}

# 4. The principal. Nobody signs in as this account; the evaluation only needs its object ID.
$user = @(Get-C2GraphCollection ('v1.0/users?$select=id,userPrincipalName,companyName&$filter=' + [uri]::EscapeDataString("userPrincipalName eq '$upn'")))[0]
if ($user) {
    if ($user.companyName -ne $script:C2Marker) { throw "A user named $upn exists but isn't the lab's. Inspect object $($user.id) before rerunning." }
    Write-Host "[EXISTS] user $upn"
}
else {
    $user = Invoke-C2Graph -Method POST -Uri 'v1.0/users' -Body @{
        accountEnabled    = $true
        displayName       = $contractorName
        mailNickname      = $contractorNick
        userPrincipalName = $upn
        jobTitle          = 'Contract maintenance technician'
        companyName       = $script:C2Marker
        passwordProfile   = @{ password = (New-C2LabPassword); forceChangePasswordNextSignIn = $true }
    }
    Write-Host "[CREATED] user $upn"
}
if (-not $user.id) { throw 'Graph returned no user ID; inspect the tenant before retrying.' }

# 5. The membership. The whole evaluation turns on this one row.
$excluded = Find-C2NamedObject @(Get-C2GraphCollection 'v1.0/groups?$select=id,displayName') $excludedGroup
$members = @(Get-C2GraphCollection "v1.0/groups/$($excluded.id)/members?`$select=id")
if (@($members | Where-Object { $_.id -eq $user.id }).Count) { Write-Host "[EXISTS] $contractorName is a member of $excludedGroup" }
else {
    $null = Invoke-C2Graph -Method POST -Uri "v1.0/groups/$($excluded.id)/members/`$ref" -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.id)" }
    Write-Host "[CREATED] membership: $contractorName in $excludedGroup"
}
# Directory writes land on one replica and a read can reach another, so confirm through the retry helper.
$confirm = Invoke-C2GraphReadback -Uri "v1.0/groups/$($excluded.id)/members?`$select=id"
if (-not @($confirm.value | Where-Object { $_.id -eq $user.id }).Count) {
    throw "The read-back doesn't show $contractorName in $excludedGroup yet. Wait a minute and rerun Deploy; it converges."
}

Write-Host ''
Write-Host '[DONE] The What If objects are in place.'
Write-Host "       contractor object ID   $($user.id)"
Write-Host "       ERP gateway app ID     $($app.appId)"
Write-Host "       excluded group ID      $($excluded.id)"
Write-Host '[NEXT] Run .\Invoke-C2M03WhatIf.ps1, then repeat the same evaluation in the portal What If tool.'
