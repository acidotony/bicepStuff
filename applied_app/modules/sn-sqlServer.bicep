import * as Types from '../imports/sn-types.bicep'

// Metadata
metadata description = 'This template defines a sql server.' 

// Parameters
@description('The environment to deploy to.')
param environment object

@description('The tags to apply to the resources.')
param tags object

@description('The name of the resource.')
param name string

@secure()
@description('The admin username for the SQL server.')
param adminUsername string

@secure()
@description('The admin password for the SQL server.')
param adminPassword string

@description('The elastic plans to create.')
param elasticPlans Types.ElasticPlan[]

@description('The log analytices workspace id to send audit logs to.')
param logAnalyticsWorkspaceId string?

// Variables
var location = az.resourceGroup().location

// Resources

// Create server
resource sqlServer 'Microsoft.Sql/servers@2024-05-01-preview' = {
  name: name
  location: location
  tags: tags
  properties: {
    administratorLogin: adminUsername
    administratorLoginPassword: adminPassword
    version: '12.0'
    publicNetworkAccess: 'Disabled'
    minimalTlsVersion: '1.2'
    administrators:{
      administratorType: 'ActiveDirectory'
      principalType: 'Group'
      login: 'SelNav-Azure-Db-Admin'
      sid: '384b38cc-3c77-4c43-9418-0dbc9bdc86fa'
      tenantId: az.tenant().tenantId
    }
  }
  identity: {
    type: 'SystemAssigned'
  }
}

// Create a lock on the Sql server
resource sqlServerLock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: sqlServer
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}

// Read the master database
resource masterDatabase 'Microsoft.Sql/servers/databases@2024-05-01-preview' existing = {
  parent: sqlServer
  name: 'master'
}

// Create elastic plan
resource elasticPlan 'Microsoft.Sql/servers/elasticPools@2024-05-01-preview' = [for elasticPlanIndex in range(0, length(elasticPlans)) : {
  parent: sqlServer
  name: 'sep-sn-${environment.name}-${location}-${format('{0:000}', elasticPlanIndex + 1)}'
  location: location
  tags: tags
  sku:{
    name: 'StandardPool'
    tier: 'Standard'
    capacity: elasticPlans[elasticPlanIndex].maxCapacity
  }
  properties: {
    maxSizeBytes: elasticPlans[elasticPlanIndex].maxSizeGB * 1024 * 1024 * 1024
    perDatabaseSettings: {
      minCapacity: 0
      maxCapacity: elasticPlans[elasticPlanIndex].maxDatabaseCapacity
    }
  }
}]

// Create a lock on the elastic plan
resource elasticPlanLock 'Microsoft.Authorization/locks@2020-05-01' = [for elasticPlanIndex in range(0, length(elasticPlans)) : {
  scope: elasticPlan[elasticPlanIndex]
  name: 'DeleteLock'
  properties: {
    level: 'CanNotDelete'
  }
}]

// Create destination for diagnostic audit logging
//resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if(logAnalyticsWorkspaceId != null) {
//  scope: masterDatabase
//  name: 'SQLSecurityAuditEvents'
//  properties: {
//    workspaceId: logAnalyticsWorkspaceId
//    logs: [
//      {
//        category: 'SQLSecurityAuditEvents'
//        enabled: true
//        retentionPolicy: {
//          enabled: false
//          days: 0
//        }
//      }
//      {
//        category: 'SQLInsights'
//        enabled: false
//        retentionPolicy: {
//          enabled: false
//          days: 0
//        }
//      }
//      {
//        category: 'AutomaticTuning'
//        enabled: false
//        retentionPolicy: {
//          enabled: false
//          days: 0
//        }
//      }
//      {
//        category: 'QueryStoreRuntimeStatistics'
//        enabled: false
//        retentionPolicy: {
//          enabled: false
//          days: 0
//        }
//      }
//      {
//        category: 'QueryStoreWaitStatistics'
//        enabled: false
//        retentionPolicy: {
//          enabled: false
//          days: 0
//        }
//      }
//      {
//        category: 'Errors'
//        enabled: false
//        retentionPolicy: {
//          enabled: false
//          days: 0
//        }
//      }
//      {
//        category: 'DatabaseWaitStatistics'
//        enabled: false
//        retentionPolicy: {
//          enabled: false
//          days: 0
//        }
//      }
//      {
//        category: 'Timeouts'
//        enabled: false
//        retentionPolicy: {
//          enabled: false
//          days: 0
//        }
//      }
//      {
//        category: 'Blocks'
//        enabled: false
//        retentionPolicy: {
//          enabled: false
//          days: 0
//        }
//      }
//      {
//        category: 'Deadlocks'
//        enabled: false
//        retentionPolicy: {
//          enabled: false
//          days: 0
//        }
//      }
//      {
//        category: 'DevOpsOperationsAudit'
//        enabled: false
//        retentionPolicy: {
//          enabled: false
//          days: 0
//        }
//      }
//    ]
//    metrics: [
//      {
//        category: 'Basic'
//        enabled: false
//        retentionPolicy: {
//          enabled: false
//          days: 0
//        }
//      }
//      {
//        category: 'InstanceAndAppAdvanced'
//        enabled: false
//        retentionPolicy: {
//          enabled: false
//          days: 0
//        }
//      }
//      {
//        category: 'WorkloadManagement'
//        enabled: false
//        retentionPolicy: {
//          enabled: false
//          days: 0
//        }
//      }
//    ]
//  }
//}

// Auditing settings
resource sqlAuditingSettings 'Microsoft.Sql/servers/auditingSettings@2024-05-01-preview' = if(logAnalyticsWorkspaceId != null) {
  parent: sqlServer
  name: 'default'
  properties: {
    state: 'Enabled'
    isAzureMonitorTargetEnabled: true
    auditActionsAndGroups: [
      'SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP'
      'FAILED_DATABASE_AUTHENTICATION_GROUP'
      'BATCH_COMPLETED_GROUP'
    ]
    isDevopsAuditEnabled: false
    isManagedIdentityInUse: false
    retentionDays: 0
    storageAccountSubscriptionId: '00000000-0000-0000-0000-000000000000'
  }
}

// Outputs
output id string = sqlServer.id
output name string = sqlServer.name
