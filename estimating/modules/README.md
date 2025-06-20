
# Module Directory

This directory contains bicep modules used to define Selection Navigator Azure resources.

## Intermediate Modules

Modules referenced by Top-Level modules for creating categorized groups of resources.

### Regional intermediate modules

#### `sn-region-core.bicep`
- **Description**: Deploys core infrastructure components for a region, including resource groups, network foundations, and shared services.
- **Parameters**: See module for parameter definitions.
- **Resources**: Defines core networking, resource groups, and foundational resources for regional deployments.
- **Outputs**: None.

#### `sn-region-shared.bicep`
- **Description**: Deploys shared resources for a region, such as shared storage accounts, DNS configurations, and common networking.
- **Parameters**: See module for parameter definitions.
- **Resources**: Defines shared storage, DNS zones, and other common resources consumed by multiple sub-modules.
- **Outputs**: None.

#### `sn-region-ahu.bicep`
- **Description**: Deploys Air Handling Unit (AHU) group resources for a region, including application deployments and related infrastructure.
- **Parameters**: See module for parameter definitions.
- **Resources**: Deploys AHU-specific applications, databases, and networking components.
- **Outputs**: None.

#### `sn-region-applied.bicep`
- **Description**:  
  Deploys all regional resources required for **AppliedDX** applications in Selection Navigator.  
  This module:
  - Loads environment-specific settings (tags, location, Log Analytics workspace, etc.) from JSON lookups.
  - Filters and deploys only the AppliedDX–grouped SQL databases and web/function apps for the current region.
  - Wires in shared storage account and network/subnet references.
  - Applies runtime app settings.
  - Assigns RBAC roles for the AppliedDX group and any application-specific overrides.

- **Parameters**:

| Name                      | Type      | Description                                                                                                                                                      | Default | Allowed Values                         |
|---------------------------|-----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------|----------------------------------------|
| `environmentName`         | string    | The environment to deploy to.                                                                                                                                     | `dev2`  | `dev2`, `dev`, `qa`, `sit`, `ppe`, `prod` |
| `tags`                    | object    | Tags to apply to all deployed resources.                                                                                                                         |         |                                        |
| `sharedStorageAccountName`| string?   | The name of an existing, shared storage account. If omitted, a default name is generated (e.g., `stsn<env><location>`).                                          |         |                                        |

- **Variables**:

| Name                         | Definition                                                                                                                                                                                                                                   | Description                                                                                          |
|------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| `environment`                | `loadJsonContent('../data/environment.json')['sn-${environmentName}']`                                                                                                                                      | Loads environment settings (subscription IDs, service principal IDs, Key Vault names, etc.)          |
| `location`                   | `az.resourceGroup().location`                                                                                                                                                                               | Uses the resource group’s location for all regional deployments.                                     |
| `logAnalyticsWorkspaces`     | `loadJsonContent('../data/logAnalyticsWorkspace.json')`                                                                                                                                                    | Loads Log Analytics workspace names and RGs per environment.                                         |
| `applications`               | `loadJsonContent('../data/sn-application.json')`                                                                                                                                                           | Reads the full list of Selection Navigator applications; used for filtering AppliedDX apps.          |
| `sqlDatabases`               | `loadJsonContent('../data/sn-sqldatabase.json')`                                                                                                                                                           | Reads the full list of SQL database definitions; used for filtering AppliedDX databases.             |
| `kvAppSettings`              | `loadJsonContent('../data/sn-kvAppSettings.json')`                                                                                                                                                         | Loads Key Vault–related app settings (e.g., secrets scopes, labels).                                 |
| `virtualNetworkIndexSuffix`  | `1`                                                                                                                                                                                                        | Numeric suffix for building the VNet name (always “001” for AppliedDX).                              |
| `virtualNetworkName`         | ``vnet-sn-${environment.name}-${location}-${format('{0:000}', virtualNetworkIndexSuffix)}``                                                                                                                | Constructs the regional VNet name, e.g., `vnet-sn-prod-eastus2-001`.                                 |
| `sharedStorageAccountNameValue` | `sharedStorageAccountName ?? 'stsn${environment.name}${location}'`                                                                                                                                      | Uses the provided shared storage account or generates a default name if none is passed.              |
| `appliedGroupRoleAssignments` | `[ { group: 'SelNav-Azure-AppDev-AppliedDX', roles: ['Contributor'], filters: ['dev2','dev','qa'] } ]`                                                                                                   | Default RBAC assignment for the AppliedDX group across non-production environments.                  |
| `groupName`                  | `'AppliedDX'`                                                                                                                                                                                             | Application group targeted by this module.                                                           |
| `filteredApplications`       | `filter(applications, application => (!contains(application, 'locations') || contains(application.locations, location)) && (contains(application, 'group') && application.group == groupName))`           | List of AppliedDX applications relevant to this region/location.                                     |
| `filteredSqlDatabases`       | `filter(sqlDatabases, sqlDatabase => (!contains(sqlDatabase, 'locations') || contains(sqlDatabase.locations, location)) && (contains(sqlDatabase, 'group') && sqlDatabase.group == groupName))`           | List of AppliedDX SQL databases relevant to this region/location.                                    |

- **Modules and Resources**:

| Name                      | Type / Module Path                                 | Description                                                                                                                                                                                                                                                                                                                                                     |
|---------------------------|----------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `appServicePlans`         | `resource Microsoft.Web/serverfarms@2024-04-01 existing` (array)  | References up to 9 existing App Service Plans named `asp-sn-<env>-<location>-<index>` (for hosting web apps).                                                                                                                                                                                                                                                 |
| `functionAppServicePlans` | `resource Microsoft.Web/serverfarms@2024-04-01 existing` (array)  | References up to 9 existing Function App Service Plans named `asp-sn-<env>-<location>-fn-<index>`.                                                                                                                                                                                                                                                            |
| `sharedStorageAccount`    | `resource Microsoft.Storage/storageAccounts@2023-01-01 existing`   | References the existing shared storage account (either passed in or default-generated).                                                                                                                                                                                                                                                                         |
| `sqlDatabasesModule`      | `module '../modules/sn-sqlDatabase.bicep'`          | Iterates over each item in `filteredSqlDatabases`, and for each:  
  • Names the SQL DB `SqlDatabase-<databaseName>` (up to 64 chars).  
  • Passes `tags`, `name`, `sqlServerName` (built from `environment.name` and RG index), optional `elasticPoolName`, optional `catalogCollation`/`collation`.  
  Deploys all region-specific AppliedDX SQL DBs. |
| `applicationsModule`       | `module './sn-site.bicep'`                          | Iterates over each item in `filteredApplications`, and for each:  
  • Generates a unique site name via `sn.CreateSiteName(environment.name, location, application.type, application.abbr)`.  
  • Passes `environment`, `tags`, `appAbbreviation`, `kind` (app or function), `appServicePlanId` or `functionAppServicePlanId`, merged `appSettings`, `keyVaultName`, `kvAppSettings` (merged), `logAnalyticsWorkspaceId`, `appInsightsDataCap` (via `P()` function), `subnetId`, `minimumAppInstances`, `storageAccountId`, `groupRoleAssignments` (merged with application overrides), optional `hybridConnections`, `netFrameworkVersion`, `use32BitWorkerProcess`.  
  Deploys all AppliedDX-grouped web or function apps. |

- **Outputs**:  
  This module does not emit any outputs directly. All child modules (`sn-sqlDatabase.bicep` and `sn-site.bicep`) handle their own outputs.


#### `sn-region-chillers.bicep`
- **Description**: Deploys all Chillers group resources for a region, including applications, SQL databases, and Event Hubs, with associated networking, storage, and RBAC.
- **Parameters**:

| Name                      | Type      | Description                                                                                 |
|---------------------------|-----------|---------------------------------------------------------------------------------------------|
| `environment`             | object    | The environment to deploy to.                                                               |
| `tags`                    | object    | The tags to apply to the resources.                                                         |
| `virtualNetworkName`      | string?   | The name of the virtual network resource (optional).                                        |
| `sharedStorageAccountName`| string?   | The name of the shared storage account resource (optional).                                 |

- **Resources**:

| Name                   | Description                                                     |
|------------------------|-----------------------------------------------------------------|
| `appServicePlans`      | References existing App Service Plans for the region.           |
| `functionAppServicePlans` | References existing Function App Service Plans for the region. |
| `applicationsModule`   | Deploys all Chillers applications as sites.                     |
| `sqlDatabasesModule`   | Deploys all Chillers SQL databases.                              |
| `chillersEventHubs`    | Deploys Event Hubs for Chillers workloads.                       |

- **Outputs**: None.

#### `sn-region-controls.bicep`
- **Description**: Deploys Controls group resources for a region, including application services, databases, and event hubs.
- **Parameters**: See module for parameter definitions.
- **Resources**: Defines Controls applications, SQL databases, and event hubs for the region.
- **Outputs**: None.

#### `sn-region-documentGenerator.bicep`
- **Description**:  
  Deploys all regional resources required for **Document Generation** applications in Selection Navigator.  
  This module:
  - Loads environment-specific settings (tags, location, Log Analytics workspace, etc.) from JSON lookups.
  - Filters and deploys only the Document Generation–grouped SQL databases and web/function apps for the current region.
  - Wires in shared storage account and network/subnet references.
  - Applies runtime app settings.
  - Assigns RBAC roles for the Document Generation group and any application-specific overrides.

