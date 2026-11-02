// =============================================================================
// SC-100 Course 1, Module 1 lab: the blob recovery estate (resource-group scope)
//
// What this builds, and the design decision each piece supports:
//   - SOURCE storage account with the full OPERATIONAL protection set: point-in-time
//     restore, blob soft delete, versioning, change feed. Fast recovery, but every
//     one of those is a property of the account a compromised administrator controls.
//   - 'orders' container. The sample order documents are uploaded by the deploy
//     script, because blob CONTENT is data plane and ARM templates can't write it.
//   - EMPTY restore-target storage account. Vaulted blob restore refuses the source
//     account, so a second account has to exist BEFORE the incident.
//   - Backup vault with a system-assigned identity, and a vaulted blob policy.
//   - Role assignments for the vault identity on BOTH accounts.
//   - A backup instance protecting the 'orders' container in the vaulted tier.
//
// Deliberately ABSENT:
//   - Vault immutability stays Disabled, so you have something to enable yourself.
//     Never lock it in a lab: the Locked state is irreversible and turns on WORM
//     storage, and a locked vault can't be deleted until its data expires.
//     https://learn.microsoft.com/azure/backup/backup-azure-immutable-vault-concept
//   - Multi-User Authorization and its Resource Guard. The Resource Guard belongs
//     in a different subscription or tenant, which is the whole point of it and the
//     reason it doesn't fit in a single-subscription lab.
// =============================================================================

@description('Region for every resource. The Backup vault must match the source storage account.')
param location string

@description('Tags stamped on every resource, so you can always tell what the lab created.')
param tags object

// Storage account names are globally unique, so each one carries a suffix derived
// from this resource group's ID. Two learners never collide, and a redeploy into the
// same group always lands on the same names, which keeps the deployment idempotent.
@description('SOURCE storage account: Globomantics order documents land here.')
@minLength(3)
@maxLength(24)
param sourceAccountName string = 'stgloborders${take(uniqueString(resourceGroup().id), 8)}'

@description('RESTORE-TARGET storage account. Exists, same region, and stays empty.')
@minLength(3)
@maxLength(24)
param restoreAccountName string = 'stglobrestore${take(uniqueString(resourceGroup().id), 8)}'

@description('Backup vault name. A Backup vault, not a Recovery Services vault: the workload picks the vault type, and blob storage lands here.')
param vaultName string = 'bvault-globomantics'

@description('Vaulted blob backup policy name.')
param policyName string = 'bkpol-blob-vaulted'

@description('Container the order documents land in, and the only container the vaulted policy protects.')
param containerName string = 'orders'

// Built-in role 'Storage Account Backup Contributor'. The vault's managed identity
// needs it on the SOURCE to take backups, and on the RESTORE TARGET so a restore can
// land there. That second assignment is the pre-incident step most designs miss.
// https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#storage
var storageAccountBackupContributorRoleId = 'e5e2a7ff-d759-4cd2-bb51-3152d37e2eb1'

var backupRuleName = 'BackupDaily'

// Both accounts share one shape: GPv2, LRS, TLS 1.2 floor, no anonymous blob
// access. The lesson lives in the data protection settings, not the SKU, so the
// cheapest redundancy tier is the right one for a lab.
var storageAccountProperties = {
  minimumTlsVersion: 'TLS1_2'
  allowBlobPublicAccess: false
  supportsHttpsTrafficOnly: true
}

// --------------------------------------------------------------------------
// SOURCE account: today's Globomantics reality. Order documents plus operational
// backup that never leaves the account, which is the module's problem statement.
// --------------------------------------------------------------------------
resource sourceAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: sourceAccountName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: storageAccountProperties
}

// Point-in-time restore REQUIRES versioning, change feed and blob soft delete, and
// its restore window must be shorter than the soft delete retention, hence 6 < 7.
resource sourceBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: sourceAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: 7 }
    isVersioningEnabled: true
    changeFeed: { enabled: true }
    restorePolicy: { enabled: true, days: 6 }
  }
}

resource ordersContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: sourceBlobService
  name: containerName
  properties: { publicAccess: 'None' }
}

// --------------------------------------------------------------------------
// RESTORE-TARGET account. Vaulted blob restore refuses the source account outright,
// and it fails if the target already holds containers with the same names as the
// ones being restored. So no blobServices or containers child, on purpose.
// --------------------------------------------------------------------------
resource restoreAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: restoreAccountName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: storageAccountProperties
}

