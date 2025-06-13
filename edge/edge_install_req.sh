#!/usr/bin/env bash
# ------------------------------------------------------------------------------
#  Bootstrap Selection-Navigator Dev2 environment (prereqs for Bicep template)
#  • Adds subnet delegation to Microsoft.Web/serverFarms
#  • Creates the SQL elastic pool in Standard edition
# ------------------------------------------------------------------------------

set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────
RG="rg-selectionnavigator-dev2-004"
RGSHARED="rg-selectionnavigator-dev2-004"  # Shared resources
LOC="southeastasia"

# Networking
VNET="aj-vnet-sn-dev2-southeastasia-001"
SUBNET_APPS_003="aj-asp-sn-dev2-southeastasia-003"
SUBNET_APPS_006="aj-asp-sn-dev2-southeastasia-006"
SUBNET_APPS_004="aj-asp-sn-dev2-southeastasia-001"
SUBNET_APPS_005="aj-asp-sn-dev2-southeastasia-005"
SUBNET_APPS_006="aj-asp-sn-dev2-southeastasia-006"
SUBNET_FN_001="aj-asp-sn-dev2-southeastasia-fn-001"
SUBNET_FN_004="aj-asp-sn-dev2-southeastasia-fn-004"
SUBNET_FN_005="aj-asp-sn-dev2-southeastasia-fn-005"
VNET_PREFIX="10.224.0.0/16"
APPS_PREFIX_006="10.224.0.80/28"
APPS_PREFIX_004="10.224.0.16/28"
FN_PREFIX_001="10.224.0.32/28"
FN_PREFIX_004="10.224.0.48/28"
APPS_PREFIX_003="10.224.0.64/28"
FN_PREFIX_005="10.224.0.96/28"
APPS_PREFIX_005="10.224.0.112/28"
# APPS_PREFIX_006="10.224.0.128/28"
DELEGATION="Microsoft.Web/serverFarms"    # ⭐ new constant

# Storage, Key Vault, Log Analytics
SA="stsndev2southeastasiaaj0"
KV="kv-sn-dev2-001aj0"
LAW_RG="$RGSHARED"
LAW="aj-law-sn-msdn-00103062025"

# App Service Plans
ASP_APPS_006="aj-asp-sn-dev2-southeastasia-006"
ASP_APPS_001="aj-asp-sn-dev2-southeastasia-001"
ASP_APPS_003="aj-asp-sn-dev2-southeastasia-003"
ASP_APPS_005="aj-asp-sn-dev2-southeastasia-005"
ASP_APPS_006="aj-asp-sn-dev2-southeastasia-006"
ASP_FN_006="aj-asp-sn-dev2-southeastasia-fn-006"
ASP_FN_001="aj-asp-sn-dev2-southeastasia-fn-001"
ASP_APPS_004="aj-asp-sn-dev2-southeastasia-004"
ASP_FN_003="aj-asp-sn-dev2-southeastasia-fn-003"
ASP_FN_004="aj-asp-sn-dev2-southeastasia-fn-004"
ASP_FN_005="aj-asp-sn-dev2-southeastasia-fn-005"



# Front Door
FD_PROFILE="aj-fd-sn-dev2"
FD_SKU="Standard_AzureFrontDoor"

# SQL
SQL_SRV="aj-sn-dev2-sql-00103062025"
SQL_ADMIN="pepito246$"
read -s -p "Enter SQL admin password: " SQL_PWD; echo
DB="FireDetection"
ELASTIC_POOL="sep-sn-dev2-southeastasia-001"

# Managed Identity
MI_NAME="mi-sn-dev2-sqlscript"

# ─── Helpers ───────────────────────────────────────────────────────────────────
# az config set extension.use_dynamic_install=yes --only-show-errors
# if ! az extension show -n front-door --only-show-errors &> /dev/null; then
#   echo "🔌 Installing Azure Front Door CLI extension..."
#   az extension add --name front-door --only-show-errors
# fi

# # ─── Resource group ─────────────────────────────────────────────────────────
# echo "🏗  Ensuring resource group $RG exists..."
# az group create --name "$RG" --location "$LOC" --output none

# ## ─── VNet (no built-in subnet) ───────────────────────────────────────────────
# echo "🌐  Creating VNet $VNET (no subnets)..."
# az network vnet create \
#   --resource-group "$RG" \
#   --name "$VNET" \
#   --address-prefix "$VNET_PREFIX" \
#   --output none

# ─── Subnets (with delegation) ─────────────────────────────────────────────
# Apps 003
# echo "    ↳ subnet $SUBNET_APPS_003 ($APPS_PREFIX_003)"
# az network vnet subnet create \
#   --resource-group "$RG" \
#   --vnet-name "$VNET" \
#   --name "$SUBNET_APPS_003" \
#   --address-prefix "$APPS_PREFIX_003" \
#   --delegation "$DELEGATION" \
#   --output none

# # Apps 006
# echo "    ↳ subnet $SUBNET_APPS_006 ($APPS_PREFIX_006)"
# az network vnet subnet create \
#   --resource-group "$RG" \
#   --vnet-name "$VNET" \
#   --name "$SUBNET_APPS_006" \
#   --address-prefix "$APPS_PREFIX_006" \
#   --delegation "$DELEGATION" \
#   --output none

