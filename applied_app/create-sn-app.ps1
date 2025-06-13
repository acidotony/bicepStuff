Param(
	[string]$Env
    #  = "poc"
     ,
    [string]$Name,
    [string]$Subscription
        # = "JCPLC-MSDN-001"
    ,
    [string]$AppAbbr
    #  = "eis"
     ,
    [string]$Runtime = "dotnet:6", #"ASPNET:V4.8","ASPNET:V3.5","DOTNETCORE|3.1","dotnet:6"
    [bool]$Use32Bit = $true,
    [int]$MinAppInstances = 1,
    [int]$PrewarmedInstanceCount = 1,
    [string]$ResourceGroup,
    [string]$Location = "eastus2",
    [bool]$CreateStagingSlot = $false,
    [array]$AppSettings = @(),
    [string]$KeyVaultName,
    [array]$KVAppSettings
    #      =@(
    #         @{AppSettingName = "SelNavSharedAuthV2:AspNetSharedAuthV2CookieName"; KVSecretName = "AspNetSharedAuthV2CookieName"}
    #      )
    ,
    [array]$RBACPermissions
        # =@(
        #     @{ AADGroupList = "SelNav-Azure-AppDev-Core"; RolesList = "Contributor"; EnvFilterList = "dev2,dev,qa"}
        # )
    ,
    [array]$HybridConnections
        # =@(
        #     @{Name="relay-sn-msdn-smtp-cg-jci-com-25"; Relay="relay-sn-msdn";}
        # )
    ,
    [hashtable]$AppsCreated
        = @{}
    ,
    [string]$AppServicePlanName
        # = "asp-sn-poc-eastus2-001"
    ,
    [string]$FrontDoorId,
    [array]$NetworkData = @(
        # @{ VNetName = "vnet-sn-poc-eastus2-001"; Location = "eastus2"; Subnets = @() },
        # @{ VNetName = "vnet-sn-poc-westeurope-001"; Location = "westeurope"; Subnets = @() }
    ),
    [int]$AiDataCapGB = 1,
    [array]$Tags,
    [string]$LogDir = ".\"
)  

#az login
#az account set --subscription "JCPLC-MSDN-001"

$stagingSlotName = "staging"
$appPrincipalRole = "SelNav AppService Monitoring Reader"

If(-not (Test-Path $LogDir)){
    New-Item -ItemType Directory -Force -Path $LogDir
}

$Env = $Env.ToLower()
$Location = $Location.ToLower()
$AppAbbr = $AppAbbr.ToLower()
If($Name){
    If(-not $Env -or -not $AppServicePlanName){
        Throw "Environment and AppServicePlanName must be specified."
    }
    $WebAppName = $Name
}
Else{
    If(-not $Env -or -not $AppAbbr -or -not $AppServicePlanName){
        Throw "Environment, Application Abbreviation, and AppServicePlanName must be specified."
    }
    $WebAppName = "app-sn-$Env-$AppAbbr-$Location"
}
If($Name){
    $AppInsightsName = $Name
}
Else{
    $AppInsightsName = "sn-$Env-$AppAbbr".ToUpper()
}

If(-not $ResourceGroup){
    $ResourceGroup = "rg-selectionnavigator-$Env-001"
}
If(-not $Subscription){
    If(@("dev2","dev","qa","poc","shared-msdn") -contains $Env){
        $Subscription = "JCPLC-MSDN-001"
    }
    Else{
        $Subscription = "JCPLC-PROD-001"
    }
}
If(-not $KeyVaultName){
    $KeyVaultName = "kv-sn-$Env-001"
}

$Runtime = $Runtime.replace("|",":")

$azureData = @{}
$azureData.Add("runtime",$Runtime)

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
. $scriptDir\AzCLI.ps1

Write-Host "**********"
Write-Host "Create Web App: $WebAppName (Runtime: $Runtime)"
Write-Host " with App Insights: $AppInsightsName"
Write-Host " using App Service Plan: $AppServicePlanName"
Write-Host "**********"
Write-Host " Resource group: $ResourceGroup"
Write-Host " Front Door ID List: $FrontDoorId`r`n"

