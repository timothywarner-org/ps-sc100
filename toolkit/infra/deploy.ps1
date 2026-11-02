<#
.SYNOPSIS
    Deploys the OPTIONAL Azure AI Search infrastructure for the SC-100 study toolkit
    and writes the .env the Python tooling reads.

.DESCRIPTION
    You do not need this for the default local path, which costs nothing.

    Wraps `az group create` + `az deployment group create` and then converts the
    deployment outputs into a .env file at the toolkit root, so no endpoint is ever
    copied by hand.

    Safe to re-run. ARM deployments are declarative and every role assignment in
    main.bicep uses a deterministic GUID, so a second run reconciles rather than
    duplicating.

    COST: this creates an Azure AI Search Basic service, which bills hourly whether
    you query it or not. The intended pattern is ephemeral -- deploy, ingest, work,
    then .\teardown.ps1. The script prints the current retail rate before creating
    anything and requires you to confirm.

.PARAMETER SubscriptionId
    Azure subscription to deploy into. Defaults to your current az CLI context.

.PARAMETER ResourceGroup
    Resource group name. Created if absent.

.PARAMETER Location
    Azure region. Must support BOTH the semantic ranker and your embedding model.

.PARAMETER SkipConfirm
    Bypass the cost confirmation prompt. For CI, not for the first run.

.EXAMPLE
    .\deploy.ps1
    Deploys to your default subscription using infra/main.bicepparam defaults.

.EXAMPLE
    .\deploy.ps1 -SubscriptionId <your-subscription-id> -ResourceGroup rg-sc100-kb
    Pins the subscription and resource group explicitly.

.NOTES
    Requires: Azure CLI (az) logged in via `az login`, and the Bicep CLI
    (`az bicep install`). Requires Owner or User Access Administrator on the target
    scope, because the template creates role assignments.
#>

[CmdletBinding()]
param(
    [string] $SubscriptionId,
    [string] $ResourceGroup = 'rg-sc100-knowledge',
    [string] $Location      = 'eastus2',
    [switch] $SkipConfirm
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# DELIBERATELY FORCED OFF, and this is the opposite of the obvious choice.
#
# $PSNativeCommandUseErrorActionPreference = $true makes PowerShell throw on any native
# command failure -- which sounds like exactly what we want, and is worse. It throws a
# bare NativeCommandExitException the moment az exits non-zero, BEFORE Assert-Az can run,
# so az's actual error text is discarded. The observed result was:
#
#     Program "az.cmd" ended with non-zero exit code: 1 (0x00000001).
#
# ...for a failure whose real cause was an MFA policy rejection with a remediation URL.
# An exit code with no reason is worse than no guard at all, because it sends you
# debugging the script instead of the actual problem.
#
# Assert-Az captures az's stderr and prints it. Turning the preference OFF is what lets
# it do that job.
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -EA SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$toolkitRoot = Split-Path -Parent $PSScriptRoot
$bicepFile   = Join-Path $PSScriptRoot 'main.bicep'
$paramFile   = Join-Path $PSScriptRoot 'main.bicepparam'
$envFile     = Join-Path $toolkitRoot '.env'

# ---------------------------------------------------------------------------
# WHY THIS HELPER EXISTS -- it caught a real failure that shipped as a success.
#
# PowerShell does NOT apply $ErrorActionPreference = 'Stop' to NATIVE commands.
# `az group create` can fail with a hard authentication error, set $LASTEXITCODE to 1,
# and the script carries straight on. Observed in the wild:
#
#     ==> Resource group: rg-sc100-knowledge
#     ERROR: AADSTS50076 ... multi-factor authentication required
#         [ok] Resource group ready          <-- printed anyway
#
# PowerShell 7.3+ has $PSNativeCommandUseErrorActionPreference to fix this globally,
# but it defaults to False and does not exist at all on Windows PowerShell 5.1. So the
# check is explicit instead of relying on a preference that may not be there.
#
# Call Assert-Az after every az invocation whose failure should stop the run.
# ---------------------------------------------------------------------------
function Assert-Az {
    param([string]$What, [string[]]$Output = @())
    if ($LASTEXITCODE -eq 0) { return }

    $text = ($Output | Out-String)

    # Known failures get a diagnosis instead of a stack trace. Each entry below is a
    # failure this script has actually hit, not a hypothetical.
    $hint = $null

    if ($text -match 'AADSTS50076' -or $text -match 'RequestDisallowedByAzure' -or $text -match 'without authenticating through MFA') {
        $hint = @"
Azure requires multi-factor authentication for management WRITE operations.
Read operations succeed on a cached token, which is why this failed only now.

Note that re-running `az login` alone is NOT enough -- the stale refresh token is
reused. You must clear the cache first:

    az logout
    az login

Details: https://aka.ms/MFAforAzure
"@
    }
    elseif ($text -match 'AuthorizationFailed' -or $text -match "does not have authorization") {
        $hint = @"
Your principal lacks permission at this scope. The template creates role assignments,
which requires Owner or User Access Administrator on the subscription or resource group:

    az role assignment list --assignee (az ad signed-in-user show --query id -o tsv) --all -o table
"@
    }
    elseif ($text -match 'SubscriptionNotFound' -or $text -match 'ResourceGroupNotFound') {
        $hint = "The subscription or resource group was not found. Confirm with: az account show -o table"
    }
    elseif ($text -match 'BCP\d+') {
        $hint = "A Bicep compilation error. Reproduce it directly with: az bicep build --file infra/main.bicep --stdout"
    }

    $detail = if ($text.Trim()) { "`n`n" + (($Output | Select-Object -First 15) -join "`n") } else { "" }
    $guidance = if ($hint) { "`n`n$hint" } else { "" }

    throw "$What failed (az exit code $LASTEXITCODE).$detail$guidance"
}

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [ok] $Message" }
function Write-Warn { param([string]$Message) Write-Host "    [warning] $Message" }

# ---------------------------------------------------------------------------
# Prerequisites. Every check here exists because skipping it produces a confusing
# failure several minutes later instead of a clear one now.
# ---------------------------------------------------------------------------

# NOTE ON `--output json`, WHICH IS NOT DECORATIVE:
# Every az call below that gets piped to ConvertFrom-Json passes --output json
# explicitly. The Azure CLI honours a per-user default set by `az configure --output
# table`, and a table string handed to ConvertFrom-Json fails silently -- producing a
# null object and a script that reports "not logged in" to someone who is definitively
# logged in. Never rely on the ambient output format.

Write-Step 'Checking prerequisites'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found. Install from https://aka.ms/installazurecli, then run 'az login'."
}

