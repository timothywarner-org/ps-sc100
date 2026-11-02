#Requires -Version 7.2

<#
.SYNOPSIS
Plans, deploys, reads back, or removes the Globomantics standing-versus-eligible privilege contrast
for SC-100 Course 2, Module 4.

.DESCRIPTION
The first half of the Module 4 demo, "Read the grant, then find the evidence", puts standing
privilege next to eligible privilege in Microsoft Entra Privileged Identity Management (PIM) and then
goes looking for the history behind both. This builds that contrast in your test tenant with
deliberately low-privilege roles:

    GLB-SC100-Helpdesk Analyst   ELIGIBLE for Helpdesk Administrator, expiring after 90 days
    GLB-SC100-Plant Operator     ELIGIBLE for Helpdesk Administrator, expiring after 90 days
    GLB-SC100-Legacy Admin       STANDING (permanently active) Directory Readers

The point is the shape of the grant, not its power. An eligible assignment has to be activated, it
expires, and its use leaves activation evidence. A standing assignment is simply on.

THIS SCRIPT NEVER TOUCHES GLOBAL ADMINISTRATOR. It resolves both role definitions live by display
name, because a fixture with hardcoded role IDs is a fixture waiting to point at the wrong role.

THIS CHANGES A MICROSOFT ENTRA TENANT. Run it only in a test tenant you control, never in production.

THE THREE ACCOUNTS NEVER SIGN IN. They exist to hold a role assignment. Each gets a random password
that is never printed or stored, no license, no group and no mailbox.

WHAT EACH MODE CHANGES
    Plan    Changes nothing and signs in to nothing. Prints what Deploy would create.
    Deploy  Creates the three users if they're missing, then the two eligible assignments and the
            standing one. An existing assignment for the same user, role and scope is left alone.
            Safe to rerun.
    Show    Changes nothing. Reads the eligible and standing assignments back with their end dates.
    Remove  Removes the eligible assignments through PIM, deletes the standing assignment, then
            deletes the three users. Each user must carry the lab marker.

DELEGATED SCOPES, requested per mode and nothing more
    Deploy, Remove  User.Read, User.ReadWrite.All, RoleManagement.ReadWrite.Directory
    Show            User.Read, User.Read.All, RoleManagement.Read.Directory

.PARAMETER Mode
Plan (the default), Deploy, Show, or Remove.

.PARAMETER TenantId
Optional. The tenant to sign in to. Defaults to AZURE_TENANT_ID when that's set, then to your home
tenant. The script prints the tenant name before it changes anything.

.EXAMPLE
pwsh -NoProfile -File .\Set-C2M04PrivilegedAccess.ps1 -Mode Deploy
Creates the three users and their assignments in your test tenant.

.EXAMPLE
pwsh -NoProfile -File .\Set-C2M04PrivilegedAccess.ps1 -Mode Show
Shows which grants are eligible, which are standing, and when each one ends.

.NOTES
ROLES: Privileged Role Administrator (to manage the assignments) and User Administrator (to create
the users), or Global Administrator in a test tenant.
LICENSING: PIM requires Microsoft Entra ID P2. A 403 on the eligibility request usually means the
license is missing.

Assign eligibility through the API:  https://learn.microsoft.com/graph/api/rbacapplication-post-roleeligibilityschedulerequests
PIM for Microsoft Entra roles:       https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-how-to-add-role-to-user
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Show', 'Remove')]
    [string]$Mode = 'Plan',

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'shared' 'C2.Graph.ps1')

$eligibleRole = 'Helpdesk Administrator'
$standingRole = 'Directory Readers'
$eligibleDays = 90
$principals = @(
    [pscustomobject]@{ DisplayName = 'GLB-SC100-Helpdesk Analyst'; Nickname = 'glb-sc100-analyst'; Grant = 'Eligible' }
    [pscustomobject]@{ DisplayName = 'GLB-SC100-Plant Operator'; Nickname = 'glb-sc100-operator'; Grant = 'Eligible' }
    [pscustomobject]@{ DisplayName = 'GLB-SC100-Legacy Admin'; Nickname = 'glb-sc100-legacyadmin'; Grant = 'Standing' }
)

function Resolve-RoleDefinitionId {
    <# Looks the role up by display name and refuses to guess when it isn't found. #>
    param([string]$DisplayName)
    $uri = 'v1.0/roleManagement/directory/roleDefinitions?$select=id,displayName&$filter=' + [uri]::EscapeDataString("displayName eq '$DisplayName'")
    $found = @(Get-C2GraphCollection $uri)
    if ($found.Count -ne 1) { throw "Expected one role named '$DisplayName' and found $($found.Count). Refusing to guess." }
    $found[0].id
}

