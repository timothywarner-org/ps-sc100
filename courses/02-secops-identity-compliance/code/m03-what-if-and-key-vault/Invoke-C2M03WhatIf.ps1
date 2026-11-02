#Requires -Version 7.2

<#
.SYNOPSIS
Runs the same Conditional Access evaluation as the portal's What If tool for the Globomantics
contractor against the ERP gateway, and tells you whether the estate decides what the design claims.
Read-only.

.DESCRIPTION
GLB-SC100-CA-04 excludes GLB-SC100-Contractors, and a policy blade will happily show you that
exclusion whether or not anyone is in the group. What decides access is the combination of every
applicable policy, so this script asks the evaluation engine directly through
POST /v1.0/identity/conditionalAccess/evaluate, the API behind the portal's What If tool.

The result you should see, and why it matters:
    GLB-SC100-CA-01  APPLIES         the all-users MFA policy still covers the contractor
    GLB-SC100-CA-04  doesn't apply   reason: users, which is the exclusion doing its job
So the exclusion is real, and it's also not an MFA bypass, because another policy still applies.
Reading one policy can't tell you that; evaluating the estate can.

THE UNDER-SPECIFICATION TRAP IS CHECKED. Microsoft documents that the evaluation returns "doesn't
apply" when the request omits sign-in details a policy's conditions depend on, with the reason
notEnoughInformation. A check that only looked for "CA-04 doesn't apply" would pass on that failure
and teach the wrong lesson, so notEnoughInformation on a lab policy fails the run and names itself.

It creates nothing and changes nothing.

.PARAMETER TenantId
Optional. The tenant to sign in to. Defaults to AZURE_TENANT_ID when that's set, then to your home tenant.

.EXAMPLE
pwsh -NoProfile -File .\Invoke-C2M03WhatIf.ps1
Evaluates the contractor against the ERP gateway and prints every policy's verdict and reason.

.OUTPUTS
Exit 0 when the evaluation matches the design, 1 when it doesn't or the lab objects are missing.

.NOTES
DELEGATED SCOPES: User.Read, Policy.Read.ConditionalAccess (the documented least privilege for the
evaluate API), User.ReadBasic.All, GroupMember.Read.All and Application.Read.All to resolve the lab
objects by name.

The evaluate API:   https://learn.microsoft.com/graph/api/conditionalaccessroot-evaluate
whatIfAnalysisResult: https://learn.microsoft.com/graph/api/resources/whatifanalysisresult
The What If tool:   https://learn.microsoft.com/entra/identity/conditional-access/what-if-tool
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'shared' 'C2.Graph.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
function Add-Failure { param([string]$Message) $failures.Add($Message); Write-Host "[FAIL] $Message" }

$tenant = Connect-C2Graph -Scopes @('Policy.Read.ConditionalAccess', 'User.ReadBasic.All', 'GroupMember.Read.All', 'Application.Read.All') -TenantId $TenantId
$upn = "glb-sc100-contractor-01@$($tenant.DefaultDomain)"

# --- resolve the lab objects ---------------------------------------------------------
$user = @(Get-C2GraphCollection ('v1.0/users?$select=id,displayName,userPrincipalName&$filter=' + [uri]::EscapeDataString("userPrincipalName eq '$upn'")))[0]
if (-not $user) { Add-Failure "$upn doesn't exist. Run .\Set-C2M03WhatIfFixture.ps1 -Mode Deploy." }
$group = @(Get-C2GraphCollection ('v1.0/groups?$select=id,displayName&$filter=' + [uri]::EscapeDataString("displayName eq 'GLB-SC100-Contractors'")))[0]
if (-not $group) { Add-Failure "GLB-SC100-Contractors doesn't exist. Run .\Set-C2M03WhatIfFixture.ps1 -Mode Deploy." }
$erp = @(Get-C2GraphCollection ('v1.0/servicePrincipals?$select=id,appId,displayName&$filter=' + [uri]::EscapeDataString("displayName eq 'GLB-SC100-ERP-Gateway'")))[0]
if (-not $erp) { Add-Failure "GLB-SC100-ERP-Gateway has no service principal, so What If can't target it. Run .\Set-C2M03WhatIfFixture.ps1 -Mode Deploy." }

if ($user -and $group) {
    $members = @(Get-C2GraphCollection "v1.0/groups/$($group.id)/members?`$select=id")
    if (@($members | Where-Object { $_.id -eq $user.id }).Count) { Write-Host "[OK] The contractor is a member of GLB-SC100-Contractors ($($members.Count) member(s) in all)" }
    else { Add-Failure "The contractor isn't in GLB-SC100-Contractors, so CA-04's exclusion can't reach them." }
}
if ($failures.Count) { Write-Host ''; Write-Host '[STOP] The lab objects are incomplete, so the evaluation was skipped.'; exit 1 }