- **Parameters**:

| Name                      | Type      | Description                                                                                                                                                      | Default | Allowed Values                         |
|---------------------------|-----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------|----------------------------------------|
| `environmentName`         | string    | The environment to deploy to.                                                                                                                                     | `dev2`  | `dev2`, `dev`, `qa`, `sit`, `ppe`, `prod` |
| `tags`                    | object    | Tags to apply to all deployed resources.                                                                                                                         |         |                                        |
| `sharedStorageAccountName`| string?   | The name of an existing, shared storage account. If omitted, a default name is generated with date suffix (e.g., `stsn<env><location>03062025`).                 |         |                                        |

- **Variables**:

| Name                         | Description                                                                                          |
|------------------------------|------------------------------------------------------------------------------------------------------|
| `environment`                | Loads environment-specific settings from `environment.json`.                         |
| `location`                   | Uses the current resource group's location.                                                          |
| `logAnalyticsWorkspaces`     | Loads Log Analytics workspace info from `logAnalyticsWorkspace.json`.                 |
| `applications`               | Filters `sn-application.json` for Document Generation apps in the region.                            |
| `sqlDatabases`               | Filters `sn-sqldatabase.json` for Document Generation DBs in the region.                             |
| `kvAppSettings`              | Merges security and LaunchDarkly Key Vault settings with app-specific entries.                      |
| `virtualNetworkName`         | Constructed as `vnet-sn-<env>-<location>-001`.                                                       |
| `sharedStorageAccountNameValue` | Resolved shared storage account name, using date-based suffix if not provided.                       |
| `documentGeneratorGroupRoleAssignments` | Assigns default Contributor role to SysControls group in non-prod environments.             |

- **Modules and Resources**:

| Name                      | Type / Module Path                                 | Description                                                                                                                                                           |
|---------------------------|----------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `appServicePlans`         | `Microsoft.Web/serverfarms@2024-04-01` (existing)  | References up to 9 App Service Plans per region.                                                                                                                      |
| `functionAppServicePlans` | `Microsoft.Web/serverfarms@2024-04-01` (existing)  | References up to 9 Function App Service Plans per region.                                                                                                             |
| `sharedStorageAccount`    | `Microsoft.Storage/storageAccounts@2023-01-01` (existing) | References an existing shared storage account.                                                                                                                  |
| `sqlDatabasesModule`      | `module '../modules/sn-sqlDatabase.bicep'`         | Iterates over filtered Document Generation SQL DBs, setting name, server, pool, and collation.                                                                       |
| `applicationsModule`      | `module './sn-site.bicep'`                         | Iterates over filtered Document Generation apps, deploying each with site-specific and environment-specific parameters including VNet, Key Vault, and AFD integration. |

- **Outputs**:  
  This module does not emit any outputs directly. Child modules handle their own outputs.

#### `sn-region-edge.bicep`

- **Description**:  
  Deploys all regional resources required for **Edge** applications in Selection Navigator.  
  This module:
  - Loads environment-specific settings (tags, location, Log Analytics workspace, etc.) from JSON lookups.
  - Filters and deploys only the Edge–grouped SQL databases and web/function apps for the current region.
  - Wires in shared storage account and network/subnet references.
  - Applies runtime app settings and Key Vault app settings.
  - Assigns RBAC roles for the Edge group and any application-specific overrides.

- **Parameters**:

| Name                      | Type      | Description                                                                                                                                                       | Default | Allowed Values                            |
|---------------------------|-----------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------|-------------------------------------------|
| `environmentName`         | string    | The environment to deploy to.                                                                                                                                      | `dev2`  | `dev2`, `dev`, `qa`, `sit`, `ppe`, `prod` |
| `tags`                    | object    | Tags to apply to all deployed resources.                                                                                                                          |         |                                           |
| `sharedStorageAccountName`| string?   | The name of an existing, shared storage account. If omitted, a default name is generated (e.g., `stsn<env><location>`).                                           |         |                                           |

- **Variables**:

| Name                         | Definition                                                                                                                                                                                                                              | Description                                                                                      |
|------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| `environment`                | `loadJsonContent('../data/environment.json')['sn-${environmentName}']`                                                                                                                           | Loads environment settings (subscription IDs, Key Vault names, etc.)                             |
| `location`                   | `az.resourceGroup().location`                                                                                                                                                                    | Uses the resource group’s location for all regional deployments.                                 |
| `logAnalyticsWorkspaces`     | `loadJsonContent('../data/logAnalyticsWorkspace.json')`                                                                                                                                          | Loads Log Analytics workspace names and RGs per environment.                                     |
| `applications`               | `loadJsonContent('../data/sn-application.json')`                                                                                                                                                 | Reads the full list of Selection Navigator applications; used for filtering Edge apps.           |
| `sqlDatabases`               | `loadJsonContent('../data/sn-sqldatabase.json')`                                                                                                                                                 | Reads the full list of SQL database definitions; used for filtering Edge databases.              |
| `kvAppSettings`              | `loadJsonContent('../data/sn-kvAppSettings.json')`                                                                                                                                               | Loads Key Vault–related app settings (e.g., secrets scopes, labels).                             |
| `virtualNetworkIndexSuffix`  | `1`                                                                                                                                                                                             | Numeric suffix for building the VNet name (always “001” for Edge).                               |
| `virtualNetworkName`         | ``vnet-sn-${environment.name}-${location}-${format('{0:000}', virtualNetworkIndexSuffix)}``                                                                                                      | Constructs the regional VNet name, e.g., `vnet-sn-prod-eastus2-001`.                             |
| `sharedStorageAccountNameValue` | `sharedStorageAccountName ?? 'stsn${environment.name}${location}'`                                                                                                                           | Uses the provided shared storage account or generates a default name if none is passed.          |
| `appliedGroupRoleAssignments` | `[ { group: 'SelNav-Azure-AppDev-Edge', roles: ['Contributor'], filters: ['dev2','dev','qa'] } ]`                                                                                              | Default RBAC assignment for the Edge group across non-production environments.                   |
| `groupName`                  | `'Edge'`                                                                                                                                                                                        | Application group targeted by this module.                                                       |
| `filteredApplications`       | `filter(applications, application => (!contains(application, 'locations') || contains(application.locations, location)) && (contains(application, 'group') && application.group == groupName))` | List of Edge applications relevant to this region/location.                                      |
| `filteredSqlDatabases`       | `filter(sqlDatabases, sqlDatabase => (!contains(sqlDatabase, 'locations') || contains(sqlDatabase.locations, location)) && (contains(sqlDatabase, 'group') && sqlDatabase.group == groupName))` | List of Edge SQL databases relevant to this region/location.                                     |

- **Modules and Resources**:

| Name                      | Type / Module Path                                       | Description                                                                                                                                                                                                                                                                                                                                                              |
|---------------------------|----------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `appServicePlans`         | `resource Microsoft.Web/serverfarms@2024-04-01 existing` (array)  | References up to 9 existing App Service Plans named `aj-asp-sn-<env>-<location>-<index>` (for hosting web apps).                                                                                                                                                                                                                                                         |
| `functionAppServicePlans` | `resource Microsoft.Web/serverfarms@2024-04-01 existing` (array)  | References up to 9 existing Function App Service Plans named `aj-asp-sn-<env>-<location>-fn-<index>`.                                                                                                                                                                                                                            |
| `sharedStorageAccount`    | `resource Microsoft.Storage/storageAccounts@2023-01-01 existing`   | References the existing shared storage account (either passed in or default-generated).                                                                                                                                                                                                                                            |
| `sqlDatabasesModule`      | `module '../modules/sn-sqlDatabase.bicep'`                | Iterates over each item in `filteredSqlDatabases`, and for each:  
  • Names the SQL DB `SqlDatabase-<databaseName>` (up to 64 chars).  
  • Passes `tags`, `name`, `sqlServerName` (built from `environment.name` and RG index), optional `elasticPoolName`, optional `catalogCollation`/`collation`.  
  Deploys all region-specific Edge SQL DBs. |
| `applicationsModule`      | `module './sn-site.bicep'`                                | Iterates over each item in `filteredApplications`, and for each:  
  • Generates a unique site name via `sn.CreateSiteName(environment.name, location, application.type, application.abbr)`.  
  • Passes `environment`, `tags`, `appAbbreviation`, `kind` (app or function), `appServicePlanId` or `functionAppServicePlanId`, merged `appSettings`, `keyVaultName`, `kvAppSettings` (merged), `logAnalyticsWorkspaceId`, `appInsightsDataCap` (via `P()` function), `subnetId`, `minimumAppInstances`, `storageAccountId`, `groupRoleAssignments` (merged with application overrides), optional `hybridConnections`, `netFrameworkVersion`, `use32BitWorkerProcess`.  
  Deploys all Edge-grouped web or function apps. |

- **Outputs**:  
  This module does not emit any outputs directly. All child modules (`sn-sqlDatabase.bicep` and `sn-site.bicep`) handle their own outputs.

#### `sn-region-est.bicep`
- **Description**: Deploys EST group resources for a region, including application deployments and required infrastructure.
- **Parameters**: See module for parameter definitions.
- **Resources**: Sets up EST-related resources such as apps, databases, and storage.
- **Outputs**: None.

