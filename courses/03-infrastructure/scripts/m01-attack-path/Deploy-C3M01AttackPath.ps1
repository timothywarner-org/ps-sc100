#Requires -Version 7.0

<#
.SYNOPSIS
Preview, deploy, or tear down the SC-100 Course 3 Module 1 attack path lab from PowerShell 7.

.DESCRIPTION
Builds the lab behind the "Follow an attack path to a critical asset" demo in your own Azure
subscription: two internet-exposed web VMs (vm-c3m01-web01 and vm-c3m01-web02) that share one
user-assigned managed identity (id-globomantics-c3m01-orders), plus a Storage Blob Data Reader
role assignment that lets that identity read the Globomantics order storage account you name.
Two entry points converging on one identity give Microsoft Defender for Cloud a choke point
to find.

The Bicep templates live inside Deploy-C3M01AttackPath.cloudshell.sh, which must sit in the
same folder as this script. This script extracts them rather than keeping a second copy, so
the PowerShell path and the Cloud Shell path can't drift apart.

What each mode changes:
  Plan      Runs ARM what-if. Creates and changes nothing.
  Deploy    Creates or updates resource group rg-globomantics-c3m01 and everything in it,
            plus one role assignment on the target storage account. Safe to rerun.
  Teardown  Removes that role assignment first, then deletes rg-globomantics-c3m01.

The deliberately old image and the internet-facing listener are training conditions, not
production guidance. A successful deployment doesn't prove Defender generated a path; that
depends on Defender for Cloud's own scan cycle.

.PARAMETER Mode
Plan (the default), Deploy, or Teardown. Start with Plan; it creates nothing.

.PARAMETER TargetStorageAccount
Name of the existing storage account that plays the critical asset. Storage account names
are globally unique, so yours can't be stglobomanticsorders; something like
stglobomanticsorders123 works. README.md has the commands that create it.

.PARAMETER TargetResourceGroup
Resource group that holds the target storage account. Defaults to rg-globomantics.

.PARAMETER SubscriptionId
Subscription ID to work in. Defaults to the subscription your Azure CLI session already uses,
as reported by az account show.

.PARAMETER Location
Azure region for the lab. Defaults to westus2. The lab needs 2 free vCPUs of regional quota
there, and deallocated VMs still count against quota.

.PARAMETER ImageVersion
Ubuntu 22.04 LTS gen2 image version. The default is an old 2022 build, pinned on purpose
because an attack path needs vulnerabilities to start from. If Azure retires it, list what's
left with: az vm image list -l westus2 -p Canonical -f 0001-com-ubuntu-server-jammy -s 22_04-lts-gen2 --all --query "[].version" -o tsv
and pass the oldest version listed.

.PARAMETER FictionalDataConfirmed
Required for Deploy. The shared identity on two internet-facing VMs receives read access to
every blob in the target account. Pass this switch only after you've checked that the account
holds fictional data and nothing real.

.EXAMPLE
.\Deploy-C3M01AttackPath.ps1 -TargetStorageAccount stglobomanticsorders123

Shows the what-if plan. Nothing is created.

.EXAMPLE
.\Deploy-C3M01AttackPath.ps1 -Mode Deploy -TargetStorageAccount stglobomanticsorders123 -FictionalDataConfirmed

Builds the lab. Rerunning it re-asserts the same resources rather than adding new ones.

.EXAMPLE
.\Deploy-C3M01AttackPath.ps1 -Mode Teardown -TargetStorageAccount stglobomanticsorders123

Removes the role assignment, reads it back absent, then deletes rg-globomantics-c3m01.

.NOTES
PREREQUISITES
  * PowerShell 7 and the Azure CLI, signed in with az login. The CLI has to deploy Bicep
    files directly: 2.20.0 or later, and the current release is the safest choice.
  * ssh-keygen (the OpenSSH client). Azure requires an SSH public key for a Linux VM even
    though this lab keeps port 22 closed. The key pair lands in ~/.ssh/c3m01_fixture.
  * Owner on the subscription, or Contributor plus User Access Administrator, because the
    deployment writes a role assignment.
  * Microsoft Defender for Cloud on the subscription, with agentless scanning and attack path
    generation available. Check Microsoft Learn for the plan that provides them and what it
    costs.
  * The target storage account must already exist.

COST WARNING
  This creates billable resources: two Standard_B1s VMs that bill while they run, their
  managed disks, two Standard public IP addresses, and any Defender for Cloud plan charges.
  The lab sets no auto-shutdown schedule, and deallocating doesn't mean zero cost. Tear it
  down as soon as you've finished the demo.