# # Apps 004
# echo "    ↳ subnet $SUBNET_APPS_004 ($APPS_PREFIX_004)"
# az network vnet subnet create \
#   --resource-group "$RG" \
#   --vnet-name "$VNET" \
#   --name "$SUBNET_APPS_004" \
#   --address-prefix "$APPS_PREFIX_004" \
#   --delegation "$DELEGATION" \
#   --output none

# # Apps 005
# echo "    ↳ subnet $SUBNET_APPS_005 ($APPS_PREFIX_005)"
# az network vnet subnet create \
#   --resource-group "$RG" \
#   --vnet-name "$VNET" \
#   --name "$SUBNET_APPS_005" \
#   --address-prefix "$APPS_PREFIX_005" \
#   --delegation "$DELEGATION" \
#   --output none

# # Apps 006
# echo "    ↳ subnet $SUBNET_APPS_006 ($APPS_PREFIX_006)"
# az network vnet subnet create \
#   --resource-group "$RG" \
#   --vnet-name "$VNET" \
#   --name "$SUBNET_APPS_006" \
#   --address-prefix "$APPS_PREFIX_006" \
#   --delegation "$DELEGATION" \
#   --output none

# # Fn 004
# echo "    ↳ subnet $SUBNET_FN_001 ($FN_PREFIX_001)"
# az network vnet subnet create \
#   --resource-group "$RG" \
#   --vnet-name "$VNET" \
#   --name "$SUBNET_FN_001" \
#   --address-prefix "$FN_PREFIX_001" \
#   --delegation "$DELEGATION" \
#   --output none

# echo "    ↳ subnet $SUBNET_FN_004 ($FN_PREFIX_004)"
# az network vnet subnet create \
#   --resource-group "$RG" \
#   --vnet-name "$VNET" \
#   --name "$SUBNET_FN_004" \
#   --address-prefix "$FN_PREFIX_004" \
#   --delegation "$DELEGATION" \
#   --output none

# echo "    ↳ subnet $SUBNET_FN_005 ($FN_PREFIX_005)"
# az network vnet subnet create \
#   --resource-group "$RG" \
#   --vnet-name "$VNET" \
#   --name "$SUBNET_FN_005" \
#   --address-prefix "$FN_PREFIX_005" \
#   --delegation "$DELEGATION" \
#   --output none



# ─── App Service Plans ------------------------------------------------------
# echo "🚀  Creating App Service Plans..."
# for PLAN in "$ASP_APPS_003" "$ASP_APPS_006" "$ASP_APPS_001" "$ASP_APPS_004" "$ASP_APPS_005" "$ASP_FN_003" "$ASP_FN_004" "$ASP_FN_006" "$ASP_FN_001" "$ASP_FN_005"; do
#   az appservice plan create \
#     --resource-group "$RG" \
#     --name "$PLAN" \
#     --sku P1v3 \
#     --location "$LOC" \
#     --output none
# done

# # # ─── SQL Server -------------------------------------------------------------
# echo "🗄️  Provisioning SQL Server $SQL_SRV..."
# az sql server create \
#   --resource-group "$RG" \
#   --name "$SQL_SRV" \
#   --location "$LOC" \
#   --admin-user "$SQL_ADMIN" \
#   --admin-password "$SQL_PWD" \
#   --output none

# az sql server firewall-rule create \
#   --resource-group "$RG" --server "$SQL_SRV" \
#   --name AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 \
#   --output none



# # ─── Elastic pool (Standard SKU) -------------------------------------------
# echo "🛠️  Creating elastic pool $ELASTIC_POOL (Standard)..."
# az sql elastic-pool create \
#   --name "$ELASTIC_POOL" \
#   --resource-group "$RG" \
#   --server "$SQL_SRV" \
#   --edition Standard \
#   --output none

# # # ─── SQL Database -----------------------------------------------------------
# # echo "🛢️  Creating SQL DB $DB..."
# # az sql db create \
# #   --resource-group "$RG" --server "$SQL_SRV" \
# #   --name "$DB"  \
# #   --elastic-pool "$ELASTIC_POOL" \
# #   --output none

# ─── Azure Front Door Standard --------------------------------------------
echo "🌍  Creating Front Door profile $FD_PROFILE..."
az afd profile create \
  --resource-group $RGSHARED --profile-name "$FD_PROFILE" \
  --sku "$FD_SKU" --output none

az afd endpoint create \
  --resource-group $RGSHARED --profile-name "$FD_PROFILE" \
  --endpoint-name "$FD_PROFILE" --enabled-state Enabled --output none

# # Log Analytics workspace
# echo "📊  Creating Log Analytics workspace $LAW..."
# az monitor log-analytics workspace create \
#   --resource-group "$LAW_RG" \
#   --workspace-name "$LAW" \
#   --location "$LOC" \
#   --sku PerGB2018 \
#   --output none

# # ─── Storage account ────────────────────────────────────────────────────────
# echo "💾  Creating storage account $SA..."
# az storage account create \
#   --resource-group "$RG" \
#   --name "$SA" \
#   --sku Standard_LRS \
#   --kind StorageV2 \
#   --location "$LOC" \
#   --output none

# # ─── Key Vault ---------------------------------------------------

# az keyvault create --resource-group "$RG" --name "$KV" --location "$LOC" --output none

# az relay namespace create --resource-group rg-selectionnavigator-dev2-004 --name aj-relay-sn-msdn-03062025 --location southeastasia

# ─── All done -----------------------------------------------------------------
echo -e "\n✅  Environment bootstrap complete."
