@export()
type GroupRoleAssignment = { 
  group: string
  roles: string[] 
  filters: string[]? 
}

@export()
type HybridConnection = { 
  hostname: string
  port: int
  filters: string[]? 
}

@export()
type ComputeSettings = { 
  name: string
  tier: string
  family: string
  capacity: int
  minCapacity: string
  autoPauseDelayMinutes: int 
}

@export()
type ElasticPlan = { 
  maxCapacity: int
  maxDatabaseCapacity: int
  maxSizeGB: int 
}

@export()
type BlobContainer = { 
  name: string
  publicAccess: 'Blob' | 'Container' | 'None' 
}

@export()
type SiteRoleAssignment = { 
  site: string
  roles: string[]
  filters: string[]?
  appSettingName: string? 
}

@export()
type SharedAccessPolicies = {
  name: string
  rights: string[]
}
