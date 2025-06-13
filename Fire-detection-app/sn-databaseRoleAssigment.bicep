// ======================================================================
//  sn-database-roleAssignment.bicep
//  • Assigns AAD groups to SQL DB roles (db_datareader, db_datawriter, etc.)
//  • Uses ARM `Microsoft.Sql/servers/databases/roleAssignments`
// ======================================================================

// ───────── Metadata ─────────
metadata description = 'Assigns Azure AD groups into T-SQL database roles directly, filtered by environment.'

// ─────────── Types ───────────
type GroupRoleAssignment = {
  group:   string
  roles:   string[]
  filters: string[]?   // optional list of environments
}

// ───────── Parameters ────────
@description('Deployment environment object, must include `name` property (e.g. "dev")')
param environment object

@description('Full ARM resource ID of the target SQL Database')
param resourceId string

@description('Which AAD groups get which DB roles, with optional environment filters')
param groupRoleAssignments GroupRoleAssignment[]

@description('Lookup of AAD group names to principal IDs')
param groups object = json(loadTextContent('../data/sn-group.json'))

// ────────── Locals ────────────
// 1) Keep only assignments relevant to this environment
var filtered = filter(
  groupRoleAssignments,
  a => !contains(a, 'filters') || contains(a.filters, environment.name)
)

// 2) Flatten each group + its roles into individual entries
var toAssign = flatten([
  for a in filtered: [
    for roleName in a.roles: {
      principalId: groups[a.group].id
      roleName:    roleName
    }
  ]
])

// ─────── Existing Resources ───────
// Tell Bicep “that ID is an existing SQL database”
resource sqlDb 'Microsoft.Sql/servers/databases@2021-02-01-preview' existing = {
  id: resourceId
}

// ───────── Role Assignments ────────
// Create one DB‐scope assignment per (principalId, roleName)
resource dbRoleAssignments 'Microsoft.Sql/servers/databases/roleAssignments@2021-02-01-preview' = [
  for entry in toAssign: {
    parent: sqlDb
    name:   guid(resourceId, entry.principalId, entry.roleName)
    properties: {
      principalId: entry.principalId
      roleName:    entry.roleName
    }
  }
]

// ─────────── Outputs ─────────────
@description('List of all group/role pairs that were applied')
output applied array = toAssign