#### `sn-region-fireDetection.bicep`
- **Description**: Deploys all regional resources required for Fire Detection applications in Selection Navigator. This includes:
  - Loading environment-specific settings (tags, location, Log Analytics workspace, etc.) from JSON lookups.
  - Filtering and deploying only the Fire Detection–grouped SQL databases and web/function apps for the current region.
  - Wiring in shared storage account and network/subnet references.
  - Applying runtime app settings.
  - Assigning RBAC roles for the Fire Detection group and any application-specific overrides.

- **Parameters**:

| Name                      | Type      | Description                                                                                                                                                      | Default | Allowed Values                         |
|---------------------------|-----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------|----------------------------------------|
| `environmentName`         | string    | The environment to deploy to.                                                                                                                                     | `dev2`  | `dev2`, `dev`, `qa`, `sit`, `ppe`, `prod` |
| `tags`                    | object    | Tags to apply to all deployed resources.                                                                                                                         |         |                                        |
| `sharedStorageAccountName`| string?   | The name of an existing, shared storage account. If omitted, a default name is generated (e.g., `stsn<env><location>26052025`).                                 |         |                                        |

- **Variables**:

| Name                         | Definition                                                                                                                                                                                                                                   | Description                                                                                          |
|------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| `environment`                | `loadJsonContent('../../../fire-detection/environment.json')['sn-${environmentName}']`                                                                                                                                                        | Loads environment settings (subscription IDs, service principal IDs, Key Vault names, etc.)          |
| `location`                   | `az.resourceGroup().location`                                                                                                                                                                                                                | Uses the resource group’s location for all regional deployments.                                     |
| `logAnalyticsWorkspaces`     | `loadJsonContent('../../../fire-detection/logAnalyticsWorkspace.json')`                                                                                                                                                                      | Loads Log Analytics workspace names and RGs per environment.                                         |
| `applications`               | `loadJsonContent('../data/sn-application.json')`                                                                                                                                                                                              | Reads the full list of Selection Navigator applications; used for filtering Fire Detection apps.     |
| `sqlDatabases`               | `loadJsonContent('../data/sn-sqldatabase.json')`                                                                                                                                                                                               | Reads the full list of SQL database definitions; used for filtering Fire Detection databases.       |
| `kvAppSettings`              | `loadJsonContent('../data/sn-kvAppSettings.json')`                                                                                                                                                                                             | Loads Key Vault–related app settings (e.g., secrets scopes, labels).                                  |
| `virtualNetworkIndexSuffix`  | `1`                                                                                                                                                                                                                                            | Numeric suffix for building the VNet name (always “001” for Fire Detection).                         |
| `virtualNetworkName`         | ``vnet-sn-${environment.name}-${location}-${format('{0:000}', virtualNetworkIndexSuffix)}``                                                                                                                                                    | Constructs the regional VNet name, e.g., `vnet-sn-prod-eastus2-001`.                                 |
| `sharedStorageAccountNameValue` | `sharedStorageAccountName ?? 'stsn${environment.name}${location}26052025'`                                                                                                                                                                     | Uses the provided shared storage account or generates a default name if none is passed.               |
| `fireDetectionGroupRoleAssignments` | `[ { group: 'SelNav-Azure-AppDev-SysControls', roles: ['Contributor'], filters: ['dev2','dev','qa'] } ]`                                                                                                                                          | Default RBAC assignment for the Fire Detection group across non-production environments.             |
| `filteredApplications`       | `filter(applications, a => (   ( !contains(a, 'locations') || contains(a.locations, location) ) && ( a.group == 'Fire Detection' ) ))`                                                                                                        | List of Fire Detection applications relevant to this region/location.                                |
| `filteredSqlDatabases`       | `filter(sqlDatabases, db => (   ( !contains(db, 'locations') || contains(db.locations, location) ) && ( db.group == 'Fire Detection' ) ))`                                                                                                  | List of Fire Detection SQL databases relevant to this region/location.                              |
| `storageConnectionString`    | ``'DefaultEndpointsProtocol=https;AccountName=${sharedStorageAccount.name};AccountKey=${sharedStorageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net'``                                                                     | The connection string used by web/function apps for content and file shares.                          |

- **Modules and Resources**:

| Name                      | Type / Module Path                                 | Description                                                                                                                                                                                                                                                                                                                                                     |
|---------------------------|----------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `appServicePlans`         | `resource Microsoft.Web/serverfarms@2024-04-01 existing` (array)  | References up to 9 existing App Service Plans named `asp-sn-<env>-<location>-<index>` (for hosting web apps).                                                                                                                                                                                                                                                 |
| `functionAppServicePlans` | `resource Microsoft.Web/serverfarms@2024-04-01 existing` (array)  | References up to 9 existing Function App Service Plans named `asp-sn-<env>-<location>-fn-<index>`.                                                                                                                                                                                                                                                            |
| `sharedStorageAccount`    | `resource Microsoft.Storage/storageAccounts@2023-01-01 existing`   | References the existing shared storage account (either passed in or default-generated).                                                                                                                                                                                                                                                                         |
| `sqlDatabasesModule`      | `module '../modules/sn-sqlDatabase.bicep'`          | Iterates over each item in `filteredSqlDatabases`, and for each:  
  • Names the SQL DB `SqlDatabase-<databaseName>` (up to 64 chars).  
  • Passes `tags`, `name`, `sqlServerName` (built from `environment.name` and RG index), optional `elasticPoolName`, optional `catalogCollation`/`collation`.  
  Deploys all region-specific Fire Detection SQL DBs. |
| `applicationsModule`       | `module './sn-site.bicep'`                          | Iterates over each item in `filteredApplications`, and for each:  
  • Generates a unique site name via `sn.CreateSiteName(environment.name, location, a.type, a.abbr)` plus a 5-char unique suffix.  
  • Passes `environment`, `tags`, `appAbbreviation`, `kind` (app or function), `appServicePlanId` or `functionAppServicePlanId`, merged `appSettings` (including `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING` and `WEBSITE_CONTENTSHARE`), `keyVaultName`, `kvAppSettings` (merged), `logAnalyticsWorkspaceId`, `appInsightsDataCap` (via `P()` function), `subnetId` (computed from VNet name and ASP index), `minimumAppInstances`, `storageAccountId`, `groupRoleAssignments` (merged with application overrides), optional `hybridConnections`, `netFrameworkVersion`, `use32BitWorkerProcess`.  
  Deploys all Fire Detection–grouped web or function apps. |

- **Outputs**:  
  This module does not emit any outputs directly. All child modules (`sn-sqlDatabase.bicep` and `sn-site.bicep`) handle their own outputs.

### Disaster Recovery intermediate modules

#### `sn-dr-shared.bicep`
- **Description**: Deploys shared disaster recovery resources, including storage and networking for DR scenarios.
- **Parameters**: See module for parameter definitions.
- **Resources**: Defines shared DR storage accounts, network configurations, and key vaults.
- **Outputs**: None.

#### `sn-dr-chillers.bicep`
- **Description**: Deploys Chillers group resources in a disaster recovery region, mirroring primary-region resources for failover.
- **Parameters**: See module for parameter definitions.
- **Resources**: Replicates Chillers applications, databases, and event hubs in the DR region.
- **Outputs**: None.

## Base Modules

Modules referenced by Intermediate modules for creating typical resources.

#### `sn-applicationInsights.bicep`
- **Description**: Defines an Application Insights resource.
- **Parameters**:

| Name                    | Type    | Description                                                                            | Default | Allowed Values |
|-------------------------|---------|----------------------------------------------------------------------------------------|---------|----------------|
| `name`                  | string  | The name of the Application Insights resource.                                         |         |                |
| `location`              | string  | The location to deploy to (default = `eastus2`).                                       | `eastus2` |                |
| `tags`                  | object  | The tags to apply to the resources.                                                    |         |                |
| `dataCap`               | int     | The data cap for the Application Insights resource in GB (default = 1, min = 1, max = 50). | `1`     | `1`-`50`       |
| `logAnalyticsWorkspaceId` | string | The Log Analytics workspace to associate with the Application Insights resource.         |         |                |

- **Resources**:

| Resource                       | Type                                                    | Description                                   |
|--------------------------------|---------------------------------------------------------|-----------------------------------------------|
| `applicationInsights`          | `Microsoft.Insights/components@2021-08-01`              | Creates the Application Insights resource.    |
| `applicationInsightsPricingPlans` | `Microsoft.Insights/components/properties/ApiKeys@2021-08-01` | Configures the pricing plan for the Application Insights resource. |

- **Outputs**:

| Name | Type   | Description                                |
|------|--------|--------------------------------------------|
| `id` | string | The ID of the Application Insights resource. |
| `name` | string | The name of the Application Insights resource. |

#### `sn-eventHub.bicep`
- **Description**: Defines Event Hubs resources.
  - `id`: (string) The ID of the Application Insights resource.
  - `name`: (string) The name of the Application Insights resource.
#### `sn-eventHub.bicep`
- **Description**: Defines Event Hubs resources.
- **Parameters**:
  - `environment`: (object) The environment to deploy to.
  - `tags`: (object) The tags to apply to the Event Hubs namespace.
  - `name`: (string?) The name of the Event Hubs namespace (optional).
  - `eventHubName`: (string) The name of the Event Hub.
  - `sku`: (string) The SKU for the Event Hubs namespace. Allowed: `Basic`, `Standard`, `Premium` (default = `Standard`).
  - `capacity`: (int) The capacity for the Event Hubs namespace (default = 1, min = 1, max = 20).
  - `groupRoleAssignments`: (GroupRoleAssignment[]) Group role assignments to apply to the namespace.
  - `sharedAccessPolicies`: (SharedAccessPolicies[]) An array of authorization rules to create for the Event Hubs namespace.
