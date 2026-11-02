// =====================================================================================
// SC-100 Course 3, Module 3 lab: "Evaluate a Foundry project against the AI controls"
// Globomantics is a fictional company. Deploy with Deploy-C3M03FoundryReview.ps1.
//
// WHAT THIS BUILDS, AND THE DECISION EACH PIECE SUPPORTS IN THE DEMO
//   Foundry resource (kind AIServices, projects enabled)
//     disableLocalAuth = true      -> a setting you should KEEP (Microsoft Entra ID only)
//     publicNetworkAccess Enabled  -> a setting you EVALUATE: private inbound is a separate
//                                     decision from authentication
//   Project glb-customer-experience -> the development boundary both workloads share
//   Content filter glb-assistant-filter on deployment glb-assistant
//     Prompt Shields (jailbreak, indirect attack) blocking on prompts -> KEEP; it governs
//     what the assistant says, and it can't govern what the assistant may read or write
//   Two user-assigned workload identities over one storage account
//     id-glb-erp-draft-agent     Storage Blob Data Contributor on container draft-orders ONLY
//     id-glb-customer-assistant  Storage Blob Data Contributor on the WHOLE storage account
//                                -> the deliberate FINDING: the assistant can write draft orders,
//                                   which is the ERP agent's authority, not its own
//
// WHY THE LAB PLANTS A FINDING
//   The demo is a configuration review. The over-broad assignment is planted by this lab so the
//   review has something real to find, and redeploying this template puts it back. Nothing in
//   the lab claims it was discovered in production.
//
// COST
//   This template creates billable resources. There's no standing compute: S0 AIServices and a
//   GlobalStandard deployment bill per token, and the review sends none. Storage holds no data.
//   Teardown: Deploy-C3M03FoundryReview.ps1 -Mode Remove deletes the resource group, then purges
//   the soft-deleted Foundry resource so its name is free for your next deployment.
// =====================================================================================

targetScope = 'resourceGroup'

@description('Defaults to the resource group region. Use a region where your subscription has gpt-5-mini GlobalStandard quota; the deploy script checks before it deploys.')
param location string = resourceGroup().location

@description('Deterministic suffix so a redeploy converges on the same names instead of adding copies.')
param suffix string = take(uniqueString(resourceGroup().id), 8)

@description('Model for the assistant deployment. It was generally available when this lab was written; models retire on a schedule, so check current availability on Microsoft Learn before you deploy.')
param modelName string = 'gpt-5-mini'

@description('Model version. If this version has retired in your region, set a current one here.')
param modelVersion string = '2025-08-07'

var tags = {
  course: 'SC100-C3M03'
  company: 'Globomantics'
  purpose: 'demo-fixture'
  teardown: 'after-course'
}

// Built-in role definition IDs. They're identical in every Azure tenant, which is why it's safe
// to hard-code them. Look one up with: az role definition list --name <id>
var roleFoundryUser = '53ca6127-db72-4b80-b1b0-d745d6d5456d' // Foundry User
var roleBlobContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor

// ---------------------------------------------------------------- Foundry resource
resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: 'glb-c3m03-foundry-${suffix}'
  location: location
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  tags: tags
  properties: {
    allowProjectManagement: true
    customSubDomainName: 'glb-c3m03-${suffix}'
    // KEEP: keys can't carry a user identity, Conditional Access or an audit trail per caller.
    disableLocalAuth: true
    // EVALUATE: reachable from all networks. Entra-only authentication still applies, which is
    // exactly the distinction the demo draws between "who may call" and "from where".
    publicNetworkAccess: 'Enabled'
    networkAcls: { defaultAction: 'Allow' }
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundry
  name: 'glb-customer-experience'
  location: location
  identity: { type: 'SystemAssigned' }
  tags: tags
  properties: {
    displayName: 'Globomantics customer experience'
    description: 'Customer assistant and ERP draft-order agent share this project; their data authority must not be shared.'
  }
}

