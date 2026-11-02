#Requires -Version 7.0

<#
.SYNOPSIS
Plans, deploys, reads, or removes the Globomantics AI workload lab for SC-100 Course 1, Module 4.

.DESCRIPTION
Builds the estate behind the demo "Govern AI adoption before you enable it" in your own Azure
subscription: two Microsoft Foundry accounts, each with a project and the same small model deployment.
One is the marketing team's shadow-AI chatbot that nobody reviewed; the other is the order-intake pilot
that came to the architecture board and is blocked at the gate. The only record of that difference is a
tag a human typed, which is the point. iac\main.bicep is the only template source and documents every
resource.

WHAT EACH MODE CHANGES
    Plan    Changes nothing. Compiles the template, checks that your region still offers the pinned
            model version, and runs what-if when the resource group already exists.
    Deploy  Creates rg-globomantics-c1m04 (tagged course=SC100-C1M04) if it's missing, then deploys
            the template into it. Safe to rerun: it converges.
    Show    Changes nothing. Lists the AI workloads the way find-ai-workloads.kql does, with the one
            column that says anything about approval, and the model behind each one.
    Remove  Deletes the resource group, purges the two soft-deleted Foundry accounts so their names
            are free next time, and switches Defender CSPM back off if this lab switched it on.

SAFETY RAILS, each one a mistake this script refuses to make
    * Wrong subscription or tenant   -> pass -SubscriptionId or -TenantId and it stops before any write
                                        when your Azure CLI context doesn't match.
    * Someone else's resource group  -> refuses unless the group carries the course tag.
    * A stale model pin              -> Plan and Deploy check the pinned model version against what your
                                        region offers before anything is created.
    * Turning off YOUR Defender plan -> Remove only reverts Defender CSPM when the resource group tag
                                        says this lab turned it on.

.PARAMETER Mode
Plan (the default), Deploy, Show, or Remove.

.PARAMETER SubscriptionId
Optional. Resolution order: this parameter, then the AZURE_SUBSCRIPTION_ID environment variable, then
your current Azure CLI subscription (az account show). Whichever wins, every later call is pinned to it.

.PARAMETER TenantId
Optional. Resolution order: this parameter, then AZURE_TENANT_ID. When either is set, the script refuses
to continue if the subscription belongs to a different tenant.

.PARAMETER Location
Region for a new resource group. Defaults to eastus2. When the group already exists, the script uses the
group's region instead.

.PARAMETER ResourceGroupName
The lab's resource group. Defaults to rg-globomantics-c1m04. find-ai-workloads.kql filters on this name,
so change the query too if you change it.

.PARAMETER ModelName
The model both accounts deploy. Defaults to the template's pin.

.PARAMETER ModelVersion
The model version both accounts deploy. Defaults to the template's pin. If Plan reports that your region
no longer offers it, pick a current version from the list Plan prints and pass it here.

.PARAMETER EnableDefenderCspm
Deploy only. Turns on the Defender CSPM plan, which discovers Foundry accounts and projects and builds the
AI Bill of Materials. It bills per billable resource across the WHOLE subscription, so it's off unless you
pass this switch. If the plan is already on, the script leaves it alone and Remove leaves it on.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C1M04AIWorkload.ps1 -Mode Plan
Compiles the template, checks the model pin, and shows what a deployment would change.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C1M04AIWorkload.ps1 -Mode Deploy
Deploys the two Foundry accounts into your current Azure CLI subscription.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C1M04AIWorkload.ps1 -Mode Show
Lists the workloads and their governance-state tag.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C1M04AIWorkload.ps1 -Mode Remove
Deletes the lab and purges the soft-deleted accounts.

.NOTES
PREREQUISITES
    * PowerShell 7 and the Azure CLI, signed in with az login. Install the Bicep CLI with
      az bicep install if you don't already have it.
    * Contributor on the subscription. Purging soft-deleted Foundry accounts needs Contributor (or
      Cognitive Services Contributor) assigned at subscription scope, not just on the resource group.
    * Quota for the model's deployment SKU in your region. Plan prints what the region offers.

COST
    Both Foundry accounts use the S0 tier, which carries no standing charge, and model deployments bill
    per token. Nothing in the lab calls the endpoints, so an idle lab costs effectively nothing. Defender
    CSPM, if you turn it on, bills across the whole subscription. Remove the lab when you're done.