$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    throw "Not logged in to Azure. Run 'az login' and try again."
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId | Out-Null
    $account = az account show --output json | ConvertFrom-Json
}
Write-Ok "Subscription: $($account.name)  [$($account.id)]"

# The template creates role assignments, so resolve the caller's object ID rather than
# hardcoding it. This is also the value the committed .bicepparam deliberately omits.
# Primary path: ask Microsoft Graph. Straightforward, but it depends on a Graph token
# the CLI may not hold yet -- immediately after a device-code login this call can come
# back empty on first invocation, and it fails outright for service principals without
# directory read permission.
$principalId = az ad signed-in-user show --query id --output tsv 2>$null

if (-not $principalId) {
    # Fallback: read the `oid` claim straight out of the ARM access token. The object ID
    # is already in the token we hold, so this needs no Graph call, no extra permission,
    # and works identically for a user or a service principal. Strictly more dependable than
    # the Graph call -- it is second only because the Graph call is more obvious to read.
    try {
        $tok = az account get-access-token --output json 2>$null | ConvertFrom-Json
        if ($tok) {
            $payload = $tok.accessToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
            while ($payload.Length % 4) { $payload += '=' }
            $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
            $principalId = $claims.oid
            if ($principalId) { Write-Warn "Graph lookup returned nothing; used the token's oid claim instead." }
        }
    } catch {
        # Deliberately swallowed -- the throw below carries the actionable message.
    }
}

if (-not $principalId) {
    throw "Could not resolve your Entra object ID by Graph lookup or token claim. Pass it explicitly: az deployment group create ... --parameters deployerPrincipalId=<objectId>"
}
Write-Ok "Deploying principal: $principalId"

# main.bicepparam reads this at compile time via readEnvironmentVariable(). A
# --parameters override cannot supply it: Bicep requires a .bicepparam file to assign
# every non-defaulted parameter itself, and fails with BCP258 before the override is
# considered.
$env:SC100_DEPLOYER_PRINCIPAL_ID = $principalId

if (-not (Test-Path $bicepFile))  { throw "Template not found: $bicepFile" }
if (-not (Test-Path $paramFile))  { throw "Parameter file not found: $paramFile" }
Write-Ok 'Template and parameter file present'

# ---------------------------------------------------------------------------
# Cost gate. State the real number before spending the user's money.
# ---------------------------------------------------------------------------

Write-Step 'Cost'

try {
    $priceUri = "https://prices.azure.com/api/retail/prices?`$filter=serviceName eq 'Azure Cognitive Search' and armRegionName eq '$Location' and skuName eq 'Basic'"
    $price    = (Invoke-RestMethod -Uri $priceUri -Method Get -TimeoutSec 20).Items |
                Where-Object { $_.unitOfMeasure -eq '1 Hour' } | Select-Object -First 1
    if ($price) {
        $monthly = [math]::Round($price.retailPrice * 730, 2)
        Write-Host "    Azure AI Search Basic in $($Location): `$$($price.retailPrice)/hour  (~`$$monthly/month if left running)"
        Write-Host "    Billing is hourly. Run .\teardown.ps1 when you are done for the day."
    }
} catch {
    Write-Warn "Could not reach the Azure retail price API. Verify pricing manually at https://azure.microsoft.com/pricing/details/search/"
}

