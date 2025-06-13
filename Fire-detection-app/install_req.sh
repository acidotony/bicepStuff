#!/usr/bin/env bash
# ------------------------------------------------------------------------------
#  Bootstrap Selection-Navigator Dev2 environment (prereqs for Bicep template)
#  • Adds subnet delegation to Microsoft.Web/serverFarms
#  • Creates the SQL elastic pool in Standard edition
# ------------------------------------------------------------------------------

set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────
RG="rg-selectionnavigator-dev2-001"
RGSHARED="rg-selectionnavigator-shared-msdn-001"  # Shared resources
LOC="eastus2"

# Networking
VNET="vnet-sn-dev2-eastus2-001"
SUBNET_APPS_003="asp-sn-dev2-eastus2-003"
SUBNET_APPS_004="asp-sn-dev2-eastus2-004"
SUBNET_FN_004="asp-sn-dev2-eastus2-fn-004"
VNET_PREFIX="10.224.16.0/23"
APPS_PREFIX_003="10.224.16.0/26"
APPS_PREFIX_004="10.224.16.128/26"
FN_PREFIX_004="10.224.16.64/26"
DELEGATION="Microsoft.Web/serverFarms"    # ⭐ new constant

# Storage, Key Vault, Log Analytics
SA="stsndev2eastus226052025"
KV="kv-sn-dev2-00128052025"
LAW_RG="$RGSHARED"
LAW="law-sn-msdn-00126052025"

# App Service Plans
ASP_APPS_003="asp-sn-dev2-eastus2-003"
ASP_APPS_004="asp-sn-dev2-eastus2-004"
ASP_FN_003="asp-sn-dev2-eastus2-fn-003"
ASP_FN_004="asp-sn-dev2-eastus2-fn-004"

# Front Door
FD_PROFILE="fd-sn-dev2"
FD_SKU="Standard_AzureFrontDoor"

# SQL
SQL_SRV="sn28052025-dev2-sql-001"
SQL_ADMIN="pepito246$"                
read -s -p "Enter SQL admin password: " SQL_PWD; echo
DB="FireDetection"
ELASTIC_POOL="sep-sn-dev2-eastus2-001"

# Managed Identity
MI_NAME="mi-sn-dev2-sqlscript"

# ─── Helpers ───────────────────────────────────────────────────────────────────
az config set extension.use_dynamic_install=yes --only-show-errors
if ! az extension show -n front-door --only-show-errors &> /dev/null; then
  echo "🔌 Installing Azure Front Door CLI extension..."
  az extension add --name front-door --only-show-errors
fi

# ─── 1. Resource group ─────────────────────────────────────────────────────────
echo "🏗  Ensuring resource group $RG exists..."
az group create --name "$RG" --location "$LOC" --output none

## ─── 2. VNet (no built-in subnet) ───────────────────────────────────────────────
echo "🌐  Creating VNet $VNET (no subnets)..."
az network vnet create \
  --resource-group "$RG" \
  --name "$VNET" \
  --address-prefix "$VNET_PREFIX" \
  --output none

# ─── 3. Subnets (with delegation) ─────────────────────────────────────────────
# Apps 003
echo "    ↳ subnet $SUBNET_APPS_003 ($APPS_PREFIX_003)"
az network vnet subnet create \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET_APPS_003" \
  --address-prefix "$APPS_PREFIX_003" \
  --delegation "$DELEGATION" \
  --output none

# Apps 004
echo "    ↳ subnet $SUBNET_APPS_004 ($APPS_PREFIX_004)"
az network vnet subnet create \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET_APPS_004" \
  --address-prefix "$APPS_PREFIX_004" \
  --delegation "$DELEGATION" \
  --output none

# Fn 004
echo "    ↳ subnet $SUBNET_FN_004 ($FN_PREFIX_004)"
az network vnet subnet create \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET_FN_004" \
  --address-prefix "$FN_PREFIX_004" \
  --delegation "$DELEGATION" \
  --output none



# ─── 5. App Service Plans ------------------------------------------------------
echo "🚀  Creating App Service Plans..."
for PLAN in "$ASP_APPS_003" "$ASP_APPS_004" "$ASP_FN_003" "$ASP_FN_004"; do
  az appservice plan create \
    --resource-group "$RG" \
    --name "$PLAN" \
    --sku P1v3 \
    --location "$LOC" \
    --output none
done

# ─── 6. SQL Server -------------------------------------------------------------
echo "🗄️  Provisioning SQL Server $SQL_SRV..."
az sql server create \
  --resource-group "$RG" \
  --name "$SQL_SRV" \
  --location "$LOC" \
  --admin-user "$SQL_ADMIN" \
  --admin-password "$SQL_PWD" \
  --output none

az sql server firewall-rule create \
  --resource-group "$RG" --server "$SQL_SRV" \
  --name AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 \
  --output none



# ─── 8. Elastic pool (Standard SKU) -------------------------------------------
echo "🛠️  Creating elastic pool $ELASTIC_POOL (Standard)..."
az sql elastic-pool create \
  --name "$ELASTIC_POOL" \
  --resource-group "$RG" \
  --server "$SQL_SRV" \
  --edition Standard \
  --output none

# ─── 9. SQL Database -----------------------------------------------------------
echo "🛢️  Creating SQL DB $DB..."
az sql db create \
  --resource-group "$RG" --server "$SQL_SRV" \
  --name "$DB"  \
  --elastic-pool "$ELASTIC_POOL" \
  --output none

# ─── 10. Azure Front Door Standard --------------------------------------------
echo "🌍  Creating Front Door profile $FD_PROFILE..."
az afd profile create \
  --resource-group "rg-selectionnavigator-shared-global-001" --profile-name "$FD_PROFILE" \
  --sku "$FD_SKU" --output none

az afd endpoint create \
  --resource-group "rg-selectionnavigator-shared-global-001" --profile-name "$FD_PROFILE" \
  --endpoint-name "$FD_PROFILE" --enabled-state Enabled --output none


echo "📊  Creating Log Analytics workspace $LAW..."
az monitor log-analytics workspace create \
  --resource-group "$LAW_RG" \
  --workspace-name "$LAW" \
  --location "$LOC" \
  --sku PerGB2018 \
  --output none

# ─── 3. Storage account ────────────────────────────────────────────────────────
echo "💾  Creating storage account $SA..."
az storage account create \
  --resource-group "$RG" \
  --name "$SA" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --location "$LOC" \
  --output none

# ─── 4. (Optional) Key Vault ---------------------------------------------------

az keyvault create --resource-group "$RG" --name "$KV" --location "$LOC" --output none


# ─── All done -----------------------------------------------------------------
echo -e "\n✅  Environment bootstrap complete."
echo    "   Front Door profile        : $FD_PROFILE"