<#
.SYNOPSIS
Plans, deploys or removes the Azure half of the Globomantics Private Access lab: the plant
network, the private network connector host and the two production line hosts.

.DESCRIPTION
Supports the SC-100 Course 3, Module 4 demo, "Scope vendor access with Microsoft Entra Private
Access". iac/main.bicep is the only template source and documents every resource, including the
finding the demo has you spot: the legacy vendor VPN rules.

WHAT IT CHANGES IN AZURE
    Creates the resource group rg-globomantics-c3m04 (tagged course=SC100-C3M04) in your
    subscription and deploys a virtual network with three subnets, three network security groups,
    three VMs (one Windows Server connector host, two Ubuntu line hosts), a private DNS zone,
    and a nightly auto-shutdown schedule for each VM. After the deployment it uses Run Command
    to install the Microsoft Entra private network connector on vm-glb-pa-conn01 WITHOUT
    registering it.

WHAT IT CHANGES IN MICROSOFT ENTRA
    Nothing. Registration needs an administrator's sign-in token, which
    Set-C3M04PrivateAccess.ps1 -Mode Register obtains.

WHY TWO SCRIPTS
    Azure Resource Manager owns the network and the VMs; Microsoft Graph owns the enterprise
    application, segment, connector group, vendor assignment and Conditional Access policy.
    Different APIs, different credentials, different failure modes. Splitting them lets the Azure
    half finish even when the Entra half is still waiting on a sign-in.

SECRETS
    The Windows password and the SSH key pair are generated per run in an owner-only temporary
    folder and deleted in a finally block. Nobody signs in to these hosts: the connector host is
    managed through Run Command, and the Linux hosts only serve one HTTPS page each. If you want
    to sign in to a VM anyway, set your own credentials with az vm user update.

.PARAMETER Mode
Plan     compiles the template and runs what-if; changes nothing. If the resource group doesn't
         exist yet, it only compiles and reports.
Deploy   creates or converges the lab, then installs the connector software unregistered.
Remove   deletes the course-tagged resource group after re-reading its tag.

.PARAMETER SubscriptionId
Optional. The subscription to deploy into. Defaults to your current Azure CLI subscription
(az account show). Nothing in this folder hard-codes a subscription.

.PARAMETER Location
Optional. Azure region for the resource group and everything in it. Defaults to westus2. The
lab needs four free B-series vCPUs in that region; the script checks quota before it deploys.

.EXAMPLE
pwsh -NoProfile -File ./Deploy-C3M04PlantNetwork.ps1 -Mode Plan

Compiles the template and, if the resource group already exists, shows the what-if result.

.EXAMPLE
pwsh -NoProfile -File ./Deploy-C3M04PlantNetwork.ps1 -Mode Deploy

Builds the Azure half. Next, run Set-C3M04PrivateAccess.ps1 -Mode Configure, then -Mode Register.

.EXAMPLE
pwsh -NoProfile -File ./Deploy-C3M04PlantNetwork.ps1 -Mode Deploy -SubscriptionId <your-subscription-id> -Location eastus2

.EXAMPLE
pwsh -NoProfile -File ./Deploy-C3M04PlantNetwork.ps1 -Mode Remove

.NOTES
PREREQUISITES
    PowerShell 7.4 or later. Earlier 7.x releases drop empty native arguments, which breaks
    ssh-keygen -N '' below.
    Azure CLI, signed in with az login, with Bicep installed (az bicep install).
    OpenSSH ssh-keygen on your PATH (included with Windows 10 and later, macOS and Linux).
    Azure role: Contributor or Owner on the subscription. The script creates a resource group,
    deploys into it, and uses Run Command on the connector host.
    Microsoft Entra: nothing for this script. The Entra half needs Application Administrator,
    User Administrator, Conditional Access Administrator and Global Secure Access Administrator
    (or Global Administrator); see Set-C3M04PrivateAccess.ps1.
    Microsoft Entra Private Access needs licensing in your tenant. Check the licensing section of
    "What is Global Secure Access?" on Microsoft Learn:
    https://learn.microsoft.com/entra/global-secure-access/overview-what-is-global-secure-access

COST
    This script creates billable Azure resources: one Standard_B2s Windows VM, two Standard_B1s
    Ubuntu VMs, and their disks. The template's own estimate is about USD 3 a day while the VMs
    run; check the Azure pricing calculator for your region. Every VM stops at 23:00 Central each
    night, but the disks keep billing until you delete the resource group.

