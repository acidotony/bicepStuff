// Metadata
metadata description = 'This module defines a single Azure Front Door origin under an existing originGroup.'

// Parameters
@description('The Front Door profile name (e.g., fd-sn-dev2)')
param profileName string

@description('The name of the origin group to add the origin to (e.g., og-sn-dev2-app)')
param originGroupName string

@description('The name of the origin to create (e.g., app-sn-dev2-eastus2)')
param originName string

@description('The host name of the origin (e.g., app-sn-dev2-eastus2.azurewebsites.net)')
param hostName string

@description('The HTTP port for the origin (default 80)')
param httpPort int = 80

@description('The HTTPS port for the origin (default 443)')
param httpsPort int = 443

@description('The host header for the origin')
param originHostHeader string

@description('Origin priority (default 1)')
param priority int = 1

@description('Origin weight (default 1000)')
param weight int = 1000

@description('Whether to enforce certificate name check (default true)')
param enforceCertificateNameCheck bool = true

@description('Whether the origin is enabled (default "Enabled")')
param enabledState string = 'Enabled'

@description('Private link resource ID, if required')
param privateLinkResourceId string = ''

@description('Private link location, if required')
param privateLinkLocation string = ''

@description('Private link group ID (default "blob")')
param privateLinkGroupId string = 'blob'

// Existing resource references
resource frontDoor 'Microsoft.Cdn/profiles@2024-09-01' existing = {
  name: profileName
}

resource originGroup 'Microsoft.Cdn/profiles/origingroups@2024-09-01' existing = {
  parent: frontDoor
  name: originGroupName
}

// The origin resource
resource origin 'Microsoft.Cdn/profiles/originGroups/origins@2024-09-01' = {
  parent: originGroup
  name: originName
  properties: {
    hostName: hostName
    originHostHeader: originHostHeader
    httpPort: httpPort
    httpsPort: httpsPort
    priority: priority
    weight: weight
    enabledState: enabledState
    enforceCertificateNameCheck: enforceCertificateNameCheck
    sharedPrivateLinkResource: empty(privateLinkResourceId) ? null : {
      privateLink: {
        id: privateLinkResourceId
      }
      groupId: privateLinkGroupId
      privateLinkLocation: privateLinkLocation
      requestMessage: profileName
    }
  }
}

// Outputs
output id string = origin.id
output name string = origin.name