CLEANUP
  .\Deploy-C3M01AttackPath.ps1 -Mode Teardown -TargetStorageAccount <your account>
  Teardown removes the role assignment before the group, so no orphaned "Identity not found"
  grant is left on your storage account. If you created rg-globomantics only for this lab:
  az group delete --name rg-globomantics --yes --no-wait
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Teardown')]
    [string]$Mode = 'Plan',

    # Storage account naming rule: 3 to 24 lowercase letters and digits.
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string]$TargetStorageAccount,

    [ValidateNotNullOrEmpty()]
    [string]$TargetResourceGroup = 'rg-globomantics',

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [ValidatePattern('^[a-z0-9]+$')]
    [string]$Location = 'westus2',

    [ValidatePattern('^22\.04\.\d+$')]
    [string]$ImageVersion = '22.04.202206220',

    [switch]$FictionalDataConfirmed
)
$ErrorActionPreference = 'Stop'
$fixtureGroup = 'rg-globomantics-c3m01'
$identityName = 'id-globomantics-c3m01-orders'
# Storage Blob Data Reader. Built-in role definition IDs are the same in every tenant.
$readerRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
$source = Join-Path $PSScriptRoot 'Deploy-C3M01AttackPath.cloudshell.sh'

if (-not (Test-Path -LiteralPath $source)) {
    throw 'Deploy-C3M01AttackPath.cloudshell.sh must sit next to this script. It holds the Bicep templates.'
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'The Azure CLI (az) is not on PATH. Install it, run az login, and try again.'
}
# Refuse before touching Azure: the identity on two internet-facing VMs gets read access to
# every blob in this account, so it must never be an account with real data in it.
if ($Mode -eq 'Deploy' -and -not $FictionalDataConfirmed) {
    throw "Check that $TargetStorageAccount holds only fictional data, then rerun with -FictionalDataConfirmed."
}

# Resolve the subscription once and pin every later call to it, so a context switch in
# another terminal halfway through a run can't redirect a write.
$sub = $SubscriptionId
if (-not $sub) {
    $sub = & az account show --query id -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $sub) { throw 'No Azure CLI context. Run az login first.' }
}

function Invoke-FixtureAz {
    param([Parameter(Mandatory)][string[]]$Arguments)
    # Never print credentials or turn on debug logging. A normal ARM error still carries an
    # MFA claims challenge without dumping an Authorization header.
    $result = & az @Arguments --subscription $sub --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed for $($Arguments[0..1] -join ' ') (exit $LASTEXITCODE)." }
    if ($result) { ($result -join "`n") | ConvertFrom-Json }
}

$account = Invoke-FixtureAz @('account', 'show')
# Print where this will land before anything changes, so a wrong context is obvious.
Write-Host "[CONTEXT] $($account.user.name) | $($account.name) | tenant $($account.tenantId) | $Location | $Mode"

if ($Mode -eq 'Teardown') {
    # Order matters: delete the role assignment FIRST. Deleting the identity first leaves an
    # orphaned assignment on the storage account that shows up later as "Identity not found"
    # and has to be cleaned up by hand.
    $storageId = (Invoke-FixtureAz @('storage', 'account', 'show', '-g', $TargetResourceGroup, '-n', $TargetStorageAccount)).id
    if (-not (Invoke-FixtureAz @('group', 'exists', '--name', $fixtureGroup))) {
        Write-Host "[INFO] $fixtureGroup is absent. If you deleted it by hand, check $TargetStorageAccount > Access control (IAM) for an orphaned Storage Blob Data Reader grant."
        return
    }
    # The course tag is the ownership check: never delete a group this lab didn't create.
    $rg = Invoke-FixtureAz @('group', 'show', '--name', $fixtureGroup)
    if ($rg.tags.course -ne 'SC100-C3M01') { throw 'The group is not tagged as the M1 lab. Refusing to delete it.' }
    $principalId = (Invoke-FixtureAz @('identity', 'show', '-n', $identityName, '-g', $fixtureGroup)).principalId
    if ($principalId) {
        $null = Invoke-FixtureAz @('role', 'assignment', 'delete', '--assignee-object-id', $principalId, '--role', $readerRoleId, '--scope', $storageId)
        # Read the grant back through a list call rather than trusting the delete's silence.
        $left = @(Invoke-FixtureAz @('role', 'assignment', 'list', '--assignee-object-id', $principalId, '--scope', $storageId,
                '--fill-principal-name', 'false', '--fill-role-definition-name', 'false') |
            Where-Object { $_.roleDefinitionId -like "*/$readerRoleId" })
        if ($left.Count) { throw 'The M1 blob grant is still there. Keeping the identity so you can remove the grant.' }
        Write-Host '[OK] M1 blob grant read back absent.'
    }
    $null = Invoke-FixtureAz @('group', 'delete', '--name', $fixtureGroup, '--yes')
    Write-Host "[OK] $fixtureGroup deleted. $TargetStorageAccount and any Defender for Cloud plans are untouched; README.md covers removing them."
    return
}

