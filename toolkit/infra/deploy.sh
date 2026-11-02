#!/usr/bin/env bash
#
# deploy.sh -- the OPTIONAL Azure AI Search infrastructure for the SC-100 study
# toolkit, bash edition. The default local path needs none of this and costs nothing.
#
# Behavioural twin of deploy.ps1, for macOS / Linux / WSL. Same template, same
# parameter file, same generated .env. Kept in step deliberately: a repo where the
# PowerShell and bash paths drift is a repo where "works on my machine" becomes a
# real answer.
#
# Safe to re-run. ARM is declarative and every role assignment uses a deterministic
# GUID, so a second run reconciles instead of duplicating.
#
# COST: creates Azure AI Search Basic, which bills hourly whether queried or not.
# The intended pattern is ephemeral -- deploy, ingest, work, ./teardown.sh.
#
# Usage:
#   ./deploy.sh
#   ./deploy.sh --subscription <id> --resource-group rg-sc100-knowledge --yes
#
# Requires: az CLI (logged in), and Owner or User Access Administrator on the
# target scope, because the template creates role assignments.

set -euo pipefail

RESOURCE_GROUP="rg-sc100-knowledge"
LOCATION="eastus2"
SUBSCRIPTION=""
SKIP_CONFIRM=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_ROOT="$(dirname "$SCRIPT_DIR")"
BICEP_FILE="$SCRIPT_DIR/main.bicep"
PARAM_FILE="$SCRIPT_DIR/main.bicepparam"
ENV_FILE="$TOOLKIT_ROOT/.env"

step() { printf '\n==> %s\n' "$1"; }
ok()   { printf '    [ok] %s\n' "$1"; }
warn() { printf '    [warning] %s\n' "$1"; }
die()  { printf '\n[error] %s\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription)   SUBSCRIPTION="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --location)       LOCATION="$2"; shift 2 ;;
    --yes|-y)         SKIP_CONFIRM=1; shift ;;
    -h|--help)        sed -n '2,25p' "$0"; exit 0 ;;
    *)                die "Unknown argument: $1" ;;
  esac
done

# --------------------------------------------------------------------------
# Prerequisites
# --------------------------------------------------------------------------

step "Checking prerequisites"

command -v az >/dev/null 2>&1 || die "Azure CLI not found. See https://aka.ms/installazurecli"
az account show >/dev/null 2>&1 || die "Not logged in to Azure. Run 'az login'."

[[ -n "$SUBSCRIPTION" ]] && az account set --subscription "$SUBSCRIPTION"

SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
ok "Subscription: $SUB_NAME  [$SUB_ID]"

# Resolved at run time, never committed. See main.bicepparam for why.
#
# Primary path is Microsoft Graph. It depends on a Graph token the CLI may not hold yet
# -- right after a device-code login this can return empty on first call -- and it fails
# for service principals without directory read permission.
PRINCIPAL_ID=$(az ad signed-in-user show --query id --output tsv 2>/dev/null || true)

if [[ -z "$PRINCIPAL_ID" ]]; then
  # Fallback: read the `oid` claim from the ARM access token we already hold. No Graph
  # call, no extra permission, works for users and service principals alike.
  PRINCIPAL_ID=$(az account get-access-token --output json 2>/dev/null \
    | python3 -c "
import base64, json, sys
try:
    tok = json.load(sys.stdin)['accessToken'].split('.')[1]
    tok += '=' * (-len(tok) % 4)
    print(json.loads(base64.urlsafe_b64decode(tok)).get('oid', ''))
except Exception:
    print('')
" 2>/dev/null || true)
  [[ -n "$PRINCIPAL_ID" ]] && warn "Graph lookup returned nothing; used the token's oid claim instead."
fi

[[ -n "$PRINCIPAL_ID" ]] || die "Could not resolve your Entra object ID by Graph lookup or token claim. Pass it explicitly: --parameters deployerPrincipalId=<objectId>"
ok "Deploying principal: $PRINCIPAL_ID"

# main.bicepparam reads this at compile time via readEnvironmentVariable(). A
# --parameters override cannot supply it -- see the comment in main.bicepparam.
export SC100_DEPLOYER_PRINCIPAL_ID="$PRINCIPAL_ID"

[[ -f "$BICEP_FILE" ]] || die "Template not found: $BICEP_FILE"
[[ -f "$PARAM_FILE" ]] || die "Parameter file not found: $PARAM_FILE"
ok "Template and parameter file present"

# --------------------------------------------------------------------------
# Cost gate -- state the real number before spending
# --------------------------------------------------------------------------

step "Cost"

if HOURLY=$(curl -fsS --max-time 20 --get --data-urlencode "\$filter=serviceName eq 'Azure Cognitive Search' and armRegionName eq '$LOCATION' and skuName eq 'Basic'" \
              "https://prices.azure.com/api/retail/prices" 2>/dev/null \
            | python3 -c "import sys,json;i=[x for x in json.load(sys.stdin)['Items'] if x['unitOfMeasure']=='1 Hour'];print(i[0]['retailPrice'] if i else '')" 2>/dev/null); then
  if [[ -n "$HOURLY" ]]; then
    MONTHLY=$(python3 -c "print(round($HOURLY*730,2))")
    printf '    Azure AI Search Basic in %s: $%s/hour  (~$%s/month if left running)\n' "$LOCATION" "$HOURLY" "$MONTHLY"
    printf '    Billing is hourly. Run ./teardown.sh when you are done for the day.\n'
  fi
else
  warn "Could not reach the Azure retail price API. Verify at https://azure.microsoft.com/pricing/details/search/"
fi

if [[ $SKIP_CONFIRM -eq 0 ]]; then
  read -r -p "    Proceed with deployment? (yes/no) " ANSWER
  case "$ANSWER" in
    y|Y|yes|YES) ;;
    *) printf '\nAborted. Nothing was created.\n'; exit 0 ;;
  esac
