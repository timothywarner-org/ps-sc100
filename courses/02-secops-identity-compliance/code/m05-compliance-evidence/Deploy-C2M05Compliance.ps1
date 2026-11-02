#Requires -Version 7.2

<#
.SYNOPSIS
Plans, assigns, reads back, or removes the NIST SP 800-53 R5.1.1 standard for the SC-100 Course 2,
Module 5 demo.

.DESCRIPTION
The second half of the Module 5 demo, "Walk one obligation to its evidence", reads a regulatory
standard on the Microsoft Defender for Cloud regulatory compliance dashboard and asks what a passing
control actually proves. This assigns that standard to your subscription.

THE INITIATIVE IS RESOLVED LIVE BY DISPLAY NAME. A hardcoded built-in ID is how a lab quietly goes
stale, and resolving it is also the move worth learning: when the name stops matching, the script
stops and lists the NIST initiatives that do exist rather than guessing.

"NOT YET" AND "NEVER" LOOK THE SAME IN THE PORTAL. A new standard takes hours to render on the
dashboard, and a standard with no relevant resources in the subscription never renders at all. Both
show up as a missing row. Show tells them apart by reading the dashboard's data, the policy
evaluation count, and the assignment's age together.

WHAT EACH MODE CHANGES
    Plan    Changes nothing. Resolves the initiative, compiles the template, and runs what-if.
    Deploy  Creates or updates the assignment glb-sc100-nist-r511 at subscription scope, then asks
            Azure Policy to start an evaluation scan. Safe to rerun.
    Show    Changes nothing. Reports the assignment, its age, the policy evaluation count, and the
            standard's passed and failed controls if the dashboard has rendered it.
    Remove  Deletes the assignment, after checking it's the lab's.

.PARAMETER Mode
Plan (the default), Deploy, Show, or Remove.

.PARAMETER InitiativeDisplayName
The built-in initiative to assign. Defaults to NIST SP 800-53 R5.1.1.

.PARAMETER SubscriptionId
Optional. The subscription to work in. Leave it out and the script uses AZURE_SUBSCRIPTION_ID, then
your current Azure CLI subscription.

.PARAMETER TenantId
Optional. The tenant you expect. Defaults to AZURE_TENANT_ID when that's set. The script stops if the
subscription belongs to another tenant.

.PARAMETER SkipMfaCheck
Skip the check for the mfa claim in your Azure token. Use it only if your organization satisfies MFA
in a way the token doesn't show.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C2M05Compliance.ps1 -Mode Deploy
Assigns the standard. Expect the dashboard to show it after several hours, not minutes.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C2M05Compliance.ps1 -Mode Show
Tells you whether the standard has rendered, is still on its way, or looks permanently empty.

.NOTES
PREREQUISITES
    * PowerShell 7.2 or later and the Azure CLI with Bicep, signed in with az login.
    * Resource Policy Contributor, Security Admin or Owner on the subscription to assign the initiative.
COST
    The assignment itself is free. Its Audit definitions assess resources you already have.

Regulatory compliance standards: https://learn.microsoft.com/azure/defender-for-cloud/concept-regulatory-compliance-standards
Azure Policy assignment:         https://learn.microsoft.com/azure/governance/policy/concepts/assignment-structure
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Show', 'Remove')]
    [string]$Mode = 'Plan',

    [ValidateNotNullOrEmpty()]
    [string]$InitiativeDisplayName = 'NIST SP 800-53 R5.1.1',

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId,

    [switch]$SkipMfaCheck
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'shared' 'C2.Auth.ps1')

$template = Join-Path $PSScriptRoot 'iac' 'main.bicep'
$assignmentName = 'glb-sc100-nist-r511'
$marker = 'GLB-SC100 '
$deploymentLocation = 'eastus2'
$deploymentName = 'c2m05-regulatory-standard'
if (-not (Test-Path -LiteralPath $template)) { throw 'The iac folder must sit next to this script and hold main.bicep.' }