Write-Host " Getting existing App Insights"
$appInsightsListJson = AzCLI {az resource list --resource-group $ResourceGroup --resource-type "Microsoft.Insights/components" --query "[].name" -o json}
$appInsightsList = $appInsightsListJson | ConvertFrom-Json
$appInsightsExists = ($appInsightsList -contains $AppInsightsName)
If(-not $appInsightsExists){
    ###Create App Insights
    Write-Host " Does not exist. Creating App Insights"

    $subAbbr = (($subscription -replace "JCPLC-","") -replace "-001","").ToLower()
    $logAnalyticsWorkspaceName = "law-sn-$subAbbr-001"
    $lawResourceGroup = "rg-selectionnavigator-shared-$subAbbr-001"
    $outputJson = az monitor log-analytics workspace show --resource-group $lawResourceGroup --workspace-name $logAnalyticsWorkspaceName
     #Next line due to a bug in CLI output
     $outputJson = $outputJson -replace "`"eTag`": null,", ""
     $output = $outputJson | ConvertFrom-Json
    $logAnalyticsWorkspaceId = $output.id

    $outputJson = AzCLI {az monitor app-insights component create --app $AppInsightsName --location $Location --resource-group $ResourceGroup --application-type web --kind web --workspace $logAnalyticsWorkspaceId}
    Write-Host " Completed.`r`n"
}
Else{
    $outputJson = AzCLI {az monitor app-insights component show --app $AppInsightsName --resource-group $ResourceGroup}
    Write-Host " Completed.`r`n"
}
$outputJson | Set-Content (Join-Path $LogDir "output.$AppInsightsName.json")
$output = $outputJson | ConvertFrom-Json
$appInsightsId = $output.Id
$azureData.Add("appInsights",$output)
$instrumentationKey = $output.instrumentationKey
$appInsightsConnectionString = $output.connectionString 

##Set Tags on App Insights resource
if($Tags){
    &$scriptDir\set-tags.ps1 -Scope $appInsightsId -Tags $Tags -LogDir $LogDir
}

##Verify/Update App Insights daily cap in GB
$billing = az monitor app-insights component billing show --ids $appInsightsId --resource-group $ResourceGroup | ConvertFrom-Json

if($billing.dataVolumeCap.cap -ne $AiDataCapGB) {         
    $billing = az monitor app-insights component billing update --ids $appInsightsId --resource-group $ResourceGroup --cap $AiDataCapGB  | ConvertFrom-Json
}
$azureData.Add("appInsights-billing",$billing)

###Get existing App Service
Write-Host " Getting existing Web App"
$outputJson = $null
$listJson = AzCLI {az webapp list --resource-group $ResourceGroup --query "[?name=='$WebAppName']"}
$appList = $listJson | ConvertFrom-Json
$appExists = ($appList.Count -gt 0)

if($appExists){
    $appServicePlanNeedsToChange = $false
    $existingAppServicePlanName = ""
    $outputJson = az webapp show --name $WebAppName --resource-group $ResourceGroup
    $outputJson | Set-Content (Join-Path $LogDir "output.$WebAppName.existing.json")
    $existingAppData = $outputJson | ConvertFrom-Json
    $existingAppServicePlanId = $existingAppData.appServicePlanId
    $existingAppServicePlanName = $existingAppServicePlanId.substring($existingAppServicePlanId.lastIndexOf("/")+1)
    Write-Host "  App exists"
    Write-Host "  Existing ASP: $existingAppServicePlanName"
    $appServicePlanNeedsToChange = ($existingAppServicePlanName -ne $AppServicePlanName)
    Write-Host "  ASP needs to change: $appServicePlanNeedsToChange"
    Write-Host " Completed.`r`n"
    $azureData.Add("app",$existingAppData)
}
else{
    Write-Host "  App does not exist"
}

$stagingSlotAlreadyExists = $false
if($CreateStagingSlot){
    try{
        $outputJson = az webapp deployment slot show --name $WebAppName --resource-group $ResourceGroup --slot $stagingSlotName
    }
    catch{
        $outputJson = $null
    }
    If(-not $outputJson){
        Write-Host "  Staging slot does not exist"
    }
    Else{
        $outputJson | Set-Content (Join-Path $LogDir "output.$WebAppName-$stagingSlotName.existing.json")
        Write-Host "  Staging slot exists"
        $stagingSlotAlreadyExists = $true
    }
}

If(-not $appExists -or $appServicePlanNeedsToChange){

    If($appExists){
        #Get existing app settings, so they can be replaced after updating
        
        Write-Host " Getting Web App settings"
        $outputJson = AzCLI {az webapp config appsettings list --name $WebAppName --resource-group $ResourceGroup}
        $existingSettingsFile = "output.$WebAppName.settings.json"
        $outputJson | Set-Content (Join-Path $LogDir $existingSettingsFile)
        $output = $outputJson | ConvertFrom-Json
        Write-Host " Completed.`r`n"
        $azureData.Add("app-settings",$output)

        if($CreateStagingSlot -and $stagingSlotAlreadyExists){
            Write-Host " Getting Web App slot settings"
            $outputJson = AzCLI {az webapp config appsettings list --name $WebAppName --slot $stagingSlotName --resource-group $ResourceGroup}
            $existingSlotSettingsFile = "output.$WebAppName-$stagingSlotName.settings.json"
            $outputJson | Set-Content (Join-Path $LogDir $existingSlotSettingsFile)
            $output = $outputJson | ConvertFrom-Json
            Write-Host " Completed.`r`n"
            $azureData.Add("slot-settings",$output)
        }
    }

    ###Create App Service
    Write-Host " Creating Web App"
    if($appServicePlanNeedsToChange){
        $outputJson = AzCLI {az webapp vnet-integration remove --name $WebAppName --resource-group $ResourceGroup} -EmptyOutputExpected $true
    }
    $appCreateCommand = "az webapp create --name $WebAppName --resource-group $ResourceGroup --plan $AppServicePlanName --https-only true"
    $currentNetFrameworkVersionNum = [float]($existingAppData.siteConfig.netFrameworkVersion -replace "v", "")
    $desiredNetFrameworkVersionNum = [float](($Runtime -split ":")[1] -replace "v", "")
    #Only update runtime .NET version if the current is less than the specified/desired; a newer current version than specified here means they have upgraded and the IaC script should not interfere
    if($currentNetFrameworkVersionNum -le $desiredNetFrameworkVersionNum){
        $appCreateCommand += " --runtime `"$Runtime`""
    }
    $outputJson = AzCLI {Invoke-Expression -Command $appCreateCommand}
    $outputJson | Set-Content (Join-Path $LogDir "output.$WebAppName.json")
    $existingAppData = $outputJson | ConvertFrom-Json
    Write-Host " Completed.`r`n"
    $azureData.Remove("app")
    $azureData.Add("app",$existingAppData)
    
    if($CreateStagingSlot -and -not $stagingSlotAlreadyExists){
        ###Create staging slot for App Service
        Write-Host " Creating staging slot for Web App"
        $outputJson = AzCLI {az webapp deployment slot create --name $WebAppName --resource-group $ResourceGroup --slot $stagingSlotName --configuration-source $WebAppName}
        $outputJson | Set-Content (Join-Path $LogDir "output.$WebAppName-$stagingSlotName.json")
        $output = $outputJson | ConvertFrom-Json
        Write-Host " Completed.`r`n"
        $azureData.Add("slot",$output)

        ###Stop staging slot for App Service
        Write-Host " Stopping staging slot for Web App"
        $outputJson = AzCLI {az webapp stop --name $WebAppName --resource-group $ResourceGroup --slot $stagingSlotName} -EmptyOutputExpected $true
        $outputJson | Set-Content (Join-Path $LogDir "output.$WebAppName-$stagingSlotName-stop.json")
        $output = $outputJson | ConvertFrom-Json
        Write-Host " Completed.`r`n"
        $azureData.Add("slot-stop",$output)
    }

    If($appExists){
        #Restore former app settings

        $existingSettingsFilePath = (Join-Path $LogDir $existingSettingsFile)
        $existingSettings = Get-Content $existingSettingsFilePath | ConvertFrom-Json
        if($existingSettings){
            Write-Host " Restore Web App settings from $existingSettingsFilePath"
            $outputJson = AzCLI {az webapp config appsettings set --name $WebAppName --settings @$existingSettingsFilePath --resource-group $ResourceGroup}
            $outputJson | Set-Content (Join-Path $LogDir "output.$WebAppName.settings-restored.json")
            $output = $outputJson | ConvertFrom-Json
            Write-Host " Completed.`r`n"
            $azureData.Remove("app-settings")
            $azureData.Add("app-settings",$output)
        }
        else{
            Write-Host " NOT restoring Web App settings from $existingSettingsFilePath, because none were found"
        }

        # $existingSlotSettingsFilePath = (Join-Path $LogDir $existingSlotSettingsFile)
        # $existingSlotSettings = Get-Content $existingSlotSettingsFilePath | ConvertFrom-Json
        # if($existingSlotSettings){
        #     Write-Host " Restore Web App slot settings from $existingSlotSettingsFilePath"
        #     $outputJson = AzCLI {az webapp config appsettings list --name $WebAppName --slot $stagingSlotName --settings @$existingSlotSettingsFilePath --resource-group $ResourceGroup}
        #     $outputJson | Set-Content (Join-Path $LogDir "output.$WebAppName-$stagingSlotName.settings-restored.json")
        #     $output = $outputJson | ConvertFrom-Json
        #     Write-Host " Completed.`r`n"
        #     $azureData.Remove("slot-settings")
        #     $azureData.Add("slot-settings",$output)
        # }
        # else{
        #     Write-Host " NOT restoring Web App slot settings from $existingSettingsFilePath, because none were found"
        # }
}
}

