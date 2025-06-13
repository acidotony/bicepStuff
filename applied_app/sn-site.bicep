import * as Types from '../imports/sn-types.bicep'

// Metadata
metadata description = 'This template defines an azure function.'

// Parameters
@description('The environment to deploy to.')
param environment object

@description('The tags to apply to the resources.')
param tags object

@description('The name of the app.')
param name string?

@description('The application abbreviation, when provided, it will override the name')
param appAbbreviation string?

@description('The app service plan to use.')
param appServicePlanId string

@description('The kind of site to create.')
@allowed([
  'app'
  'app,linux'
  'functionapp'
  'functionapp,linux'
])
param kind string 

@description('The app settings to configure, if a kvSecretName is provided, the value will be ignored.')
param appSettings object = {}

@description('The name of the key vault.')
param keyVaultName string?

@description('The app settings to configure a connection to the key vault.')
param kvAppSettings object

@description('The connection strings to configure, the value will be ignored.')
param connectionStrings object = {}

@description('The sql server name to link databases to.')
param sqlServerName string?

@description('Array of sql database name to create connection strings for.')
param sqlDatabaseNames string[] = []

@description('The log analytics workspace to associate with the application insights resource.')
param logAnalyticsWorkspaceId string

@description('The location of the application insights resource, if not in the standard region.')
param appInsightsLocation string = 'eastus2'

@minValue(1)
@maxValue(50)
@description('The data cap for the application insights resource in GB.')
param appInsightsDataCap int = 1

@description('The subnet id to connect to.')
param subnetId string

@description('The storage account id for function backend storage')
param storageAccountId string = ''

@minValue(0)
@maxValue(20)
@description('The minimum number of instances to run.')
param minimumAppInstances int = 1

@minValue(0)
@maxValue(10)
@description('The number of instances to pre-warm.')
param preWarmedInstanceCount int = 2

@description('Use 32 bit worker process. Default is no-change.')
param use32BitWorkerProcess bool?

@description('The .NET framework version to use. Default is no-change.')
@allowed([
  'v4.8'
  'v6.0'
  'v8.0'
])
param netFrameworkVersion string?

@description('Should existing patterns to match be retained?')
param retainExistingPatternsToMatch bool = true

@description('The custom patterns to match for routing. (ex. "/systemselection/*" )')
param customPatternsToMatch string[] = []

@description('Group role assignments to apply to the site.')
param groupRoleAssignments Types.GroupRoleAssignment[] = []

@description('Names of the hybrid connections to configure.')
param hybridConnections Types.HybridConnection[] = []
<<<<<<< HEAD

@description('The HTTP port for the origin (default 80)')
param afdRouteHttpPort int = 80

@description('The HTTPS port for the origin (default 443)')
param afdRouteHttpsPort int = 443

@description('Origin priority (default 1)')
param afdRoutePriority int = 1

@description('Origin weight (default 1000)')
param afdRouteWeight int = 1000

@description('Private link resource ID, if required')
param afdRoutePrivateLinkResourceId string = ''

@description('Private link location, if required')
param afdRoutePrivateLinkLocation string = ''

@description('Private link group ID (default "blob")')
param afdRoutePrivateLinkGroupId string = 'blob'
=======
>>>>>>> origin/dev

// Variables
var location = az.resourceGroup().location
var existingRoutes = loadJsonContent('../data/sn-route.json')
var relay = loadJsonContent('../data/relay.json')[environment.relay]

var isFunctionApp = startsWith(kind, 'functionapp')
var siteName =  name ?? '${isFunctionApp ? 'fn' : 'app'}-sn-${environment.name}-${appAbbreviation}-${location}'
var siteShortName = name ?? '${isFunctionApp ? 'fn' : 'app'}-${appAbbreviation}'
var appInsightsName =  name ?? toUpper('sn-${environment.name}-${appAbbreviation}')

// Expand key vault settings
var kvAppSettingsExpanded = mapValues(kvAppSettings, value => '@Microsoft.KeyVault(SecretUri=https://${keyVaultName}${az.environment().suffixes.keyvaultDns}/secrets/${value})')

// Create SQL Database connection strings
var sqlConnectionStrings = sqlServerName != null && length(sqlDatabaseNames) > 0 ? toObject(sqlDatabaseNames, sqlDatabaseName => 'DataSource=${sqlServerName}${az.environment().suffixes.sqlServerHostname},1433;Initial Catalog=${sqlDatabaseName};Authentication=Active Directory Managed Identity;Connect Timeout=30;Persist Security Info=False;Encrypt=true;') : {}

