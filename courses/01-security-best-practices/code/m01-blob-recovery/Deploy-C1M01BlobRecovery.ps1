#Requires -Version 7.0

<#
.SYNOPSIS
Plans, deploys, reads, or removes the Globomantics blob recovery lab for SC-100 Course 1, Module 1.

.DESCRIPTION
Builds the estate behind the demo "Evidence a ransomware-resilient recovery design" in your own Azure
subscription: Globomantics order documents in a storage account with operational backup switched on,
an empty restore-target account, and a Backup vault holding a vaulted copy outside the source
account's blast radius. iac\main.bicep is the only template source and documents every resource.

WHAT EACH MODE CHANGES
    Plan    Changes nothing. Compiles the template and runs a subscription-scope what-if.
    Deploy  Registers the two resource providers Azure Backup needs, adds the Azure CLI
            dataprotection extension if it's missing, deploys the template (which creates the
            resource group rg-globomantics-c1m01, tagged course=SC100-C1M01), uploads five small
            fictional order documents, and asks for the first vaulted backup so a recovery point
            exists without waiting for the daily schedule. Safe to rerun: it converges.
    Show    Changes nothing. Reads back the evidence the demo walks through: the operational
            protection on the source account, the empty restore target, who can destroy the
            backups, the vault's immutability and soft delete state, and the recovery points.
    Remove  Unpicks the Backup vault (a vault holding backup data refuses to delete), deletes the
            resource group, and switches Defender CSPM back off if this lab switched it on.

SAFETY RAILS, each one a mistake this script refuses to make
    * Wrong subscription or tenant  -> pass -SubscriptionId or -TenantId and it stops before any
                                       write when your Azure CLI context doesn't match.
    * Someone else's resource group -> refuses unless the group carries the course tag.
    * Locking the vault             -> nothing here ever sets immutability to Locked. That state is
                                       irreversible, and a locked vault can't be deleted until its
                                       recovery points expire.
    * Turning off YOUR Defender plan -> Remove only reverts Defender CSPM when the resource group
                                       tag says this lab turned it on.

.PARAMETER Mode
Plan (the default), Deploy, Show, or Remove.

.PARAMETER SubscriptionId
Optional. The subscription to work in. Resolution order: this parameter, then the
AZURE_SUBSCRIPTION_ID environment variable, then your current Azure CLI subscription (az account show).
Whichever wins, every later call is pinned to it.

.PARAMETER TenantId
Optional. The Microsoft Entra tenant you expect to be working in. Resolution order: this parameter,
then AZURE_TENANT_ID. When either is set, the script refuses to continue if the subscription belongs to
a different tenant.

.PARAMETER Location
Region for a new lab. Defaults to eastus2. When the resource group already exists, the script uses the
group's region instead, because the Backup vault has to share the source account's region.

.PARAMETER ResourceGroupName
The lab's resource group. Defaults to rg-globomantics-c1m01.

.PARAMETER EnableDefenderCspm
Deploy only. Turns on the Defender CSPM plan, which feeds the critical asset classification surface the
demo opens on. It bills per billable resource across the WHOLE subscription, so it's off unless you
pass this switch. If the plan is already on, the script leaves it alone and Remove leaves it on.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C1M01BlobRecovery.ps1 -Mode Plan
Compiles the template and shows what a deployment would change. Changes nothing.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C1M01BlobRecovery.ps1 -Mode Deploy
Deploys the lab into your current Azure CLI subscription in East US 2.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C1M01BlobRecovery.ps1 -Mode Deploy -EnableDefenderCspm
Same, and also turns on Defender CSPM if it's off, so the critical asset surface has data.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C1M01BlobRecovery.ps1 -Mode Show
Reads the lab back and prints the evidence for each design decision.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C1M01BlobRecovery.ps1 -Mode Remove
Deletes the lab. Run it the same day you deploy.

.NOTES
PREREQUISITES
    * PowerShell 7 and the Azure CLI, signed in with az login. Install the Bicep CLI with
      az bicep install if you don't already have it.
    * Owner on the subscription, or Contributor plus User Access Administrator. The template writes
      role assignments for the vault's managed identity, and Contributor alone can't do that.

