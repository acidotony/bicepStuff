param(
	[string]$Env 
    # = "dev2"
    ,
    [string]$LocationsList 
    # = "eastus2"
    ,
    [string]$GloballySharedResourceLocationList 
    # = "eastus2" ## Where our globally shared resources are deployed; will move to ;DEV:eastus2,westeurope,southeastasia; soon
    ,
    [string]$Subscription 
    # = "JCPLC-MSDN-001"
    ,
    [string]$ResourceGroup 
    # = "rg-selectionnavigator-dev2-001"
    ,
    [string]$AzureResourceScriptsDir = "..\Resource",
    [string]$LogDir = ".\Logs",
    [bool]$LoadExtensions = $true,
    [bool]$ShowDebug = $false
)  

## "Picks" a value from a set of filter criteria and returns the appropriate string
##   Expects the $Env variable to be correctly set correctly outside the function
##   Example input string: "4;DEV,QA:3;PROD:8" -- Means: a default of "4", unless the environment is DEV or QA (which will use a value of "3") or the environment is PROD (which will use a value of "8")
function P {
    param ($ValuesRule)
    
    $resultValue = ""
    $filters = $ValuesRule -split ";"
    $defaultValue = ($filters | Where-Object {-not($_.contains(":"))} | Select-Object -First 1 )
    if($defaultValue){
        $resultValue = $defaultValue
    }
    foreach ($filter in $filters) {
        if($filter.contains(":")){
            $parts = $filter -split ":"
            $envs = $parts[0] -split ","
            if($envs -contains $Env){
                $resultValue = $parts[1].Trim()
            }
        }
    }
    $resultValue
}

$ErrorActionPreference = "stop"

if(-not (Test-Path $LogDir)){
    New-Item -ItemType Directory -Force -Path $LogDir
}

$Env = $Env.ToLower()
if(-not $ResourceGroup){
    $ResourceGroup = "rg-selectionnavigator-$Env-001"
}

$selNavAzureAdminsAadGroup = "SelNav-Azure-Admins"
$selNavAzureAdminsAadGroupId = "e61b2bb8-a0ec-4425-8a21-0625047eab4f"

Write-Host "******************************************"
Write-Host "* Configuring SelNav Environment: $Env"
Write-Host "*   Locations: $LocationsList"
Write-Host "*   Globally Shared Resource Locations: $GloballySharedResourceLocationList"
Write-Host "*   Resource group: $ResourceGroup"
Write-Host "*   Subscription: $Subscription"
Write-Host "*   Resource Scripts folder: $AzureResourceScriptsDir"
Write-Host "*   Log folder: $LogDir"
Write-Host "******************************************"
Write-Host

#Short variable name for script path references
$resDir = $AzureResourceScriptsDir

. $resDir\AzCLI.ps1

az config set core.only_show_errors=true --only-show-errors

### Show information on current identity
az account show

$debugSuffix = ($ShowDebug) ? "--debug" : ""

if($LoadExtensions){
    ### Load Front Door extension
    Invoke-Expression -Command "az extension add --name front-door --allow-preview false $debugSuffix"; if($? -eq $false){ Throw "Error loading Front Door Azure CLI extension." }

    ### Load Application Insights extension
    Invoke-Expression -Command "az extension add --name application-insights --allow-preview false $debugSuffix"; if($? -eq $false){ Throw "Error loading App Insights Azure CLI extension." }

    ### Load Cosmos Db preview
    Invoke-Expression -Command "az extension add --name cosmosdb-preview --allow-preview true $debugSuffix"; if($? -eq $false){ Throw "Error loading Cosmos Db Preview extension." }

    ### Load Data Factory extension
    Invoke-Expression -Command "az extension add --name datafactory --allow-preview false $debugSuffix"; if(!$? -or $LASTEXITCODE -ne 0){ Throw "Error loading Data Factory Azure CLI extension." }
}
else{
    az config set extension.use_dynamic_install=yes_without_prompt
}

az version

### Set subscription
Write-Host "Setting Subscription: $Subscription"
$outputJson = az account set --subscription $Subscription ; if($? -eq $false){ Throw "Error setting Subscription to $Subscription" }
$outputJson | Set-Content (Join-Path $LogDir "output.$Subscription.json")
$output = $outputJson | ConvertFrom-Json

$subscriptionAbbr = $Subscription.Split("-")[1].ToLower()

### Get Front Door ID
$premiumFrontDoorResources = (Get-Content "afd-resources.json" | ConvertFrom-Json)
$premiumFrontDoor = $premiumFrontDoorResources."$Env"

$frontDoorIdTest = (P "$($premiumFrontDoor.frontDoorId);QA,SIT,PPE,PROD:")
$frontDoorId = "$($premiumFrontDoor.frontDoorId)"

Write-Host "Front Door ID (for apps testing network restrictions): $frontDoorIdTest"
Write-Host "Front Door ID: $frontDoorId"

#####################################
### SelNav Environment Definition ###
#####################################

#Locations as of 3/30/2020: centralus,eastus,eastus2,westus,northcentralus,southcentralus,westcentralus,westus2,northeurope,westeurope,eastasia,southeastasia,japanwest,japaneast,brazilsouth,australiaeast,australiasoutheast,southindia,centralindia,westindia,canadacentral,canadaeast,uksouth,ukwest,koreacentral,koreasouth,francecentral,francesouth,australiacentral,australiacentral2,uaecentral,uaenorth,southafricanorth,southafricawest,switzerlandnorth,switzerlandwest,germanynorth,germanywestcentral,norwaywest,norwayeast
$usOnlyLocationsList = $LocationsList
$usOnlyLocations = @($usOnlyLocationsList -split ",")
$worldwideLocations = @("eastus2","westeurope","southeastasia")
$globalResourceLocations = @($GloballySharedResourceLocationList -split ",")

# Determine the associated shared resource group
$sharedResourceGroup = "rg-selectionnavigator-shared-$subscriptionAbbr-001"

$adfsCreated = @{}
$appsCreated = @{}
$databasesCreated = @{}
$azureOutput = @{}

### Apply permissions to Resource Group
$envResourceGroupRBAC = @(
    @{ AADGroupList = "SelNav-Azure-Admins"; RolesList = "Azure Service Bus Data Owner"},
    @{ AADGroupList = "SelNav-Azure-Cdb-Admin"; RolesList = "DocumentDB Account Contributor"},
    @{ AADGroupList = "SelNav-Azure-DevOps-Admins"; RolesList = "Contributor,Storage Table Data Contributor,Storage Queue Data Contributor,Storage Blob Data Owner,Cosmos DB Account Reader Role,Cost Management Contributor,Azure Service Bus Data Sender,Azure Service Bus Data Receiver"},
    @{ AADGroupList = "SelNav-Azure-Reader"; RolesList = "Application Insights Snapshot Debugger,Monitoring Reader,Workbook Contributor,Reader,SelNav SQL DB Recommendations Reader"},
    @{ AADGroupList = "SelNav-Azure-Reader"; RolesList = "Storage Table Data Reader,Storage Blob Data Reader,Storage Queue Data Reader,Search Index Data Reader,Azure Service Bus Data Receiver"; EnvFilterList = "dev2,dev,qa,sit,ppe"},
    @{ AADGroupList = "SelNav-Azure-Reader"; RolesList = "Storage Table Data Contributor,Storage Queue Data Contributor,Storage Blob Data Contributor,SQL DB Contributor,Application Insights Component Contributor,Azure Service Bus Data Sender"; EnvFilterList = "dev2,dev,qa"},
    @{ AADGroupList = "SelNav-Azure-AppDev-Core"; RolesList = "Cosmos DB Account Reader Role"; EnvFilterList = "dev2,dev,qa"},
    @{ AADGroupList = "SelNav-Azure-AppDev-All"; RolesList = "DocumentDB Account Contributor"; EnvFilterList = "dev2,dev,qa"},
    @{ AADGroupList = "SelNav-Azure-AppDev-All"; RolesList = "Cosmos DB Account Reader Role"; EnvFilterList = "sit,ppe,prod"}
)
$rgScope = az group show --name $ResourceGroup --query id | ConvertFrom-Json; if(-not $rgScope){ Throw "Error showing resource group info." }
&$resDir\grant-scope-rbac-access.ps1 -Scope $rgScope -RBACPermissions $envResourceGroupRBAC -Env $Env -LogDir $LogDir

### Tags for use across Selection Navigator resources

$sharedTags = @( @{ Name = "SNCostCategory"; Value = "Shared"})
$coreTags = @( @{ Name = "SNCostCategory"; Value = "Core"})
$docGenTags = @( @{ Name = "SNCostCategory"; Value = "DocGen"})
$edgeTags = @( @{ Name = "SNCostCategory"; Value = "Edge"})
$sysControlsTags = @( @{ Name = "SNCostCategory"; Value = "SysControls"})
$chillersTags = @( @{ Name = "SNCostCategory"; Value = "Chillers"})
$ahuTags = @( @{ Name = "SNCostCategory"; Value = "AHU"})
$appliedTags = @( @{ Name = "SNCostCategory"; Value = "Applied"})

#######################
# Environment network #
#######################

$usOnlyLocationOrdinals = @(@{Location = "eastus2"; Ordinal = 0})
$networkData = @()
$nsgIndex = 001
&$resDir\create-sn-vnet.ps1 -Env $Env -LocationOrdinals $usOnlyLocationOrdinals -BaseAddressRange "172.16.0.0/16" -AdditionalAddressRanges @("172.31.1.0/24") -SuffixNum 1 -NetworkData ([ref]$networkData) -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
foreach($loc in $usOnlyLocations){

    # Create Network Security Groups
    $nsg1Rules = @(
        #@{ Name = "DenyInternetOutbound"; Description = "Deny all outbound internet traffic."; Priority = "1000"; Access = "Deny"; Direction = "Outbound"; Protocol = "*"; DestinationAddressPrefix = "Internet"; DestinationPortRanges = "*" }
    )
    &$resDir\create-sn-nsg.ps1 -ResourceGroup $ResourceGroup -Env $Env -Location $loc -SuffixNum $nsgIndex -Rules $nsg1Rules -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir

    # Create NAT Gateway
    $natgIndex = 001
    &$resDir\create-sn-natg.ps1 -ResourceGroup $ResourceGroup -Env $Env -Location $loc -NetworkData $networkData -SuffixNum $natgIndex -IpCount (P "1;PROD:2") -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir

    # Create the services subnet for regional services
    $servicesSubNetName = "services"
    &$resDir\create-sn-subnet.ps1 -Name $servicesSubNetName -Env $Env -Location $loc -AddressRange "x.x.0.0/24" -NetworkData $networkData -NsgSuffixNum $nsgIndex -AzureData $azureOutput -LogDir $LogDir
}

# Create the Private endpoint zones
&$resDir\create-sn-pdz.ps1 -ResourceGroup $ResourceGroup -Name "privatelink.database.windows.net" -NetworkData $networkData -Tags $sharedTags
&$resDir\create-sn-pdz.ps1 -ResourceGroup $ResourceGroup -Name "privatelink.documents.azure.com" -NetworkData $networkData -Tags $sharedTags
&$resDir\create-sn-pdz.ps1 -ResourceGroup $ResourceGroup -Name "privatelink.vaultcore.azure.net" -NetworkData $networkData -Tags $sharedTags
&$resDir\create-sn-pdz.ps1 -ResourceGroup $ResourceGroup -Name "privatelink.blob.core.windows.net" -NetworkData $networkData -Tags $sharedTags
&$resDir\create-sn-pdz.ps1 -ResourceGroup $ResourceGroup -Name "privatelink.table.core.windows.net" -NetworkData $networkData -Tags $sharedTags
&$resDir\create-sn-pdz.ps1 -ResourceGroup $ResourceGroup -Name "privatelink.queue.core.windows.net" -NetworkData $networkData -Tags $sharedTags
&$resDir\create-sn-pdz.ps1 -ResourceGroup $ResourceGroup -Name "privatelink.file.core.windows.net" -NetworkData $networkData -Tags $sharedTags
&$resDir\create-sn-pdz.ps1 -ResourceGroup $ResourceGroup -Name "privatelink.search.windows.net" -NetworkData $networkData -Tags $sharedTags
&$resDir\create-sn-pdz.ps1 -ResourceGroup $ResourceGroup -Name "privatelink.service.signalr.net" -NetworkData $networkData -Tags $sharedTags
#&$resDir\create-sn-pdz.ps1 -ResourceGroup $ResourceGroup -Name "privatelink.datafactory.azure.net" -NetworkData $networkData -Tags $sharedTags
#&$resDir\create-sn-pdz.ps1 -ResourceGroup $ResourceGroup -Name "privatelink.adf.azure.com" -NetworkData $networkData -Tags $sharedTags

###########################
# Log Analytics Workspace #
###########################

# Create the name to lookup
$logAnalyticsWorkspaceName = "law-sn-msdn-001"
if($Subscription -like "*PROD*") { $logAnalyticsWorkspaceName = "law-sn-prod-001" }

# Read the Log Analytics Workspace
$outputJson = az monitor log-analytics workspace show --resource-group $sharedResourceGroup --workspace-name $logAnalyticsWorkspaceName
$outputJson | Set-Content (Join-Path $LogDir "output.$logAnalyticsWorkspaceName.json")
$lawData = $outputJson | ConvertFrom-Json
$logAnalyticsWorkspaceId = $lawData.id
$azureOutput.Add("logAnalyticsWorkSpace", $lawData)

#############
# Key Vault #
#############

# Create private endpoints
$keyVaultName = "kv-sn-$Env-001"
foreach($network in $networkData){
    $vnetName = $network.VNetName
    $loc = $network.Location

    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $loc -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $keyVaultName -PrivateLinkResourceType "Microsoft.KeyVault/vaults" -GroupId "vault" -PrivateDnsZone "privatelink.vaultcore.azure.net" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir 
}

############################
# Security Storage Account #
############################

## Security storage account
$securityBlobContainers =@(
    @{Name="securityv2"; PubAccess="off"}
)
$securityStorageName = "stselnav$Env"
&$resDir\create-sn-st.ps1 -StorageName $securityStorageName -StorageSku "Standard_GRS" -EnableSoftDelete $true -SoftDeleteRetentionDays 30 -Env $Env -Location "eastus2" -AppAbbr "" -FileShareList $sharedFileLocationFileShareList -BlobContainers $sharedFileLocationBlobContainers -AllowForContainerLevelPublicAccessEnablement $false -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir

# Create private endpoints
foreach($network in $networkData){
    $vnetName = $network.VNetName
    $peName = "$($vnetName.Replace("vnet","pe"))-$securityStorageName"
    $loc = $network.Location

    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $loc -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $securityStorageName -Name "$peName-blob" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "blob" -PrivateDnsZone "privatelink.blob.core.windows.net" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir 
}     

############################
# Item Storage Account(s) #
############################

## Item storage account
$itemBlobContainers =@(
    @{Name="tenant-1"; PubAccess="off"},
    @{Name="tenant1"; PubAccess="off"},
    @{Name="tenant2"; PubAccess="off"},
    @{Name="tenant3"; PubAccess="off"},
    @{Name="tenant4"; PubAccess="off"},
    @{Name="backup-item"; PubAccess="off"},
    @{Name="backup-itemdetail"; PubAccess="off"},
    @{Name="backup-itemrelationship"; PubAccess="off"}
)

## Define the storage account names and address ranges
$itemStorageAccounts = @{
    eastus2 = @{Name="stsn$($Env)itemeastus2"; AccountCreated=$false; Id = "";}
    westeurope = @{Name="stsn$($Env)itemwesteurope"; AccountCreated=$false; Id = "";}
    southeastasia = @{Name="stsn$($Env)itemsoutheastasia"; AccountCreated=$false; Id = "";}
}

## Define the management policies for the item storage accounts
$itemAccountManagementPolicies = @(
    @{name="ReferenceLifecycle"; type="Lifecycle"; enabled=$true; definition=@{
        actions=@{
            baseBlob=@{tierToCool=@{daysAfterModificationGreaterThan=90}; tierToCold=@{daysAfterModificationGreaterThan=180};};
            version=@{tierToCold=@{daysAfterCreationGreaterThan=0}; delete=@{daysAfterCreationGreaterThan=(P "14;PROD:90")};};
        }; 
        filters=@{
            blobTypes=@("blockBlob");
            prefixMatch=@("tenant0/","tenant1/","tenant2/","tenant3/","tenant4/")
        };
    };},
    @{name="BackupLifecycle"; type="Lifecycle"; enabled=$true; definition=@{
        actions=@{
            baseBlob=@{tierToCool=@{daysAfterModificationGreaterThan=90}; tierToCold=@{daysAfterModificationGreaterThan=180};};
            version=@{tierToCold=@{daysAfterCreationGreaterThan=0}; delete=@{daysAfterCreationGreaterThan=(P "14;PROD:90")};};
        }; 
        filters=@{
            blobTypes=@("blockBlob");
            prefixMatch=@("backup-item/","backup-itemdetail/","backup-itemrelationship/")
        };
    };}
)

## For the non-prod versions remove the tierToCold action from the version policy
if($Env -ne "prod"){
    foreach($policy in $itemAccountManagementPolicies){
        if($policy.definition.actions.version){
            $policy.definition.actions.version.Remove("tierToCold")
        }
    }
}

## Create storage accounts in each region
foreach($location in $globalResourceLocations) {
    $itemStorageAccount = $itemStorageAccounts[$location]
    &$resDir\create-sn-st.ps1 -StorageName $itemStorageAccount.Name -Env $Env -Location $location -AppAbbr "item" -StorageSku "Standard_GRS" -EnablePointInTimeRestore $true -SoftDeleteRetentionDays (P "15;PROD:91") -ChangeFeedRetentionDays (P "15;PROD:91") -PointInTimeRetentionDays (P "14;PROD:90") -ManagementPolicyRules $itemAccountManagementPolicies -AllowForContainerLevelPublicAccessEnablement $false -BlobContainers $itemBlobContainers -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
    $itemStorageAccount.Id = $azureOutput."st-item$location".id
    $itemStorageAccount.AccountCreated = $true
}

# Create private endpoints for each region
foreach($network in $networkData){

    ## Create a private endpoint for each individual storage account
    foreach($itemStorageAccount in $itemStorageAccounts.GetEnumerator()) {
        
        ## if we created the storage account, then create the private endpoint
        if($itemStorageAccount.Value.AccountCreated){

            $vnetName = $network.VNetName          
            $loc = $itemStorageAccount.Key  ## Place the PE in the region of the resource not the network
            $peName = "$($vnetName.Replace("vnet","pe"))-$($itemStorageAccount.Value.Name)"

            &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $loc -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $itemStorageAccount.Value.Name -Name "$peName-blob" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "blob" -PrivateDnsZone "privatelink.blob.core.windows.net" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir 
        }
    }
}