CLEANUP
    pwsh -NoProfile -File .\Deploy-C1M04AIWorkload.ps1 -Mode Remove
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Show', 'Remove')]
    [string]$Mode = 'Plan',

    [string]$SubscriptionId,

    [string]$TenantId,

    [ValidatePattern('^[a-z0-9]{3,40}$')]
    [string]$Location = 'eastus2',

    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$')]
    [string]$ResourceGroupName = 'rg-globomantics-c1m04',

    [ValidatePattern('^[A-Za-z0-9._-]{1,64}$')]
    [string]$ModelName = 'gpt-5.4-mini',

    [ValidatePattern('^[A-Za-z0-9._-]{1,32}$')]
    [string]$ModelVersion = '2026-03-17',

    [switch]$EnableDefenderCspm
)

$ErrorActionPreference = 'Stop'
$courseTag = 'SC100-C1M04'
$deploymentName = 'c1m04-ai-workload'
$guidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$template = Join-Path $PSScriptRoot 'iac' 'main.bicep'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'The Azure CLI (az) isn''t on your PATH. Install it, run az login, then rerun this script.'
}
if (-not (Test-Path -LiteralPath $template)) {
    throw "The iac folder must sit next to this script and hold main.bicep: $template"
}

# Explicit parameter first, then the environment variable, then whatever az login selected.
$script:LabSubscriptionId = if ($SubscriptionId) { $SubscriptionId } elseif ($env:AZURE_SUBSCRIPTION_ID) { $env:AZURE_SUBSCRIPTION_ID } else { $null }
$expectedTenant = if ($TenantId) { $TenantId } elseif ($env:AZURE_TENANT_ID) { $env:AZURE_TENANT_ID } else { $null }
if ($script:LabSubscriptionId -and $script:LabSubscriptionId -notmatch $guidPattern) { throw "Subscription ID '$($script:LabSubscriptionId)' isn't a GUID." }
if ($expectedTenant -and $expectedTenant -notmatch $guidPattern) { throw "Tenant ID '$expectedTenant' isn't a GUID." }

function Invoke-LabAz {
    <#
    .SYNOPSIS
    Runs one Azure CLI command and returns its JSON output as objects.
    .DESCRIPTION
    Pins the subscription once one is known, asks for JSON, keeps stderr out of the JSON stream, and
    throws on a non-zero exit with the error text attached, so a failed call can never hand back an
    empty result that looks like "nothing exists".
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)
    $full = @($Arguments)
    if ($script:LabSubscriptionId) { $full += @('--subscription', $script:LabSubscriptionId) }
    $full += @('--only-show-errors', '--output', 'json')
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $raw = & az @full 2>$errFile
        $code = $LASTEXITCODE
        $err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
    }
    finally {
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
    if ($code -ne 0) {
        $hint = ''
        if ("$err" -match 'AADSTS50076') {
            $hint = ' Microsoft Entra wants multifactor authentication for this operation. Sign in again with az login, or run the script from Azure Cloud Shell.'
        }
        elseif ("$err" -match 'ServiceModelDeprecating|DeploymentModelNotSupported|InvalidResourceProperties') {
            $hint = ' The pinned model version may no longer be offered for new deployments here. Run -Mode Plan to see what your region offers, then pass -ModelVersion.'
        }
        throw "az $($Arguments[0..1] -join ' ') failed.$hint`n$err"
    }
    if ($raw) { ($raw -join "`n") | ConvertFrom-Json }
}

function Write-Status {
    # The bracketed WORD carries the meaning, so the output reads the same with or without color.
    param([Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string]$Message)
    Write-Host ('[{0}] {1}' -f $Tag, $Message)
}

function Test-ModelPin {
    <#
    .SYNOPSIS
    Checks that the region still offers the pinned model version, and returns $true when it does.
    .DESCRIPTION
    A pinned version is reproducible right up to the day Microsoft stops offering it for new
    deployments, and nothing warns you in between. Asking the region first turns a failed deployment
    into a one-line fix.
    #>
    param([Parameter(Mandatory)][string]$Region)
    $models = @(Invoke-LabAz @('cognitiveservices', 'model', 'list', '--location', $Region))
    $named = @($models | Where-Object { $_.model.name -eq $ModelName -and $_.model.format -eq 'OpenAI' })
    $match = $named | Where-Object { $_.model.version -eq $ModelVersion } | Select-Object -First 1
    if ($match -and $match.model.lifecycleStatus -ne 'Deprecating' -and $match.model.lifecycleStatus -ne 'Deprecated') {
        Write-Status 'OK' "$Region offers $ModelName $ModelVersion ($($match.model.lifecycleStatus))"
        return $true
    }
    $offered = @($named | ForEach-Object { '{0} ({1})' -f $_.model.version, $_.model.lifecycleStatus } | Sort-Object -Unique)
    $why = if ($match) { "is $($match.model.lifecycleStatus)" } else { "isn't offered" }
    Write-Status 'WARN' "$ModelName $ModelVersion $why in $Region. Versions this region lists: $(if ($offered) { $offered -join ', ' } else { 'none' })"
    Write-Status 'NEXT' 'Rerun with -ModelVersion <a current version above>, or -ModelName for a different small model.'
    return $false
}

