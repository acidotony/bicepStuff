// Metadata
metadata description = 'This template defines the network including default subnets, NAT gateway, network security groups, and private dns zones.' 

// Parameters
@description('The environment to deploy to.')
param environment object

@description('The tags to apply to the resources.')
param tags object

@description('The name of the resource.')
param name string

@minValue(1)
@maxValue(999)
@description('The index suffix for the virtual network.')
param indexSuffix int = 1

@description('The number of public ip addresses to create for outbound communication.')
param publicIpCount int = 1

@minValue(0)
@maxValue(64)
@description('The number of app service plan subnets to create.')
param appServicePlanSubnetCount int = 0

@minValue(0)
@maxValue(64)
@description('The number of function app service plan subnets to create.')
param functionAppServicePlanSubnetCount int = 0

// Variables
var location = az.resourceGroup().location
var privateDNSZoneNames  = [
  'privatelink${az.environment().suffixes.sqlServerHostname}'
  'privatelink.documents.azure.com'
  'privatelink.vaultcore.azure.net'
  'privatelink.blob.${az.environment().suffixes.storage}'
  'privatelink.table.${az.environment().suffixes.storage}'
  'privatelink.queue.${az.environment().suffixes.storage}'
  'privatelink.file.${az.environment().suffixes.storage}'
  'privatelink.search.windows.net'
  'privatelink.service.signalr.net'
  //'privatelink.azurewebsites.net'
  //'privatelink.datafactory.azure.net'
  //'privatelink.adf.azure.com'
]

// Define the default subnets
var defaultSubnets = [
  {
    name: 'services'
    properties: {
      addressPrefix: '172.16.0.0/24'
      networkSecurityGroup: { id: networkSecurityGroup.id }
      defaultOutboundAccess: false
    }
  }
]

// Define the app service plan subnets
var appServicePlanSubnets = [for subnetIndex in range(1, appServicePlanSubnetCount) : {
  name: 'asp-sn-${environment.name}-${location}-${format('{0:000}', subnetIndex)}'
  properties: {
    addressPrefix: '172.16.${subnetIndex}.0/24'
    networkSecurityGroup: { id: networkSecurityGroup.id }
    natGateway: { id: natGateway.id }
    defaultOutboundAccess: false
    delegations: [
      {
        name: '0'
        properties: {
          serviceName: 'Microsoft.Web/serverFarms'
        }
      }
    ]
  }
}]

// Define the function app service plan subnets
var functionAppServicePlanSubnets = [for subnetIndex in range(1, functionAppServicePlanSubnetCount) : {
  name: 'asp-sn-${environment.name}-${location}-fn-${format('{0:000}', subnetIndex)}'
  properties: {
    addressPrefix: '172.16.${subnetIndex + 64}.0/24'
    networkSecurityGroup: { id: networkSecurityGroup.id }
    natGateway: { id: natGateway.id }
    defaultOutboundAccess: false
    delegations: [
      {
        name: '0'
        properties: {
          serviceName: 'Microsoft.Web/serverFarms'
        }
      }
    ]
  }
}]

// Combine the subnet definitions
var subnets = union(defaultSubnets, appServicePlanSubnets, functionAppServicePlanSubnets)

// Resources

// Create a network security group
resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-sn-${environment.name}-${location}-${format('{0:000}', indexSuffix)}'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
} 

// Create a lock on the network security group
resource networkSecurityGroupLock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: networkSecurityGroup
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// Create public ip address(es) for outbound communication via NAT gateway
resource publicIpAddresses 'Microsoft.Network/publicIPAddresses@2024-05-01' = [for publicIpIndex in range(1, publicIpCount) : {
  name: 'pip-natg-sn-${environment.name}-${location}-${format('{0:000}', publicIpIndex)}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    ddosSettings: {protectionMode: 'VirtualNetworkInherited'}
  }
}]

// Create a lock for each of the public ip addresses
resource publicIpAddressLock 'Microsoft.Authorization/locks@2020-05-01' = [for (publicIpIndex, index) in range(1, publicIpCount) : {
  scope: publicIpAddresses[index]
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}]

// Create a NAT gateway
resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
  name: 'natg-sn-${environment.name}-${location}-${format('{0:000}', indexSuffix)}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [for (publicIpIndex, index) in range(1, publicIpCount) : {
      id: publicIpAddresses[index].id
    }]
  }
}

// Create a lock on the NAT gateway
resource natGatewayLock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: natGateway
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// Create the virtual network
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties:{
    addressSpace: {
      addressPrefixes: ['172.16.0.0/16']
    }
    privateEndpointVNetPolicies: 'Disabled'
    subnets:subnets
  }
}

// Create a lock on the virtual network
resource virtualNetworkLock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: virtualNetwork
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// Create private dns zones
resource privateDNSZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for privateDNSZoneName in privateDNSZoneNames : {
  name: privateDNSZoneName
  location: 'global'
  tags: tags
  properties: {}
}]

// Create locks on the private DNS zones
resource privateDNSZoneLocks 'Microsoft.Authorization/locks@2020-05-01' = [for (privateDNSZoneName, index) in privateDNSZoneNames : {
  scope: privateDNSZones[index]
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}]

// Link the virtual network to the private dns zones
resource privateDNSZoneVirtualNetworkLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (privateDNSZoneName, index) in privateDNSZoneNames : {
  parent: privateDNSZones[index]
  name: 'pdl-sn-${environment.name}-${location}-${format('{0:000}', indexSuffix)}'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: {
      id: virtualNetwork.id
    }
    registrationEnabled: false
  }
}]

// Read back the services subnet
resource servicesSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  name: 'services'
  parent: virtualNetwork
}

// Outputs
output virtualNetworkId string = virtualNetwork.id
output virtualNetworkName string = virtualNetwork.name
output natGatewayId string = natGateway.id
output natGatewayName string = natGateway.name
output networkSecurityGatewayId string = networkSecurityGroup.id
output networkSecurityGatewayName string = networkSecurityGroup.name
output servicesSubNetId string = servicesSubnet.id
output servicesSubNetName string = servicesSubnet.name
output subnets array = subnets