#############
# Cosmos DB #
#############

### Access list for global access to Cosmos Db
$cdbAccessList = @()

### Create Cosmos Db Account for the environment
$cdbFarmNum = 1
&$resDir\create-sn-cdb-acct.ps1 -ServerFarmNum $cdbFarmNum -Env $Env -Locations $usOnlyLocations -ResourceGroup $ResourceGroup -Tags $coreTags -AzureData $azureOutput -LogDir $LogDir -BackupInterval 1440 -BackupRetention (P "48;PROD:168")  ## 1 day backup interval, 2 days retention for lower, 7 days retention for prod
$cosmosDbAccount1Name = $azureOutput."cdb-$cdbFarmNum".name
&$resDir\create-sn-cdb-role.ps1 -AccountName $cosmosDbAccount1Name -RoleName "Read Metadata" -Scope "/" -Permissions @("Microsoft.DocumentDB/databaseAccounts/readMetadata") -ResourceGroup $ResourceGroup -AzureData $azureOutput -LogDir $LogDir
Write-Host " Created/checked CosmosDb account: $cosmosDbAccount1Name"

$cdbAccessList += @{AccountName = $cosmosDbAccount1Name; Scope = "/";  Role = "Read Metadata"; AADGroupList = "SelNav-Azure-Reader";}
$cdbAccessList += @{AccountName = $cosmosDbAccount1Name; Scope = "/";  Role = "Cosmos DB Built-in Data Contributor"; AADGroupList = "SelNav-Azure-Admins,SelNav-Azure-Cdb-Admin";}
$cdbAccessList += @{AccountName = $cosmosDbAccount1Name; Scope = "/"; Role = "Cosmos DB Built-in Data Reader"; EnvFilterList = "dev2,dev,qa";  AADGroupList = "SelNav-Azure-AppDev-All";}

### Create private endpoint on the environment network
foreach($network in $networkData){
    $vnetName = $network.VNetName
    $loc = $network.Location

    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $loc -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $cosmosDbAccount1Name -PrivateLinkResourceType "Microsoft.DocumentDB/databaseAccounts" -GroupId "Sql" -PrivateDnsZone "privatelink.documents.azure.com" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
}

### Create Cosmos Db SharedServices Database for the environment
$sharedservicesDatabaseName = "SharedServices"
$cosmosDbContainers = @(
    @{ContainerName="Cache"; PartitionKey="/pk"; TTL=86400;},
    @{ContainerName="Entitlement"; PartitionKey="/pk"; TTL=(P "172800;PROD:604800");},
    @{ContainerName="Preference"; PartitionKey="/pk"; TTL=(P "172800;PROD:604800");},
    @{ContainerName="Session"; PartitionKey="/pk"; TTL=(P "172800;PROD:604800");},
    @{ContainerName="UserSetting"; PartitionKey="/pk"; TTL=-1;},
    @{ContainerName="Configuration"; PartitionKey="/pk"; TTL=-1;},
    @{ContainerName="ApplicationCache"; PartitionKey="/pk"; TTL=-1;}
    ##@{ContainerName="LaborRate"; PartitionKey="/pk"; TTL=-1;}
)
&$resDir\create-sn-cdb-db.ps1 -AccountName $cosmosDbAccount1Name -DatabaseName $sharedservicesDatabaseName -Containers $cosmosDbContainers -Throughput 0 -MaxThroughput (P "4000;PROD:10000") -ResourceGroup $ResourceGroup -AzureData $azureOutput -LogDir $LogDir
&$resDir\create-sn-cdb-role.ps1 -AccountName $cosmosDbAccount1Name -RoleName "$sharedservicesDatabaseName Read Write Role" -Scope "/dbs/$sharedservicesDatabaseName" -Permissions @("Microsoft.DocumentDB/databaseAccounts/readMetadata","Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/*","Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/*") -ResourceGroup $ResourceGroup -AzureData $azureOutput -LogDir $LogDir
#$cdbAccessList += @{AccountName = $cosmosDbAccount1Name; Scope = "/dbs/$sharedservicesDatabaseName"; Role = "$sharedservicesDatabaseName Read Write Role"; AADGroupList = "SelNav-Azure-Team-Gladiators";}
#$cdbAccessList += @{AccountName = $cosmosDbAccount1Name; Scope = "/dbs/$sharedservicesDatabaseName"; Role = "$sharedservicesDatabaseName Read Write Role"; EnvFilterList = "dev2,dev,qa";  AADGroupList = "SelNav-Azure-AppDev-All";}
Write-Host " Created/checked CosmosDb database: $sharedservicesDatabaseName"

### Create Cosmos Db Item Database for the environment
$itemDatabaseName = "Item"
$itemDbContainers = @(
    @{ContainerName="Item"; PartitionKey="/pk"; TTL=$null;},
    @{ContainerName="ItemDetail"; PartitionKey="/pk"; TTL=$null;},
    @{ContainerName="ItemRelationship"; PartitionKey="/pk"; TTL=$null;}
)
&$resDir\create-sn-cdb-db.ps1 -AccountName $cosmosDbAccount1Name -DatabaseName $itemDatabaseName -Containers $itemDbContainers -Throughput 0 -MaxThroughput (P "10000;PROD:10000") -ResourceGroup $ResourceGroup -AzureData $azureOutput -LogDir $LogDir
&$resDir\create-sn-cdb-role.ps1 -AccountName $cosmosDbAccount1Name -RoleName "$itemDatabaseName Read Write Role" -Scope "/dbs/$itemDatabaseName" -Permissions @("Microsoft.DocumentDB/databaseAccounts/readMetadata","Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/*","Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/*") -ResourceGroup $ResourceGroup -AzureData $azureOutput -LogDir $LogDir
#$cdbAccessList += @{AccountName = $cosmosDbAccount1Name; Scope = "/dbs/$itemDatabaseName"; Role = "$itemDatabaseName Read Write Role"; AADGroupList = "SelNav-Azure-Team-Gladiators";}
#$cdbAccessList += @{AccountName = $cosmosDbAccount1Name; Scope = "/dbs/$itemDatabaseName"; Role = "$itemDatabaseName Read Write Role"; EnvFilterList = "dev2,dev,qa";  AADGroupList = "SelNav-Azure-AppDev-All";}
Write-Host " Created/checked CosmosDb database: $itemDatabaseName"

## Grant global accesses to Cosmos Db
&$resDir\grant-apps-cdb-access.ps1 -ResourceGroup $ResourceGroup -AccessList $cdbAccessList -Env $Env -LogDir $LogDir

#############
# SignalR #
#############

### Create Signal R service for the environment
&$resDir\create-sn-srs.ps1 -Env $Env -Locations $usOnlyLocations -Sku (P "Standard_S1;PROD:Premium_P1") -Tags $coreTags -AzureData $azureOutput -LogDir $LogDir `
    -MinCount 1 -MaxCount 100 -Count 1 -ScaleOutCount 1 -ScaleOutCondition "ConnectionQuotaUtilization > 80 avg 5m" `
    -ScaleInCount 1 -ScaleInCondition "ConnectionQuotaUtilization < 30 avg 5m"

## Read all signalr instances 
$signalRNames = @()
foreach($location in $usOnlyLocations) {

    $signalRName = $azureOutput."srs-$location".name
    $signalRNames += $signalRName

    ## Create private endpoint on the environment network
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $signalRName -PrivateLinkResourceType "Microsoft.SignalRService/SignalR" -GroupId "signalr" -PrivateDnsZone "privatelink.service.signalr.net" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
    
    # ToDo: automate only allowing the sn private network access to the server request and the sn/jci for dev
}

#####################
# App Service Plans #
#####################
### Guidance on controlling density in ASPs: https://docs.microsoft.com/en-us/archive/msdn-magazine/2017/february/azure-inside-the-azure-app-service-architecture#controlling-density

### 001 - First set of App Service Plans for the environment
###   Ordering apps + Smaller Core apps
$aspPool1Names = @{} 
$aspPool1MinAppInstances = [int](P "1;QA,PROD:2")
&$resDir\create-sn-asp.ps1 -Env $Env -Locations $usOnlyLocations -Sku P2V3 -ServerFarmNum 1 -ASPResourceNameByLocation $aspPool1Names -NetworkData $networkData -NsgSuffixNum $nsgIndex -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir `
    -EnableAutoscale $true -MaxAutoscaleBurstCount 20
    # -MinCount 2 -MaxCount 8 -Count 2 -ScaleOutCount 2 -ScaleOutCondition "CpuPercentage > 60 avg 5m" `
    # -ScaleInCount 2 -ScaleInCondition "CpuPercentage < 25 avg 5m"
Write-Host " Created ASP #1 (used by Ordering apps + Smaller Core apps):"
$aspPool1Names

### 002 - Second set of App Service Plans for the environment
###   Used by AHU rater apps
$aspPool2Names = @{}
$aspPool2MinAppInstances = [int](P "1;QA,PROD:2")
&$resDir\create-sn-asp.ps1 -Env $Env -Locations $usOnlyLocations -Sku P2V3 -ServerFarmNum 2 -ASPResourceNameByLocation $aspPool2Names -NetworkData $networkData -NsgSuffixNum $nsgIndex -Tags $ahuTags -AzureData $azureOutput -LogDir $LogDir `
    -EnableAutoscale $true -MaxAutoscaleBurstCount 20
    # -MinCount 2 -MaxCount 8 -Count 2 -ScaleOutCount 2 -ScaleOutCondition "CpuPercentage > 60 avg 5m" `
    # -ScaleInCount 2 -ScaleInCondition "CpuPercentage < 25 avg 5m"
Write-Host " Created ASP #2 (for AHU rater apps):"
$aspPool2Names

### 003 - Third App Service Plan for the environment
###   Used by Controls apps
$aspPool3Names = @{}
$aspPool3MinAppInstances = [int](P "1;QA,PROD:2")
&$resDir\create-sn-asp.ps1 -Env $Env -Locations $usOnlyLocations -Sku P2V3 -ServerFarmNum 3 -ASPResourceNameByLocation $aspPool3Names -NetworkData $networkData -NsgSuffixNum $nsgIndex -Tags $sysControlsTags -AzureData $azureOutput -LogDir $LogDir `
    -EnableAutoscale $true -MaxAutoscaleBurstCount 20
    # -MinCount (P "1;PPE,PROD:2") -MaxCount (P "3;PPE,PROD:8") -Count 2 -ScaleOutCount 2 -ScaleOutCondition "CpuPercentage > 60 avg 5m" `
    # -ScaleInCount 2 -ScaleInCondition "CpuPercentage < 25 avg 5m"
Write-Host " Created ASP #3 (for Controls apps):"
$aspPool3Names

### 004 - Fourth App Service Plan for the environment
###   Used by Chillers apps
$aspPool4Names = @{}
$aspPool4MinAppInstances = [int](P "1;QA,PROD:2")
&$resDir\create-sn-asp.ps1 -Env $Env -Locations $usOnlyLocations -Sku P2V3 -ServerFarmNum 4 -ASPResourceNameByLocation $aspPool4Names -NetworkData $networkData -NsgSuffixNum $nsgIndex -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir `
    -EnableAutoscale $true -MaxAutoscaleBurstCount 20
    # `
    # -MinCount 2 -MaxCount 12 -Count 2 -ScaleOutCount 2 -ScaleOutCondition "CpuPercentage > 60 max 3m" `
    # -ScaleInCount 2 -ScaleInCondition "CpuPercentage < 25 avg 5m"
Write-Host " Created ASP #4 (for Chillers apps):"
$aspPool4Names

### 005 - Fifth App Service Plan for the environment
### Used by Core apps
$aspPool5Names = @{}
$aspPool5MinAppInstances = [int](P "1;QA,PROD:2")
&$resDir\create-sn-asp.ps1 -Env $Env -Locations $usOnlyLocations -Sku P2V3 -ServerFarmNum 5 -ASPResourceNameByLocation $aspPool5Names -NetworkData $networkData -NsgSuffixNum $nsgIndex -Tags $coreTags -AzureData $azureOutput -LogDir $LogDir `
    -EnableAutoscale $true -MaxAutoscaleBurstCount 20
    #-MinCount 2 -MaxCount 10 -Count 2 -ScaleOutCount 2 -ScaleOutCondition "CpuPercentage > 60 avg 5m" `
    #-ScaleInCount 2 -ScaleInCondition "CpuPercentage < 25 avg 5m"
Write-Host " Created ASP #5 (for Core apps):"
$aspPool5Names

### 006 - Sixth App Service Plan for the environment
### Used by Applied apps + AHU Score
$aspPool6Names = @{}
$aspPool6MinAppInstances = [int](P "1;QA,PROD:2")
&$resDir\create-sn-asp.ps1 -Env $Env -Locations $usOnlyLocations -Sku P2V3 -ServerFarmNum 6 -ASPResourceNameByLocation $aspPool6Names -NetworkData $networkData -NsgSuffixNum $nsgIndex -Tags $coreTags -AzureData $azureOutput -LogDir $LogDir `
    -EnableAutoscale $true -MaxAutoscaleBurstCount 20
    #-MinCount 2 -MaxCount 10 -Count 2 -ScaleOutCount 2 -ScaleOutCondition "CpuPercentage > 60 avg 5m" `
    #-ScaleInCount 2 -ScaleInCondition "CpuPercentage < 25 avg 5m"
Write-Host " Created ASP #6 (for Applied apps + AHU Score):"
$aspPool6Names

$subscriptionRelay = "relay-sn-$subscriptionAbbr"
$smtpHybridConnection = @{Name = "$subscriptionRelay-smtp-cg-jci-com-25"; Relay = $subscriptionRelay}

