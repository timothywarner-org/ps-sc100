#Requires -Version 7.0

<#
.SYNOPSIS
Read-only: the Globomantics Foundry configuration review in plain words.

.DESCRIPTION
The evidence for the SC-100 Course 3, Module 3 demo "Evaluate a Foundry project against the AI
controls". It reads the lab's Foundry resource, the assistant's model deployment and content
filter, and every role assignment held by the two workload identities, then prints three short
sections you can read on one screen:

    RESOURCE              who may call (authentication) and from where (inbound network)
    MODEL DEPLOYMENT      what the content filter blocks, including Prompt Shields
    WORKLOAD PERMISSIONS  what each workload identity may do to Globomantics data

The lab plants one over-broad permission on purpose, and WORKLOAD PERMISSIONS is where you'll
find it: the customer assistant holds Storage Blob Data Contributor on the whole storage
account, so it can write draft orders that belong to the ERP draft-order agent. The content
filter can't catch that, because it governs what the assistant says, not what it may read or
write.

WHY A SCRIPT AND NOT THREE PORTAL BLADES
    The decision the demo teaches is a comparison across three different resource types. In the
    portal that's three blades and a lot of scrolling; here it's one screen, and every value is
    read live from Azure Resource Manager at the moment you run it.

It changes nothing: every call is an HTTP GET to Azure Resource Manager, signed with your Azure
CLI sign-in. It prints no secrets, keys, or subscription IDs. Meaning is carried by words in
every column, never by color. It stops rather than print a section built from a failed read,
because a missing row would look like a finding.

.PARAMETER SubscriptionId
The subscription that holds the lab. Defaults to your current Azure CLI subscription, read with
az account show --query id -o tsv.

.PARAMETER ResourceGroup
The lab's resource group, created by Deploy-C3M03FoundryReview.ps1. Defaults to
rg-globomantics-c3m03.

.EXAMPLE
pwsh -NoProfile -File .\Show-C3M03FoundryReview.ps1
Reads the lab in your current Azure CLI subscription and prints the review.

.EXAMPLE
pwsh -NoProfile -File .\Show-C3M03FoundryReview.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000
Reads the lab in a named subscription. Replace the zeros with your own subscription ID.

.NOTES
PREREQUISITES
    * PowerShell 7 and the Azure CLI, signed in with az login.
    * The lab deployed with: pwsh -NoProfile -File .\Deploy-C3M03FoundryReview.ps1 -Mode Deploy
    * Reader on the subscription. The script lists role assignments across the whole
      subscription, so it shows every permission each identity holds, not only the ones inside
      the lab's resource group.

COST
    This script is read-only and creates nothing. The lab it reads does create billable Azure
    resources; see Deploy-C3M03FoundryReview.ps1 and remove the lab when you finish.

CLEANUP
    pwsh -NoProfile -File .\Deploy-C3M03FoundryReview.ps1 -Mode Remove

    Or by hand. Foundry resources are soft-deleted, so purge the account once the group delete
    finishes, or its name stays reserved:
    az group delete --name rg-globomantics-c3m03 --yes --no-wait
    az cognitiveservices account list-deleted -o table
    az cognitiveservices account purge --resource-group rg-globomantics-c3m03 --name <foundry-name> --location <region>
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [PSDefaultValue(Help = 'Your current Azure CLI subscription (az account show --query id -o tsv)')]
    [string]$SubscriptionId,

    [ValidatePattern('^[-\w\._\(\)]{1,90}$')]
    [string]$ResourceGroup = 'rg-globomantics-c3m03'
)

$ErrorActionPreference = 'Stop'
$api = '2025-06-01'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'The Azure CLI (az) is not on your PATH. Install it, run az login, then rerun this script.'
}

# No subscription supplied: use the one your Azure CLI session already points at.
if (-not $SubscriptionId) {
    $current = & az account show --query id -o tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $current) { throw 'No Azure CLI sign-in found. Run az login, then rerun this script.' }
    $SubscriptionId = "$current".Trim()
}
$base = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"

