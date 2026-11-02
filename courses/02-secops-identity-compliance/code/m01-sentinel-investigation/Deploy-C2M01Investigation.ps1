#Requires -Version 7.2

<#
.SYNOPSIS
Plans, deploys, reads back, or removes the Globomantics synthetic Microsoft Sentinel investigation
for SC-100 Course 2, Module 1.

.DESCRIPTION
Builds the lab behind the Module 1 demo, "Investigate one incident across three signals", in your
own Azure subscription: a dedicated Log Analytics workspace with Microsoft Sentinel, one scheduled
analytics rule that turns three fictional observations into a real Sentinel alert and incident, and
three MAP ONLY rules that carry MITRE ATT&CK technique metadata over a query that never returns a
row. iac\main.bicep is the only template source and explains every resource.

WHY THE SEED TIME MATTERS
The investigation query keeps rows only for 30 minutes after a fixed seed time. The rule runs every
five minutes, fires once inside that window, and its one-hour suppression stops repeats. After the
window closes the rule keeps running and returns nothing. That's by design, and it's also the trap:
an incident that never appeared looks exactly like a rule that is merely quiet. Show tells the two
apart, and to replay the exercise you deploy again with a new seed.

WHAT EACH MODE CHANGES
    Plan    Changes nothing. Compiles the template and, if the resource group exists, runs what-if.
    Deploy  Registers the Microsoft.OperationalInsights and Microsoft.SecurityInsights resource
            providers if they aren't yet, creates rg-globomantics-c2m01 (tagged course=SC100-C2M01)
            if it's missing, and deploys the template. Safe to rerun.
    Show    Changes nothing. Reads the workspace, the four rules, and the incident the synthetic
            rule produced, with its alerts and its Account, Host and URL entities.
    Remove  Deletes the resource group after re-reading its course tag, and waits for the delete.

SAFETY RAILS, each one a mistake this script refuses to make
    * Wrong subscription or tenant   -> pass -SubscriptionId or -TenantId and it stops before any
                                        write when your Azure CLI context doesn't match.
    * A write the session can't make -> it checks your Azure token for the mfa claim first and
                                        explains the fix, instead of failing halfway through.
    * Someone else's resource group  -> it refuses any rg-globomantics-c2m01 that lacks the course tag.

.PARAMETER Mode
Plan (the default), Deploy, Show, or Remove.

.PARAMETER SeedUtc
The fixed seed time for the synthetic observations. Defaults to now. Deploy prints the value it used;
pass the same value to a rerun when you don't want a new exercise, or let it default to replay one.
A replay inside an hour of the last alert is suppressed by the rule, by design.

.PARAMETER SubscriptionId
Optional. The subscription to work in. Leave it out and the script uses AZURE_SUBSCRIPTION_ID, then
your current Azure CLI subscription (az account show).

.PARAMETER TenantId
Optional. The Microsoft Entra tenant you expect. Defaults to AZURE_TENANT_ID when that's set. When a
value is present, the script refuses to continue if the subscription belongs to another tenant.

.PARAMETER Location
Region for a new resource group. Defaults to eastus2. When the group already exists, its region wins.

.PARAMETER SkipMfaCheck
Skip the check for the mfa claim in your Azure token. Use it only if your organization satisfies MFA
in a way the token doesn't show; a refused write then fails with AADSTS50076 instead.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C2M01Investigation.ps1 -Mode Plan
Compiles the template and shows what a deployment would change. Changes nothing.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C2M01Investigation.ps1 -Mode Deploy
Deploys the lab with a seed of now. The incident appears within about 15 minutes.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C2M01Investigation.ps1 -Mode Show
Reads back the rules and the incident, with its alerts and entities.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C2M01Investigation.ps1 -Mode Remove
Deletes the lab. Disconnect the workspace in the Defender portal first if you connected it.

.NOTES
PREREQUISITES
    * PowerShell 7.2 or later and the Azure CLI with Bicep (az bicep install), signed in with az login.
    * Contributor on the subscription, which covers the resource group, the workspace and the rules.
    * Connecting the workspace to the Microsoft Defender portal is a separate, manual step with its
      own role requirements. See the README.

