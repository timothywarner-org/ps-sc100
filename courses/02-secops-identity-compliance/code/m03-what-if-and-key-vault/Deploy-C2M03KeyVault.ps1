#Requires -Version 7.2

<#
.SYNOPSIS
Plans, deploys, reads back, or removes the Globomantics ERP gateway credential shelf for SC-100
Course 2, Module 3.

.DESCRIPTION
The second half of the Module 3 demo asks the ERP gateway a lifecycle question: what credentials
does it present, and who renews them? This builds the vault that answers it, in your own Azure
subscription, and seeds four objects that each carry different lifecycle evidence:

    cert-erp-gateway   certificate, one-month validity, renews itself at 50 percent of its life.
                       The credential that is always close to expiry, so there is always
                       something to triage.
    cert-plant-portal  certificate, twelve-month validity, renews at 80 percent. The healthy control.
    legacy-tls-cert    a SECRET holding certificate-shaped placeholder text, with no expiry date and
                       no renewal owner. It looks managed and isn't. That absence is the finding,
                       so don't "fix" it.
    key-data-signing   an RSA key with no rotation policy, on purpose.

WHY CERT-ERP-GATEWAY RENEWS ON A PERCENTAGE
A one-month certificate on the default policy, which triggers 90 days before expiry, is outside the
range Key Vault accepts. Even a valid days-before trigger lets a short certificate count down to
zero, and the lab silently turns from "find the credential that is about to fail" into "here is one
that already failed". A lifetimePercentage trigger is bounded 1 to 99 whatever the validity, so the
expiry stays in a band of roughly 15 to 30 days and never reaches zero. The policy is changed as an
object, not by text substitution, so a change in the CLI's JSON formatting can't silently undo it.

WHAT EACH MODE CHANGES
    Plan    Changes nothing. Compiles the template, prints the vault name, and runs what-if if the
            resource group exists.
    Deploy  Creates rg-globomantics-c2m03 (tagged course=SC100-C2M03) if it's missing, deploys the
            vault and your Key Vault Administrator assignment, waits for that access to reach the
            data plane, then creates any of the four objects that don't exist yet. Safe to rerun.
    Show    Changes nothing. Prints the vault's settings and each object's lifecycle evidence.
    Remove  Deletes the resource group after re-reading its course tag, then purges the soft-deleted
            vault so its name is free for the next Deploy.

SAFETY RAILS
    * Wrong subscription or tenant  -> pass -SubscriptionId or -TenantId and it stops before any write.
    * A write the session can't make -> it checks your Azure token for the mfa claim first.
    * Someone else's resource group  -> it refuses an rg-globomantics-c2m03 that lacks the course tag.
    * A soft-deleted name clash      -> Deploy stops early and prints the purge command, rather than
                                        purging anything on its own.

.PARAMETER Mode
Plan (the default), Deploy, Show, or Remove.

.PARAMETER SubscriptionId
Optional. The subscription to work in. Leave it out and the script uses AZURE_SUBSCRIPTION_ID, then
your current Azure CLI subscription.

.PARAMETER TenantId
Optional. The tenant you expect. Defaults to AZURE_TENANT_ID when that's set. The script stops if the
subscription belongs to another tenant.

.PARAMETER Location
Region for a new resource group. Defaults to eastus2. When the group already exists, its region wins.

.PARAMETER SkipMfaCheck
Skip the check for the mfa claim in your Azure token. Use it only if your organization satisfies MFA
in a way the token doesn't show.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C2M03KeyVault.ps1 -Mode Deploy
Builds the vault and seeds the four objects.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C2M03KeyVault.ps1 -Mode Show
Prints the lifecycle evidence for each object, for you to triage.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C2M03KeyVault.ps1 -Mode Remove
Deletes the lab and purges the soft-deleted vault.

