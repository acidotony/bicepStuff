Param(
    [string]$Env
    #   = "poc"
    ,
    [string]$Subscription,
    [string]$AppAbbr
    #   = "apr"
    ,
    [string]$Name,
    [string]$FunctionsVersion = 4,
    [string]$StorageName
    #    = "rgselectionnavigato895a"
    ,
    [bool]$UseConsumptionPlan
    = $true
    ,
    [bool]$Use32Bit = $true, 
    [bool]$IsLinuxSku = $false,
    [string]$AppServicePlanName
    #   = "asp-sn-poc-eastus2-fn-001"
    ,
    [int]$MinAppInstances = 1,
    [int]$PremiumPrewarmedInstances = 2,
    [string]$KeyVaultName,
    [string]$ResourceGroup 
    # = ""
    ,
    [string]$Location = "eastus2",
    [array]$AppSettings = @()
    # {
    #     Value =  "AppInsights:Verbose",
    #     AppSettingName = "SCALE_CONTROLLER_LOGGING_ENABLED"
    # }
    ,
    [array]$KVAppSettings = @()
    ,
    [array]$RBACPermissions
    # =@(@{RolesList="Contributor";AADGroupList="SelNav-Azure-AppDev-SysControls";EnvFilterList="dev2,dev,qa";})
    ,
    [hashtable]$AppsCreated = @{},
    [string]$FrontDoorId,
    [array]$NetworkData = @(
        # @{ VNetName = "vnet-sn-poc-eastus2-001"; Location = "eastus2"; Subnets = @() },
        # @{ VNetName = "vnet-sn-poc-westeurope-001"; Location = "westeurope"; Subnets = @() }
    ),
    [string]$Runtime = "dotnet", # "dotnet","dotnet-isolated", "node", "python", "java", "powershell"
    [int]$AiDataCapGB = 1,
    [array]$Tags, #= @( @{ Name = "SNCostCategory"; Value = "SysControls"}),
    [string]$LogDir = ".\Logs"
)  

#az login
#az account set --subscription

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Force -Path $LogDir
}

$Env = $Env.ToLower()
$Location = $Location.ToLower()
$AppAbbr = $AppAbbr.ToLower()
If ($Name) {
    if (-not $Env -or -not $StorageName) {
        Throw "Environment and Storage account must be specified."
    }
    $FunctionName = $Name
}
else {
    if (-not $Env -or -not $AppAbbr -or -not $StorageName) {
        Throw "Environment, Application Abbreviation, and Storage account must be specified."
    }
    $FunctionName = "fn-sn-$Env-$AppAbbr-$Location"
}
If ($Name) {
    $AppInsightsName = $Name
}
Else {
    $AppInsightsName = "sn-$Env-$AppAbbr".ToUpper()
}
#$StorageName = "stsn$Env$AppAbbr$Location"
if (-not $ResourceGroup) {
    $ResourceGroup = "rg-selectionnavigator-$Env-001"
}
If (-not $Subscription) {
    If (@("dev2", "dev", "qa", "poc", "shared-msdn") -contains $Env) {
        $Subscription = "JCPLC-MSDN-001"
    }
    Else {
        $Subscription = "JCPLC-PROD-001"
    }
}
If (-not $KeyVaultName) {
    $KeyVaultName = "kv-sn-$Env-001"
}

$azureData = @{}
$azureData.Add("runtime", $Runtime)

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
. $scriptDir\AzCLI.ps1

$osType = $IsLinuxSku ? "Linux":"Windows"

Write-Host "**********"
Write-Host "Create Function: $FunctionName"
if ($UseConsumptionPlan) {
    Write-Host " as consumption, serverless: $UseConsumptionPlan"
}
else {
    Write-Host " with Plan: $AppServicePlanName"
    Write-Host " (for Premium Plans) with Prewarmed instances: $PremiumPrewarmedInstances"
}
Write-Host " with OS type: $osType"
Write-Host " using Storage: $StorageName"
Write-Host " with App Insights: $AppInsightsName"
Write-Host "**********"
Write-Host " Resource group: $ResourceGroup"
Write-Host " Front Door ID List: $FrontDoorId`r`n"

Write-Host "App Settings:"
Write-Host ($AppSettings | ConvertTo-Json)

Write-Host "KeyVault Settings:"
Write-Host ($KVAppSettings | ConvertTo-Json)

