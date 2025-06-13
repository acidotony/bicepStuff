import * as Types from '../imports/sn-types.bicep'

// Metadata
metadata description = 'This template defines a sql database.' 

// Parameters
@description('The tags to apply to the resources.')
param tags object

@description('The name of the resource.')
param name string

@description('The name of the sql server.')
param sqlServerName string

@description('The name of the elastic pool to associate with the database.')
param elasticPoolName string?

@description('The compute settings for databases not included in an elastic pool.')
param computeSettings Types.ComputeSettings? // = {name: 'GP_S_Gen5', tier: 'GeneralPurpose', family: 'Gen5', capacity: 1, minCapacity: '0.5', autoPauseDelayMinutes: 60}

@description('The maximum size of the database in GB.')
@minValue(1)
param maxSizeGB int = 1

@description('Collation of the metadata catalog.')
param catalogCollation string = 'SQL_Latin1_General_CP1_CI_AS'

@description('Collation of the database.')
param collation string = 'SQL_Latin1_General_CP1_CI_AS'

// Variables
var location = az.resourceGroup().location

var elasticPoolSku = {
  name: 'ElasticPool'
  tier: 'Standard'
  capacity: 0
}

var computeSku = computeSettings != null ? {
  name: computeSettings.name
  tier: computeSettings.tier
  family: computeSettings.family
  capacity: computeSettings.capacity
} : null

// Resources
resource sqlServer 'Microsoft.Sql/servers@2024-05-01-preview' existing = {
  name: sqlServerName
}

resource elasticPool 'Microsoft.Sql/servers/elasticPools@2024-05-01-preview' existing = if (elasticPoolName != null && computeSettings == null) {
  parent: sqlServer
  name: elasticPoolName ?? ''
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2024-05-01-preview' = {
  parent: sqlServer
  name: name
  location: location
  tags: tags
  sku: (elasticPoolName != null && computeSettings == null) ? elasticPoolSku : computeSku
  properties: {
    maxSizeBytes: maxSizeGB * 1024 * 1024 * 1024 // Convert GB to bytes
    elasticPoolId: computeSettings == null ? elasticPool.id : null
    autoPauseDelay: computeSettings != null ? computeSettings.?autoPauseDelayMinutes : null
    minCapacity: computeSettings != null && computeSettings.?minCapacity != null ? json(computeSettings.minCapacity) : null
    requestedBackupStorageRedundancy: 'Geo'
    catalogCollation: catalogCollation
    collation: collation
    availabilityZone: 'NoPreference'
    zoneRedundant: false
    isLedgerOn: false
    readScale: 'Disabled'
  }
}

// Outputs
output id string = sqlDatabase.id
output name string = sqlDatabase.name
