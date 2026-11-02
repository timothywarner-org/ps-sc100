#Requires -Version 7.2

<#
.SYNOPSIS
Plans, turns on, reads back, or turns off the Defender CSPM plan the SC-100 Course 2, Module 4 demo
reads its privileged-access finding from.

.DESCRIPTION
The second half of the Module 4 demo asks the standing-privilege question one plane over, about
Azure resource roles instead of directory roles. There Microsoft Defender for Cloud does the looking
and hands you a finding, such as "Privileged roles should not have permanent access at the
subscription and resource group level". Findings like that come from the Defender CSPM plan, and the
permissions management extension adds cloud infrastructure entitlement management (CIEM).

This script turns that plan on for your subscription with that extension, and its Show mode lists
the identity and access findings your subscription actually holds. What appears depends on what
Defender for Cloud finds in your subscription, so your list won't match anyone else's. An empty list
isn't proof of a clean estate: an estate the plan never assessed looks exactly the same.

WHAT EACH MODE CHANGES
    Plan    Changes nothing. Compiles the template, prints the plan's current state, and runs what-if.
    Deploy  Turns the Defender CSPM plan to Standard with the permissions management extension on.
            If the plan is already Standard, the script changes nothing, because rewriting a plan you
            configured yourself could switch off extensions you rely on.
    Show    Changes nothing. Prints the plan state and every identity and access assessment, worst first.
    Remove  Turns the Defender CSPM plan back to Free for the WHOLE subscription. It asks you to
            confirm first. Run it only if you turned the plan on for this lab.

.PARAMETER Mode
Plan (the default), Deploy, Show, or Remove.

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
pwsh -NoProfile -File .\Deploy-C2M04Cspm.ps1 -Mode Deploy
Turns on Defender CSPM with the permissions management extension. Wait a day before you expect findings.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C2M04Cspm.ps1 -Mode Show
Lists the identity and access findings Defender for Cloud holds for your subscription.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C2M04Cspm.ps1 -Mode Remove
Turns Defender CSPM back to Free after asking you to confirm.

.NOTES
PREREQUISITES
    * PowerShell 7.2 or later and the Azure CLI with Bicep, signed in with az login.
    * Owner, Contributor or Security Admin on the subscription to change a Defender plan.

COST
    Defender CSPM is a paid plan billed per billable resource in the subscription. Check the
    Defender for Cloud pricing page, and turn the plan back to Free when you're done if you enabled
    it only for this lab.

Defender CSPM:                       https://learn.microsoft.com/azure/defender-for-cloud/concept-cloud-security-posture-management
Permissions management (CIEM):       https://learn.microsoft.com/azure/defender-for-cloud/permissions-management
Identity and access recommendations: https://learn.microsoft.com/azure/defender-for-cloud/recommendations-reference-identity-access
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Plan', 'Deploy', 'Show', 'Remove')]
    [string]$Mode = 'Plan',

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId,

    [switch]$SkipMfaCheck
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'shared' 'C2.Auth.ps1')

$template = Join-Path $PSScriptRoot 'iac' 'main.bicep'
$extension = 'EntraPermissionsManagement'
# Subscription-scope deployments record their metadata in a region. It places nothing there.
$deploymentLocation = 'eastus2'
$deploymentName = 'c2m04-defender-cspm'
$featured = 'Privileged roles should not have permanent access at the subscription and resource group level'
# Match on the words the recommendation blade shows rather than on assessment IDs, which Microsoft can reissue.
$identityPattern = 'permission|entitlement|identit|privileg|overprovision|unused|excessive|MFA|owner|permanent access'
if (-not (Test-Path -LiteralPath $template)) { throw 'The iac folder must sit next to this script and hold main.bicep.' }

Assert-C2AzureCli -Bicep
$null = Invoke-C2Az -Arguments @('bicep', 'build', '--file', $template, '--stdout') -Text
Write-Host '[OK] The template compiles.'

$ctx = Resolve-C2AzureContext -SubscriptionId $SubscriptionId -TenantId $TenantId
Write-C2AzureContext -Context $ctx -Mode $Mode
$sub = $ctx.SubscriptionId

function Get-CspmState {
    <# The plan's tier and whether the permissions management extension is on. #>
    $p = Invoke-C2Az -Arguments @('security', 'pricing', 'show', '--name', 'CloudPosture') -SubscriptionId $sub
    $ext = @($p.extensions | Where-Object { $_.name -eq $extension }) | Select-Object -First 1
    [pscustomobject]@{ Tier = [string]$p.pricingTier; ExtensionOn = [bool]($ext -and "$($ext.isEnabled)" -eq 'True') }
}

$state = Get-CspmState
Write-Host "[INFO] Defender CSPM is $($state.Tier); permissions management extension $(if ($state.ExtensionOn) { 'on' } else { 'off' })"