fi

# --------------------------------------------------------------------------
# Deploy
# --------------------------------------------------------------------------

step "Resource group: $RESOURCE_GROUP"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
ok "Resource group ready"

step "Validating template"
az deployment group validate \
  --resource-group "$RESOURCE_GROUP" \
  --template-file  "$BICEP_FILE" \
  --parameters     "$PARAM_FILE" \
  --output none
ok "Template valid"

step "Deploying (this typically takes 3-6 minutes)"
DEPLOYMENT_NAME="sc100-kb-$(date +%Y%m%d-%H%M%S)"

az deployment group create \
  --name           "$DEPLOYMENT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --template-file  "$BICEP_FILE" \
  --parameters     "$PARAM_FILE" \
  --output none
ok "Deployment succeeded: $DEPLOYMENT_NAME"

# --------------------------------------------------------------------------
# Materialize .env from outputs
# --------------------------------------------------------------------------

step "Writing .env"

get_output() {
  az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" \
    --query "properties.outputs.$1.value" -o tsv
}

SEARCH_ENDPOINT=$(get_output searchEndpoint)
SEARCH_NAME=$(get_output searchServiceName)
FOUNDRY_ENDPOINT=$(get_output foundryEndpoint)
FOUNDRY_NAME=$(get_output foundryName)
EMBED_DEPLOY=$(get_output embeddingDeployment)
EMBED_MODEL=$(get_output embeddingModel)
STORAGE_ACCOUNT=$(get_output storageAccountName)
BLOB_ENDPOINT=$(get_output storageBlobEndpoint)
CORPUS_SRC=$(get_output corpusSourceContainer)
CORPUS_ART=$(get_output corpusArtifactsContainer)
RG_OUT=$(get_output resourceGroupName)
LOC_OUT=$(get_output location)

cat > "$ENV_FILE" <<EOF
# Generated by infra/deploy.sh on $(date '+%Y-%m-%d %H:%M:%S').
# Do not commit this file -- see .gitignore. Regenerate by re-running deploy.sh.
#
# There are no secrets here on purpose. The search service refuses API keys
# (disableLocalAuth=true); every client authenticates with Entra ID via
# DefaultAzureCredential, which picks up your 'az login' session automatically.

AZURE_SUBSCRIPTION_ID=$SUB_ID
AZURE_RESOURCE_GROUP=$RG_OUT
AZURE_LOCATION=$LOC_OUT

AZURE_SEARCH_ENDPOINT=$SEARCH_ENDPOINT
AZURE_SEARCH_SERVICE=$SEARCH_NAME
AZURE_SEARCH_INDEX=sc100-learn

AZURE_FOUNDRY_ENDPOINT=$FOUNDRY_ENDPOINT
AZURE_FOUNDRY_NAME=$FOUNDRY_NAME
AZURE_EMBEDDING_DEPLOYMENT=$EMBED_DEPLOY
AZURE_EMBEDDING_MODEL=$EMBED_MODEL

# Corpus snapshot archive. A private provenance store, NOT an ingestion source:
# nothing in Azure reads from it. Keep it private.
AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT
AZURE_STORAGE_BLOB_ENDPOINT=$BLOB_ENDPOINT
AZURE_CORPUS_SOURCE_CONTAINER=$CORPUS_SRC
AZURE_CORPUS_ARTIFACTS_CONTAINER=$CORPUS_ART

# Retrieval backend for the MCP server. Switch to azure after ingest_azure.py runs.
SC100_BACKEND=local

# Local paths. Relative values resolve against the toolkit folder.
SC100_CHROMA_PATH=./index/learn-chroma
SC100_CHUNKS=./index/learn-chunks.jsonl
SC100_CORPUS_DIR=./corpus
EOF

ok ".env written to $ENV_FILE"

cat <<EOF

============================================================
  Infrastructure ready.
============================================================

  Search    $SEARCH_ENDPOINT
  Foundry   $FOUNDRY_ENDPOINT
  Embedding $EMBED_DEPLOY
  Storage   $BLOB_ENDPOINT  (corpus-source, corpus-artifacts)

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
    ./teardown.sh

============================================================

EOF
