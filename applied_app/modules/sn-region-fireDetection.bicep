import * as sn from '../imports/sn-functions.bicep'

// Metadata
metadata description = 'This template defines the Selection Navigator regional resources for Fire Detection applications.'

// Functions
@description('Picker function. Given a selector value for filtering, and default value if the selector is not found, and an array of values to filter, return the first value that contains the selector.  Filter values can have multiple keys that are separated by commas followed by a single value separated from the keys by a colon.')
func P(selector string, default string, filterValues string[]) string => trim(last(split(first(filter(filterValues, filterValue => contains(split(first(split(filterValue,':')),','), selector))) ?? ':${default}',':')))


//  Parameters 
@description('The environment to deploy to.')
@allowed(['dev2', 'dev', 'qa', 'sit', 'ppe', 'prod'])
param environmentName string = 'dev2'

@description('Tags to apply to all resources.')
param tags object

@description('The name of the shared storeage account resource.')
param sharedStorageAccountName string?

// Variables
var environment = loadJsonContent('../data/environment.json')['sn-${environmentName}']
var location = az.resourceGroup().location
var logAnalyticsWorkspaces = loadJsonContent('../data/logAnalyticsWorkspace.json')
var applications = loadJsonContent('../data/sn-application.json')
var sqlDatabases = loadJsonContent('../data/sn-sqldatabase.json')
var kvAppSettings = loadJsonContent('../data/sn-kvAppSettings.json')
var virtualNetworkIndexSuffix = 1
var virtualNetworkName = 'vnet-sn-${environment.name}-${location}-${format('{0:000}', virtualNetworkIndexSuffix)}'
var sharedStorageAccountNameValue = sharedStorageAccountName ?? 'stsn${environment.name}${location}26052025'
var fireDetectionGroupRoleAssignments = [ { group: 'SelNav-Azure-AppDev-SysControls', roles: ['Contributor'], filters: ['dev2','dev','qa'] }]

// Filter the group roles by environment
var groupName = 'Fire Detection'
var filteredApplications = filter(applications, application => (!contains(application, 'locations') || contains(application.locations, location)) && (contains(application, 'group') && application.group == groupName))
var filteredSqlDatabases = filter(sqlDatabases, sqlDatabase => (!contains(sqlDatabase, 'locations') || contains(sqlDatabase.locations, location)) && (contains(sqlDatabase, 'group') && sqlDatabase.group == groupName))

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${sharedStorageAccount.name};AccountKey=${sharedStorageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net'

// Modules and Resources
resource appServicePlans 'Microsoft.Web/serverfarms@2024-04-01' existing =  [for aspIndex in range(1, 10): {
  name: 'asp-sn-${environment.name}-${location}-${format('{0:000}', aspIndex)}'
}]
resource functionAppServicePlans 'Microsoft.Web/serverfarms@2024-04-01' existing =  [for aspIndex in range(1, 10): {
  name: 'asp-sn-${environment.name}-${location}-fn-${format('{0:000}', aspIndex)}'
}]

resource sharedStorageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: sharedStorageAccountNameValue
}

// Deploy SQL Databases module
module sqlDatabasesModule '../modules/sn-sqlDatabase.bicep' = [for sqlDatabase in filteredSqlDatabases: {
  name: take('SqlDatabase-${sqlDatabase.databaseName}', 64)
  params: {
    tags: tags
    name: sqlDatabase.databaseName
    sqlServerName: 'sn28052025-${environment.name}-sql-${format('{0:000}', sn.ResourceGroupIndex(az.resourceGroup().name))}'
    elasticPoolName: sqlDatabase.?elasticPoolIndex != null ? 'sep-sn-${environment.name}-${location}-${format('{0:000}', sqlDatabase.?elasticPoolIndex)}' : 'sep-sn-${environment.name}-${location}-${format('{0:000}', 1)}'
    catalogCollation: sqlDatabase.?catalogCollation ?? null
    collation: sqlDatabase.?collation ?? null
  }
}]

//  Deploy Site / Function-App for every application
module applicationsModule './sn-site.bicep' = [
  for a in filteredApplications: {
    name: take('Site-${toLower(a.abbr)}', 59)
    params: {
      name: '${sn.CreateSiteName(environment.name, location, a.type, a.abbr)}-${toLower(substring(uniqueString(resourceGroup().id, a.abbr), 0, 5))}'
      environment     : environment
      tags            : tags
      appAbbreviation : a.abbr
      kind            : a.type
      appServicePlanId: startsWith(a.type, 'function') ? functionAppServicePlans[a.aspIndex - 1].id : appServicePlans    [a.aspIndex - 1].id
      appSettings: union({
        WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: storageConnectionString
        WEBSITE_CONTENTSHARE: toLower('${sn.CreateSiteName(environment.name, location, a.type, a.abbr)}-${toLower(substring(uniqueString(resourceGroup().id, a.abbr), 0, 5))}-content')
      },
        a.?appSettings ?? {}
      )
      keyVaultName  : environment.keyVault.name
      kvAppSettings : union(kvAppSettings.v2Security,kvAppSettings.launchDarkly,a.?kvAppSettings ?? {})
      logAnalyticsWorkspaceId: az.resourceId(logAnalyticsWorkspaces[environment.logAnalyticsWorkspace].resourceGroup,'Microsoft.OperationalInsights/workspaces',logAnalyticsWorkspaces[environment.logAnalyticsWorkspace].name)
      appInsightsDataCap: int(P(environment.name, '1', union(a.?appInsightsDataCap ?? [], [ 'prod:10' ])))
      subnetId: resourceId(resourceGroup().name,'Microsoft.Network/virtualNetworks/subnets', virtualNetworkName,'asp-sn-${environment.name}-${location}${a.type == 'functionapp' ? '-fn' : ''}-${format('{0:000}', a.aspIndex)}')
      minimumAppInstances: startsWith(a.type, 'function')? functionAppServicePlans[a.aspIndex - 1].sku.capacity : appServicePlans    [a.aspIndex - 1].sku.capacity
      storageAccountId: sharedStorageAccount.id
      groupRoleAssignments: union(fireDetectionGroupRoleAssignments, a.?groupRoleAssignments ?? [])
      hybridConnections: [for hc in (a.?hybridConnections ?? []): {
          hostname: hc.hostname
          port    : hc.port
          filters : hc.?filters ?? []
        }
      ]
      netFrameworkVersion   : a.?netFrameworkVersion   ?? null
      use32BitWorkerProcess : a.?use32BitWorkerProcess ?? null
    }
  }
]