CLEANUP
    Azure (deletes everything this script created):
        az group delete --name rg-globomantics-c3m04 --yes --no-wait
    or, with a tag check first and a wait until it's gone:
        pwsh -NoProfile -File ./Deploy-C3M04PlantNetwork.ps1 -Mode Remove
    Microsoft Entra (Conditional Access policy, enterprise application with its segment and
    vendor assignment, vendor account, connector, connector group):
        pwsh -NoProfile -File ./Set-C3M04PrivateAccess.ps1 -Mode Remove
    README.md lists the manual commands for each Entra object if you'd rather remove them by hand.
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Remove')]
    [string]$Mode = 'Plan',

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string]$Location = 'westus2'
)

$ErrorActionPreference = 'Stop'
$group = 'rg-globomantics-c3m04'
$tag = 'SC100-C3M04'
$connectorVm = 'vm-glb-pa-conn01'
$template = Join-Path $PSScriptRoot 'iac/main.bicep'
if (-not (Test-Path -LiteralPath $template)) { throw "Template not found: $template. Keep the iac folder next to this script." }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'The Azure CLI (az) is not on your PATH. Install it, run az login, then rerun.' }

# The subscription comes from YOUR Azure CLI sign-in (or -SubscriptionId), never from this file.
$showArgs = @('account', 'show', '--only-show-errors', '-o', 'json')
if ($SubscriptionId) { $showArgs += @('--subscription', $SubscriptionId) }
$accountJson = & az @showArgs
if ($LASTEXITCODE -ne 0 -or -not $accountJson) { throw 'No usable Azure CLI sign-in. Run az login (and az account set --subscription <your subscription ID>), then rerun.' }
$account = ($accountJson -join "`n") | ConvertFrom-Json
$sub = $account.id

function Invoke-CourseAz {
    # Every call names the subscription explicitly, so changing your CLI default in another window
    # mid-run can't send half of the work somewhere else.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = & az @Arguments --subscription $sub --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI call failed: az $($Arguments[0..1] -join ' ')" }
    if ($out) { ($out -join "`n") | ConvertFrom-Json }
}

function Initialize-PrivateFolder {
    # Owner-only folder for this run's secrets. On Windows, break ACL inheritance and grant only
    # you; on macOS and Linux, mode 700.
    $path = Join-Path ([IO.Path]::GetTempPath()) ('sc100-c3m04-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    if ($IsWindows) {
        $acl = Get-Acl -LiteralPath $path
        $acl.SetAccessRuleProtection($true, $false)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        Set-Acl -LiteralPath $path -AclObject $acl
    } else {
        & chmod 700 $path
        if ($LASTEXITCODE -ne 0) { throw "Couldn't restrict $path to your account." }
    }
    $path
}

Write-Host "[CONTEXT] $($account.user.name) | $($account.name) | $Mode"

# Ownership check: only ever converge or delete a group this lab tagged.
$exists = Invoke-CourseAz @('group', 'exists', '-n', $group)
if ($exists) {
    $current = Invoke-CourseAz @('group', 'show', '-n', $group)
    if ($current.tags.course -ne $tag) { throw "Ownership mismatch: $group is not tagged course=$tag, so this script won't touch it." }
}

if ($Mode -eq 'Remove') {
    if (-not $exists) { Write-Host "[PASS] $group is already absent"; return }
    $recheck = Invoke-CourseAz @('group', 'show', '-n', $group)
    if ($recheck.tags.course -ne $tag) { throw 'Tag changed between checks; refusing to delete.' }
    $null = Invoke-CourseAz @('group', 'delete', '-n', $group, '--yes')
    Write-Host "[PASS] $group removed. Run Set-C3M04PrivateAccess.ps1 -Mode Remove for the Entra half."
    return
}

# Quota: four new vCPUs (one B2s, two B1s) the first time; zero on a converging redeploy.
$vmCount = if ($exists) { @(Invoke-CourseAz @('vm', 'list', '-g', $group)).Count } else { 0 }
$need = if ($vmCount -eq 0) { 4 } else { 0 }
$usage = @(Invoke-CourseAz @('vm', 'list-usage', '-l', $Location))
foreach ($name in 'cores', 'standardBSFamily') {
    $q = @($usage | Where-Object { $_.name.value -eq $name })
    if ($q.Count -ne 1 -or ([int]$q[0].limit - [int]$q[0].currentValue) -lt $need) { throw "Insufficient $name quota in $Location. Pick another region with -Location, or request more quota." }
    Write-Host "[PASS] $name $($q[0].currentValue)/$($q[0].limit), need $need"
}