function Get-LabUser {
    <# Finds a lab user by sign-in name, or returns nothing. #>
    param([string]$Upn)
    @(Get-C2GraphCollection ('v1.0/users?$select=id,displayName,userPrincipalName,companyName&$filter=' + [uri]::EscapeDataString("userPrincipalName eq '$Upn'")))[0]
}

function Get-EligibilitySchedule {
    param([string]$PrincipalId, [string]$RoleId)
    $uri = 'v1.0/roleManagement/directory/roleEligibilitySchedules?$filter=' + [uri]::EscapeDataString("principalId eq '$PrincipalId' and roleDefinitionId eq '$RoleId'")
    @(Get-C2GraphCollection $uri)
}

function Get-StandingAssignment {
    param([string]$PrincipalId, [string]$RoleId)
    $uri = 'v1.0/roleManagement/directory/roleAssignments?$filter=' + [uri]::EscapeDataString("principalId eq '$PrincipalId' and roleDefinitionId eq '$RoleId'")
    @(Get-C2GraphCollection $uri)
}

if ($Mode -eq 'Plan') {
    Write-Host '[PLAN] No sign-in and no changes. Deploy creates, in your test tenant:'
    foreach ($p in $principals) {
        $grant = if ($p.Grant -eq 'Eligible') { "ELIGIBLE for $eligibleRole, expiring after $eligibleDays days" } else { "STANDING $standingRole" }
        Write-Host "[PLAN]   $($p.DisplayName) ($($p.Nickname)@<your default domain>): $grant"
    }
    Write-Host '[PLAN] Role IDs are resolved live by display name. Global Administrator is never touched.'
    return
}

# Show reads companyName to recognize the lab's users, and that isn't a basic profile property, so it
# needs User.Read.All rather than User.ReadBasic.All.
$scopeSet = if ($Mode -eq 'Show') { @('User.Read.All', 'RoleManagement.Read.Directory') } else { @('User.ReadWrite.All', 'RoleManagement.ReadWrite.Directory') }
$tenant = Connect-C2Graph -Scopes $scopeSet -TenantId $TenantId
$eligibleRoleId = Resolve-RoleDefinitionId $eligibleRole
$standingRoleId = Resolve-RoleDefinitionId $standingRole
foreach ($p in $principals) { $p | Add-Member -NotePropertyName Upn -NotePropertyValue "$($p.Nickname)@$($tenant.DefaultDomain)" }

