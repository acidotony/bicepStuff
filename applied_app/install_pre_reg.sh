#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────────
RG="rg-selectionnavigator-dev2-001"
LOC="eastus2"
VNET="vnet-sn-dev2-eastus2-001"
SUBNET_APPS="snet-003"
SUBNET_FN="snet-fn-004"
VNET_PREFIX="10.224.16.0/23"
APPS_PREFIX="10.224.16.0/26"
FN_PREFIX="10.224.16.64/26"
SA="stsndev2eastus226052025"
KV="kv-sn-dev2-00128052026"
LAW_RG="rg-selectionnavigator-dev2-001"
LAW="law-sn-msdn-00126052025"
ASP_APPS="asp-sn-dev2-eastus2-003"
ASP_FN="asp-sn-dev2-eastus2-fn-003"
SQL_SRV="sn28052025-dev2-sql-001"
SQL_ADMIN="sqladminuser"      # ← set your SQL admin username
SQL_PWD="P@ssw0rdHere!"      # ← set your SQL admin password securely
DB="FireDetection"

# ─── Azure AD group ─────────────────────────────────────────────────────────────
AAD_GROUP="Contributor"



# ─── 2. Resource group ─────────────────────────────────────────────────────────
echo "🏗  Creating or updating RG $RG..."
az group create \
  --name "$RG" \
  --location "$LOC" \
  --output none

# # ─── 3. VNet + subnets ─────────────────────────────────────────────────────────
echo "🌐  Deploying VNet $VNET + subnets..."
az network vnet create \
  --resource-group "$RG" \
  --name "$VNET" \
  --address-prefix "$VNET_PREFIX" \
  --subnet-name "$SUBNET_APPS" \
  --subnet-prefix "$APPS_PREFIX" \
  --output none

az network vnet subnet create \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET_FN" \
  --address-prefix "$FN_PREFIX" \
  --output none

# ─── 4. Storage account ────────────────────────────────────────────────────────
echo "💾  Creating storage account $SA..."
az storage account create \
  --resource-group "$RG" \
  --name "$SA" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --location "$LOC" \
  --output none

# ─── 5. Key Vault ───────────────────────────────────────────────────────────────
echo "🔐  Creating Key Vault $KV..."
az keyvault create \
  --resource-group "$RG" \
  --name "$KV" \
  --location "$LOC" \
  --output none

# ─── 6. Log Analytics Workspace ────────────────────────────────────────────────
echo "📊  Creating Log Analytics workspace $LAW..."
az monitor log-analytics workspace create \
  --resource-group "$LAW_RG" \
  --workspace-name "$LAW" \
  --location "$LOC" \
  --sku PerGB2018 \
  --output none

# ─── 7. App Service Plans ──────────────────────────────────────────────────────
echo "🚀  Creating App Service Plans..."
az appservice plan create \
  --resource-group "$RG" \
  --name "$ASP_APPS" \
  --sku P1v3 \
  --output none

az appservice plan create \
  --resource-group "$RG" \
  --name "$ASP_FN" \
  --sku P1v3 \
  --output none

#─── 8. SQL Server + firewall ───────────────────────────────────────────────────
echo "🗄️  Provisioning SQL Server $SQL_SRV..."
az sql server create \
  --resource-group "$RG" \
  --name "$SQL_SRV" \
  --location "$LOC" \
  --admin-user "$SQL_ADMIN" \
  --admin-password "$SQL_PWD" \
  --output none

az sql elastic-pool create \
  --name sep-sn-dev2-eastus2-001 \
  --resource-group "$RG" \
  --server "$SQL_SRV"

echo "🔓  Allowing Azure services through SQL firewall..."
az sql server firewall-rule create \
  --resource-group "$RG" \
  --server "$SQL_SRV" \
  --name AllowAzureServices \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0 \
  --output none

# ─── 9. SQL Database ────────────────────────────────────────────────────────────
echo "🛢️  Creating SQL DB $DB..."
az sql db create \
  --resource-group "$RG" \
  --server "$SQL_SRV" \
  --name "$DB" \
  --service-objective S0 \
  --output none

# ─── 10. Assign Contributor on the RG ───────────────────────────────────────────
# echo "🔐  Granting Contributor to \"$AAD_GROUP\" on $RG..."
# SUB_ID=$(az account show --query id -o tsv)
# az role assignment create \
#   --assignee-object-id "$GROUP_ID" \
#   --role Contributor \
#   --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" \
#   --output none

echo "✅  All prerequisites for sn-region-fireDetection (dev2) are in place!"