# Compile first and offline: a template error should stop the run before anything touches Azure.
$null = & az bicep build --file $template --stdout --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "The template didn't compile: $template" }

$account = Invoke-LabAz @('account', 'show')
if ($expectedTenant -and $account.tenantId -ne $expectedTenant) {
    throw "Subscription '$($account.name)' belongs to tenant $($account.tenantId), not $expectedTenant. Refusing to continue."
}
# Pin every later call to the subscription just checked, even if the CLI default changes mid-run.
$script:LabSubscriptionId = $account.id
Write-Status 'CONTEXT' "$($account.user.name) | $($account.name) | $Mode"

$exists = Invoke-LabAz @('group', 'exists', '--name', $ResourceGroupName)
$labGroup = $null
if ($exists) {
    $labGroup = Invoke-LabAz @('group', 'show', '--name', $ResourceGroupName)
    if ($labGroup.tags.course -ne $courseTag) {
        throw "Ownership mismatch: $ResourceGroupName exists but isn't tagged course=$courseTag. Refusing to touch it."
    }
    $Location = $labGroup.location
}
if ($Mode -eq 'Show' -and -not $exists) { throw "$ResourceGroupName doesn't exist yet. Run -Mode Deploy first." }

function Get-CspmTier {
    # Older CLI builds nest the tier under properties, newer ones flatten it.
    $p = Invoke-LabAz @('security', 'pricing', 'show', '--name', 'CloudPosture')
    if ($p.pricingTier) { return $p.pricingTier }
    return $p.properties.pricingTier
}

