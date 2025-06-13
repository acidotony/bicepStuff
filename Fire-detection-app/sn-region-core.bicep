// Metadata
metadata description = 'This template defines the Selection Navigator regional resources for Core applications.'

// Functions
@description('Picker function. Given a selector value for filtering, and default value if the selector is not found, and an array of values to filter, return the first value that contains the selector.  Filter values can have multiple keys that are separated by commas followed by a single value separated from the keys by a colon.')
func P(selector string, default string, filterValues string[]) string => trim(last(split(first(filter(filterValues, filterValue => contains(split(first(split(filterValue,':')),','), selector))) ?? first(filter(filterValues, filterValue => empty(first(split(filterValue, ':'))))) ?? ':${default}',':')))

@description('Returns the index of the resource group based on the last three characters of its name.')
func ResourceGroupIndex(resourceGroupName string) int => int(substring(resourceGroupName, length(resourceGroupName) - 3, 3))

// Parameters
@description('The environment to deploy to.')
param environmentName string = 'dev2'

@description('The tags to apply to the resources.')
param tags object

@description('The name of the virtual network resource.')
param virtualNetworkName string?

@description('The name of the shared storeage account resource.')
param sharedStorageAccountName string?

// Variables
var environment = loadJsonContent('../data/environment.json')['sn-${environmentName}']
var location = az.resourceGroup().location
var logAnalyticsWorkspaces = loadJsonContent('../data/logAnalyticsWorkspace.json')
var applications = loadJsonContent('../data/sn-application.json')
var sqlDatabases = loadJsonContent('../data/sn-sqldatabase.json')
var kvAppSettings = loadJsonContent('../data/sn-kvAppSettings.json')

var virtualNetworkNameValue = virtualNetworkName ?? 'vnet-sn-${environmentName}-${location}-${format('{0:000}', 1)}'
var sharedStorageAccountNameValue = sharedStorageAccountName ?? 'stsn${environmentName}${location}'

// Filter the group roles by environment
var groupName = 'Common/Core'
var filteredApplications = filter(applications, application => (!contains(application, 'locations') || contains(application.locations, location)) && (contains(application, 'group') && application.group == groupName))
var filteredSqlDatabases = filter(sqlDatabases, sqlDatabase => (!contains(sqlDatabase, 'locations') || contains(sqlDatabase.locations, location)) && (contains(sqlDatabase, 'group') && sqlDatabase.group == groupName))

// Modules and Resources
resource appServicePlans 'Microsoft.Web/serverfarms@2024-04-01' existing =  [for aspIndex in range(1, 10): {
  name: 'asp-sn-${environment.name}-${location}-${format('{0:000}', aspIndex)}'
}]
resource functionAppServicePlans 'Microsoft.Web/serverfarms@2024-04-01' existing =  [for aspIndex in range(1, 10): {
  name: 'asp-sn-${environment.name}-${location}-fn-${format('{0:000}', aspIndex)}'
}]

var coreGroupRoleAssignments = [
  { group: 'SelNav-Azure-AppDev-Core', roles: ['Contributor'], filters: ['dev2','dev','qa'] }
]

// Define the applications
module applicationsModule './sn-site.bicep' = [for application in filteredApplications: {
  name: take('Site-${toLower(application.abbr)}',64)
  params: {
    environment: environment
    tags: tags
    appAbbreviation: application.abbr
    appServicePlanId: startsWith(application.type, 'function') ? functionAppServicePlans[application.aspIndex - 1].id : appServicePlans[application.aspIndex - 1].id
    kind: application.type
    appSettings: application.?appSettings ?? {}
    keyVaultName: environment.keyVault.name
    kvAppSettings: union(kvAppSettings.v2Security, kvAppSettings.launchDarkly, application.?kvAppSettings ?? {})
    logAnalyticsWorkspaceId: az.resourceId(logAnalyticsWorkspaces[environment.logAnalyticsWorkspace].resourceGroup, 'Microsoft.OperationalInsights/workspaces', logAnalyticsWorkspaces[environment.logAnalyticsWorkspace].name)
    appInsightsDataCap: int(P(environment.name, '1', union(application.?appInsightsDataCap ?? [], ['prod:10'])))
    subnetId: az.resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkNameValue, 'asp-sn-${environment.name}-${location}${startsWith(application.type, 'function') ? '-fn' : ''}-${format('{0:000}', application.aspIndex)}')
    minimumAppInstances: startsWith(application.type, 'function') ? functionAppServicePlans[application.aspIndex - 1].sku.capacity : appServicePlans[application.aspIndex - 1].sku.capacity
    storageAccountId: az.resourceId('Microsoft.Storage/storageAccounts', sharedStorageAccountNameValue)
    groupRoleAssignments: union(coreGroupRoleAssignments, application.?groupRoleAssignments ?? [])
    hybridConnections: application.?hybridConnections ?? []
    netFrameworkVersion: application.?netFrameworkVersion ?? null
    use32BitWorkerProcess: application.?use32BitWorkerProcess ?? null
  }
}]

// Define the SQL databases
module sqlDatabasesModule './sn-sqlDatabase.bicep' = [for sqlDatabase in filteredSqlDatabases: {
  name: take('SqlDatabase-${sqlDatabase.databaseName}',64)
  params: {
    name: sqlDatabase.databaseName
    tags: tags
    sqlServerName: 'sn-${environment.name}-sql-${format('{0:000}', ResourceGroupIndex(az.resourceGroup().name))}'
    elasticPoolName: sqlDatabase.?elasticPoolIndex != null ? 'sep-sn-${environment.name}-${location}-${format('{0:000}', sqlDatabase.?elasticPoolIndex)}' : 'sep-sn-${environment.name}-${location}-${format('{0:000}', 1)}'
    computeSettings: sqlDatabase.?computeSettings
    maxSizeGB: int(P(environment.name, '1', union(sqlDatabase.?maxSizeGB ?? [], ['prod:10'])))
    catalogCollation: sqlDatabase.?catalogCollation ?? null
    collation: sqlDatabase.?collation ?? null
  }
}]

// Assign signalR roles
var signalRName ='srs-sn-${environment.name}-${location}-001'
module signalRRoles './sn-signalR-roleAssignment.bicep' = {
  name: take('RoleAssignment-${signalRName}',64)
  params: {
    environment: environment
    resourceId: az.resourceId('Microsoft.SignalRService/signalR', signalRName)
    groupRoleAssignments: [
      { group: 'SelNav-Azure-Team-Gladiators', roles: ['SignalR App Server'], filters: ['dev2','dev','qa'] }
    ]
    siteRoleAssignments: [
      { site: 'shs', roles: ['SignalR App Server'], appSettingName: 'ConnectionStrings:SignalRPrimary' }
    ]
  }
}
