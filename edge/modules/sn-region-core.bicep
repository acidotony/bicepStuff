import * as sn from '../imports/sn-functions.bicep'

// Metadata
metadata description = 'This template defines the Selection Navigator regional resources for Core applications.'

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
    appInsightsDataCap: int(sn.P(environment.name, '1', union(application.?appInsightsDataCap ?? [], ['prod:10'])))
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
    sqlServerName: 'sn-${environment.name}-sql-${format('{0:000}', sn.ResourceGroupIndex(az.resourceGroup().name))}'
    elasticPoolName: sqlDatabase.?elasticPoolIndex != null ? 'sep-sn-${environment.name}-${location}-${format('{0:000}', sqlDatabase.?elasticPoolIndex)}' : 'sep-sn-${environment.name}-${location}-${format('{0:000}', 1)}'
    computeSettings: sqlDatabase.?computeSettings
    maxSizeGB: int(sn.P(environment.name, '1', union(sqlDatabase.?maxSizeGB ?? [], ['prod:10'])))
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

// ITA/ITBP
var itaSiteName = 'app-sn-${environment.name}-ita-${location}'
module itaAppSettingsModule './sn-site-config-appsettings.bicep' =  {
  name: take('AppSettings-${itaSiteName}',64)
  params: {
    name: itaSiteName
    appSettings: {'ConnectionStrings:AzureWebJobsStorage': '@Microsoft.KeyVault(SecretUri=https://${environment.keyVault.name}.vault.azure.net/secrets/stsn${environment.name}${location}-ConnectionString)'}
    existingAppSettings: list(az.resourceId('Microsoft.Web/sites/config', itaSiteName, 'appsettings'), 'Microsoft.Web/sites@2024-04-01').properties
  }
}

// ToDo: Connect item storage accounts from other regions

// Item Storage Account Access
var itemStorageAccountName = 'stsn${environment.name}item${location}'
module itemStorageAccountAccessModule 'sn-storageAccount-roleAssignment.bicep' = {
  name: take('RoleAssignment-${itemStorageAccountName}',64)
  params: {
    environment: environment
    resourceId: az.resourceId('Microsoft.Storage/storageAccounts', itemStorageAccountName)
    siteRoleAssignments: [
      { site: 'ita', roles: ['Storage Blob Data Contributor'], appSettingName: 'ItemDataAccess:BlobUrl:${location}' }
      { site: 'ea', roles: ['Storage Blob Data Contributor'], appSettingName: 'ItemDataAccess:BlobUrl:${location}' }
      { site: 'itbp', roles: ['Storage Blob Data Owner'], appSettingName: 'ItemDataAccess:BlobUrl:${location}' }
    ]
    groupRoleAssignments: coreGroupRoleAssignments
  }
}

// Shared Service Bus Queue Access
// Group Role Assignments
var sharedServiceBusGroupQueueAccess = []
var sharedServiceBusGroupQueueAccessByQueue = [for assignment in sharedServiceBusGroupQueueAccess: map(assignment.queues, queue => {
  group: assignment.group
  roles: assignment.roles
  queue: queue
  filters: assignment.filters
})]
var sharedServiceBusGroupQueueAccessByQueueFlattened = flatten(sharedServiceBusGroupQueueAccessByQueue)
var sharedServiceBusGroupQueueNames = [for assignment in sharedServiceBusGroupQueueAccessByQueueFlattened: assignment.queue]

// Site Role Assignments
var sharedServiceBusSiteQueueAccess = [
  { site: 'ita', roles: ['Azure Service Bus Data Sender'], queues:['backup-item-delete','backup-itemdetail-delete','backup-itemrelationship-delete'], filters: [] }
  { site: 'itbp', roles: ['Azure Service Bus Data Receiver','Azure Service Bus Data Sender'], queues:['backup-item-delete','backup-itemdetail-delete','backup-itemrelationship-delete'], filters: [] }
]
var sharedServiceBusSiteQueueAccessByQueue = [for assignment in sharedServiceBusSiteQueueAccess: map(assignment.queues, queue => {
  site: assignment.site
  roles: assignment.roles
  queue: queue
  filters: assignment.filters
})]
var sharedServiceBusSiteQueueAccessByQueueFlattened = flatten(sharedServiceBusSiteQueueAccessByQueue)
var sharedServiceBusSiteQueueNames = [for assignment in sharedServiceBusSiteQueueAccessByQueueFlattened: assignment.queue]