###Enforce Https
Write-Host " Configuring app TLS settings and pre-warmed instances ($PreWarmedInstanceCount) and minimum instances ($MinAppInstances)"
$outputJson = AzCLI {az webapp update --name $WebAppName --resource-group $ResourceGroup --minimum-elastic-instance-count $MinAppInstances --https-only true --prewarmed-instance-count $PrewarmedInstanceCount}
$outputJson | Set-Content (Join-Path $LogDir "output.$WebAppName.tls-settings.json")
$output = $outputJson | ConvertFrom-Json

###Link application to VNet for access to dependencies
if($NetworkData.Count -gt 0){
    $vnetData = $NetworkData | Where-Object {$_.Location -eq $Location} | Select-Object -First 1
    if(-not $vnetData) { throw "VNet not found for location" }
    $vnetName = $vnetData.VNetName
    
    Write-Host " Linking app to VNet for access to dependent resources in VNet"
    $outputJson = AzCLI { az webapp vnet-integration add --name $WebAppName --resource-group $ResourceGroup --subnet $AppServicePlanName --vnet $vnetName }
    $outputJson | Set-Content (Join-Path $LogDir "output.$WebAppName.vnet-integration.json")
    $output = $outputJson | ConvertFrom-Json
    Write-Host " Completed.`r`n"
    $azureData.Add("vnet-integration",$output)

    Write-Host " Checking Route All property"
    $outputJson = AzCLI { az webapp config show --resource-group $ResourceGroup --name $WebAppName }
    $output = $outputJson | ConvertFrom-Json
    if($output.vnetRouteAllEnabled){
        Write-Host " Enabling Route All property."
        $outputJson = AzCLI { az webapp config set --resource-group $ResourceGroup --name $WebAppName --vnet-route-all-enabled true }
    }
    Write-Host " Completed.`r`n"
}