if (-not $SkipConfirm) {
    $answer = Read-Host "    Proceed with deployment? (yes/no)"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host "`nAborted. Nothing was created." -ForegroundColor Yellow
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

Write-Step "Resource group: $ResourceGroup"
$rgOut = az group create --name $ResourceGroup --location $Location --output json 2>&1
Assert-Az -What "az group create" -Output $rgOut
Write-Ok 'Resource group ready'

Write-Step 'Validating template'
$validateOut = az deployment group validate `
    --resource-group $ResourceGroup `
    --template-file  $bicepFile `
    --parameters     $paramFile `
    --output json 2>&1
Assert-Az -What "az deployment group validate" -Output $validateOut
Write-Ok 'Template valid'

Write-Step 'Deploying (this typically takes 3-6 minutes)'
$stamp          = Get-Date -Format 'yyyyMMdd-HHmmss'
$deploymentName = "sc100-kb-$stamp"

$deployOut = az deployment group create `
    --name           $deploymentName `
    --resource-group $ResourceGroup `
    --template-file  $bicepFile `
    --parameters     $paramFile `
    --output json
Assert-Az -What "az deployment group create" -Output $deployOut
$result = $deployOut | ConvertFrom-Json

if (-not $result -or -not $result.properties) {
    throw "Deployment returned no parseable result. Inspect it with: az deployment group show -g $ResourceGroup -n $deploymentName --output json"
}

if ($result.properties.provisioningState -ne 'Succeeded') {
    throw "Deployment finished in state '$($result.properties.provisioningState)'. Inspect it with: az deployment group show -g $ResourceGroup -n $deploymentName"
}
Write-Ok "Deployment succeeded: $deploymentName"

# ---------------------------------------------------------------------------
# Materialize .env from the outputs
# ---------------------------------------------------------------------------

Write-Step 'Writing .env'

$o = $result.properties.outputs

$envLines = @(
    "# Generated by infra/deploy.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss').",
    "# Do not commit this file -- see .gitignore. Regenerate by re-running deploy.ps1.",
    "#",
    "# There are no secrets here on purpose. The search service refuses API keys",
    "# (disableLocalAuth=true); every client authenticates with Entra ID via",
    "# DefaultAzureCredential, which picks up your 'az login' session automatically.",
    "",
    "AZURE_SUBSCRIPTION_ID=$($account.id)",
    "AZURE_RESOURCE_GROUP=$($o.resourceGroupName.value)",
    "AZURE_LOCATION=$($o.location.value)",
    "",
    "AZURE_SEARCH_ENDPOINT=$($o.searchEndpoint.value)",
    "AZURE_SEARCH_SERVICE=$($o.searchServiceName.value)",
    "AZURE_SEARCH_INDEX=sc100-learn",
    "",
    "AZURE_FOUNDRY_ENDPOINT=$($o.foundryEndpoint.value)",
    "AZURE_FOUNDRY_NAME=$($o.foundryName.value)",
    "AZURE_EMBEDDING_DEPLOYMENT=$($o.embeddingDeployment.value)",
    "AZURE_EMBEDDING_MODEL=$($o.embeddingModel.value)",
    "",
    "# Corpus snapshot archive. A private provenance store, NOT an ingestion source:",
    "# nothing in Azure reads from it. Keep it private.",
    "AZURE_STORAGE_ACCOUNT=$($o.storageAccountName.value)",
    "AZURE_STORAGE_BLOB_ENDPOINT=$($o.storageBlobEndpoint.value)",
    "AZURE_CORPUS_SOURCE_CONTAINER=$($o.corpusSourceContainer.value)",
    "AZURE_CORPUS_ARTIFACTS_CONTAINER=$($o.corpusArtifactsContainer.value)",
    "",
    "# Retrieval backend for the MCP server. Switch to azure after ingest_azure.py runs.",
    "SC100_BACKEND=local",
    "",
    "# Local paths. Relative values resolve against the toolkit folder.",
    "SC100_CHROMA_PATH=./index/learn-chroma",
    "SC100_CHUNKS=./index/learn-chunks.jsonl",
    "SC100_CORPUS_DIR=./corpus"
)

$envLines | Set-Content -Path $envFile -Encoding utf8
Write-Ok ".env written to $envFile"

# ---------------------------------------------------------------------------
# Next steps
# ---------------------------------------------------------------------------

Write-Host @"

============================================================
  Infrastructure ready.
============================================================

  Search    $($o.searchEndpoint.value)
  Foundry   $($o.foundryEndpoint.value)
  Embedding $($o.embeddingDeployment.value)
  Storage   $($o.storageBlobEndpoint.value)  (corpus-source, corpus-artifacts)

  Role assignments can take a minute or two to propagate through Entra. If the
  next step returns 403, wait 60 seconds and retry -- that is replication lag,
  not a broken template.

  From the toolkit folder:
    uv sync --group azure
    uv run python tools/create_index.py
    uv run python tools/ingest_azure.py
    uv run python tools/sync_corpus.py --dry-run    # optional snapshot: preview
    uv run python tools/sync_corpus.py              # optional snapshot: upload
  Then set SC100_BACKEND=azure in .env to point the MCP server at the index.

  The search service bills by the hour. When you are done for the day:
    .\teardown.ps1

============================================================

"@ -ForegroundColor Green
