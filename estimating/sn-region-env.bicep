import * as sn from './imports/sn-functions.bicep'

// Metadata
metadata description = 'This template defines the Selection Navigator regional environment resources.'

// Parameters
@description('The environment to deploy to.')
@allowed(['dev2', 'dev', 'qa', 'sit', 'ppe', 'prod'])
param environmentName string = 'dev2'

// Variables
var environment = loadJsonContent('data/environment.json')['sn-${environmentName}']
var location = az.resourceGroup().location
var logAnalyticsWorkspaces = loadJsonContent('data/logAnalyticsWorkspace.json')
var tags = loadJsonContent('data/tags.json')

// Read the resource group index from the resoucegroup name as an integer representation of the last 3 characters
var resourceGroupName = az.resourceGroup().name
var resourceGroupIndex = int(substring(resourceGroupName, length(resourceGroupName) - 3, 3))

// Modules and Resources

// Set resource group permissions
module resourceGroupModule './modules/sn-resourceGroup.bicep' = {
  name: take('ResourceGroupPermissions-${az.resourceGroup().name}',64)
  params: {
    environment: environment
    groupRoleAssignments: json(loadTextContent('data/sn-resourceGroupRBAC.json'))
  }
}

// Read the Log Analytics Workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2020-08-01' existing = {
  scope: az.resourceGroup(logAnalyticsWorkspaces[environment.logAnalyticsWorkspace].resourceGroup)
  name: logAnalyticsWorkspaces[environment.logAnalyticsWorkspace].name
}

// Create the network
var virtualNetworkIndexSuffix = 1
var virtualNetworkName = 'vnet-sn-${environment.name}-${location}-${format('{0:000}', virtualNetworkIndexSuffix)}'
module virtualNetworkModule './modules/sn-network.bicep' = {
  name: take('VirtualNetwork-${virtualNetworkName}',64)
  params: {
    environment: environment
    tags: union(tags.default, tags.shared)
    name: virtualNetworkName
    indexSuffix: virtualNetworkIndexSuffix
    publicIpCount: int(sn.P(environment.name, '1', ['prod:2']))
    appServicePlanSubnetCount: 6
    functionAppServicePlanSubnetCount: 4
  }
}

// Read VirtualNetwork
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: virtualNetworkName
}

// Connect the security storage account to the network
resource securityStorageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  scope: az.resourceGroup(environment.securityStorageAccount.resourceGroup)
  name: environment.securityStorageAccount.name
}
module securityStorageAccountPrivateEndpointModule './modules/sn-privateEndpoint.bicep' = {
  name: take('PrivateEndpoint-${securityStorageAccount.name}',64)
  params: {
    tags: union(tags.default, tags.shared)
    virtualNetworkName: virtualNetworkName
    subnetName: 'services'
    resourceId: securityStorageAccount.id
    nameSuffix: '-blob'
    groupId: 'blob'
    privateDnsZoneName: 'privatelink.blob.${az.environment().suffixes.storage}'
  }
}

// Read the keyvault
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  scope: az.resourceGroup(environment.keyVault.resourceGroup)
  name: environment.keyVault.name
}

module keyVaultPrivateEndpointModule './modules/sn-privateEndpoint.bicep' = {
  name: take('PrivateEndpoint-${keyVault.name}',64)
  params: {
    tags: union(tags.default, tags.shared)
    virtualNetworkName: virtualNetworkName
    subnetName: 'services'
    resourceId: keyVault.id
    groupId: 'vault'
    privateDnsZoneName: 'privatelink.vaultcore.azure.net'
  }
}

// Connect the cosmos DB to the network
resource cosmosDbAccount 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  scope: az.resourceGroup(environment.cosmosDbAccount.resourceGroup)
  name: environment.cosmosDbAccount.name
}

module cosmosDbAccountPrivateEndpointModule './modules/sn-privateEndpoint.bicep' = {
  name: take('PrivateEndpoint-${cosmosDbAccount.name}',64)
  params: {
    tags: union(tags.default, tags.shared)
    virtualNetworkName: virtualNetworkName
    subnetName: 'services'
    resourceId: cosmosDbAccount.id
    groupId: 'Sql'
    privateDnsZoneName: 'privatelink.documents.azure.com'
  }
}

// Create Signal R Service
var signalRSku = sn.P(environment.name, 'Standard_S1',['prod:Premium_P1'])
resource signalRService 'Microsoft.SignalRService/signalR@2024-03-01' = {
  name: 'srs-sn-${environment.name}-${location}-001'
  location: location
  tags: union(tags.default, tags.shared)
  kind: 'SignalR'
  sku: {
    name: signalRSku
  }
  properties: {
    features: [
      {
        flag: 'ServiceMode'
        value: 'Default'
        properties: {}
      }
      {
        flag: 'EnableMessagingLogs'
        value: 'False'
        properties: {}
      }
    ]
  }
}

