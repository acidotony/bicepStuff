@description('Picker function. Given a selector value for filtering, and default value if the selector is not found, and an array of values to filter, return the first value that contains the selector.  Filter values can have multiple keys that are separated by commas followed by a single value separated from the keys by a colon.')
@export()
func P(selector string, default string, filterValues string[]) string => trim(last(split(first(filter(filterValues, filterValue => contains(split(first(split(filterValue,':')),','), selector))) ?? first(filter(filterValues, filterValue => empty(first(split(filterValue, ':'))))) ?? ':${default}',':')))
 
@description('Returns the index of the resource group based on the last three characters of its name.')
@export()
func ResourceGroupIndex(resourceGroupName string) int => int(substring(resourceGroupName, length(resourceGroupName) - 3, 3))

@description('SiteNameLookup')
@export()
func SiteNameLookup(sites object[], environmentName string, location string) object => toObject(filter(sites, site => site.?type != null), site => site.abbr, site => '${startsWith(site.?type, 'functionapp') ? 'fn' : 'app'}-sn-${environmentName}-${site.abbr}-${location}')

@description('FilterRoleAssignments')
@export()
func FilterRoleAssignments(roleAssignments object[], environmentName string) object[] => filter(roleAssignments, roleAssignment => !contains(roleAssignment, 'filters') || contains(roleAssignment.?filters ?? [], environmentName))

@description('CreateFunctionName')
@export()
func CreateFunctionName(environmentName string, location string, appAbbreviation string) string => 'fn-sn-${environmentName}-${appAbbreviation}-${location}'

@description('CreateAppName')
@export()
func CreateAppName(environmentName string, location string, appAbbreviation string) string => 'app-sn-${environmentName}-${appAbbreviation}-${location}'

@description('CreateSiteName')
@export()
func CreateSiteName(environmentName string, location string, type string, appAbbreviation string) string => '${startsWith(type, 'functionapp') ? CreateFunctionName(environmentName, location, appAbbreviation) : CreateAppName(environmentName, location, appAbbreviation)}'
