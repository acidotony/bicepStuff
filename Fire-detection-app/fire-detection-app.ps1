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