COST
    The workspace is pay-as-you-go and Microsoft Sentinel bills on data ingested. The lab ingests
    almost nothing, but check the Microsoft Sentinel pricing page for your region, and remove the
    lab the same day.

Sentinel scheduled rule schema:
  https://learn.microsoft.com/azure/templates/microsoft.securityinsights/alertrules
Microsoft Sentinel in the Defender portal:
  https://learn.microsoft.com/azure/sentinel/microsoft-sentinel-defender-portal
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Show', 'Remove')]
    [string]$Mode = 'Plan',

    [datetimeoffset]$SeedUtc = [datetimeoffset]::UtcNow,

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId,

    [ValidatePattern('^[a-z0-9]{3,40}$')]
    [string]$Location = 'eastus2',

    [switch]$SkipMfaCheck
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'shared' 'C2.Auth.ps1')

$group = 'rg-globomantics-c2m01'
$tag = 'SC100-C2M01'
$workspace = 'law-glb-c2m01'
$deploymentName = 'c2m01-investigation'
$syntheticRule = 'GLOB SYNTHETIC Identity endpoint ERP investigation'
$apiVersion = @{ Workspace = '2025-02-01'; Sentinel = '2025-06-01' }
# The template and its query ship beside this script, so the lab works from wherever you unzip it.
$template = Join-Path $PSScriptRoot 'iac' 'main.bicep'
if (-not (Test-Path -LiteralPath $template) -or -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'iac' 'investigation.kql'))) {
    throw 'The iac folder must sit next to this script and hold main.bicep and investigation.kql.'
}

Assert-C2AzureCli -Bicep
# Compile first and offline: a template error should stop the run before anything touches Azure.
$null = Invoke-C2Az -Arguments @('bicep', 'build', '--file', $template, '--stdout') -Text
Write-Host '[OK] The template compiles.'

# Invariant culture on purpose: some cultures change the time separator, and the query needs ISO 8601.
$seed = $SeedUtc.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture)

$ctx = Resolve-C2AzureContext -SubscriptionId $SubscriptionId -TenantId $TenantId
Write-C2AzureContext -Context $ctx -Mode $Mode
$sub = $ctx.SubscriptionId

$exists = [bool](Invoke-C2Az -Arguments @('group', 'exists', '--name', $group) -SubscriptionId $sub)
if ($exists) {
    $current = Invoke-C2Az -Arguments @('group', 'show', '--name', $group) -SubscriptionId $sub
    if ($current.tags.course -ne $tag) { throw "Ownership mismatch: $group exists but isn't tagged course=$tag. Refusing to touch it." }
    $Location = $current.location
}