# --- run the evaluation the portal runs ----------------------------------------------
# Every condition the lab policies read is supplied. An under-specified request is the documented
# cause of a false "doesn't apply", so the request is deliberately complete.
$body = @{
    signInIdentity      = @{ '@odata.type' = '#microsoft.graph.userSignIn'; userId = $user.id }
    signInContext       = @{ '@odata.type' = '#microsoft.graph.applicationContext'; includeApplications = @($erp.appId) }
    signInConditions    = @{
        clientAppType   = 'browser'
        country         = 'US'
        devicePlatform  = 'windows'
        deviceInfo      = @{ isCompliant = $true }
        signInRiskLevel = 'low'
        userRiskLevel   = 'low'
    }
    appliedPoliciesOnly = $false
}
try { $result = Invoke-C2Graph -Method POST -Uri 'v1.0/identity/conditionalAccess/evaluate' -Body $body }
catch {
    Write-Host "[FAIL] The evaluate call was rejected: $(($_.Exception.Message -split [Environment]::NewLine)[0])"
    Write-Host '       That points at the request shape, not the lab objects. The body sent was:'
    Write-Host ($body | ConvertTo-Json -Depth 10)
    Write-Host '       Run the same scenario in the portal What If tool to compare.'
    exit 1
}

$rows = @($result.value)
if (-not $rows.Count) { Write-Host '[FAIL] The evaluation returned no policies.'; exit 1 }
Write-Host ''
Write-Host "Evaluation: $($user.displayName) signing in to GLB-SC100-ERP-Gateway, browser, Windows, compliant device"
foreach ($r in ($rows | Sort-Object { $_.displayName })) {
    $verdict = if ($r.policyApplies) { 'APPLIES       ' } else { 'doesn''t apply ' }
    Write-Host ("  {0}  {1,-58} reason: {2}" -f $verdict, $r.displayName, $r.analysisReasons)
}
Write-Host ''

foreach ($t in @($rows | Where-Object { "$($_.analysisReasons)" -match 'notEnoughInformation' })) {
    if ($t.displayName -like "$script:C2Prefix*") { Add-Failure "$($t.displayName) returned notEnoughInformation: the request omits a condition it reads. That isn't an exclusion." }
    else { Write-Host "[WARN] $($t.displayName) isn't a lab policy and returned notEnoughInformation. It doesn't affect this lab." }
}

$ca01 = @($rows | Where-Object { $_.displayName -eq $script:C2PolicyNames.CA01 })[0]
$ca04 = @($rows | Where-Object { $_.displayName -eq $script:C2PolicyNames.CA04 })[0]
if (-not $ca01) { Add-Failure "CA-01 is missing from the evaluation. Run the Module 2 lab's Deploy." }
elseif (-not $ca01.policyApplies) { Add-Failure "CA-01 doesn't apply ($($ca01.analysisReasons)), but the design says it still covers the contractor." }
else { Write-Host '[OK] CA-01 applies to the contractor: the all-users MFA policy survives the exclusion' }
if (-not $ca04) { Add-Failure 'CA-04 is missing from the evaluation. Run .\Set-C2M03WhatIfFixture.ps1 -Mode Deploy.' }
elseif ($ca04.policyApplies) { Add-Failure "CA-04 applies, so the exclusion isn't reaching the contractor." }
elseif ("$($ca04.analysisReasons)" -notmatch 'users') { Add-Failure "CA-04 doesn't apply, but the reason is $($ca04.analysisReasons), not users. Something other than the exclusion filtered it out." }
else { Write-Host "[OK] CA-04 doesn't apply, reason users: that's the exclusion doing its job" }

Write-Host ''
if ($failures.Count) { Write-Host "[RESULT] $($failures.Count) check(s) failed. The estate doesn't decide what the design claims."; exit 1 }
Write-Host '[RESULT] The exclusion is real, and it isn''t an MFA bypass, because CA-01 still applies.'
Write-Host '         Same evaluation in the portal: Microsoft Entra admin center > Entra ID > Conditional Access > Policies > What If.'
Write-Host '         Then clear Country and Device platform and evaluate again. Read every reason: "not enough'
Write-Host '         information" means you under-described the sign-in, which isn''t the same finding as an exclusion.'
exit 0
