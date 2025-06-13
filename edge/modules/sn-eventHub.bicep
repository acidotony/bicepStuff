import * as Types from '../imports/sn-types.bicep'

metadata description = 'This template defines Event Hubs resources.'

// Parameters
@description('The environment to deploy to.')
param environment object

@description('The tags to apply to the Event Hubs namespace.')
param tags object = {}

@description('The name of the Event Hubs namespace.')
param name string?

@description('The name of the Event Hub')
param eventHubName string

@description('The SKU for the Event Hubs namespace.')
@allowed(['Basic', 'Standard', 'Premium'])
param sku string = 'Standard'

@description('The capacity for the Event Hubs namespace (only applicable for Standard and Premium SKUs).')
@minValue(1)
@maxValue(20)
param capacity int = 1

@description('Group role assignments to apply to the site.')
param groupRoleAssignments Types.GroupRoleAssignment[] = []

@description('An array of authorization rules to create for the Event Hubs namespace.')
param sharedAccessPolicies Types.SharedAccessPolicies[]

var location = resourceGroup().location
var namespaceName = name ?? 'eh-sn-${environment.name}-${eventHubName}-${location}'
var eventHubs = [
  { name: 'clients0', partitionCount: 32, messageRetentionInDays: 1}
  { name: 'clients1', partitionCount: 32, messageRetentionInDays: 1 }
  { name: 'clients2', partitionCount: 32, messageRetentionInDays: 1 }
  { name: 'clients3', partitionCount: 32, messageRetentionInDays: 1 }
  { name: 'loadmonitor', partitionCount: 1, messageRetentionInDays: 1 }
  { name: 'partitions', partitionCount: eventHubName == 'csbo' ? 18 : 12, messageRetentionInDays: 1 }
  { name: 'test', partitionCount: 4, messageRetentionInDays: 7 }
]

resource eventHubsNamespace 'Microsoft.EventHub/namespaces@2024-05-01-preview' = {
  name: namespaceName
  location: location
  tags: tags
  sku: {
    name: sku
    tier: sku
    capacity: capacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    geoDataReplication: {
      maxReplicationLagDurationInSeconds: 0
      locations: [
        {
          locationName: location
          roleType: 'Primary'
        }
      ]
    }
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
    zoneRedundant: true
    kafkaEnabled: true
    isAutoInflateEnabled: sku == 'Standard' ? true : false
    maximumThroughputUnits: sku == 'Standard' ? 40 : null
  }
}

resource accessPolicies 'Microsoft.EventHub/namespaces/authorizationRules@2024-05-01-preview' = [for policy in sharedAccessPolicies: {
  parent: eventHubsNamespace
  name: policy.name
  properties: {
    rights: policy.rights
  }
}]

resource eventHubsResources 'Microsoft.EventHub/namespaces/eventhubs@2024-05-01-preview' = [for eventHub in eventHubs: {
  parent: eventHubsNamespace
  name: eventHub.name
  properties: {
    messageTimestampDescription: {
      timestampType: 'LogAppend'
    }
    retentionDescription: {
      cleanupPolicy: 'Delete'
      retentionTimeInHours: eventHub.name == 'test' ? 168 : 24
    }
    partitionCount: eventHub.partitionCount
    messageRetentionInDays: eventHub.messageRetentionInDays
  }
}]

module roleAssignmentModule 'sn-eventHub-roleAssignment.bicep' = {
  name: take('RoleAssignment-${namespaceName}',64)
  params: {
    environment: environment
    resourceId: eventHubsNamespace.id
    groupRoleAssignments: groupRoleAssignments
  }
}

// Outputs
output namespaceId string = eventHubsNamespace.id
