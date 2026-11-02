#Requires -Version 7.4

<#
.SYNOPSIS
Plans, deploys, or deallocates the Globomantics server estate for the SC-100 Course 3 Module 2 demo.

.DESCRIPTION
Builds the lab behind the demo "Read server coverage and plan fit in Defender for Cloud": three
Azure VMs and one Azure Arc-enabled server whose Defender for Servers plans differ on purpose, so
there's a real plan decision to read.

  rg-globomantics-c3m02 (what the demo reads)
    vm-glb-erp01   Windows Server 2025, Azure VM   Plan 2, inherited from the subscription
    vm-glb-web01   Ubuntu, Azure VM, storefront    Plan 1, set on the VM
    vm-glb-test01  Ubuntu, Azure VM, test          Plan 1, set on the VM
    glb-dc-file01  Azure Arc-enabled server        Plan 2, inherited from the subscription
  rg-globomantics-c3m02-host (plumbing the demo never shows)
    vm-glb-arc-host01  the Azure VM that plays glb-dc-file01 (evaluation only)

The templates in the iac folder next to this script are the only source. The script works in
the subscription your Azure CLI is signed in to, or the one you pass with -SubscriptionId. It
refuses to touch an existing group with these names unless it carries this lab's course tag,
checks vCPU quota before it deploys, and never changes a subscription-wide Defender plan.

What Deploy changes outside the two resource groups:
  * One Microsoft Entra app registration and service principal, sp-globomantics-c3m02-arc,
    holding ONLY "Azure Connected Machine Onboarding" on rg-globomantics-c3m02. The host VM uses
    it to connect itself to Azure Arc. Each run adds a secret that expires in one day, and the
    script revokes that secret as soon as the connection attempt ends.
  * The Microsoft.HybridCompute, Microsoft.GuestConfiguration and Microsoft.HybridConnectivity
    resource providers get registered if they aren't already. That's a subscription setting,
    not a resource.

Secrets: the Windows admin password and the onboarding secret are generated at run time, never
printed, and never written to a file. Linux sign-in is key-only, and the private key is deleted
as soon as its public half is read, because nothing in this module needs a shell on any machine.

.PARAMETER Mode
Plan (the default) runs a what-if and creates nothing. Deploy creates the lab, or re-asserts it
if it already exists, then waits up to ten minutes for glb-dc-file01 to connect to Azure Arc.
Stop deallocates only the lab's tagged VMs and keeps their disks, so you can start them later.

.PARAMETER SubscriptionId
The subscription to work in. When you leave it out, the script uses the Azure CLI's current
subscription (az account show).

.PARAMETER Location
Azure region for every resource. Defaults to westus2. Pick a region where you have at least 5
free B-series vCPUs; the script checks before it deploys.

.PARAMETER ShutdownTimeZone
Windows time zone ID for the nightly 11 PM auto-shutdown of every lab VM, for example
'Pacific Standard Time' or 'W. Europe Standard Time'. Defaults to 'Central Standard Time'.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C3M02ServerEstate.ps1
Shows what Deploy would create. Creates nothing. Run this first.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C3M02ServerEstate.ps1 -Mode Deploy
Builds the lab in your current subscription. The deployment takes 10 to 15 minutes.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C3M02ServerEstate.ps1 -Mode Deploy -Location eastus2 -ShutdownTimeZone 'Eastern Standard Time'
Builds the lab in another region, with the nightly shutdown in your own time zone.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C3M02ServerEstate.ps1 -Mode Stop
Deallocates the lab VMs between sessions.

.NOTES
Prerequisites
  * PowerShell 7.4 or later, the Azure CLI signed in with az login, and ssh-keygen (the OpenSSH
    client) on your PATH. Built and checked with Azure CLI 2.85; run az upgrade if yours is older.
  * Owner on the subscription, or Contributor plus User Access Administrator, because Deploy
    creates a role assignment.
  * Permission to create app registrations in Microsoft Entra ID.
  * Microsoft Defender for Servers Plan 2 turned on at subscription scope. Two lab servers inherit
    it and two override it with Plan 1, and that difference is the demo. Deploy checks and stops
    if it's missing rather than change a subscription-wide plan on your behalf. Plan 2 at
    subscription scope covers every server in that subscription, not just this lab's. To turn
    it on:
      az security pricing create --name VirtualMachines --tier standard --subplan P2

COST WARNING
  Deploy creates billable resources: four small VMs while they run, their disks, and Defender for
  Servers on three Azure VMs and one Arc machine. Stop deallocates compute, not disks or the Arc
  machine's plan. Check current rates on Microsoft's Azure and Defender for Cloud pricing pages,
  and clean up as soon as you're done.

