param(
    [string]$Name,
    [string]$Server,
    [string]$Env,
    [string]$ResourceGroup,
    [string]$KeyVaultName,
    ### Must use CLIOptions OR ElasticPoolName
    [string]$CLIOptions,
    [string]$ElasticPoolName,
    [string]$MaxSize = "1GB", ### For databases in Elastic Pools
    [string]$LogDir,
    [hashtable]$DatabasesCreated,
    [string]$CatalogCollation ="SQL_Latin1_General_CP1_CI_AS",
    [string]$Collation ="SQL_Latin1_General_CP1_CI_AS",
    [array]$Tags
)

If(-not $KeyVaultName){
    $KeyVaultName = "kv-sn-$Env-001"
}

if($Name.IndexOf(" ") -ge 0){
    Write-Error "Database name cannot contain a space character. ($Name)"
    Throw
}

$outputJson = ""
Write-Host "**********"
Write-Host "Create Database: $Name"
Write-Host " on Server: $Server"
Write-Host " using KeyVault: $KeyVaultName"
if($CLIOptions){
    Write-Host " with options: $CLIOptions"
}
else{
    Write-Host " in Elastic Pool: $ElasticPoolName"
    Write-Host "   with max size: $MaxSize"
}
Write-Host "**********"

$AzureData = @{}
$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
if($CLIOptions){
    &$scriptDir\create-sn-sql-db.ps1 -DatabaseName $Name -DatabaseServerName $Server -KeyVaultName $KeyVaultName -CLIOptions $CLIOptions -Env $Env -CatalogCollation $CatalogCollation -Collation $Collation -ResourceGroup $ResourceGroup -Tags $Tags -LogDir $LogDir -AzureData $AzureData
}
else{
    &$scriptDir\create-sn-sql-db.ps1 -DatabaseName $Name -DatabaseServerName $Server -KeyVaultName $KeyVaultName -ElasticPoolName $ElasticPoolName -MaxSize $MaxSize -Env $Env -CatalogCollation $CatalogCollation -Collation $Collation -ResourceGroup $ResourceGroup -Tags $Tags -LogDir $LogDir -AzureData $AzureData
}
Write-Host " Completed.`r`n"

$key = "$DatabaseServerName.$DatabaseName"
if(-not $DatabasesCreated[$key]){
    $DatabasesCreated.Add($key, @{
        Name = $DatabaseName
        Server = $DatabaseServerName
        AzureData = @()
    })
}
$DatabasesCreated[$key].AzureData += $AzureData