###Config App Defaults
Write-Host " Configuring app general settings"
$use32BitValue = ([string]$Use32Bit).ToLower()
$outputJson = AzCLI {az webapp config set --name $WebAppName --resource-group $ResourceGroup --always-on true --http20-enabled true --min-tls-version "1.2" --ftps-state "Disabled" --remote-debugging-enabled false --use-32bit-worker-process $use32BitValue}
$outputJson | Set-Content (Join-Path $LogDir "output.$WebAppName.general-settings.json")
$output = $outputJson | ConvertFrom-Json
Write-Host " Completed.`r`n"
$azureData.Add("general-settings",$output)

Write-Host " Completed.`r`n"
$azureData.Add("tls-settings",$output)

###Create identity for App Service
Write-Host " Creating Identity for Web App"
$outputJson = AzCLI {az webapp identity assign --name $WebAppName --resource-group $ResourceGroup}
$outputJson | Set-Content (Join-Path $LogDir "output.$WebAppName.identity.json")
$output = $outputJson | ConvertFrom-Json
Write-Host " Completed.`r`n"
$azureData.Add("appIdentity",$output)

$appServiceIdentityId = $output.principalId

if($CreateStagingSlot){
    ###Create identity for staging slot
    Write-Host " Creating Identity for staging slot"
    $outputJson = AzCLI {az webapp identity assign --name $WebAppName --resource-group $ResourceGroup --slot $stagingSlotName}
    $outputJson | Set-Content (Join-Path $LogDir "output.$WebAppName-$stagingSlotName.identity.json")
    $output = $outputJson | ConvertFrom-Json
    Write-Host " Completed.`r`n"
    $azureData.Add("slotIdentity",$output)
    #$appServiceSlotIdentityId = $output.principalId
}