Cleanup, everything Deploy creates
  az ad app delete --id (az ad app list --display-name sp-globomantics-c3m02-arc --query "[0].appId" -o tsv)
  az group delete --name rg-globomantics-c3m02 --yes --no-wait
  az group delete --name rg-globomantics-c3m02-host --yes --no-wait
  If you turned on Defender for Servers Plan 2 only for this lab, turn it back off:
  az security pricing create --name VirtualMachines --tier free
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Stop')]
    [string]$Mode = 'Plan',

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [ValidatePattern('^[a-z0-9]{3,40}$')]
    [string]$Location = 'westus2',

    [ValidateNotNullOrEmpty()]
    [string]$ShutdownTimeZone = 'Central Standard Time'
)

$ErrorActionPreference = 'Stop'

$groups = @('rg-globomantics-c3m02', 'rg-globomantics-c3m02-host')
$tag = 'SC100-C3M02'
$appName = 'sp-globomantics-c3m02-arc'
# Azure Connected Machine Onboarding, a built-in role. Built-in role IDs are the same in every
# tenant, so this ID works unchanged wherever you run the lab.
$onboardingRole = 'b64e21ea-ac4e-4cdf-9dc9-5b892992bee7'
$template = Join-Path $PSScriptRoot 'iac/main.bicep'
if (-not (Test-Path -LiteralPath $template)) {
    throw "Template not found: $template. Keep the iac folder next to this script."
}

function Write-LabStatus {
    # Status lines go to the information stream, which the console shows, so the script's
    # output stream stays clean.
    param([string]$Message)
    Write-Information -MessageData $Message -InformationAction Continue
}

function Invoke-LabAz {
    param([string[]]$Arguments)
    # Every subscription-scoped call names the subscription explicitly, so a CLI default that
    # changes mid-run can't send half the lab somewhere else. Directory (ad) commands carry
    # tenant context only, and bicep build is offline, so neither takes --subscription.
    $scopeArgs = @()
    if ($Arguments[0] -notin 'ad', 'bicep') { $scopeArgs = @('--subscription', $sub) }
    $raw = & az @Arguments @scopeArgs --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) { throw "Azure operation failed: $($Arguments[0..1] -join ' ')" }
    if ($raw) { ($raw -join "`n") | ConvertFrom-Json }
}

# Work in YOUR subscription: the one you name, or the CLI's current one. Nothing in this lab is
# tied to a particular tenant or subscription.
if (-not $SubscriptionId) {
    $cliSubscription = & az account show --query id -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $cliSubscription) { throw 'No Azure CLI sign-in found. Run az login, then rerun.' }
    $SubscriptionId = "$cliSubscription".Trim()
}
$sub = $SubscriptionId.ToLowerInvariant()
$account = Invoke-LabAz @('account', 'show')
Write-LabStatus "[CONTEXT] $($account.user.name) | $($account.name) | $Mode | $Location"

# Refuse to touch a same-named group that some other project owns.
foreach ($g in $groups) {
    if (Invoke-LabAz @('group', 'exists', '-n', $g)) {
        $existing = Invoke-LabAz @('group', 'show', '-n', $g)
        if ($existing.tags.course -ne $tag) { throw "Ownership mismatch: $g exists but isn't tagged course=$tag" }
    }
}

if ($Mode -eq 'Stop') {
    foreach ($g in $groups) {
        if (Invoke-LabAz @('group', 'exists', '-n', $g)) {
            foreach ($vm in @(Invoke-LabAz @('vm', 'list', '-g', $g))) {
                if ($vm.tags.course -ne $tag) { throw "Untagged VM: $($vm.name)" }
                $null = Invoke-LabAz @('vm', 'deallocate', '-g', $g, '-n', $vm.name)
                $state = Invoke-LabAz @('vm', 'get-instance-view', '-g', $g, '-n', $vm.name)
                if ('PowerState/deallocated' -notin $state.instanceView.statuses.code) { throw "Deallocation not confirmed: $($vm.name)" }
                Write-LabStatus "[PASS] $($vm.name) deallocated; disks and Defender coverage may still incur charges"
            }
        }
    }
    return
}

# The lab's whole point is that two VMs OVERRIDE the subscription's plan. If the subscription
# isn't on Plan 2, the inherited rows read wrong. Turning on a subscription-wide plan is your
# decision, so Plan mode only warns and Deploy stops.
$pricing = Invoke-LabAz @('security', 'pricing', 'show', '--name', 'VirtualMachines')
if ($pricing.pricingTier -ne 'Standard' -or $pricing.subPlan -ne 'P2') {
    $planMessage = "Defender for Servers at subscription scope is '$($pricing.pricingTier)/$($pricing.subPlan)', and this lab needs Standard/P2. " +
        'It covers every server in the subscription. To turn it on: az security pricing create --name VirtualMachines --tier standard --subplan P2'
    if ($Mode -eq 'Deploy') { throw $planMessage }
    Write-Warning $planMessage
} else {
    Write-LabStatus '[PASS] Defender for Servers subscription plan: Standard/P2'
}

