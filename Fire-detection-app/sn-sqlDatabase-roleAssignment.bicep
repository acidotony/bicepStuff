//
// modules/sn-database-roleAssignment.bicep
//
// Creates contained AAD-group users in an Azure SQL Database
// and adds them to built-in database roles
//

// ───────────── Types ─────────────────────────────────────────
type GroupRoleAssignment = {
  group  : string
  roles  : string[]
  filters: string[]
}

// ───────────── Parameters ────────────────────────────────────
@description('Environment object with a .name field')
param environment object

@description('Resource ID of the target database')
param databaseResourceId string

@description('Group-to-role assignment list')
param groupRoleAssignments GroupRoleAssignment[]


// ───────────── Derive script identity from SQL server ────────
// Example databaseResourceId:
//   /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Sql/servers/<srv>/databases/<db>
var dbParts  = split(databaseResourceId, '/')
var serverRg = dbParts[4]
var sqlSrv   = dbParts[8]
var dbName   = dbParts[10] // Extract database name for naming the script

// Naming convention used in your bootstrap script
var miName   = 'mi-sn-dev2-sqlscript'

// Build full resourceId of the UAMI
var scriptIdentityId = resourceId(serverRg, 'Microsoft.ManagedIdentity/userAssignedIdentities', miName)

// ───────────── Filter & flatten assignments ──────────────────
var groupRoleAssignmentsFiltered = filter(
  groupRoleAssignments,
  item => item.filters == null || empty(item.filters) || contains(item.filters, environment.name)
)

var groupRoleAssignmentsPerRole = [
  for a in groupRoleAssignmentsFiltered: map(
    a.roles,
    r => {
      group: a.group
      role : r
    }
  )
]

var groupRoleAssignmentsFlattened = flatten(groupRoleAssignmentsPerRole)

// ───────────── deploymentScript resource (SINGLE INSTANCE) ────────────────────
resource assignRoles 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  // Use a single, consistent name for the deployment script
  name: take(toLower('assign-${sqlSrv}-${dbName}-dbRoles'), 64)
  location: resourceGroup().location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${scriptIdentityId}': {}
    }
  }
  properties: {
    azPowerShellVersion: '7.2'
    timeout           : 'PT30M' // Generous timeout for module installation and SQL operations
    cleanupPreference : 'OnSuccess' // Retain resources for debugging on failure
    retentionInterval : 'P1D'     // Keep resources for 1 day if cleanupPreference is not 'Always'

    scriptContent: '''
param(
  [string]$DatabaseResourceId,
  [array]$RoleAssignments  # This parameter will now be an array of objects
)

# Function to log messages with timestamps
function Write-ScriptLog {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [string]$Level = 'INFO' # INFO, WARNING, ERROR
    )
    $timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Write-Host "[$timestamp] [$Level] $Message"
}

Write-ScriptLog -Message "Starting SQL role assignment script."

# Ensure PowerShellGet is updated/installed
Write-ScriptLog -Message "Ensuring PowerShellGet module is up-to-date..."
try {
    Install-Module -Name PowerShellGet -Force -Scope CurrentUser -AllowClobber -MinimumVersion 2.2.5
    Write-ScriptLog -Message "PowerShellGet updated/installed successfully."
}
catch {
    Write-ScriptLog -Message "Failed to update/install PowerShellGet: $_" -Level ERROR
    throw $_ # Re-throw to fail the deployment script
}

# Forcefully remove existing Az.Accounts from the session and install/import latest
Write-ScriptLog -Message "Managing Az.Accounts module version..."
try {
    Get-Module -Name Az.Accounts -ErrorAction SilentlyContinue | Remove-Module -Force -ErrorAction SilentlyContinue
    Write-ScriptLog -Message "Removed existing Az.Accounts from session (if present)."
    Install-Module -Name Az.Accounts -Force -Scope CurrentUser -AllowClobber
    Import-Module -Name Az.Accounts -Force
    Write-ScriptLog -Message "Az.Accounts module installed and imported successfully."
}
catch {
    Write-ScriptLog -Message "Failed to manage Az.Accounts module: $_" -Level ERROR
    throw $_ # Re-throw to fail the deployment script
}

# Install and import Az.Sql
Write-ScriptLog -Message "Installing and importing Az.Sql module..."
try {
    Install-Module -Name Az.Sql -Force -Scope CurrentUser -AllowClobber
    Import-Module -Name Az.Sql -Force
    Write-ScriptLog -Message "Az.Sql module installed and imported successfully."
}
catch {
    Write-ScriptLog -Message "Failed to install/import Az.Sql module: $_" -Level ERROR
    throw $_ # Re-throw to fail the deployment script
}

# Login with the script’s managed identity
Write-ScriptLog -Message "Connecting to Azure with managed identity..."
try {
    Connect-AzAccount -Identity | Out-Null
    Write-ScriptLog -Message "Successfully connected to Azure."
}
catch {
    #  NEW – safe
Write-ScriptLog -Message ("Failed to process assignment for " +
                          "PrincipalName=${PrincipalName}, Role=${Role}: $_") `
                -Level ERROR
}

# Parse resource IDs → server RG, server name, DB name
$parts       = $DatabaseResourceId -split '/'
$serverRg    = $parts[4]
$serverName  = $parts[8]
$dbName      = $parts[10]

Write-ScriptLog -Message "Targeting SQL Server '$serverName' in resource group '$serverRg', database '$dbName'."

# Loop through each role assignment
if ($RoleAssignments) {
    foreach ($assignment in $RoleAssignments) {
        $PrincipalName = $assignment.group
        $Role = $assignment.role

        Write-ScriptLog -Message "Processing assignment: PrincipalName=$PrincipalName, Role=$Role"

        # T-SQL batches
        $createUser = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$PrincipalName')
    CREATE USER [$PrincipalName] FROM EXTERNAL PROVIDER;
"@

        $grantRole  = "ALTER ROLE [$Role] ADD MEMBER [$PrincipalName];"

        # Run them with Invoke-AzSqlcmd (Az.Sql module)
        try {
            Write-ScriptLog -Message "Executing T-SQL to create user '$PrincipalName'..."
            Invoke-AzSqlcmd -ResourceGroupName $serverRg `
                            -ServerName        $serverName `
                            -DatabaseName      $dbName `
                            -Query             $createUser
            Write-ScriptLog -Message "User '$PrincipalName' created or already exists."

            Write-ScriptLog -Message "Executing T-SQL to assign role '$Role' to user '$PrincipalName'..."
            Invoke-AzSqlcmd -ResourceGroupName $serverRg `
                            -ServerName        $serverName `
                            -DatabaseName      $dbName `
                            -Query             $grantRole
            Write-ScriptLog -Message "Role '$Role' assigned to user '$PrincipalName'."
        }
        catch {
            Write-ScriptLog -Message "Failed to process assignment for PrincipalName=$PrincipalName, Role=$Role: $_" -Level ERROR
            # Re-throw the exception to ensure the deployment script fails if any assignment fails
            throw $_
        }
    }
    Write-ScriptLog -Message "All SQL role assignments processed successfully."
} else {
    Write-ScriptLog -Message "No role assignments provided. Script finished without actions." -Level WARNING
}
'''
    arguments: '''
      -DatabaseResourceId "${databaseResourceId}" `
      -RoleAssignments ${json(groupRoleAssignmentsFlattened)} # Pass the entire array as JSON
    '''
  }
}

// ───────────── Outputs ───────────────────────────────────────
output assignedPairs       array  = groupRoleAssignmentsFlattened