Assert-C2AzureCli -Bicep
$null = Invoke-C2Az -Arguments @('bicep', 'build', '--file', $template, '--stdout') -Text
Write-Host '[OK] The template compiles.'

$ctx = Resolve-C2AzureContext -SubscriptionId $SubscriptionId -TenantId $TenantId
Write-C2AzureContext -Context $ctx -Mode $Mode
$sub = $ctx.SubscriptionId
$scope = "/subscriptions/$sub"

function Get-LabAssignment {
    <# The lab's assignment, or nothing. ARM answers 404 when it doesn't exist. #>
    Invoke-C2Arm -Context $ctx -Path "$scope/providers/Microsoft.Authorization/policyAssignments/$assignmentName" -ApiVersion '2024-04-01' -AllowNotFound
}

function Resolve-Initiative {
    <# Finds the built-in initiative by its exact display name, and refuses to guess. #>
    $filter = [uri]::EscapeDataString("policyType eq 'BuiltIn'")
    $sets = @(Invoke-C2Arm -Context $ctx -Path "$scope/providers/Microsoft.Authorization/policySetDefinitions?`$filter=$filter" -ApiVersion '2023-04-01' -All)
    $hit = @($sets | Where-Object { $_.properties.displayName -eq $InitiativeDisplayName })
    if ($hit.Count -eq 1) { return $hit[0] }
    Write-Host "[FAIL] Expected one built-in initiative named '$InitiativeDisplayName' and found $($hit.Count). NIST initiatives that exist:"
    $sets | Where-Object { $_.properties.displayName -match 'NIST' } | ForEach-Object { Write-Host "         $($_.properties.displayName)" }
    throw 'Pick one of the names above and pass it with -InitiativeDisplayName. Never paste a GUID from memory.'
}

function Invoke-ResourceGraph {
    <# One Azure Resource Graph query, scoped to this subscription. #>
    param([string]$Query)
    $r = Invoke-C2Arm -Context $ctx -Path '/providers/Microsoft.ResourceGraph/resources' -ApiVersion '2021-03-01' -Method POST -Body @{ subscriptions = @($sub); query = $Query }
    @($r.data)
}

switch ($Mode) {
    { $_ -in 'Plan', 'Deploy' } {
        $initiative = Resolve-Initiative
        Write-Host "[RESOLVED] $($initiative.properties.displayName), version $($initiative.properties.version), $($initiative.id)"
        if ($Mode -eq 'Plan') {
            $result = Invoke-C2Az -Arguments @('deployment', 'sub', 'what-if', '--location', $deploymentLocation, '--name', $deploymentName,
                '--template-file', $template, '--parameters', "nistSetDefinitionId=$($initiative.id)", '--no-pretty-print') -SubscriptionId $sub
            $changes = @($result.changes)
            Write-Host "[PLAN] what-if: $(@($changes | Group-Object changeType | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ')"
            foreach ($c in $changes) { Write-Host ('  {0,-10}{1}' -f $c.changeType, ($c.resourceId -split '/providers/', 2)[-1]) }
            return
        }
        $existing = Get-LabAssignment
        if ($existing -and "$($existing.properties.displayName)" -notlike "$marker*") {
            throw "An assignment named $assignmentName exists but isn't the lab's. Inspect it before rerunning."
        }
        Assert-C2ArmWriteReady -Context $ctx -Skip:$SkipMfaCheck
        $result = Invoke-C2Az -Arguments @('deployment', 'sub', 'create', '--location', $deploymentLocation, '--name', $deploymentName,
            '--template-file', $template, '--parameters', "nistSetDefinitionId=$($initiative.id)") -SubscriptionId $sub
        if ($result.properties.provisioningState -ne 'Succeeded') { throw "The deployment returned $($result.properties.provisioningState)." }
        Write-Host "[OK] Assigned $($initiative.properties.displayName) as $assignmentName at subscription scope"
        # Shorten the Azure Policy half of the wait. The dashboard keeps its own, longer schedule.
        $null = Invoke-C2Az -Arguments @('policy', 'state', 'trigger-scan', '--no-wait') -SubscriptionId $sub
        Write-Host '[OK] Requested an Azure Policy evaluation scan'
        Write-Host '[WAIT] The dashboard renders a new standard after several hours. Run -Mode Show tomorrow.'
        return
    }

    'Remove' {
        $existing = Get-LabAssignment
        if (-not $existing) { Write-Host "[OK] $assignmentName is already gone"; return }
        if ("$($existing.properties.displayName)" -notlike "$marker*") { throw "$assignmentName exists but isn't the lab's. Left in place." }
        Assert-C2ArmWriteReady -Context $ctx -Skip:$SkipMfaCheck
        $null = Invoke-C2Az -Arguments @('policy', 'assignment', 'delete', '--name', $assignmentName, '--scope', $scope) -SubscriptionId $sub
        Write-Host "[REMOVED] $assignmentName. The standard leaves the dashboard on its next refresh."
        return
    }
}