var sharedServiceBusQueues = union([], sharedServiceBusGroupQueueNames, sharedServiceBusSiteQueueNames)
var sharedServiceBusName = 'sb-sn-${environment.name}-shared-${location}'
module sharedServiceBusQueueAccessModule 'sn-serviceBus-queue-roleAssignment.bicep' = [for sharedServiceBusQueue in sharedServiceBusQueues : {
  name: take('RoleAssignment-${sharedServiceBusName}_${sharedServiceBusQueue}',64)
  params: {
    environment: environment
    resourceId: az.resourceId('Microsoft.ServiceBus/namespaces', sharedServiceBusName)
    childResourceName: sharedServiceBusQueue
    groupRoleAssignments: filter(sharedServiceBusGroupQueueAccessByQueueFlattened, assignment => assignment.queue == sharedServiceBusQueue)
    siteRoleAssignments: filter(sharedServiceBusSiteQueueAccessByQueueFlattened, assignment => assignment.queue == sharedServiceBusQueue)
  }
}]

// Shared Service Bus Topic Access
// Group Role Assignments
var sharedServiceBusGroupTopicAccess = []
var sharedServiceBusGroupTopicAccessByQueue = [for assignment in sharedServiceBusGroupTopicAccess: map(assignment.topics, topic => {
  group: assignment.group
  roles: assignment.roles
  topic: topic
  filters: assignment.filters
})]
var sharedServiceBusGroupQueueAccessByTopicFlattened = flatten(sharedServiceBusGroupTopicAccessByQueue)
var sharedServiceBusGroupTopicNames = [for assignment in sharedServiceBusGroupQueueAccessByTopicFlattened: assignment.topic]

// Site Role Assignments
var sharedServiceBusSiteTopicAccess = [
  { site: 'ita', roles: ['Azure Service Bus Data Sender'], topics:['create','update','delete','resequence'], filters: [] }
  { site: 'itbp', roles: ['Azure Service Bus Data Receiver','Azure Service Bus Data Sender'], topics:['create','update','delete','resequence'], filters: [] }
]
var sharedServiceBusSiteTopicAccessByTopic = [for assignment in sharedServiceBusSiteTopicAccess: map(assignment.topics, topic => {
  site: assignment.site
  roles: assignment.roles
  topic: topic
  filters: assignment.filters
})]
var sharedServiceBusSiteTopicAccessByTopicFlattened = flatten(sharedServiceBusSiteTopicAccessByTopic)
var sharedServiceBusSiteTopicNames = [for assignment in sharedServiceBusSiteTopicAccessByTopicFlattened: assignment.topic]

var sharedServiceBusTopics = union([], sharedServiceBusGroupTopicNames, sharedServiceBusSiteTopicNames)

module sharedServiceBusTopicAccessModule 'sn-serviceBus-topic-roleAssignment.bicep' = [for sharedServiceBusTopic in sharedServiceBusTopics : {
  name: take('RoleAssignment-${sharedServiceBusName}_${sharedServiceBusTopic}',64)
  params: {
    environment: environment
    resourceId: az.resourceId('Microsoft.ServiceBus/namespaces', sharedServiceBusName)
    childResourceName: sharedServiceBusTopic
    groupRoleAssignments: filter(sharedServiceBusGroupQueueAccessByTopicFlattened, assignment => assignment.topic == sharedServiceBusTopic)
    siteRoleAssignments: filter(sharedServiceBusSiteTopicAccessByTopicFlattened, assignment => assignment.topic == sharedServiceBusTopic)
  }
}]