# Compile before anything is created: a template error should stop the run with nothing changed.
$null = & az bicep build --file $template --stdout --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "Bicep compile failed: $template" }
if ($Mode -eq 'Plan' -and -not $exists) {
    Write-Host "[PLAN] $group doesn't exist yet. Deploy creates it with the course tag; the template compiled cleanly."
    return
}
if ($Mode -eq 'Deploy' -and -not $exists) {
    $null = Invoke-CourseAz @('group', 'create', '-n', $group, '-l', $Location, '--tags', "course=$tag", 'company=Globomantics', 'purpose=demo-fixture', 'teardown=after-course')
    Write-Host "[PASS] Created $group in $Location"
}

$secretDir = Initialize-PrivateFolder
try {
    & ssh-keygen -t ed25519 -N '' -f (Join-Path $secretDir 'lab-key') -q
    if ($LASTEXITCODE -ne 0) { throw 'SSH key generation failed' }
    $pub = (Get-Content -LiteralPath (Join-Path $secretDir 'lab-key.pub') -Raw).Trim()
    # 32 random bytes plus one character from each complexity class Windows requires. Nobody
    # needs to know it: the host is managed through Run Command.
    $password = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) + 'aA1.'
    $param = @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{ windowsAdminPassword = @{ value = $password }; sshPublicKey = @{ value = $pub } }
    }
    # The parameter file keeps the password off the command line, where other processes can read it.
    $parameterFile = Join-Path $secretDir 'parameters.json'
    $param | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $parameterFile
    $action = if ($Mode -eq 'Plan') { 'what-if' } else { 'create' }
    $arguments = @('deployment', 'group', $action, '-g', $group, '--name', 'c3m04-plant-network', '--template-file', $template, '--parameters', "@$parameterFile")
    if ($Mode -eq 'Plan') { $arguments += '--no-pretty-print' }
    $result = Invoke-CourseAz $arguments

    if ($Mode -eq 'Plan') {
        $changes = @($result.changes | Group-Object changeType | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '
        Write-Host "[PLAN] what-if: $changes"
        return
    }
    Write-Host "[RESULT] ARM deployment $($result.properties.provisioningState)"

    # Install the connector software, unregistered. This script runs ON the connector host and is
    # idempotent: it skips the download when the connector service already exists.
    # The download link is the one Microsoft's own marketplace token script on Microsoft Learn
    # downloads. d3c8b69d-6bf7-42be-a529-3fe9c2e70c90 is Microsoft's public, generic download ID for
    # the private network connector installer, not a value from any tenant. REGISTERCONNECTOR="false"
    # and /q are the unattended-install switches from Microsoft Learn.
    $install = @'
$ErrorActionPreference = 'Stop'
$svc = Get-Service | Where-Object { $_.DisplayName -like 'Microsoft Entra private network connector' }
if ($svc) { "ALREADY-INSTALLED $($svc.Status)"; return }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir = Join-Path $env:SystemDrive 'glb'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$installer = Join-Path $dir 'MicrosoftEntraPrivateNetworkConnectorInstaller.exe'
Invoke-WebRequest -UseBasicParsing -Uri 'https://download.msappproxy.net/Subscription/d3c8b69d-6bf7-42be-a529-3fe9c2e70c90/Connector/DownloadConnectorInstaller' -OutFile $installer
Start-Process -FilePath $installer -ArgumentList 'REGISTERCONNECTOR="false"', '/q' -Wait
$svc = Get-Service | Where-Object { $_.DisplayName -like 'Microsoft Entra private network connector*' }
"INSTALLED " + (($svc | ForEach-Object { "$($_.DisplayName)=$($_.Status)" }) -join '; ')
'@
    $scriptFile = Join-Path $secretDir 'install-connector.ps1'
    Set-Content -LiteralPath $scriptFile -Value $install
    $run = Invoke-CourseAz @('vm', 'run-command', 'invoke', '-g', $group, '-n', $connectorVm, '--command-id', 'RunPowerShellScript', '--scripts', "@$scriptFile")
    $out = ($run.value | Where-Object { $_.code -like '*StdOut*' }).message
    Write-Host "[RESULT] Connector host: $($out.Trim())"
} finally {
    # Delete only inside the temporary folder this run created; a wrong path must never reach
    # Remove-Item.
    $resolved = [IO.Path]::GetFullPath($secretDir)
    $allowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $allowed.EndsWith([IO.Path]::DirectorySeparatorChar)) { $allowed += [IO.Path]::DirectorySeparatorChar }
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected temporary path; nothing deleted.' }
    Get-ChildItem -LiteralPath $resolved -File -Force | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Remove-Item -LiteralPath $resolved -Force
}
Write-Host '[NEXT] Set-C3M04PrivateAccess.ps1 -Mode Configure, then -Mode Register -AdminUserPrincipalName <your admin account>, then Show-C3M04PrivateAccess.ps1.'
