#Requires -Version 7.0

<#
.SYNOPSIS
Plans, deploys, reads, or removes the Globomantics landing zone hierarchy for SC-100 Course 1, Module 3.

.DESCRIPTION
Builds the governance design behind the demo "Two landing zones, one template, two answers" in your own
tenant: a Globomantics management group, a Landing zones group beneath it, and two archetypes, Corp and
Online, carrying the same built-in storage policy with two different effects. Your subscription moves
under Online. iac\main.bicep is the only template source and documents every resource. Once it's built,
Invoke-C1M03Workload.ps1 runs the workload template that succeeds in Online and is denied in Corp.

WHAT EACH MODE CHANGES
    Plan    Changes nothing. Compiles the template and, when the top group already exists, runs a
            management-group what-if.
    Deploy  Creates the top management group if it's missing, records where your subscription sits
            today, deploys the template (three child groups, three policy assignments, and your
            subscription moved under Online), and asks Azure Policy for an on-demand compliance scan.
            Safe to rerun: it converges. Requires -ConfirmSubscriptionMove.
    Show    Changes nothing. Reads the hierarchy, your subscription's current archetype, and each
            assignment's effect and enforcement mode back from Azure.
    Remove  Deletes the storefront resource group the workload script created, deletes the three
            assignments, moves your subscription back to the management group it started in, and
            deletes the four Globomantics groups.

WHAT DEPLOY CHANGES ABOUT YOUR SUBSCRIPTION
    From about five minutes after Deploy finishes, every create or update in your subscription outside
    the allowed regions is refused, and in Corp every storage account that allows public blob access is
    refused too. That's the lab working. Deploy checks the regions your existing resources use first,
    and stops if any of them sits outside -AllowedLocations, because those resources would otherwise
    become impossible to update until Remove runs.

SAFETY RAILS, each one a mistake this script refuses to make
    * Moving a subscription by accident  -> Deploy needs -ConfirmSubscriptionMove.
    * Locking up your existing resources -> Deploy refuses while any existing resource sits in a region
                                            outside -AllowedLocations.
    * Losing track of where it came from -> the subscription's original parent is recorded in the
                                            deployment history, and Remove moves it back there.
    * Wrong subscription or tenant       -> pass -SubscriptionId or -TenantId and it stops before any
                                            write when your Azure CLI context doesn't match.
    * Root-level rights                  -> nothing here needs the Microsoft Entra "elevate access"
                                            toggle or any role at the Tenant Root Group.

.PARAMETER Mode
Plan (the default), Deploy, Show, or Remove.

.PARAMETER SubscriptionId
Optional. The subscription that becomes the governed landing zone. Resolution order: this parameter,
then the AZURE_SUBSCRIPTION_ID environment variable, then your current Azure CLI subscription.

.PARAMETER TenantId
Optional. The Microsoft Entra tenant you expect to be working in. Resolution order: this parameter, then
AZURE_TENANT_ID. When either is set, the script refuses to continue if the subscription belongs to a
different tenant.

.PARAMETER Location
Deployment metadata location for the management-group deployment. Management groups and policy
assignments have no region, but Azure Resource Manager still requires one. Defaults to eastus2.

.PARAMETER AllowedLocations
The regions the org-wide Deny permits. Defaults to eastus2 and eastus. Must include every region your
subscription's existing resources use, and must include eastus2, where the workload template deploys.

.PARAMETER ManagementGroupPrefix
Prefix for the four management group IDs. Defaults to mg-globomantics, which yields mg-globomantics,
mg-globomantics-landingzones, mg-globomantics-corp and mg-globomantics-online.

.PARAMETER StorefrontResourceGroup
The resource group Invoke-C1M03Workload.ps1 creates. Remove deletes it when it carries the course tag.
Defaults to rg-globomantics-storefront.

.PARAMETER ConfirmSubscriptionMove
Deploy only. Your acknowledgment that the lab moves your subscription under a new management group and
assigns a Deny policy above it.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C1M03LandingZones.ps1 -Mode Plan
Compiles the template and shows what a deployment would change. Changes nothing.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C1M03LandingZones.ps1 -Mode Deploy -ConfirmSubscriptionMove
Builds the hierarchy and moves your current Azure CLI subscription under Online.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C1M03LandingZones.ps1 -Mode Deploy -ConfirmSubscriptionMove -AllowedLocations eastus2,eastus,centralus
Same, with Central US added because existing resources in your subscription live there.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C1M03LandingZones.ps1 -Mode Show
Reads the hierarchy and the three assignments back.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C1M03LandingZones.ps1 -Mode Remove
Puts your subscription back where it started and deletes everything the lab created.

