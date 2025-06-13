// Metadata
metadata description = 'This template defines a front door origin, origin group, and route. The scope of this must be set at the time of calling.'

// Parameters
@description('The front door profile name to which the Origin Group belongs.')
param frontDoorName string

@description('The name of the origin group to create. ex. fn-slc')
param originGroupName string

@description('The path the health probe should use. Default is "/".')
param healthProbePath string = '/'

@description('The method the health probe should use. Default is "HEAD".')
@allowed([
  'HEAD'
  'GET'
])
param healthProbeMethod string = 'HEAD'

// Resources
resource frontDoor 'Microsoft.Cdn/profiles@2024-09-01' existing = {
  name: frontDoorName

}

resource originGroup 'Microsoft.Cdn/profiles/origingroups@2024-09-01' = {
  parent: frontDoor
  name: originGroupName
  properties:{
    sessionAffinityState: 'Disabled'
    healthProbeSettings:{
      probePath: healthProbePath
      probeRequestType: healthProbeMethod
      probeProtocol: 'Https'
      probeIntervalInSeconds: 100
    }
    loadBalancingSettings:{
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
  }
}

// Outputs
output id string = originGroup.id
output name string = originGroup.name
output type string = originGroup.type

