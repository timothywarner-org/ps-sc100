// =============================================================================
// SC-100 Course 1, Module 4 lab: Globomantics AI workloads (resource group scope)
//
// The estate behind the demo "Govern AI adoption before you enable it":
//
//   rg-globomantics-c1m04
//   ├── aif-globomantics-marketing-<suffix>    <- the shadow-AI chatbot, never reviewed
//   │     └── proj-marketing-chatbot
//   └── aif-globomantics-orderintake-<suffix>  <- the sanctioned pilot, blocked at the gate
//         └── proj-order-intake
//
// Discovery is the easy half: Azure Resource Graph lists both accounts in about a
// second (find-ai-workloads.kql), and Defender CSPM goes further with an AI Bill of
// Materials. Governance is the hard half: no column anywhere records whether anyone
// APPROVED a workload. The only opinion in this estate is a tag a human typed.
//
// Deploy it with Deploy-C1M04AIWorkload.ps1. By hand:
//   az group create --name rg-globomantics-c1m04 --location eastus2
//   az deployment group create --resource-group rg-globomantics-c1m04 --template-file main.bicep
//
// WHY MICROSOFT FOUNDRY AND NOT A STANDALONE AZURE OPENAI ACCOUNT
//   A Foundry resource IS Microsoft.CognitiveServices/accounts with kind
//   'AIServices', plus an accounts/projects child. Defender CSPM discovers Foundry
//   accounts AND projects, so the project isn't decoration: it's half of what a
//   discovery query returns.
//   https://learn.microsoft.com/azure/foundry/how-to/create-resource-template
//
// WHY THE MODEL VERSION IS PINNED, AND WHY YOU SHOULD CHECK IT
//   A pin makes the deployment reproducible, and it also goes stale silently. When a
//   pinned model moves into a deprecating state, validation fails with
//   ServiceModelDeprecating before anything deploys. The deploy script's Plan mode
//   checks the pin against what your region offers; pass modelName and modelVersion
//   to override it rather than editing this file.
//
// WHY PUBLIC NETWORK ACCESS STAYS ON
//   A pilot somebody stood up without review is internet-reachable, because that's
//   what makes it convenient. Locking it down would be better security and would
//   delete the finding the lab exists to show. This is a deliberately ungoverned
//   estate.
//
// WHAT THIS FILE REFUSES TO DO
//   No private endpoints, no virtual network, no Key Vault, no agents, no content
//   filter customization. Each is real practice, and none of them is the lesson.
// =============================================================================

targetScope = 'resourceGroup'

@description('Region. Must offer the model below. eastus2 is also on the allowed-locations list the Module 3 lab enforces, so the two labs coexist.')
param location string = resourceGroup().location

@description('The model both accounts deploy. Identical on purpose: same model, two workloads, and only one of them was ever submitted for review.')
param modelName string = 'gpt-5.4-mini'

@description('Model version, pinned so a silent upstream default can\'t change what you deploy. Check it against your region before deploying; Deploy-C1M04AIWorkload.ps1 -Mode Plan does that for you.')
param modelVersion string = '2026-03-17'

@description('Deployment SKU. GlobalStandard is the default; if validation rejects it for this model, pass Standard instead rather than editing this file.')
param deploymentSku string = 'GlobalStandard'

@description('Thousands of tokens per minute. 10 is the smallest useful unit, and nothing in the lab calls the endpoint.')
@minValue(1)
@maxValue(50)
param capacity int = 10

// Custom subdomain names are global DNS names, so each account carries a suffix
// derived from this resource group's ID. Two learners never collide, and a redeploy
// into the same group lands on the same names.
var suffix = take(uniqueString(resourceGroup().id), 6)

// The two workloads from the adoption gate artifact. governance-state is a TAG rather
// than anything enforced: the point of the lab is that no Azure surface has a column
// for approval, so it lives where a human put it and nowhere else.
var workloads = [
  {
    name: 'aif-globomantics-marketing-${suffix}'
    project: 'proj-marketing-chatbot'
    projectLabel: 'Marketing chatbot'
    purpose: 'Marketing chatbot. Shadow AI, never submitted for review.'
    governed: 'not-submitted'
  }
  {
    name: 'aif-globomantics-orderintake-${suffix}'
    project: 'proj-order-intake'
    projectLabel: 'Order-intake AI pilot'
    purpose: 'Order-intake AI pilot. Submitted, blocked at the gate.'
    governed: 'blocked-no-data-boundary'
  }
]

resource accounts 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = [for w in workloads: {
  name: w.name
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // Required for a Foundry account to expose a token endpoint at all, and the
    // account won't accept model deployments without one.
    customSubDomainName: w.name
    publicNetworkAccess: 'Enabled'
    // Lets the account host Foundry projects. Without it the projects child fails.
    allowProjectManagement: true
  }
  tags: {
    course: 'SC100-C1M04'
    company: 'Globomantics'
    purpose: w.purpose
    'governance-state': w.governed
  }
}]

resource projects 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = [for (w, i) in workloads: {
  parent: accounts[i]
  name: w.project
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: w.projectLabel
    description: w.purpose
  }
}]

// Deployments are a separate loop rather than nested. Two model deployments against
// the SAME account must run one after another, and Bicep only guarantees that through
// an explicit dependency chain. Here each account has exactly one, so index alignment
// is the dependency.
resource deployments 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = [for (w, i) in workloads: {
  parent: accounts[i]
  name: modelName
  sku: {
    name: deploymentSku
    capacity: capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}]

@description('The two workloads find-ai-workloads.kql returns.')
output workloadNames array = [for (w, i) in workloads: accounts[i].name]

@description('What the AI Bill of Materials has to inventory.')
output modelDeployed string = '${modelName} ${modelVersion} (${deploymentSku}, ${capacity}K TPM) on both Foundry accounts'
