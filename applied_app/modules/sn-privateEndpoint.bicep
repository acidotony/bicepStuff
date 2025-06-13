// Metadata
metadata description = 'This template defines private endpoint resources for the network.' 

@description('The tags to apply to the resources.')
param tags object

@description('The name of the virtual network to attach the private endpoint to.')
param virtualNetworkName string

@description('The name of the subnet to attach the private endpoint to.')
param subnetName string

@description('The id of the resource the private endpoint will connect to.')
param resourceId string

@description('A suffix to append to the private endpoint name. ex. "-blob"')
param nameSuffix string = ''

@description('The group id to connect to.')
param groupId string

@description('The private dns zone name.')
param privateDnsZoneName string

// Variables
var location = az.resourceGroup().location
var resourceName = last(split(resourceId, '/'))
var privateEndpointName = '${replace(virtualNetworkName, 'vnet', 'pe')}-${resourceName}${nameSuffix}'

// Resources

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: virtualNetworkName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: virtualNetwork
  name: subnetName
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnet.id
    }
    privateLinkServiceConnections: [{
      name: '${virtualNetworkName}-${subnetName}'
      properties: {
        privateLinkServiceId: resourceId
        groupIds: [groupId]
      }
    }]
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-05-01' existing = {
  name: privateDnsZoneName
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [{
      name: replace(privateDnsZone.name, '.', '_')
      properties: {
        privateDnsZoneId: privateDnsZone.id
      }
    }]
  }
}

// Outputs
output id string = privateEndpoint.id
output name string = privateEndpointName