// Create Signal R Autoscale for Premium SKU
resource signalRAutoscale 'Microsoft.Insights/autoscalesettings@2022-10-01' = if(signalRSku == 'Premium_P1') {
  name: signalRService.name
  location: location
  properties: {
    name: signalRService.name
    enabled: true
    targetResourceUri: signalRService.id
    notifications:[
      {
        operation: 'Scale'
        email: {
          sendToSubscriptionAdministrator: false
          sendToSubscriptionCoAdministrators: false
          customEmails: []
        }
      }
    ]
    profiles: [
      {
        name: 'default'
        capacity: {
          default: '1'
          minimum: '1'
          maximum: '100'
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'ConnectionQuotaUtilization'
              metricResourceUri: signalRService.id
              operator: 'GreaterThan'
              statistic: 'Average'
              threshold: 80
              timeAggregation: 'Average'
              timeGrain: 'PT1M'
              timeWindow: 'PT5M'
              dividePerInstance: false
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
          {
            metricTrigger: {
              metricName: 'ConnectionQuotaUtilization'
              metricResourceUri: signalRService.id
              operator: 'LessThan'
              statistic: 'Average'
              threshold: 30
              timeAggregation: 'Average'
              timeGrain: 'PT1M'
              timeWindow: 'PT5M'
              dividePerInstance: false
            }
            scaleAction: {
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
        ]
      }
    ]
  }
}

// Create a lock on the Signal R service
resource signalRServiceLock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: signalRService
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// Create App Sevice Plans

// App Service Plan 001 - Ordering + Smaller Core apps
resource appServicePlan001 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-sn-${environment.name}-${location}-001'
  location: location
  kind: 'app'
  tags: union(tags.default, tags.shared)
  sku: {
    name: 'P2v3'
    capacity: int(sn.P(environment.name, '1', ['qa,prod:2']))
  }
  properties: {
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 20
  }
}

resource appServicePlan001Lock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: appServicePlan001
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// App Service Plan 002 - AHU rater apps
resource appServicePlan002 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-sn-${environment.name}-${location}-002'
  location: location
  kind: 'app'
  tags: union(tags.default, tags.ahu)
  sku: {
    name: 'P2v3'
    capacity: int(sn.P(environment.name, '1', ['qa,prod:2']))
  }
  properties: {
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 20
  }
}

resource appServicePlan002Lock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: appServicePlan002
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// App Service Plan 003 - SysControls Apps
resource appServicePlan003 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-sn-${environment.name}-${location}-003'
  location: location
  kind: 'app'
  tags: union(tags.default, tags.sysControls)
  sku: {
    name: 'P2v3'
    capacity: int(sn.P(environment.name, '1', ['qa,prod:2']))
  }
  properties: {
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 20
  }
}

resource appServicePlan003Lock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: appServicePlan003
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// App Service Plan 004 - Chillers apps
resource appServicePlan004 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-sn-${environment.name}-${location}-004'
  location: location
  kind: 'app'
  tags: union(tags.default, tags.chillers)
  sku: {
    name: 'P2v3'
    capacity: int(sn.P(environment.name, '1', ['qa,prod:2']))
  }
  properties: {
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 20
  }
}

resource appServicePlan004Lock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: appServicePlan004
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// App Service Plan 005 - Core apps
resource appServicePlan005 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-sn-${environment.name}-${location}-005'
  location: location
  kind: 'app'
  tags: union(tags.default, tags.core)
  sku: {
    name: 'P2v3'
    capacity: int(sn.P(environment.name, '1', ['qa,prod:2']))
  }
  properties: {
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 20
  }
}

resource appServicePlan005Lock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: appServicePlan005
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// App Service Plan 006 - Applied/AHU Score apps
resource appServicePlan006 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-sn-${environment.name}-${location}-006'
  location: location
  kind: 'app'
  tags: union(tags.default, tags.core)
  sku: {
    name: 'P2v3'
    capacity: int(sn.P(environment.name, '1', ['qa,prod:2']))
  }
  properties: {
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 20
  }
}

resource appServicePlan006Lock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: appServicePlan006
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// Create Function elastic App Sevice Plans

// Function Elastic App Service Plan 001 - Chillers
var appFnServicePlan001MinInstances = int(sn.P(environment.name, '2', ['prod:4']))
resource appFnServicePlan001 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-sn-${environment.name}-${location}-fn-001'
  location: location
  kind: 'elastic'
  tags: union(tags.default, tags.chillers)
  sku: {
    name: 'EP3'
  }
  properties: {
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 100
  }
}

