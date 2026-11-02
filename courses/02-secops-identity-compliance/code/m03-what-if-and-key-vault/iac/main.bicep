// SC-100 Course 2, Module 3 lab: the Globomantics credential shelf for the ERP gateway.
//
// One vault in RBAC mode plus one role assignment so you can seed and read its data plane. The
// certificates, the secret and the key are data-plane objects with no Azure Resource Manager
// surface, so Deploy-C2M03KeyVault.ps1 creates them after this template deploys.
//
// Deploy it with Deploy-C2M03KeyVault.ps1, which computes the vault name and your object ID.

@description('Region for the vault. The deploy script passes the resource group region.')
param location string = resourceGroup().location

@description('Globally unique vault name, 3 to 24 characters. The deploy script derives a repeatable one.')
@minLength(3)
@maxLength(24)
param vaultName string

@description('Object ID of the identity that seeds and reads the data plane: you.')
param operatorObjectId string

@description('Whether that identity is a user or a service principal.')
@allowed([
  'User'
  'ServicePrincipal'
])
param operatorPrincipalType string = 'User'

// Key Vault Administrator is a built-in role, and its definition ID is the same in every tenant.
// https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/security#key-vault-administrator
var keyVaultAdministratorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '00482a5a-887f-4fb3-b363-3b7fe8e74483')

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: vaultName
  location: location
  tags: {
    course: 'SC100-C2M03'
    company: 'Globomantics'
    workload: 'erp-gateway'
  }
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    // RBAC mode: data-plane access comes from Azure role assignments, and access policies are ignored.
    enableRbacAuthorization: true
    enableSoftDelete: true
    // The shortest retention Key Vault allows, so a removed lab vault clears quickly. The deploy
    // script purges it on Remove anyway.
    softDeleteRetentionInDays: 7
    // Left Enabled ON PURPOSE. Network access to the vault is a design decision Globomantics hasn't
    // made yet, and the demo points at this setting as the open question. A production vault would
    // normally close it with a private endpoint and a firewall.
    publicNetworkAccess: 'Enabled'
  }
}

// One assignment at vault scope, so you can create and read certificates, secrets and keys.
resource operatorKeyVaultAdministrator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // guid() makes the assignment name deterministic, so a rerun converges instead of failing.
  name: guid(vault.id, operatorObjectId, keyVaultAdministratorRoleId)
  scope: vault
  properties: {
    roleDefinitionId: keyVaultAdministratorRoleId
    principalId: operatorObjectId
    principalType: operatorPrincipalType
  }
}

output vaultName string = vault.name
output vaultUri string = vault.properties.vaultUri
