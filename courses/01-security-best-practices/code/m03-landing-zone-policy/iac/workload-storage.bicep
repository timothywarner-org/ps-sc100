// =============================================================================
// SC-100 Course 1, Module 3 lab: the workload template that runs TWICE
//
// THIS FILE DOESN'T CHANGE BETWEEN THE TWO RUNS. That's the entire point.
// Invoke-C1M03Workload.ps1 deploys it while your subscription sits in the Online
// landing zone and it SUCCEEDS. Then it moves the subscription to Corp and deploys
// the identical file, same parameters, same account name, same region, and it's
// PREVENTED. Nothing about the workload changed. Its address did.
//
// THE STORY: Globomantics marketing is launching the storefront refresh and needs a
// container of product images served straight from blob storage. That's an
// ordinary, legitimate request. Whether it's ALLOWED depends entirely on which
// landing zone the workload was placed in, and nobody on the marketing team knows
// what a landing zone is. That's the architecture doing its job.
//
// WHY allowBlobPublicAccess IS THE HINGE
//   It's a single boolean on a resource every SC-100 learner already understands,
//   it's governed by a Deny-capable built-in, and it maps to a real architectural
//   decision (exposure) rather than a synthetic one (naming, tagging, region trivia).
//
// WHY THE REGION IS eastus2
//   eastus2 SATISFIES the org-wide Allowed locations rule. If this template broke
//   both rules at once, the denial would be ambiguous and you'd rightly ask which
//   rule fired. Exactly one variable moves in this lab, and it's the archetype.
//
// WHY THE RESOURCE GROUP ISN'T IN HERE
//   The script creates rg-globomantics-storefront in eastus2 first, so the only thing
//   policy has to speak to is the storage account itself. One violation, one error.
// =============================================================================

targetScope = 'resourceGroup'

@description('Compliant with the org-wide Allowed locations rule ON PURPOSE. Only one variable moves in this lab.')
param location string = 'eastus2'

@description('Storage account name. Globally unique and capped at 24 characters. Seeded from the resource group ID, so both runs request the SAME name: a different name would let someone argue that something other than the archetype changed.')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'stgloboweb${take(uniqueString(resourceGroup().id), 13)}'

resource storefrontImages 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    // THE HINGE. Corp denies this. Online audits it. Everything else on this resource
    // is hardened, so nobody can claim the block was about general sloppiness.
    allowBlobPublicAccess: true

    // Hardened everywhere else, deliberately: the ONLY finding either archetype has
    // to say anything about is the public blob endpoint.
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
  tags: {
    course: 'SC100-C1M03'
    workload: 'globomantics-storefront-images'
    purpose: 'Demonstrates archetype-differentiated governance. Safe to delete.'
  }
}

output storageAccountName string = storefrontImages.name
output allowBlobPublicAccess bool = storefrontImages.properties.allowBlobPublicAccess
output location string = storefrontImages.location
