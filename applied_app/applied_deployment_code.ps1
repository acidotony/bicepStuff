$appliedTags = @( @{ Name = "SNCostCategory"; Value = "Applied"})


### Used by Applied apps + AHU Score
$aspPool6Names = @{}
$aspPool6MinAppInstances = [int](P "1;QA,PROD:2")
&$resDir\create-sn-asp.ps1 -Env $Env -Locations $usOnlyLocations -Sku P2V3 -ServerFarmNum 6 -ASPResourceNameByLocation $aspPool6Names -NetworkData $networkData -NsgSuffixNum $nsgIndex -Tags $coreTags -AzureData $azureOutput -LogDir $LogDir `
    -EnableAutoscale $true -MaxAutoscaleBurstCount 20
    #-MinCount 2 -MaxCount 10 -Count 2 -ScaleOutCount 2 -ScaleOutCondition "CpuPercentage > 60 avg 5m" `
    #-ScaleInCount 2 -ScaleInCondition "CpuPercentage < 25 avg 5m"
Write-Host " Created ASP #6 (for Applied apps + AHU Score):"
$aspPool6Names


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
    
        
    $sharedFileLocationFileShareList = ""
    $sharedFileLocationQueueList  = "" ##= "gry-nameplate"
    $sharedFileLocationBlobContainerNameList = ($sharedFileLocationBlobContainers | Where-Object { $_.Clean -eq $true } | ForEach-Object {$_.Name}) -join ","


    ### Applied Equipment
    &$resDir\create-sn-app.ps1 -AppAbbr "ae" -Env $Env -Runtime "ASPNET:V4.8" -MinAppInstances $aspPool6MinAppInstances -AppServicePlanName $aspPool6Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC


    ### Applied Equipment Ordering
    &$resDir\create-sn-app.ps1 -AppAbbr "aeo" -Env $Env -Runtime "dotnet:6" -MinAppInstances $aspPool1MinAppInstances -AppServicePlanName $aspPool1Name -KVAppSettings ($v2SecurityAppSettings + $launchDarklyAppSettings) -Location $location -Tags $coreTags -FrontDoorId $frontDoorId -NetworkData $networkData -AiDataCapGB (P "1;PROD:10") -LogDir $LogDir -AppsCreated $appsCreated -RBACPermissions $coreTeamsRBAC


    ### Applied Equipment database
    &$resDir\create-sn-db.ps1 -Name "AppliedEquipmentDatabase" -MaxSize "5GB" -Server $sqlServer1Name -ElasticPoolName $elasticPool1Name -ADAdminGroupName $selNavAzureAdminsAadGroup -ADAdminGroupObjectId $selNavAzureAdminsAadGroupId -Env $Env -Tags $coreTags -LogDir $LogDir -DatabasesCreated $databasesCreated
    $dbAccessList += @{DBName = "AppliedEquipmentDatabase"; Server = $sqlServer1Name; AppAbbrList = "ae,aeop"; Roles = "db_datareader,db_execute"}
    $dbAccessList += @{DBName = "AppliedEquipmentDatabase"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core"; Roles = "db_datareader,db_execute,db_datawriter,db_viewdefinition"; EnvFilterList = "dev2,dev"}
    $dbAccessList += @{DBName = "AppliedEquipmentDatabase"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Core"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "qa,sit,ppe"}
    $dbAccessList += @{DBName = "AppliedEquipmentDatabase"; Server = $sqlServer1Name; AADGroupList = "SelNav-Azure-AppDev-Chillers"; Roles = "db_datareader,db_viewdefinition"; EnvFilterList = "dev2,dev"} ## Temp access granted 2/21/2025, remove after 4/1/2025 (contact Mahesh Wakchaure prior to removal)


    # Ducted Systems (AppliedDX) Resources #
    ########################################


        @{ AADGroupList = "SelNav-Azure-AppDev-AppliedDX"; RolesList = "Contributor"; EnvFilterList = "dev2,dev,qa"}
    


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
