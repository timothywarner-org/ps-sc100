// =============================================================================
// SC-100 Course 1, Module 1 lab: Globomantics blob recovery (subscription scope)
//
// The estate behind the demo "Evidence a ransomware-resilient recovery design":
// a storage account holding Globomantics order documents with every operational
// protection switched on, an empty restore-target account, and a Backup vault that
// keeps a vaulted copy outside the source account's blast radius.
//
// Deploy it with Deploy-C1M01BlobRecovery.ps1, which also seeds the sample order
// documents and triggers the first backup. By hand:
//   az deployment sub what-if --location eastus2 --template-file main.bicep
//   az deployment sub create  --location eastus2 --template-file main.bicep
//
// WHY SUBSCRIPTION SCOPE
//   Two things the lab needs live above a resource group: the resource group
//   itself, and the optional Defender CSPM plan, which only exists at subscription
//   scope. Owning the resource group in the template is what makes the whole lab
//   reproducible from one command and removable with one delete.
//
// WHY DEFENDER CSPM IS OFF BY DEFAULT
//   The demo opens on critical asset classification in Microsoft Security Exposure
//   Management, which the Defender CSPM plan feeds. The plan bills per billable
//   resource across the WHOLE subscription, not just this lab, so turning it on is
//   your decision. The deploy script passes enableDefenderCspm=true only when you
//   ask for it and the plan was off, and the resource group tag it writes is how
//   the Remove mode knows to turn the plan back off afterwards.
// =============================================================================

targetScope = 'subscription'

@description('Region for the whole lab. The Backup vault has to share the source storage account\'s region, so one parameter drives everything.')
param location string = 'eastus2'

@description('Resource group for the lab. Every lab resource lands in it, so one delete removes the lab.')
@minLength(1)
@maxLength(90)
param resourceGroupName string = 'rg-globomantics-c1m01'

@description('Turns on the Defender CSPM plan (CloudPosture, Standard tier) for the whole subscription. Leave false unless you want the critical asset surface and accept the subscription-wide charge.')
param enableDefenderCspm bool = false

// Tags carry the teardown contract. The deploy script refuses to touch a resource
// group that exists without the course tag, and Remove re-reads it before deleting.
var labTags = {
  course: 'SC100-C1M01'
  company: 'Globomantics'
  purpose: 'course-lab'
}

// The extra tag records that the LAB turned Defender CSPM on, as opposed to you
// having it on already. Remove only switches the plan off when this tag is present.
var resourceGroupTags = enableDefenderCspm ? union(labTags, { 'defender-cspm': 'enabled-by-lab' }) : labTags

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: resourceGroupTags
}

// The estate itself (storage, vault, policy, role assignments, backup instance) is
// resource-group scoped, so it lives in a module deployed into the group above.
module estate 'modules/blob-recovery-estate.bicep' = {
  name: 'c1m01-blob-recovery-estate'
  scope: rg
  params: {
    location: location
    tags: labTags
  }
}

// Defender CSPM. Conditional, and never deployed with 'Free': if you already run
// the plan, the template leaves it exactly as you configured it.
resource defenderCspm 'Microsoft.Security/pricings@2024-01-01' = if (enableDefenderCspm) {
  name: 'CloudPosture'
  properties: {
    pricingTier: 'Standard'
  }
}

output resourceGroupName string = rg.name
output sourceAccountName string = estate.outputs.sourceAccountName
output restoreAccountName string = estate.outputs.restoreAccountName
output vaultName string = estate.outputs.vaultName
output backupInstanceName string = estate.outputs.backupInstanceName
output backupRuleName string = estate.outputs.backupRuleName
output ordersContainerName string = estate.outputs.ordersContainerName
