import * as sn from '../imports/sn-functions.bicep'
import * as Types from '../imports/sn-types.bicep'

// Metadata
metadata description = 'This template defines role based access control (RBAC) rights for a event hub.'

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

// Filter and flatten the group roles by environment
var groupRoleAssignmentsFlattedByGroup = [for assignment in sn.FilterRoleAssignments(groupRoleAssignments, environment.name): map(assignment.roles, role =>{
  group: assignment.group
  role: role
})]
var groupRoleAssignmentsFlattened = flatten(groupRoleAssignmentsFlattedByGroup)

// Resources
resource eventHubsNamespace 'Microsoft.EventHub/namespaces@2024-05-01-preview' existing = {
  name: last(split(resourceId,'/'))
}

// Associate the group roles to the resource
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' =  [for assignment in groupRoleAssignmentsFlattened: {
  scope: eventHubsNamespace
  name: guid(resourceId, assignment.role, assignment.group)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles[assignment.role].id)
    principalId: groups[assignment.group].id
  }
}]

// Outputs
output groupRoleAssignments object[] = groupRoleAssignmentsFlattened