.NOTES
PREREQUISITES
    * PowerShell 7.2 or later and the Azure CLI with Bicep, signed in with az login.
    * Owner, or User Access Administrator plus Contributor, on the subscription. The template
      creates one role assignment, and creating role assignments needs that right.

COST
    Standard-tier vault operations and certificate renewals are billed per operation. The lab makes
    very few, but cert-erp-gateway renews itself about every 15 days for as long as it exists, so
    remove the lab when you're done.

Key Vault certificate renewal:  https://learn.microsoft.com/azure/key-vault/certificates/overview-renew-certificate
Key Vault soft delete:          https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview
Key rotation policy:            https://learn.microsoft.com/azure/key-vault/keys/how-to-configure-key-rotation
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Show', 'Remove')]
    [string]$Mode = 'Plan',

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

$group = 'rg-globomantics-c2m03'
$tag = 'SC100-C2M03'
$deploymentName = 'c2m03-key-vault'
$template = Join-Path $PSScriptRoot 'iac' 'main.bicep'
if (-not (Test-Path -LiteralPath $template)) { throw 'The iac folder must sit next to this script and hold main.bicep.' }

Assert-C2AzureCli -Bicep
# Compile first and offline: a template error should stop the run before anything touches Azure.
$null = Invoke-C2Az -Arguments @('bicep', 'build', '--file', $template, '--stdout') -Text
Write-Host '[OK] The template compiles.'

$ctx = Resolve-C2AzureContext -SubscriptionId $SubscriptionId -TenantId $TenantId
Write-C2AzureContext -Context $ctx -Mode $Mode
$sub = $ctx.SubscriptionId
# Vault names are global. A suffix derived from your subscription is unique to you and identical on
# every rerun, so the lab converges on one vault instead of scattering new ones.
$vaultName = "kv-glb-c2m03-$(Get-C2DeterministicSuffix -SubscriptionId $sub -Seed $group)"
Write-Host "[INFO] Vault name for this subscription: $vaultName"

$exists = [bool](Invoke-C2Az -Arguments @('group', 'exists', '--name', $group) -SubscriptionId $sub)
if ($exists) {
    $current = Invoke-C2Az -Arguments @('group', 'show', '--name', $group) -SubscriptionId $sub
    if ($current.tags.course -ne $tag) { throw "Ownership mismatch: $group exists but isn't tagged course=$tag. Refusing to touch it." }
    $Location = $current.location
}

function Get-OperatorIdentity {
    <# Your own object ID, so the role assignment goes to whoever runs the lab. #>
    if ($ctx.AccountType -eq 'user') {
        $me = Invoke-C2Az -Arguments @('ad', 'signed-in-user', 'show')
        return [pscustomobject]@{ Id = [string]$me.id; Type = 'User' }
    }
    # A service principal sign-in reports its application ID as the account name.
    $sp = Invoke-C2Az -Arguments @('ad', 'sp', 'show', '--id', $ctx.Account)
    [pscustomobject]@{ Id = [string]$sp.id; Type = 'ServicePrincipal' }
}

function Get-VaultObjects {
    <#
    Lists the objects of one kind, excluding the secret and key that back each certificate. A list
    returns metadata only, so a secret's value is never fetched, let alone shown.
    #>
    param([ValidateSet('certificate', 'secret', 'key')][string]$Kind)
    @(Invoke-C2Az -Arguments @('keyvault', $Kind, 'list', '--vault-name', $vaultName) -SubscriptionId $sub |
        Where-Object { -not ($_.PSObject.Properties.Name -contains 'managed' -and $_.managed) })
}

function Get-VaultObjectNames {
    <# Just the names, for the "create it only if it's missing" checks. #>
    param([ValidateSet('certificate', 'secret', 'key')][string]$Kind)
    @(Get-VaultObjects -Kind $Kind | ForEach-Object { $_.name })
}