- **Resources**:
  - `eventHubsNamespace`: Creates the Event Hubs namespace.
  - `accessPolicies`: Creates authorization rules for the namespace.
  - `eventHubsResources`: Creates Event Hubs within the namespace (clients0, clients1, clients2, clients3, loadmonitor, partitions, test).
  - `roleAssignmentModule`: Assigns roles to groups for the namespace.
- **Outputs**:
  - `namespaceId`: (string) The ID of the Event Hubs namespace.
#### `sn-eventHub-roleAssignment.bicep`
- **Description**: Defines role-based access control (RBAC) rights for an Event Hub namespace.
- **Parameters**:
  - `environment`: (object) The environment to deploy to.
  - `resourceId`: (string) The resource ID of the Event Hub namespace where roles will be assigned.
  - `groupRoleAssignments`: (GroupRoleAssignment[]) Group role assignments to apply to the Event Hub namespace.
  - `groups`: A group lookup containing all groups, keyed by name, that are referenced in the groupRoleAssignments.  Default is to read from the sn-group.json file in the data directory. 
    ```json
    {
    "SelNav-Azure-Reader":{"id":"b975b55c-a404-4ff4-90e6-411031fcfa80"}
    }
    ```
  - `roles`: A role lookup containing all roles, keyed by name, that are referenced in the groupRoleAssignments.  Deafult is to read from the sn-role.json file in the data directory.
    ```json
    {
    "Reader":{"id":"acdd72a7-3385-48ef-bd42-f606fba81ae7"}
    }
    ```
- **Resources**:
  - `eventHubsNamespace`: References the existing Event Hub namespace.
  - `roleAssignment`: Associates the group roles to the Event Hub namespace.
- **Outputs**:
  - `groupRoleAssignments`: (object[]) The flattened group role assignments.
#### `sn-frontDoor-origin.bicep`
- **Description**: Defines a Front Door origin, origin group, and route. The scope of this must be set at the time of calling.
- **Parameters**:

| Name                | Type       | Description                                                                     | Default      | Allowed Values   |
|---------------------|------------|---------------------------------------------------------------------------------|--------------|------------------|
| `environment`       | object     | The environment to deploy to.                                                   |              |                  |
| `tags`              | object     | The tags to apply to the Event Hubs namespace.                                  |              |                  |
| `name`              | string?    | The name of the Event Hubs namespace (optional).                                |              |                  |
| `eventHubName`      | string     | The name of the Event Hub.                                                      |              |                  |
| `sku`               | string     | The SKU for the Event Hubs namespace.                                           | `Standard`   | `Basic`, `Standard`, `Premium` |
| `capacity`          | int        | The capacity for the Event Hubs namespace (default = 1, min = 1, max = 20).     | `1`          | `1`-`20`         |
| `groupRoleAssignments` | GroupRoleAssignment[] | Group role assignments to apply to the namespace.                                |              |                  |
| `sharedAccessPolicies` | SharedAccessPolicies[] | An array of authorization rules to create for the Event Hubs namespace.          |              |                  |

- **Resources**:

| Resource                | Type                                                         | Description                                                         |
|-------------------------|--------------------------------------------------------------|---------------------------------------------------------------------|
| `eventHubsNamespace`    | `Microsoft.EventHub/namespaces@2021-11-01`                   | Creates the Event Hubs namespace.                                   |
| `accessPolicies`        | `Microsoft.EventHub/namespaces/authorizationRules@2021-11-01` | Creates authorization rules for the namespace.                      |
| `eventHubsResources`    | `Microsoft.EventHub/namespaces/eventhubs@2021-11-01`         | Creates Event Hubs within the namespace (clients0, clients1, clients2, clients3, loadmonitor, partitions, test). |
| `roleAssignmentModule`  | Module reference                                              | Assigns roles to groups for the namespace.                           |

- **Outputs**:

| Name             | Type   | Description                         |
|------------------|--------|-------------------------------------|
| `namespaceId`    | string | The ID of the Event Hubs namespace. |

#### `sn-eventHub-roleAssignment.bicep`
- **Description**: Defines role-based access control (RBAC) rights for an Event Hub namespace.
- **Parameters**:

| Name                  | Type       | Description                                                                                 |
|-----------------------|------------|---------------------------------------------------------------------------------------------|
| `environment`         | object     | The environment to deploy to.                                                               |
| `resourceId`          | string     | The resource ID of the Event Hub namespace where roles will be assigned.                   |
| `groupRoleAssignments`| GroupRoleAssignment[] | Group role assignments to apply to the Event Hub namespace.                                |
| `groups`              | object     | A group lookup containing all groups, keyed by name, that are referenced in the groupRoleAssignments. Default reads from `sn-group.json`. |
| `roles`               | object     | A role lookup containing all roles, keyed by name, that are referenced in the groupRoleAssignments. Default reads from `sn-role.json`. |

- **Resources**:

| Resource         | Type                 | Description                                              |
|------------------|----------------------|----------------------------------------------------------|
| `eventHubsNamespace` | Module reference  | References the existing Event Hub namespace.             |
| `roleAssignment` | `Microsoft.Authorization/roleAssignments@2020-04-01-preview` | Associates the group roles to the Event Hub namespace.  |

- **Outputs**:

| Name                   | Type     | Description                                |
|------------------------|----------|--------------------------------------------|
| `groupRoleAssignments` | object[] | The flattened group role assignments.      |

#### `sn-frontDoor-origin.bicep`
- **Description**: Defines a Front Door origin. The scope of this must be set at the time of calling.
- **Parameters**:

| Name                  | Type    | Description                                                                                     | Default | Allowed Values |
|-----------------------|---------|-------------------------------------------------------------------------------------------------|---------|----------------|
| `environment`         | object  | The environment to deploy to, as pulled from the environment.json lookup.                      |         |                |
| `name`                | string  | The name of the resource to create an origin for (e.g., `fn-sn-prod-slc-eastus2`).               |         |                |
| `originGroupName`     | string  | The name of the origin group to create (e.g., `fn-slc`).                                        |         |                |
| `routeName`           | string  | The name of the route to create (default = `originGroupName`).                                  | `originGroupName` | |
| `hostName`            | string  | The host name (e.g., `fn-sn-prod-slc-eastus2.azurewebsites.net`).                               |         |                |
| `healthProbePath`     | string  | The path the health probe should use (default = `/`).                                           | `/`     |                |
| `healthProbeMethod`   | string  | The method the health probe should use (default = `HEAD`, allowed values: `HEAD`, `GET`).        | `HEAD`  | `HEAD`, `GET`  |
| `privateLinkResourceId` | string? | The private link resource ID. If provided, a private link connection will be created (optional). |         |                |
| `privateLinkLocation` | string? | The private link location (optional).                                                           |         |                |
| `privateLinkGroupId`  | string  | The private link group ID (default = `blob`).                                                   | `blob`  |                |
| `patternsToMatch`     | string[]| The patterns to match for the route (e.g., `["/*"]`).                                            |         |                |
| `customDomainNames`   | string[]| An array of custom domain names to associate with the route.                                     |         |                |
| `ruleSetNames`        | string[]| An array of ruleset names to associate with the route.                                          |         |                |

- **Resources**:

| Resource         | Type                                                      | Description                                              |
|------------------|-----------------------------------------------------------|----------------------------------------------------------|
| `frontDoor`      | `Microsoft.Cdn/profiles@2024-09-01` (existing)             | References the existing Front Door profile.              |
| `frontDoorEndpoint` | `Microsoft.Cdn/profiles/afdendpoints@2024-09-01` (existing) | References the existing Front Door endpoint.              |
| `originGroup`    | `Microsoft.Cdn/profiles/originGroups@2024-09-01` (existing) | References the existing origin group.                     |
| `origin`         | `Microsoft.Cdn/profiles/originGroups/origins@2024-09-01`    | Creates the origin under the origin group.                |
| `customDomains`  | `Microsoft.Cdn/profiles/customDomains@2024-09-01` (existing) | References existing custom domains.                       |
| `ruleSets`       | `Microsoft.Cdn/profiles/rulesets@2024-09-01` (existing)    | References existing rulesets.                             |
| `route`          | `Microsoft.Cdn/profiles/afdendpoints/routes@2024-09-01`     | Creates the Front Door route.                             |

- **Outputs**:

| Name              | Type    | Description                              |
|-------------------|---------|------------------------------------------|
| `id`              | string  | The ID of the origin.                    |
| `name`            | string  | The name of the origin.                  |
| `originGroupId`   | string  | The ID of the origin group.              |
| `originGroupName` | string  | The name of the origin group.            |
| `routeId`         | string  | The ID of the route.                     |
| `routeName`       | string  | The name of the route.                   |

#### `sn-frontDoor-originGroup.bicep`
- **Description**: Defines a Front Door origin group with health probe and load balancing settings. The scope of this must be set at the time of calling.
- **Parameters**:

| Name              | Type    | Description                                                         | Default | Allowed Values |
|-------------------|---------|---------------------------------------------------------------------|---------|----------------|
| `environment`     | object  | The environment to deploy to.                                        |         |                |
| `originGroupName` | string  | The name of the origin group to create (e.g., `fn-slc`).             |         |                |
| `healthProbePath` | string  | The path the health probe should use.                                | `/`     |                |
| `healthProbeMethod` | string | The method the health probe should use.                              | `HEAD`  | `HEAD`, `GET`  |

- **Resources**:

| Resource        | Type                                               | Description                                                  |
|-----------------|----------------------------------------------------|--------------------------------------------------------------|
| `frontDoor`     | `Microsoft.Cdn/profiles@2024-09-01` (existing)      | References the existing Front Door profile.                  |
| `originGroup`   | `Microsoft.Cdn/profiles/originGroups@2024-09-01`    | Creates the origin group with health probe and load balancing settings. |

- **Outputs**:

| Name | Type   | Description                          |
|------|--------|--------------------------------------|
| `id` | string | The ID of the origin group.          |
| `name` | string | The name of the origin group.       |
| `type` | string | The type of the origin group resource. |

#### `sn-frontDoor-route.bicep`
- **Description**: Defines a Front Door route, associating origin groups with routing rules and custom domains. The scope of this must be set at the time of calling.
- **Parameters**:

| Name               | Type      | Description                                                          |
|--------------------|-----------|----------------------------------------------------------------------|
| `environment`      | object    | The environment to deploy to.                                        |
| `routeName`        | string    | The name of the route to create.                                     |
| `originGroupName`  | string    | The name of the origin group to associate.                           |
| `patternsToMatch`  | string[]  | The patterns to match for routing (e.g., `["/*"]`).                  |
| `customDomainNames`| string[]  | An array of custom domain names to associate with the route.         |
| `ruleSetNames`     | string[]  | An array of ruleset names to associate with the route.               |

- **Resources**:

| Resource            | Type                                                      | Description                                              |
|---------------------|-----------------------------------------------------------|----------------------------------------------------------|
| `frontDoor`         | `Microsoft.Cdn/profiles@2024-09-01` (existing)             | References the existing Front Door profile.              |
| `frontDoorEndpoint` | `Microsoft.Cdn/profiles/afdendpoints@2024-09-01` (existing) | References the existing Front Door endpoint.             |
| `originGroup`       | `Microsoft.Cdn/profiles/originGroups@2024-09-01` (existing) | References the existing origin group.                    |
| `customDomains`     | `Microsoft.Cdn/profiles/customDomains@2024-09-01` (existing) | References existing custom domains.                      |
| `ruleSets`          | `Microsoft.Cdn/profiles/rulesets@2024-09-01` (existing)    | References existing rulesets.                            |
| `route`             | `Microsoft.Cdn/profiles/afdendpoints/routes@2024-09-01`     | Creates the Front Door route.                             |

- **Outputs**:

| Name | Type   | Description                          |
|------|--------|--------------------------------------|
| `id` | string | The ID of the route.                 |
| `name` | string | The name of the route.              |

#### `sn-keyVault-secret.bicep`
- **Description**: Defines a Key Vault secret.
- **Parameters**:

| Name          | Type    | Description                                                      |
|---------------|---------|------------------------------------------------------------------|
| `keyVaultName`| string  | The name of the Key Vault where the secret will be stored.       |
| `name`        | string  | The name of the Key Vault secret.                                |
| `value`       | string  | The value of the Key Vault secret.                               |

- **Resources**:

| Resource       | Type                                        | Description                         |
|----------------|---------------------------------------------|-------------------------------------|
| `keyVault`     | `Microsoft.KeyVault/vaults@2024-04-01` (existing) | References the existing Key Vault.  |
| `keyVaultSecret` | `Microsoft.KeyVault/vaults/secrets@2024-04-01`  | Creates the Key Vault secret.       |

- **Outputs**:

| Name | Type   | Description                            |
|------|--------|----------------------------------------|
| `id` | string | The ID of the Key Vault secret.        |
| `name` | string | The name of the Key Vault secret.     |

#### `sn-network.bicep`
- **Description**: Defines the network including default subnets, NAT gateway, network security groups, and private DNS zones.
- **Parameters**:

| Name                       | Type      | Description                                                                                                   | Default | Allowed Values |
|----------------------------|-----------|---------------------------------------------------------------------------------------------------------------|---------|----------------|
| `environment`              | object    | The environment to deploy to, as pulled from the environment.json lookup.                                     |         |                |
| `tags`                     | object    | The tags to associate to the resources created. Each of the object's key/value properties become a tag.       |         |                |
| `name`                     | string    | The name of the resource.                                                                                     |         |                |
| `indexSuffix`             | int       | The index suffix for the virtual network (default = 1).                                                        | `1`     |                |
| `publicIpCount`           | int       | The number of public IP addresses to create for outbound communication (default = 1).                          | `1`     |                |
| `appServicePlanSubnetCount` | int     | The number of app service plan subnets to create (default = 0).                                               | `0`     |                |
| `functionAppServicePlanSubnetCount` | int | The number of function app service plan subnets to create (default = 0).                                      | `0`     |                |

- **Resources**:

| Resource                          | Type                                                      | Description                                                                                 |
|-----------------------------------|-----------------------------------------------------------|---------------------------------------------------------------------------------------------|
| `networkSecurityGroup`            | `Microsoft.Network/networkSecurityGroups@2024-06-01`      | Creates the network security group.                                                         |
| `networkSecurityGroupLock`        | `Microsoft.Authorization/locks@2023-01-01-preview`         | Creates a lock on the network security group.                                               |
| `publicIpAddresses`               | `Microsoft.Network/publicIPAddresses@2024-06-01`          | Creates public IP addresses for outbound communication via NAT gateway.                    |
| `publicIpAddressLock`             | `Microsoft.Authorization/locks@2023-01-01-preview`         | Creates a lock for each of the public IP addresses.                                        |
| `natGateway`                      | `Microsoft.Network/natGateways@2024-06-01`                | Creates the NAT gateway.                                                                    |
| `natGatewayLock`                  | `Microsoft.Authorization/locks@2023-01-01-preview`         | Creates a lock on the NAT gateway.                                                          |
| `virtualNetwork`                  | `Microsoft.Network/virtualNetworks@2024-06-01`             | Creates the virtual network.                                                                |
| `virtualNetworkLock`              | `Microsoft.Authorization/locks@2023-01-01-preview`         | Creates a lock on the virtual network.                                                      |
| `privateDNSZones`                 | `Microsoft.Network/privateDnsZones@2024-06-01`            | Creates private DNS zones.                                                                  |
| `privateDNSZoneLocks`             | `Microsoft.Authorization/locks@2023-01-01-preview`         | Creates locks on the private DNS zones.                                                     |
| `privateDNSZoneVirtualNetworkLinks` | `Microsoft.Network/privateDnsZoneVirtualNetworkLinks@2024-06-01` | Links the virtual network to the private DNS zones.                                         |
| `servicesSubnet`                  | Reads back the services subnet.                             |                                                                                             |

- **Outputs**:

| Name                      | Type   | Description                                |
|---------------------------|--------|--------------------------------------------|
| `virtualNetworkId`        | string | The ID of the virtual network.             |
| `virtualNetworkName`      | string | The name of the virtual network.           |
| `natGatewayId`            | string | The ID of the NAT gateway.                 |
| `natGatewayName`          | string | The name of the NAT gateway.               |
| `networkSecurityGroupId`  | string | The ID of the network security group.      |
| `networkSecurityGroupName`| string | The name of the network security group.    |
| `servicesSubNetId`        | string | The ID of the services subnet.             |
| `servicesSubNetName`      | string | The name of the services subnet.           |
| `subnets`                 | array  | The combined list of subnet definitions.   |

#### `sn-privateEndpoint.bicep`
- **Description**: Defines private endpoint resources for the network.
- **Parameters**:

| Name                  | Type    | Description                                                        |
|-----------------------|---------|--------------------------------------------------------------------|
| `tags`                | object  | The tags to associate to the resources created.                    |
| `virtualNetworkName`  | string  | The name of the virtual network to attach the private endpoint to. |
| `subnetName`          | string  | The name of the subnet to attach the private endpoint to.          |
| `resourceId`          | string  | The ID of the resource the private endpoint will connect to.       |
| `nameSuffix`          | string  | A suffix to append to the private endpoint name. e.g., "-blob".     |
| `groupId`             | string  | The group ID to connect to.                                         |
| `privateDnsZoneName`  | string  | The private DNS zone name. e.g., "privatelink.vaultcore.azure.net". |

- **Resources**:

| Resource          | Type                                                      | Description                                              |
|-------------------|-----------------------------------------------------------|----------------------------------------------------------|
| `virtualNetwork`  | `Microsoft.Network/virtualNetworks@2024-06-01` (existing) | References the existing virtual network.                 |
| `subnet`          | `Microsoft.Network/virtualNetworks/subnets@2024-06-01` (existing) | References the existing subnet.                           |
| `privateEndpoint` | `Microsoft.Network/privateEndpoints@2024-06-01`          | Creates the private endpoint.                           |
| `privateDnsZone`  | `Microsoft.Network/privateDnsZones@2024-06-01` (existing) | References the existing private DNS zone.                |
| `privateDnsZoneGroup` | `Microsoft.Network/privateDnsZones/privateDnsZoneGroups@2024-06-01` | Creates the private DNS zone group.                       |

- **Outputs**:

| Name | Type   | Description                                |
|------|--------|--------------------------------------------|
| `id` | string | The ID of the private endpoint.            |
| `name` | string | The name of the private endpoint.         |

#### `sn-logAnalytics.bicep`
- **Description**: This template defines a Log Analytics Workspace resource. The scope of this must be set at the time of calling.
- **Parameters**:

| Name      | Type    | Description                              |
|-----------|---------|------------------------------------------|
| `tags`    | object  | Tags to apply to the resources.          |
| `name`    | string  | The name of the Log Analytics Workspace. |
| `properties` | object | The properties of the resource.           |

- **Resources**:

| Resource                       | Type                                                   | Description                                   |
|--------------------------------|--------------------------------------------------------|-----------------------------------------------|
| **Log Analytics Workspace**    | `Microsoft.OperationalInsights/workspaces@2025-02-01`   | Creates a workspace using the provided `name`, `sku`, and `tags`. |

- **Outputs**:

| Name | Type   | Description                                |
|------|--------|--------------------------------------------|
| `id` | string | The resource ID of the deployed workspace. |
| `name` | string | The name of the deployed workspace.       |

  - `id`: (string) The ID of the private endpoint.
  - `name`: (string) The name of the private endpoint.
#### `sn-region-chillers.bicep`
- **Description**: Deploys all Chillers group resources for a region, including applications, SQL databases, and Event Hubs, with associated networking, storage, and RBAC.
- **Parameters**:
  - `environment`: (object) The environment to deploy to.
  - `tags`: (object) The tags to apply to the resources.
  - `virtualNetworkName`: (string?) The name of the virtual network resource (optional).
  - `sharedStorageAccountName`: (string?) The name of the shared storage account resource (optional).
- **Resources**:
  - `appServicePlans`: References existing App Service Plans for the region.
  - `functionAppServicePlans`: References existing Function App Service Plans for the region.
  - `applicationsModule`: Deploys all Chillers applications as sites.
  - `sqlDatabasesModule`: Deploys all Chillers SQL databases.
  - `chillersEventHubs`: Deploys Event Hubs for Chillers workloads.
- **Outputs**: None.
#### `sn-resourceGroup.bicep`
- **Description**: Defines role-based access control (RBAC) rights for existing resource groups. Resource groups are created via IT ticket system.
- **Types**:

| Type                | Definition                                                                                            |
|---------------------|-------------------------------------------------------------------------------------------------------|
| `GroupRoleAssignment` | Defines the properties of a group role assignment.                                                  |
|                     | ```json                                                                                              |
|                     | {                                                                                                     |
|                     |   "group": "string",                                                                                  |
|                     |   "roles": ["string"],                                                                                |
|                     |   "filters": ["string"]                                                                               |
|                     | }                                                                                                     |
|                     | ```                                                                                                   |

- **Parameters**:

| Name                   | Type                   | Description                                                                                                  |
|------------------------|------------------------|--------------------------------------------------------------------------------------------------------------|
| `environment`          | object                 | The environment to deploy to, as pulled from the environment.json lookup.                                     |
| `groupRoleAssignments` | GroupRoleAssignment[]  | Group role assignments to apply to the resource group. The `filters` property is optional and controls which environments the assignment applies to. |

- **Outputs**:

| Name                   | Type       | Description                            |
|------------------------|------------|----------------------------------------|
| `groupRoleAssignments` | object[]   | The flattened group role assignments.  |

#### `sn-roleAssignment.bicep`
- **Description**: Defines role-based access control (RBAC) rights for existing resources. Resource groups are created via IT ticket system.
- **Types**:

| Type                | Definition                                                                                            |
|---------------------|-------------------------------------------------------------------------------------------------------|
| `GroupRoleAssignment` | Defines the properties of a group role assignment.                                                  |
|                     | ```json                                                                                              |
|                     | {                                                                                                     |
|                     |   "group": "string",                                                                                  |
|                     |   "roles": ["string"],                                                                                |
|                     |   "filters": ["string"]                                                                               |
|                     | }                                                                                                     |
|                     | ```                                                                                                   |

- **Parameters**:

| Name                   | Type                   | Description                                                                                                  |
|------------------------|------------------------|--------------------------------------------------------------------------------------------------------------|
| `environment`          | object                 | The environment to deploy to, as pulled from the environment.json lookup.                                     |
| `groupRoleAssignments` | GroupRoleAssignment[]  | Group role assignments to apply to the resources. The `filters` property is optional and controls which environments the assignment applies to. |
| `groups`               | object                 | A group lookup containing all groups, keyed by name, that are referenced in the `groupRoleAssignments`. Defaults to reading from `sn-group.json`. |
| `roles`                | object                 | A role lookup containing all roles, keyed by name, that are referenced in the `groupRoleAssignments`. Defaults to reading from `sn-role.json`. |

- **Resources**:

| Resource         | Type                                                                                       | Description                                              |
|------------------|--------------------------------------------------------------------------------------------|----------------------------------------------------------|
| `roleAssignment` | `Microsoft.Authorization/roleAssignments@2020-04-01-preview`                               | Associates the group roles to the resource group.        |

- **Outputs**:

| Name                   | Type       | Description                                |
|------------------------|------------|--------------------------------------------|
| `groupRoleAssignments` | object[]   | The flattened group role assignments.      |

#### `sn-site-config-appsettings.bicep`
- **Description**: Defines the app settings for a site while preserving the existing settings.
- **Parameters**:

| Name                | Type    | Description                                                                                               |
|---------------------|---------|-----------------------------------------------------------------------------------------------------------|
| `name`              | string  | The name of the function app.                                                                             |
| `appSettings`       | object  | The app settings to configure.                                                                            |
| `existingAppSettings` | object | The existing app settings to be overridden but not lost.                                                  |

- **Resources**:

| Resource           | Type                                                     | Description                                              |
|--------------------|----------------------------------------------------------|----------------------------------------------------------|
| `site`             | `Microsoft.Web/sites@2024-01-01` (existing)              | References the existing site.                             |
| `siteConfigAppSettings` | `Microsoft.Web/sites/config@2024-01-01`              | Configures the app settings for the site by merging existing and new settings. |

- **Outputs**: None.

#### `sn-site.bicep`
- **Description**:  
  Creates and configures an Azure Function or App Service site, including:  
  1. Provisioning a system-assigned managed identity.  
  2. Creating or referencing an Application Insights resource to capture telemetry.  
  3. Configuring networking, authentication, and security settings (e.g., enabling HTTPS only, VNet integration, IP restrictions).  
  4. Merging and preserving existing site app settings and connection strings (including Key Vault references, SQL connection strings, and Azure Functions storage settings).  
  5. Setting up hybrid connections if provided.  
  6. Integrating with Azure Front Door by creating an origin group, origin, and route to route traffic to the site.  
  7. Assigning RBAC roles to the site’s managed identity for Key Vault access.

- **Parameters**:

| Name                          | Type      | Description                                                                                                                                                       | Default   | Allowed Values                                   |
|-------------------------------|-----------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------|--------------------------------------------------|
| `environment`                 | object    | The environment to deploy to (from `environment.json` lookup).                                                                                                    |           |                                                  |
| `tags`                        | object    | Tags to apply to the site and related resources.                                                                                                                   |           |                                                  |
| `name`                        | string?   | The name of the App Service or Function App. If omitted, constructed from `appAbbreviation`, `environment.name`, and `location`.                                    |           |                                                  |
| `appAbbreviation`             | string?   | A short abbreviation for the application; used to generate a site name when `name` is not provided.                                                               |           |                                                  |
| `appServicePlanId`            | string    | Resource ID of the App Service Plan (server farm) to host the site.                                                                                              |           |                                                  |
| `kind`                        | string    | The kind of site to create. Allowed: `app`, `app,linux`, `functionapp`, `functionapp,linux`.                                                                       |           | `app`, `app,linux`, `functionapp`, `functionapp,linux` |
| `appSettings`                 | object    | Application settings to apply. If `kvAppSettings` is provided, settings here will be merged with Key Vault references.                                               | `{}`      |                                                  |
| `keyVaultName`                | string?   | Name of the Key Vault to reference for secret retrieval.                                                                                                          |           |                                                  |
| `kvAppSettings`               | object    | Key-value pairs whose values are names of Key Vault secrets. These are expanded to Key Vault URIs at runtime.                                                     |           |                                                  |
| `connectionStrings`           | object    | Connection strings to configure for the site. If `sqlDatabaseNames` is provided, SQL connection strings will be generated and merged.                              | `{}`      |                                                  |
| `sqlServerName`               | string?   | The SQL server hostname (without suffix) to build managed-identity–based connection strings.                                                                      |           |                                                  |
| `sqlDatabaseNames`            | string[]  | Array of SQL database names for which to create Active Directory managed identity connection strings.                                                             | `[]`      |                                                  |
| `logAnalyticsWorkspaceId`     | string    | Resource ID of the Log Analytics workspace to associate with Application Insights.                                                                                |           |                                                  |
| `appInsightsLocation`         | string    | Location to deploy Application Insights if not in default region.                                                                                                 | `eastus2` |                                                  |
| `appInsightsDataCap`          | int       | Data cap (GB) for Application Insights (1–50).                                                                                                                     | `1`       | `1`–`50`                                         |
| `subnetId`                    | string    | Resource ID of the Virtual Network Subnet for site VNet integration.                                                                                               |           |                                                  |
| `storageAccountId`            | string    | Resource ID of the storage account for Azure Functions.                                                                                                           | `''`      |                                                  |
| `minimumAppInstances`         | int       | Minimum number of instances (0–20). Used for “Always On” or Function pre-warmed instances.                                                                         | `1`       | `0`–`20`                                         |
| `preWarmedInstanceCount`      | int       | Number of pre-warmed instances for Functions (0–10).                                                                                                               | `2`       | `0`–`10`                                         |
| `use32BitWorkerProcess`       | bool?     | If true, forces site to run 32-bit worker process.                                                                                                                |           |                                                  |
| `netFrameworkVersion`         | string?   | .NET framework version (e.g., `v4.8`, `v6.0`, `v8.0`) if site requires .NET.                                                                                     |           | `v4.8`, `v6.0`, `v8.0`                           |
| `retainExistingPatternsToMatch` | bool    | If true, retains any existing Front Door routing patterns when creating a new route; otherwise overwrites with `customPatternsToMatch`.                             | `true`    |                                                  |
| `customPatternsToMatch`       | string[]  | Custom path patterns for Front Door route (e.g., `["/api/*"]`).                                                                                                     | `[]`      |                                                  |
| `groupRoleAssignments`        | Types.GroupRoleAssignment[] | List of RBAC assignments (group + role names + environment filters) to associate with the site’s managed identity.                                                      | `[]`      |                                                  |
| `hybridConnections`           | Types.HybridConnection[]    | Array of hybrid connection definitions (hostname, port, filters) to connect to Azure Relay.                                                                        | `[]`      |                                                  |
| `afdRouteHttpPort`            | int       | HTTP port for Front Door health probes.                                                                                                                            | `80`      |                                                  |
| `afdRouteHttpsPort`           | int       | HTTPS port for Front Door health probes.                                                                                                                           | `443`     |                                                  |
| `afdRoutePriority`            | int       | Origin priority within origin group for load balancing (lower number = higher priority).                                                                           | `1`       |                                                  |
| `afdRouteWeight`              | int       | Origin weight within origin group for load balancing.                                                                                                              | `1000`    |                                                  |
| `afdRoutePrivateLinkResourceId` | string   | Private Link resource ID if Origin should use a Private Endpoint.                                                                                                   | `''`      |                                                  |
| `afdRoutePrivateLinkLocation` | string    | Private Link location (region), if applicable.                                                                                                                      | `''`      |                                                  |
| `afdRoutePrivateLinkGroupId`  | string    | Private Link group ID (e.g., `blob`).                                                                                                                               | `blob`    |                                                  |

