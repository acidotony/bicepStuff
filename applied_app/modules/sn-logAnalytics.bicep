// Metadata
metadata description = 'This template defines a Log Analytics Workspace resource. The scope of this must be set at the time of calling.' 

// Parameters
@description('The tags to apply to the resources.')
param tags object

@description('The name of the resource.')
param name string

@description('The properties of the resource.')
param properties object 

// Variables
var location = az.resourceGroup().location

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: name
  location: location
  properties: properties
  tags: tags
}

output id string = logAnalyticsWorkspace.id
output name string = logAnalyticsWorkspace.name
