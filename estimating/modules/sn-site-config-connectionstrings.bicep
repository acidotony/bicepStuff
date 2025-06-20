// Metadata
metadata description = 'This template defines the connection strings for a site, while perserving the existing strings.'

// Parameters
@description('The name of the site.')
param name string

@description('The connection strings to configure.')
param connectionStrings object

@description('The existing connection strings to be overridden, but not lost.')
param existingConnectionStrings object

// Resources

resource site 'Microsoft.Web/sites@2024-04-01' existing = {
  name: name
}

resource siteConfigConnectionStrings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: site
  name: 'connectionstrings'
  properties: union(existingConnectionStrings, connectionStrings)  // Existing connection strings are included first, any new connection strings with matching keys will override them
}