### Loop through each of the locations
foreach($location in $usOnlyLocations) {
    $dbAccessList = @()
    $fnAccessList = @()
    $cdbAccessList = @()
    $storageAccessList = @()
    $searchServiceAccessList = @()
    $sbAccessList = @()
    $ehAccessList = @()
    $srsAccessList =@()
    
    $aspPool1Name = $aspPool1Names."$location"
    $aspPool2Name = $aspPool2Names."$location"
    $aspPool3Name = $aspPool3Names."$location"
    $aspPool4Name = $aspPool4Names."$location"
    $aspPool5Name = $aspPool5Names."$location"
    $aspPool6Name = $aspPool6Names."$location"
    $vnetName = "vnet-sn-$Env-$location-001"

    ######################################
    # Elastic Function App Service Plans #
    ######################################

    ### First Function App Service Plan for Chillers Functions
    $aspFnPool1MinAppInstances = [int](P "2;PROD:4")
    &$resDir\create-sn-asp-fn.ps1 -Env $Env -Location $location -Sku EP3 -ServerFarmNum 1 -MaxBurst 100 -NetworkData $networkData -NsgSuffixNum $nsgIndex  -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    $aspFnPool1Name = $azureOutput."asp-fn-$location-1".name
    Write-Host " Created Elastic Function ASP for Chillers Function apps: $aspFnPool1Name"

    ### Second Function App Service Plan for Chillers Durable Functions
    $aspFnPool2MinAppInstances = [int](P "1;DEV2,DEV,PROD:2")
    &$resDir\create-sn-asp-fn.ps1 -Env $Env -Location $location -Sku EP3 -ServerFarmNum 2 -MaxBurst 100 -NetworkData $networkData -NsgSuffixNum $nsgIndex  -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    $aspFnPool2Name = $azureOutput."asp-fn-$location-2".name
    Write-Host " Created Elastic Function ASP for Chillers Function apps: $aspFnPool2Name"

    ### Third Function App Service Plan for the environment
    ### For AHU rater Function apps
    $aspFnPool3MinAppInstances = [int](P "1;DEV2,DEV:2;SIT,PROD:10")
    &$resDir\create-sn-asp-fn.ps1 -Env $Env -Location $location -Sku EP2 -ServerFarmNum 3 -MaxBurst 50 -NetworkData $networkData -NsgSuffixNum $nsgIndex  -Tags $ahuTags -AzureData $azureOutput -LogDir $LogDir
    $ahuFnPoolName = $azureOutput."asp-fn-$location-3".name
    Write-Host " Created Elastic Function ASP for AHU Function apps: $ahuFnPoolName"

    ### Fourth Function App Service Plan for the environment
    ### For Platform & SysControls Function apps
    $aspFnPool4MinAppInstances = [int](P "1;DEV2,DEV,PROD:2")
    &$resDir\create-sn-asp-fn.ps1 -Env $Env -Location $location -Sku EP2 -ServerFarmNum 4 -MaxBurst 100 -NetworkData $networkData -NsgSuffixNum $nsgIndex  -Tags $sysControlsTags -AzureData $azureOutput -LogDir $LogDir
    $coreSysControlsFnPoolName = $azureOutput."asp-fn-$location-4".name
    Write-Host " Created Elastic Function ASP for SysControls Function apps: $coreSysControlsFnPoolName"

    ### Fifth Function App Service Plan for the DXChill Chillers Function
    $aspFnPool5MinAppInstances = [int](P "2;PROD:4")
    &$resDir\create-sn-asp-fn.ps1 -Env $Env -Location $location -Sku EP3 -ServerFarmNum 5 -MaxBurst 100 -NetworkData $networkData -NsgSuffixNum $nsgIndex  -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    $aspFnPool5Name = $azureOutput."asp-fn-$location-5".name
    Write-Host " Created Elastic Function ASP for DXChill Chillers Function app: $aspFnPool5Name"

    ##############
    # SQL Server #
    ##############

    ### Create SQL Server for the environment
    &$resDir\create-sn-sql-svr.ps1 -Env $Env -Location $location -ServerFarmNum 1 -ADAdminGroupName "SelNav-Azure-Db-Admin" -ADAdminGroupObjectId "384b38cc-3c77-4c43-9418-0dbc9bdc86fa" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
    $sqlServer1Name = $azureOutput.sqlServer.name
    Write-Host " Created/checked SQL Server: $sqlServer1Name"

    ### Create SQL Elastic Pool for the SQL Server
    $elasticPool1DTUSize = (P "400;PROD:800")
    $maxDatabaseDtuAllowed = (P "300;PROD:400")
    &$resDir\create-sn-sql-ep.ps1 -Env $Env -Location $location -ElasticPoolNum 1 -SqlServerName $sqlServer1Name -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir -CLIOptions " --capacity $elasticPool1DTUSize --db-dtu-max $maxDatabaseDtuAllowed --edition Standard --max-size 500GB"
    $elasticPool1Name = $azureOutput."sqlElasticPool-1".name
    Write-Host " Created SQL Elastic Pool: $elasticPool1Name"

    ### Create private endpoint on the environment network
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $sqlServer1Name -PrivateLinkResourceType "Microsoft.Sql/servers" -GroupId "sqlserver" -PrivateDnsZone "privatelink.database.windows.net" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir

    # ### Create SQL Elastic Pool for Estimating
    # &$resDir\create-sn-sql-ep.ps1 -Env $Env -Location $location -ElasticPoolNum 2 -SqlServerName $sqlServer1Name -AzureData $azureOutput -LogDir $LogDir -CLIOptions "--edition GeneralPurpose --family Gen5 --capacity 12 --min-capacity 1.5 --compute-model Serverless --max-size 2TB --auto-pause-delay 120"
    # $coreElasticPoolName = $azureOutput."sqlElasticPool-core".name
    # Write-Host " Created core SQL Elastic Pool: $coreElasticPoolName"

    ####################
    # Shared Resources #
    ####################
    
    ### Cloud Shared File Locations for use with the Shared.Utilities.FileStorage SDK
    $sharedFileLocationBlobContainers = @(
        @{Name="ahudebuglogs"; PubAccess="off"; Clean=$true},
        @{Name="aomsorders"; PubAccess="off"; Clean=$true},
        @{Name="appliedequipmentorderpackages"; PubAccess="off"; Clean=$true},
        @{Name="applieddxdrawings"; PubAccess="off"; Clean=$false},
        @{Name="applieddxtemporaryfiles"; PubAccess="off"; Clean=$true},
        @{Name="applieddxvtz"; PubAccess="off"; Clean=$false},
        @{Name="chillersoutput"; PubAccess="off"; Clean=$true},
        @{Name="controlscbs"; PubAccess="off"; Clean=$true},
        @{Name="docgentemplates"; PubAccess="off"; Clean=$false},
        @{Name="documentdownload"; PubAccess="off"; Clean=$true},
        @{Name="documentgeneration"; PubAccess="off"; Clean=$true},
        @{Name="documentrenderingservice"; PubAccess="off"; Clean=$true},
        @{Name="ahuorderingservices"; PubAccess="off"; Clean=$true},
        @{Name="equipmentcbs"; PubAccess="off"; Clean=$true},
        @{Name="fpcdocgen"; PubAccess="off"; Clean=$true},
        @{Name="gryphonrpdata"; PubAccess="off"; Clean=$false},
        @{Name="modelgrouptemplates"; PubAccess="off"; Clean=$false},
        @{Name="sessiontemporaryfiles"; PubAccess="off"; Clean=$true},
        @{Name="sessiondatasnapshots"; PubAccess="off"; Clean=$false},
        @{Name="slidingbtp"; PubAccess="off"; Clean=$true},
        @{Name="specialrequests"; PubAccess="off"; Clean=$true},
        @{Name="sstgeneration"; PubAccess="off"; Clean=$true},
        @{Name="systemversionmanifests"; PubAccess="off"; Clean=$false},
        @{Name="transientdocumentrepository"; PubAccess="off"; Clean=$true},
        @{Name="excelgeneration"; PubAccess="off"; Clean=$true}
    )
    $sharedFileLocationFileShareList = ""
    $sharedFileLocationQueueList  = "" ##= "gry-nameplate"
    $sharedFileLocationBlobContainerNameList = ($sharedFileLocationBlobContainers | Where-Object { $_.Clean -eq $true } | ForEach-Object {$_.Name}) -join ","

    ### Create shared Storage account for the environment
    &$resDir\create-sn-st.ps1 -Env $Env -Location $location -AppAbbr "" -QueueList $sharedFileLocationQueueList -FileShareList $sharedFileLocationFileShareList -BlobContainers $sharedFileLocationBlobContainers -AllowForContainerLevelPublicAccessEnablement $false -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
    $sharedStorageId = $azureOutput."st-$location".id
    $sharedStorageName = $azureOutput."st-$location".name
    $peName = "$($vnetName.Replace("vnet","pe"))-$sharedStorageName"
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $sharedStorageName -Name "$peName-blob" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "blob" -PrivateDnsZone "privatelink.blob.core.windows.net" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $sharedStorageName -Name "$peName-table" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "table" -PrivateDnsZone "privatelink.table.core.windows.net" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $sharedStorageName -Name "$peName-queue" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "queue" -PrivateDnsZone "privatelink.queue.core.windows.net" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $sharedStorageName -Name "$peName-file" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "file" -PrivateDnsZone "privatelink.file.core.windows.net" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
    Write-Host " Created shared Storage: $sharedStorageName"

    ### Create the Shared Location Cleanup Function App, used to clean out shared locations
    $slcAppSettings = @(@{AppSettingName = "BlobContainerList"; Value = $sharedFileLocationBlobContainerNameList},@{AppSettingName = "FileShareList"; Value = $sharedFileLocationFileShareList})
    &$resDir\create-sn-fn.ps1 -AppAbbr "slc" -Env $Env -MinAppInstances $aspFnPool4MinAppInstances -Location $location -AppSettings $slcAppSettings -UseConsumptionPlan $false -AppServicePlanName $coreSysControlsFnPoolName -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName
    $storageAccessList += @{StorageAccount = $sharedStorageName; StorageAccountName="Shared"; AppAbbrList = "slc"}

    ### Create SolNav Latency Monitor Function App
    &$resDir\create-sn-fn.ps1 -AppAbbr "snlm" -Env $Env -MinAppInstances $aspFnPool4MinAppInstances -Location $location -UseConsumptionPlan $false -AppServicePlanName $coreSysControlsFnPoolName -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName

    # KV app settings for use by apps that use the v2 security solution
    $v2SecurityAppSettings = @(
        @{AppSettingName = "SelNavSharedAuthV2:AspNetSharedAuthV2CookieName"; KVSecretName = "AspNetSharedAuthV2CookieName"},
        @{AppSettingName = "SelNavSharedAuthV2:AspNetSharedAuthV2ExpiryTimeoutMinutes"; KVSecretName = "AspNetSharedAuthV2ExpiryTimeoutMinutes"},
        @{AppSettingName = "SelNavSharedAuthV2:AspNetSharedAuthV2SASUrl"; KVSecretName = "AspNetSharedAuthV2SASUrl"},
        @{AppSettingName = "SelNavSharedAuthV2:SelNavSharedMachineDecryptionKey"; KVSecretName = "SelNavSharedMachineDecryptionKey"},
        @{AppSettingName = "SelNavSharedAuthV2:SelNavSharedMachineValidationKey"; KVSecretName = "SelNavSharedMachineValidationKey"}
    );
    $launchDarklyAppSettings = @(
        @{AppSettingName = "LdSdkKey"; KVSecretName = "LdSdkKey"},
        @{AppSettingName = "LdClientsideId"; KVSecretName = "LdClientsideId"}
    );

    ##################
    # Core Resources #
    ##################

    $coreTeamsAADGroupList = "SelNav-Azure-AppDev-Core"
    $coreTeamsRBAC = @(
        @{ AADGroupList = $coreTeamsAADGroupList; RolesList = "Contributor"; EnvFilterList = "dev2,dev,qa"}
    )

    $estimatingTeamsRBAC = @(
        @{ AADGroupList = "SelNav-Azure-AppDev-Estimating"; RolesList = "Contributor"; EnvFilterList = "dev2,dev,qa"}
    )
   
    $tuxedoTeamRBAC = @(
        @{ AADGroupList = "SelNav-Azure-Team-Tuxedo"; RolesList = "Contributor"; EnvFilterList = "dev2,dev,qa"}
    )
   
    ### Create Shared Services web app
    $shsAppSettings = @(
        @{AppSettingName = "Tenant:1:ConsumerKey"; KVSecretName = "Tenant1-ConsumerKey"},
        @{AppSettingName = "Tenant:1:ConsumerSecret"; KVSecretName = "Tenant1-ConsumerSecret"},
        @{AppSettingName = "Tenant:2:ConsumerKey"; KVSecretName = "Tenant2-ConsumerKey"},
        @{AppSettingName = "Tenant:2:ConsumerSecret"; KVSecretName = "Tenant2-ConsumerSecret"},
        @{AppSettingName = "Tenant:3:ClientId"; KVSecretName = "Tenant3-ClientId"},
        @{AppSettingName = "Tenant:3:ClientSecret"; KVSecretName = "Tenant3-ClientSecret"},
        @{AppSettingName = "Tenant:4:Salesforce:ClientId"; KVSecretName = "Tenant4-Salesforce-ClientId"},
        @{AppSettingName = "Tenant:4:Salesforce:ClientSecret"; KVSecretName = "Tenant4-Salesforce-ClientSecret"},
        @{AppSettingName = "Tenant:4:Oracle:ClientId"; KVSecretName = "Tenant4-Oracle-ClientId"},
        @{AppSettingName = "Tenant:4:Oracle:ClientSecret"; KVSecretName = "Tenant4-Oracle-ClientSecret"},
        @{AppSettingName = "Tenant:4:Oracle:SecondaryContext:Username"; KVSecretName = "Tenant4-Oracle-Username"},
        @{AppSettingName = "Tenant:4:Oracle:SecondaryContext:Password"; KVSecretName = "Tenant4-Oracle-Password"},
        @{AppSettingName = "SalesforceLogin:UserId"; KVSecretName = "SFDCUsername"},
        @{AppSettingName = "SalesforceLogin:Password"; KVSecretName = "SFDCPassword"},
        @{AppSettingName = "SalesforceLogin:ConsumerKey"; KVSecretName = "Tenant1-ConsumerKey"},
        @{AppSettingName = "SalesforceLogin:ConsumerSecret"; KVSecretName = "Tenant1-ConsumerSecret"},
        @{AppSettingName = "SalesforceLogin:RefreshToken"; KVSecretName = "Tenant1-RefreshToken"},
        @{AppSettingName = "ConnectionStrings:AzureWebJobsStorage"; KVSecretName = "$sharedStorageName-ConnectionString"},
        @{AppSettingName = "SelNavSharedAuthV2:AspNetSharedAuthV1ExpiryTimeoutMinutes"; KVSecretName = "AspNetSharedAuthV1ExpiryTimeoutMinutes"}
    )

    $refreshTeamsRBAC = @(
        @{ AADGroupList = "SelNav-Azure-Refresh"; RolesList = "SelNav AppService Configuration Contributor"; EnvFilterList = "dev2,dev,qa,sit,ppe"}
    )

    &$resDir\create-sn-app.ps1 -AppAbbr "shs" -Env $Env -Runtime "dotnet:8" -MinAppInstances $aspPool5MinAppInstances -Location $location -AppServicePlanName $aspPool5Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings + $shsAppSettings) -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions ($coreTeamsRBAC + $refreshTeamsRBAC)
    $cdbAccessList += @{AccountName = $cosmosDbAccount1Name; ConnectionUrlName = "SharedServicesContext"; Scope = "/dbs/$sharedservicesDatabaseName"; Role = "$sharedservicesDatabaseName Read Write Role"; AppAbbrList = "shs";}
    $principalId = $appsCreated."$location.shs".AzureData.app.identity.principalId
    &$resDir\grant-svcprincipal-roles-for-scope.ps1 -PrincipalId $principalId -RolesList "Storage Blob Data Reader" -Scope $sharedStorageId -LogDir $LogDir 
    &$resDir\grant-svcprincipal-roles-for-scope.ps1 -PrincipalId $principalId -RolesList "Storage Blob Data Contributor" -Scope "$sharedStorageId/blobServices/default/containers/sessiondatasnapshots" -LogDir $LogDir 
    &$resDir\grant-svcprincipal-roles-for-scope.ps1 -PrincipalId $principalId -RolesList "Storage Blob Data Contributor" -Scope "$sharedStorageId/blobServices/default/containers/sessiontemporaryfiles" -LogDir $LogDir
    
    # Grant signalR access 
    $srsAccessList += @{Service = $signalRName; AppAbbrList = "shs"; RolesList = "SignalR App Server"; AADGroupList = "SelNav-Azure-Team-Gladiators"; EnvFilterList = "dev2,dev"}
    $signalRSecondaryIndex = 1
    foreach($signalRName in $signalRNames) {
        if($signalRName.StartsWith("srs-sn-$Env-$location")){
            $srsAccessList += @{Service = $signalRName; AppAbbrList = "shs"; RolesList = "SignalR App Server"; ConnectionStringName="SignalRPrimary";}
        } else {
            $srsAccessList += @{Service = $signalRName; AppAbbrList = "shs"; RolesList = "SignalR App Server"; ConnectionStringName="SignalRSecondary$signalRSecondaryIndex";}
            $signalRSecondaryIndex++
        }       
    }

    ### Create Shared (Premium) Service Bus (and queues)
    $chillersBatchQueueMaxDeliveryCount = (P "5;DEV2:2")
    $sharedSBQueues = @(
        # For Shared Services
        @{Name="tenant1"},
        @{Name="tenant2"},
        @{Name="tenant3"},
        @{Name="tenant4"; LockDuration="PT3M"; MaxMessageSize="102400"; MaxSize="1024";MaxDeliveryCount=3},
        # For Item API
        @{Name="backup-item-delete";LockDuration="PT5M"},
        @{Name="backup-itemdetail-delete";LockDuration="PT5M"},
        @{Name="backup-itemrelationship-delete";LockDuration="PT5M"},
        # For DocGen apps
        @{Name="jobs";LockDuration="PT5M"},
        @{Name="document-request";LockDuration="PT5M"},
        @{Name="document-upload";LockDuration="PT5M"},
        @{Name="document-failed";LockDuration="PT5M"},
        # For EBP processing
        @{Name="copy-project";LockDuration="PT5M"},
        # For Chillers processing
        @{Name="pumps-unitprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="armstrong-process";LockDuration="PT5M";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="armstrong-complete";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="dxchill-unitprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="dxchill-unitsecondary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="dxchill-batchprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=$chillersBatchQueueMaxDeliveryCount},
        @{Name="dxchill-batchsecondary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=$chillersBatchQueueMaxDeliveryCount},
        @{Name="dxchill-largebatchprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=$chillersBatchQueueMaxDeliveryCount},
        @{Name="dxchill-largebatchsecondary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=$chillersBatchQueueMaxDeliveryCount},
        @{Name="xengine-unitprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="xengine-unitsecondary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="xengine-batchprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=$chillersBatchQueueMaxDeliveryCount},
        @{Name="hisela-unitprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="interpolation-unitprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="interpolation-batchprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="aecworks-unitprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="aecworks-batchprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="ltc-unitprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="ltc-unitsecondary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="ltc-batchprimary";LockDuration="PT5M";EnableDeadLettering=$true;MaxDeliveryCount=$chillersBatchQueueMaxDeliveryCount},
        @{Name="completed-ratings";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2}
        @{Name="completed-unit-ratings";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="slow-batch-input-conversion";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="fast-batch-input-conversion";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="batch-input-conversion-result";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="batch-output-conversion";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="batch-output-conversion-result";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="batch-pick-list-conversion";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="batch-pick-list-conversion-result";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="rating-metadata";LockDuration="PT5M";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="completed-sub-batch-ratings";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="dxchill-maxcapacityprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="dxchill-maxcapacitysecondary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2}
        )
    $sharedSBTopics = @(
        @{Name="create"; Subscriptions=@()},
        @{Name="update"; Subscriptions=@()},
        @{Name="delete"; Subscriptions=@(@{Name="itbp"; TTL="P1M"})},
        @{Name="resequence"; DuplicateDetection = $true; DuplicateDetectionDuration = "PT8H"; Subscriptions=@(@{Name="itbp"; TTL="P1M"})}
        )
    $sharedSBRBAC = ($coreTeamsRBAC + $estimatingTeamsRBAC + $chillersTeamRBAC)
    &$resDir\create-sn-sb.ps1 -Env $Env -Location $location -AppAbbr "shared" -StorageSku "Premium" -LogDir $LogDir -Topics $sharedSBTopics -Queues $sharedSBQueues -RBACPermissions $sharedSBRBAC -Tags $sharedTags -AzureData $azureOutput
    $sharedSBName = $azureOutput."sb-shared-$location".name
    $sbAccessList +=  @{ServiceBus = $sharedSBName; ServiceBusName="Shared"; AppAbbrList = "shs,dgb,dgbp,dg,ebp,ea,est,crs,cbo,csbo,cuo,crd,cred,crel,crex,crear,creh,crei,creae,ccem"}

    ### Create Tenant Service Bus (and queues)
    $premiumTenantSBSkuEnvList = "DEV"
    $premiumTenantSBSkuEnvs = $premiumTenantSBSkuEnvList.Split(",")
    $tenant4Queue = @{Name="tenant4"; LockDuration="PT3M";}
    if($premiumTenantSBSkuEnvs -contains $Env){
        $tenant4Queue.MaxMessageSize="102400"
        $tenant4Queue.MaxSize="1024";
    }
    $tenentSBQueues = @(@{Name="tenant1"},@{Name="tenant2"},@{Name="tenant3"},$tenant4Queue)
    $tenantSBSku = (P "$($premiumTenantSBSkuEnvList):Premium;Standard")
    &$resDir\create-sn-sb.ps1 -Env $Env -Location $location -AppAbbr "tenant" -StorageSku $tenantSBSku -LogDir $LogDir -Queues $tenentSBQueues -RBACPermissions $coreTeamsRBAC -Tags $coreTags -AzureData $azureOutput
    $tenantSBName = $azureOutput."sb-tenant-$location".name
    $sbAccessList +=  @{ServiceBus = $tenantSBName; ServiceBusName="Tenant"; AppAbbrList = "shs"}

    ## Create Item api web app (ITA)
    $itaAppSettings = @(
        @{AppSettingName = "ConnectionStrings:AzureWebJobsStorage"; KVSecretName = "$sharedStorageName-ConnectionString"},
        @{AppSettingName = "SelNavSharedAuthV2:AspNetSharedAuthV1ExpiryTimeoutMinutes"; KVSecretName = "AspNetSharedAuthV1ExpiryTimeoutMinutes"}
    )

    &$resDir\create-sn-app.ps1 -AppAbbr "ita" -Env $Env -Runtime "dotnet:8" -MinAppInstances $aspPool5MinAppInstances -Location $location -AppServicePlanName $aspPool5Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings + $itaAppSettings) -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions ($coreTeamsRBAC)
    $cdbAccessList += @{AccountName = $cosmosDbAccount1Name; ConnectionUrlName = "ItemDatabase"; Scope = "/dbs/$itemDatabaseName"; Role = "$itemDatabaseName Read Write Role"; AppAbbrList = "ita";}

    ## Grant Item Storage Account access to the ITA app
    $principalId = $appsCreated."$location.ita".AzureData.app.identity.principalId
    foreach($itemStorageAccount in $itemStorageAccounts.GetEnumerator()){
        if ($itemStorageAccount.Value.AccountCreated){           
            &$resDir\grant-svcprincipal-roles-for-scope.ps1 -PrincipalId $principalId -RolesList "Storage Blob Data Contributor" -Scope $itemStorageAccount.Value.Id -LogDir $LogDir  
        }
    }

    ### Item Background Processor (ITBP)
    &$resDir\create-sn-fn.ps1 -AppAbbr "itbp" -Env $Env -MinAppInstances $aspFnPool4MinAppInstances -Location $location -UseConsumptionPlan $false -Runtime "dotnet-isolated" -AppServicePlanName $coreSysControlsFnPoolName -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions ($coreTeamsRBAC)
    $cdbAccessList += @{AccountName = $cosmosDbAccount1Name; ConnectionUrlName = "ItemDatabase"; Scope = "/dbs/$itemDatabaseName"; Role = "$itemDatabaseName Read Write Role"; AppAbbrList = "itbp";}
  
    ## Grant Item Storage Account access to the ITBP function
    $principalId = $appsCreated."$location.itbp".AzureData.app.identity.principalId
    foreach($itemStorageAccount in $itemStorageAccounts.GetEnumerator()){
        if ($itemStorageAccount.Value.AccountCreated){          
            &$resDir\grant-svcprincipal-roles-for-scope.ps1 -PrincipalId $principalId -RolesList "Storage Blob Data Owner" -Scope $itemStorageAccount.Value.Id -LogDir $LogDir  
        }
    }

    ### Create Item Service Bus (and topics)
    $itemSBQueues = @(@{Name="backup-item-delete";LockDuration="PT5M"},@{Name="backup-itemdetail-delete";LockDuration="PT5M"},@{Name="backup-itemrelationship-delete";LockDuration="PT5M"})
    $itemSBTopics = @(@{Name="create"; Subscriptions=@()},@{Name="update"; Subscriptions=@()},@{Name="delete"; Subscriptions=@(@{Name="itbp"; TTL="P1M"})},@{Name="resequence"; DuplicateDetection = $true; DuplicateDetectionDuration = "PT8H"; Subscriptions=@(@{Name="itbp"; TTL="P1M"})})
    &$resDir\create-sn-sb.ps1 -Env $Env -Location $location -AppAbbr "item" -LogDir $LogDir -Topics $itemSBTopics -Queues $itemSBQueues -RBACPermissions $coreTeamsRBAC -Tags $coreTags -AzureData $azureOutput
    $itemSBId = $azureOutput."sb-item-$location".id

    ## Grant Item Service Bus access to the ITA and ITBP apps
    $principalId = $appsCreated."$location.ita".AzureData.app.identity.principalId
    &$resDir\grant-svcprincipal-roles-for-scope.ps1 -PrincipalId $principalId -RolesList "Azure Service Bus Data Sender" -Scope $itemSBId -LogDir $LogDir
    $principalId = $appsCreated."$location.itbp".AzureData.app.identity.principalId
    &$resDir\grant-svcprincipal-roles-for-scope.ps1 -PrincipalId $principalId -RolesList "Azure Service Bus Data Receiver,Azure Service Bus Data Sender" -Scope $itemSBId -LogDir $LogDir  

    ## Create item data factory
    $adfAccessList = @()
    $adfAccessList += @{ AADGroupList = $coreTeamsAADGroupList; RolesList = "Data Factory Contributor"; EnvFilterList = "dev2,dev,qa";}
    $adfItemPrivateEndpoints = @( 
        @{ resourceId = $azureOutput."cdb-1".id; groupId = "Analytical";}
    )
    foreach($itemStorageAccount in $itemStorageAccounts.GetEnumerator()){
        if ($itemStorageAccount.Value.AccountCreated){   
            $adfItemPrivateEndpoints += @{ resourceId = $itemStorageAccount.Value.Id; groupId = "blob";}
        }
    }

    &$resDir\create-sn-adf.ps1 -Env $Env -AdfAbbr "item" -ResourceGroup $ResourceGroup -Location $location -KeyVaultName $keyVaultName -PrivateEndpoints $adfItemPrivateEndpoints -AdfsCreated $adfsCreated -RBACPermissions $adfAccessList -Tags $coreTags; if(!$? -or $LASTEXITCODE -ne 0){ Throw "Error creating adf" }
    $adfPrincipalId = $adfsCreated."$location.item".AzureData.adf.identity.principalId
    &$resDir\grant-svcprincipal-roles-for-scope.ps1 -PrincipalId $adfPrincipalId -RolesList "Azure Service Bus Data Sender" -Scope $itemSBId -LogDir $LogDir 
    $storageAccessList += @{StorageAccount = $itemStorageAccounts[$location].name; StorageAccountName="Item"; AppAbbrList = ""}

    ## Create CDN Storage Account (containers now created in cdn deployment scripts)
    $cdnBlobContainers = @()
    &$resDir\create-sn-st.ps1 -Env $Env -Location $location -AppAbbr "cdn" -BlobContainers $cdnBlobContainers -AllowForContainerLevelPublicAccessEnablement $true -PublicNetworkAccess "Enabled" -PublicNetworkDefaultAction "Deny" -Tags $coreTags -AzureData $azureOutput -LogDir $LogDir
    $cdnStorageName = $azureOutput."st-cdn$location".name

    ### Document Generation web apps & databases
    &$resDir\create-sn-app.ps1 -AppAbbr "dg" -Env $Env -Use32Bit $false -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool5MinAppInstances -AppServicePlanName $aspPool5Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $docGenTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "dgb" -Env $Env -Use32Bit $false -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool5MinAppInstances -AppServicePlanName $aspPool5Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -HybridConnections @($smtpHybridConnection) -Location $location -Tags $docGenTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "ddf" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool5MinAppInstances -AppServicePlanName $aspPool5Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $docGenTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    &$resDir\create-sn-fn.ps1 -AppAbbr "dgbp" -Env $Env -MinAppInstances $aspFnPool4MinAppInstances -Location $location -UseConsumptionPlan $false -AppServicePlanName $coreSysControlsFnPoolName -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Tags $docGenTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions ($coreTeamsRBAC)
    &$resDir\create-sn-db.ps1 -Name "DocumentGeneration" -Server $sqlServer1Name -MaxSize "5GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -LogDir $LogDir -DatabasesCreated $databasesCreated
    $fnAccessList += @{FunctionAppAbbr = "dgbp"; AppAbbrList = "dgb"}
    $dbAccessList += @{DBName = "DocumentGeneration"; Server = $sqlServer1Name; Roles = "db_datareader,db_execute"; AppAbbrList = "dg"; UseMultipleActiveResultSets = $true}
    $dbAccessList += @{DBName = "DocumentGeneration"; Server = $sqlServer1Name; Roles = "db_datareader,db_datawriter,db_execute"; AppAbbrList = "dgb,ddf,dgbp"}
    $dbAccessList += @{DBName = "DocumentGeneration"; Server = $sqlServer1Name; AADGroupList = $coreTeamsAADGroupList; Roles = "db_datareader,db_execute,db_viewdefinition,db_datawriter"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "DocumentGeneration"; Server = $sqlServer1Name; AADGroupList = $coreTeamsAADGroupList; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-app.ps1 -AppAbbr "ee" -Env $Env -Use32Bit $false -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool5MinAppInstances -AppServicePlanName $aspPool5Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $docGenTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    &$resDir\create-sn-fn.ps1 -AppAbbr "eebp" -Env $Env -MinAppInstances $aspFnPool4MinAppInstances -Location $location -UseConsumptionPlan $false -AppServicePlanName $coreSysControlsFnPoolName -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Tags $sysControlsTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $coreTeamsRBAC
    $fnAccessList += @{FunctionAppAbbr = "eebp"; AppAbbrList = "ee"}
    &$resDir\create-sn-db.ps1 -Name "EcrionEngine" -Server $sqlServer1Name -MaxSize "50GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "EcrionEngine"; Server = $sqlServer1Name; Roles = "db_datareader,db_datawriter"; AppAbbrList = "ee,eebp"}
    $dbAccessList += @{DBName = "EcrionEngine"; Server = $sqlServer1Name; AADGroupList = $coreTeamsAADGroupList; Roles = "db_datareader,db_viewdefinition,db_datawriter"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "EcrionEngine"; Server = $sqlServer1Name; AADGroupList = $coreTeamsAADGroupList; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    #Had set up and used: "j030m02m-53605,j030m02i-53605,j030m02e-53605"
    $excelSstAgentsByEnv = @{
        DEV2 = "j030m02m-53605,j030m02i-53605,j030m02e-53605,j030m02i-63875,j030m02e-58286"
        DEV = "j030m0al-53605,j030m0bc-53605,j030m0ati-53605"
        QA = "j030m0ah-53605,j030m05g-53605,j030m0ai-53605"
        SIT = "j030M02S-53605,j030M02T-53605,j030M02X-53605"
        PPE = "j030M07L-53605,j030M07X-53605,j030M07C-53605"
        PROD = "J030M0BK-53605,j030M4TEV1N-53605,J030M4TEV1R-53605,J030M4TEV1S-53605"
    }
    ## For a list of hybrid connections to set up: $excelSstAgentsByEnv["QA"].Split(",") | ForEach-Object{ "$subscriptionRelay-$_`r`n$($_.Split("-")[0]).go.johnsoncontrols.com`r`n$($_.Split("-")[1])`r`n" }
    $excelSstAgentHybridConnections = $excelSstAgentsByEnv[$Env].Split(",") | Where-Object {$_} | ForEach-Object{ @{Name = "$subscriptionRelay-$_"; Relay = $subscriptionRelay} }

    &$resDir\create-sn-app.ps1 -AppAbbr "eg" -Env $Env -Use32Bit $false -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool5MinAppInstances -HybridConnections $excelSstAgentHybridConnections -AppServicePlanName $aspPool5Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $docGenTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    &$resDir\create-sn-db.ps1 -Name "ExcelGeneration" -Server $sqlServer1Name -MaxSize "5GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "ExcelGeneration"; Server = $sqlServer1Name; Roles = "db_datareader,db_datawriter,db_execute"; AppAbbrList = "eg"}
    $dbAccessList += @{DBName = "ExcelGeneration"; Server = $sqlServer1Name; AADGroupList = $coreTeamsAADGroupList; Roles = "db_datareader,db_execute,db_viewdefinition,db_datawriter"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "ExcelGeneration"; Server = $sqlServer1Name; AADGroupList = $coreTeamsAADGroupList; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-app.ps1 -AppAbbr "mpe" -Env $Env -Use32Bit $false -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool5MinAppInstances -AppServicePlanName $aspPool5Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $docGenTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    &$resDir\create-sn-fn.ps1 -AppAbbr "mpebp" -Env $Env -MinAppInstances $aspFnPool4MinAppInstances -Location $location -UseConsumptionPlan $false -AppServicePlanName $coreSysControlsFnPoolName -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Tags $sysControlsTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $coreTeamsRBAC
    $fnAccessList += @{FunctionAppAbbr = "mpebp"; AppAbbrList = "mpe"}
    &$resDir\create-sn-db.ps1 -Name "MergePdfEngine" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "MergePdfEngine"; Server = $sqlServer1Name; Roles = "db_datareader,db_datawriter,db_execute"; AppAbbrList = "mpe,mpebp"}
    $dbAccessList += @{DBName = "MergePdfEngine"; Server = $sqlServer1Name; AADGroupList = $coreTeamsAADGroupList; Roles = "db_datareader,db_execute,db_viewdefinition,db_datawriter"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "MergePdfEngine"; Server = $sqlServer1Name; AADGroupList = $coreTeamsAADGroupList; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-app.ps1 -AppAbbr "due" -Env $Env -Use32Bit $false -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool5MinAppInstances -AppServicePlanName $aspPool5Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $docGenTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    &$resDir\create-sn-db.ps1 -Name "DocUpdateEngine" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "DocUpdateEngine"; Server = $sqlServer1Name; Roles = "db_datareader,db_datawriter,db_execute"; AppAbbrList = "due"}
    $dbAccessList += @{DBName = "DocUpdateEngine"; Server = $sqlServer1Name; AADGroupList = $coreTeamsAADGroupList; Roles = "db_datareader,db_execute,db_viewdefinition,db_datawriter"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "DocUpdateEngine"; Server = $sqlServer1Name; AADGroupList = $coreTeamsAADGroupList; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    $dgSBQueues = @(
        @{Name="jobs";LockDuration="PT5M"}
        @{Name="document-request";LockDuration="PT5M"}
        @{Name="document-upload";LockDuration="PT5M"}
        @{Name="document-failed";LockDuration="PT5M"}
        )
    &$resDir\create-sn-sb.ps1 -Env $Env -Location $location -AppAbbr "dg" -LogDir $LogDir -Queues $dgSBQueues -RBACPermissions ($coreTeamsRBAC + $estimatingTeamsRBAC) -Tags $docGenTags -AzureData $azureOutput
    $dgSBName = $azureOutput."sb-dg-$location".name
    $sbAccessList +=  @{ServiceBus = $dgSBName; ServiceBusName="DocGen"; AppAbbrList = "dgb,dgbp,dg"}

    ### Estimating API web apps & databases
    &$resDir\create-sn-app.ps1 -AppAbbr "ea" -Env $Env -Runtime "dotnet:8" -MinAppInstances $aspPool5MinAppInstances -AppServicePlanName $aspPool5Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    &$resDir\create-sn-db.ps1 -Name "EstimateReference" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "EstimateReference"; Server = $sqlServer1Name; Roles = "db_datareader,db_execute"; AppAbbrList = "est,ea"}
    $dbAccessList += @{DBName = "EstimateReference"; Server = $sqlServer1Name; AADGroupList = $coreTeamsAADGroupList; Roles = "db_datareader,db_execute,db_viewdefinition,db_datawriter"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "EstimateReference"; Server = $sqlServer1Name; AADGroupList = $coreTeamsAADGroupList; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}
    $cdbAccessList += @{AccountName = $cosmosDbAccount1Name; ConnectionUrlName = "ItemDatabase"; Scope = "/dbs/$itemDatabaseName"; Role = "$itemDatabaseName Read Write Role"; AppAbbrList = "ea";}

    ## Grant Item Storage Account access to the EA app
    $principalId = $appsCreated."$location.ea".AzureData.app.identity.principalId
    foreach($itemStorageAccount in $itemStorageAccounts.GetEnumerator()){
        if ($itemStorageAccount.Value.AccountCreated){           
            &$resDir\grant-svcprincipal-roles-for-scope.ps1 -PrincipalId $principalId -RolesList "Storage Blob Data Contributor" -Scope $itemStorageAccount.Value.Id -LogDir $LogDir  
        }
    }

    ## Grant Item Service Bus access to the EA app
    $principalId = $appsCreated."$location.ea".AzureData.app.identity.principalId
    &$resDir\grant-svcprincipal-roles-for-scope.ps1 -PrincipalId $principalId -RolesList "Azure Service Bus Data Sender" -Scope $itemSBId -LogDir $LogDir

    ### Estimating web app
    &$resDir\create-sn-app.ps1 -AppAbbr "est" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool5MinAppInstances -AppServicePlanName $aspPool5Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -HybridConnections @($corpSftpHybridConnection) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    $dbAccessList += @{DBName = "EstimateReference"; Server = $sqlServer1Name; Roles = "db_datareader,db_execute"; AppAbbrList = "est"}

    ### Estimating Background Processor
    &$resDir\create-sn-fn.ps1 -AppAbbr "ebp" -Env $Env -MinAppInstances $aspFnPool4MinAppInstances -Location $location -UseConsumptionPlan $false -AppServicePlanName $coreSysControlsFnPoolName -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions ($coreTeamsRBAC + $estimatingTeamsRBAC)
    $cdbAccessList += @{AccountName = $cosmosDbAccount1Name; ConnectionUrlName = "ItemDatabase"; Scope = "/dbs/$itemDatabaseName"; Role = "$itemDatabaseName Read Write Role"; AppAbbrList = "ebp";}

    ### Estimating Service Bus and queue
    $estSBQueues = @(@{Name="copy-project";LockDuration="PT5M"})
    &$resDir\create-sn-sb.ps1 -Env $Env -Location $location -AppAbbr "ebp" -LogDir $LogDir -Queues $estSBQueues -RBACPermissions ($coreTeamsRBAC + $estimatingTeamsRBAC) -Tags $coreTags -AzureData $azureOutput
    $estSBName = $azureOutput."sb-ebp-$location".name
    $sbAccessList +=  @{ServiceBus = $estSBName; ServiceBusName="Estimating"; AppAbbrList = "ebp,ea,est"}
    
    ### Portal web site
    &$resDir\create-sn-app.ps1 -AppAbbr "por" -Env $Env -Runtime "dotnet:8" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions ($coreTeamsRBAC)

    ### Micro Front End App Insights resources
    &$resDir\create-sn-app-insights.ps1 -AppAbbr "psel" -Env $Env -Location $location -Tags $coreTags -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir
    &$resDir\create-sn-app-insights.ps1 -AppAbbr "pdg" -Env $Env -Location $location -Tags $coreTags -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir
    &$resDir\create-sn-app-insights.ps1 -AppAbbr "psel" -Env $Env -Location $location -Tags $coreTags -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir
    &$resDir\create-sn-app-insights.ps1 -AppAbbr "ptt" -Env $Env -Location $location -Tags $coreTags -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir

    ### Design System Manager web site
    &$resDir\create-sn-app.ps1 -AppAbbr "dsm" -Env $Env -Runtime "dotnet:8" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings $launchDarklyAppSettings -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions ($tuxedoTeamRBAC)

    ### Item Import Service and database
    &$resDir\create-sn-app.ps1 -AppAbbr "iis" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions ($coreTeamsRBAC + $estimatingTeamsRBAC)    
    &$resDir\create-sn-db.ps1 -Name "ItemImport" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "ItemImport"; Server = $sqlServer1Name; Roles = "db_datareader,db_execute"; AppAbbrList = "iis"}
    $dbAccessList += @{DBName = "ItemImport"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Estimating"; Roles = "db_datareader,db_execute,db_viewdefinition,db_datawriter"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "ItemImport"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Estimating"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    $eisAppSettings = @(
        @{AppSettingName = "ConnectionStrings:AzureWebJobsStorage"; KVSecretName = "$sharedStorageName-ConnectionString"}
    );

    ### Estimate Item Search API (EIS)
    &$resDir\create-sn-app.ps1 -AppAbbr "eis" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings + $eisAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions ($coreTeamsRBAC + $estimatingTeamsRBAC)
    $eisBlobContainers = @(
        @{Name="product-data"; PubAccess="off"},
        @{Name="systems-data"; PubAccess="off"},
        @{Name="task-data"; PubAccess="off"},
        @{Name="cost-data"; PubAccess="off"}
    )
    &$resDir\create-sn-st.ps1 -Env $Env -Location $location -AppAbbr "eis" -BlobContainers $eisBlobContainers -EnableSoftDelete $true -SoftDeleteRetentionDays 7 -AllowForContainerLevelPublicAccessEnablement $false -Tags $coreTags -AzureData $azureOutput -LogDir $LogDir
    $eisStorageName = $azureOutput."st-eis$location".name
    $peName = "$($vnetName.Replace("vnet","pe"))-$eisStorageName"
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $eisStorageName -Name "$peName-blob" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "blob" -PrivateDnsZone "privatelink.blob.core.windows.net" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
    $storageAccessList += @{StorageAccount = $eisStorageName; StorageAccountName="EISData"; AppAbbrList = "eis"}
    $eisSearchDataSources = @(
        @{Name="product-datasource"; SourceType="Blob"; StorageSource=$eisStorageName; ContainerSource="product-data"; BlobFolder = ""; TrackDeletions=$true; DeleteDetectionPolicy = "NativeBlobSoftDelete"},
        @{Name="systems-datasource"; SourceType="Blob"; StorageSource=$eisStorageName; ContainerSource="systems-data"; BlobFolder = ""; TrackDeletions=$true; DeleteDetectionPolicy = "NativeBlobSoftDelete"},
        @{Name="task-datasource"; SourceType="Blob"; StorageSource=$eisStorageName; ContainerSource="task-data"; BlobFolder = ""; TrackDeletions=$true; DeleteDetectionPolicy = "NativeBlobSoftDelete"},
        @{Name="cost-datasource"; SourceType="Blob"; StorageSource=$eisStorageName; ContainerSource="cost-data"; BlobFolder = ""; TrackDeletions=$true; DeleteDetectionPolicy = "NativeBlobSoftDelete"}
    )
    $eisQueryKeys = @("EISApp")
    $eisSearchReplicaCount = [int](P "1;PROD:3")
    &$resDir\create-sn-ss.ps1 -AppAbbr "eis" -Env $Env -Sku "Standard" -ReplicaCount $eisSearchReplicaCount -PartitonCount 1 -DataSources $eisSearchDataSources -QueryKeys $eisQueryKeys -Location $location -Tags $coreTags -AzureData $azureOutput -LogDir $LogDir -RBACPermissions ($coreTeamsRBAC + $estimatingTeamsRBAC)
    $eisSearchServiceName = $azureOutput."ss-eis$location".name
    #Needs to be added to the jci network for deployment if we want this on the sn network
    #&$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $eisSearchServiceName -PrivateLinkResourceType "Microsoft.Search/searchServices" -GroupId "searchService" -PrivateDnsZone "privatelink.search.windows.net" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
    $searchServiceAccessList += @{SearchService = $eisSearchServiceName; SettingNamePrefix="EISearch"; QueryKeys=$eisQueryKeys; AppAbbrList = "eis" }

    ### UDP app and database
    #&$resDir\create-sn-app.ps1 -AppAbbr "udp" -Env $Env -Runtime "DOTNETCORE|3.1" -MinAppInstances $aspPool5MinAppInstances -AppServicePlanName $aspPool5Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    #&$resDir\create-sn-db.ps1 -Name "UserDefinedProducts" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $coreTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    #$dbAccessList += @{DBName = "UserDefinedProducts"; Server = $sqlServer1Name; AppAbbrList = "udp"; Roles = "db_datareader,db_datawriter,db_execute"}
    #$dbAccessList += @{DBName = "UserDefinedProducts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    #$dbAccessList += @{DBName = "UserDefinedProducts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    ### Product Application Selector web app & database
    &$resDir\create-sn-app.ps1 -AppAbbr "pas" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool1MinAppInstances -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -AppServicePlanName $aspPool1Name -RBACPermissions $coreTeamsRBAC
    &$resDir\create-sn-db.ps1 -Name "ProductApplicationSelector.Database" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $coreTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "ProductApplicationSelector.Database"; Server = $sqlServer1Name; AppAbbrList = "pas"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "ProductApplicationSelector.Database"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core"; Roles = "db_datareader,db_execute,db_viewdefinition,db_datawriter"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "ProductApplicationSelector.Database"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    ### AOMS Order API
    $aoaAppSettings = @(@{AppSettingName = "OrdersContainer"; Value = "aomsorders"})
    &$resDir\create-sn-app.ps1 -AppAbbr "aoa" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool1MinAppInstances -AppSettings $aoaAppSettings -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    $storageAccessList += @{StorageAccount = $sharedStorageName; StorageAccountName="Orders"; AppAbbrList = "aoa"}

    ### Common and common order web/api apps
    &$resDir\create-sn-app.ps1 -AppAbbr "com" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "co" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "coa" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    &$resDir\create-sn-db.ps1 -Name "OrderDatabase" -Server $sqlServer1Name -MaxSize "50GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $coreTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "OrderDatabase"; Server = $sqlServer1Name; AppAbbrList = "co,coa"; Roles = "db_datareader,db_execute,db_datawriter"}
    $dbAccessList += @{DBName = "OrderDatabase"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "OrderDatabase"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}
    $dbAccessList += @{DBName = "OrderDatabase"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-DataAnalytics-DevTest"; Roles = "db_datareader,db_execute"; EnvFilterList = "dev,qa"}
    $dbAccessList += @{DBName = "OrderDatabase"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-DataAnalytics-Prod"; Roles = "db_datareader,db_execute"; EnvFilterList = "prod"}
    #$dbAccessList += @{DBName = "OrderDatabase"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-DataAnalytics-DevTest"; Roles = "db_cdc"; EnvFilterList = "dev,qa"}
    #$dbAccessList += @{DBName = "OrderDatabase"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-DataAnalytics-Prod"; Roles = "db_cdc"; EnvFilterList = "prod"}

    ### Applied Equipment
    &$resDir\create-sn-app.ps1 -AppAbbr "ae" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool6MinAppInstances -AppServicePlanName $aspPool6Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC

    ### Applied Equipment Ordering
    &$resDir\create-sn-app.ps1 -AppAbbr "aeo" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC

    ### AEO Processing Durable Function app
    &$resDir\create-sn-st.ps1 -Env $Env -Location $location -StorageSku "Standard_LRS" -AppAbbr "aeop" -AllowForContainerLevelPublicAccessEnablement $false -RBACPermissions $coreTeamsRBAC -Tags $coreTags -AzureData $azureOutput -LogDir $LogDir
    $aeopStorageName = $azureOutput."st-aeop$location".name
    $peName = "$($vnetName.Replace("vnet","pe"))-$aeopStorageName"
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $aeopStorageName -Name "$peName-blob" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "blob" -PrivateDnsZone "privatelink.blob.core.windows.net" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $aeopStorageName -Name "$peName-table" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "table" -PrivateDnsZone "privatelink.table.core.windows.net" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $aeopStorageName -Name "$peName-queue" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "queue" -PrivateDnsZone "privatelink.queue.core.windows.net" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $aeopStorageName -Name "$peName-file" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "file" -PrivateDnsZone "privatelink.file.core.windows.net" -Tags $sharedTags -AzureData $azureOutput -LogDir $LogDir
    
    $corpSftpServer = (P "corpsftp--nonprd;PROD:corpsftp--prd")
    $corpSftpHybridConnection = @{Name = "$corpSftpServer-johnsoncontrols-com-22"; Relay = $subscriptionRelay}
    $aeopAppSettings = @(@{AppSettingName = "Values:SftpServerKey"; KVSecretName = "fn-sn-$Env-aeop-$location-SftpServerKey"})
    &$resDir\create-sn-fn.ps1 -AppAbbr "aeop" -Env $Env -MinAppInstances $aspFnPool4MinAppInstances -Use32Bit $false -HybridConnections @($corpSftpHybridConnection) -Location $location -UseConsumptionPlan $false -AppServicePlanName $coreSysControlsFnPoolName -KVAppSettings ($v2SecurityAppSettings + $aeopAppSettings) -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $aeopStorageName -RBACPermissions $coreTeamsRBAC
    $fnAccessList += @{FunctionAppAbbr = "aeop"; AppAbbrList = "aeo"}

    ### Product Documentation API
    &$resDir\create-sn-app.ps1 -AppAbbr "pda" -Env $Env -Runtime "dotnet:8" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    &$resDir\create-sn-db.ps1 -Name "ProductDocumentation" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $coreTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "ProductDocumentation"; Server = $sqlServer1Name; AppAbbrList = "pda"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "ProductDocumentation"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core,SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "ProductDocumentation"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    ### Product Documentation storage
    $productDocumentationAuthoringTeamRBAC = @(
        @{ AADGroupList = "SelNav-Azure-Team-GPNavigatorDocMgmt"; RolesList = "Storage Blob Data Contributor";}
    )
    $productDocumentationBlobContainers = @()
    ## Production Documentation containers now created in pd deployment scripts
    #$productDocumentationBlobContainers = @(@{Name="productdocumentation"; PubAccess="blob"})
    &$resDir\create-sn-st.ps1 -Env $Env -Location $location -AppAbbr "pd" -BlobContainers $productDocumentationBlobContainers -StorageSku "Standard_GRS" -AllowForContainerLevelPublicAccessEnablement $true -RBACPermissions $productDocumentationAuthoringTeamRBAC -Tags $coreTags -AzureData $azureOutput -LogDir $LogDir
    $productDocumentationStorageName = $azureOutput."st-pd$location".name
    $peName = "$($vnetName.Replace("vnet","pe"))-$productDocumentationStorageName"
    $storageAccessList += @{StorageAccount = $productDocumentationStorageName; StorageAccountName="ProductDocumentation"; AppAbbrList = "pda"}
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $productDocumentationStorageName -Name "$peName-blob" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "blob" -PrivateDnsZone "privatelink.blob.core.windows.net" -Tags $coreTags -AzureData $azureOutput -LogDir $LogDir
    
    ### Applied Equipment database
    &$resDir\create-sn-db.ps1 -Name "AppliedEquipmentDatabase" -MaxSize "5GB" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $coreTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "AppliedEquipmentDatabase"; Server = $sqlServer1Name; AppAbbrList = "ae,aeop"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "AppliedEquipmentDatabase"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "AppliedEquipmentDatabase"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}
    $dbAccessList += @{DBName = "AppliedEquipmentDatabase"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "dev2,dev"} ## Temp access granted 2/21/2025, remove after 4/1/2025 (contact Mahesh Wakchaure prior to removal)

    ### Special Requests
    $maxSpecialRequestDbSize = (P "10GB;PROD:50GB")
    &$resDir\create-sn-app.ps1 -AppAbbr "sr" -Env $Env -Runtime "dotnet:8" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -HybridConnections @($smtpHybridConnection) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    &$resDir\create-sn-db.ps1 -Name "SpecialRequest" -MaxSize $maxSpecialRequestDbSize -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $coreTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SpecialRequest"; Server = $sqlServer1Name; AppAbbrList = "sr"; Roles = "db_datareader,db_datawriter,db_execute"}
    $dbAccessList += @{DBName = "SpecialRequest"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core,SelNav-Azure-AppDev-AHU"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SpecialRequest"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core,SelNav-Azure-AppDev-AHU"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    ### Special Pricing Requests API
    &$resDir\create-sn-app.ps1 -AppAbbr "spr" -Env $Env -Runtime "dotnet:8" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC
    &$resDir\create-sn-db.ps1 -Name "SpecialPricingRequests" -MaxSize "100GB" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $coreTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SpecialPricingRequests"; Server = $sqlServer1Name; AppAbbrList = "spr"; Roles = "db_datareader,db_datawriter,db_execute"}
    $dbAccessList += @{DBName = "SpecialPricingRequests"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SpecialPricingRequests"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}
    $dbAccessList += @{DBName = "SpecialPricingRequests"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-DataAnalytics-DevTest"; Roles = "db_cdc,db_datareader"; EnvFilterList = "dev,qa"}
    $dbAccessList += @{DBName = "SpecialPricingRequests"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-DataAnalytics-Prod"; Roles = "db_cdc,db_datareader"; EnvFilterList = "prod"}

    ### Admin
    &$resDir\create-sn-app.ps1 -AppAbbr "adm" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC

    
    #################
    # AHU Resources #
    #################

    ### AHU dev/tester RBAC permissions for resources
    $AHUTeamRBAC = @(
        @{ AADGroupList = "SelNav-Azure-AppDev-AHU"; RolesList = "Contributor"; EnvFilterList = "dev2,dev,qa"}
    )

    $ahuScaleControllerLogSetting = (P "None;DEV2,DEV:Verbose")
    $ahuFnAppSettings = @(@{AppSettingName = "SCALE_CONTROLLER_LOGGING_ENABLED"; Value = "AppInsights:$ahuScaleControllerLogSetting"})

    $momStorageAccount = "$(P "DEV2,DEV:testgpv2mom;QA,SIT:qagpv2mom;PPE,PROD:prodgpv2mom")"
    # Are for .blob.core.windows.net
    $momStorageHybridConnection = @{Name = "$subscriptionRelay-$momStorageAccount-443"; Relay = $subscriptionRelay}

    &$resDir\create-sn-app.ps1 -AppAbbr "abs" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "aas" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "acr" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "acs" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC
    &$resDir\create-sn-db.ps1 -Name "AHUShellData" -MaxSize "2GB" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $ahuTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "AHUShellData"; Server = $sqlServer1Name; AppAbbrList = "ash"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "AHUShellData"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AHU"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "AHUShellData"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AHU"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}
    &$resDir\create-sn-app.ps1 -AppAbbr "ads" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "aor" -Env $Env -Runtime "dotnet:8" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -HybridConnections @($momStorageHybridConnection) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "aeh" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "aes" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "aer" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC

    &$resDir\create-sn-app.ps1 -AppAbbr "afn" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC
    &$resDir\create-sn-db.ps1 -Name "AHUFanData" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $ahuTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "AHUFanData"; Server = $sqlServer1Name; AppAbbrList = "afn,ajf"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "AHUFanData"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AHU"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "AHUFanData"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AHU"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}
    &$resDir\create-sn-app.ps1 -AppAbbr "afl" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "agh" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "ahs" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC

    &$resDir\create-sn-fn.ps1 -AppAbbr "ajf" -Env $Env -MinAppInstances $aspFnPool3MinAppInstances -Location $location -AppSettings $ahuFnAppSettings -PremiumPrewarmedInstances 2 -UseConsumptionPlan $false -AppServicePlanName $ahuFnPoolName -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $AHUTeamRBAC -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings)
    $fnAccessList += @{FunctionAppAbbr = "ajf"; AppAbbrList = "AFN"}
    &$resDir\create-sn-fn.ps1 -AppAbbr "air" -Env $Env -MinAppInstances $aspFnPool3MinAppInstances -Location $location -AppSettings $ahuFnAppSettings -PremiumPrewarmedInstances 2 -UseConsumptionPlan $false -AppServicePlanName $ahuFnPoolName -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $AHUTeamRBAC -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings)
    $fnAccessList += @{FunctionAppAbbr = "air"; AppAbbrList = "ASC"}
    &$resDir\create-sn-fn.ps1 -AppAbbr "aep" -Env $Env -MinAppInstances $aspFnPool3MinAppInstances -Location $location -AppSettings $ahuFnAppSettings -PremiumPrewarmedInstances 5 -UseConsumptionPlan $false -AppServicePlanName $ahuFnPoolName -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $AHUTeamRBAC -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings)
    $fnAccessList += @{FunctionAppAbbr = "aep"; AppAbbrList = "ASC,AFN"}
    &$resDir\create-sn-fn.ps1 -AppAbbr "ait" -Env $Env -MinAppInstances $aspFnPool3MinAppInstances -Location $location -AppSettings $ahuFnAppSettings -PremiumPrewarmedInstances 5 -UseConsumptionPlan $false -AppServicePlanName $ahuFnPoolName -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $AHUTeamRBAC -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings)
    $fnAccessList += @{FunctionAppAbbr = "ait"; AppAbbrList = "AER"}
    &$resDir\create-sn-fn.ps1 -AppAbbr "ajc" -Env $Env -MinAppInstances $aspFnPool3MinAppInstances -Location $location -AppSettings $ahuFnAppSettings -PremiumPrewarmedInstances 5 -UseConsumptionPlan $false -AppServicePlanName $ahuFnPoolName -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $AHUTeamRBAC -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings)
    $fnAccessList += @{FunctionAppAbbr = "ajc"; AppAbbrList = "ASC,ACR,ACS"}
    &$resDir\create-sn-fn.ps1 -AppAbbr "atc" -Env $Env -MinAppInstances $aspFnPool3MinAppInstances -Location $location -AppSettings $ahuFnAppSettings -PremiumPrewarmedInstances 5 -UseConsumptionPlan $false -AppServicePlanName $ahuFnPoolName -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $AHUTeamRBAC -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings)
    $fnAccessList += @{FunctionAppAbbr = "atc"; AppAbbrList = "ASC,AFN"}

    &$resDir\create-sn-app.ps1 -AppAbbr "ams" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "aos" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC
    &$resDir\create-sn-db.ps1 -Name "AHUPricingData" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $ahuTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "AHUPricingData"; Server = $sqlServer1Name; AppAbbrList = "apr"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "AHUPricingData"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AHU"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "AHUPricingData"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AHU"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}
    &$resDir\create-sn-fn.ps1 -AppAbbr "apr" -Env $Env -MinAppInstances $aspFnPool3MinAppInstances -Location $location -AppSettings $ahuFnAppSettings -UseConsumptionPlan $false -AppServicePlanName $ahuFnPoolName -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $AHUTeamRBAC -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings)
    $fnAccessList += @{FunctionAppAbbr = "apr"; AppAbbrList = "ASC"}
    &$resDir\create-sn-app.ps1 -AppAbbr "asc" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool6MinAppInstances -AppServicePlanName $aspPool6Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -HybridConnections @($momStorageHybridConnection) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:20") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC
    &$resDir\create-sn-fn.ps1 -AppAbbr "axs" -Env $Env -MinAppInstances $aspFnPool3MinAppInstances -Location $location -AppSettings $ahuFnAppSettings -UseConsumptionPlan $false -AppServicePlanName $ahuFnPoolName -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $AHUTeamRBAC -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings)
    $fnAccessList += @{FunctionAppAbbr = "axs"; AppAbbrList = "AER"}
    &$resDir\create-sn-app.ps1 -AppAbbr "ash" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool2MinAppInstances -AppServicePlanName $aspPool2Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC
    &$resDir\create-sn-db.ps1 -Name "AHUValidationData" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $ahuTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "AHUValidationData"; Server = $sqlServer1Name; AppAbbrList = "avs"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "AHUValidationData"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AHU"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "AHUValidationData"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AHU"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}
    &$resDir\create-sn-fn.ps1 -AppAbbr "avs" -Env $Env -MinAppInstances $aspFnPool3MinAppInstances -Location $location -AppSettings $ahuFnAppSettings -UseConsumptionPlan $false -AppServicePlanName $ahuFnPoolName -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $AHUTeamRBAC -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings)
    $fnAccessList += @{FunctionAppAbbr = "avs"; AppAbbrList = "ASC"}
    &$resDir\create-sn-fn.ps1 -AppAbbr "aws" -Env $Env -MinAppInstances $aspFnPool3MinAppInstances -Location $location -AppSettings $ahuFnAppSettings -UseConsumptionPlan $false -AppServicePlanName $ahuFnPoolName -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $AHUTeamRBAC -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings)
    $fnAccessList += @{FunctionAppAbbr = "aws"; AppAbbrList = "ASC"}

    $drsDrawingServer = (P "DEV2,DEV:j030m0wx;QA,SIT:j030m1i4;PPE,PROD:j030m1ic")
    $drawingServerHybridConnection = @{Name = "$subscriptionRelay-$drsDrawingServer-80"; Relay = $subscriptionRelay}
    &$resDir\create-sn-app.ps1 -AppAbbr "drs" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -HybridConnections @($drawingServerHybridConnection) -Location $location -Tags $ahuTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $AHUTeamRBAC

    ##################
    # Edge Resources #
    ##################

    $edgeTeamsRBAC = @(
        @{ AADGroupList = "SelNav-Azure-AppDev-Edge"; RolesList = "Contributor"; EnvFilterList = "dev2,dev,qa"}
    )

    ### Largo app and databases
    &$resDir\create-sn-app.ps1 -AppAbbr "lar" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool6MinAppInstances -AppServicePlanName $aspPool6Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $edgeTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $edgeTeamsRBAC
    &$resDir\create-sn-db.ps1 -Name "LargoTerminal" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "LargoTerminal"; Server = $sqlServer1Name; AppAbbrList = "lar"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "LargoTerminal"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "LargoTerminal"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    ### Edge migrated app resources
    &$resDir\create-sn-app.ps1 -AppAbbr "edge" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool6MinAppInstances -AppServicePlanName $aspPool6Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -HybridConnections @($smtpHybridConnection) -Location $location -Tags $edgeTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $edgeTeamsRBAC

    # DEV2,DEV,QA,SIT,PPE:as-ahu-test-jci-largo-order-api.azurewebsites.net:443 
    # PROD:as-ahu-prod-jci-largo-order-api.azurewebsites.net:443 
    $largoOrderServer = (P "DEV2,DEV,QA,SIT,PPE:as-ahu-test-jci-largo-order-api;PROD:as-ahu-prod-jci-largo-order-api")
    $largoOrderHybridConnection = @{Name = "$subscriptionRelay-$largoOrderServer-443"; Relay = $subscriptionRelay}
    $eoHybridConnections = ($largoOrderServer) ? @($smtpHybridConnection, $largoOrderHybridConnection) : @($smtpHybridConnection)
    ## For a list of hybrid connections to set up: $excelSstAgentsByEnv["QA"].Split(",") | ForEach-Object{ "$subscriptionRelay-$_`r`n$($_.Split("-")[0]).go.johnsoncontrols.com`r`n$($_.Split("-")[1])`r`n" }
    &$resDir\create-sn-app.ps1 -AppAbbr "eo" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -HybridConnections $eoHybridConnections -Location $location -Tags $edgeTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $edgeTeamsRBAC

    ### Edge Background Processor
    &$resDir\create-sn-fn.ps1 -AppAbbr "edbp" -Env $Env -MinAppInstances $aspFnPool4MinAppInstances -Location $location -UseConsumptionPlan $false -AppServicePlanName $coreSysControlsFnPoolName -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $edgeTeamsRBAC

    &$resDir\create-sn-db.ps1 -Name "Edge.Krueger" -MaxSize "2GB" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.Krueger"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Edge.Krueger"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.Krueger"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Edge.Krueger.Discounts" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.Krueger.Discounts"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Edge.Krueger.Discounts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.Krueger.Discounts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Edge.Ruskin" -MaxSize "2GB" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.Ruskin"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Edge.Ruskin"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.Ruskin"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Edge.Titus" -MaxSize "2GB" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.Titus"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Edge.Titus"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.Titus"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Edge.Titus.Discounts" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.Titus.Discounts"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Edge.Titus.Discounts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.Titus.Discounts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Edge.TNB" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.TNB"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Edge.TNB"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.TNB"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Edge.TNB.Discounts" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.TNB.Discounts"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Edge.TNB.Discounts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.TNB.Discounts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Edge.Ruskin.Discounts" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.Ruskin.Discounts"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Edge.Ruskin.Discounts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.Ruskin.Discounts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Edge.Pennbarry" -Server $sqlServer1Name -MaxSize "5GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.Pennbarry"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Edge.Pennbarry"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.Pennbarry"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Edge.Pennbarry.Discounts" -Server $sqlServer1Name -MaxSize "5GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.Pennbarry.Discounts"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Edge.Pennbarry.Discounts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.Pennbarry.Discounts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Edge.Envirco" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.Envirco"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Edge.Envirco"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.Envirco"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Edge.Envirco.Discounts" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.Envirco.Discounts"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Edge.Envirco.Discounts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.Envirco.Discounts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Edge.YorkFans" -MaxSize "5GB" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.YorkFans"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Edge.YorkFans"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.YorkFans"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Edge.YorkFans.Discounts" -MaxSize "5GB" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.YorkFans.Discounts"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Edge.YorkFans.Discounts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.YorkFans.Discounts"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Edge.DocumentEngine" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.DocumentEngine"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_datawriter,db_execute"}
    $dbAccessList += @{DBName = "Edge.DocumentEngine"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.DocumentEngine"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Edge.SuperiorRex" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $edgeTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Edge.SuperiorRex"; Server = $sqlServer1Name; AppAbbrList = "edge,eo,edbp"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Edge.SuperiorRex"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Edge.SuperiorRex"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Edge"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    ######################
    # Controls Resources #
    ######################

    $sysControlsTeamsRBAC = @(
        @{ AADGroupList = "SelNav-Azure-AppDev-SysControls"; RolesList = "Contributor"; EnvFilterList = "dev2,dev,qa"; }
    )

    ### Video Bandwidth Configurator and database
    &$resDir\create-sn-app.ps1 -AppAbbr "vbc" -Env $Env -Runtime "dotnet:8" -MinAppInstances $aspPool3MinAppInstances -AppServicePlanName $aspPool3Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $sysControlsTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $sysControlsTeamsRBAC
    &$resDir\create-sn-db.ps1 -Name "VideoBandwidthConfigurator" -Server $sqlServer1Name -MaxSize "2GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "VideoBandwidthConfigurator"; Server = $sqlServer1Name; AppAbbrList = "vbc"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "VideoBandwidthConfigurator"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "VideoBandwidthConfigurator"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    ### Product Selection Application
    $psAppSettings = @(
        @{AppSettingName = "PricingApiClientSecret"; KVSecretName = "ps-PricingApiClientSecret"},
        @{AppSettingName = "PricingTestApiClientSecret"; KVSecretName = "ps-PricingApiTestClientSecret"}
    )
    &$resDir\create-sn-app.ps1 -AppAbbr "ps" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool3MinAppInstances -AppServicePlanName $aspPool3Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings + $psAppSettings) -Location $location -Tags $sysControlsTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $sysControlsTeamsRBAC
       
    &$resDir\create-sn-db.ps1 -Name "FDB_Library" -Server $sqlServer1Name -CLIOptions "--edition GeneralPurpose --family Gen5 --capacity 8 --min-capacity 1 --compute-model Serverless --max-size 250GB --auto-pause-delay 60" -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "FDB_Library"; Server = $sqlServer1Name; AppAbbrList = "ps,fd"; Roles = "AimGtUserRole"}
    $dbAccessList += @{DBName = "FDB_Library"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-Db-Manager"; Roles = "db_datareader,AimGtUserRole,AimGtMkeAdminRole,db_execute,db_datawriter,db_backupoperator";}
    $dbAccessList += @{DBName = "FDB_Library"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,AimGtUserRole,AimGtMkeAdminRole,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "FDB_Library"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    if(@( "dev2", "dev" ) -contains $Env) {
        &$resDir\create-sn-db.ps1 -Name "FDB_Library_Test" -Server $sqlServer1Name -CLIOptions "--edition GeneralPurpose --family Gen5 --capacity 8 --min-capacity 1 --compute-model Serverless --max-size 250GB --auto-pause-delay 60" -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
        $dbAccessList += @{DBName = "FDB_Library_Test"; Server = $sqlServer1Name; AppAbbrList = "ps,fd"; Roles = "AimGtUserRole" ; EnvFilterList = "dev2,dev"}
        $dbAccessList += @{DBName = "FDB_Library_Test"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-Db-Manager"; Roles = "db_datareader,AimGtUserRole,AimGtMkeAdminRole,db_execute,db_datawriter,db_backupoperator";}
        $dbAccessList += @{DBName = "FDB_Library_Test"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,AimGtUserRole,AimGtMkeAdminRole,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
        #$dbAccessList += @{DBName = "FDB_Library_Test"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}
    }

    ### System Selection app and databases
    $sstAgentsByEnv = @{
        DEV2 = "j030m02k-44406,j030m02m-44406,j030m02k-44405,j030m02m-44405,j030m02i-44404"
        DEV = "j030m4tev0w-44405,j030m0al-44404,j030m0li-44405,j030m0li-44406,j030m0bc-44404,j030m0at-44405,j030m0at-44406"
        QA = "j030m09h-44404,j030m4tev09-44405,j030m0lk-44405,j030m0lk-44406,j030m0ah-44406,j030m0ah-44405,j030m0ai-44404,j030m05g-44404"
        SIT = ""
        PPE = ""
        PROD = ""
    }
    ## For a list of hybrid connections to set up: $sstAgentsByEnv["QA"].Split(",") | ForEach-Object{ "$subscriptionRelay-$_`r`n$($_.Split("-")[0]).go.johnsoncontrols.com`r`n$($_.Split("-")[1])`r`n" }
    $sstAgentHybridConnections = $sstAgentsByEnv[$Env].Split(",") | Where-Object {$_} | ForEach-Object{ @{Name = "$subscriptionRelay-$_"; Relay = $subscriptionRelay} }

    &$resDir\create-sn-app.ps1 -AppAbbr "ss" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool3MinAppInstances -HybridConnections $sstAgentHybridConnections -AppServicePlanName $aspPool3Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $sysControlsTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $sysControlsTeamsRBAC

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_BACnet" -Server $sqlServer1Name -MaxSize "2GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_BACnet"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_HVAC_BACnet"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_BACnet"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_ABCS_BACnet" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_ABCS_BACnet"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_HVAC_ABCS_BACnet"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_ABCS_BACnet"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_Configurable_Demo" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_Configurable_Demo"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_Configurable_Demo"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_Configurable_Demo"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_FireSec_Access_Control" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_FireSec_Access_Control"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_FireSec_Access_Control"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_FireSec_Access_Control"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_FireSec_CCTV" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_FireSec_CCTV"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_FireSec_CCTV"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_FireSec_CCTV"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_FireSec_FIRE" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_FireSec_FIRE"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_FireSec_FIRE"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_FireSec_FIRE"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_FireSec_Intrusion" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_FireSec_Intrusion"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_FireSec_Intrusion"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_FireSec_Intrusion"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_FireSec_Simplex" -Server $sqlServer1Name -MaxSize "2GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_FireSec_Simplex"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_FireSec_Simplex"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_FireSec_Simplex"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_ABCS_Network" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_ABCS_Network"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_HVAC_ABCS_Network"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_ABCS_Network"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_CCS" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_CCS"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_HVAC_CCS"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_CCS"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_CES" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_CES"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_HVAC_CES"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_CES"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_CMS" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_CMS"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_HVAC_CMS"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_CMS"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_Critical_Environments" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_Critical_Environments"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_HVAC_Critical_Environments"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_Critical_Environments"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_Custom" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_Custom"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_HVAC_Custom"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_Custom"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_Flexsys" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_Flexsys"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_HVAC_Flexsys"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_Flexsys"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_Custom_Panel" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_Custom_Panel"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_HVAC_Custom_Panel"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_Custom_Panel"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_LON" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_LON"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_HVAC_LON"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_LON"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_MEMs" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_MEMs"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_HVAC_MEMs"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_MEMs"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_Network" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_Network"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_HVAC_Network"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_Network"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_SCC" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_SCC"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_HVAC_SCC"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_SCC"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_TEC" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_TEC"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_HVAC_TEC"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_TEC"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_HVAC_Verasys" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_HVAC_Verasys"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"; AADGroupList = "SelNav-Azure-AppDev-SysControls"}
    $dbAccessList += @{DBName = "SST_HVAC_Verasys"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_HVAC_Verasys"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_Ref_Industrial" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_Ref_Industrial"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_Ref_Industrial"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_Ref_Industrial"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_ModelGroupMaster" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_ModelGroupMaster"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "SST_ModelGroupMaster"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_ModelGroupMaster"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "SST_DocumentGeneration" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "SST_DocumentGeneration"; Server = $sqlServer1Name; AppAbbrList = "ss"; Roles = "db_datareader,db_execute"; AADGroupList = "SelNav-Azure-AppDev-SysControls"}
    $dbAccessList += @{DBName = "SST_DocumentGeneration"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "SST_DocumentGeneration"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    ### SS Panel Selection 
    &$resDir\create-sn-app.ps1 -AppAbbr "ssps" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool3MinAppInstances -AppServicePlanName $aspPool3Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $sysControlsTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $sysControlsTeamsRBAC

    ### Controls Budget Tool - CBT App and Database 
    &$resDir\create-sn-app.ps1 -AppAbbr "cbt" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool3MinAppInstances -AppServicePlanName $aspPool3Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $sysControlsTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $sysControlsTeamsRBAC
    &$resDir\create-sn-db.ps1 -Name "CBT.Database" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "CBT.Database"; Server = $sqlServer1Name; AppAbbrList = "cbt"; Roles = "db_datareader,db_datawriter,db_execute"}
    $dbAccessList += @{DBName = "CBT.Database"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "CBT.Database"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-app.ps1 -AppAbbr "cha" -Env $Env -Runtime "dotnet:8" -MinAppInstances $aspPool3MinAppInstances -AppServicePlanName $aspPool3Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $sysControlsTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $sysControlsTeamsRBAC
    &$resDir\create-sn-db.ps1 -Name "ContractHistorical" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "ContractHistorical"; Server = $sqlServer1Name; AppAbbrList = "cbt,cha"; Roles = "db_datareader,db_datawriter,db_execute"}
    $dbAccessList += @{DBName = "ContractHistorical"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "ContractHistorical"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    ### Electrical Budget Estimate - EBE 
    &$resDir\create-sn-app.ps1 -AppAbbr "ebe" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool3MinAppInstances -AppServicePlanName $aspPool3Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $sysControlsTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $sysControlsTeamsRBAC

    ### Fire Detection
    &$resDir\create-sn-app.ps1 -AppAbbr "fd" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool3MinAppInstances -AppServicePlanName $aspPool3Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings)  -HybridConnections @($smtpHybridConnection) -Location $location -Tags $sysControlsTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $sysControlsTeamsRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "fda" -Env $Env -Runtime "dotnet:8" -MinAppInstances $aspPool3MinAppInstances -AppServicePlanName $aspPool3Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $sysControlsTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $sysControlsTeamsRBAC

    &$resDir\create-sn-db.ps1 -Name "FireDetection" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "FireDetection"; Server = $sqlServer1Name; AppAbbrList = "fda"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "FireDetection"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "FireDetection"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    ### Fire Detection Background Processor
    &$resDir\create-sn-fn.ps1 -AppAbbr "fdbp" -Env $Env -MinAppInstances $aspFnPool4MinAppInstances -Location $location -UseConsumptionPlan $false -AppServicePlanName $coreSysControlsFnPoolName -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Tags $sysControlsTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $sysControlsTeamsRBAC
    $fnAccessList += @{FunctionAppAbbr = "fdbp"; AppAbbrList = "fd"}

    ### Point Schedule Matrix web app & database
    &$resDir\create-sn-app.ps1 -AppAbbr "psm" -Env $Env -Runtime "dotnet:8" -MinAppInstances $aspPool3MinAppInstances -AppServicePlanName $aspPool3Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $sysControlsTags -FrontDoorId $frontDoorIdTest -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $sysControlsTeamsRBAC
    &$resDir\create-sn-db.ps1 -Name "PointScheduleMatrix" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "PointScheduleMatrix"; Server = $sqlServer1Name; AppAbbrList = "psm"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "PointScheduleMatrix"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "PointScheduleMatrix"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}
    
    ### Controller Selection Tool web app & database
    &$resDir\create-sn-app.ps1 -AppAbbr "cnst" -Env $Env -Runtime "dotnet:8" -MinAppInstances $aspPool3MinAppInstances -AppServicePlanName $aspPool3Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $sysControlsTags -FrontDoorId $frontDoorIdTest -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $sysControlsTeamsRBAC
    &$resDir\create-sn-db.ps1 -Name "ControllerSelectionTool" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "ControllerSelectionTool"; Server = $sqlServer1Name; AppAbbrList = "cnst"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "ControllerSelectionTool"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "ControllerSelectionTool"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-fn.ps1 -AppAbbr "csat" -Env $Env -MinAppInstances $aspFnPool4MinAppInstances -Location $location -UseConsumptionPlan $false -AppServicePlanName $coreSysControlsFnPoolName -Tags $sysControlsTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $sysControlsTeamsRBAC
    $fnAccessList += @{FunctionAppAbbr = "csat"; AppAbbrList = "cnst"}
    
    ### Factory Package Controls web app & database
    $sysControlsScaleControllerLogSetting = (P "None;DEV2,DEV:Verbose")
    $sysControlsFnAppSettings = @(@{AppSettingName = "SCALE_CONTROLLER_LOGGING_ENABLED"; Value = "AppInsights:$sysControlsScaleControllerLogSetting"})

    &$resDir\create-sn-app.ps1 -AppAbbr "fpc" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool3MinAppInstances -AppServicePlanName $aspPool3Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -HybridConnections @($smtpHybridConnection) -Location $location -Tags $sysControlsTags -FrontDoorId $frontDoorIdTest -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $sysControlsTeamsRBAC
    &$resDir\create-sn-fn.ps1 -AppAbbr "fpcdg" -Env $Env -MinAppInstances $aspFnPool4MinAppInstances -Location $location -AppSettings $sysControlsFnAppSettings -Tags $sysControlsTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -UseConsumptionPlan $false -AppServicePlanName $coreSysControlsFnPoolName -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $sysControlsTeamsRBAC -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings)
    $storageAccessList += @{StorageAccount = $sharedStorageName; StorageAccountName="Shared"; AppAbbrList = "fpcdg"}
    &$resDir\create-sn-db.ps1 -Name "FactoryPackageControls" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $sysControlsTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "FactoryPackageControls"; Server = $sqlServer1Name; AppAbbrList = "fpc,fpcdg"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "FactoryPackageControls"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "FactoryPackageControls"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-SysControls"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}
    
    ######################
    # Chillers Resources #
    ######################

    ### Chillers dev/tester RBAC permissions for resources
    $chillersTeamRBAC = @(
        @{ AADGroupList = "SelNav-Azure-AppDev-Chillers"; RolesList = "Contributor"; EnvFilterList = "dev2,dev,qa"}
    )

    ### Create Event Hubs for CBO, CUO, CSBO, and CREAR
    &$resDir\create-sn-eh.ps1 -Env $Env -Location $location -AppAbbr "cbo" -LogDir $LogDir -MaxThroughputForAutoInflate 40 -RBACPermissions $chillersTeamRBAC -Tags $chillersTags -AzureData $azureOutput
    $cboEHName = $azureOutput."ehns-cbo-$location".name
    $ehAccessList += @{EventHub = $cboEHName; CustomAppSettingName = "EventHubsConnection"; AppAbbrList = "cbo"}

    &$resDir\create-sn-eh.ps1 -Env $Env -Location $location -AppAbbr "cuo" -LogDir $LogDir -MaxThroughputForAutoInflate 40 -RBACPermissions $chillersTeamRBAC -Tags $chillersTags -AzureData $azureOutput
    $cuoEHName = $azureOutput."ehns-cuo-$location".name
    $ehAccessList += @{EventHub = $cuoEHName; CustomAppSettingName = "EventHubsConnection"; AppAbbrList = "cuo"}

    &$resDir\create-sn-eh.ps1 -Env $Env -Location $location -AppAbbr "csbo" -LogDir $LogDir -MaxThroughputForAutoInflate 40 -RBACPermissions $chillersTeamRBAC -Tags $chillersTags -AzureData $azureOutput
    $csboEHName = $azureOutput."ehns-csbo-$location".name
    $ehAccessList += @{EventHub = $csboEHName; CustomAppSettingName = "EventHubsConnection"; AppAbbrList = "csbo"}

    &$resDir\create-sn-eh.ps1 -Env $Env -Location $location -AppAbbr "crear" -LogDir $LogDir -MaxThroughputForAutoInflate 40 -RBACPermissions $chillersTeamRBAC -Tags $chillersTags -AzureData $azureOutput
    $crearEHName = $azureOutput."ehns-crear-$location".name
    $ehAccessList += @{EventHub = $crearEHName; CustomAppSettingName = "EventHubsConnection"; AppAbbrList = "crear"}

    ### Chillers migrated apps and databases
    &$resDir\create-sn-app.ps1 -AppAbbr "chl" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool4MinAppInstances -AppServicePlanName $aspPool4Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $chillersTeamRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "cspsa" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool4MinAppInstances -AppServicePlanName $aspPool4Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $chillersTeamRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "cra" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool4MinAppInstances -AppServicePlanName $aspPool4Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $chillersTeamRBAC
    &$resDir\create-sn-db.ps1 -Name "ChillersDatabase" -Server $sqlServer1Name -MaxSize "20GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $chillersTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "ChillersDatabase"; Server = $sqlServer1Name; AppAbbrList = "chl,cra"; Roles = "db_datareader,db_datawriter,db_execute"}
    $dbAccessList += @{DBName = "ChillersDatabase"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "ChillersDatabase"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Chillers.CSPS.Database" -Server $sqlServer1Name -MaxSize "10GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $chillersTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Chillers.CSPS.Database"; Server = $sqlServer1Name; AppAbbrList = "cspsa,crs"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Chillers.CSPS.Database"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev,qa"}
    $dbAccessList += @{DBName = "Chillers.CSPS.Database"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Chillers.CSPS.PricingLeadTime.Database" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $chillersTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Chillers.CSPS.PricingLeadTime.Database"; Server = $sqlServer1Name; AppAbbrList = "cspsa"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Chillers.CSPS.PricingLeadTime.Database"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev,qa"}
    $dbAccessList += @{DBName = "Chillers.CSPS.PricingLeadTime.Database"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Chillers.LineCard" -Server $sqlServer1Name -MaxSize "10GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $chillersTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Chillers.LineCard"; Server = $sqlServer1Name; AppAbbrList = "chl,cra"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Chillers.LineCard"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev,qa"}
    $dbAccessList += @{DBName = "Chillers.LineCard"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "sit,ppe"}

    $crsAppSettings = @(
        @{AppSettingName = "ConnectionStrings:AzureWebJobsStorage"; KVSecretName = "$sharedStorageName-ConnectionString"}
    )

    ### Create Chillers Rating Service web app (using separate ASP)
    &$resDir\create-sn-app.ps1 -AppAbbr "crs" -Env $Env -Runtime "dotnet:6" -Use32Bit $false -MinAppInstances $aspPool4MinAppInstances -Location $location -AppServicePlanName $aspPool4Name -KVAppSettings ($v2SecurityAppSettings + $crsAppSettings) -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $chillersTeamRBAC

    $chillersScaleControllerLogSetting = (P "None;DEV2,DEV,QA:Verbose")
    $chlRatingsFnAppSettings = @(@{AppSettingName = "SCALE_CONTROLLER_LOGGING_ENABLED"; Value = "AppInsights:$chillersScaleControllerLogSetting"})

    ### Create Chillers storage account to back the DXChill Function app
    &$resDir\create-sn-st.ps1 -Env $Env -Location $location -StorageSku "Standard_LRS" -AppAbbr "cred" -AllowForContainerLevelPublicAccessEnablement $false -RBACPermissions $chillersTeamRBAC -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    $credStorageName = $azureOutput."st-cred$location".name
    $peName = "$($vnetName.Replace("vnet","pe"))-$credStorageName"
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $credStorageName -Name "$peName-blob" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "blob" -PrivateDnsZone "privatelink.blob.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $credStorageName -Name "$peName-table" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "table" -PrivateDnsZone "privatelink.table.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $credStorageName -Name "$peName-queue" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "queue" -PrivateDnsZone "privatelink.queue.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $credStorageName -Name "$peName-file" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "file" -PrivateDnsZone "privatelink.file.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir

    ### Create Chillers storage account to back the CBO Function app
    &$resDir\create-sn-st.ps1 -Env $Env -Location $location -StorageSku "Standard_LRS" -AppAbbr "cbo" -AllowForContainerLevelPublicAccessEnablement $false -RBACPermissions $chillersTeamRBAC -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    $cboStorageName = $azureOutput."st-cbo$location".name
    $peName = "$($vnetName.Replace("vnet","pe"))-$cboStorageName"
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $cboStorageName -Name "$peName-blob" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "blob" -PrivateDnsZone "privatelink.blob.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $cboStorageName -Name "$peName-table" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "table" -PrivateDnsZone "privatelink.table.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $cboStorageName -Name "$peName-queue" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "queue" -PrivateDnsZone "privatelink.queue.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $cboStorageName -Name "$peName-file" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "file" -PrivateDnsZone "privatelink.file.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir

    ### Create Chillers storage account to back the CUO Function app
    &$resDir\create-sn-st.ps1 -Env $Env -Location $location -StorageSku "Standard_LRS" -AppAbbr "cuo" -AllowForContainerLevelPublicAccessEnablement $false -RBACPermissions $chillersTeamRBAC -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    $cuoStorageName = $azureOutput."st-cuo$location".name
    $peName = "$($vnetName.Replace("vnet","pe"))-$cuoStorageName"
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $cuoStorageName -Name "$peName-blob" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "blob" -PrivateDnsZone "privatelink.blob.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $cuoStorageName -Name "$peName-table" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "table" -PrivateDnsZone "privatelink.table.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $cuoStorageName -Name "$peName-queue" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "queue" -PrivateDnsZone "privatelink.queue.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $cuoStorageName -Name "$peName-file" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "file" -PrivateDnsZone "privatelink.file.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir

    ### Create Chillers storage account to back the CSBO Function app
    &$resDir\create-sn-st.ps1 -Env $Env -Location $location -StorageSku "Standard_LRS" -AppAbbr "csbo" -AllowForContainerLevelPublicAccessEnablement $false -RBACPermissions $chillersTeamRBAC -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    $csboStorageName = $azureOutput."st-csbo$location".name
    $peName = "$($vnetName.Replace("vnet","pe"))-$csboStorageName"
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $csboStorageName -Name "$peName-blob" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "blob" -PrivateDnsZone "privatelink.blob.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $csboStorageName -Name "$peName-table" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "table" -PrivateDnsZone "privatelink.table.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $csboStorageName -Name "$peName-queue" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "queue" -PrivateDnsZone "privatelink.queue.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $csboStorageName -Name "$peName-file" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "file" -PrivateDnsZone "privatelink.file.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir

    ### Create Chillers storage account to back the CREAR Function app
    &$resDir\create-sn-st.ps1 -Env $Env -Location $location -StorageSku "Standard_LRS" -AppAbbr "crear" -AllowForContainerLevelPublicAccessEnablement $false -RBACPermissions $chillersTeamRBAC -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    $crearStorageName = $azureOutput."st-crear$location".name
    $peName = "$($vnetName.Replace("vnet","pe"))-$crearStorageName"
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $crearStorageName -Name "$peName-blob" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "blob" -PrivateDnsZone "privatelink.blob.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $crearStorageName -Name "$peName-table" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "table" -PrivateDnsZone "privatelink.table.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $crearStorageName -Name "$peName-queue" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "queue" -PrivateDnsZone "privatelink.queue.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $crearStorageName -Name "$peName-file" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "file" -PrivateDnsZone "privatelink.file.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir

    ### Create Chillers Functions

    ## Durable function apps
    $aspForChillersDurableFunctionApps = $aspFnPool2Name
    $aspForChillersDurableFunctionAppsMinInstances = (P "DEV2:$aspFnPool2MinAppInstances;$aspFnPool1MinAppInstances")
    &$resDir\create-sn-fn.ps1 -AppAbbr "cbo" -Env $Env -MinAppInstances $aspForChillersDurableFunctionAppsMinInstances -Use32Bit $false -Location $location -PremiumPrewarmedInstances 5 -UseConsumptionPlan $false -AppServicePlanName $aspForChillersDurableFunctionApps -AppSettings $chlRatingsFnAppSettings -KVAppSettings $v2SecurityAppSettings -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:20") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $cboStorageName -RBACPermissions $chillersTeamRBAC
    $fnAccessList += @{FunctionAppAbbr = "cbo"; AppAbbrList = "crs,chl"}
    &$resDir\create-sn-fn.ps1 -AppAbbr "cuo" -Env $Env -MinAppInstances $aspForChillersDurableFunctionAppsMinInstances -Use32Bit $false -Location $location -PremiumPrewarmedInstances 5 -UseConsumptionPlan $false -AppServicePlanName $aspForChillersDurableFunctionApps -AppSettings $chlRatingsFnAppSettings -KVAppSettings $v2SecurityAppSettings -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $cuoStorageName -RBACPermissions $chillersTeamRBAC
    $fnAccessList += @{FunctionAppAbbr = "cuo"; AppAbbrList = "crs,chl"}
    &$resDir\create-sn-fn.ps1 -AppAbbr "csbo" -Env $Env -MinAppInstances $aspForChillersDurableFunctionAppsMinInstances -Location $location -PremiumPrewarmedInstances 5 -UseConsumptionPlan $false -AppServicePlanName $aspForChillersDurableFunctionApps -AppSettings $chlRatingsFnAppSettings -KVAppSettings $v2SecurityAppSettings -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $csboStorageName -RBACPermissions $chillersTeamRBAC
    &$resDir\create-sn-fn.ps1 -AppAbbr "crear" -Env $Env -MinAppInstances $aspForChillersDurableFunctionAppsMinInstances -Location $location -PremiumPrewarmedInstances 5 -UseConsumptionPlan $false -AppServicePlanName $aspForChillersDurableFunctionApps -AppSettings $chlRatingsFnAppSettings -KVAppSettings $v2SecurityAppSettings -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $crearStorageName -RBACPermissions $chillersTeamRBAC
    $fnAccessList += @{FunctionAppAbbr = "crear"; AppAbbrList = "crs"}

    #Other function apps
    &$resDir\create-sn-fn.ps1 -AppAbbr "cred" -Env $Env -MinAppInstances $aspFnPool5MinAppInstances -Location $location -PremiumPrewarmedInstances 5 -UseConsumptionPlan $false -AppServicePlanName $aspFnPool5Name -StorageName $credStorageName -AppSettings $chlRatingsFnAppSettings -KVAppSettings $v2SecurityAppSettings -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $chillersTeamRBAC

    &$resDir\create-sn-fn.ps1 -AppAbbr "crd" -Env $Env -MinAppInstances 2 -Location $location -PremiumPrewarmedInstances 5 -UseConsumptionPlan $false -AppServicePlanName $aspFnPool1Name -StorageName $sharedStorageName -AppSettings $chlRatingsFnAppSettings -KVAppSettings $v2SecurityAppSettings -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $chillersTeamRBAC
    &$resDir\create-sn-fn.ps1 -AppAbbr "crel" -Env $Env -MinAppInstances $aspFnPool1MinAppInstances -Location $location -PremiumPrewarmedInstances 5 -UseConsumptionPlan $false -AppServicePlanName $aspFnPool1Name -AppSettings $chlRatingsFnAppSettings -KVAppSettings $v2SecurityAppSettings -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $chillersTeamRBAC
    &$resDir\create-sn-fn.ps1 -AppAbbr "crex" -Env $Env -MinAppInstances $aspFnPool1MinAppInstances -Location $location -UseConsumptionPlan $false -AppServicePlanName $aspFnPool1Name -AppSettings $chlRatingsFnAppSettings -KVAppSettings $v2SecurityAppSettings -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $chillersTeamRBAC
    &$resDir\create-sn-fn.ps1 -AppAbbr "creh" -Env $Env -MinAppInstances $aspFnPool1MinAppInstances -Location $location -UseConsumptionPlan $false -AppServicePlanName $aspFnPool1Name -AppSettings $chlRatingsFnAppSettings -KVAppSettings $v2SecurityAppSettings -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $chillersTeamRBAC
    &$resDir\create-sn-fn.ps1 -AppAbbr "crei" -Env $Env -MinAppInstances $aspFnPool1MinAppInstances -Location $location -UseConsumptionPlan $false -AppServicePlanName $aspFnPool1Name -AppSettings $chlRatingsFnAppSettings -KVAppSettings $v2SecurityAppSettings -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $chillersTeamRBAC
    &$resDir\create-sn-fn.ps1 -AppAbbr "creae" -Env $Env -MinAppInstances $aspFnPool1MinAppInstances -Location $location -UseConsumptionPlan $false -AppServicePlanName $aspFnPool1Name -AppSettings $chlRatingsFnAppSettings -KVAppSettings $v2SecurityAppSettings -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $chillersTeamRBAC
    &$resDir\create-sn-fn.ps1 -AppAbbr "ccem" -Env $Env -MinAppInstances $aspFnPool1MinAppInstances -Location $location -UseConsumptionPlan $false -AppServicePlanName $aspFnPool1Name -AppSettings $chlRatingsFnAppSettings -KVAppSettings $v2SecurityAppSettings -Tags $chillersTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $chillersTeamRBAC
    $fnAccessList += @{FunctionAppAbbr = "ccem"; AppAbbrList = "crs"}

    ### Create Chillers.RatingMappings database
    &$resDir\create-sn-db.ps1 -Name "Chillers.RatingMappings" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $chillersTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Chillers.RatingMappings"; Server = $sqlServer1Name; AppAbbrList = "crs,cbo,cuo,cred,crear,crel,crex,creh,crei,creae,ccem,csbo"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Chillers.RatingMappings"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Chillers.RatingMappings"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    ### Create Chillers.Xengine database
    &$resDir\create-sn-db.ps1 -Name "Chillers.Xengine" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $chillersTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Chillers.Xengine"; Server = $sqlServer1Name; AppAbbrList = "crex"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Chillers.Xengine"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Chillers.Xengine"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    ### Create Chillers.Cache database
    $maxChillersCacheDbSize = (P "200GB;PROD:400GB")
    &$resDir\create-sn-db.ps1 -Name "Chillers.Cache" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -MaxSize $maxChillersCacheDbSize -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $chillersTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Chillers.Cache"; Server = $sqlServer1Name; AppAbbrList = "crs,cuo,cbo,csbo"; ConnStrSuffix = "Max Pool Size=400;"; Roles = "db_datareader,db_datawriter,db_execute"}
    $dbAccessList += @{DBName = "Chillers.Cache"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Chillers.Cache"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    ### Create Chillers Ratings Service Bus (and queues)
    $crsSBQueues = @(
        @{Name="pumps-unitprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="armstrong-process";LockDuration="PT5M";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="armstrong-complete";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="dxchill-unitprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="dxchill-unitsecondary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="dxchill-batchprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=$chillersBatchQueueMaxDeliveryCount},
        @{Name="dxchill-batchsecondary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=$chillersBatchQueueMaxDeliveryCount},
        @{Name="dxchill-largebatchprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=$chillersBatchQueueMaxDeliveryCount},
        @{Name="dxchill-largebatchsecondary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=$chillersBatchQueueMaxDeliveryCount},
        @{Name="xengine";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="xengine-unitprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="xengine-unitsecondary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="xengine-batchprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=$chillersBatchQueueMaxDeliveryCount},
        @{Name="stcsound-unitprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="stcsound-batchprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="hisela-unitprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="interpolation-unitprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="interpolation-batchprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="aecworks-unitprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="aecworks-batchprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="ecodesign";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="tewi";LockDuration="PT5M";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="ltc-unitprimary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="ltc-unitsecondary";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="ltc-batchprimary";LockDuration="PT5M";EnableDeadLettering=$true;MaxDeliveryCount=$chillersBatchQueueMaxDeliveryCount},
        @{Name="completed-ratings";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2}
        @{Name="completed-unit-ratings";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="slow-batch-input-conversion";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="fast-batch-input-conversion";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="batch-input-conversion-result";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="batch-output-conversion";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="batch-output-conversion-result";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="batch-pick-list-conversion";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="batch-pick-list-conversion-result";LockDuration="PT30S";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="rating-metadata";LockDuration="PT5M";EnableDeadLettering=$true;MaxDeliveryCount=2},
        @{Name="completed-sub-batch-ratings";LockDuration="PT5M";EnableDeadLettering=$true;MaxDeliveryCount=2}
    )
    &$resDir\create-sn-sb.ps1 -Env $Env -Location $location -AppAbbr crs -LogDir $LogDir -Queues $crsSBQueues -RBACPermissions $chillersTeamRBAC -Tags $chillersTags -AzureData $azureOutput
    $crsSBName = $azureOutput."sb-crs-$location".name
    $sbAccessList += @{ServiceBus = $crsSBName; ServiceBusName="CRS"; AppAbbrList = "crs,cbo,csbo,cuo,crd,cred,crel,crex,crear,creh,crei,creae,ccem"}

    ## Create CRS Storage Account (containers now created in crs deployment scripts)
    $crsBlobContainers = @()
    ##$crsBlobContainers = @(
    ##    @{Name="batch"; PubAccess="off"},
    ##    @{Name="ratings"; PubAccess="off"},
    ##    @{Name="dxchill-results-debug"; PubAccess="off"}
    ##)

    ## Define the management policies for the CRS storage account
    $crsAccountManagementPolicies = @(
        #chiller-engine-files
        @{name="ChillerEngineFilesCleanupLifecycle"; type="Lifecycle"; enabled=$true; definition=@{
            actions=@{baseBlob=@{delete=@{daysAfterModificationGreaterThan=1};};}; 
            filters=@{blobTypes=@("blockBlob");prefixMatch=@("chiller-ratings-container/EngineFiles")};
        };}
        #chiller-ratings-to-cool
        @{name="ChillerRatingsToCoolLifecycle"; type="Lifecycle"; enabled=$true; definition=@{
            actions=@{baseBlob=@{tierToCool=@{daysAfterLastAccessTimeGreaterThan=15};};}; 
            filters=@{blobTypes=@("blockBlob");prefixMatch=@("chiller-ratings-container")};
        };}
        #chiller-rating-delete
        @{name="ChillerRatingsCleanupLifecycle"; type="Lifecycle"; enabled=$true; definition=@{
            actions=@{baseBlob=@{delete=@{daysAfterLastAccessTimeGreaterThan=(P "14;PROD:60")};};}; 
            filters=@{blobTypes=@("blockBlob");prefixMatch=@("chiller-ratings-container")};
        };}
        #orchestrators-shared-state-delete
        @{name="OrchestrationsStateCleanupLifecycle"; type="Lifecycle"; enabled=$true; definition=@{
            actions=@{baseBlob=@{delete=@{daysAfterLastAccessTimeGreaterThan=1};};}; 
            filters=@{blobTypes=@("blockBlob");prefixMatch=@("orchestrators-shared-state-container")};
        };}
        #chiller-batch-container-delete
        @{name="BatchContainerCleanupLifecycle"; type="Lifecycle"; enabled=$true; definition=@{
            actions=@{baseBlob=@{delete=@{daysAfterLastAccessTimeGreaterThan=(P "14;PROD:60")};};}; 
            filters=@{blobTypes=@("blockBlob");prefixMatch=@("chiller-batch-container")};
        };}
    )

    ### Create Chillers Rating Storage (and queue and containers)
    &$resDir\create-sn-st.ps1 -Env $Env -Location $location -AppAbbr "crs" -BlobContainers $crsBlobContainers -ManagementPolicyRules $crsAccountManagementPolicies -EnableLastAccessTracking $true -AllowForContainerLevelPublicAccessEnablement $false -RBACPermissions $chillersTeamRBAC -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    $crsStorageName = $azureOutput."st-crs$location".name
    $peName = "$($vnetName.Replace("vnet","pe"))-$crsStorageName"
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $crsStorageName -Name "$peName-blob" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "blob" -PrivateDnsZone "privatelink.blob.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $crsStorageName -Name "$peName-queue" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "queue" -PrivateDnsZone "privatelink.queue.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir
    &$resDir\create-sn-pe.ps1 -ResourceGroup $ResourceGroup -Location $location -VirtualNetworkName $vnetName -SubnetName $servicesSubNetName -PrivateLinkResourceName $crsStorageName -Name "$peName-table" -PrivateLinkResourceType "Microsoft.Storage/storageAccounts" -GroupId "table" -PrivateDnsZone "privatelink.table.core.windows.net" -Tags $chillersTags -AzureData $azureOutput -LogDir $LogDir

    ### Grant app access to Chillers Ratings Results Storage
    $storageAccessList += @{StorageAccount = $crsStorageName; StorageAccountName="CRS"; AppAbbrList = "crs,cbo,cuo,cred,crel,crex,crear,creh,crei,creae,ccem,csbo"}

    ########################################
    # Ducted Systems (AppliedDX) Resources #
    ########################################

    ### DX dev/tester RBAC permissions for resources
    $dxTeamRBAC = @(
        @{ AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; RolesList = "Contributor"; EnvFilterList = "dev2,dev,qa"}
    )

    # JCDSE app and database
    $jcdsDrawingServer = (P "DEV2,DEV,QA:tm-yw-clst1-dev;SIT,PPE,PROD:tm-yw-clst-prod")
    $jcdsServerHybridConnection = @{Name = "$subscriptionRelay-$jcdsDrawingServer-443"; Relay = $subscriptionRelay}
    &$resDir\create-sn-app.ps1 -AppAbbr "jcdse" -Env $Env -Runtime "dotnet:8" -MinAppInstances $aspPool5MinAppInstances -AppServicePlanName $aspPool5Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -HybridConnections @($jcdsServerHybridConnection, $drawingServerHybridConnection) -Location $location -Tags $docGenTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $dxTeamRBAC
    &$resDir\create-sn-fn.ps1 -AppAbbr "jcdsebp" -Env $Env -MinAppInstances $aspFnPool4MinAppInstances -Location $location -UseConsumptionPlan $false -AppServicePlanName $coreSysControlsFnPoolName -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Tags $sysControlsTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -StorageName $sharedStorageName -RBACPermissions $dxTeamRBAC
    $fnAccessList += @{FunctionAppAbbr = "jcdsebp"; AppAbbrList = "jcdse"}
    &$resDir\create-sn-db.ps1 -Name "JCDSEngine" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "JCDSEngine"; Server = $sqlServer1Name; Roles = "db_datareader,db_datawriter,db_execute"; AppAbbrList = "jcdse,jcdsebp"}
    $dbAccessList += @{DBName = "JCDSEngine"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_execute,db_viewdefinition,db_datawriter"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "JCDSEngine"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    # AppliedDX Migrated app resources #
    &$resDir\create-sn-app.ps1 -AppAbbr "ad" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool6MinAppInstances -Use32Bit $false -AppServicePlanName $aspPool6Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -HybridConnections @($smtpHybridConnection) -Location $location -Tags $appliedTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $dxTeamRBAC

    &$resDir\create-sn-db.ps1 -Name "Series100" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $appliedTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Series100"; Server = $sqlServer1Name; AppAbbrList = "ad"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Series100"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Series100"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "Shared.Airside" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $appliedTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Shared.Airside"; Server = $sqlServer1Name; AppAbbrList = "ad"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "Shared.Airside"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Shared.Airside"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}
   
    # AppliedDX UPG apps
    &$resDir\create-sn-app.ps1 -AppAbbr "adu" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool6MinAppInstances -Use32Bit $false -AppServicePlanName $aspPool6Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -HybridConnections @($smtpHybridConnection) -Location $location -Tags $appliedTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $dxTeamRBAC
    &$resDir\create-sn-app.ps1 -AppAbbr "uoa" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $appliedTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $dxTeamRBAC

    # AppliedDX UPG Databases
    &$resDir\create-sn-db.ps1 -Name "ADU.Cache" -Server $sqlServer1Name -MaxSize "10GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $appliedTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "ADU.Cache"; Server = $sqlServer1Name; AppAbbrList = "adu"; Roles = "db_datareader,db_datawriter,db_execute"}
    $dbAccessList += @{DBName = "ADU.Cache"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "ADU.Cache"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "ResidentialData" -Server $sqlServer1Name -MaxSize "5GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $appliedTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "ResidentialData"; Server = $sqlServer1Name; AppAbbrList = "adu"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "ResidentialData"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "ResidentialData"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "AppliedDX.SFA" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $appliedTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "AppliedDX.SFA"; Server = $sqlServer1Name; AppAbbrList = "adu,ad,uoa,gry"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "AppliedDX.SFA"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "AppliedDX.SFA"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "AppliedDX.SAP" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $appliedTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "AppliedDX.SAP"; Server = $sqlServer1Name; AppAbbrList = "adu,gry"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "AppliedDX.SAP"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "AppliedDX.SAP"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "EspPackage" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $appliedTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "EspPackage"; Server = $sqlServer1Name; AppAbbrList = "adu"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "EspPackage"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "EspPackage"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "MasterDataManagement" -Server $sqlServer1Name -MaxSize "5GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $appliedTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "MasterDataManagement"; Server = $sqlServer1Name; AppAbbrList = "adu,uoa"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "MasterDataManagement"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "MasterDataManagement"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "ProdCharacteristicsRules" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $appliedTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "ProdCharacteristicsRules"; Server = $sqlServer1Name; AppAbbrList = "adu,ad,uoa,gry"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "ProdCharacteristicsRules"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "ProdCharacteristicsRules"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "RatingPlateData" -Server $sqlServer1Name -MaxSize "5GB" -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $appliedTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "RatingPlateData"; Server = $sqlServer1Name; AppAbbrList = "adu,gry"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "RatingPlateData"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "RatingPlateData"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    &$resDir\create-sn-db.ps1 -Name "NxTrendCatalog" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $appliedTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "NxTrendCatalog"; Server = $sqlServer1Name; AppAbbrList = "adu,uoa"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "NxTrendCatalog"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "NxTrendCatalog"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}   

    &$resDir\create-sn-app.ps1 -AppAbbr "gry" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool6MinAppInstances -AppServicePlanName $aspPool6Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -HybridConnections @($smtpHybridConnection) -Location $location -Tags $appliedTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $dxTeamRBAC

    &$resDir\create-sn-db.ps1 -Name "Gryphon" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $appliedTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "Gryphon"; Server = $sqlServer1Name; AppAbbrList = "gry,adu"; Roles = "db_datareader,db_datawriter,db_execute"}
    $dbAccessList += @{DBName = "Gryphon"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_datawriter,db_execute,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "Gryphon"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}

    ############################################
    # All search service access permissions for location
    ############################################

    $appsCreated | ConvertTo-Json -Depth 50 | Set-Content (Join-Path $LogDir "apps.json")

    $searchServiceAccessList | ConvertTo-Json -Depth 50 | Set-Content (Join-Path $LogDir "ss-access.json")
    &$resDir\grant-apps-ss-access.ps1 -AccessList $searchServiceAccessList -Env $Env -Location $location -AppsCreated $appsCreated -LogDir $LogDir

    ############################################
    # All event hub access permissions for location
    ############################################

    $ehAccessList | ConvertTo-Json -Depth 50 | Set-Content (Join-Path $LogDir "eh-access.json")
    &$resDir\grant-apps-eh-access.ps1 -AccessList $ehAccessList -Env $Env -Location $location -AppsCreated $appsCreated -LogDir $LogDir

    ############################################
    # All service bus access permissions for location
    ############################################

    $sbAccessList | ConvertTo-Json -Depth 50 | Set-Content (Join-Path $LogDir "sb-access.json")
    &$resDir\grant-apps-sb-access.ps1 -AccessList $sbAccessList -Env $Env -Location $location -AppsCreated $appsCreated -LogDir $LogDir

    ############################################
    # All storage account access permissions for location
    ############################################

    $storageAccessList | ConvertTo-Json -Depth 50 | Set-Content (Join-Path $LogDir "st-access.json")
    &$resDir\grant-apps-storage-access.ps1 -AccessList $storageAccessList -Env $Env -Location $location -AppsCreated $appsCreated -LogDir $LogDir

    ############################################
    # All function app permissions for location
    ############################################

    $fnAccessList | ConvertTo-Json -Depth 50 | Set-Content (Join-Path $LogDir "fn-access.json")
    &$resDir\grant-apps-function-access.ps1 -AccessList $fnAccessList -Env $Env -Location $location -AppsCreated $appsCreated -LogDir $LogDir

    ########################################
    # All database permissions for location
    ########################################

    $dbAccessList | ConvertTo-Json -Depth 50 | Set-Content (Join-Path $LogDir "sqldb-access.json")
    &$resDir\grant-apps-db-access.ps1 -AccessList $dbAccessList -Env $Env -Location $location -AppsCreated $appsCreated -LogDir $LogDir

    ########################################
    # All Cosmos DB permissions for location
    ########################################

    $cdbAccessList | ConvertTo-Json -Depth 50 | Set-Content (Join-Path $LogDir "cdb-access.json")
    &$resDir\grant-apps-cdb-access.ps1 -ResourceGroup $ResourceGroup -AccessList $cdbAccessList -Env $Env -Location $location -AppsCreated $appsCreated -LogDir $LogDir

    ########################################
    # All SignalR permissions for location
    ########################################

    $srsAccessList | ConvertTo-Json -Depth 50 | Set-Content (Join-Path $LogDir "srs-access.json")
    &$resDir\grant-apps-srs-access.ps1 -ResourceGroup $ResourceGroup -AccessList $srsAccessList -Location $location -AppsCreated $appsCreated -LogDir $LogDir

    ######################
    # Lockdown SQL Server
    ######################

    Write-Host " Configuring Sql Server networking"
    $outputJson = AzCLI {az sql server update --name $sqlServer1Name --resource-group $ResourceGroup --enable-public-network $false}
    Write-Host " Completed.`r`n"
}

###########################
# Lockdown CosmosDb Account
###########################

Write-Host " Configuring Cosmos Db networking"
$outputJson = AzCLI {az cosmosdb update --name $cosmosDbAccount1Name --resource-group $ResourceGroup --public-network-access Disabled}
Write-Host " Completed.`r`n"

##############################################
# Update Front Door routes and origin groups #
##############################################
$frontDoorName = "fd-sn-$Env"

## Create RuleSets
Write-Host " Creating Front Door RuleSets"
$ruleSets = @(
    @{ name = "DefaultRules"; rules = @(
        @{name = "RemoveResponseHeaders"; actions = @( @{name = "ModifyResponseHeader"; headerAction = "Delete"; headerName = "X-Powered-By"},@{name = "ModifyResponseHeader"; headerAction = "Delete"; headerName = "X-UA-Compatible"})},
        @{name = "HSTS"; actions = @( @{name = "ModifyResponseHeader"; headerAction = "Overwrite"; headerName = "Strict-Transport-Security";headerValue = "max-age=63072000; includeSubDomains; preload"})},
        @{name = "ContentTypeOptions"; actions = @( @{name = "ModifyResponseHeader"; headerAction = "Overwrite"; headerName = "X-Content-Type-Options";headerValue = "nosniff"})},
        @{name = "ReferrerPolicy"; actions = @( @{name = "ModifyResponseHeader"; headerAction = "Overwrite"; headerName = "Referrer-Policy";headerValue = "strict-origin-when-cross-origin"})}
    )},
    @{ name = "cdn"; routes = @("cdn"); rules = @(
        @{name = "CacheControl"; actions = @( @{name = "ModifyResponseHeader"; headerAction = "Overwrite"; headerName = "Cache-Control"; headerValue = "$(P "max-age=300, must-revalidate;PROD:max-age=1800, must-revalidate")"})}
    )}
)
## Add the RuleSets to the FD
&$resDir\create-sn-fd-ruleset.ps1 -ResourceGroup $ResourceGroup -Env $Env -ProfileName $frontDoorName -RuleSets $ruleSets
Write-Host " Completed.`r`n"

$unmanagedRoutes = @("startpage","cdn","st-pda","st-shared-eastus2","st-item-eastus2","st-item-westeurope","st-item-southeastasia")
$unmanagedBackendPools = @("DefaultPool-CentralUS","st-cdn","st-shared-eastus2","st-pda","st-item-eastus2","st-item-westeurope","st-item-southeastasia")

Write-Host " Associating Front Door RuleSets to unmanaged routes"

## Link cdn to RuleSet
Write-Host " Linking cdn route to cdn & DefaultRules rule sets"
$outputJson = AzCLI {az afd route update --resource-group $ResourceGroup --profile-name $frontDoorName --endpoint-name $frontDoorName --route-name "cdn" --rule-sets @("cdn","DefaultRules") }
Write-Host " Completed.`r`n"

## Link unmanaged routes to the default rules
foreach($unmanagedRoute in $unmanagedRoutes + "default-route"){
    $isItemStorageRoute = $unmanagedRoute.StartsWith("st-item-")
    $itemStorageRouteLocation = $unmanagedRoute.Split("-")[-1]    
    if($unmanagedRoute -ne "cdn" -and (-not $isItemStorageRoute -or ($isItemStorageRoute -and $itemStorageAccounts[$itemStorageRouteLocation].AccountCreated))){
        Write-Host " Linking $unmanagedRoute route to DefaultRules rule set"
        $outputJson = az afd route update --resource-group $ResourceGroup --profile-name $frontDoorName --endpoint-name $frontDoorName --route-name $unmanagedRoute --rule-sets @("DefaultRules")
        Write-Host " Completed.`r`n"
    }
}

$appsLocations = $appsCreated.Keys | ForEach-Object { @{ AppUrlPath = $appsCreated[$_].Route; Locations = @() } }
foreach ($app in $appsLocations) {
    $locations = ($appsCreated.Keys  | Where-Object { $appsCreated[$_].Route -eq $app.AppUrlPath} | ForEach-Object {$appsCreated[$_].Location})
    if($locations -isnot [array]){$locations = @($locations)}
    $app.Locations = $locations
    $app.RuleSets += "DefaultRules" ## link the default rules to all apps routes
}

&$resDir\update-sn-afd.ps1 -FrontDoorName $frontDoorName -ResourceGroup $ResourceGroup -Subscription $Subscription -Env $Env -AppsLocations $appsLocations -UnmanagedRoutes $unmanagedRoutes -UnmanagedOriginGroups $unmanagedBackendPools -LogDir $LogDir

##############################################

$azureOutput.Add("apps-created",$appsCreated)
$azureOutput | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $LogDir "azureOutput.json")