# One Azure Resource Manager token from your Azure CLI sign-in, reused for every read. The reads
# go straight to the REST API rather than through az rest because on Windows az runs through a
# batch file, and cmd.exe treats the '&' in the role-assignment query as a command separator,
# which silently truncates the URL.
$token = & az account get-access-token --subscription $SubscriptionId --resource https://management.azure.com/ --query accessToken -o tsv --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not get an Azure Resource Manager token. Run az login, then rerun this script.' }
$headers = @{ Authorization = "Bearer $token" }

function Get-Arm {
    param([Parameter(Mandatory)][string]$Uri)
    try {
        Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -ErrorAction Stop
    } catch {
        # Name the path that failed, minus the subscription ID, and stop: a guess here would
        # print as if it were a real setting.
        $status = if ($_.Exception.Response) { " (HTTP $([int]$_.Exception.Response.StatusCode))" } else { '' }
        $path = ([uri]$Uri).AbsolutePath -replace '/subscriptions/[^/]+', '/subscriptions/<id>'
        throw "Read failed$($status): $path. Nothing was inferred."
    }
}

# Built-in role definition IDs are identical in every Azure tenant, so this lookup works in yours.
# It translates them to the names you see in the portal.
$roleNames = @{
    'ba92f5b4-2d11-453d-a403-e96b0029c9fe' = 'Storage Blob Data Contributor'
    '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' = 'Storage Blob Data Reader'
    '53ca6127-db72-4b80-b1b0-d745d6d5456d' = 'Foundry User'
}
# Plain-language names for the two workloads, so the table reads as business roles, not resource names.
$workloads = [ordered]@{
    'id-glb-customer-assistant' = 'customer assistant'
    'id-glb-erp-draft-agent'    = 'ERP draft-order agent'
}

# ---- Resource: the Foundry account in the lab group ------------------------------------------
$accounts = @((Get-Arm "$base/providers/Microsoft.CognitiveServices/accounts?api-version=$api").value)
if ($accounts.Count -eq 0) {
    throw "No Foundry resource found in $ResourceGroup. Deploy the lab first: pwsh -NoProfile -File .\Deploy-C3M03FoundryReview.ps1 -Mode Deploy"
}
if ($accounts.Count -gt 1) {
    Write-Warning "Found $($accounts.Count) Foundry resources in $ResourceGroup; the lab builds one. Reviewing $($accounts[0].name)."
}
$acct = $accounts[0]
$projects = @((Get-Arm "https://management.azure.com$($acct.id)/projects?api-version=$api").value)
$auth = if ($acct.properties.disableLocalAuth) { 'Microsoft Entra ID only (local keys disabled)' } else { 'Keys AND Microsoft Entra ID (local keys enabled)' }
$inbound = switch ("$($acct.properties.publicNetworkAccess)/$($acct.properties.networkAcls.defaultAction)") {
    'Enabled/Allow' { 'Public, from all networks' }
    'Enabled/Deny'  { 'Public, from selected networks only' }
    default         { 'Public access disabled (private endpoints only)' }
}

# ---- Model deployment and its content filter --------------------------------------------------
$deployments = @((Get-Arm "https://management.azure.com$($acct.id)/deployments?api-version=$api").value)
if ($deployments.Count -eq 0) {
    throw "No model deployment found on $($acct.name). Rerun: pwsh -NoProfile -File .\Deploy-C3M03FoundryReview.ps1 -Mode Deploy"
}
# The lab's deployment is glb-assistant; fall back to the first one so a renamed lab still reads.
$dep = $deployments | Where-Object name -eq 'glb-assistant' | Select-Object -First 1
if (-not $dep) {
    $dep = $deployments[0]
    Write-Warning "Deployment glb-assistant wasn't found; reviewing $($dep.name) instead."
}
$filterName = $dep.properties.raiPolicyName
if (-not $filterName) { throw "Deployment $($dep.name) has no content filter attached, so the MODEL DEPLOYMENT section can't be read." }
$filter = Get-Arm "https://management.azure.com$($acct.id)/raiPolicies/$($filterName)?api-version=$api"