resource appFnServicePlan001Lock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: appFnServicePlan001
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// Function Elastic App Service Plan 002 - Chillers Durable Functions
var appFnServicePlan002MinInstances = int(sn.P(environment.name, '1', ['dev2,dev,prod:2']))
resource appFnServicePlan002 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-sn-${environment.name}-${location}-fn-002'
  location: location
  kind: 'elastic'
  tags: union(tags.default, tags.chillers)
  sku: {
    name: 'EP3'
  }
  properties: {
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 100
  }
}

resource appFnServicePlan002Lock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: appFnServicePlan002
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// Function Elastic App Service Plan 003 - AHU Rater Functions
var appFnServicePlan003MinInstances = int(sn.P(environment.name, '1', ['dev2,dev:2','sit,prod:10']))
resource appFnServicePlan003 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-sn-${environment.name}-${location}-fn-003'
  location: location
  kind: 'elastic'
  tags: union(tags.default, tags.ahu)
  sku: {
    name: 'EP2'
  }
  properties: {
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 50
  }
}

resource appFnServicePlan003Lock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: appFnServicePlan003
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// Function Elastic App Service Plan 004 - AHU Rater Functions
var appFnServicePlan004MinInstances = int(sn.P(environment.name, '1', ['dev2,dev,prod:2']))
resource appFnServicePlan004 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-sn-${environment.name}-${location}-fn-004'
  location: location
  kind: 'elastic'
  tags: union(tags.default, tags.sysControls)
  sku: {
    name: 'EP1'
  }
  properties: {
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 100
  }
}

resource appFnServicePlan004Lock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: appFnServicePlan004
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// Function Elastic App Service Plan 005 - Chillers CRED Functions
var appFnServicePlan005MinInstances = int(sn.P(environment.name, '1', ['dev2,dev,prod:2']))
resource appFnServicePlan005 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-sn-${environment.name}-${location}-fn-005'
  location: location
  kind: 'elastic'
  tags: union(tags.default, tags.chillers)
  sku: {
    name: 'EP3'
  }
  properties: {
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 100
  }
}

resource appFnServicePlan005Lock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: appFnServicePlan005
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// Create SQL Server
var sqlServerIndexSuffix = resourceGroupIndex
var sqlServerName = 'sn-${environment.name}-sql-${format('{0:000}', sqlServerIndexSuffix)}'
module sqlServerModule './modules/sn-sqlServer.bicep' = {
  name: take('SQLServer-${sqlServerName}',64)
  params: {
    environment: environment
    tags: union(tags.default, tags.shared)
    name: sqlServerName
    adminUsername: keyVault.getSecret('sqlServerUsername')
    adminPassword: keyVault.getSecret('sqlServerPassword') 
    elasticPlans: [
      {
        maxCapacity: int(sn.P(environment.name, '400', ['prod:800']))
        maxDatabaseCapacity: int(sn.P(environment.name, '300', ['prod:400']))
        maxSizeGB: 500
      }
    ]
    logAnalyticsWorkspaceId: logAnalyticsWorkspace.id
  }
}

// Read SQL Server
resource sqlServer 'Microsoft.Sql/servers@2024-05-01-preview' existing = {
  name: sqlServerName
}

module sqlServerPrivateEndpointModule './modules/sn-privateEndpoint.bicep' = {
  name: take('PrivateEndpoint-${sqlServerName}',64)
  params: {
    tags: union(tags.default, tags.shared)
    virtualNetworkName: virtualNetworkName
    subnetName: 'services'
    resourceId: sqlServer.id
    groupId: 'sqlserver'
    privateDnsZoneName: 'privatelink${az.environment().suffixes.sqlServerHostname}'
  }
}

