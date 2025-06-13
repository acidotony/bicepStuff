// ======================================================================
//  sn-fireDetection.bicep  — Fire Detection workload deployment
// ======================================================================

// ───────────── Imports ─────────────
import * as Functions from '../imports/sn-functions.bicep'

// ═════════════ Scope ═══════════════
targetScope = 'resourceGroup'

// ─────────────────────────── Parameters ───────────────────────────
@description('Deployment environment code: dev, qa, test, prod, …')
param environmentName string

@description('Tags to apply to all resources.')
param tags object

// Optional overrides ─── leave value empty ("") to use whatever is in test-environment.json
@description('Storage account name – leave blank to use value from environment file.')
param storageAccountName string = ''

@description('Key Vault name – leave blank to use value from environment file.')
param keyVaultName string = ''

@description('SQL logical server name – leave blank to use value from environment file.')
param sqlServerName string = ''

@description('Log Analytics workspace name – leave blank to use value from environment file.')
param logAnalyticsWorkspaceName string = ''

// SQL admin credentials
@secure() 
param sqlAdminUsername string
@secure() 
param sqlAdminPassword string

// ─────────────────────────── JSON Manifests ───────────────────────────
var applications      = loadJsonContent('../data/sn-application.json')
var kvAppGlobalJson   = loadJsonContent('../data/sn-kvAppSettings.json')
var sqlDatabasesJson  = loadJsonContent('../data/sn-sqldatabase.json')
var environment       = loadJsonContent('../data/environment-test.json')['sn-${environmentName}']
var location          = resourceGroup().location

// ─────────────────────────── Derived names (with override support) ───────────────────────────
var storageAccountNameFinal = empty(storageAccountName)
  ? environment.securityStorageAccount.name
  : storageAccountName

var keyVaultNameFinal = empty(keyVaultName)
  ? environment.keyVault.name
  : keyVaultName

var logAnalyticsWorkspaceNameFinal = empty(logAnalyticsWorkspaceName)
  ? environment.logAnalyticsWorkspace
  : logAnalyticsWorkspaceName

// Provide a sensible default if it’s missing from the env-file and not overridden
var sqlServerNameFinal = empty(sqlServerName)
  ? (contains(environment, 'sqlServerName')
        ? environment.sqlServerName
        : 'sql-sn-${environment.name}001')
  : sqlServerName



// Convenience
var groupName          = 'Fire Detection'
var envCode            = toLower(environment.name)
var virtualNetworkName = 'vnet-sn-${environment.name}-${location}'

// ─────────────────────────── Global KV app settings ───────────────────────────
var globalKvAppSettings = union(
  kvAppGlobalJson.v2Security,
  kvAppGlobalJson.launchDarkly
)

// ─────────────────────────── Filter Fire-Detection apps for this region ────────
var fireApps = [
  for a in applications:  (contains(a, 'group') && a.group == groupName &&   contains(a, 'locations') && contains(a.locations, location)) ? {
      name:     a.name
      abbr:     a.abbr
      type:     a.type
      aspIndex: a.aspIndex
      hybridConnections:  contains(a, 'hybridConnections') ? a.hybridConnections  : []
  } : null
]

// SQL DBs for this region & workload
var filteredSqlDatabases = filter(  sqlDatabasesJson,  db => ((!contains(db, 'locations') || contains(db.locations, location)) && (contains(db, 'group') && db.group == groupName))
)
var sqlDatabaseNameList = [ for db in filteredSqlDatabases: db.databaseName ]

// ─────────────────────────── Plans (existing) ───────────────────────────
resource aspPlanExisting 'Microsoft.Web/serverfarms@2024-04-01' existing = {
  name: 'asp-sn-${environment.name}-${location}-003'
}

// 2. If it doesn’t exist, deploy it via your module
module aspPlanMod '../modules/sn-appServiceplan.bicep' = if (aspPlanExisting.name == '') {
  name: 'deploy-asp-sn-${environment.name}-${location}-003'
  params: {
    appServicePlanName: 'asp-sn-${environment.name}-${location}-003'
    location:           location
    tags:               tags
    skuName:            'EP2'
    skuTier:            'ElasticPremium'
    capacity:           1
    maximumElasticWorkerCount: 5
    perSiteScaling:     false
    kind:               'elastic'
  }
}

var aspPlanId           = empty(aspPlanExisting.name) ? aspPlanMod.outputs.appServicePlanId        : aspPlanExisting.id
var aspPlanSkuCapacity  = empty(aspPlanExisting.name) ? aspPlanMod.outputs.appServicePlanSkuCapacity : aspPlanExisting.sku.capacity


resource fnPlanExisting 'Microsoft.Web/serverfarms@2024-04-01' existing = {
  name: 'asp-sn-${environment.name}-${location}-fn-004'
}

module fnPlanMod '../modules/sn-appServiceplan.bicep' = if (fnPlanExisting.name == '')  {
  name: 'deploy-asp-sn-${environment.name}-${location}-fn-004'
  params: {
    appServicePlanName:        'asp-sn-${environment.name}-${location}-fn-004'
    location:                  location
    tags:                      tags
    skuName:                   'EP2'
    skuTier:                   'ElasticPremium'
    capacity:                  1
    maximumElasticWorkerCount: 5
    perSiteScaling:            false
    kind:                      'functionapp'
  }
}