Write-Host " Getting current app settings"
$outputJson = AzCLI { az webapp config appsettings list --name $WebAppName --resource-group $ResourceGroup --only-show-errors}
$curAppSettings = @{}
($outputJson | ConvertFrom-Json) | ForEach-Object {$curAppSettings.Add([string]$_.name,[string]$_.value)}

##Create settings for App Service
$AppSettings += @{AppSettingName = "APPLICATIONINSIGHTS_CONNECTION_STRING"; Value = $appInsightsConnectionString}
$AppSettings += @{AppSettingName = "APPINSIGHTS_CONNECTIONSTRING"; Value = $appInsightsConnectionString}
$AppSettings += @{AppSettingName = "ApplicationInsights:ConnectionString"; Value = $appInsightsConnectionString}
$AppSettings += @{AppSettingName = "APPINSIGHTS_INSTRUMENTATIONKEY"; Value = $instrumentationKey}
$AppSettings += @{AppSettingName = "ApplicationInsights:InstrumentationKey"; Value = $instrumentationKey}
$AppSettings += @{AppSettingName = "InstrumentationKey"; Value = $instrumentationKey}
$AppSettings += @{AppSettingName = "ApplicationInsightsAgent_EXTENSION_VERSION"; Value = "~2"}

###Grant read access to Key Vault secret
#Write-Host " Grant Get access to Key Vault section"
#$outputJson = AzCLI {az keyvault set-policy --name $KeyVaultName --secret-permissions get --object-id $appServiceIdentityId}
#$outputJson | Set-Content (Join-Path $LogDir "output.$KeyVaultName.policy.$WebAppName.json")
#$output = $outputJson | ConvertFrom-Json
#Write-Host " Completed.`r`n"
#$azureData.Add("kv-policy-app",$output)

