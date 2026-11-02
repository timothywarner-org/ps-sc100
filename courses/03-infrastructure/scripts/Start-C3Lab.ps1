#Requires -Version 7.0

<#
.SYNOPSIS
Starts the stopped virtual machines for one Course 3 lab, and changes nothing else.

.DESCRIPTION
The Module 2 and Module 4 labs shut their VMs down at 11 PM every night so an idle lab doesn't
run all month, so you'll usually find them stopped when you come back. This script finds the
lab's resource group in your current subscription, confirms the group carries that lab's course
tag, and starts only the VMs that carry the same tag.

The tag check is the safety catch. It means this script can't start a VM that the lab didn't
create, even if you happen to have a resource group with the same name.

It never deploys, deletes or reconfigures anything.

Module 1's VMs have no shutdown schedule, so they stay running until you stop or delete them.
Module 3 has no VMs.

.PARAMETER Module
1, 2, 3 or 4.

.PARAMETER SubscriptionId
The subscription that holds the lab. Defaults to your current Azure CLI subscription.

.PARAMETER CheckOnly
Report each VM's power state without starting anything.

.EXAMPLE
pwsh -NoProfile -File .\Start-C3Lab.ps1 -Module 4
Starts any stopped Module 4 lab VMs.

.EXAMPLE
pwsh -NoProfile -File .\Start-C3Lab.ps1 -Module 2 -CheckOnly
Lists the Module 2 VMs and whether each is running, without starting them.

.NOTES
Prerequisites: PowerShell 7, the Azure CLI signed in with az login, and Virtual Machine
Contributor (or Contributor) on the lab's resource group.

Cost: a running VM bills for compute by the minute. When you're done for the day, stop the VMs
(for example: az vm deallocate --ids $(az vm list -g rg-globomantics-c3m02 --query "[].id" -o tsv)),
and when you're done with the lab, delete it with the cleanup commands in that module's README.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 4)]
    [int]$Module,

    [ValidatePattern('^$|^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId = '',

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

function Invoke-Az {
    <# Runs one az command and returns its JSON as objects, or stops with a readable message. #>
    param([Parameter(Mandatory)][string[]]$Arguments)
    $raw = & az @Arguments --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments[0..1] -join ' ') failed. Run az login, check the subscription, then try again."
    }
    if ($raw) { ($raw -join "`n") | ConvertFrom-Json }
}

# Work in the subscription you're signed in to unless you name another one, so the script never
# guesses at a subscription you didn't choose.
$account = Invoke-Az @('account', 'show')
$sub = if ($SubscriptionId) { $SubscriptionId } else { $account.id }
Write-Host "Course 3 Module $Module lab | subscription $($account.name)"

$tag = 'SC100-C3M{0:00}' -f $Module
$group = 'rg-globomantics-c3m{0:00}' -f $Module
# Module 2 keeps its Arc host in a second group, so its VMs live in two places.
$groups = if ($Module -eq 2) { @($group, "$group-host") } else { @($group) }

$found = 0
foreach ($g in $groups) {
    # Parse the CLI's JSON answer rather than compare raw text: on Windows, az runs through a .cmd
    # shim, and its raw output can carry characters that make a plain string comparison fail.
    $exists = Invoke-Az @('group', 'exists', '--name', $g, '--subscription', $sub)
    if ($exists -ne $true) {
        Write-Warning "$g doesn't exist in this subscription. Deploy the Module $Module lab first."
        continue
    }
    $rg = Invoke-Az @('group', 'show', '--name', $g, '--subscription', $sub)
    if ($rg.tags.course -ne $tag) {
        throw "$g doesn't carry the course tag $tag, so it wasn't created by this lab. Nothing started."
    }
    $vms = @(Invoke-Az @('vm', 'list', '-g', $g, '--subscription', $sub))
    foreach ($vm in $vms) {
        if ($vm.tags.course -ne $tag) {
            Write-Warning "Skipping $($vm.name): it doesn't carry the course tag $tag."
            continue
        }
        $found++
        $view = Invoke-Az @('vm', 'get-instance-view', '--ids', $vm.id)
        $power = ($view.instanceView.statuses | Where-Object code -like 'PowerState/*').code
        if ($power -eq 'PowerState/running') { Write-Host "[RUNNING]  $($vm.name)"; continue }
        if ($CheckOnly) { Write-Host "[STOPPED]  $($vm.name)"; continue }
        Write-Host "[STARTING] $($vm.name)"
        $null = Invoke-Az @('vm', 'start', '--ids', $vm.id)
        Write-Host "[RUNNING]  $($vm.name)"
    }
}

if ($found -eq 0) {
    if ($Module -eq 3) {
        Write-Host 'The Module 3 lab has no VMs, so there was nothing to start.'
    } else {
        Write-Host "No lab VMs found for Module $Module. Deploy the lab first with its Deploy script."
    }
}