// Create shared storage account
var sharedBlobContainers = [
  {name:'ahudebuglogs', publicAccess: 'None', clean: true}
  {name:'aomsorders', publicAccess: 'None', clean: true}
  {name:'appliedequipmentorderpackages', publicAccess: 'None', clean: true}
  {name:'applieddxdrawings', publicAccess: 'None', clean: false}
  {name:'applieddxtemporaryfiles', publicAccess: 'None', clean: true}
  {name:'applieddxvtz', publicAccess: 'None', clean: false}
  {name:'chillersoutput', publicAccess: 'None', clean: true}
  {name:'controlscbs', publicAccess: 'None', clean: true}
  {name:'docgentemplates', publicAccess: 'None', clean: false}
  {name:'documentdownload', publicAccess: 'None', clean: true}
  {name:'documentgeneration', publicAccess: 'None', clean: true}
  {name:'documentrenderingservice', publicAccess: 'None', clean: true}
  {name:'ahuorderingservices', publicAccess: 'None', clean: true}
  {name:'equipmentcbs', publicAccess: 'None', clean: true}
  {name:'fpcdocgen', publicAccess: 'None', clean: true}
  {name:'gryphonrpdata', publicAccess: 'None', clean: false}
  {name:'modelgrouptemplates', publicAccess: 'None', clean: false}
  {name:'sessiontemporaryfiles', publicAccess: 'None', clean: true}
  {name:'sessiondatasnapshots', publicAccess: 'None', clean: false}
  {name:'slidingbtp', publicAccess: 'None', clean: true}
  {name:'specialrequests', publicAccess: 'None', clean: true}
  {name:'sstgeneration', publicAccess: 'None', clean: true}
  {name:'systemversionmanifests', publicAccess: 'None', clean: false}
  {name:'transientdocumentrepository', publicAccess: 'None', clean: true}
  {name:'excelgeneration', publicAccess: 'None', clean: true}
]

var sharedStorageAccountName = 'stsn${environment.name}${location}'
module sharedStorageAccountModule './modules/sn-storageAccount.bicep' = {
  name: take('StorageAccount-${sharedStorageAccountName}',64)
  params: {
    environment: environment
    tags: union(tags.default, tags.shared)
    name: sharedStorageAccountName
    sku: 'Standard_ZRS'
    publicNetworkAccess: false
    blobContainers: [for sharedBlobContainer in sharedBlobContainers: {name: sharedBlobContainer.name, publicAccess: sharedBlobContainer.publicAccess}]
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

// Read back the storage account
resource sharedStorageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: sharedStorageAccountName
}

var sharedStorageAccountPrivateEndpointDefinitions = [
  {nameSuffix: '-blob', groupId: 'blob', privateDnsZoneName: 'privatelink.blob.${az.environment().suffixes.storage}'}
  {nameSuffix: '-table', groupId: 'table', privateDnsZoneName: 'privatelink.table.${az.environment().suffixes.storage}'}
  {nameSuffix: '-queue', groupId: 'queue', privateDnsZoneName: 'privatelink.queue.${az.environment().suffixes.storage}'}
  {nameSuffix: '-file', groupId: 'file', privateDnsZoneName: 'privatelink.file.${az.environment().suffixes.storage}'}
]

module sharedStorageAccountPrivateEndpointsModule './modules/sn-privateEndpoint.bicep' = [for privateEndpoint in sharedStorageAccountPrivateEndpointDefinitions: {
  name: take('PrivateEndpoint-${sharedStorageAccountName}${privateEndpoint.nameSuffix}',64)
  params: {
    nameSuffix: privateEndpoint.nameSuffix
    tags: union(tags.default, tags.shared)
    virtualNetworkName: virtualNetworkName
    subnetName: 'services'
    resourceId: sharedStorageAccount.id
    groupId: privateEndpoint.groupId
    privateDnsZoneName: privateEndpoint.privateDnsZoneName
  }
}]

module chillersModule './modules/sn-region-chillers.bicep' = {
  name: take('ChillersModule-${environment.name}',64)
  params: {
    environment: environment.name
    tags: tags
    virtualNetworkName: virtualNetworkName
    sharedStorageAccountName: sharedStorageAccountName
  }
}

module fireDetectionModule './modules/sn-region-fireDetection.bicep' = {
  name: take('ChillersModule-${environment.name}',64)
  params: {
    environmentName: environment.name
    tags: tags
    sharedStorageAccountName: sharedStorageAccountName
  }
}

module appliedModule './modules/sn-region-applied.bicep' = {
  name: take('AppliedModule-${environment.name}',64)
  params: {
    environmentName: environment.name
    tags: tags
    sharedStorageAccountName: sharedStorageAccountName
  }
}

module edgeModule './modules/sn-region-edge.bicep' = {
  name: take('EdgeModule-${environment.name}',64)
  params: {
    environmentName: environment.name
    tags: tags
    sharedStorageAccountName: sharedStorageAccountName
  }
}

// Create shared location cleanup function
var cleanBlobContainer = filter(sharedBlobContainers, container => container.clean)
var cleanBlobContainerNames = [for container in cleanBlobContainer: container.name]
var cleanBlobContainerList = join(cleanBlobContainerNames, ',')

var slcAppSettings = {
  BlobContainerList: cleanBlobContainerList
  FileShareList: ''
}

// Outputs
output environment object = environment