// --------------------------------------------------------------------------
// Backup vault. The system-assigned identity is the principal that reads the source
// account during backup. No securitySettings block: immutability defaults to
// Disabled, and soft delete takes whatever default your region applies, so the
// settings you read in the portal are the platform's, not the template's.
// --------------------------------------------------------------------------
resource vault 'Microsoft.DataProtection/backupVaults@2024-04-01' = {
  name: vaultName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    storageSettings: [
      { datastoreType: 'VaultStore', type: 'LocallyRedundant' }
    ]
  }
}

// Vaulted blob policy: one daily discrete backup into the vault store, 30-day
// retention. Production retention is a business decision; 30 days is plenty here.
resource backupPolicy 'Microsoft.DataProtection/backupVaults/backupPolicies@2024-04-01' = {
  parent: vault
  name: policyName
  properties: {
    objectType: 'BackupPolicy'
    datasourceTypes: [ 'Microsoft.Storage/storageAccounts/blobServices' ]
    policyRules: [
      {
        name: backupRuleName
        objectType: 'AzureBackupRule'
        backupParameters: { objectType: 'AzureBackupParams', backupType: 'Discrete' }
        dataStore: { dataStoreType: 'VaultStore', objectType: 'DataStoreInfoBase' }
        trigger: {
          objectType: 'ScheduleBasedTriggerContext'
          // 08:00 UTC daily, so a fresh recovery point appears every day without
          // anyone triggering it. A start date in the past is fine; the schedule
          // simply repeats from it.
          schedule: {
            repeatingTimeIntervals: [ 'R/2026-08-28T08:00:00+00:00/P1D' ]
            timeZone: 'UTC'
          }
          taggingCriteria: [
            {
              isDefault: true
              taggingPriority: 99
              tagInfo: { tagName: 'Default', id: 'Default_' }
            }
          ]
        }
      }
      {
        name: 'Default'
        objectType: 'AzureRetentionRule'
        isDefault: true
        lifecycles: [
          {
            deleteAfter: { objectType: 'AbsoluteDeleteOption', duration: 'P30D' }
            sourceDataStore: { dataStoreType: 'VaultStore', objectType: 'DataStoreInfoBase' }
            targetDataStoreCopySettings: []
          }
        ]
      }
    ]
  }
}

// --------------------------------------------------------------------------
// Role assignments for the vault identity. guid() over stable IDs makes each
// assignment name deterministic, so a redeploy converges instead of failing with
// RoleAssignmentExists.
// --------------------------------------------------------------------------
resource sourceRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sourceAccount.id, vault.id, storageAccountBackupContributorRoleId)
  scope: sourceAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageAccountBackupContributorRoleId)
    principalId: vault.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource restoreRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(restoreAccount.id, vault.id, storageAccountBackupContributorRoleId)
  scope: restoreAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageAccountBackupContributorRoleId)
    principalId: vault.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// --------------------------------------------------------------------------
// Backup instance: vaulted protection for the 'orders' container. Azure Backup
// checks the vault's permissions on the source when the instance is created, so the
// explicit dependency on the role assignment matters. A brand-new role assignment
// can still take a minute or two to propagate; the deploy script retries once when
// that happens, and everything else in the template converges as a no-op.
// --------------------------------------------------------------------------
resource backupInstance 'Microsoft.DataProtection/backupVaults/backupInstances@2024-04-01' = {
  parent: vault
  name: '${sourceAccountName}-${containerName}'
  properties: {
    objectType: 'BackupInstance'
    friendlyName: sourceAccountName
    dataSourceInfo: {
      objectType: 'Datasource'
      resourceID: sourceAccount.id
      resourceName: sourceAccountName
      resourceType: 'Microsoft.Storage/storageAccounts'
      resourceUri: sourceAccount.id
      resourceLocation: location
      datasourceType: 'Microsoft.Storage/storageAccounts/blobServices'
    }
    policyInfo: {
      policyId: backupPolicy.id
      policyParameters: {
        backupDatasourceParametersList: [
          {
            objectType: 'BlobBackupDatasourceParameters'
            containersList: [ containerName ]
          }
        ]
      }
    }
  }
  dependsOn: [
    sourceRoleAssignment
    ordersContainer
  ]
}

output sourceAccountName string = sourceAccount.name
output restoreAccountName string = restoreAccount.name
output vaultName string = vault.name
output backupInstanceName string = backupInstance.name
output backupRuleName string = backupRuleName
output ordersContainerName string = containerName