Write-Host "RBAC settings:"
Write-Host ($RBACPermissions | ConvertTo-Json)

Write-Host " Getting existing App Insights"
$appInsightsListJson = AzCLI { az resource list --resource-group $ResourceGroup --resource-type "Microsoft.Insights/components" --query "[].name" -o json }
$appInsightsList = $appInsightsListJson | ConvertFrom-Json
$appInsightsExists = ($appInsightsList -contains $AppInsightsName)
If (-not $appInsightsExists) {
    ###Create App Insights
    Write-Host " Does not exist. Creating App Insights"

    $subAbbr = (($subscription -replace "JCPLC-", "") -replace "-001", "").ToLower()
    $logAnalyticsWorkspaceName = "law-sn-$subAbbr-001"
    $lawResourceGroup = "rg-selectionnavigator-shared-$subAbbr-001"
    $outputJson = az monitor log-analytics workspace show --resource-group $lawResourceGroup --workspace-name $logAnalyticsWorkspaceName
    #Next line due to a bug in CLI output
    $outputJson = $outputJson -replace "`"eTag`": null,", ""
    $output = $outputJson | ConvertFrom-Json
    $logAnalyticsWorkspaceId = $output.id

    $outputJson = AzCLI { az monitor app-insights component create --app $AppInsightsName --location $Location --resource-group $ResourceGroup --application-type web --kind web --workspace $logAnalyticsWorkspaceId }
    Write-Host " Completed.`r`n"
}
Else {
    $outputJson = AzCLI { az monitor app-insights component show --app $AppInsightsName --resource-group $ResourceGroup }
    Write-Host " Completed.`r`n"
}
$outputJson | Set-Content (Join-Path $LogDir "output.$AppInsightsName.json")
$output = $outputJson | ConvertFrom-Json
$azureData.Add("appInsights", $output)
$appInsightsId = $output.Id
$instrumentationKey = $output.instrumentationKey
$appInsightsConnectionString = $output.connectionString 

##Set Tags on App Insights resource
if ($Tags) {
    &$scriptDir\set-tags.ps1 -Scope $appInsightsId -Tags $Tags -LogDir $LogDir
}

##Verify/Update App Insights daily cap in GB
$billing = az monitor app-insights component billing show --ids $appInsightsId --resource-group $ResourceGroup | ConvertFrom-Json

if ($billing.dataVolumeCap.cap -ne $AiDataCapGB) {         
    $billing = az monitor app-insights component billing update --ids $appInsightsId --resource-group $ResourceGroup --cap $AiDataCapGB  | ConvertFrom-Json
}
$azureData.Add("appInsights-billing", $billing)

###Get existing Function app
Write-Host " Getting existing Function"
$outputJson = $null
$listJson = AzCLI { az functionapp list --resource-group $ResourceGroup --query "[?name=='$FunctionName']" }
$fnList = $listJson | ConvertFrom-Json
$fnExists = ($fnList.Count -gt 0)

if ($fnExists) {
    $outputJson = AzCLI { az functionapp show --name $FunctionName --resource-group $ResourceGroup }
    
    Write-Host " Completed.`r`n"
    $outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.existing.json")
    $existingAppData = $outputJson | ConvertFrom-Json
    $curAppData = $existingAppData
    $azureData.Add("app", $existingAppData)

    $currentLocation = $azureData.app.location -replace " ", ""
    $currentPlanId = $azureData.app.appServicePlanId
    $currentPlanName = $currentPlanId.substring($currentPlanId.lastindexof("/") + 1)
    $currentlyUsingConsumptionPlan = ($currentPlanName -eq "$($currentLocation)Plan")
    Write-Host " Is currently using a consumption plan: $currentlyUsingConsumptionPlan"
    if ($currentlyUsingConsumptionPlan -ne $UseConsumptionPlan) {
        # Is switching from Consumption-based to Plan-based or vice versa

        Write-Host " Deleting Function App, so it can be recreated"
        $outputJson = AzCLI { az functionapp delete --name $FunctionName --resource-group $ResourceGroup } -EmptyOutputExpected $true
        $outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.delete-old.json")
        $output = $outputJson | ConvertFrom-Json
        Write-Host " Completed.`r`n"
        $azureData.Add("app-deleted", $output)

        $fnExists = $false
    }
    ### If is on a Plan and current plan is different than specified plan, change it
    else {
        if (-not $UseConsumptionPlan -and $AppServicePlanName -and $currentPlanName -ne $AppServicePlanName) {
            $vnetData = $NetworkData | Where-Object { $_.Location -eq $Location } | Select-Object -First 1
            if (-not $vnetData) { throw "VNet not found for location" }
            $vnetName = $vnetData.VNetName

            ### Remove the current VNet integration
            Write-Host " Removing current VNet integration"
            AzCLI { az functionapp vnet-integration remove --name $FunctionName --resource-group $ResourceGroup} -EmptyOutputExpected $true | Out-Null
            
            ### Update the plan used by the Function App
            Write-Host " Updating plan from $currentPlanName to $AppServicePlanName"
            $outputJson = AzCLI { az functionapp update  --name $FunctionName --plan $AppServicePlanName --resource-group $ResourceGroup }
            $outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.update-plan.json")
            $output = $outputJson | ConvertFrom-Json
            $curAppData = $output
            Write-Host " Completed.`r`n"
            $azureData.Add("updated-plan", $output)
        }
    }
}

if (-not $fnExists) {
    
    if ($UseConsumptionPlan) {
        ###Create consumption-based Function
        Write-Host " Creating consumption-based serverless Function App"
        $outputJson = AzCLI { az functionapp create --name $FunctionName --resource-group $ResourceGroup --storage-account $StorageName --app-insights $AppInsightsName --consumption-plan-location $Location --functions-version $FunctionsVersion --os-type $osType --runtime $Runtime --https-only true }
        $outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.json")
        $output = $outputJson | ConvertFrom-Json
        Write-Host " Completed.`r`n"
        $azureData.Remove("app")
        $azureData.Add("app", $output)
        $curAppData = $output

        $use32BitValue = ([string]$Use32Bit).ToLower()
        ###Config Function app Defaults
        Write-Host " Configuring function bitness of function (Use32Bit = $use32BitValue)"
        # Temporarily disabled due to bug in Az CLI
        # $outputJson = AzCLI {az functionapp config set --name $FunctionName --resource-group $ResourceGroup --use-32bit-worker-process $use32BitValue }
        $outputJson = AzCLI { az resource update --resource-type "Microsoft.Web/sites" --name $FunctionName --resource-group $ResourceGroup --set properties.siteConfig.use32BitWorkerProcess=$use32BitValue }
        $outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.bitness.json")
        $output = $outputJson | ConvertFrom-Json
        Write-Host " Completed.`r`n"
        $azureData.Add("bitness", $output)
    }
    else {
        if (-not $AppServicePlanName) {
            Throw "App Service Plan must be specified for non-consumption-based Function Apps."
        }
        
        ###Determine whether the storage account has public access enabled
        $originalPublicAccessSetting = AzCLI { az storage account show --name $StorageName --resource-group $ResourceGroup --query "publicNetworkAccess" -o tsv } -NonJsonOutputExpected $true
        if ($originalPublicAccessSetting -eq "Disabled") {
            Write-Host " Public access to $StorageName is currently disabled. Enabling public access."
            $outputJson = AzCLI { az storage account update --name $StorageName --resource-group $ResourceGroup --public-network-access Enabled --default-action Allow }
            Write-Host " Completed.`r`n"
        }

        ###Create plan-based Function
        Write-Host " Creating plan-based Function App"
        $outputJson = AzCLI { az functionapp create --name $FunctionName --resource-group $ResourceGroup --storage-account $StorageName --app-insights $AppInsightsName --plan $AppServicePlanName --functions-version $FunctionsVersion --os-type $osType --runtime $Runtime --https-only true }
        $outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.json")
        $output = $outputJson | ConvertFrom-Json
        $curAppData = $output
        Write-Host " Completed.`r`n"
        $azureData.Remove("app")
        $azureData.Add("app", $output)

        if ($originalPublicAccessSetting -eq "Disabled") {
            Write-Host " Disabling public access again to $StorageName"
            $outputJson = AzCLI { az storage account update --name $StorageName --resource-group $ResourceGroup --public-network-access Disabled --default-action Deny }
            Write-Host " Completed.`r`n"
        }

        $use32BitValue = ([string]$Use32Bit).ToLower()
        ###Config Function app Defaults
        Write-Host " Configuring function bitness of function (Use32Bit = $use32BitValue)"
        # Temporarily disabled due to bug in Az CLI
        # $outputJson = AzCLI {az functionapp config set --name $FunctionName --resource-group $ResourceGroup --use-32bit-worker-process $use32BitValue }
        $outputJson = AzCLI { az resource update --resource-type "Microsoft.Web/sites" --name $FunctionName --resource-group $ResourceGroup --set properties.siteConfig.use32BitWorkerProcess=$use32BitValue }

        $outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.bitness.json")
        $output = $outputJson | ConvertFrom-Json
        Write-Host " Completed.`r`n"
        $azureData.Add("bitness", $output)
    }
}

if (-not $UseConsumptionPlan) {
    ###Link application to VNet for access to dependencies
    if ($NetworkData.Count -gt 0) {
        $vnetData = $NetworkData | Where-Object { $_.Location -eq $Location } | Select-Object -First 1
        if (-not $vnetData) { throw "VNet not found for location" }
        $vnetName = $vnetData.VNetName
        
        Write-Host " Linking app to VNet for access to dependent resources in VNet"
        $outputJson = AzCLI { az functionapp vnet-integration add --name $FunctionName --resource-group $ResourceGroup --subnet $AppServicePlanName --vnet $vnetName }
        $outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.vnet-integration.json")
        $output = $outputJson | ConvertFrom-Json
        Write-Host " Completed.`r`n"
        $azureData.Add("vnet-integration", $output)
    
        Write-Host " Checking Route All property"
        $outputJson = AzCLI { az functionapp config show --resource-group $ResourceGroup --name $FunctionName }
        $output = $outputJson | ConvertFrom-Json
        if ($output.vnetRouteAllEnabled) {
            Write-Host " Enable Route All property."
            # Temporarily disabled due to bug in Az CLI
            # $outputJson = AzCLI { az functionapp config set --resource-group $ResourceGroup --name $FunctionName --vnet-route-all-enabled true }
            $outputJson = AzCLI { az resource update --resource-type "Microsoft.Web/sites" --name $FunctionName --resource-group $ResourceGroup --set properties.vnetRouteAllEnabled=true }
        }
        Write-Host " Completed.`r`n"
    }

    Write-Host " Setting Pre-warmed Instance Count for Function"
    $outputJson = AzCLI { az resource update --name $FunctionName/config/web --set properties.preWarmedInstanceCount=$PremiumPrewarmedInstances --resource-type Microsoft.Web/sites --resource-group $ResourceGroup }
    $outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.identity.json")
    $output = $outputJson | ConvertFrom-Json
    Write-Host " Completed.`r`n"

    Write-Host " Enabling dynamic scale monitoring"
    $outputJson = AzCLI { az resource update --resource-group $ResourceGroup --name $FunctionName/config/web --set properties.functionsRuntimeScaleMonitoringEnabled=1 --resource-type Microsoft.Web/sites }
    $outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.dynamic-scale-monitoring.json")
    Write-Host " Completed.`r`n"
}

###Config Function app Defaults
Write-Host " Configuring function general settings"
# Removed --remote-debugging-enabled false because OS and runtime must be set properly
# Temporarily disabled due to bug in Az CLI
# $outputJson = AzCLI {az functionapp config set --name $FunctionName --resource-group $ResourceGroup --min-tls-version "1.2" --ftps-state "Disabled" }
$outputJson = AzCLI { az resource update --resource-type "Microsoft.Web/sites" --name $FunctionName --resource-group $ResourceGroup --set properties.siteConfig.minTlsVersion="1.2" properties.siteConfig.ftpsState="Disabled" }
$outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.general-settings.json")
$output = $outputJson | ConvertFrom-Json
Write-Host " Completed.`r`n"
$azureData.Add("general-settings", $output)

##Force to HTTPS if not already
if (-not $curAppData.http20Enabled) {
    Write-Host " Setting to HTTP 2.0"
    # Temporarily disabled due to bug in Az CLI
    # $outputJson = AzCLI {az functionapp config set --name $FunctionName --resource-group $ResourceGroup --http20-enabled true}
    $outputJson = AzCLI { az resource update --resource-type "Microsoft.Web/sites" --name $FunctionName --resource-group $ResourceGroup --set properties.siteConfig.http20Enabled=true }
    $outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.https-settings.json")
    $output = $outputJson | ConvertFrom-Json
    $curAppData = $output
    Write-Host " Completed.`r`n"
}

###Set minimum instances and https only
Write-Host " Setting minimum instances to $MinAppInstances and HTTPS only"
$outputJson = AzCLI { az functionapp update --name $FunctionName --resource-group $ResourceGroup --set siteConfig.minimumElasticInstanceCount=$MinAppInstances httpsOnly=true }
$outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.https-only.json")
$output = $outputJson | ConvertFrom-Json
Write-Host " Completed.`r`n"

###Create identity for Function
Write-Host " Creating Identity for Function"
$outputJson = AzCLI { az functionapp identity assign --name $FunctionName --resource-group $ResourceGroup }
$outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.identity.json")
$output = $outputJson | ConvertFrom-Json
Write-Host " Completed.`r`n"
$azureData.Add("fnIdentity", $output)
$functionIdentityId = $output.principalId

###Grant read access to Key Vault secrets
##Write-Host " Granting Get access to Key Vault"
##$outputJson = AzCLI {az keyvault set-policy --name $KeyVaultName --secret-permissions get --object-id $functionIdentityId}
##$outputJson | Set-Content (Join-Path $LogDir "output.$KeyVaultName.policy.$FunctionName.json")
##$output = $outputJson | ConvertFrom-Json
##Write-Host " Completed.`r`n"
##$azureData.Add("kv-policy-fn",$output)

Write-Host " Grant Get access to Key Vault section"
$outputJson = AzCLI { az account show }
$account = $outputJson | ConvertFrom-Json
$keyVaultUrl = "https://management.azure.com/subscriptions/$($account.id)/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVaultName/accessPolicies/add?api-version=2022-07-01"
$keyVaultBody = @{
    properties = @{
        accessPolicies = @(
            @{
                tenantId    = $account.tenantId
                objectId    = $functionIdentityId
                permissions = @{
                    secrets = @("get")
                }
            }
        )
    }
}
$keyVaultBody = ($keyVaultBody | ConvertTo-Json -Compress -Depth 10) -replace "`"", "\`""
$outputJson = AzCLI { az rest --method PUT --uri $keyVaultUrl --body $keyVaultBody --headers "Content-Type=application/json" }
$outputJson | Set-Content (Join-Path $LogDir "output.$KeyVaultName.policy.$FunctionName.json")
$output = $outputJson | ConvertFrom-Json
Write-Host " Completed.`r`n"
$azureData.Add("kv-policy-fn", $output)

Write-Host " Getting current app settings"
$outputJson = AzCLI { az functionapp config appsettings list --name $FunctionName --resource-group $ResourceGroup --only-show-errors }
$curAppSettings = @{}
($outputJson | ConvertFrom-Json) | ForEach-Object { $curAppSettings.Add([string]$_.name, [string]$_.value) }

##Create settings for Function
$AppSettings += @{AppSettingName = "APPLICATIONINSIGHTS_CONNECTION_STRING"; Value = $appInsightsConnectionString }
$AppSettings += @{AppSettingName = "APPINSIGHTS_CONNECTIONSTRING"; Value = $appInsightsConnectionString }
#$AppSettings += @{AppSettingName = "ApplicationInsights:ConnectionString"; Value = $appInsightsConnectionString}
$AppSettings += @{AppSettingName = "APPINSIGHTS_INSTRUMENTATIONKEY"; Value = $instrumentationKey }
#$AppSettings += @{AppSettingName = "ApplicationInsights:InstrumentationKey"; Value = $instrumentationKey}
$AppSettings += @{AppSettingName = "InstrumentationKey"; Value = $instrumentationKey }
$AppSettings += @{AppSettingName = "ApplicationInsightsAgent_EXTENSION_VERSION"; Value = "~2" }
$AppSettings += @{AppSettingName = "WEBSITE_CONTENTOVERVNET"; Value = "1" }

##Look for and delete AzureWebJobsDashboard setting if found; disables log output to Storage container (should go only to App Insights)
$logDashboardSetting = ($output | Where-Object { $_.name -eq "AzureWebJobsDashboard" } | Select-Object -First 1)
if ($logDashboardSetting) {
    Write-Host " Found unwanted 'AzureWebJobsDashboard' setting. Deleting it."
    $outputJson = AzCLI { az functionapp config appsettings delete --name $FunctionName --resource-group $ResourceGroup --setting-names AzureWebJobsDashboard }
    $outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.settings.delete.json")
    $output = $outputJson | ConvertFrom-Json
    Write-Host " Completed.`r`n"
    $azureData.Add("settings.deleted", $output)
}

#Create app settings (including referencing existing KV secrets)
$settingsFileArr = @()
if ($KVAppSettings) {
    foreach ($kvAppSetting in $KVAppSettings) {
        #Get the Key Vault reference
        $secretName = $kvAppSetting.KVSecretName
        # Write-Host "  Getting '$secretName' in $KeyVaultName (to build app settings list)"
        # $outputJson = AzCLI {az keyvault secret show --name $secretName --vault-name $KeyVaultName}
        # $output = $outputJson | ConvertFrom-Json
        # Write-Host "  Completed.`r`n"
        # $secretId = $output.id
        $secretId = "https://$KeyVaultName.vault.azure.net/secrets/$secretName"
        $settingName = $kvAppSetting.AppSettingName
        $settingValue = "@Microsoft.KeyVault(SecretUri=$secretId)"
        #$settingsArr += "$settingName=$settingValue"
        if ($curAppSettings[$settingName] -ne $settingValue) {
            $settingsFileArr += @{ name = $settingName; slotSetting = $false; value = $settingValue }
        }
    }
}
foreach ($appSetting in $AppSettings) {
    if ($curAppSettings[$appSetting.AppSettingName] -ne $appSetting.Value) {
        $settingsFileArr += @{ name = $appSetting.AppSettingName; slotSetting = $false; value = $appSetting.Value }
    }
}

if ($settingsFileArr) {
    #Update app settings
    Write-Host " Some app settings missing; updating"

    $settingsFile = "output.$FunctionName.appSettings.json"
    $settingsJson = ConvertTo-Json $settingsFileArr
    $settingsJson | Set-Content $settingsFile
    #$settingsList = $settingsArr -join " "

    #Update app settings
    Write-Host "  Creating app settings for Function App:"
    Write-Host $settingsJson
    $outputJson = AzCLI { az functionapp config appsettings set --name $FunctionName --resource-group $ResourceGroup --settings @$settingsFile }
    $outputJson | Set-Content (Join-Path $LogDir "output.$FunctionName.settings.json")
    $output = $outputJson | ConvertFrom-Json
    Write-Host " Completed.`r`n"
}
else {
    Write-Host " No app settings need to be updated.`r`n"
}

##Create FrontDoor access restriction
if ($FrontDoorId) {
    $frontDoorHeaders = ($FrontDoorId -split "," | ForEach-Object { "x-azure-fdid=$_" }) -join " "
    $accessRestrictions = @(
        @{Action = "Allow"; RuleName = "Allow FrontDoor"; Description = "Allow access via $Env front door"; Priority = 100; ServiceTag = "AzureFrontDoor.Backend"; HttpHeader = $frontDoorHeaders; },
        @{Action = "Allow"; RuleName = "Allow AzureCloud apps access"; Description = "Allow access from other Azure cloud apps"; Priority = 200; ServiceTag = "AzureCloud"; }
    )
    
    &$scriptDir\create-sn-app-accessrestriction.ps1 -ResourceGroup $ResourceGroup -AppName $FunctionName -Restrictions $accessRestrictions -LogDir $LogDir
}

##Grant RBAC permissions
if ($RBACPermissions) {
    $fnAppScope = $azureData.app.id
    &$scriptDir\grant-scope-rbac-access.ps1 -Scope $fnAppScope -RBACPermissions $RBACPermissions -Env $Env -LogDir $LogDir
}

##Set Tags on resource
if ($Tags) {
    $fnAppScope = $azureData.app.id
    &$scriptDir\set-tags.ps1 -Scope $fnAppScope -Tags $Tags -LogDir $LogDir
}


If ($Name) {
    $key = $FunctionName
    $route = "fn-$FunctionName"
}
else {
    $key = "$Location.$AppAbbr"
    $route = "fn-$AppAbbr"
}
if (-not $AppsCreated[$key]) {
    $AppsCreated.Add($key, @{
            AppAbbr   = $AppAbbr
            Location  = $Location
            Route     = $route
            AzureData = @()
        })
}
$AppsCreated[$key].AzureData += $azureData

Write-Host "**********`r`n"
