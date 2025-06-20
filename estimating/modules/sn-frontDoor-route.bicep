// Metadata
metadata description = 'This template defines a front door route. The scope of this must be set at the time of calling.'

// Parameters
@description('The front door profile name to which the route belongs.')
param frontDoorName string

@description('The name of the route to create.')
param routeName string

@description('The name of the origin group to associate.')
param originGroupName string

@description('The patterns to match for routing.')
param patternsToMatch string[]

@description('An array of custom domain names to associate with the route.')
param customDomainNames string[]

@description('An array of ruleset names to associate with the route.')
param ruleSetNames string[]

// Variables
var customDomainIds = [for customDomainIndex in range(0, length(customDomainNames)): {id: customDomains[customDomainIndex].id}]
var ruleSetIds = [for ruleSetIndex in range(0, length(ruleSetNames)): {id: ruleSets[ruleSetIndex].id}]

// Resources
resource frontDoor 'Microsoft.Cdn/profiles@2024-09-01' existing = {
  name: frontDoorName
}

resource frontDoorEndpoint 'Microsoft.Cdn/profiles/afdendpoints@2024-09-01' existing = {
  parent: frontDoor
  name: frontDoorName
}

resource originGroup 'Microsoft.Cdn/profiles/origingroups@2024-09-01' existing = {
  parent: frontDoor
  name: originGroupName
}

resource customDomains 'Microsoft.Cdn/profiles/customDomains@2024-09-01' existing = [for customDomainName in customDomainNames: {
  parent: frontDoor
  name: replace(customDomainName, '.', '-')
}]

resource ruleSets 'Microsoft.Cdn/profiles/rulesets@2024-09-01' existing = [for ruleSetName in ruleSetNames: {
  parent: frontDoor
  name: ruleSetName
}]

// Route resource
resource route 'Microsoft.Cdn/profiles/afdendpoints/routes@2024-09-01' = {
  parent: frontDoorEndpoint
  name: routeName
  properties: {
    customDomains: customDomainIds
    originGroup: {
      id: originGroup.id
    }
    originPath: '/'
    ruleSets: ruleSetIds
    supportedProtocols: [
      'Https'
    ]
    patternsToMatch: patternsToMatch
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
    enabledState: 'Enabled'
  }
}

// Outputs
output id string = route.id
output name string = route.name