.NOTES
PREREQUISITES
    * PowerShell 7 and the Azure CLI, signed in with az login. Install the Bicep CLI with
      az bicep install if you don't already have it.
    * Owner on the subscription, assigned directly rather than inherited from a management group.
      Moving a subscription needs role assignment write on it, and an inherited Owner can only move it
      to groups where you're also Owner.
    * Your tenant must let users create management groups. That's the default; if an administrator
      turned on "Require write permissions for creating new management groups", ask them to create
      the top group and make you its Owner.
    * Use a tenant and subscription you keep for learning. Never run this against production.

COST
    Management groups, policy assignments and the compliance scan are free. The only billable resource
    in the lab is the one storage account Invoke-C1M03Workload.ps1 creates, which costs very little and
    which Remove deletes.

CLEANUP
    pwsh -NoProfile -File .\Deploy-C1M03LandingZones.ps1 -Mode Remove
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Show', 'Remove')]
    [string]$Mode = 'Plan',

    [string]$SubscriptionId,

    [string]$TenantId,

    [ValidatePattern('^[a-z0-9]{3,40}$')]
    [string]$Location = 'eastus2',

    [ValidateNotNullOrEmpty()]
    [ValidateScript({ $_ -notmatch '[^a-z0-9]' })]
    [string[]]$AllowedLocations = @('eastus2', 'eastus'),

    [ValidatePattern('^[A-Za-z0-9._()-]{1,60}$')]
    [string]$ManagementGroupPrefix = 'mg-globomantics',

    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$')]
    [string]$StorefrontResourceGroup = 'rg-globomantics-storefront',

    [switch]$ConfirmSubscriptionMove
)

$ErrorActionPreference = 'Stop'
$courseTag = 'SC100-C1M03'
$deploymentName = 'c1m03-landing-zones'
$guidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$mg = [ordered]@{
    Platform     = $ManagementGroupPrefix
    LandingZones = "$ManagementGroupPrefix-landingzones"
    Corp         = "$ManagementGroupPrefix-corp"
    Online       = "$ManagementGroupPrefix-online"
}
# Assignment name, scope key, and the effect the lab expects. Show and Remove both read this table.
$assignments = @(
    [pscustomobject]@{ Name = 'deny-allowed-locations'; Group = 'Platform'; Effect = 'Deny' }
    [pscustomobject]@{ Name = 'deny-storage-public';    Group = 'Corp';     Effect = 'Deny' }
    [pscustomobject]@{ Name = 'audit-storage-public';   Group = 'Online';   Effect = 'Audit' }
)
$template = Join-Path $PSScriptRoot 'iac' 'main.bicep'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'The Azure CLI (az) isn''t on your PATH. Install it, run az login, then rerun this script.'
}
if (-not (Test-Path -LiteralPath $template)) {
    throw "The iac folder must sit next to this script and hold main.bicep: $template"
}
if ($AllowedLocations -notcontains 'eastus2') {
    throw 'AllowedLocations must include eastus2: the workload template deploys there, and it has to break exactly one rule, not two.'
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
    Asks for JSON, keeps stderr out of the JSON stream, and throws on a non-zero exit with the error
    text attached, so a failed call can never hand back an empty result that looks like "nothing
    exists". Management group and policy commands take no --subscription, so the caller adds it only
    where it applies.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $raw = & az @Arguments --only-show-errors --output json 2>$errFile
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
        throw "az $($Arguments[0..2] -join ' ') failed.$hint`n$err"
    }
    if ($raw) { ($raw -join "`n") | ConvertFrom-Json }
}

