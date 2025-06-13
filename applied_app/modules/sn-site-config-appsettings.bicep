// Metadata
metadata description = 'This template defines the app settings for a site, while perserving the existing settings.'

// Parameters
@description('The name of the function app.')
param name string

@description('The app settings to configure.')
param appSettings object

@description('The existing app settings to be overridden, but not lost.')
param existingAppSettings object

// Resources

resource site 'Microsoft.Web/sites@2024-04-01' existing = {
  name: name
}

resource siteConfigAppSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: site
  name: 'appsettings'
  properties: union(existingAppSettings, appSettings)  // Existing setting are included first, any new settings with matching keys will override them
}
