// SC-100 Course 4, Module 4 lab: the storage account behind the Globomantics customer assistant.
//
// This is the same account design Course 3 Module 3 built for the assistant's customer records, rebuilt
// in its own resource group so this lab never touches a Course 3 lab you might still have. Every
// property below is a design decision you'll read back with Deploy-C4M04DataPath.ps1 -Mode Show:
//   allowSharedKeyAccess false   keep: only Microsoft Entra ID or a user delegation SAS gets in
//   minimumTlsVersion TLS1_2     keep: older TLS versions are refused
//   allowBlobPublicAccess false  keep: no anonymous reads
//   publicNetworkAccess Enabled  the finding: the account still listens on the internet
//   no infrastructure encryption the decision: it can only be set when an account is created
// Defender for Storage is turned on for this one account by the script, not here, through the
// account-level settings API, so no other storage account in your subscription starts billing.

targetScope = 'resourceGroup'

@description('Deterministic suffix, so the same group always yields the same globally unique account name.')
param suffix string = take(uniqueString(resourceGroup().id), 8)
param location string = resourceGroup().location

var tags = {
  course: 'SC100-C4M04'
  company: 'Globomantics'
  purpose: 'course-lab'
  teardown: 'after-course'
}

resource data 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stglbc4m04${suffix}'
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  tags: tags
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false          // a keep
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'          // a keep
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'       // the change to make, set explicitly so the value prints
    // No encryption block: infrastructure encryption stays off, and it can only be set at creation.
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

output storageName string = data.name
output storageId string = data.id