function Test-LabAz {
    # True when the command succeeds. For existence checks, where "not found" is an answer, not an error.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $null = & az @Arguments --only-show-errors --output none 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-Arm {
    <#
    .SYNOPSIS
    Calls Azure Resource Manager directly and follows nextLink paging.
    .DESCRIPTION
    Used for the two calls the CLI has no tidy command for: listing every resource's region, and asking
    which management group a subscription sits under. Invoke-WebRequest takes the URL as one string, so
    an & or a $filter inside it can't be split by cmd.exe the way an az rest argument can on Windows.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET'
    )
    $token = (Invoke-LabAz @('account', 'get-access-token', '--resource', 'https://management.azure.com/')).accessToken
    $headers = @{ Authorization = "Bearer $token" }
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $resp = Invoke-WebRequest -Uri $next -Method $Method -Headers $headers -SkipHttpErrorCheck -TimeoutSec 60
        if ($resp.StatusCode -ge 400) { throw "ARM $Method $next returned $($resp.StatusCode): $($resp.Content)" }
        $doc = $resp.Content | ConvertFrom-Json
        foreach ($v in @($doc.value)) { if ($v) { $items.Add($v) } }
        $next = $doc.nextLink
    }
    return $items.ToArray()
}

function Write-Status {
    # The bracketed WORD carries the meaning, so the output reads the same with or without color.
    param([Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string]$Message)
    Write-Host ('[{0}] {1}' -f $Tag, $Message)
}

function Get-SubscriptionParent {
    # The management group the subscription sits under right now, by name. getEntities is the one API
    # that answers this without walking the whole hierarchy from the root.
    $filter = [uri]::EscapeDataString("name eq '$($script:LabSubscriptionId)'")
    $entities = @(Invoke-Arm -Method POST -Uri "https://management.azure.com/providers/Microsoft.Management/getEntities?api-version=2020-05-01&`$filter=$filter")
    $sub = $entities | Where-Object { $_.name -eq $script:LabSubscriptionId } | Select-Object -First 1
    if (-not $sub -or -not $sub.properties.parent.id) { return $null }
    return ($sub.properties.parent.id -split '/')[-1]
}

function Get-RecordedOriginalParent {
    # The parent recorded by the first Deploy, read from the deployment history at the top group.
    if (-not (Test-LabAz @('account', 'management-group', 'show', '--name', $mg.Platform))) { return $null }
    if (-not (Test-LabAz @('deployment', 'mg', 'show', '--management-group-id', $mg.Platform, '--name', $deploymentName))) { return $null }
    $record = Invoke-LabAz @('deployment', 'mg', 'show', '--management-group-id', $mg.Platform, '--name', $deploymentName)
    $value = $record.properties.outputs.originalParentMgId.value
    if ($value) { return $value }
    return $null
}

# Compile first and offline: a template error should stop the run before anything touches Azure.
$null = & az bicep build --file $template --stdout --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "The template didn't compile: $template" }

$accountArgs = @('account', 'show')
if ($script:LabSubscriptionId) { $accountArgs += @('--subscription', $script:LabSubscriptionId) }
$account = Invoke-LabAz $accountArgs
if ($expectedTenant -and $account.tenantId -ne $expectedTenant) {
    throw "Subscription '$($account.name)' belongs to tenant $($account.tenantId), not $expectedTenant. Refusing to continue."
}
# Pin every later call to the subscription just checked, even if the CLI default changes mid-run.
$script:LabSubscriptionId = $account.id
$tenantRootGroup = $account.tenantId   # The Tenant Root Group's name is the tenant ID.
Write-Status 'CONTEXT' "$($account.user.name) | $($account.name) | $Mode"

$labGroupNames = @($mg.Values)
$platformExists = Test-LabAz @('account', 'management-group', 'show', '--name', $mg.Platform)

