// Metadata
metadata description = 'This template defines an application insights resource.' 

// Parameters
@description('The name of the key vault secret.')
param name string

@description('The location to deploy to.')
param location string = 'eastus2'

@description('The tags to apply to the resources.')
param tags object

@minValue(1)
@maxValue(50)
@description('The data cap for the application insights resource in GB.')
param dataCap int = 1

@description('The log analytics workspace to associate with the application insights resource.')
param logAnalyticsWorkspaceId string

// Resources

// Create Application Insights
resource applicationInsights 'Microsoft.Insights/components@2020-02-02-preview' = {
  name: name
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Flow_Type: 'Bluefield'
    Request_Source: 'rest'
    IngestionMode: 'LogAnalytics'
    WorkspaceResourceId: logAnalyticsWorkspaceId
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource applicationInsightsPricingPlans 'Microsoft.Insights/components/pricingPlans@2017-10-01' = {
  parent: applicationInsights
  name: 'current'
  properties: {
    cap: dataCap
    planType: 'Basic'
    stopSendNotificationWhenHitCap: true
    stopSendNotificationWhenHitThreshold: true
    warningThreshold: 90
  }
}

// Output
output id string = applicationInsights.id
output name string = applicationInsights.name
