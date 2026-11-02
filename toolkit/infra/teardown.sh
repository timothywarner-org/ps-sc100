#!/usr/bin/env bash
#
# teardown.sh -- delete the SC-100 study toolkit's optional Azure infrastructure.
# Bash twin of teardown.ps1.
#
# This is not a cleanup afterthought, it is half the cost design. Azure AI Search Basic
# bills hourly whether queried or not (about $74/month if left running). Because
# everything downstream of the Bicep is reproducible (deterministic chunker,
# content-addressed IDs, idempotent ingest), rebuilding takes minutes. Deploy, study,
# tear down.
#
# WHAT THIS DOES NOT TOUCH:
#   * your downloaded corpus in corpus/
#   * index/learn-chunks.jsonl and its stats report
#   * index/learn-chroma, your local vector store, which never lived in Azure
#   * any ADR, script, or note in this toolkit
#
# Usage:
#   ./teardown.sh
#   ./teardown.sh --resource-group rg-sc100-knowledge --force --wait

set -euo pipefail

RESOURCE_GROUP="rg-sc100-knowledge"
SUBSCRIPTION=""
FORCE=0
WAIT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_ROOT="$(dirname "$SCRIPT_DIR")"

step() { printf '\n==> %s\n' "$1"; }
ok()   { printf '    [ok] %s\n' "$1"; }
die()  { printf '\n[error] %s\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --subscription)   SUBSCRIPTION="$2"; shift 2 ;;
    --force|-f)       FORCE=1; shift ;;
    --wait)           WAIT=1; shift ;;
    -h|--help)        sed -n '2,21p' "$0"; exit 0 ;;
    *)                die "Unknown argument: $1" ;;
  esac
done

step "Checking prerequisites"
command -v az >/dev/null 2>&1 || die "Azure CLI not found."
az account show >/dev/null 2>&1 || die "Not logged in to Azure. Run 'az login'."
[[ -n "$SUBSCRIPTION" ]] && az account set --subscription "$SUBSCRIPTION"
ok "Subscription: $(az account show --query name -o tsv)"

if [[ "$(az group exists --name "$RESOURCE_GROUP" -o tsv)" != "true" ]]; then
  printf "\nResource group '%s' does not exist. Nothing to tear down.\n" "$RESOURCE_GROUP"
  exit 0
fi

# Enumerate before deleting. A teardown script that deletes without showing what it is
# about to remove is one that eventually removes the wrong resource group.
step "Resources in '$RESOURCE_GROUP'"
az resource list --resource-group "$RESOURCE_GROUP" \
  --query "[].{type:type,name:name}" -o tsv | sed 's/^/    - /' || true

if [[ $FORCE -eq 0 ]]; then
  printf '\n    This deletes the resource group and everything listed above.\n'
  printf '    Your corpus, chunks, and local vector store are NOT affected.\n'
  read -r -p "    Type the resource group name to confirm: " ANSWER
  if [[ "$ANSWER" != "$RESOURCE_GROUP" ]]; then
    printf '\nName did not match. Aborted -- nothing was deleted.\n'
    exit 0
  fi
fi

step "Deleting '$RESOURCE_GROUP'"
if [[ $WAIT -eq 1 ]]; then
  az group delete --name "$RESOURCE_GROUP" --yes --output none
  ok "Deleted"
else
  az group delete --name "$RESOURCE_GROUP" --yes --no-wait --output none
  ok "Deletion started in the background"
  printf '    Check progress with: az group exists --name %s\n' "$RESOURCE_GROUP"
fi

# The .env now points at endpoints that no longer exist. Retire rather than delete:
# the values remain a useful record of what was deployed.
if [[ -f "$TOOLKIT_ROOT/.env" ]]; then
  mv -f "$TOOLKIT_ROOT/.env" "$TOOLKIT_ROOT/.env.torn-down"
  ok "Retired .env -> .env.torn-down (endpoints no longer exist)"
fi

cat <<EOF

============================================================
  Torn down. Billing stopped.
============================================================

  Still on disk, ready to rebuild:
    index/learn-chunks.jsonl      the chunked corpus
    index/learn-chroma/           your local vector store, never was in Azure
    docs/ADR-001 to ADR-003       the decisions

  With .env retired, the MCP server is back on its local default.

  To bring it all back:
    ./deploy.sh
    uv run python tools/create_index.py
    uv run python tools/ingest_azure.py

============================================================

EOF
