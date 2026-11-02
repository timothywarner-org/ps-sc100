/*
  main.bicep -- SC-100 study toolkit, OPTIONAL Azure AI Search infrastructure.

  You do not need any of this. The default local path (Chroma on your disk) costs
  nothing. Deploy this only if you want BM25 plus the semantic ranker on top of vector
  search, and tear it down the same day.

  WHAT THIS DEPLOYS
  -----------------
    Microsoft Foundry account (Cognitive Services, kind 'AIServices')
      + a text-embedding-3-large deployment
    Azure AI Search, Basic SKU, system-assigned managed identity
    Storage account with corpus-source and corpus-artifacts containers (archive only)
    Five role assignments that make the whole thing work without a single API key

  WHAT THIS DELIBERATELY DOES NOT DEPLOY
  --------------------------------------
    No indexer. No data source. No skillset. No Document Intelligence.

    The storage account above is an ARCHIVE, not an ingestion source: nothing in
    Azure reads from it. See the Storage section for why that distinction matters.

    Indexers and skillsets belong to the "let Azure chunk it" architecture, which
    ADR-002 rejects for this corpus: the source is already clean Markdown carrying
    H2/H3 structure and a Source: URL on every unit, so paying a layout model to
    re-derive that structure would cost money, endanger the provenance line, and make
    chunking impossible to git-diff. Chunking happens locally in tools/chunk_learn.py
    and the documents are PUSHED. The index still gets a query-time vectorizer, which
    is where integrated vectorization genuinely earns its keep.

  KEYLESS BY DEFAULT
  ------------------
  `disableLocalAuth` is true, so the search service will not accept API keys at all.
  Every caller (the ingest scripts, the MCP server, you at the CLI) authenticates with
  Microsoft Entra ID. For a toolkit that helps you study SC-100 this is not decoration:
  hardcoding an admin key in a Zero Trust study project teaches the opposite of the
  lesson. Set disableLocalAuth=false only if a tool you need genuinely cannot do token
  auth.

  COST: READ BEFORE DEPLOYING
  ---------------------------
  Azure AI Search Basic in East US 2 was $0.101/hour when this was written (about
  $74/month if left running). It bills hourly whether you query it or not, and
  everything downstream of this template is reproducible, so the intended pattern is
  EPHEMERAL: deploy, ingest, study, then run teardown.ps1. Rebuilding takes minutes.
  deploy.ps1 prints the live retail rate for your region before it creates anything.

  DEPLOY
  ------
    ./deploy.ps1                 (Windows / PowerShell)
    ./deploy.sh                  (bash / macOS / Linux / WSL)

  Both wrap: az group create + az deployment group create. Re-running is safe --
  ARM deployments are declarative, and every role assignment below uses a
  deterministic GUID so a second run updates rather than duplicating.
*/

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Short prefix for resource names. Lowercase alphanumeric; a uniqueness suffix is appended automatically.')
@minLength(3)
@maxLength(11)
param namePrefix string = 'sc100kb'

@description('Azure region. Must support Azure AI Search semantic ranker AND your chosen embedding model. eastus2 satisfies both at time of authoring.')
param location string = resourceGroup().location

@description('Object ID of the principal that will run the ingest scripts and the MCP server -- normally your own user. Get it with: az ad signed-in-user show --query id -o tsv')
param deployerPrincipalId string

@description('Principal type of deployerPrincipalId. Setting this correctly avoids spurious "principal not found" failures caused by Entra replication lag.')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param deployerPrincipalType string = 'User'

@description('Azure AI Search SKU. ADR-002 selects basic: the free tier has no managed identity, and its semantic ranker support is region-dependent and contradicted across Microsoft docs.')
@allowed([
  'free'
  'basic'
  'standard'
])
param searchSku string = 'basic'

@description('Semantic ranker billing plan. "free" grants a monthly free request allowance on any tier and is ample for one person studying one exam. "standard" is pay-as-you-go past that allowance and requires basic or higher.')
@allowed([
  'disabled'
  'free'
  'standard'
])
param semanticSearchPlan string = 'free'

@description('Refuse API-key authentication on the search service. Leave true unless a tool you need cannot present an Entra token.')
param disableLocalAuth bool = true

@description('Embedding model to deploy. ADR-002 assumes 3072-dimension vectors; changing this requires changing the index schema in tools/create_index.py to match.')
param embeddingModelName string = 'text-embedding-3-large'

@description('Model version. Left empty to accept the Foundry default, which avoids a template that breaks when Microsoft retires a pinned version.')
param embeddingModelVersion string = ''

@description('Embedding deployment SKU name.')
param embeddingSkuName string = 'Standard'

@description('Embedding capacity in thousands of tokens per minute. 50 comfortably ingests a ~1,100 chunk corpus; raise only if your subscription quota allows.')
@minValue(1)
param embeddingCapacity int = 50