// Child operations on one Cognitive Services account conflict when they run in parallel, so each
// child depends on the previous one. That's the only reason for the dependsOn chain below.
resource filter 'Microsoft.CognitiveServices/accounts/raiPolicies@2025-06-01' = {
  parent: foundry
  name: 'glb-assistant-filter'
  dependsOn: [ project ]
  properties: {
    basePolicyName: 'Microsoft.DefaultV2'
    mode: 'Default'
    contentFilters: [
      { name: 'Hate', source: 'Prompt', enabled: true, blocking: true, severityThreshold: 'Medium' }
      { name: 'Sexual', source: 'Prompt', enabled: true, blocking: true, severityThreshold: 'Medium' }
      { name: 'Violence', source: 'Prompt', enabled: true, blocking: true, severityThreshold: 'Medium' }
      { name: 'Selfharm', source: 'Prompt', enabled: true, blocking: true, severityThreshold: 'Medium' }
      { name: 'Hate', source: 'Completion', enabled: true, blocking: true, severityThreshold: 'Medium' }
      { name: 'Sexual', source: 'Completion', enabled: true, blocking: true, severityThreshold: 'Medium' }
      { name: 'Violence', source: 'Completion', enabled: true, blocking: true, severityThreshold: 'Medium' }
      { name: 'Selfharm', source: 'Completion', enabled: true, blocking: true, severityThreshold: 'Medium' }
      // Prompt Shields: direct attacks (jailbreak) and attacks carried in documents (indirect).
      { name: 'Jailbreak', source: 'Prompt', enabled: true, blocking: true }
      { name: 'Indirect Attack', source: 'Prompt', enabled: true, blocking: true }
      { name: 'Protected Material Text', source: 'Completion', enabled: true, blocking: true }
      { name: 'Protected Material Code', source: 'Completion', enabled: true, blocking: false }
    ]
  }
}

resource assistantModel 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: foundry
  name: 'glb-assistant'
  dependsOn: [ filter ]
  // 10 units of GlobalStandard capacity: the deploy script checks this much quota is free.
  sku: { name: 'GlobalStandard', capacity: 10 }
  properties: {
    model: { format: 'OpenAI', name: modelName, version: modelVersion }
    raiPolicyName: filter.name
    // Pin the version so the lab you review matches the template you read.
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

// ---------------------------------------------------------------- business data
resource data 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stglbc3m03${suffix}'
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  tags: tags
  properties: {
    allowBlobPublicAccess: false
    // Entra authorization only, so role assignments are the whole story the review reads.
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: data
  name: 'default'
}

resource customerRecords 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blob
  name: 'customer-records'
}

resource draftOrders 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blob
  name: 'draft-orders'
}

// ---------------------------------------------------------------- workload identities
resource assistant 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-glb-customer-assistant'
  location: location
  tags: tags
}

resource erpAgent 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-glb-erp-draft-agent'
  location: location
  tags: tags
}

// Correct: the ERP agent writes draft orders and nothing else (the approval from Course 2).
resource erpDraftOrders 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: draftOrders
  name: guid(draftOrders.id, erpAgent.id, roleBlobContributor)
  properties: {
    principalId: erpAgent.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleBlobContributor)
    description: 'C3M03 lab: ERP agent, draft orders only'
  }
}

// FINDING, planted on purpose: write access to every container, draft-orders included. The fix
// the demo recommends is Storage Blob Data Reader on customer-records. Leave it here so the
// review has something to find, and practice the fix against the deployed lab instead.
resource assistantAccountWide 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: data
  name: guid(data.id, assistant.id, roleBlobContributor)
  properties: {
    principalId: assistant.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleBlobContributor)
    description: 'C3M03 lab FINDING: customer assistant can write every container'
  }
}

// Both workloads call models through the shared project with the least-privilege Foundry role.
resource assistantFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: project
  name: guid(project.id, assistant.id, roleFoundryUser)
  properties: {
    principalId: assistant.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleFoundryUser)
    description: 'C3M03 lab: assistant model access at project scope'
  }
}

resource erpFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: project
  name: guid(project.id, erpAgent.id, roleFoundryUser)
  properties: {
    principalId: erpAgent.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleFoundryUser)
    description: 'C3M03 lab: ERP agent model access at project scope'
  }
}

output foundryName string = foundry.name
output projectName string = project.name
output deploymentName string = assistantModel.name
output filterName string = filter.name
output storageName string = data.name
output assistantPrincipalId string = assistant.properties.principalId
output erpAgentPrincipalId string = erpAgent.properties.principalId
