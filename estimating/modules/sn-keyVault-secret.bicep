// Metadata
metadata description = 'This template defines a key vault secret.  The scope of this must be set at the time of calling.' 

// Parameters
@description('The name of the key vault secret parent.')
param keyVaultName string

@description('The name of the key vault secret.')
param name string

@description('The value of the key vault secret.')
param value string

// Resources

// Read the keyvault
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName
}

// Set the connection string in the key vault
resource keyVaultSecret 'Microsoft.KeyVault/vaults/secrets@2021-06-01-preview' = {
  parent: keyVault
  name: name
  properties: {
    value: value
  }
}

// Output
output id string = keyVaultSecret.id
output name string = keyVaultSecret.name