# A fresh lab needs 5 vCPUs: one B2s (2) and three B1ms (1 each). A lab that already exists
# needs none, so a re-run isn't blocked by its own VMs.
$usage = Invoke-LabAz @('vm', 'list-usage', '-l', $Location)
$current = @()
foreach ($g in $groups) {
    if (Invoke-LabAz @('group', 'exists', '-n', $g)) { $current += @(Invoke-LabAz @('vm', 'list', '-g', $g)) }
}
$need = if ($current.Count -eq 0) { 5 } else { 0 }
foreach ($quotaName in 'cores', 'standardBSFamily') {
    $q = @($usage | Where-Object { $_.name.value -eq $quotaName })
    if ($q.Count -ne 1 -or ([int]$q[0].limit - [int]$q[0].currentValue) -lt $need) {
        throw "Insufficient $quotaName quota in $Location; the lab needs $need vCPUs. Choose another region with -Location."
    }
    Write-LabStatus "[PASS] $quotaName quota $($q[0].currentValue)/$($q[0].limit)"
}

# Azure Arc needs these resource providers registered before glb-dc-file01 can appear.
foreach ($ns in 'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity') {
    $registration = (Invoke-LabAz @('provider', 'show', '-n', $ns)).registrationState
    if ($registration -eq 'Registered') { Write-LabStatus "[PASS] provider $ns registered"; continue }
    if ($Mode -eq 'Deploy') {
        $null = Invoke-LabAz @('provider', 'register', '-n', $ns, '--wait')
        Write-LabStatus "[PASS] registered $ns"
    } else {
        Write-Warning "$ns is $registration; -Mode Deploy registers it"
    }
}

# Compile first, offline, so a template error stops the run before anything is created.
$null = Invoke-LabAz @('bicep', 'build', '--file', $template, '--stdout')

