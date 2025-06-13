// Metadata
metadata description = 'This template defines the Selection Navigator regional resources for Fire Detection applications.'

// Functions
@description('Picker function. Given a selector value for filtering, and default value if the selector is not found, and an array of values to filter, return the first value that contains the selector.  Filter values can have multiple keys that are separated by commas followed by a single value separated from the keys by a colon.')
func P(selector string, default string, filterValues string[]) string => trim(last(split(first(filter(filterValues, filterValue => contains(split(first(split(filterValue,':')),','), selector))) ?? ':${default}',':')))

//  Imports 
import * as Functions from '../imports/sn-functions.bicep'


//  Parameters 
@description('The environment to deploy to.')
@allowed(['dev2', 'dev', 'qa', 'sit', 'ppe', 'prod'])
param environmentName string = 'dev2'

@description('Tags to apply to all resources.')
param tags object

@description('The name of the shared storeage account resource.')
param sharedStorageAccountName string?

@description('The name of the virtual network resource.')
param virtualNetworkName string?

// Variables
var environment = loadJsonContent('../data/environment.json')['sn-${environmentName}']
var location = az.resourceGroup().location
var logAnalyticsWorkspaces = loadJsonContent('../data/logAnalyticsWorkspace.json')
var applications = loadJsonContent('../data/sn-application.json')
var sqlDatabases = loadJsonContent('../data/sn-sqldatabase.json')
var kvAppSettings = loadJsonContent('../data/sn-kvAppSettings.json')


var sqlServerNameFinal = 'sql-sn-${environment.name}001'
 


// Filter the group roles by environment
var groupName = 'Fire Detection'
var filteredApplications = filter(applications, application => (!contains(application, 'locations') || contains(application.locations, location)) && (contains(application, 'group') && application.group == groupName))
var filteredSqlDatabases = filter(sqlDatabases, sqlDatabase => (!contains(sqlDatabase, 'locations') || contains(sqlDatabase.locations, location)) && (contains(sqlDatabase, 'group') && sqlDatabase.group == groupName))

var virtualNetworkNameValue = virtualNetworkName ?? 'vnet-sn-${environment.name}-${location}-${format('{0:000}', 1)}'
var sharedStorageAccountNameValue = sharedStorageAccountName ?? 'stsn${environment.name}${location}'
var fireDetectionGroupRoleAssignments = [
  { group: 'SelNav-Azure-AppDev-SysControls', roles: ['Contributor'], filters: ['dev2','dev','qa'] }
]



// Modules and Resources
resource appServicePlans 'Microsoft.Web/serverfarms@2024-04-01' existing =  [for aspIndex in range(1, 10): {
  name: 'asp-sn-${environment.name}-${location}-${format('{0:000}', aspIndex)}'
}]
resource functionAppServicePlans 'Microsoft.Web/serverfarms@2024-04-01' existing =  [for aspIndex in range(1, 10): {
  name: 'asp-sn-${environment.name}-${location}-fn-${format('{0:000}', aspIndex)}'
}]



// Deploy SQL Databases module
module sqlDatabasesModule '../modules/sn-sqlDatabase.bicep' = [for db in filteredSqlDatabases: {
  name: take('SqlDatabase-${db.databaseName}', 64)
  params: {
    tags: tags
    name: db.databaseName
    sqlServerName: 'sn-${environment.name}-sql-${format('{0:000}', sn.ResourceGroupIndex(az.resourceGroup().name))}'
    elasticPoolName: db.?elasticPoolIndex != null ? 'sep-sn-${environment.name}-${location}-${format('{0:000}', db.?elasticPoolIndex)}' : 'sep-sn-${environment.name}-${location}-${format('{0:000}', 1)}'
    computeSettings: db.computeSettings
    maxSizeGB: int(P(environmentName, '1', union(db.maxSizeGB ?? [], ['prod:10'])))
    catalogCollation: db.?catalogCollation ?? null
    collation: db.?collation ?? null
  }
}]


// Define the applications
module applicationsModule './sn-site.bicep' = [for application in filteredApplications: {
  name: take('Site-${toLower(application.abbr)}',64)
  params: {
    name: application.name
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
    groupRoleAssignments: union(fireDetectionGroupRoleAssignments, application.?groupRoleAssignments ?? [])
    hybridConnections: application.?hybridConnections ?? []
    netFrameworkVersion: application.?netFrameworkVersion ?? null
    use32BitWorkerProcess: application.?use32BitWorkerProcess ?? null
  }
}]



// ─ Outputs ─