switch ($Mode) {
    'Deploy' {
        $created = 0
        foreach ($p in $principals) {
            $user = Get-LabUser $p.Upn
            if ($user) {
                if ($user.companyName -ne $script:C2Marker) { throw "A user named $($p.Upn) exists but isn't the lab's. Inspect object $($user.id) before rerunning." }
                Write-Host "[EXISTS] user $($p.Upn)"
            }
            else {
                $user = Invoke-C2Graph -Method POST -Uri 'v1.0/users' -Body @{
                    accountEnabled    = $true
                    displayName       = $p.DisplayName
                    mailNickname      = $p.Nickname
                    userPrincipalName = $p.Upn
                    companyName       = $script:C2Marker
                    passwordProfile   = @{ password = (New-C2LabPassword); forceChangePasswordNextSignIn = $true }
                }
                Write-Host "[CREATED] user $($p.Upn)"
                $created++
            }
            $p | Add-Member -NotePropertyName Id -NotePropertyValue $user.id
        }
        if ($created) {
            # Entra is eventually consistent. Handing a brand-new object ID straight to role
            # management is how a fixture fails on a tenant where it worked yesterday.
            foreach ($p in $principals) { $null = Invoke-C2GraphReadback -Uri "$script:C2UsersPath/$($p.Id)?`$select=id" }
        }

        foreach ($p in $principals | Where-Object Grant -eq 'Eligible') {
            if ((Get-EligibilitySchedule $p.Id $eligibleRoleId).Count) { Write-Host "[EXISTS] $($p.DisplayName) is eligible for $eligibleRole"; continue }
            $null = Invoke-C2Graph -Method POST -Uri 'v1.0/roleManagement/directory/roleEligibilityScheduleRequests' -Body @{
                action           = 'adminAssign'
                justification    = 'SC-100 Course 2 lab: an eligible, expiring assignment for the standing-versus-eligible review'
                roleDefinitionId = $eligibleRoleId
                principalId      = $p.Id
                directoryScopeId = '/'
                scheduleInfo     = @{
                    startDateTime = [datetime]::UtcNow.ToString('o')
                    expiration    = @{ type = 'afterDuration'; duration = "P$($eligibleDays)D" }
                }
            }
            Write-Host "[CREATED] $($p.DisplayName) is ELIGIBLE for $eligibleRole for $eligibleDays days"
        }

        foreach ($p in $principals | Where-Object Grant -eq 'Standing') {
            if ((Get-StandingAssignment $p.Id $standingRoleId).Count) { Write-Host "[EXISTS] $($p.DisplayName) holds standing $standingRole"; continue }
            $null = Invoke-C2Graph -Method POST -Uri 'v1.0/roleManagement/directory/roleAssignments' -Body @{
                roleDefinitionId = $standingRoleId
                principalId      = $p.Id
                directoryScopeId = '/'
            }
            Write-Host "[CREATED] $($p.DisplayName) holds STANDING $standingRole"
        }
        Write-Host '[NEXT] Run -Mode Show, then open PIM in the Microsoft Entra admin center and filter the Assignments blade by role.'
        return
    }

    'Show' {
        Write-Host ''
        Write-Host 'ELIGIBLE: has to be activated, expires, and leaves activation evidence when used'
        foreach ($p in $principals | Where-Object Grant -eq 'Eligible') {
            $user = Get-LabUser $p.Upn
            if (-not $user) { Write-Host "  [--] $($p.DisplayName) doesn't exist. Run -Mode Deploy."; continue }
            $s = @(Get-EligibilitySchedule $user.id $eligibleRoleId)[0]
            if ($s) {
                $ends = if ($s.scheduleInfo.expiration.endDateTime) { ([datetime]$s.scheduleInfo.expiration.endDateTime).ToUniversalTime().ToString('yyyy-MM-dd') } else { 'never' }
                Write-Host ("  [OK] {0,-28} {1}, status {2}, ends {3}" -f $p.DisplayName, $eligibleRole, $s.status, $ends)
            }
            else { Write-Host ("  [WARN] {0,-28} no eligibility. If it expired, rerun -Mode Deploy." -f $p.DisplayName) }
        }
        Write-Host ''
        Write-Host 'STANDING: on all the time, with nothing to activate and no end date'
        foreach ($p in $principals | Where-Object Grant -eq 'Standing') {
            $user = Get-LabUser $p.Upn
            if (-not $user) { Write-Host "  [--] $($p.DisplayName) doesn't exist. Run -Mode Deploy."; continue }
            if ((Get-StandingAssignment $user.id $standingRoleId).Count) { Write-Host ("  [OK] {0,-28} {1}, permanently active" -f $p.DisplayName, $standingRole) }
            else { Write-Host ("  [WARN] {0,-28} no standing assignment. Run -Mode Deploy." -f $p.DisplayName) }
        }
        Write-Host ''
        Write-Host 'A grant is configuration. Whether anyone USED it is separate evidence, on a different surface with'
        Write-Host 'its own retention window. Go find that evidence for each row before you call any of them unused.'
        return
    }

    'Remove' {
        foreach ($p in $principals) {
            $user = Get-LabUser $p.Upn
            if (-not $user) { Write-Host "[OK] $($p.Upn) is already gone"; continue }
            if ($user.companyName -ne $script:C2Marker) { Write-Host "[WARN] $($p.Upn) exists but doesn't carry the lab marker. Left in place."; continue }
            if ($p.Grant -eq 'Eligible' -and (Get-EligibilitySchedule $user.id $eligibleRoleId).Count) {
                # Eligibility is removed through PIM with an adminRemove request, the mirror of adminAssign.
                $null = Invoke-C2Graph -Method POST -Uri 'v1.0/roleManagement/directory/roleEligibilityScheduleRequests' -Body @{
                    action = 'adminRemove'; justification = 'SC-100 Course 2 lab teardown'
                    roleDefinitionId = $eligibleRoleId; principalId = $user.id; directoryScopeId = '/'
                }
                Write-Host "[REMOVED] eligibility: $($p.DisplayName), $eligibleRole"
            }
            if ($p.Grant -eq 'Standing') {
                foreach ($a in (Get-StandingAssignment $user.id $standingRoleId)) {
                    Remove-C2GraphObject -Uri "v1.0/roleManagement/directory/roleAssignments/$($a.id)" -Label "standing assignment: $($p.DisplayName), $standingRole"
                }
            }
            Remove-C2GraphObject -Uri "$script:C2UsersPath/$($user.id)" -Label "user $($p.Upn)"
        }
        Write-Host '[DONE] A deleted user stays restorable for 30 days and keeps its sign-in name reserved meanwhile.'
        Write-Host '       Restore it rather than rerunning Deploy the same day.'
        return
    }
}