switch ($Mode) {
    'Plan' {
        Write-Host "[PLAN] Seed (UTC) $seed"
        if (-not $exists) {
            # what-if needs an existing group. Report that instead of creating one in a no-change mode.
            Write-Host "[PLAN] $group doesn't exist yet. Deploy creates it in $Location with the course tag."
            return
        }
        $result = Invoke-C2Az -Arguments @('deployment', 'group', 'what-if', '--resource-group', $group, '--name', $deploymentName,
            '--template-file', $template, '--parameters', "fixtureStartUtc=$seed", "location=$Location", '--no-pretty-print') -SubscriptionId $sub
        $changes = @($result.changes)
        Write-Host "[PLAN] what-if: $(@($changes | Group-Object changeType | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ')"
        foreach ($c in $changes) { Write-Host ('  {0,-10}{1}' -f $c.changeType, ($c.resourceId -split '/providers/', 2)[-1]) }
        return
    }

    'Deploy' {
        Assert-C2ArmWriteReady -Context $ctx -Skip:$SkipMfaCheck
        # A subscription that has never used Sentinel may not have its providers registered yet.
        foreach ($ns in @('Microsoft.OperationalInsights', 'Microsoft.SecurityInsights')) {
            $provider = Invoke-C2Az -Arguments @('provider', 'show', '--namespace', $ns) -SubscriptionId $sub
            if ($provider.registrationState -ne 'Registered') {
                Write-Host "[REGISTER] $ns (a minute or two)"
                $null = Invoke-C2Az -Arguments @('provider', 'register', '--namespace', $ns, '--wait') -SubscriptionId $sub
            }
        }
        if (-not $exists) {
            $null = Invoke-C2Az -Arguments @('group', 'create', '--name', $group, '--location', $Location,
                '--tags', "course=$tag", 'company=Globomantics', 'purpose=course-lab') -SubscriptionId $sub
            Write-Host "[OK] Created $group in $Location"
        }
        Write-Host "[DEPLOY] Workspace, Sentinel onboarding and four rules, seed $seed. Allow a few minutes."
        $result = Invoke-C2Az -Arguments @('deployment', 'group', 'create', '--resource-group', $group, '--name', $deploymentName,
            '--template-file', $template, '--parameters', "fixtureStartUtc=$seed", "location=$Location") -SubscriptionId $sub
        if ($result.properties.provisioningState -ne 'Succeeded') { throw "The deployment returned $($result.properties.provisioningState)." }
        Write-Host "[OK] Deployed. Seed (UTC) $seed. Keep this value if you rerun Deploy and don't want a new exercise."
        Write-Host '[NEXT] Connect law-glb-c2m01 in the Defender portal (see the README), wait about 15 minutes, then run -Mode Show.'
        Write-Host '[COST] The workspace bills on ingestion, and the lab ingests almost nothing. Run -Mode Remove the same day.'
        return
    }

    'Remove' {
        if (-not $exists) { Write-Host "[OK] $group is already absent"; return }
        Assert-C2ArmWriteReady -Context $ctx -Skip:$SkipMfaCheck
        Write-Host "[INFO] If you connected $workspace in the Defender portal, disconnect it there first:"
        Write-Host '       System > Settings > Microsoft Sentinel > Workspaces > Disconnect workspace.'
        # Re-read the tag immediately before the delete, so a tag change between checks can't slip through.
        $recheck = Invoke-C2Az -Arguments @('group', 'show', '--name', $group) -SubscriptionId $sub
        if ($recheck.tags.course -ne $tag) { throw 'The course tag changed between checks; refusing to delete.' }
        Write-Host "[REMOVE] Deleting $group and waiting for it to finish..."
        $null = Invoke-C2Az -Arguments @('group', 'delete', '--name', $group, '--yes') -SubscriptionId $sub
        Write-Host "[REMOVED] $group. Check Cost Management tomorrow to confirm the charges stopped."
        return
    }
}

# ------------------------------------------------------------------ Show reads the live lab
if (-not $exists) { throw "$group doesn't exist yet. Run -Mode Deploy first." }
$base = "/subscriptions/$sub/resourceGroups/$group/providers/Microsoft.OperationalInsights/workspaces/$workspace"
$ws = Invoke-C2Arm -Context $ctx -Path $base -ApiVersion $apiVersion.Workspace -AllowNotFound
if (-not $ws) { throw "The lab is incomplete: $workspace is missing. Run -Mode Deploy again; it converges." }
$onboarded = Invoke-C2Arm -Context $ctx -Path "$base/providers/Microsoft.SecurityInsights/onboardingStates/default" -ApiVersion $apiVersion.Sentinel -AllowNotFound
Write-Host ''
Write-Host "THE WORKSPACE: $workspace, retention $($ws.properties.retentionInDays) days, Sentinel $(if ($onboarded) { 'onboarded' } else { 'NOT onboarded' })"

$rules = @(Invoke-C2Arm -Context $ctx -Path "$base/providers/Microsoft.SecurityInsights/alertRules" -ApiVersion $apiVersion.Sentinel -All)
Write-Host ''
Write-Host 'THE RULES: what each one claims, and what it can prove'
foreach ($r in ($rules | Sort-Object { $_.properties.displayName })) {
    $p = $r.properties
    $state = if ($p.enabled) { 'enabled ' } else { 'DISABLED' }
    $techniques = if ($p.techniques) { @($p.techniques) -join ',' } else { 'none' }
    Write-Host ("  {0}  {1,-52} techniques {2,-6} runs every {3}" -f $state, $p.displayName, $techniques, $p.queryFrequency)
}
Write-Host '  A MAP ONLY rule is enabled and mapped, and its query can never return a row. Mapped isn''t tested.'

