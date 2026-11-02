<#
.SYNOPSIS
    Deletes the SC-100 study toolkit's optional Azure infrastructure. Stops the hourly billing.

.DESCRIPTION
    This is not a cleanup afterthought; it is half the cost design. Azure AI Search
    Basic bills by the hour whether or not you query it (about $74/month if left
    running). Because every step downstream of the Bicep is reproducible
    (deterministic chunker, content-addressed IDs, idempotent ingest), rebuilding takes
    minutes. So the intended rhythm is: deploy, study, tear down.

    Reproducible infrastructure is what makes deletion affordable. That is a better
    habit than "leave it running and hope."

.PARAMETER ResourceGroup
    Resource group to delete. Must match what deploy.ps1 created.

.PARAMETER SubscriptionId
    Azure subscription. Defaults to your current az CLI context.

.PARAMETER Force
    Skip the confirmation prompt. For CI only.

.PARAMETER Wait
    Block until deletion completes. Default is to return immediately and let Azure
    finish in the background.

.EXAMPLE
    .\teardown.ps1

.EXAMPLE
    .\teardown.ps1 -ResourceGroup rg-sc100-knowledge -Wait

.NOTES
    WHAT THIS DOES NOT TOUCH, and this is the reassuring part:

      * Your downloaded corpus in corpus/
      * index/learn-chunks.jsonl and its stats report
      * index/learn-chroma, your local vector store, which never lived in Azure
      * Any ADR, script, or note in this toolkit

    Only the Azure resources go. Everything needed to recreate them stays on disk.
#>

[CmdletBinding()]
param(
    [string] $ResourceGroup = 'rg-sc100-knowledge',
    [string] $SubscriptionId,
    [switch] $Force,
    [switch] $Wait
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [ok] $Message" }

Write-Step 'Checking prerequisites'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found. Install from https://aka.ms/installazurecli."
}

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not logged in to Azure. Run 'az login'." }

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId | Out-Null
    $account = az account show | ConvertFrom-Json
}
Write-Ok "Subscription: $($account.name)"

$exists = az group exists --name $ResourceGroup --output tsv
if ($exists -ne 'true') {
    Write-Host "`nResource group '$ResourceGroup' does not exist. Nothing to tear down." -ForegroundColor Yellow
    exit 0
}

# Show exactly what is about to disappear. A teardown script that deletes without
# enumerating is a teardown script that eventually deletes the wrong resource group.
Write-Step "Resources in '$ResourceGroup'"
$resources = az resource list --resource-group $ResourceGroup --output json | ConvertFrom-Json
if ($resources.Count -eq 0) {
    Write-Ok 'Resource group is empty'
} else {
    $resources | ForEach-Object { Write-Host "    - $($_.type)  $($_.name)" }
}

if (-not $Force) {
    Write-Host ''
    Write-Host "    This deletes the resource group and everything listed above." -ForegroundColor Yellow
    Write-Host "    Your corpus, chunks, and local vector store are NOT affected." -ForegroundColor Yellow
    $answer = Read-Host "    Type the resource group name to confirm"
    if ($answer -ne $ResourceGroup) {
        Write-Host "`nName did not match. Aborted -- nothing was deleted." -ForegroundColor Yellow
        exit 0
    }
}

Write-Step "Deleting '$ResourceGroup'"

if ($Wait) {
    az group delete --name $ResourceGroup --yes --output none
    Write-Ok 'Deleted'
} else {
    az group delete --name $ResourceGroup --yes --no-wait --output none
    Write-Ok 'Deletion started in the background'
    Write-Host "    Check progress with: az group exists --name $ResourceGroup"
}

# The .env now points at endpoints that are gone. Leaving it in place would produce a
# confusing connection error later, so retire it rather than delete it -- the values
# are still useful as a record of what was deployed.
$toolkitRoot = Split-Path -Parent $PSScriptRoot
$envFile     = Join-Path $toolkitRoot '.env'
if (Test-Path $envFile) {
    $retired = Join-Path $toolkitRoot '.env.torn-down'
    Move-Item -Path $envFile -Destination $retired -Force
    Write-Ok "Retired .env -> .env.torn-down (endpoints no longer exist)"
}

Write-Host @"

============================================================
  Torn down. Billing stopped.
============================================================

  Still on disk, ready to rebuild:
    index/learn-chunks.jsonl      the chunked corpus
    index/learn-chroma/           your local vector store, never was in Azure
    docs/ADR-001 to ADR-003       the decisions

  With .env retired, the MCP server is back on its local default.

  To bring it all back:
    .\deploy.ps1
    uv run python tools/create_index.py
    uv run python tools/ingest_azure.py

============================================================

"@ -ForegroundColor Green
