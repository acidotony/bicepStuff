metadata description = 'This template defines the Chillers storage account resources.'

// Parameters
@description('The environment to deploy to.')
param environment object

@description('The tags to apply to the resources.')
param tags object

@description('Storage account name.')
param name string?

@description('The name of the virtual network resource.')
param virtualNetworkName string?

// Variables
var location = resourceGroup().location
var chillersGroupRoleAssignments = [
  { group: 'SelNav-Azure-AppDev-Chillers', roles: ['Contributor'], filters: ['dev2','dev','qa'] }
]
var virtualNetworkNameValue = virtualNetworkName ?? 'vnet-sn-${environment.name}-${location}-${format('{0:000}', 1)}'
var storageAccountNameValue = name ?? 'stsn${environment.name}${location}'

var sharedStorageAccountPrivateEndpointDefinitions = [
  {nameSuffix: '-blob', groupId: 'blob', privateDnsZoneName: 'privatelink.blob.${az.environment().suffixes.storage}'}
  {nameSuffix: '-table', groupId: 'table', privateDnsZoneName: 'privatelink.table.${az.environment().suffixes.storage}'}
  {nameSuffix: '-queue', groupId: 'queue', privateDnsZoneName: 'privatelink.queue.${az.environment().suffixes.storage}'}
  {nameSuffix: '-file', groupId: 'file', privateDnsZoneName: 'privatelink.file.${az.environment().suffixes.storage}'}
]

// Modules and Resources
module storageAccount 'sn-storageAccount.bicep' = {
  name: storageAccountNameValue
  params: {
    environment: environment
    tags: union(tags.default, tags.shared)
    name: storageAccountNameValue
    sku: 'Standard_ZRS'
    publicNetworkAccess: false
    blobServiceProperties:{ 
      changeFeed: {
        enabled: false
      }
      deleteRetentionPolicy: {
        enabled: false
        allowPermanentDelete: false
      }
      isVersioningEnabled: false
      restorePolicy:{
        enabled: false
      }
    }
    deleteLock: true
  }
}

module credSharedStorageAccountPrivateEndpointsModule 'sn-privateEndpoint.bicep' = [for privateEndpoint in sharedStorageAccountPrivateEndpointDefinitions: {
  name: take('PrivateEndpoint-${storageAccount.name}${privateEndpoint.nameSuffix}',64)
  params: {
    nameSuffix: privateEndpoint.nameSuffix
    tags: union(tags.default, tags.shared)
    virtualNetworkName: virtualNetworkNameValue
    subnetName: 'services'
    resourceId: storageAccount.outputs.id
    groupId: privateEndpoint.groupId
    privateDnsZoneName: privateEndpoint.privateDnsZoneName
  }
}]

module credStorageAccountRoleAssignmentsModule 'sn-storageAccount-roleAssignment.bicep' =  {
  name: take('RoleAssignments-${storageAccount.name}',64)
  params: {
    environment: environment
    resourceId: storageAccount.outputs.id
    groupRoleAssignments: chillersGroupRoleAssignments
  }
}
