import * as Types from '../imports/sn-types.bicep'

// Metadata
metadata description = 'This template defines role based access control (RBAC) rights for existing resource groups.  Resource groups are created via IT ticket system.'

// Parameters
@description('The environment to deploy to.')
param environment object

@description('Group role assignments to apply to the resource group.')
param groupRoleAssignments Types.GroupRoleAssignment[]

// Variables

// Resources
module roleAssignmentModule './sn-resourceGroup-roleAssignment.bicep' = {
  name: take('RoleAssignment-${az.resourceGroup().name}',64)
  params: {
    environment: environment
    resourceId: resourceGroup().id
    groupRoleAssignments: groupRoleAssignments
  }
}

// Outputs
output groupRoleAssignments object[] = roleAssignmentModule.outputs.groupRoleAssignments