switch ($Mode) {
    'Plan' {
        $null = Test-ModelPin -Region $Location
        if (-not $exists) {
            # what-if needs an existing group. Report that instead of creating one in a no-change mode.
            Write-Status 'PLAN' "$ResourceGroupName doesn't exist yet. Deploy creates it with the course tag; the template compiled cleanly."
            return
        }
        $result = Invoke-LabAz @('deployment', 'group', 'what-if', '--resource-group', $ResourceGroupName, '--name', $deploymentName,
                                 '--template-file', $template, '--no-pretty-print',
                                 '--parameters', "modelName=$ModelName", "modelVersion=$ModelVersion")
        $changes = @($result.changes)
        Write-Status 'PLAN' "what-if: $(@($changes | Group-Object changeType | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ')"
        foreach ($c in $changes) { Write-Host ('  {0,-10}{1}' -f $c.changeType, ($c.resourceId -split '/providers/', 2)[-1]) }
        return
    }

    'Deploy' {
        if (-not (Test-ModelPin -Region $Location)) { throw 'Stopping before anything is created: the pinned model version would fail validation.' }

        if (-not $exists) {
            $labGroup = Invoke-LabAz @('group', 'create', '--name', $ResourceGroupName, '--location', $Location,
                                       '--tags', "course=$courseTag", 'company=Globomantics', 'purpose=course-lab')
            Write-Status 'OK' "Created $ResourceGroupName in $Location"
        }

        # Defender CSPM: only switch it on when you asked AND it's off, and tag the group so Remove knows
        # the lab owns that change. Merge keeps the course tag intact.
        if ($EnableDefenderCspm -and $labGroup.tags.'defender-cspm' -ne 'enabled-by-lab') {
            # The plan lives in the Microsoft.Security provider, which a fresh subscription may not have
            # registered yet.
            if ((Invoke-LabAz @('provider', 'show', '--namespace', 'Microsoft.Security')).registrationState -ne 'Registered') {
                $null = Invoke-LabAz @('provider', 'register', '--namespace', 'Microsoft.Security', '--wait')
            }
            if ((Get-CspmTier) -eq 'Standard') {
                Write-Status 'OK' 'Defender CSPM is already on in this subscription. Leaving it exactly as you configured it.'
            }
            else {
                $null = Invoke-LabAz @('security', 'pricing', 'create', '--name', 'CloudPosture', '--tier', 'Standard')
                $null = Invoke-LabAz @('tag', 'update', '--resource-id', $labGroup.id, '--operation', 'Merge', '--tags', 'defender-cspm=enabled-by-lab')
                Write-Status 'COST' 'Turned on Defender CSPM for this subscription. It bills per billable resource until Remove turns it back off.'
            }
        }

        Write-Status 'DEPLOY' 'Deploying two Foundry accounts, their projects and model deployments. This takes a few minutes.'
        $result = Invoke-LabAz @('deployment', 'group', 'create', '--resource-group', $ResourceGroupName, '--name', $deploymentName,
                                 '--template-file', $template, '--parameters', "modelName=$ModelName", "modelVersion=$ModelVersion")
        $o = $result.properties.outputs
        Write-Status 'OK' "Deployment $($result.properties.provisioningState): $(@($o.workloadNames.value) -join ', ')"
        Write-Status 'INFO' $o.modelDeployed.value
        Write-Status 'NEXT' 'Run -Mode Show, or paste iac\find-ai-workloads.kql into Resource Graph Explorer. Resource Graph sees the workloads now.'
        Write-Status 'NEXT' 'Defender for Cloud posture views publish on a daily snapshot, so give them about 24 hours before you look for these workloads there.'
        Write-Status 'COST' 'Idle deployments bill nothing per token, but remove the lab when you''re done.'
        return
    }

    'Show' {
        # The same lookup as find-ai-workloads.kql: type, name, kind, region, and the one governance column.
        $workloads = @(Invoke-LabAz @('resource', 'list', '--resource-group', $ResourceGroupName, '--resource-type', 'Microsoft.CognitiveServices/accounts'))
        Write-Host ''
        Write-Host "THE ESTATE ALREADY KNOWS: $($workloads.Count) AI workload(s) in $ResourceGroupName"
        Write-Host ('  {0,-38} {1,-12} {2,-10} {3}' -f 'name', 'kind', 'location', 'GovernanceState (a tag)')
        foreach ($w in $workloads) {
            Write-Host ('  {0,-38} {1,-12} {2,-10} {3}' -f $w.name, $w.kind, $w.location, $w.tags.'governance-state')
        }
        Write-Host ''
        Write-Host 'WHAT EACH ONE RUNS'
        foreach ($w in $workloads) {
            foreach ($d in @(Invoke-LabAz @('cognitiveservices', 'account', 'deployment', 'list', '--resource-group', $ResourceGroupName, '--name', $w.name))) {
                Write-Host ('  {0,-38} {1} {2} ({3}, {4}K TPM)' -f $w.name, $d.properties.model.name, $d.properties.model.version, $d.sku.name, $d.sku.capacity)
            }
        }
        Write-Host ''
        Write-Status 'INFO' 'Everything above is configuration. There is no column for the data boundary, the shared responsibility line, or who owns the risk.'
        Write-Status 'INFO' 'GovernanceState is a tag somebody typed. Nothing validates it, and deleting it changes nothing about whether either workload serves traffic.'
        Write-Status 'NEXT' 'Open ..\..\demo-artifacts\m04-ai-adoption-gate.html: that gate is where the decisions get written down.'
        return
    }

    'Remove' {
        if (-not $exists) { Write-Status 'OK' "$ResourceGroupName is already absent"; return }
        $cspmByLab = $labGroup.tags.'defender-cspm' -eq 'enabled-by-lab'

        # Capture the account names BEFORE the group goes. Deleted Foundry accounts are soft-deleted and
        # keep their names reserved, so a redeploy into the same group would collide with them.
        $accounts = @(Invoke-LabAz @('cognitiveservices', 'account', 'list', '--resource-group', $ResourceGroupName))
        $recheck = Invoke-LabAz @('group', 'show', '--name', $ResourceGroupName)
        if ($recheck.tags.course -ne $courseTag) { throw 'The course tag changed between checks. Refusing to delete.' }
        Write-Status 'REMOVE' "Deleting $ResourceGroupName and waiting for it to finish..."
        $null = Invoke-LabAz @('group', 'delete', '--name', $ResourceGroupName, '--yes')
        Write-Status 'OK' "$ResourceGroupName removed"

        foreach ($a in $accounts) {
            try {
                $null = Invoke-LabAz @('cognitiveservices', 'account', 'purge', '--location', $a.location, '--resource-group', $ResourceGroupName, '--name', $a.name)
                Write-Status 'OK' "Purged soft-deleted account $($a.name)"
            }
            catch {
                Write-Status 'WARN' "Couldn't purge $($a.name). Purging needs Contributor at subscription scope. Otherwise it's purged automatically after its retention period."
            }
        }

        if ($cspmByLab) {
            $null = Invoke-LabAz @('security', 'pricing', 'create', '--name', 'CloudPosture', '--tier', 'Free')
            Write-Status 'OK' 'Defender CSPM is back on the Free tier, because this lab turned it on.'
        }
        Write-Status 'NEXT' 'Check Cost Management tomorrow to confirm the charges stopped.'
        return
    }
}
