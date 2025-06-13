// Metadata
metadata description = 'This template createa a hybrid connection.' 

// Parameters
@description('The name of the hybrid connection relay.')
param relayName string

@description('The name of the hybrid connection.')
param name string

@description('The hostname of the hybrid connection.')
param hostName string

@description('The port of the hybrid connection.')
param port int

// Variables


// Resources
resource relayNamespace 'Microsoft.Relay/namespaces@2024-01-01' existing = {
  name: relayName
}

resource hybridConnection 'Microsoft.Relay/namespaces/hybridConnections@2024-01-01' = {
  parent: relayNamespace
  name: name
  properties: {
    requiresClientAuthorization: true
    userMetadata: '[{"key":"endpoint","value":"${hostName}:${port}"}]'
  }
}
