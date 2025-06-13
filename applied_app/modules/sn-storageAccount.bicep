import * as Types from '../imports/sn-types.bicep'

// Metadata
metadata description = 'This template defines a storage account.' 

// Parameters
@description('The environment to deploy to.')
param environment object

@description('The tags to apply to the resources.')
param tags object

@description('The name of the resource.')
param name string

@description('The storage account sku.')
@allowed(['Standard_LRS','Standard_ZRS','Standard_GRS']) // Other options are available
param sku string = 'Standard_ZRS'

@description('Specifies if the storage account supports public network access(ex. cdn).')
param publicNetworkAccess bool = false

@allowed(['Allow', 'Deny'])
@description('Default firewall action if public network access is allowed.')
param defaultFirewallAction string = 'Deny'

@description('An array of IP address ranges in CIDR notation that should be allowed to access the storage account. Assumes a public network access with a Deny default firewall action.')
param allowedIPAddresses string[] = []

@description('An array of resource IDs (same tenant) that should be allowed to access the storage account. Assumes a public network access with a Deny default firewall action.')
param allowedResourceIds string[] = []

@description('Specifies if the storage account allows public access to blobs (no auth).')
param allowBlobPublicAccess bool = false

@description('Blob service properties.')
param blobServiceProperties object?

@description('An array of blob containers to create.')
param blobContainers Types.BlobContainer[] = []

@description('The management policy rules.')
param managementPolicyRules array?

@description('File service properties.')
param fileServiceProperties object?

@description('An array of file shares to create.')
param fileShares string[] = []

@description('Queue service properties.')
param queueServiceProperties object?

@description('An array of queues to create.')
param queues string[] = []

@description('Add a delete lock to the storage account.')
param deleteLock bool = false

// Variables
var location = az.resourceGroup().location
var allowedIPAddressObjects = [for ipAddress in allowedIPAddresses: {
  value: ipAddress
  action: 'Allow'
}]
var allowedResourceIdObjects = [for resourceId in allowedResourceIds: {
  tenantId: az.subscription().tenantId
  resourceId: resourceId
}]

// Resources
resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: name
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: sku
  }
  properties: {
    accessTier: 'Hot'
    publicNetworkAccess: publicNetworkAccess ? 'Enabled' : 'Disabled'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: allowBlobPublicAccess
    supportsHttpsTrafficOnly: true
    networkAcls: publicNetworkAccess ? {
      defaultAction: defaultFirewallAction
      bypass: 'AzureServices'
      ipRules: allowedIPAddressObjects
      resourceAccessRules: allowedResourceIdObjects
    } :  null
  }
}

// Create a lock on the Storage Account
resource storageAccountLock 'Microsoft.Authorization/locks@2020-05-01' = if(deleteLock) {
  scope: storageAccount
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// Blob
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  name: 'default'
  parent: storageAccount
  properties: blobServiceProperties ?? {}
}

resource blobContainerResources 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = [for blobContainer in blobContainers : {
  name: blobContainer.name
  parent: blobService
  properties: {
    publicAccess: blobContainer.publicAccess
    defaultEncryptionScope: '$account-encryption-key'
    denyEncryptionScopeOverride: false
  }
}]

resource lifecycleRules 'Microsoft.Storage/storageAccounts/managementPolicies@2024-01-01' = if(managementPolicyRules != null){
  name: 'default'
  parent: storageAccount
  properties: {
    policy: {
      rules: managementPolicyRules
    }
  }
}

// File
resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2024-01-01' = {
  name: 'default'
  parent: storageAccount
  properties: fileServiceProperties ?? {}
}

resource fileShareResources 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = [for fileShare in fileShares : {
  name: fileShare
  parent: fileServices
}]

// Queue
resource queueServices 'Microsoft.Storage/storageAccounts/queueServices@2024-01-01' = {
  name: 'default'
  parent: storageAccount
  properties: queueServiceProperties ?? {}
}

resource queueResources 'Microsoft.Storage/storageAccounts/queueServices/queues@2024-01-01' = [for queue in queues : {
  name: queue
  parent: queueServices
}]

// Read the storage account keys
var storageAccountKeys = storageAccount.listKeys()
var connectionString = 'DefaultEndpointsProtocol=https;EndpointSuffix=${az.environment().suffixes.storage};AccountName=${name};AccountKey=${storageAccountKeys.keys[0].value}'

// Store the connection string in the key vault
module keyVaultSecret 'sn-keyVault-secret.bicep' = if (contains(environment, 'keyVault')) {
  scope: az.resourceGroup(environment.keyVault.resourceGroup)
  name: take('KeyVaultSecret-${name}-ConnectionString',64)
  params: {
    keyVaultName: environment.keyVault.name
    name: '${name}-ConnectionString'
    value: connectionString
  }
}

// Outputs
output id string = storageAccount.id
output name string = storageAccount.name
