import * as sn from '../imports/sn-functions.bicep'
import * as Type from '../imports/sn-types.bicep'

metadata description = 'This template defines the Chillers regional environment resources.'

// Parameters
@description('The environment to deploy to.')
param environment object

@description('The tags to apply to the resources.')
param tags object

@description('The name of the virtual network resource.')
param virtualNetworkName string?

@description('The name of the shared storeage account resource.')
param sharedStorageAccountName string?

// Variables
var location = resourceGroup().location
var applications = loadJsonContent('../data/sn-application.json')
var sqlDatabases = loadJsonContent('../data/sn-sqldatabase.json')
var kvAppSettings = loadJsonContent('../data/sn-kvAppSettings.json')
var logAnalyticsWorkspaces = loadJsonContent('../data/logAnalyticsWorkspace.json')

var virtualNetworkNameValue = virtualNetworkName ?? 'vnet-sn-${environment.name}-${location}-${format('{0:000}', 1)}'
var sharedStorageAccountNameValue = sharedStorageAccountName ?? 'stsn${environment.name}${location}'
var chillersGroupRoleAssignments = [
  { group: 'SelNav-Azure-AppDev-Chillers', roles: ['Contributor'], filters: ['dev2','dev','qa'] }
]

// Filter the group roles by environment
var groupName = 'Chillers'

// Filter the group roles by environment
var filteredApplications = filter(applications, application => (!contains(application, 'locations') || contains(application.locations, location)) && (contains(application, 'group') && application.group == groupName))
var filteredSqlDatabases = filter(sqlDatabases, sqlDatabase => (!contains(sqlDatabase, 'locations') || contains(sqlDatabase.locations, location)) && (contains(sqlDatabase, 'group') && sqlDatabase.group == groupName))
var eventHubs = [
  {name: 'cbo'}, {name: 'cuo'}, {name: 'csbo'}, {name: 'crear'}
]

var storageAccountInfo = [
  {
    name: 'stsn${environment.name}cred${location}'
    group: 'cred'
  }
  {
    name: 'stsn${environment.name}cbo${location}'
    group: 'cbo'
  }
  {
    name: 'stsn${environment.name}cuo${location}'
    group: 'cuo'
  }
  {
    name: 'stsn${environment.name}csbo${location}'
    group: 'csbo'
  }
  {
    name: 'stsn${environment.name}crear${location}'
    group: 'crear'
  }
  {
    name: 'stsn${environment.name}crs${location}'
    group: 'crs'
  }
]

module storageAccounts 'sn-region-chillers-storageAccount.bicep' = [for storageAccount in storageAccountInfo: {
  name: storageAccount.name
  params: {
    environment: environment
    tags: union(tags.default, tags.shared)
    name: storageAccount.name
    virtualNetworkName: virtualNetworkNameValue
  }
}]

resource appServicePlans 'Microsoft.Web/serverfarms@2024-04-01' existing =  [for aspIndex in range(1, 10): {
  name: 'asp-sn-${environment.name}-${location}-${format('{0:000}', aspIndex)}'
}]
resource functionAppServicePlans 'Microsoft.Web/serverfarms@2024-04-01' existing =  [for aspIndex in range(1, 10): {
  name: 'asp-sn-${environment.name}-${location}-fn-${format('{0:000}', aspIndex)}'
}]

module applicationsModule 'sn-site.bicep' = [for application in filteredApplications: {
  name: take('Site-${toLower(application.abbr)}',64)
  params: {
    environment: environment
    tags: union(tags.default, tags.chillers)
    appAbbreviation: application.abbr
    appServicePlanId: startsWith(application.type, 'function') ? functionAppServicePlans[application.aspIndex - 1].id : appServicePlans[application.aspIndex - 1].id
    kind: application.type
    appSettings: application.?appSettings ?? {}
    keyVaultName: environment.keyVault.name
    kvAppSettings: union(kvAppSettings.v2Security, kvAppSettings.launchDarkly, application.?kvAppSettings ?? {})
    logAnalyticsWorkspaceId: az.resourceId(logAnalyticsWorkspaces[environment.logAnalyticsWorkspace].resourceGroup, 'Microsoft.OperationalInsights/workspaces', logAnalyticsWorkspaces[environment.logAnalyticsWorkspace].name)
    appInsightsDataCap: int(sn.P(environment.name, '1', union(application.?appInsightsDataCap ?? [], ['prod:10'])))
    subnetId: az.resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkNameValue, 'asp-sn-${environment.name}-${location}${startsWith(application.type, 'function') ? '-fn' : ''}-${format('{0:000}', application.aspIndex)}')
    minimumAppInstances: startsWith(application.type, 'function') ? functionAppServicePlans[application.aspIndex - 1].sku.capacity : appServicePlans[application.aspIndex - 1].sku.capacity
    storageAccountId: az.resourceId('Microsoft.Storage/storageAccounts', storageAccountInfo[application.?storageAccountGroup].name)
    groupRoleAssignments: union(chillersGroupRoleAssignments, application.?groupRoleAssignments ?? [])
    hybridConnections: application.?hybridConnections ?? []
    netFrameworkVersion: application.?netFrameworkVersion ?? null
    use32BitWorkerProcess: application.?use32BitWorkerProcess ?? null
    preWarmedInstanceCount: application.?preWarmedInstanceCount ?? null
  }
}]

module sqlDatabasesModule 'sn-sqlDatabase.bicep' = [for sqlDatabase in filteredSqlDatabases: {
  name: take('SqlDatabase-${sqlDatabase.databaseName}',64)
  params: {
    name: sqlDatabase.databaseName
    tags: union(tags.default, tags.chillers)
    sqlServerName: 'sn-${environment.name}-sql-${format('{0:000}', sn.ResourceGroupIndex(az.resourceGroup().name))}'
    elasticPoolName: sqlDatabase.?elasticPoolIndex != null ? 'sep-sn-${environment.name}-${location}-${format('{0:000}', sqlDatabase.?elasticPoolIndex)}' : 'sep-sn-${environment.name}-${location}-${format('{0:000}', 1)}'
    computeSettings: sqlDatabase.?computeSettings
    maxSizeGB: int(sn.P(environment.name, '1', union(sqlDatabase.?maxSizeGB ?? [], ['prod:10'])))
    catalogCollation: sqlDatabase.?catalogCollation ?? null
    collation: sqlDatabase.?collation ?? null
  }
}]

module chillersEventHubs 'sn-eventhub.bicep' = [for eventhub in eventHubs: {
  name: 'eh-sn-${environment.name}-${eventhub.name}-${location}'
  params: {
    environment: environment
    tags: union(tags.default, tags.chillers)
    name: 'eh-sn-${environment.name}-${eventhub.name}-${location}'
    eventHubName: eventhub.name
    sku: 'Standard'
    capacity: 1
    groupRoleAssignments : chillersGroupRoleAssignments
    sharedAccessPolicies: [
      {
        name: 'RootManageSharedAccessKey'
        rights: [
          'Listen'
          'Manage'
          'Send'
        ]
      }
    ]
  }
}]