@description('Tags applied to every resource.')
param tags object = {
  project: 'sc100-study-toolkit'
  purpose: 'sc100-exam-study'
  lifecycle: 'ephemeral'
  managedBy: 'bicep'
}

// ---------------------------------------------------------------------------
// Naming
//
// Search service names are GLOBALLY unique, so a bare prefix would collide the first
// time this template is deployed twice. uniqueString() derives a stable 13-character
// hash from the resource group ID: same RG always yields the same name, which is what
// keeps redeployment idempotent instead of sprawling.
// ---------------------------------------------------------------------------

var suffix = uniqueString(resourceGroup().id)
var searchName = toLower('${namePrefix}-search-${suffix}')
var foundryName = toLower('${namePrefix}-foundry-${suffix}')
var embeddingDeploymentName = embeddingModelName

// Storage account names allow only lowercase alphanumerics, 3-24 characters -- no
// hyphens, unlike every other resource here. take() guards the ceiling so an unusually
// long namePrefix produces a short name rather than a deployment error.
var storageName = take(toLower(replace('${namePrefix}st${suffix}', '-', '')), 24)

// Built-in role definition GUIDs. Verified against the Azure built-in roles reference
// rather than recalled -- a wrong GUID here produces a deployment that succeeds and an
// application that gets 403 at runtime, which is an expensive way to find a typo.
var roleIds = {
  // Read/write access to index DATA. Needed to push documents.
  searchIndexDataContributor: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  // Read/write access to index DEFINITIONS. Needed to create the index itself.
  searchServiceContributor: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  // Permits embedding calls. Needed by you at ingest time and by Search at query time.
  cognitiveServicesOpenAIUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  // Read/write blob data. Needed to archive your corpus snapshot.
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
}

// ---------------------------------------------------------------------------
// Microsoft Foundry account + embedding deployment
// ---------------------------------------------------------------------------

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: foundryName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // A custom subdomain is REQUIRED for Entra ID token authentication against the
    // data plane. Without it the account only answers to keys, which would quietly
    // defeat the keyless design above.
    customSubDomainName: foundryName
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: disableLocalAuth
  }
}

resource embedding 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: foundry
  name: embeddingDeploymentName
  sku: {
    name: embeddingSkuName
    capacity: embeddingCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingModelName
      // An empty version means "use the Foundry default". Pinning a version makes the
      // template fail the day Microsoft retires it; accepting the default makes the
      // template survive that. If you need reproducible vectors across a long project,
      // pin deliberately and record the pin in an ADR.
      version: empty(embeddingModelVersion) ? null : embeddingModelVersion
    }
    // Never silently jump major versions -- an embedding model change invalidates every
    // vector already in the index, and a silent re-embed is the kind of drift that makes
    // retrieval quality mysteriously degrade between study sessions.
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

// ---------------------------------------------------------------------------
// Azure AI Search
// ---------------------------------------------------------------------------

resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: searchName
  location: location
  tags: tags
  sku: {
    name: searchSku
  }
  identity: {
    // The search service needs its own identity so the query-time vectorizer can call
    // the embedding endpoint without a key travelling in the index definition.
    type: 'SystemAssigned'
  }
  properties: {
    replicaCount: 1
    // One partition is ample. ADR-002 measures the whole corpus at ~1,600 chunks;
    // the constraint here is retrieval quality, never scale.
    partitionCount: 1
    // hostingMode is intentionally omitted. It is only meaningful for standard3, and
    // the service default is correct for every SKU this template allows.
    semanticSearch: semanticSearchPlan
    disableLocalAuth: disableLocalAuth
    publicNetworkAccess: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Storage -- the corpus snapshot archive
//
// WHAT THIS IS FOR, AND WHAT IT IS NOT FOR
//
// It is a PROVENANCE ARCHIVE. It answers "did my answers change because Microsoft
// changed the training, or because I changed the chunker?", which matters because
// Microsoft Learn is a moving target. When a fresh download changes a unit, blob
// versioning lets you diff the snapshot rather than argue from memory.
//
// It is NOT an ingestion source. There is deliberately no indexer and no data source
// pointed at this account. ADR-002 rejected indexer-driven chunking for this corpus,
// and adding a container does not reopen that decision: chunk_learn.py still chunks
// locally and ingest_azure.py still pushes. Blob is where the inputs are KEPT, not
// where they are read from.
//
// IT STAYS PRIVATE
//
// The corpus is Microsoft's copyrighted training content, downloaded for your own
// study. Anonymous access is off, account keys are off, and both containers are
// created with publicAccess 'None'. A public container would turn a personal study
// snapshot into redistribution, so leave all three settings as they are.
// ---------------------------------------------------------------------------

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  // BCP334 suppressed deliberately, with the arithmetic stated so the claim is checkable:
  // namePrefix is @minLength(3), uniqueString() always returns exactly 13 characters, and
  // 'st' adds 2 -- so the shortest possible result is 18 characters, well over the
  // 3-character floor. Bicep cannot infer a lower bound through replace(), hence the hint.
  #disable-next-line BCP334
  name: storageName
  location: location
  tags: tags
  sku: {
    // Locally-redundant is correct for a reproducible archive. The authoritative copy
    // of this corpus is the downloader plus Microsoft Learn; paying for geo-redundancy
    // to protect a snapshot you can regenerate is spending on the wrong risk.
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    // No anonymous blob access, ever. A "public" container is how a private corpus
    // snapshot quietly becomes a public one.
    allowBlobPublicAccess: false
    // Keyless, matching the search service and Foundry account. With shared-key auth
    // off there is no account key to leak, rotate, or accidentally commit -- every
    // caller presents an Entra token instead.
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storage
  name: 'default'
  properties: {
    // Versioning is the whole reason this account exists. Re-uploading a changed unit
    // preserves the previous version, so "what did this page say when I built my
    // index?" is a query rather than a guess.
    isVersioningEnabled: true
    deleteRetentionPolicy: {
      enabled: true
      days: 30
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 30
    }
  }
}

// Your downloaded copy of the Learn training: markdown units and their figures.
resource corpusSource 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: 'corpus-source'
  properties: {
    publicAccess: 'None'
    metadata: {
      contents: 'Microsoft Learn SC-100 training, downloaded for personal study'
      sharing: 'keep private'
    }
  }
}