var fnPlanId          = empty(fnPlanExisting.name) ? fnPlanMod.outputs.appServicePlanId        : fnPlanExisting.id
var fnPlanSkuCapacity = empty(fnPlanExisting.name) ? fnPlanMod.outputs.appServicePlanSkuCapacity : fnPlanExisting.sku.capacity


// ─────────────────────────── Core Resources ───────────────────────────
resource saExisting 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountNameFinal
}

module saModule '../modules/sn-storageAccount.bicep' = if (storageAccountNameFinal != '')  {
  name: storageAccountName
  params: {
    environment: { name: environmentName }
    tags:        tags
    name:        storageAccountName
  }
}
var storageAccountId = empty(saExisting.name) ? saModule.outputs.id : saExisting.id

// Log Analytics
resource laExisting 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: logAnalyticsWorkspaceNameFinal
}

module laModule '../modules/sn-logAnalytics.bicep' = if (logAnalyticsWorkspaceNameFinal != '') {
  name: logAnalyticsWorkspaceNameFinal
  params: {
    name:     logAnalyticsWorkspaceNameFinal
    location: location
    tags:     tags
  }
}
var logAnalyticsWorkspaceId = (logAnalyticsWorkspaceNameFinal != '') ? laModule.outputs.logAnalyticsWorkspaceId : laExisting.id

// Key Vault
resource kvExisting 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultNameFinal
}

module kvModule '../modules/sn-keyVault-secret.bicep' = if (empty(kvExisting.name)) {
  name: keyVaultNameFinal
  params: {
    keyVaultName: keyVaultNameFinal
    tags:         tags
  }
}

// SQL Server
resource sqlSrvExisting 'Microsoft.Sql/servers@2023-08-01' existing = {
  name: sqlServerNameFinal
}

module sqlServerModule '../modules/sn-sqlServer.bicep' = if (sqlServerNameFinal != '')  {
  name: 'sn-fd-sql-${envCode}'
  params: {
    environment:             { name: environmentName }
    tags:                    tags
    name:                    sqlServerNameFinal
    adminUsername:           sqlAdminUsername
    adminPassword:           sqlAdminPassword
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    elasticPlans:            []
  }
}

// ─────────────────────────── SQL Databases ───────────────────────────
resource sqlDbExisting 'Microsoft.Sql/servers/databases@2023-08-01' existing = [
  for db in filteredSqlDatabases: {
    parent: sqlSrvExisting
    name:   db.databaseName
  }
]

module sqlDatabasesModule '../modules/sn-sqlDatabase.bicep' = [
  for (db, idx) in filteredSqlDatabases: if (empty(sqlDbExisting[idx].name)) {
    name: take('SqlDatabase-${db.databaseName}', 64)
    params: {
      name:          db.databaseName
      tags:          tags
      sqlServerName: sqlServerNameFinal
      computeSettings: db.?computeSettings
      maxSizeGB:       int(Functions.P(environment.name, '1', union(db.?maxSizeGB ?? [], ['prod:10'])))
    }
  }
]

// ─────────────────────────── Application Deployment ───────────────────────────
module sites '../modules/sn-site.bicep' = [
  for app in fireApps: if (app != null) {
    name: take('Site-${toLower(app!.abbr)}', 64)
    params: {
      // Basics
      environment:             environment
      tags:                    tags
      name:                    'app-sn-${envCode}-${app!.abbr}'
      appAbbreviation:         app!.abbr
      kind:                    app!.type

      // Plan & network
      appServicePlanId:     startsWith(app!.type, 'function') ? fnPlanId        : aspPlanId

      subnetId: az.resourceId(
        'Microsoft.Network/virtualNetworks/subnets',
        virtualNetworkName,
        'asp-sn-${environment.name}-${location}${startsWith(app!.type, 'function') ? '-fn' : ''}-${format('{0:000}', app!.aspIndex)}'
      )
      hybridConnections: app!.hybridConnections
      // KV & settings
      kvAppSettings:            globalKvAppSettings
      keyVaultName:             keyVaultNameFinal

      // Monitoring
      logAnalyticsWorkspaceId:  logAnalyticsWorkspaceId

      // Data
      storageAccountId:         storageAccountId
      sqlServerName:            sqlServerNameFinal
      sqlDatabaseNames:         sqlDatabaseNameList

      // Scaling
      minimumAppInstances:  startsWith(app!.type, 'function') ? fnPlanSkuCapacity : aspPlanSkuCapacity
    }
  }
]

// ─────────────────────────── Outputs ───────────────────────────
output deployedAppNames array = [
  for app in fireApps: (app != null) ? 'app-sn-${envCode}-${app!.abbr}' : null
]

output sqlDatabaseNames      array  = sqlDatabaseNameList
output logAnalyticsId        string = logAnalyticsWorkspaceId
output storageAccountId      string = storageAccountId
output sqlServerNameResolved string = sqlServerNameFinal
output keyVaultNameResolved  string = keyVaultNameFinal