switch ($Mode) {
    'Plan' {
        if (-not $platformExists) {
            Write-Status 'PLAN' "$($mg.Platform) doesn't exist yet, so there's nothing to what-if against. The template compiled cleanly. Deploy will:"
            Write-Host "  1. Create $($mg.Platform) under your Tenant Root Group (you become its Owner)."
            Write-Host "  2. Create $($mg.LandingZones), $($mg.Corp) and $($mg.Online) beneath it."
            Write-Host "  3. Assign Allowed locations (Deny: $($AllowedLocations -join ', ')) at $($mg.Platform)."
            Write-Host "  4. Assign Storage account public access should be disallowed: Deny at $($mg.Corp), Audit at $($mg.Online)."
            Write-Host "  5. Move subscription '$($account.name)' under $($mg.Online)."
            Write-Status 'NEXT' 'Run -Mode Deploy -ConfirmSubscriptionMove to build it.'
            return
        }
        $paramFile = Join-Path ([System.IO.Path]::GetTempPath()) "c1m03-params-$([guid]::NewGuid().ToString('N')).json"
        try {
            $original = Get-RecordedOriginalParent
            @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'
               parameters = @{ platformMgId = @{ value = $mg.Platform }; landingZonesMgId = @{ value = $mg.LandingZones }
                               corpMgId = @{ value = $mg.Corp }; onlineMgId = @{ value = $mg.Online }
                               governedSubscriptionId = @{ value = $script:LabSubscriptionId }; allowedLocations = @{ value = @($AllowedLocations) }
                               originalParentMgId = @{ value = "$original" } } } | ConvertTo-Json -Depth 6 | Set-Content -Path $paramFile -Encoding utf8
            $result = Invoke-LabAz @('deployment', 'mg', 'what-if', '--management-group-id', $mg.Platform, '--location', $Location,
                                     '--name', $deploymentName, '--template-file', $template, '--parameters', "@$paramFile", '--no-pretty-print')
        }
        finally { Remove-Item -LiteralPath $paramFile -Force -ErrorAction SilentlyContinue }
        $changes = @($result.changes)
        Write-Status 'PLAN' "what-if: $(@($changes | Group-Object changeType | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ')"
        foreach ($c in $changes) { Write-Host ('  {0,-10}{1}' -f $c.changeType, ($c.resourceId -split '/providers/', 2)[-1]) }
        return
    }

    'Deploy' {
        if (-not $ConfirmSubscriptionMove) {
            throw "Deploy moves subscription '$($account.name)' under $($mg.Online) and assigns a Deny policy above it. Rerun with -ConfirmSubscriptionMove once you've read the README."
        }

        # Every region your subscription already uses has to be allowed, or those resources become
        # non-compliant and can't be updated until Remove runs. Read ARM directly, with paging, so a
        # quiet empty answer can't pass this check by accident.
        $resources = @(Invoke-Arm -Uri "https://management.azure.com/subscriptions/$($script:LabSubscriptionId)/resources?api-version=2021-04-01")
        $inUse = @($resources | ForEach-Object { "$($_.location)".ToLower() } | Where-Object { $_ -and $_ -ne 'global' } | Sort-Object -Unique)
        $outside = @($inUse | Where-Object { $_ -notin $AllowedLocations })
        Write-Status 'INFO' "$($resources.Count) existing resource(s) in the subscription, in: $(if ($inUse) { $inUse -join ', ' } else { 'no regional resources' })"
        if ($outside.Count) {
            throw "Existing resources live in $($outside -join ', '), which the Deny would lock. Rerun with -AllowedLocations $((@($AllowedLocations) + $outside) -join ','), or use a subscription you keep only for this lab."
        }
        Write-Status 'OK' "Every region in use is on the allowed list ($($AllowedLocations -join ', '))"

        # The one imperative step: a management-group deployment can't create its own target. Creation
        # is asynchronous, so poll until Resource Manager can resolve the new group.
        if (-not $platformExists) {
            $null = Invoke-LabAz @('account', 'management-group', 'create', '--name', $mg.Platform, '--display-name', 'Globomantics')
            Write-Status 'OK' "Created $($mg.Platform) under the Tenant Root Group"
            $visible = $false
            for ($i = 1; $i -le 12 -and -not $visible; $i++) {
                Start-Sleep -Seconds 5
                $visible = Test-LabAz @('account', 'management-group', 'show', '--name', $mg.Platform)
            }
            if (-not $visible) { throw "$($mg.Platform) was created but isn't resolvable yet. Wait a minute and rerun Deploy; it converges." }
        }

        # Record where the subscription started, exactly once. A rerun reuses the first answer, because
        # by then the subscription already sits under Online.
        $original = Get-RecordedOriginalParent
        if (-not $original) {
            $current = Get-SubscriptionParent
            if ($current -and $current -notin $labGroupNames) { $original = $current }
            else {
                $original = $tenantRootGroup
                Write-Status 'WARN' 'Couldn''t read the subscription''s current parent, so Remove will return it to the Tenant Root Group.'
            }
        }
        Write-Status 'INFO' "Subscription's original parent: $original (Remove moves it back here)"

        # Parameters travel in a file: a JSON array on the command line doesn't survive cmd.exe quoting
        # on Windows.
        $paramFile = Join-Path ([System.IO.Path]::GetTempPath()) "c1m03-params-$([guid]::NewGuid().ToString('N')).json"
        try {
            @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'
               parameters = @{ platformMgId = @{ value = $mg.Platform }; landingZonesMgId = @{ value = $mg.LandingZones }
                               corpMgId = @{ value = $mg.Corp }; onlineMgId = @{ value = $mg.Online }
                               governedSubscriptionId = @{ value = $script:LabSubscriptionId }; allowedLocations = @{ value = @($AllowedLocations) }
                               originalParentMgId = @{ value = $original } } } | ConvertTo-Json -Depth 6 | Set-Content -Path $paramFile -Encoding utf8
            Write-Status 'DEPLOY' "Deploying at $($mg.Platform). Management group operations can take a few minutes."
            $result = Invoke-LabAz @('deployment', 'mg', 'create', '--management-group-id', $mg.Platform, '--location', $Location,
                                     '--name', $deploymentName, '--template-file', $template, '--parameters', "@$paramFile")
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match '(?i)authoriz|permission') {
                throw "The deployment was refused. The usual cause is an Owner role on the subscription that's inherited rather than assigned directly; assign Owner on the subscription itself and rerun.`n$msg"
            }
            throw
        }
        finally { Remove-Item -LiteralPath $paramFile -Force -ErrorAction SilentlyContinue }
        Write-Status 'OK' "Deployment $($result.properties.provisioningState). Subscription '$($account.name)' now sits under $($mg.Online)."

        # An on-demand evaluation brings Audit results forward instead of waiting for the daily sweep.
        # It's asynchronous and slow, so don't wait for it.
        try {
            $null = Invoke-LabAz @('policy', 'state', 'trigger-scan', '--subscription', $script:LabSubscriptionId, '--no-wait')
            Write-Status 'OK' 'Asked Azure Policy for an on-demand compliance scan (it runs in the background).'
        }
        catch { Write-Status 'WARN' 'The on-demand scan was refused. Not a problem; the standard 24-hour sweep picks everything up.' }

        Write-Status 'NEXT' 'Wait about five minutes for the new assignments to take effect. Deny decisions made before then can be wrong in either direction.'
        Write-Status 'NEXT' 'Then run .\Invoke-C1M03Workload.ps1 -ShowTemplate (it should deploy), and .\Invoke-C1M03Workload.ps1 -MoveTo corp (it should be denied).'
        return
    }

    'Show' {
        if (-not $platformExists) { throw "$($mg.Platform) doesn't exist yet. Run -Mode Deploy -ConfirmSubscriptionMove first." }
        Write-Host ''
        Write-Host 'THE HIERARCHY'
        foreach ($key in $mg.Keys) {
            if (Test-LabAz @('account', 'management-group', 'show', '--name', $mg[$key])) {
                $g = Invoke-LabAz @('account', 'management-group', 'show', '--name', $mg[$key])
                $parent = if ($g.details.parent.name) { $g.details.parent.name } else { 'Tenant Root Group' }
                Write-Status 'OK' ('{0,-32} "{1}", parent {2}' -f $mg[$key], $g.displayName, $parent)
            }
            else { Write-Status 'FAIL' ('{0,-32} missing. Rerun -Mode Deploy; it converges.' -f $mg[$key]) }
        }

        $parentNow = Get-SubscriptionParent
        $archetype = switch ($parentNow) { $mg.Online { 'Online' } $mg.Corp { 'Corp' } default { 'neither archetype' } }
        Write-Host ''
        Write-Host 'WHERE YOUR SUBSCRIPTION LIVES'
        $tag = if ($archetype -eq 'neither archetype') { 'WARN' } else { 'OK' }
        Write-Status $tag "'$($account.name)' sits under $parentNow ($archetype). Its archetype decides which storage rule applies."

        Write-Host ''
        Write-Host 'THE RULES, one definition assigned twice under one org-wide rule'
        foreach ($a in $assignments) {
            $scope = "/providers/Microsoft.Management/managementGroups/$($mg[$a.Group])"
            if (-not (Test-LabAz @('policy', 'assignment', 'show', '--name', $a.Name, '--scope', $scope))) {
                Write-Status 'FAIL' ('{0,-24} missing at {1}. Rerun -Mode Deploy.' -f $a.Name, $mg[$a.Group])
                continue
            }
            $pa = Invoke-LabAz @('policy', 'assignment', 'show', '--name', $a.Name, '--scope', $scope)
            $effect = $pa.parameters.effect.value
            # 'Default' is the API value the portal labels "Enabled". DoNotEnforce would let the Corp
            # denial quietly succeed, which looks like the lab working when it isn't.
            $enforced = $pa.enforcementMode -eq 'Default'
            $tag = if ($effect -eq $a.Effect -and $enforced) { 'OK' } else { 'WARN' }
            Write-Status $tag ('{0,-24} at {1,-30} effect {2,-6} enforcement {3}' -f $a.Name, $mg[$a.Group], $effect, $(if ($enforced) { 'Enabled' } else { $pa.enforcementMode }))
            if ($a.Name -eq 'deny-allowed-locations') {
                Write-Host ('  {0,-24} allowed regions: {1}' -f '', (@($pa.parameters.listOfAllowedLocations.value) -join ', '))
            }
        }
        Write-Host ''
        Write-Status 'INFO' 'Some rules are about who you are, and some are about where you live. The org-wide rule reaches every landing zone; each storage rule reaches only its own archetype.'
        return
    }

    'Remove' {
        # 1. The workload's resource group. It holds the storage account from the first workload run.
        if ((Invoke-LabAz @('group', 'exists', '--name', $StorefrontResourceGroup, '--subscription', $script:LabSubscriptionId))) {
            $rg = Invoke-LabAz @('group', 'show', '--name', $StorefrontResourceGroup, '--subscription', $script:LabSubscriptionId)
            if ($rg.tags.course -eq $courseTag) {
                Write-Status 'REMOVE' "Deleting $StorefrontResourceGroup and waiting for it to finish..."
                $null = Invoke-LabAz @('group', 'delete', '--name', $StorefrontResourceGroup, '--subscription', $script:LabSubscriptionId, '--yes')
                Write-Status 'OK' "$StorefrontResourceGroup removed"
            }
            else { Write-Status 'WARN' "$StorefrontResourceGroup exists but isn't tagged course=$courseTag, so it was left alone." }
        }

        # 2. Read the recorded parent BEFORE anything is deleted: the record lives in the top group's
        #    deployment history and goes away with it.
        $original = Get-RecordedOriginalParent
        if (-not $original) { $original = $tenantRootGroup }

        # 3. The assignments first, so nothing in the subscription is refused while the hierarchy
        #    comes down.
        foreach ($a in $assignments) {
            $scope = "/providers/Microsoft.Management/managementGroups/$($mg[$a.Group])"
            if (Test-LabAz @('policy', 'assignment', 'show', '--name', $a.Name, '--scope', $scope)) {
                $null = Invoke-LabAz @('policy', 'assignment', 'delete', '--name', $a.Name, '--scope', $scope)
                Write-Status 'OK' "Deleted assignment $($a.Name) at $($mg[$a.Group])"
            }
        }

        # 4. The subscription goes home. Moving back to the Tenant Root Group needs no rights on the root.
        $parentNow = Get-SubscriptionParent
        if ($parentNow -in $labGroupNames) {
            $null = Invoke-LabAz @('account', 'management-group', 'subscription', 'add', '--name', $original, '--subscription', $script:LabSubscriptionId)
            Write-Status 'OK' "Moved '$($account.name)' back under $original"
        }
        else { Write-Status 'OK' "'$($account.name)' already sits under $(if ($parentNow) { $parentNow } else { 'its original parent' })" }

        # 5. The groups, children before parents, because a group with children refuses to delete.
        foreach ($name in @($mg.Corp, $mg.Online, $mg.LandingZones, $mg.Platform)) {
            if (Test-LabAz @('account', 'management-group', 'show', '--name', $name)) {
                $null = Invoke-LabAz @('account', 'management-group', 'delete', '--name', $name)
                Write-Status 'OK' "Deleted management group $name"
            }
        }

        $final = Get-SubscriptionParent
        Write-Status 'INFO' "'$($account.name)' now sits under $(if ($final) { $final } else { 'an unreported parent; check Management groups in the portal' })."
        return
    }
}
