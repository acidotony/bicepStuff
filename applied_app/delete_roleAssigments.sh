#!/bin/bash

# Required: Azure CLI must be logged in with sufficient permissions
# Set values for your deployment
subscriptionId="c557b832-a26b-4729-a9f9-21adb21c3063"
resourceGroup="rg-selectionnavigator-dev2-001"
keyVaultName="kv-sn-dev2-00103062025"
keyVaultId="/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.KeyVault/vaults/$keyVaultName"
roleDefinitionId="4633458b-17de-408a-b874-0445c86b69e6"  # Key Vault Secrets User

# List of Function App names
apps=(
  "fn-sn-dev2-dgbp-eastus2-03062025"
  "fn-sn-dev2-eebp-eastus2-03062025"
  "fn-sn-dev2-jcdsebp-eastus2-03062025"
  "fn-sn-dev2-mpebp-eastus2-03062025"
  "fn-sn-dev2-due-eastus2-03062025"
)

# Function to compute the Bicep-style GUID
compute_guid() {
  local scope="$1"
  local kv="$2"
  local site="$3"
  local role="$4"
  python3 -c "import uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, '$scope$kv$site$role'))"
}

for app in "${apps[@]}"; do
  echo "🔍 Processing $app"

  siteId="/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$app"
  scope="/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"

  # Compute deterministic role assignment ID
  assignmentGuid=$(compute_guid "$scope" "$keyVaultId" "$siteId" "$roleDefinitionId")
  roleAssignmentId="/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleAssignments/$assignmentGuid"

  echo "🧹 Attempting to delete role assignment: $roleAssignmentId"
  az role assignment delete --ids "$roleAssignmentId" 2>/dev/null

  if [[ $? -eq 0 ]]; then
    echo "✅ Deleted: $roleAssignmentId"
  else
    echo "⚠️  Role assignment not found or already deleted"
  fi

  echo "--------------------------------------"
done