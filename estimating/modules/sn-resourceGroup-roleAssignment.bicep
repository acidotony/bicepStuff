import * as Types from '../imports/sn-types.bicep'
import * as sn from '../imports/sn-functions.bicep'

// Metadata
metadata description = 'This template defines role based access control (RBAC) rights for a resource group.'

// Parameters
@description('The environment to deploy to.')
param environment object

@description('The resource id where the roles will be assigned.')
param resourceId string

@description('Group role assignments to apply to the resource group.')
param groupRoleAssignments Types.GroupRoleAssignment[]

@description('Group lookup.')
param groups object = json(loadTextContent('../data/sn-group.json'))

@description('Role lookup.')
param roles object = json(loadTextContent('../data/role.json'))

// Variables

// Groups
// Filter by environment, expand by role and flatten into a single array
var groupRoleAssignmentsFlattedByGroup = [for assignment in sn.FilterRoleAssignments(groupRoleAssignments, environment.name): map(assignment.roles, role =>{
  group: assignment.group
  role: role
})]
var groupRoleAssignmentsFlattened = flatten(groupRoleAssignmentsFlattedByGroup)

// Resources

// Associate the group roles to the resource
resource groupRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' =  [for assignment in groupRoleAssignmentsFlattened :  {
  name: guid(resourceId, assignment.role, assignment.group)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles[assignment.role].id)
    principalId: groups[assignment.group].id
  }
}]

// Outputs
output groupRoleAssignments object[] = groupRoleAssignmentsFlattened