COST
    This lab creates billable Azure resources: two Standard_LRS storage accounts, and a Backup vault
    whose vaulted blob backup bills per protected instance plus backup storage. The data is a few
    kilobytes of fictional order documents, so it stays small, but it isn't zero. Defender CSPM, if you
    turn it on, bills across the whole subscription. Check the Azure pricing pages for your region and
    remove the lab the same day.

CLEANUP
    pwsh -NoProfile -File .\Deploy-C1M01BlobRecovery.ps1 -Mode Remove
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
    [string]$ResourceGroupName = 'rg-globomantics-c1m01',

    [switch]$EnableDefenderCspm
)

$ErrorActionPreference = 'Stop'
$courseTag = 'SC100-C1M01'
$deploymentName = 'c1m01-blob-recovery'
$guidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
# Roles that can delete a backup instance or rewrite a backup policy. Counting principals that hold
# one of these at the vault is the honest answer to "can a compromised admin destroy our backups?"
$destructiveRoles = @('Owner', 'Contributor', 'Backup Contributor')
# The template ships beside this script, so the lab works from wherever you unzip or clone it.
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
    throws on a non-zero exit, so a failed call can never hand back an empty result that looks like
    "nothing exists". The error text travels with the exception, because callers here make decisions
    on it (a role assignment that hasn't propagated yet, a missing MFA claim).
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$NoSubscription
    )
    $full = @($Arguments)
    if (-not $NoSubscription -and $script:LabSubscriptionId) { $full += @('--subscription', $script:LabSubscriptionId) }
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
        throw "az $($Arguments[0..1] -join ' ') failed.$hint`n$err"
    }
    if ($raw) { ($raw -join "`n") | ConvertFrom-Json }
}

