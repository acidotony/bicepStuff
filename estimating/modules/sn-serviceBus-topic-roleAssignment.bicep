import * as Types from '../imports/sn-types.bicep'
import * as sn from '../imports/sn-functions.bicep'

// Metadata
metadata description = 'This template defines role based access control (RBAC) rights for service bus topic resource.'

// Parameters
@description('The environment to deploy to.')
param environment object

@description('The resource id where the roles will be assigned.')
param resourceId string

@description('The resource name of the child resource where the roles will be assigned.')
param childResourceName string

@description('Group role assignments to apply to the resource.')
param groupRoleAssignments Types.GroupRoleAssignment[] = []

@description('Group lookup.')
param groups object = json(loadTextContent('../data/sn-group.json'))

@description('Site role assignments to apply to the resource.')
param siteRoleAssignments Types.SiteRoleAssignment[] = []

@description('Site array.')
param sites object[] = json(loadTextContent('../data/sn-application.json'))

@description('Role lookup.')
param roles object = json(loadTextContent('../data/role.json'))

// Variables
var location = az.resourceGroup().location

// Get the list of sites that are used in the role assignments
var siteFilter = [for siteRoleAssignment in siteRoleAssignments: [
  siteRoleAssignment.site
]]
var siteFilterFlattened = flatten(siteFilter)

// Filter the full list of sites to only those that are used in the role assignments and have a type
// Create an array of objects with the site name and the index of the site in this array
var filteredSites = [for (site, siteIndex) in union([], filter(sites, site => contains(siteFilterFlattened, site.abbr) && site.?type != null)):{
  abbr: site.abbr
  name: sn.CreateSiteName(environment.name, location, site.type, site.abbr)
  index: siteIndex
}]
var filteredSitesLookup = toObject(filteredSites, site => site.abbr, site => site)

// Groups
// Filter by environment, expand by role and flatten into a single array
var groupRoleAssignmentsFlattedByGroup = [for assignment in sn.FilterRoleAssignments(groupRoleAssignments, environment.name): map(assignment.roles, role =>{
  group: assignment.group
  role: role
})]
var groupRoleAssignmentsFlattened = flatten(groupRoleAssignmentsFlattedByGroup)

// Sites
// Filter by environment, expand by role and flatten into a single array
var siteRoleAssignmentsFlattedBySite = [for assignment in sn.FilterRoleAssignments(siteRoleAssignments, environment.name): map(assignment.roles, role =>{
  abbr: assignment.site
  name: filteredSitesLookup[assignment.site].name
  role: role
  appSettingName: assignment.?appSettingName
})]
var siteRoleAssignmentsFlattened = flatten(siteRoleAssignmentsFlattedBySite)

// Settings
// Determine unique site/app settings
var siteSettings = [for assignment in sn.FilterRoleAssignments(siteRoleAssignments, environment.name): (assignment.?appSettingName != null) ? {
  abbr: assignment.site
  name: filteredSitesLookup[assignment.site].name
  appSettingName: assignment.?appSettingName
} : null]
var siteSettingsFlattened = union([], siteSettings)

// Resources

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2024-01-01' existing = {
  name: last(split(resourceId,'/'))
}

resource topic 'Microsoft.ServiceBus/namespaces/topics@2024-01-01' existing = {
  parent: serviceBusNamespace
  name: childResourceName
}

// Associate the group roles to the resource
resource groupRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' =  [for assignmentIndex in range(0, length(groupRoleAssignmentsFlattened)): {
  scope: topic
  name: guid(resourceId, groupRoleAssignmentsFlattened[assignmentIndex].role, groupRoleAssignmentsFlattened[assignmentIndex].group)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles[groupRoleAssignmentsFlattened[assignmentIndex].role].id)
    principalId: groups[groupRoleAssignmentsFlattened[assignmentIndex].group].id
  }
}]

// Lookup each site
resource siteResources 'Microsoft.Web/sites@2024-04-01' existing = [for site in filteredSites: {
  name: site.name
}]

// Associate the site roles to the resource
resource siteRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' =  [for assignmentIndex in range(0, length(siteRoleAssignmentsFlattened)): {
  scope: topic
  name: guid(resourceId, siteRoleAssignmentsFlattened[assignmentIndex].role, siteRoleAssignmentsFlattened[assignmentIndex].name)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles[siteRoleAssignmentsFlattened[assignmentIndex].role].id)
    principalId: siteResources[filteredSitesLookup[siteRoleAssignmentsFlattened[assignmentIndex].abbr].index].identity.principalId
  }
}]

// Create app settings for the sites
module appSettingsModule './sn-site-config-appsettings.bicep' = [for siteSetting in siteSettingsFlattened: {
  name: take('AppSettings-${siteSetting.name}',64)
  params: {
    name: siteSetting.name
    appSettings: toObject([{name: siteSetting.appSettingName, value:  'https://${serviceBusNamespace.name}.servicebus.windows.net'}], arg => arg.name, arg => arg.value)
    existingAppSettings: list(az.resourceId('Microsoft.Web/sites/config', siteSetting.name, 'appsettings'), '2024-04-01').properties
  }
}]

// Outputs
output groupRoleAssignments object[] = groupRoleAssignmentsFlattened
output siteRoleAssignments object[] = siteRoleAssignmentsFlattened