// Derived artifacts: the chunk JSONL and its stats report. Kept beside the source so a
// snapshot and the chunks produced from it can be recovered as a matched pair.
resource corpusArtifacts 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: 'corpus-artifacts'
  properties: {
    publicAccess: 'None'
    metadata: {
      contents: 'derived chunk JSONL, chunking stats reports, snapshot manifests'
      note: 'derived from corpus-source; regenerate with tools/chunk_learn.py'
    }
  }
}

// ---------------------------------------------------------------------------
// Role assignments
//
// Names are deterministic GUIDs derived from (scope, principal, role). That is what
// makes redeployment idempotent: ARM sees the same name and updates in place instead
// of failing on a conflict or creating a duplicate.
// ---------------------------------------------------------------------------

// 1. Search service -> Foundry. Lets the index's query-time vectorizer embed the
//    caller's search text, so the MCP server can send plain strings.
resource searchCanEmbed 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, search.id, roleIds.cognitiveServicesOpenAIUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.cognitiveServicesOpenAIUser)
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// 2. You -> Foundry. Lets ingest_azure.py compute document embeddings.
resource deployerCanEmbed 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, deployerPrincipalId, roleIds.cognitiveServicesOpenAIUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.cognitiveServicesOpenAIUser)
    principalId: deployerPrincipalId
    principalType: deployerPrincipalType
  }
}

// 3. You -> Search, definitions. Lets create_index.py define the index.
resource deployerManagesIndexes 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: search
  name: guid(search.id, deployerPrincipalId, roleIds.searchServiceContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.searchServiceContributor)
    principalId: deployerPrincipalId
    principalType: deployerPrincipalType
  }
}

// 4. You -> Search, data. Lets ingest_azure.py upload documents and the MCP server query.
resource deployerWritesData 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: search
  name: guid(search.id, deployerPrincipalId, roleIds.searchIndexDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.searchIndexDataContributor)
    principalId: deployerPrincipalId
    principalType: deployerPrincipalType
  }
}

// 5. You -> Storage, blob data. Lets sync_corpus.py archive your corpus snapshot.
//    Scoped to the storage account, and note there is no corresponding assignment for
//    the search service: nothing in Azure reads this container, by design.
resource deployerWritesBlobs 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, deployerPrincipalId, roleIds.storageBlobDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.storageBlobDataContributor)
    principalId: deployerPrincipalId
    principalType: deployerPrincipalType
  }
}

// ---------------------------------------------------------------------------
// Outputs
//
// deploy.ps1 / deploy.sh read these and write .env, so no human ever transcribes an
// endpoint by hand. Note that no key is emitted anywhere -- there is nothing to leak.
// ---------------------------------------------------------------------------

output searchEndpoint string = 'https://${search.name}.search.windows.net'
output searchServiceName string = search.name
output searchIdentityPrincipalId string = search.identity.principalId
output foundryEndpoint string = foundry.properties.endpoint
output foundryName string = foundry.name
output embeddingDeployment string = embedding.name
output embeddingModel string = embeddingModelName
output storageAccountName string = storage.name
output storageBlobEndpoint string = storage.properties.primaryEndpoints.blob
output corpusSourceContainer string = corpusSource.name
output corpusArtifactsContainer string = corpusArtifacts.name
output resourceGroupName string = resourceGroup().name
output location string = location