// Setup storage account settings for functions
var storageAccountName = last(split(storageAccountId, '/'))
var storageAccountKeyVaultReference = '@Microsoft.KeyVault(SecretUri=https://${keyVaultName}${az.environment().suffixes.keyvaultDns}/secrets/${storageAccountName}-ConnectionString)'
var storageSettings = isFunctionApp ? {
  AzureWebJobsStorage: storageAccountKeyVaultReference
  WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: storageAccountKeyVaultReference
  WEBSITE_CONTENTOVERVNET: '1' // Enable VNet integration for function app
} : {}

// Filter the hybrid connections by environment
var filteredHybridConnections = length(hybridConnections) > 0 ? filter(hybridConnections, hybridConnection => (!contains(hybridConnection, 'filters') || contains(hybridConnection.filters, environment.name))) : []
var linkedHybridConnection = [for hybridConnection in filteredHybridConnections: {
  name: filter(relay.hybridConnections, hc => hc.hostname == hybridConnection.hostname && hc.port == hybridConnection.port)[0].name
  hostname: hybridConnection.hostname
  port: hybridConnection.port
}]


// Resources

// Create Application Insights
module applicationInsightsModule 'sn-applicationInsights.bicep' = {
  scope: az.resourceGroup(environment.applicationInsights.resourceGroup)
  name: 'ApplicationInsights-${appInsightsName}'
  params: {
    name: appInsightsName
    location: appInsightsLocation
    tags: tags
    dataCap: appInsightsDataCap
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
  }
}

// Read the application insights resource group
resource applicationInsights'Microsoft.Insights/components@2020-02-02-preview' existing = {
  scope: az.resourceGroup(environment.applicationInsights.resourceGroup)
  name: appInsightsName
}

// Create site
resource site 'Microsoft.Web/sites@2024-04-01' = {
  name: siteName
  location: location
  tags: tags
  kind: kind
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    enabled: true
    serverFarmId: appServicePlanId
    httpsOnly: true
    virtualNetworkSubnetId: subnetId
    vnetRouteAllEnabled: true
    keyVaultReferenceIdentity: 'SystemAssigned'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: environment.keyVault.name
  scope: az.resourceGroup(environment.keyVault.resourceGroup)
}
resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, site.id, 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId: site.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Read front door resource
resource frontDoor 'Microsoft.Cdn/profiles@2024-09-01' existing = {
  scope: az.resourceGroup(environment.frontDoor.resourceGroup)
  name: environment.frontDoor.name
}
resource frontDoorEndpoint 'Microsoft.Cdn/profiles/afdendpoints@2024-09-01' existing = {
  parent: frontDoor
  name: environment.frontDoor.name
}

// Configure the site
resource siteConfig 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: site
  name: 'web'
  properties: {
    alwaysOn: isFunctionApp ? null : true
    http20Enabled: true   
    ftpsState: 'Disabled'
    minTlsVersion: '1.2'
    minimumElasticInstanceCount: minimumAppInstances
    preWarmedInstanceCount: preWarmedInstanceCount
    use32BitWorkerProcess: use32BitWorkerProcess ?? null
    netFrameworkVersion: netFrameworkVersion ?? null
    webSocketsEnabled: false
    ipSecurityRestrictionsDefaultAction: 'Deny'
    ipSecurityRestrictions: [
      {
        name: 'Allow AzureCloud apps access'
        description: 'Allow access from other Azure cloud apps'
        ipAddress:'AzureCloud'
        action: 'Allow'
        tag: 'ServiceTag'
        priority: 200
      }
      {
        name: 'Allow FrontDoor'
        description: 'Allow access via ${environment.name} front door'
        ipAddress:'AzureFrontDoor.Backend'
        action: 'Allow'
        tag: 'ServiceTag'
        priority: 100
        headers: {
          'x-azure-fdid': [frontDoor.properties.frontDoorId]
        }
      }
      {
        name: 'Deny all'
        description: 'Deny all access'
        ipAddress:'Any'
        action: 'Deny'
        priority: 2147483647
      }
    ]
    scmIpSecurityRestrictionsDefaultAction: 'Allow'
    scmIpSecurityRestrictions: [
      {
        name: 'Allow all'
        description: 'Allow all access'
        ipAddress: 'Any'
        action: 'Allow'
        priority: 2147483647
      }
    ]
  }
}