- **Resources**:

| Resource                               | Type                                                           | Description                                                                                                                                                                                                                                                                                                                                                                                                                         |
|----------------------------------------|----------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `applicationInsightsModule`            | Module: `sn-applicationInsights.bicep`                          | Deploys or references an Application Insights instance in the designated resource group (from `environment.applicationInsights.resourceGroup`).                                                                                                                                                                                                                                                                                   |
| `applicationInsights`                  | `Microsoft.Insights/components@2020-02-02-preview` (existing)   | Reads the existing Application Insights resource (to retrieve `InstrumentationKey` and `ConnectionString`).                                                                                                                                                                                                                                                                                                                         |
| `site`                                 | `Microsoft.Web/sites@2024-04-01`                                | Creates the App Service or Function App with:  
  • Managed identity (system assigned).  
  • VNet integration via `virtualNetworkSubnetId`.  
  • HTTPS-only enforcement; always-on or pre-warmed instance counts.  
  • IP restrictions to allow only AzureCloud and Front Door traffic.  
  • Key Vault access enabled for managed identity.                                                                                                                                                                                                                                                                    |
| `keyVault`                             | `Microsoft.KeyVault/vaults@2024-11-01` (existing)               | References the Key Vault defined in `environment.keyVault` (to assign secrets to identity).                                                                                                                                                                                                                                                                                                                                          |
| `kvRoleAssignment`                     | `Microsoft.Authorization/roleAssignments@2022-04-01`           | Grants the site’s managed identity `Key Vault Secrets User` role on the Key Vault so it can retrieve secrets at runtime.                                                                                                                                                                                                                                                                                                            |
| `frontDoor`                            | `Microsoft.Cdn/profiles@2024-09-01` (existing)                  | References the Front Door profile defined in `environment.frontDoor`.                                                                                                                                                                                                                                                                                                                                                               |
| `frontDoorEndpoint`                    | `Microsoft.Cdn/profiles/afdendpoints@2024-09-01` (existing)     | References the Front Door endpoint (AFD) under the profile.                                                                                                                                                                                                                                                                                                                                                                          |
| `siteConfig`                           | `Microsoft.Web/sites/config@2024-04-01`                         | Configures site properties:  
  • Always On (for Web Apps).  
  • HTTP/2 enabled.  
  • FTPS disabled.  
  • TLS 1.2 minimum.  
  • Instance counts.  
  • 32-bit worker toggling, .NET version if provided.  
  • WebSockets disabled; default IP restrictions (AzureCloud + AFD).  
  • SCM (Kudu) IP restrictions open by default.                                                                                                                                                                                                                                                              |
| `hybridConnectionResources`            | `Microsoft.Web/sites/hybridConnectionNamespaces/relays@2024-04-01` (array) | Configures each allowed hybrid connection to Azure Relay by linking the site to Relay namespaces found in `relay.json` (filtered by `hybridConnections`).                                                                                                                                                                                                                                    |
| `siteConfigAppSettingsModule`          | Module: `sn-site-config-appsettings.bicep`                      | Merges any `kvAppSettings` (expanded to Key Vault URIs), `applicationInsightsSettings`, `storageSettings` (for Functions), and the base `appSettings` with existing app settings.                                                                                                                                                                                                                                                 |
| `siteConfigConnectionStringsModule`    | Module: `sn-site-config-connectionstrings.bicep` @conditional | If `kvAppSettings` or `sqlConnectionStrings` exist, merges new connection strings with existing ones.                                                                                                                                                                                                                                                                                                                                 |
| `existingRoute`                        | `Microsoft.Cdn/profiles/afdendpoints/routes@2024-09-01` (existing) | If a Front Door route named `<siteShortName>` already exists, read its properties (e.g., existing `patternsToMatch`).                                                                                                                                                                                                                                                                                                                |
| `originGroupModule`                    | Module: `sn-frontDoor-originGroup.bicep`                         | Creates an AFD origin group named `<siteShortName>`, or reuses existing one, with specified health probe settings.                                                                                                                                                                                                                                                                                                                  |
| `originModule`                         | Module: `sn-frontDoor-origin.bicep`                              | Creates an AFD origin under `<siteShortName>` origin group, pointing to `<siteName>.azurewebsites.net` on ports `afdRouteHttpPort/afdRouteHttpsPort`, with load balancing settings (`priority`, `weight`), and optional Private Link integration.                                                                                                                                                                                   |
| `routeModule`                          | Module: `sn-frontDoor-route.bicep`                               | Defines an AFD route named `<siteShortName>`, associating it with the `originGroupModule` output, applying `patternsToMatch` (by default `['/<siteShortName>/*']`), binding the site’s custom domain (`environment.frontDoor.domain`), and linking any `ruleSetNames` (e.g., `DefaultRules`).                                                                                                                                         |
| `roleAssignmentModule`                 | Module: `sn-site-roleAssignment.bicep`                            | Assigns any provided `groupRoleAssignments` (e.g., granting roles such as Contributor/Reader for service principals or user groups) to the site’s identity so it can access downstream resources (e.g., Key Vault, SQL).                                                                                                                                                                                                                 |

- **Outputs**:

| Name | Type   | Description                                                    |
|------|--------|----------------------------------------------------------------|
| `id` | string | The ARM resource ID of the created App Service/Function App.  |
| `name` | string | The name of the created site resource. 

#### `sn-sqlDatabase.bicep`
- **Description**: Defines a SQL database.
- **Types**:

| Type                | Definition                                                                                           |
|---------------------|------------------------------------------------------------------------------------------------------|
| `ComputeSettingsType` | Defines the compute settings for databases not included in an elastic pool.                        |
|                     | ```json                                                                                              |
|                     | {                                                                                                    |
|                     |   "name": "string",                                                                                   |
|                     |   "tier": "string",                                                                                   |
|                     |   "family": "string",                                                                                 |
|                     |   "capacity": "int",                                                                                 |
|                     |   "minCapacity": "string",                                                                            |
|                     |   "autoPauseDelayMinutes": "int"                                                                      |
|                     | }                                                                                                    |
|                     | ```                                                                                                  |

- **Parameters**:

| Name                | Type                   | Description                                                                                                    | Default                                                                                   |
|---------------------|------------------------|----------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------|
| `environment`       | object                 | The environment to deploy to, as pulled from the environment.json lookup.                                        |                                                                                           |
| `tags`              | object                 | The tags to apply to the resources.                                                                             |                                                                                           |
| `name`              | string                 | The name of the SQL database.                                                                                   |                                                                                           |
| `sqlServerName`     | string                 | The name of the SQL server.                                                                                     |                                                                                           |
| `elasticPoolName`   | string?                | The name of the elastic pool to associate with the database (optional).                                         |                                                                                           |
| `computeSettings`   | ComputeSettingsType    | The compute settings for databases not included in an elastic pool (default = `{name: 'GP_S_Gen5', tier: 'GeneralPurpose', family: 'Gen5', capacity: 1, minCapacity: '0.5', autoPauseDelayMinutes: 60}`). | `{name: 'GP_S_Gen5', tier: 'GeneralPurpose', family: 'Gen5', capacity: 1, minCapacity: '0.5', autoPauseDelayMinutes: 60}` |
| `maxSizeGB`         | int                    | The maximum size of the database in GB (default = 1, min = 1).                                                   | `1`                                                                                       |
| `catalogCollation`  | string                 | The collation of the metadata catalog (default = `SQL_Latin1_General_CP1_CI_AS`).                               | `SQL_Latin1_General_CP1_CI_AS`                                                            |
| `collation`         | string                 | The collation of the database (default = `SQL_Latin1_General_CP1_CI_AS`).                                        | `SQL_Latin1_General_CP1_CI_AS`                                                            |

- **Resources**:

| Resource         | Type                                                          | Description                                             |
|------------------|---------------------------------------------------------------|---------------------------------------------------------|
| `sqlServer`      | `Microsoft.Sql/servers@2020-11-01-preview`                     | References the existing SQL server.                     |
| `elasticPool`    | `Microsoft.Sql/servers/elasticPools@2020-11-01-preview`        | References the existing elastic pool (if provided).     |
| `sqlDatabase`    | `Microsoft.Sql/servers/databases@2020-11-01-preview`           | Creates the SQL database.                                |

- **Outputs**:

| Name | Type   | Description                              |
|------|--------|------------------------------------------|
| `id` | string | The ID of the SQL database.             |
| `name` | string | The name of the SQL database.           |

#### `sn-sqlServer.bicep`
- **Description**: Defines a SQL server.
- **Types**:

| Type                | Definition                                                                                          |
|---------------------|-----------------------------------------------------------------------------------------------------|
| `ElasticPlan`       | Defines the properties of an elastic plan.                                                          |
|                     | ```json                                                                                             |
|                     | {                                                                                                   |
|                     |   "maxCapacity": "int",                                                                              |
|                     |   "maxDatabaseCapacity": "int"                                                                       |
|                     | }                                                                                                   |
|                     | ```                                                                                                 |

- **Parameters**:

| Name                     | Type          | Description                                                                                      | Default                                                                                       |
|--------------------------|---------------|--------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------|
| `environment`            | object        | The environment to deploy to, as pulled from the environment.json lookup.                          |                                                                                              |
| `tags`                   | object        | The tags to apply to the resources.                                                                 |                                                                                              |
| `name`                   | string        | The name of the resource.                                                                          |                                                                                              |
| `adminUsername`          | secure string | The admin username for the SQL server.                                                             |                                                                                              |
| `adminPassword`          | secure string | The admin password for the SQL server.                                                             |                                                                                              |
| `elasticPlans`           | ElasticPlan[] | The elastic plans to create.                                                                       | `[{"maxCapacity": 50, "maxDatabaseCapacity": 10}]`                                            |
| `logAnalyticsWorkspaceId`| string?       | The log analytics workspace ID to send audit logs to.                                              |                                                                                              |

- **Resources**:

| Resource               | Type                                                          | Description                                        |
|------------------------|---------------------------------------------------------------|----------------------------------------------------|
| `sqlServer`            | `Microsoft.Sql/servers@2020-11-01-preview`                     | Creates the SQL server.                              |
| `sqlServerLock`        | `Microsoft.Authorization/locks@2023-01-01-preview`              | Creates a lock on the SQL server.                    |
| `masterDatabase`       | `Microsoft.Sql/servers/databases@2020-11-01-preview` (existing) | Reads the master database.                            |
| `elasticPlan`          | `Microsoft.Sql/servers/elasticPools@2020-11-01-preview`        | Creates the elastic plan(s).                          |
| `elasticPlanLock`      | `Microsoft.Authorization/locks@2023-01-01-preview`              | Creates a lock on the elastic plan(s).                |
| `diagnosticSettings`   | `Microsoft.Insights/diagnosticSettings@2024-05-01-preview`      | Creates the destination for diagnostic audit logging. |
| `sqlAuditingSettings`  | `Microsoft.Sql/servers/auditingSettings@2020-11-01-preview`     | Creates the auditing settings.                         |

- **Outputs**:

| Name | Type   | Description                              |
|------|--------|------------------------------------------|
| `id` | string | The ID of the SQL server.               |
| `name` | string | The name of the SQL server.             |

#### `sn-storageAccount.bicep`
- **Description**: Defines a storage account.
- **Types**:

| Type              | Definition                                                                                         |
|-------------------|----------------------------------------------------------------------------------------------------|
| `BlobContainer`   | Defines the properties of a blob container.                                                        |
|                   | ```json                                                                                            |
|                   | {                                                                                                  |
|                   |   "name": "string",                                                                                 |
|                   |   "publicAccess": "Blob" \| "Container" \| "None"                                                   |
|                   | }                                                                                                  |
|                   | ```                                                                                                 |

- **Parameters**:

| Name                   | Type      | Description                                                                          | Default              | Allowed Values                          |
|------------------------|-----------|--------------------------------------------------------------------------------------|----------------------|------------------------------------------|
| `environment`          | object    | The environment to deploy to, as pulled from the environment.json lookup.            |                      |                                          |
| `tags`                 | object    | The tags to associate to the resources created. Each of the object's key/value properties become a tag. |                      |                                          |
| `name`                 | string    | The name of the resource.                                                            |                      |                                          |
| `sku`                  | string    | The SKU of the storage account (e.g., Standard_LRS, Standard_ZRS, Standard_GRS).       |                      |                                          |
| `publicNetworkAccess`  | bool      | Specifies if the storage account supports public network access (e.g., CDN).          |                      |                                          |
| `blobServiceProperties`| object?   | Properties for the blob service. See Azure documentation.                              |                      |                                          |
| `blobContainers`       | BlobContainer[] | An array of blob containers to create within the storage account.                          |                      |                                          |
| `managementPolicyRules`| array?    | The management policy rules. See Azure documentation.                                   |                      |                                          |
| `fileServiceProperties`| object?   | Properties for the file service. See Azure documentation.                              |                      |                                          |
| `fileShares`           | array     | An array of file shares to create within the storage account.                           |                      |                                          |
| `queueServiceProperties`| object?  | Properties for the queue service. See Azure documentation.                              |                      |                                          |
| `queues`               | array     | An array of queues to create within the storage account.                                |                      |                                          |
| `deleteLock`           | bool      | Add a delete lock to the storage account (default = false).                              | `false`               |                                          |

- **Resources**:

| Resource                   | Type                                                             | Description                                                                                     |
|----------------------------|------------------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| `storageAccount`           | `Microsoft.Storage/storageAccounts@2022-09-01`                    | Creates the storage account.                                                                     |
| `storageAccountLock`       | `Microsoft.Authorization/locks@2023-01-01-preview`                 | Creates a lock on the storage account.                                                           |
| `blobService`              | `Microsoft.Storage/storageAccounts/blobServices@2022-09-01`        | Creates the blob service.                                                                        |
| `blobContainerResources`   | `Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01` | Creates the blob containers.                                                                     |
| `lifecycleRules`           | `Microsoft.Storage/storageAccounts/managementPolicies@2021-04-01`  | Creates the management policy rules.                                                             |
| `fileServices`             | `Microsoft.Storage/storageAccounts/fileServices@2022-09-01`        | Creates the file services.                                                                        |
| `fileShareResources`       | `Microsoft.Storage/storageAccounts/fileServices/shares@2022-09-01` | Creates the file shares.                                                                         |
| `queueServices`            | `Microsoft.Storage/storageAccounts/queueServices@2022-09-01`       | Creates the queue services.                                                                       |
| `queueResources`           | `Microsoft.Storage/storageAccounts/queueServices/queues@2022-09-01` | Creates the queues.                                                                               |
| `keyVaultSecret`           | `Microsoft.KeyVault/vaults/secrets@2024-04-01`                     | Stores the connection string in the Key Vault.                                                   |

- **Outputs**:

| Name             | Type    | Description                                 |
|------------------|---------|---------------------------------------------|
| `id`             | string  | The ID of the storage account.               |
| `name`           | string  | The name of the storage account.             |
| `connectionString` | string | The connection string for the storage account. |

#### `sn-frontDoor.bicep`
- **Description**: Defines a complete Front Door configuration, including profiles, endpoints, origin groups, and routes.
- **Parameters**: See module for parameter definitions.
- **Resources**: Deploys Front Door profiles, endpoints, origin groups, routes, custom domains, and rules.
- **Outputs**: None.

#### `sn-cosmosDatabase.bicep`
- **Description**: Defines a Cosmos DB account and database configuration.
- **Parameters**: See module for parameter definitions.
- **Resources**: Creates Cosmos DB account, databases, and containers as specified.
- **Outputs**: None.

#### `sn-multi-shared-sqlserver.bicep`
- **Description**: Deploys multiple SQL servers for shared use across environments.
- **Parameters**: See module for parameter definitions.
- **Resources**: Creates SQL servers with configurations for multi-environment usage.
- **Outputs**: None.

#### `sn-multi-shared-signalR.bicep`
- **Description**: Deploys a SignalR service for shared real-time communication across applications.
- **Parameters**: See module for parameter definitions.
- **Resources**: Creates SignalR service instances and configurations.
- **Outputs**: None.