# A private folder for the throwaway SSH key pair, readable only by you. The API needs a public
# key for the Linux VMs; nobody keeps the private one.
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$keyDir = Join-Path $tempRoot ('sc100-c3m02-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $keyDir
if ($IsWindows) {
    $acl = Get-Acl -LiteralPath $keyDir
    $acl.SetAccessRuleProtection($true, $false)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $keyDir -AclObject $acl
} else {
    & chmod 700 $keyDir
}

$appId = $null; $credentialKey = $null
try {
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        throw 'ssh-keygen not found. Install the OpenSSH client, then rerun.'
    }
    $keyFile = Join-Path $keyDir 'lab'
    & ssh-keygen -t ed25519 -N '' -C 'c3m02-lab-throwaway' -f $keyFile -q
    if ($LASTEXITCODE -ne 0) { throw 'SSH key generation failed' }
    $pub = (Get-Content -LiteralPath "$keyFile.pub" -Raw).Trim()
    Remove-Item -LiteralPath $keyFile -Force

    # Windows needs upper case, lower case, a digit and a symbol; the fixed tail guarantees all
    # four. The random part stays alphanumeric so it reaches az intact on every platform.
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $password = (-join (1..24 | ForEach-Object { $alphabet[[Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)] })) + 'aA1.'
    # Plan mode never creates the app, so it hands what-if a random throwaway secret and an
    # all-zero app ID. Deploy replaces both with the real ones below.
    $secret = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16))
    $client = '00000000-0000-0000-0000-000000000000'

    if ($Mode -eq 'Deploy') {
        foreach ($g in $groups) {
            $null = Invoke-LabAz @('group', 'create', '-n', $g, '-l', $Location, '--tags', "course=$tag", 'company=Globomantics', 'purpose=demo-fixture', 'teardown=after-course')
        }
        $apps = @(Invoke-LabAz @('ad', 'app', 'list', '--display-name', $appName))
        if ($apps.Count -gt 1) { throw "Ambiguous onboarding application name: more than one app is called $appName" }
        if ($apps.Count -eq 0) {
            $app = Invoke-LabAz @('ad', 'app', 'create', '--display-name', $appName)
            $sp = Invoke-LabAz @('ad', 'sp', 'create', '--id', $app.appId)
        } else {
            $app = $apps[0]
            $sp = Invoke-LabAz @('ad', 'sp', 'show', '--id', $app.appId)
        }
        $appId = $app.appId; $client = $appId
        # Scope the onboarding role to the one group the Arc machine lands in, nothing wider.
        $scope = "/subscriptions/$sub/resourceGroups/$($groups[0])"
        $assign = @(Invoke-LabAz @('role', 'assignment', 'list', '--assignee', $sp.id, '--scope', $scope, '--role', $onboardingRole))
        if ($assign.Count -eq 0) {
            # Object ID plus principal type skips a directory lookup that can fail while a brand
            # new service principal is still replicating.
            $null = Invoke-LabAz @('role', 'assignment', 'create', '--assignee-object-id', $sp.id, '--assignee-principal-type', 'ServicePrincipal', '--role', $onboardingRole, '--scope', $scope)
        }
        # A named, one-day secret, so the finally block can revoke exactly this one and leave any
        # other credential on the app alone.
        $credentialName = 'C3M02-' + [guid]::NewGuid().ToString('N')
        $cred = Invoke-LabAz @('ad', 'app', 'credential', 'reset', '--id', $appId, '--append', '--display-name', $credentialName, '--end-date', (Get-Date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        $secret = $cred.password
        $keys = @(Invoke-LabAz @('ad', 'app', 'credential', 'list', '--id', $appId))
        $credentialKey = ($keys | Where-Object displayName -EQ $credentialName).keyId
        if (-not $credentialKey) { throw 'Cannot identify the new onboarding credential for cleanup' }
    }

    # Secrets travel as deployment parameters on az's command line, never in a parameters file,
    # so nothing secret is written to your disk. Your own process list can see them while az
    # runs, which is one reason the onboarding secret is scoped to one role on one resource
    # group, expires in a day, and is revoked the moment the connection attempt ends.
    $deployParams = @(
        "adminPassword=$password", "sshPublicKey=$pub", "arcSpAppId=$client", "arcSpSecret=$secret",
        "location=$Location", "shutdownTimeZone=$ShutdownTimeZone"
    )
    $name = 'c3m02-estate-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')

    if ($Mode -eq 'Plan') {
        # Pretty-printed what-if goes straight to your console; it's the whole point of Plan mode.
        & az deployment sub what-if --name $name --location $Location --template-file $template --parameters @deployParams --subscription $sub --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'What-if failed. Nothing was deployed.' }
        Write-LabStatus '[PLAN] What-if only. Nothing was created. To build it: pwsh -NoProfile -File .\Deploy-C3M02ServerEstate.ps1 -Mode Deploy'
        return
    }

    Write-LabStatus '[DEPLOY] Creating or re-asserting the lab (10 to 15 minutes) ...'
    $result = Invoke-LabAz (@('deployment', 'sub', 'create', '--name', $name, '--location', $Location, '--template-file', $template, '--parameters') + $deployParams)
    Write-LabStatus ('[RESULT] ' + ($result.properties.outputs | ConvertTo-Json -Depth 5 -Compress))

    $connected = $false
    for ($i = 0; $i -lt 20; $i++) {
        # Ask for the machine by exact name. The generic resource-list endpoint has returned an
        # empty list even while an exact GET and Resource Graph showed the connected host.
        $arcRead = & az resource show -g $groups[0] -n glb-dc-file01 --resource-type Microsoft.HybridCompute/machines --api-version 2024-07-10 --subscription $sub --only-show-errors -o json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $machine = ($arcRead -join "`n") | ConvertFrom-Json
            if ($machine.properties.status -eq 'Connected') { $connected = $true; break }
        } elseif (($arcRead -join "`n") -notmatch 'ResourceNotFound') {
            throw 'Arc status read failed; connection state is unknown'
        }
        Start-Sleep -Seconds 30
    }
    if ($connected) {
        Write-LabStatus '[PASS] glb-dc-file01 is Connected to Azure Arc'
    } else {
        Write-Warning ('glb-dc-file01 is not Connected yet. Read the host''s own report: ' +
            'az vm boot-diagnostics get-boot-log -g rg-globomantics-c3m02-host -n vm-glb-arc-host01')
    }
    Write-LabStatus '[NEXT] Read the plans: pwsh -NoProfile -File .\Show-C3M02ServerPlans.ps1'
    Write-LabStatus '[WAIT] Defender for Endpoint onboarding and the Defender for Cloud inventory run on their own cycles; give the portal views up to 24 hours.'
} finally {
    try {
        if ($appId -and $credentialKey) {
            $null = Invoke-LabAz @('ad', 'app', 'credential', 'delete', '--id', $appId, '--key-id', $credentialKey)
            Write-LabStatus '[PASS] Temporary Arc onboarding secret revoked'
        }
    } finally {
        # Resolve and constrain the target before removing anything, so a bad path can never
        # delete outside your temp folder.
        $resolved = [IO.Path]::GetFullPath($keyDir)
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected temporary path' }
        if (Test-Path -LiteralPath $resolved) {
            Get-ChildItem -LiteralPath $resolved -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
            Remove-Item -LiteralPath $resolved
        }
    }
}