// Connect hybrid connections
var relayId = az.resourceId(relay.resourceGroup, 'Microsoft.Relay/namespaces', relay.name)
resource hybridConnectionResources 'Microsoft.Web/sites/hybridConnectionNamespaces/relays@2024-04-01' = [for hybridConnection in linkedHybridConnection: {
  name: hybridConnection.name
  dependsOn:[site]
  properties: {
    serviceBusNamespace: relay.name
    relayName: hybridConnection.name
    relayArmUri: '${relayId}/hybridconnections/${hybridConnection.name}'
    hostname: hybridConnection.hostname
    port: hybridConnection.port
  }
}]
  
// Setup application insights app settings
var applicationInsightsSettings = {
  APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsights.properties.ConnectionString  // Preferred value
  APPINSIGHTS_CONNECTIONSTRING: applicationInsights.properties.ConnectionString // Legacy value
  APPINSIGHTS_INSTRUMENTATIONKEY: applicationInsights.properties.InstrumentationKey // Legacy Legacy value
  InstrumentationKey: applicationInsights.properties.InstrumentationKey
  ApplicationInsightsAgent_EXTENSION_VERSION: '~2'
  //APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'  // Future for authenticated insights ingestion, https://learn.microsoft.com/en-us/azure/azure-monitor/app/azure-ad-authentication?tabs=net
}
 
// Read the existing app settings
var existingAppSettings = list(az.resourceId('Microsoft.Web/sites/config', site.name, 'appsettings'), site.apiVersion).properties

module siteConfigAppSettingsModule './sn-site-config-appsettings.bicep' = if (length(kvAppSettings) > 0) {
  name: take('AppSettings-${siteName}',64)
  params: {
    name: site.name
    appSettings: union(appSettings, applicationInsightsSettings, storageSettings, kvAppSettingsExpanded)
    existingAppSettings: existingAppSettings
  }
}

// Read the existing connection strings
var existingConnectionStrings = list(az.resourceId('Microsoft.Web/sites/config', site.name, 'connectionstrings'), site.apiVersion).properties

module siteConfigConnectionStringsModule './sn-site-config-connectionstrings.bicep' = if (length(kvAppSettings) > 0) {
  name: take('ConnectionStrings-${siteName}',64)
  params: {
    name: site.name
    connectionStrings: union(connectionStrings, sqlConnectionStrings)
    existingConnectionStrings: existingConnectionStrings
  }
}

// Check if the route exists, if so read the existing patterns to match
var routeExists = contains(existingRoutes, siteShortName)

resource existingRoute 'Microsoft.Cdn/profiles/afdendpoints/routes@2024-09-01' existing = if (routeExists) {
  parent: frontDoorEndpoint
  name: siteShortName
}

var existingPatternsToMatch = retainExistingPatternsToMatch && routeExists ? existingRoute.properties.patternsToMatch : []

// Create Origin
module originGroupModule './sn-frontDoor-originGroup.bicep' = {
  scope: az.resourceGroup(environment.frontDoor.resourceGroup)
  name: take('FrontDoorOriginGroup-${siteShortName}',64)
  params: {
    environment: environment
    originGroupName: siteShortName

  }
}

module originModule './sn-frontDoor-origin.bicep' = {
  scope: resourceGroup(environment.frontDoor.resourceGroup)
  name: take('FrontDoorOrigin-${siteShortName}',64)
  params: {
    hostName: '${siteName}.azurewebsites.net'
    profileName: environment.frontDoor.name                     
    originGroupName: siteShortName                             
    originName: siteName                                      
    originHostHeader: '${siteName}.azurewebsites.net'
    httpPort: afdRouteHttpPort
    httpsPort: afdRouteHttpsPort
    priority: afdRoutePriority
    weight: afdRouteWeight
    enabledState: 'Enabled'
    privateLinkResourceId: afdRoutePrivateLinkResourceId
    privateLinkLocation: afdRoutePrivateLinkLocation
    privateLinkGroupId: afdRoutePrivateLinkGroupId
  }
}

module routeModule './sn-frontDoor-route.bicep' = {
  scope: resourceGroup(environment.frontDoor.resourceGroup)
  name: 'FrontDoorRoute-${siteShortName}'
  params: {
    environment: environment
    routeName: siteShortName
    originGroupName: originGroupModule.outputs.name 
    patternsToMatch: [
      '/${siteShortName}/*'
    ]
    customDomainNames: [
      environment.frontDoor.domain
    ]
    ruleSetNames: [
      'DefaultRules'
    ]
  }
}


// Associate the group roles to the site
module roleAssignmentModule './sn-site-roleAssignment.bicep' = {
  name: take('RoleAssignment-${siteName}',64)
  params: {
    environment: environment
    resourceId: site.id
    groupRoleAssignments: groupRoleAssignments
  }
}

// Outputs
output id string = site.id
output name string = site.name