function Get-FilterState {
    param([Parameter(Mandatory)][object]$Policy, [Parameter(Mandatory)][string]$Name)
    $f = @($Policy.properties.contentFilters | Where-Object { $_.name -eq $Name -and $_.source -eq 'Prompt' })
    if (-not $f) { return 'not configured' }
    if (-not $f[0].enabled) { return 'off' }
    if ($f[0].blocking) { 'blocking on prompts' } else { 'annotating only (not blocking)' }
}
# Four harm categories on both prompts and completions make eight entries when fully configured.
$harms = @($filter.properties.contentFilters | Where-Object { $_.name -in 'Hate', 'Sexual', 'Violence', 'Selfharm' })
$harmLine = if ($harms.Count -eq 8 -and -not ($harms | Where-Object { -not $_.blocking -or $_.severityThreshold -ne 'Medium' })) {
    'Hate, Sexual, Violence, Self-harm: blocking at Medium on prompts and completions'
} else { 'Mixed settings; open this content filter in the Foundry portal for detail' }

# ---- Workload permissions: every role assignment each identity holds, anywhere in scope ------
$identities = @((Get-Arm "$base/providers/Microsoft.ManagedIdentity/userAssignedIdentities?api-version=2023-01-31").value)
$rows = foreach ($name in $workloads.Keys) {
    $id = $identities | Where-Object name -eq $name
    if (-not $id) {
        # Print the gap as a row rather than drop it: a silent omission would read as "no access".
        Write-Warning "Identity $name wasn't found in $ResourceGroup."
        [pscustomobject]@{ Workload = $workloads[$name]; Role = '(identity not found)'; Scope = '-' }
        continue
    }
    $filterExpr = [uri]::EscapeDataString("principalId eq '$($id.properties.principalId)'")
    $assignments = @((Get-Arm "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleAssignments?`$filter=$filterExpr&api-version=2022-04-01").value)
    if ($assignments.Count -eq 0) {
        [pscustomobject]@{ Workload = $workloads[$name]; Role = '(no role assignments)'; Scope = '-' }
    }
    foreach ($a in $assignments) {
        $roleId = ($a.properties.roleDefinitionId -split '/')[-1]
        $scope = $a.properties.scope
        # Translate the scope path into plain words.
        $where = switch -Regex ($scope) {
            '/blobServices/default/containers/([^/]+)$'                      { "container $($Matches[1]) only"; break }
            '/Microsoft\.Storage/storageAccounts/[^/]+$'                     { 'whole storage account (every container)'; break }
            '/Microsoft\.CognitiveServices/accounts/[^/]+/projects/([^/]+)$' { "project $($Matches[1])"; break }
            default                                                          { $scope }
        }
        [pscustomobject]@{
            Workload = $workloads[$name]
            Role     = if ($roleNames.ContainsKey($roleId)) { $roleNames[$roleId] } else { "role $roleId" }
            Scope    = $where
        }
    }
}

# ---- Print ---------------------------------------------------------------------------------
Write-Host ''
Write-Host 'Globomantics customer experience: Foundry configuration review (read-only)'
Write-Host ''
Write-Host "RESOURCE  $($acct.name)"
Write-Host ('  {0,-22}{1}' -f 'Authentication', $auth)
Write-Host ('  {0,-22}{1}' -f 'Inbound network', $inbound)
Write-Host ('  {0,-22}{1}' -f 'Project', (($projects | ForEach-Object { ($_.name -split '/')[-1] }) -join ', '))
Write-Host ''
Write-Host "MODEL DEPLOYMENT  $($dep.name) ($($dep.properties.model.name) $($dep.properties.model.version))"
Write-Host ('  {0,-22}{1}' -f 'Content filter', $filterName)
Write-Host ('  {0,-22}{1}' -f 'Prompt Shields', "Jailbreak: $(Get-FilterState $filter 'Jailbreak')  |  Indirect attack: $(Get-FilterState $filter 'Indirect Attack')")
Write-Host ('  {0,-22}{1}' -f 'Harm categories', $harmLine)
Write-Host ''
Write-Host 'WORKLOAD PERMISSIONS'
$rows | Sort-Object Workload, Role | Format-Table Workload, Role, Scope -AutoSize | Out-String -Width 160 | Write-Host