$exists = Invoke-FixtureAz @('group', 'exists', '--name', $fixtureGroup)
if ($exists) {
    $rg = Invoke-FixtureAz @('group', 'show', '--name', $fixtureGroup)
    if ($rg.tags.course -ne 'SC100-C3M01') { throw 'The existing group is not marked as the M1 lab. Refusing to change it.' }
}
$usage = Invoke-FixtureAz @('vm', 'list-usage', '--location', $Location)
foreach ($family in @('cores', 'standardBSFamily')) {
    $quota = @($usage | Where-Object { $_.name.value -eq $family })
    # Existing M1 VMs already occupy quota, so a rerun doesn't reserve two more slots.
    # ARM validation still checks the requested final state.
    $needed = if ($exists) { 0 } else { 2 }
    if ($quota.Count -ne 1 -or ([int]$quota[0].limit - [int]$quota[0].currentValue) -lt $needed) {
        throw "Insufficient or unreadable $family quota in $Location. Free some up or pass -Location with another region."
    }
    Write-Host "[PASS] $family quota $($quota[0].currentValue)/$($quota[0].limit)"
}
try {
    $null = Invoke-FixtureAz @('vm', 'image', 'show', '--location', $Location, '--urn', "Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:$ImageVersion")
} catch {
    throw "Image version $ImageVersion is gone from $Location. Run Get-Help $PSCommandPath -Parameter ImageVersion for the command that lists what's left."
}
Write-Host "[PASS] image Ubuntu 22.04 gen2 $ImageVersion is available in $Location"
try {
    $storage = Invoke-FixtureAz @('storage', 'account', 'show', '-g', $TargetResourceGroup, '-n', $TargetStorageAccount)
} catch {
    throw "Target $TargetStorageAccount wasn't found in $TargetResourceGroup. Create it first; README.md has the commands."
}
Write-Host "[PASS] target $($storage.name) exists in $TargetResourceGroup"

# A fresh temp folder per run keeps the extracted templates out of the lab folder and
# leaves them where you can open them to see exactly what was deployed.
$work = Join-Path ([IO.Path]::GetTempPath()) ('c3m01-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + $Mode.ToLower())
New-Item -ItemType Directory -Force $work | Out-Null

# Extract, don't maintain a second copy of the infrastructure definitions.
$pattern = '(?ms)^cat > "\$WORK/(?<name>[^"/]+\.bicep)" <<''BICEP_EOF''\r?\n(?<body>.*?)^BICEP_EOF'
$parts = [regex]::Matches((Get-Content -LiteralPath $source -Raw), $pattern)
if ($parts.Count -ne 3) { throw 'Expected exactly three embedded Bicep files; the Cloud Shell script format changed.' }
foreach ($part in $parts) {
    [IO.File]::WriteAllText((Join-Path $work $part.Groups['name'].Value), $part.Groups['body'].Value.Replace("`r`n", "`n"))
}

# SSH key: required by the API even though port 22 stays closed. Nothing in the demo uses it.
$keyDir = Join-Path $HOME '.ssh'
New-Item -ItemType Directory -Force $keyDir | Out-Null
$key = Join-Path $keyDir 'c3m01_fixture'
if (-not (Test-Path -LiteralPath $key)) {
    & ssh-keygen -t ed25519 -N '' -C 'c3m01-fixture' -f $key -q
    if ($LASTEXITCODE -ne 0) { throw 'Lab SSH key creation failed. Is the OpenSSH client installed?' }
}
if (-not (Test-Path -LiteralPath "$key.pub")) { throw 'Public key is missing. This script never replaces an existing private key automatically.' }

# location goes to the template as well as to the deployment, so -Location moves the
# resources and not just the deployment record.
$parameters = @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = @{
    location = @{ value = $Location }; targetRg = @{ value = $TargetResourceGroup }; targetStorage = @{ value = $TargetStorageAccount }
    imageVersion = @{ value = $ImageVersion }; adminPublicKey = @{ value = (Get-Content -LiteralPath "$key.pub" -Raw).Trim() }
}}
$paramFile = Join-Path $work 'parameters.json'
$parameters | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $paramFile -Encoding utf8
$action = if ($Mode -eq 'Plan') { 'what-if' } else { 'create' }
$argsList = @('deployment', 'sub', $action, '--name', 'c3m01-attack-path', '--location', $Location,
    '--template-file', (Join-Path $work 'main.bicep'), '--parameters', "@$paramFile")
# What-if has a separate human renderer that otherwise ignores the JSON output flag.
if ($Mode -eq 'Plan') { $argsList += '--no-pretty-print' }
Write-Host "[RUN] ARM $action. Templates: $work"
$result = Invoke-FixtureAz $argsList
if ($Mode -eq 'Plan') {
    $result.changes | Select-Object changeType, resourceId | Format-Table -AutoSize
    Write-Host '[DONE] Plan only. Nothing was deployed.'
} else {
    if ($result.properties.provisioningState -ne 'Succeeded') { throw 'ARM did not return Succeeded.' }
    $result.properties.outputs | ConvertTo-Json -Depth 8 | Write-Host
    Write-Host '[DONE] Deployment succeeded. Give Defender for Cloud at least 24 hours, better 48, to scan.'
    Write-Host '[NEXT] Then run .\C3M01VulnerabilityEvidence.ps1 and the queries in C3M01-ExposureGraphCheck.kql.'
    Write-Host "[NEXT] Defender portal: Settings > Microsoft Defender XDR > Rules > Critical asset management. Confirm a rule classifies $TargetStorageAccount as a critical asset. If one already does, don't add a duplicate."
    Write-Host "[COST] The VMs bill until you tear the lab down: .\Deploy-C3M01AttackPath.ps1 -Mode Teardown -TargetStorageAccount $TargetStorageAccount"
}