# ------------------------------------------------------------------ Show
$assignment = Get-LabAssignment
if (-not $assignment) { Write-Host "[--] $assignmentName isn't assigned here. Run -Mode Deploy."; exit 1 }
$created = $assignment.systemData.createdAt
$ageHours = if ($created) { ([datetime]::UtcNow - ([datetime]$created).ToUniversalTime()).TotalHours } else { 0 }
Write-Host ("[OK] {0} is assigned, {1:N1} hours ago, enforcement mode {2}" -f $assignmentName, $ageHours, $assignment.properties.enforcementMode)

$states = @(Invoke-ResourceGraph -Query "policyresources | where type =~ 'microsoft.policyinsights/policystates' | where tolower(tostring(properties.policyAssignmentName)) == '$assignmentName' | summarize evaluated=count(), nonCompliant=countif(tostring(properties.complianceState) =~ 'NonCompliant')")
$evaluated = if ($states.Count) { [int]$states[0].evaluated } else { 0 }
$nonCompliant = if ($states.Count) { [int]$states[0].nonCompliant } else { 0 }
Write-Host "[INFO] Azure Policy has evaluated $evaluated resource state(s) for it; $nonCompliant are non-compliant."

$standards = @(Invoke-ResourceGraph -Query "securityresources | where type =~ 'microsoft.security/regulatorycompliancestandards' | project name, state=tostring(properties.state), passed=toint(properties.passedControls), failed=toint(properties.failedControls), skipped=toint(properties.skippedControls)")
$nist = @($standards | Where-Object { $_.name -match 'NIST' -and $_.name -match '800' -and $_.name -match '53' }) | Select-Object -First 1
Write-Host ''
if ($nist) {
    Write-Host "[OK] The dashboard has rendered $($nist.name): $($nist.passed) passed, $($nist.failed) failed, $($nist.skipped) skipped, state $($nist.state)"
    if (($nist.passed + $nist.failed) -eq 0) { Write-Host '[WARN] No control has been assessed yet. Confirm the subscription holds resources the standard applies to.' }
}
elseif ($ageHours -lt 24) {
    Write-Host ("[WAIT] Not rendered yet, and that's expected: the assignment is {0:N1} hours old. Check again tomorrow." -f $ageHours)
}
else {
    Write-Host ("[WARN] The assignment is {0:N1} hours old and the dashboard still has no NIST row. That points at the standard" -f $ageHours)
    Write-Host '       choice or an empty subscription, not at waiting. Confirm the standard is listed for Azure in the'
    Write-Host "       available-standards table, and that this subscription holds resources it assesses."
}
Write-Host ''
Write-Host 'Open Defender for Cloud > Regulatory compliance and expand one control. Then ask: does a passing'
Write-Host 'automated assessment prove the obligation is met, or only that one technical condition holds today?'