$story = @($rules | Where-Object { $_.properties.displayName -eq $syntheticRule })
if ($story.Count -ne 1) { throw "Expected one rule named '$syntheticRule' and found $($story.Count). Run -Mode Deploy again." }

# The incident is the evidence. Find it by the rule that produced it, not by its title, because a
# hand-made incident with the same title would prove nothing.
$incidents = @(Invoke-C2Arm -Context $ctx -Path "$base/providers/Microsoft.SecurityInsights/incidents" -ApiVersion $apiVersion.Sentinel -All)
$matching = @($incidents | Where-Object { @($_.properties.relatedAnalyticRuleIds) -contains $story[0].id } |
    Sort-Object { $_.properties.createdTimeUtc } -Descending)

Write-Host ''
Write-Host 'THE INCIDENT'
if (-not $matching.Count) {
    # Tell "not yet" apart from "the window closed": both look like an empty incident queue.
    $last = Invoke-C2Az -Arguments @('deployment', 'group', 'show', '--resource-group', $group, '--name', $deploymentName) -SubscriptionId $sub
    $rawSeed = $last.properties.outputs.fixtureStartUtc.value
    # ConvertFrom-Json turns an ISO 8601 string into a DateTime on its own, so handle both shapes
    # and keep the value in UTC rather than letting it drift to local time.
    $lastSeed = if ($rawSeed -is [datetime]) { [datetimeoffset]::new($rawSeed.ToUniversalTime()) }
                else { [datetimeoffset]::Parse([string]$rawSeed, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal) }
    $closes = $lastSeed.AddMinutes(30)
    if ([datetimeoffset]::UtcNow -lt $closes.AddMinutes(15)) {
        Write-Host "[WAIT] No incident yet. The seed is $($lastSeed.ToString('u')) and the rule runs every five minutes,"
        Write-Host '       so give it up to 15 minutes after Deploy, then run -Mode Show again.'
        return
    }
    Write-Host "[FAIL] The seed window closed at $($closes.ToString('u')) and no incident was linked to the synthetic rule."
    Write-Host '       Rerun -Mode Deploy to replay with a fresh seed. If that fails too, open the rule in the'
    Write-Host '       Defender portal and read its health and last run before trying again.'
    exit 1
}

$incident = $matching[0]
$ip = $incident.properties
Write-Host "[OK] Incident #$($ip.incidentNumber): $($ip.title)"
Write-Host "     Severity $($ip.severity), status $($ip.status), created $($ip.createdTimeUtc)"
if ($matching.Count -gt 1) { Write-Host "     $($matching.Count) incidents came from this rule; that's the newest. Earlier replays made the others." }

# Listing an incident's alerts and entities is a POST in the Sentinel API, but it only reads.
$alerts = Invoke-C2Arm -Context $ctx -Path "$($incident.id)/alerts" -ApiVersion $apiVersion.Sentinel -Method POST
$entities = Invoke-C2Arm -Context $ctx -Path "$($incident.id)/entities" -ApiVersion $apiVersion.Sentinel -Method POST
$alertCount = @($alerts.value).Count
if ($alertCount -ge 1) { Write-Host "[OK] $alertCount alert(s) behind the incident" } else { Write-Host '[FAIL] The incident has no alert behind it, so it carries no evidence.' }
foreach ($kind in @('Account', 'Host', 'Url')) {
    $hits = @($entities.entities | Where-Object { $_.kind -eq $kind })
    if ($hits.Count) {
        $names = @($hits | ForEach-Object { $_.properties.friendlyName }) -join ', '
        Write-Host ("[OK] {0,-8} entity: {1}" -f $kind, $names)
    }
    else { Write-Host ("[WARN] {0,-8} entity: none. Entity mapping may still be processing; run Show again in a few minutes." -f $kind) }
}
Write-Host ''
Write-Host 'Every row behind this incident is SYNTHETIC TRAINING DATA. It proves the investigation path works,'
Write-Host 'not that three products independently detected an attack.'
Write-Host '[NEXT] Open the incident in the Defender portal: Investigation & response > Incidents & alerts > Incidents.'