switch ($Mode) {
    'Plan' {
        $result = Invoke-C2Az -Arguments @('deployment', 'sub', 'what-if', '--location', $deploymentLocation, '--name', $deploymentName,
            '--template-file', $template, '--no-pretty-print') -SubscriptionId $sub
        $changes = @($result.changes)
        Write-Host "[PLAN] what-if: $(@($changes | Group-Object changeType | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ')"
        foreach ($c in $changes) { Write-Host ('  {0,-10}{1}' -f $c.changeType, ($c.resourceId -split '/providers/', 2)[-1]) }
        return
    }

    'Deploy' {
        if ($state.Tier -eq 'Standard') {
            if ($state.ExtensionOn) { Write-Host '[OK] Defender CSPM and the permissions management extension are already on. Nothing to change.' }
            else {
                Write-Host '[WARN] Defender CSPM is already Standard, so this script won''t rewrite your plan settings.'
                Write-Host '       Turn the extension on yourself: Defender for Cloud > Environment settings > your subscription >'
                Write-Host '       Defender CSPM plan > Settings > Permissions Management (CIEM), then Save.'
            }
            return
        }
        Assert-C2ArmWriteReady -Context $ctx -Skip:$SkipMfaCheck
        Write-Host '[DEPLOY] Turning Defender CSPM to Standard with the permissions management extension.'
        $result = Invoke-C2Az -Arguments @('deployment', 'sub', 'create', '--location', $deploymentLocation, '--name', $deploymentName,
            '--template-file', $template) -SubscriptionId $sub
        if ($result.properties.provisioningState -ne 'Succeeded') { throw "The deployment returned $($result.properties.provisioningState)." }
        $after = Get-CspmState
        Write-Host "[OK] Defender CSPM is $($after.Tier); permissions management extension $(if ($after.ExtensionOn) { 'on' } else { 'OFF, check the portal' })"
        Write-Host '[WAIT] Defender for Cloud assesses on its own cycle of roughly 12 to 24 hours. Run -Mode Show tomorrow.'
        Write-Host '[COST] Defender CSPM bills per billable resource. Run -Mode Remove when you are done with the lab.'
        return
    }

    'Remove' {
        if ($state.Tier -ne 'Standard') { Write-Host '[OK] Defender CSPM is already Free.'; return }
        if (-not $PSCmdlet.ShouldProcess("subscription $($ctx.SubscriptionName)", 'Set the Defender CSPM plan to Free for the WHOLE subscription')) {
            Write-Host '[SKIP] Left Defender CSPM as it was.'
            return
        }
        Assert-C2ArmWriteReady -Context $ctx -Skip:$SkipMfaCheck
        $null = Invoke-C2Az -Arguments @('security', 'pricing', 'create', '--name', 'CloudPosture', '--tier', 'free') -SubscriptionId $sub
        Write-Host "[REMOVED] Defender CSPM is now $((Get-CspmState).Tier) on $($ctx.SubscriptionName)."
        return
    }
}

# ------------------------------------------------------------------ Show
if ($state.Tier -ne 'Standard') { Write-Host '[WARN] Defender CSPM is Free here, so plan-dependent findings won''t appear. Run -Mode Deploy first.' }
$all = @(Invoke-C2Arm -Context $ctx -Path "/subscriptions/$sub/providers/Microsoft.Security/assessments" -ApiVersion '2020-01-01' -All)
$matched = @($all | Where-Object { $_.properties.displayName -and $_.properties.displayName -match $identityPattern })
Write-Host ''
Write-Host "IDENTITY AND ACCESS ASSESSMENTS: $($matched.Count) of $($all.Count) on this subscription"
# Unhealthy first, because those are the findings you can open and read.
$order = @{ Unhealthy = 0; Healthy = 1; NotApplicable = 2 }
foreach ($m in ($matched | Sort-Object { if ($order.ContainsKey([string]$_.properties.status.code)) { $order[[string]$_.properties.status.code] } else { 3 } }, { $_.properties.displayName })) {
    $code = [string]$m.properties.status.code
    $label = switch ($code) { 'Unhealthy' { '[FINDING]' } 'Healthy' { '[HEALTHY]' } 'NotApplicable' { '[N/A]    ' } default { "[$code]" } }
    Write-Host "  $label $($m.properties.displayName)"
}
$hit = @($matched | Where-Object { $_.properties.displayName -eq $featured -and $_.properties.status.code -eq 'Unhealthy' })
Write-Host ''
if ($hit.Count) { Write-Host "[OK] The recommendation the demo opens is unhealthy here: $featured" }
elseif (@($matched | Where-Object { $_.properties.status.code -eq 'Unhealthy' }).Count) { Write-Host '[OK] Open any [FINDING] above in Defender for Cloud > Recommendations; each one makes the same architectural point.' }
else {
    Write-Host '[WAIT] No unhealthy identity or access finding yet. If you turned the plan on today, check again after the next'
    Write-Host '       assessment cycle. An empty list isn''t evidence the estate is clean.'
}
Write-Host ''
Write-Host 'Read a finding before you touch the grant: what scope is it about, what severity did Defender give it, and'
Write-Host 'what does it recommend? Then decide what you would need to verify before you remove anything.'
