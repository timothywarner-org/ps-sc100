/*
  main.bicepparam -- tunables for the SC-100 study toolkit's optional Azure infrastructure.

  deployerPrincipalId is your Entra object ID. It differs per operator, and hardcoding
  it into a committed file is how a repo ends up granting data-plane access to someone
  who left the project. So it is read from the ENVIRONMENT at compile time.

  Why not a `--parameters deployerPrincipalId=...` override on the az command line?
  Because that does not work with a .bicepparam file. Bicep compiles the params file as
  a standalone unit and requires every non-defaulted parameter to be assigned inside it
  -- an unassigned one fails with BCP258 before any CLI override is even considered.
  readEnvironmentVariable() is the supported way to keep a per-operator secret-ish value
  out of source control while still satisfying that rule.

  The deploy scripts set SC100_DEPLOYER_PRINCIPAL_ID before invoking az. To deploy by
  hand:  $env:SC100_DEPLOYER_PRINCIPAL_ID = (az ad signed-in-user show --query id -o tsv)

  Edit this file to change region, SKU, or model. Everything else lives in main.bicep.
*/

using './main.bicep'

// Compile-time environment read. No default: a missing value should fail loudly here
// rather than silently deploying role assignments to an empty principal.
param deployerPrincipalId = readEnvironmentVariable('SC100_DEPLOYER_PRINCIPAL_ID')

// Short prefix for resource names. A uniqueness hash is appended automatically.
param namePrefix = 'sc100kb'

// East US 2 supports both the semantic ranker and text-embedding-3-large at time of
// authoring. If you move region, verify BOTH before deploying -- a region that has the
// model but not the ranker will deploy cleanly and then retrieve badly.
param location = 'eastus2'

// ADR-002: basic, not free. The free tier has no managed identity, which would force
// key-based auth on the MCP server.
param searchSku = 'basic'

// The free billing plan grants a monthly free semantic-ranker request allowance on any
// tier. Ample for one person studying one exam. Switch to 'standard' only if you exhaust it.
param semanticSearchPlan = 'free'

// Keyless. Every caller presents an Entra token. See main.bicep for why this matters
// more than usual in a toolkit for studying Zero Trust architecture.
param disableLocalAuth = true

// 3072-dimension vectors. Changing this model REQUIRES changing VECTOR_DIMENSIONS in
// tools/create_index.py, and re-embedding the entire corpus.
param embeddingModelName = 'text-embedding-3-large'

// Thousands of tokens per minute. 50 ingests ~1,100 chunks without throttling.
param embeddingCapacity = 50