function Write-Status {
    # The bracketed WORD carries the meaning, so the output reads the same with or without color.
    param([Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string]$Message)
    Write-Host ('[{0}] {1}' -f $Tag, $Message)
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

function Get-LabNames {
    <#
    .SYNOPSIS
    Returns the lab's resource names from the deployment record.
    .DESCRIPTION
    The storage account names carry a suffix the template derives from the resource group ID, so the
    script reads them from the deployment's outputs instead of guessing them.
    #>
    $record = Invoke-LabAz @('deployment', 'sub', 'show', '--name', $deploymentName)
    $o = $record.properties.outputs
    [pscustomobject]@{
        Source    = $o.sourceAccountName.value
        Restore   = $o.restoreAccountName.value
        Vault     = $o.vaultName.value
        Instance  = $o.backupInstanceName.value
        Rule      = $o.backupRuleName.value
        Container = $o.ordersContainerName.value
    }
}

function Get-CspmTier {
    # Older CLI builds nest the tier under properties, newer ones flatten it.
    $p = Invoke-LabAz @('security', 'pricing', 'show', '--name', 'CloudPosture')
    if ($p.pricingTier) { return $p.pricingTier }
    return $p.properties.pricingTier
}

switch ($Mode) {
    'Plan' {
        # A subscription-scope what-if works before the resource group exists, so Plan always runs.
        $cspmParam = 'enableDefenderCspm=false'
        if ($labGroup -and $labGroup.tags.'defender-cspm' -eq 'enabled-by-lab') { $cspmParam = 'enableDefenderCspm=true' }
        $result = Invoke-LabAz @('deployment', 'sub', 'what-if', '--name', $deploymentName, '--location', $Location,
                                 '--template-file', $template, '--no-pretty-print',
                                 '--parameters', "resourceGroupName=$ResourceGroupName", "location=$Location", $cspmParam)
        $changes = @($result.changes)
        Write-Status 'PLAN' "what-if: $(@($changes | Group-Object changeType | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ')"
        foreach ($c in $changes) { Write-Host ('  {0,-10}{1}' -f $c.changeType, ($c.resourceId -split '/providers/', 2)[-1]) }
        Write-Status 'NEXT' 'Run -Mode Deploy to build it. Add -EnableDefenderCspm only if you want the critical asset surface and accept the subscription-wide charge.'
        return
    }

    'Deploy' {
        # Microsoft.DataProtection is the Backup vault provider. Microsoft.RecoveryServices has to be
        # registered too, or the vault's immutability settings never appear in the portal, and nothing
        # tells you why. Defender CSPM lives in Microsoft.Security, which a fresh subscription may not have
        # registered. Registration is idempotent, so checking first only saves time.
        $providers = @('Microsoft.DataProtection', 'Microsoft.RecoveryServices')
        if ($EnableDefenderCspm) { $providers += 'Microsoft.Security' }
        foreach ($ns in $providers) {
            $state = (Invoke-LabAz @('provider', 'show', '--namespace', $ns)).registrationState
            if ($state -ne 'Registered') {
                Write-Status 'DEPLOY' "Registering $ns. This can take a few minutes."
                $null = Invoke-LabAz @('provider', 'register', '--namespace', $ns, '--wait')
            }
            Write-Status 'OK' "$ns is registered"
        }

        # The backup commands live in a CLI extension. Adding it up front avoids an install prompt
        # halfway through the run.
        $null = & az extension show --name dataprotection --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Status 'DEPLOY' 'Adding the Azure CLI dataprotection extension.'
            $null = Invoke-LabAz @('extension', 'add', '--name', 'dataprotection') -NoSubscription
        }

        # Defender CSPM: only switch it on when you asked AND it's off. A redeploy keeps the lab's tag,
        # so Remove still knows the lab owns that change.
        $cspmByLab = [bool]($labGroup -and $labGroup.tags.'defender-cspm' -eq 'enabled-by-lab')
        if ($EnableDefenderCspm -and -not $cspmByLab) {
            $tier = Get-CspmTier
            if ($tier -eq 'Standard') {
                Write-Status 'OK' 'Defender CSPM is already on in this subscription. Leaving it exactly as you configured it.'
            }
            else {
                $cspmByLab = $true
                Write-Status 'COST' 'Turning on Defender CSPM for this subscription. It bills per billable resource until Remove turns it back off.'
            }
        }

        # A brand-new role assignment can take a minute or two to reach Azure Backup, and the backup
        # instance fails if it lands first. One retry after a pause fixes that; everything else in the
        # template converges as a no-op on the second pass.
        $arguments = @('deployment', 'sub', 'create', '--name', $deploymentName, '--location', $Location,
                       '--template-file', $template,
                       '--parameters', "resourceGroupName=$ResourceGroupName", "location=$Location", "enableDefenderCspm=$($cspmByLab.ToString().ToLower())")
        $result = $null
        for ($attempt = 1; $attempt -le 2 -and -not $result; $attempt++) {
            try {
                Write-Status 'DEPLOY' "Deploying the template (attempt $attempt). This takes a few minutes."
                $result = Invoke-LabAz $arguments
            }
            catch {
                if ($attempt -eq 1 -and $_.Exception.Message -match '(?i)permission|authoriz|RoleAssignment|UserErrorMissingRequiredPermissions') {
                    Write-Status 'WARN' 'The backup instance raced its role assignment. Waiting 90 seconds, then retrying.'
                    Start-Sleep -Seconds 90
                }
                else { throw }
            }
        }
        Write-Status 'OK' "Deployment $($result.properties.provisioningState)"
        $names = Get-LabNames

        # Sample data. Five tiny fictional order documents. --auth-mode key makes the CLI fetch the
        # account key itself, so no data-plane role assignment (and no wait for one) is needed and the
        # key never lands in a variable or the console.
        $dataDir = Join-Path ([System.IO.Path]::GetTempPath()) 'globomantics-c1m01-orders'
        $null = New-Item -ItemType Directory -Path $dataDir -Force
        $orders = @(
            [ordered]@{ orderId = 'ORD-2026-08471'; customer = 'Meridian Auto Group';  item = 'GX-9 robotic welding arm'; qty = 4;  plant = 'Nashville'; status = 'in-fulfillment' }
            [ordered]@{ orderId = 'ORD-2026-08488'; customer = 'Cascade Aerospace';    item = 'GX-5 pick-and-place unit'; qty = 12; plant = 'Nashville'; status = 'in-fulfillment' }
            [ordered]@{ orderId = 'ORD-2026-08502'; customer = 'Blue Harbor Foods';    item = 'GS-2 palletizer';          qty = 2;  plant = 'Knoxville'; status = 'scheduled' }
            [ordered]@{ orderId = 'ORD-2026-08517'; customer = 'Ironline Fabrication'; item = 'GX-9 robotic welding arm'; qty = 1;  plant = 'Knoxville'; status = 'received' }
        )
        foreach ($o in $orders) { $o | ConvertTo-Json | Set-Content -Path (Join-Path $dataDir "$($o.orderId).json") -Encoding utf8 }
        $manifest = @('orderId,customer,qty,plant,status') + @($orders | ForEach-Object { '{0},{1},{2},{3},{4}' -f $_.orderId, $_.customer, $_.qty, $_.plant, $_.status })
        $manifest | Set-Content -Path (Join-Path $dataDir 'order-manifest.csv') -Encoding utf8
        try {
            $null = Invoke-LabAz @('storage', 'blob', 'upload-batch', '--destination', $names.Container, '--source', $dataDir,
                                   '--account-name', $names.Source, '--auth-mode', 'key', '--overwrite')
            Write-Status 'OK' "Uploaded $($orders.Count + 1) fictional order documents to $($names.Source)/$($names.Container)"
        }
        catch {
            # The usual cause is a policy in your tenant that disables shared key access. The lab still
            # works without sample data; the backup just protects an empty container.
            Write-Status 'WARN' "Couldn't upload the sample documents with the account key. The lab works without them. Detail: $($_.Exception.Message.Split("`n")[0])"
        }
        finally {
            Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        # An on-demand backup is an ACTION, not a resource, so the template can't express it. It gives
        # you a recovery point today instead of at the next 08:00 UTC run.
        try {
            $null = Invoke-LabAz @('dataprotection', 'backup-instance', 'adhoc-backup', '--resource-group', $ResourceGroupName,
                                   '--vault-name', $names.Vault, '--name', $names.Instance,
                                   '--rule-name', $names.Rule, '--retention-tag-override', 'Default')
            Write-Status 'OK' 'Asked for the first vaulted backup. The job takes a few minutes.'
        }
        catch {
            Write-Status 'WARN' 'The on-demand backup was refused, usually because the instance is still configuring. Rerun -Mode Deploy in a few minutes, or let the daily 08:00 UTC run take the first recovery point.'
        }

        Write-Status 'NEXT' 'Run -Mode Show once the backup job finishes, to read back every piece of evidence.'
        Write-Status 'NEXT' 'Classify the order storage account as a critical asset yourself: Microsoft Defender portal > Settings > Microsoft XDR > Rules > Critical asset management. The README has the steps.'
        Write-Status 'COST' 'The lab bills from now on. Run -Mode Remove the same day.'
        return
    }

    'Show' {
        $names = Get-LabNames
        $rgPath = "/subscriptions/$($script:LabSubscriptionId)/resourceGroups/$ResourceGroupName"
        Write-Host ''
        Write-Host "WHAT MATTERS: the Globomantics order documents in $($names.Source)"

        # Operational protection lives ON the source account, which is the whole problem with it.
        $bp = Invoke-LabAz @('storage', 'account', 'blob-service-properties', 'show', '--account-name', $names.Source, '--resource-group', $ResourceGroupName)
        $checks = [ordered]@{
            'Blob soft delete'      = [bool]$bp.deleteRetentionPolicy.enabled
            'Versioning'            = [bool]$bp.isVersioningEnabled
            'Change feed'           = [bool]$bp.changeFeed.enabled
            'Point-in-time restore' = [bool]$bp.restorePolicy.enabled
        }
        foreach ($k in $checks.Keys) {
            $tag = if ($checks[$k]) { 'OK' } else { 'WARN' }
            $word = if ($checks[$k]) { 'on' } else { 'off' }
            Write-Status $tag ('{0,-22} {1}' -f $k, $word)
        }
        Write-Host '  Every one of those is a property of the source account, so it sits inside the blast radius of whoever controls that account.'

        # Who can already break it: principals that can delete a backup instance or rewrite a policy.
        $vaultObj = Invoke-LabAz @('dataprotection', 'backup-vault', 'show', '--resource-group', $ResourceGroupName, '--vault-name', $names.Vault)
        $assignments = @(Invoke-LabAz @('role', 'assignment', 'list', '--scope', $vaultObj.id, '--include-inherited') |
                         Where-Object { $_.roleDefinitionName -in $destructiveRoles })
        Write-Host ''
        Write-Host "WHO CAN DESTROY THE BACKUPS TODAY: role assignments on $($names.Vault) at Backup Contributor or above"
        foreach ($a in $assignments) {
            $where = if ($a.scope -eq $vaultObj.id) { 'assigned on the vault' } else { "inherited from $($a.scope)" }
            Write-Host ('  {0,-20} {1,-18} {2}' -f $a.roleDefinitionName, $a.principalType, $where)
        }
        Write-Status 'INFO' "$(@($assignments | Select-Object -ExpandProperty principalId -Unique).Count) principal(s). That count is the real answer to 'can a compromised administrator eliminate our recovery points?'"

        # The recovery architecture: a vaulted copy, and a restore target that already exists.
        $instances = @(Invoke-LabAz @('dataprotection', 'backup-instance', 'list', '--resource-group', $ResourceGroupName, '--vault-name', $names.Vault))
        Write-Host ''
        Write-Host "THE RECOVERY PATH: vaulted backup in Backup vault $($names.Vault)"
        foreach ($bi in $instances) {
            $state = $bi.properties.currentProtectionState
            $tag = if ($state -eq 'ProtectionConfigured') { 'OK' } else { 'WARN' }
            Write-Status $tag ('{0,-22} {1}' -f 'Protection state', $state)
            $points = @(Invoke-LabAz @('dataprotection', 'recovery-point', 'list', '--resource-group', $ResourceGroupName,
                                       '--vault-name', $names.Vault, '--backup-instance-name', $bi.name))
            $tag = if ($points.Count -gt 0) { 'OK' } else { 'WARN' }
            Write-Status $tag ('{0,-22} {1}' -f 'Recovery points', $points.Count)
        }
        $targetContainers = @(Invoke-LabAz @('storage', 'container-rm', 'list', '--storage-account', $names.Restore, '--resource-group', $ResourceGroupName))
        $tag = if ($targetContainers.Count -eq 0) { 'OK' } else { 'WARN' }
        Write-Status $tag ('{0,-22} {1} exists and holds {2} container(s)' -f 'Restore target', $names.Restore, $targetContainers.Count)
        Write-Host '  Vaulted restore refuses the source account and fails on a container name collision, so this account has to exist, stay empty, and carry'
        Write-Host '  the vault identity''s Storage Account Backup Contributor role before the incident.'

        # Hardening, and what the platform will grade it as.
        $sec = $vaultObj.properties.securitySettings
        $imm = if ($sec.immutabilitySettings.state) { $sec.immutabilitySettings.state } else { 'Disabled' }
        $sd = $sec.softDeleteSettings
        Write-Host ''
        Write-Host 'HARDENING THE RECOVERY PATH'
        $immWord = switch ($imm) { 'Unlocked' { 'Enabled (reversible: a Backup Contributor can turn it off)' } 'Locked' { 'Enabled and locked (irreversible)' } default { 'Disabled' } }
        Write-Status 'INFO' ('{0,-22} {1}' -f 'Vault immutability', $immWord)
        Write-Status 'INFO' ('{0,-22} {1}, {2} day(s) retention' -f 'Soft delete', $sd.state, $sd.retentionDurationInDays)
        Write-Host '  Only the irreversible versions (locked immutability, or always-on soft delete) plus Multi-User Authorization reach the top security level'
        Write-Host '  in Resiliency in Azure. Open Resiliency > Manage > Vaults in the portal to see the level the platform gives this vault.'
        Write-Host ''
        Write-Status 'INFO' "Resource group: $rgPath"
        return
    }

    'Remove' {
        if (-not $exists) { Write-Status 'OK' "$ResourceGroupName is already absent"; return }
        $cspmByLab = $labGroup.tags.'defender-cspm' -eq 'enabled-by-lab'

        # A Backup vault that still holds backup data refuses to delete, and the resource group delete
        # then fails with a message that never mentions the vault. So unpick each vault first, in the
        # order Azure Backup allows: immutability off, soft delete off, then the backup instances.
        $softDeleteStuck = $false
        $vaults = @(Invoke-LabAz @('dataprotection', 'backup-vault', 'list', '--resource-group', $ResourceGroupName))
        foreach ($listed in $vaults) {
            # Read each vault individually: the show call is the one that reliably carries securitySettings.
            $v = Invoke-LabAz @('dataprotection', 'backup-vault', 'show', '--resource-group', $ResourceGroupName, '--vault-name', $listed.name)
            $sec = $v.properties.securitySettings
            if ($sec.immutabilitySettings.state -eq 'Locked') {
                throw "Vault $($v.name) has immutability LOCKED. That's irreversible: its recovery points can't be deleted before they expire, so the lab can't be removed today. Rerun Remove after the 30-day retention ends."
            }
            if ($sec.immutabilitySettings.state -eq 'Unlocked') {
                # Immutability blocks "stop protection and delete data", so it has to go first.
                $null = Invoke-LabAz @('dataprotection', 'backup-vault', 'update', '--resource-group', $ResourceGroupName, '--vault-name', $v.name, '--immutability-state', 'Disabled')
                Write-Status 'OK' "Disabled immutability on $($v.name)"
            }
            if ($sec.softDeleteSettings.state -eq 'On') {
                $null = Invoke-LabAz @('dataprotection', 'backup-vault', 'update', '--resource-group', $ResourceGroupName, '--vault-name', $v.name, '--soft-delete-state', 'Off')
                Write-Status 'OK' "Turned soft delete off on $($v.name), so deleted backups go away now instead of in two weeks"
            }
            elseif ($sec.softDeleteSettings.state -eq 'AlwaysOn') {
                $softDeleteStuck = $true
                Write-Status 'WARN' "Soft delete on $($v.name) is always-on, which is permanent. Deleted backup data stays for the $($sec.softDeleteSettings.retentionDurationInDays)-day retention, and the vault can't be deleted until it's gone."
            }

            foreach ($bi in @(Invoke-LabAz @('dataprotection', 'backup-instance', 'list', '--resource-group', $ResourceGroupName, '--vault-name', $v.name))) {
                $null = Invoke-LabAz @('dataprotection', 'backup-instance', 'delete', '--resource-group', $ResourceGroupName, '--vault-name', $v.name, '--name', $bi.name, '--yes')
                Write-Status 'OK' "Deleted backup instance $($bi.name)"
            }

            # Anything deleted while soft delete was still on is sitting in the soft-deleted state.
            # With soft delete now off, undeleting and deleting again removes it for good.
            if (-not $softDeleteStuck) {
                foreach ($d in @(Invoke-LabAz @('dataprotection', 'backup-instance', 'deleted-backup-instance', 'list', '--resource-group', $ResourceGroupName, '--vault-name', $v.name))) {
                    $null = Invoke-LabAz @('dataprotection', 'backup-instance', 'deleted-backup-instance', 'undelete', '--resource-group', $ResourceGroupName, '--vault-name', $v.name, '--name', $d.name)
                    $null = Invoke-LabAz @('dataprotection', 'backup-instance', 'delete', '--resource-group', $ResourceGroupName, '--vault-name', $v.name, '--name', $d.name, '--yes')
                    Write-Status 'OK' "Permanently deleted soft-deleted backup instance $($d.name)"
                }
            }
        }

        if ($softDeleteStuck) {
            # Delete what CAN go today, so the storage accounts stop billing, and leave the vault to age out.
            foreach ($st in @(Invoke-LabAz @('storage', 'account', 'list', '--resource-group', $ResourceGroupName))) {
                $null = Invoke-LabAz @('storage', 'account', 'delete', '--name', $st.name, '--resource-group', $ResourceGroupName, '--yes')
                Write-Status 'OK' "Deleted storage account $($st.name)"
            }
            Write-Status 'WARN' "The vault stays until its soft-deleted data ages out. Rerun -Mode Remove after the retention period to delete $ResourceGroupName."
        }
        else {
            $recheck = Invoke-LabAz @('group', 'show', '--name', $ResourceGroupName)
            if ($recheck.tags.course -ne $courseTag) { throw 'The course tag changed between checks. Refusing to delete.' }
            Write-Status 'REMOVE' "Deleting $ResourceGroupName and waiting for it to finish..."
            $null = Invoke-LabAz @('group', 'delete', '--name', $ResourceGroupName, '--yes')
            Write-Status 'OK' "$ResourceGroupName removed"
        }

        if ($cspmByLab) {
            $null = Invoke-LabAz @('security', 'pricing', 'create', '--name', 'CloudPosture', '--tier', 'Free')
            Write-Status 'OK' 'Defender CSPM is back on the Free tier, because this lab turned it on.'
        }
        Write-Status 'NEXT' 'Check Cost Management tomorrow to confirm the charges stopped.'
        return
    }
}