function New-LabCertificate {
    <# Creates one self-signed certificate from the CLI's default policy, changed as an object. #>
    param([string]$Name, [string]$Subject, [int]$ValidityMonths, [int]$RenewAtPercent)
    $policy = Invoke-C2Az -Arguments @('keyvault', 'certificate', 'get-default-policy')
    $policy.x509CertificateProperties.subject = $Subject
    $policy.x509CertificateProperties.validityInMonths = $ValidityMonths
    # A percentage trigger, not daysBeforeExpiry. See the description block above.
    $policy.lifetimeActions[0].trigger = [pscustomobject]@{ lifetimePercentage = $RenewAtPercent }
    $file = New-TemporaryFile
    try {
        $policy | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $file.FullName -Encoding utf8NoBOM
        $null = Invoke-C2Az -Arguments @('keyvault', 'certificate', 'create', '--vault-name', $vaultName, '--name', $Name, '--policy', "@$($file.FullName)") -SubscriptionId $sub
    }
    finally { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
}

switch ($Mode) {
    'Plan' {
        if (-not $exists) { Write-Host "[PLAN] $group doesn't exist yet. Deploy creates it in $Location with the course tag."; return }
        $operator = Get-OperatorIdentity
        $result = Invoke-C2Az -Arguments @('deployment', 'group', 'what-if', '--resource-group', $group, '--name', $deploymentName, '--template-file', $template,
            '--parameters', "vaultName=$vaultName", "operatorObjectId=$($operator.Id)", "operatorPrincipalType=$($operator.Type)", "location=$Location", '--no-pretty-print') -SubscriptionId $sub
        $changes = @($result.changes)
        Write-Host "[PLAN] what-if: $(@($changes | Group-Object changeType | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ')"
        foreach ($c in $changes) { Write-Host ('  {0,-10}{1}' -f $c.changeType, ($c.resourceId -split '/providers/', 2)[-1]) }
        return
    }

    'Deploy' {
        Assert-C2ArmWriteReady -Context $ctx -Skip:$SkipMfaCheck
        # A soft-deleted vault keeps its name reserved. Stop early with the fix rather than fail
        # mid-deploy, and leave the purge to you: purging is permanent.
        $live = @()
        if ($exists) { $live = @(Invoke-C2Az -Arguments @('keyvault', 'list', '--resource-group', $group) -SubscriptionId $sub | Where-Object { $_.name -eq $vaultName }) }
        if (-not $live.Count) {
            $deleted = @(Invoke-C2Az -Arguments @('keyvault', 'list-deleted', '--resource-type', 'vault') -SubscriptionId $sub | Where-Object { $_.name -eq $vaultName })
            if ($deleted.Count) {
                throw "A soft-deleted vault still holds the name $vaultName. Purge it, then rerun: az keyvault purge --name $vaultName --location $($deleted[0].properties.location)"
            }
        }
        if (-not $exists) {
            $null = Invoke-C2Az -Arguments @('group', 'create', '--name', $group, '--location', $Location,
                '--tags', "course=$tag", 'company=Globomantics', 'purpose=course-lab') -SubscriptionId $sub
            Write-Host "[OK] Created $group in $Location"
        }
        $operator = Get-OperatorIdentity
        Write-Host "[DEPLOY] Vault $vaultName and a Key Vault Administrator assignment for you."
        $result = Invoke-C2Az -Arguments @('deployment', 'group', 'create', '--resource-group', $group, '--name', $deploymentName, '--template-file', $template,
            '--parameters', "vaultName=$vaultName", "operatorObjectId=$($operator.Id)", "operatorPrincipalType=$($operator.Type)", "location=$Location") -SubscriptionId $sub
        if ($result.properties.provisioningState -ne 'Succeeded') { throw "The deployment returned $($result.properties.provisioningState)." }

        # The role assignment exists as soon as the deployment finishes, but data-plane authorization
        # propagates separately, and seeding right away returns 403 on a correctly deployed vault.
        $reachable = $false
        foreach ($i in 1..15) {
            try { $null = Invoke-C2Az -Arguments @('keyvault', 'key', 'list', '--vault-name', $vaultName) -SubscriptionId $sub; $reachable = $true; break }
            catch { Write-Host "[WAIT] Data-plane access isn't active yet (attempt $i of 15). Retrying in 20 seconds."; Start-Sleep -Seconds 20 }
        }
        if (-not $reachable) { throw 'Data-plane access still refused after five minutes. Check the Key Vault Administrator assignment on the vault, then rerun Deploy.' }
        Write-Host '[OK] The data plane accepts your requests.'

        # Create each object only if it's missing, so a rerun adds no new versions.
        $certs = Get-VaultObjectNames -Kind certificate
        if ($certs -notcontains 'cert-erp-gateway') {
            New-LabCertificate -Name 'cert-erp-gateway' -Subject 'CN=erp-gateway.globomantics.example' -ValidityMonths 1 -RenewAtPercent 50
            Write-Host '[CREATED] cert-erp-gateway: one-month validity, renews at 50 percent of its life'
        } else { Write-Host '[EXISTS] cert-erp-gateway' }
        if ($certs -notcontains 'cert-plant-portal') {
            New-LabCertificate -Name 'cert-plant-portal' -Subject 'CN=plant-portal.globomantics.example' -ValidityMonths 12 -RenewAtPercent 80
            Write-Host '[CREATED] cert-plant-portal: twelve-month validity, the healthy control'
        } else { Write-Host '[EXISTS] cert-plant-portal' }

        if ((Get-VaultObjectNames -Kind secret) -notcontains 'legacy-tls-cert') {
            # Placeholder text shaped like a certificate, never a real one. No expiry and no owner, on purpose.
            $null = Invoke-C2Az -Arguments @('keyvault', 'secret', 'set', '--vault-name', $vaultName, '--name', 'legacy-tls-cert',
                '--description', 'Lab anti-pattern: certificate material stored as a secret', '--content-type', 'application/x-pem-file',
                '--value', '-----BEGIN CERTIFICATE-----GLOBOMANTICS-LAB-PLACEHOLDER-NOT-A-REAL-CERT-----END CERTIFICATE-----') -SubscriptionId $sub
            Write-Host '[CREATED] legacy-tls-cert: a secret with no expiry metadata, on purpose'
        } else { Write-Host '[EXISTS] legacy-tls-cert' }

        if ((Get-VaultObjectNames -Kind key) -notcontains 'key-data-signing') {
            $null = Invoke-C2Az -Arguments @('keyvault', 'key', 'create', '--vault-name', $vaultName, '--name', 'key-data-signing', '--kty', 'RSA', '--size', '2048') -SubscriptionId $sub
            Write-Host '[CREATED] key-data-signing: RSA 2048 with no rotation policy, on purpose'
        } else { Write-Host '[EXISTS] key-data-signing' }

        Write-Host '[NEXT] Run -Mode Show and triage the four objects. Remove the lab the same day.'
        return
    }

    'Remove' {
        if (-not $exists) { Write-Host "[OK] $group is already absent" }
        else {
            Assert-C2ArmWriteReady -Context $ctx -Skip:$SkipMfaCheck
            # Re-read the tag immediately before the delete, so a change between checks can't slip through.
            $recheck = Invoke-C2Az -Arguments @('group', 'show', '--name', $group) -SubscriptionId $sub
            if ($recheck.tags.course -ne $tag) { throw 'The course tag changed between checks; refusing to delete.' }
            Write-Host "[REMOVE] Deleting $group and waiting for it to finish..."
            $null = Invoke-C2Az -Arguments @('group', 'delete', '--name', $group, '--yes') -SubscriptionId $sub
            Write-Host "[REMOVED] $group"
        }
        # Only this lab's exact vault name is ever purged.
        $deleted = @(Invoke-C2Az -Arguments @('keyvault', 'list-deleted', '--resource-type', 'vault') -SubscriptionId $sub | Where-Object { $_.name -eq $vaultName })
        if ($deleted.Count) {
            $null = Invoke-C2Az -Arguments @('keyvault', 'purge', '--name', $vaultName, '--location', $deleted[0].properties.location) -SubscriptionId $sub
            Write-Host "[REMOVED] Purged the soft-deleted vault $vaultName, so its name is free for the next Deploy."
        }
        Write-Host '[DONE] Check Cost Management tomorrow to confirm the charges stopped.'
        return
    }
}

# ------------------------------------------------------------------ Show reads the live lab
if (-not $exists) { throw "$group doesn't exist yet. Run -Mode Deploy first." }
$vault = Invoke-C2Az -Arguments @('keyvault', 'show', '--name', $vaultName, '--resource-group', $group) -SubscriptionId $sub
$vp = $vault.properties
Write-Host ''
Write-Host "THE VAULT: $vaultName"
Write-Host "  Permission model     $(if ($vp.enableRbacAuthorization) { 'Azure RBAC' } else { 'access policies' })"
Write-Host "  Public network       $($vp.publicNetworkAccess)   (the open design decision)"
Write-Host "  Soft delete          $($vp.softDeleteRetentionInDays) days, purge protection $(if ($vp.enablePurgeProtection) { 'on' } else { 'off' })"

$now = [datetime]::UtcNow
Write-Host ''
Write-Host 'THE CERTIFICATES: expiry and who renews them'
foreach ($name in (Get-VaultObjectNames -Kind certificate)) {
    $c = Invoke-C2Az -Arguments @('keyvault', 'certificate', 'show', '--vault-name', $vaultName, '--name', $name) -SubscriptionId $sub
    # ConvertFrom-Json already turned the timestamp into a DateTime; normalize it to UTC for the arithmetic.
    $expires = ([datetime]$c.attributes.expires).ToUniversalTime()
    $trigger = $c.policy.lifetimeActions | Select-Object -First 1
    $how = if ($trigger.trigger.lifetimePercentage) { "renews at $($trigger.trigger.lifetimePercentage) percent of its life" }
           elseif ($trigger.trigger.daysBeforeExpiry) { "renews $($trigger.trigger.daysBeforeExpiry) days before expiry" }
           else { 'no renewal trigger' }
    Write-Host ("  {0,-18} expires {1:yyyy-MM-dd}, {2} days left, {3} ({4})" -f $name, $expires, [int]($expires - $now).TotalDays, $how, $trigger.action.actionType)
}

Write-Host ''
Write-Host 'THE SECRETS: expiry metadata only. Values are never shown.'
foreach ($s in (Get-VaultObjects -Kind secret)) {
    $exp = if ($s.attributes.expires) { ([datetime]$s.attributes.expires).ToUniversalTime().ToString('yyyy-MM-dd') } else { 'NONE' }
    Write-Host ("  {0,-18} content type {1}, expires {2}" -f $s.name, $s.contentType, $exp)
}

Write-Host ''
Write-Host 'THE KEYS: rotation policy'
foreach ($name in (Get-VaultObjectNames -Kind key)) {
    $policy = $null
    try { $policy = Invoke-C2Az -Arguments @('keyvault', 'key', 'rotation-policy', 'show', '--vault-name', $vaultName, '--name', $name) -SubscriptionId $sub } catch { $policy = $null }
    $rotate = @($policy.lifetimeActions | Where-Object { $_.action -eq 'Rotate' -or $_.action.type -eq 'Rotate' })
    Write-Host ("  {0,-18} {1}" -f $name, $(if ($rotate.Count) { 'has a rotation action' } else { 'NO rotation policy' }))
}

Write-Host ''
Write-Host 'Triage it: which object fails first, which one only looks managed, and who owns each renewal?'
Write-Host 'Remember the consumer: a renewed certificate helps only the services that pick up the new version.'