###Grant read access to Key Vault secrets with REST api
Write-Host " Grant Get access to Key Vault section"
$outputJson = AzCLI {az account show}
$account = $outputJson | ConvertFrom-Json
$keyVaultUrl = "https://management.azure.com/subscriptions/$($account.id)/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVaultName/accessPolicies/add?api-version=2022-07-01"
$keyVaultBody = @{
    properties = @{
        accessPolicies = @(
            @{
                tenantId = $account.tenantId
                objectId = $appServiceIdentityId
                permissions = @{
                    secrets = @("get")
                }
            }
        )
    }
}
$keyVaultBody = ($keyVaultBody | ConvertTo-Json -Compress -Depth 10) -replace "`"","\`""
$outputJson = AzCLI {az rest --method PUT --uri $keyVaultUrl --body $keyVaultBody --headers "Content-Type=application/json"}
$outputJson | Set-Content (Join-Path $LogDir "output.$KeyVaultName.policy.$WebAppName.json")
$output = $outputJson | ConvertFrom-Json
Write-Host " Completed.`r`n"
$azureData.Add("kv-policy-app",$output)

#Create app settings (including referencing existing KV secrets)
$settingsFileArr = @()
if($KVAppSettings){
    foreach($kvAppSetting in $KVAppSettings){
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
        if($curAppSettings[$settingName] -ne $settingValue){
            $settingsFileArr += @{ name = $settingName; slotSetting = $false; value = $settingValue }
        }
    }
}
foreach($appSetting in $AppSettings){
    if($curAppSettings[$appSetting.AppSettingName] -ne $appSetting.Value){
        Write-Host " Current value for '$($appSetting.AppSettingName)' app setting ($($curAppSettings[$appSetting.AppSettingName])) does not match desired value ($($appSetting.Value))."
        $settingsFileArr += @{ name = $appSetting.AppSettingName; slotSetting = $false; value=$appSetting.Value }
    }
}

if($settingsFileArr){
    #Update app settings
    Write-Host " Some app settings missing; updating"

    $settingsFile = "output.$WebAppName.appSettings.json"
    $settingsJson = ConvertTo-Json $settingsFileArr
    $settingsJson | Set-Content $settingsFile
    #$settingsList = $settingsArr -join " "

    Write-Host $settingsJson
    $outputJson = AzCLI {az webapp config appsettings set --name $WebAppName --resource-group $ResourceGroup --settings @$settingsFile}
    $outputJson | Set-Content (Join-Path $LogDir "output.$WebAppName.settings.json")
    $output = $outputJson | ConvertFrom-Json
    Write-Host " Completed.`r`n"
}
else{
    Write-Host " No app settings need to be updated.`r`n"
}

if($HybridConnections){
    ###Create Hybrid Connections
    Write-Host " Creating Hybrid Connections"
    foreach($hc in $HybridConnections){
        $hcName = $hc.Name
        $hcRelay = $hc.Relay
        Write-Host "  $hcName"
        $outputJson = AzCLI {az webapp hybrid-connection add --name $WebAppName --resource-group $ResourceGroup --namespace $hcRelay --hybrid-connection $hcName}
        $outputJson | Set-Content (Join-Path $LogDir "output.$WebAppName.$hcName.json")
        $output = $outputJson | ConvertFrom-Json
        Write-Host "  Completed.`r`n"
        $azureData.Add("hybrid-connection.$WebAppName.$hcName",$output)
    }
}

##Create FrontDoor access restriction
if($FrontDoorId){
    $frontDoorHeaders = ($FrontDoorId -split "," | ForEach-Object {"x-azure-fdid=$_"}) -join " "
    $accessRestrictions = @(
        @{Action="Allow";RuleName="Allow FrontDoor";Description="Allow access via $Env front door";Priority=100;ServiceTag="AzureFrontDoor.Backend";HttpHeader=$frontDoorHeaders;},
        @{Action="Allow";RuleName="Allow AzureCloud apps access";Description="Allow access from other Azure cloud apps";Priority=200;ServiceTag="AzureCloud";}
    )
    
    $scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path

    &$scriptDir\create-sn-app-accessrestriction.ps1 -ResourceGroup $ResourceGroup -AppName $WebAppName -Restrictions $accessRestrictions -LogDir $LogDir
}

##Grant RBAC permissions
if($RBACPermissions){
    ##Include additional monitoring role for the App service principal.
    $RBACPermissions += @{AADPrincipalIDList=$appServiceIdentityId ; RolesList=$appPrincipalRole}
    $appScope = $azureData.app.id
    $scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
    &$scriptDir\grant-scope-rbac-access.ps1 -Scope $appScope -RBACPermissions $RBACPermissions -Env $Env -LogDir $LogDir
}

##Set Tags on resource
if($Tags){
    $appScope = $azureData.app.id
    &$scriptDir\set-tags.ps1 -Scope $appScope -Tags $Tags -LogDir $LogDir
}


If($Name){
    $route = "app-$WebAppName"
    $key = $WebAppName
}
else {
    $route = "app-$AppAbbr"
    $key = "$Location.$AppAbbr"
}
if(-not $AppsCreated[$key]){
    $AppsCreated.Add($key, @{
        AppAbbr = $AppAbbr
        AppName = $WebAppName
        Location = $Location
        Route = $route
        RuleSets = @()
        AzureData = @()
    })
}
$AppsCreated[$key].AzureData += $azureData

Write-Host "**********`r`n"
