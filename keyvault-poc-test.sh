#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Azure Workload Identity + External Secrets Setup ===${NC}\n"

# Variables - Update these for your environment
RESOURCE_GROUP="external-secrets-rg"
LOCATION="eastus"
IDENTITY_NAME="external-secrets-identity"
KEYVAULT_NAME="kubesoar-homelab-67029"
ISSUER_URL="https://oidcissuer2aa6a2e6.z13.web.core.windows.net/"

# External Secrets Operator namespace and service account
NAMESPACE="external-secrets"
SERVICE_ACCOUNT_NAME="workload-identity-sa"
CLUSTER_SECRET_STORE_NAME="azure-keyvault-store"

# Federated credential name
FED_CRED_NAME="external-secrets-federated-${NAMESPACE}"

# Step 1: Create Azure resource group
echo -e "${YELLOW}Step 1: Creating Azure resource group...${NC}"
if az group show --name $RESOURCE_GROUP &>/dev/null; then
  echo -e "${GREEN}✓ Resource group $RESOURCE_GROUP already exists${NC}\n"
else
  az group create --name $RESOURCE_GROUP --location $LOCATION -o none
  echo -e "${GREEN}✓ Resource group $RESOURCE_GROUP created${NC}\n"
fi

# Step 2: Create user-assigned managed identity
echo -e "${YELLOW}Step 2: Creating user-assigned managed identity...${NC}"
if az identity show --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP &>/dev/null; then
  echo -e "${GREEN}✓ Managed identity $IDENTITY_NAME already exists${NC}"
else
  az identity create --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP --location $LOCATION -o none
  echo -e "${GREEN}✓ Managed identity created${NC}"
fi

# Get identity properties
CLIENT_ID=$(az identity show --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP --query principalId -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

echo -e "  Client ID:    ${BLUE}$CLIENT_ID${NC}"
echo -e "  Principal ID: ${BLUE}$PRINCIPAL_ID${NC}"
echo -e "  Tenant ID:    ${BLUE}$TENANT_ID${NC}\n"

# Step 3: Grant Key Vault access to the managed identity (RBAC)
echo -e "${YELLOW}Step 3: Granting Key Vault Secrets User role to managed identity...${NC}"
KEYVAULT_ID=$(az keyvault show --name $KEYVAULT_NAME --query id -o tsv 2>/dev/null || echo "")
if [ -z "$KEYVAULT_ID" ]; then
  echo -e "${RED}✗ Key Vault $KEYVAULT_NAME not found${NC}"
  echo -e "${YELLOW}Please create the Key Vault first or update KEYVAULT_NAME variable${NC}\n"
else
  # Check if role assignment already exists
  EXISTING_ROLE=$(az role assignment list --assignee $PRINCIPAL_ID --scope $KEYVAULT_ID --role "Key Vault Secrets User" --query "[0].id" -o tsv 2>/dev/null || echo "")
  if [ -n "$EXISTING_ROLE" ]; then
    echo -e "${GREEN}✓ Role assignment already exists${NC}\n"
  else
    az role assignment create \
      --assignee-object-id $PRINCIPAL_ID \
      --assignee-principal-type ServicePrincipal \
      --role "Key Vault Secrets User" \
      --scope $KEYVAULT_ID \
      -o none
    echo -e "${GREEN}✓ Key Vault Secrets User role assigned${NC}\n"
  fi
fi

# Step 4: Ensure OpenShift namespace exists
echo -e "${YELLOW}Step 4: Ensuring namespace $NAMESPACE exists...${NC}"
if oc get namespace $NAMESPACE &>/dev/null; then
  echo -e "${GREEN}✓ Namespace $NAMESPACE already exists${NC}\n"
else
  oc create namespace $NAMESPACE
  echo -e "${GREEN}✓ Namespace $NAMESPACE created${NC}\n"
fi

# Step 5: Create service account with workload identity annotations
echo -e "${YELLOW}Step 5: Creating service account with workload identity annotations...${NC}"
cat <<EOF | oc apply --force-conflicts --server-side -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICE_ACCOUNT_NAME
  namespace: $NAMESPACE
  annotations:
    azure.workload.identity/client-id: "$CLIENT_ID"
    azure.workload.identity/tenant-id: "$TENANT_ID"
  labels:
    azure.workload.identity/use: "true"
EOF
echo -e "${GREEN}✓ Service account $SERVICE_ACCOUNT_NAME created with annotations${NC}\n"

# Step 6: Create federated identity credential
echo -e "${YELLOW}Step 6: Creating federated identity credential...${NC}"
SUBJECT="system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}"

if az identity federated-credential show --name $FED_CRED_NAME --identity-name $IDENTITY_NAME --resource-group $RESOURCE_GROUP &>/dev/null; then
  echo -e "${GREEN}✓ Federated credential already exists${NC}"
else
  az identity federated-credential create \
    --name "$FED_CRED_NAME" \
    --identity-name $IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP \
    --issuer $ISSUER_URL \
    --subject "$SUBJECT" \
    --audiences "api://AzureADTokenExchange" \
    -o none
  echo -e "${GREEN}✓ Federated credential created${NC}"
fi
echo -e "  Subject: ${BLUE}$SUBJECT${NC}\n"

# Step 7: Create ClusterSecretStore
echo -e "${YELLOW}Step 7: Creating ClusterSecretStore...${NC}"
KEYVAULT_URL="https://${KEYVAULT_NAME}.vault.azure.net"

cat <<EOF | oc apply --force-conflicts --server-side -f -
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: $CLUSTER_SECRET_STORE_NAME
spec:
  provider:
    azurekv:
      authType: WorkloadIdentity
      vaultUrl: "$KEYVAULT_URL"
      serviceAccountRef:
        name: $SERVICE_ACCOUNT_NAME
        namespace: $NAMESPACE
EOF
echo -e "${GREEN}✓ ClusterSecretStore $CLUSTER_SECRET_STORE_NAME created${NC}\n"

# Step 8: Ensure target namespace exists
TARGET_NAMESPACE="datadog"
echo -e "${YELLOW}Step 8: Ensuring target namespace $TARGET_NAMESPACE exists...${NC}"
if oc get namespace $TARGET_NAMESPACE &>/dev/null; then
  echo -e "${GREEN}✓ Namespace $TARGET_NAMESPACE already exists${NC}\n"
else
  oc create namespace $TARGET_NAMESPACE
  echo -e "${GREEN}✓ Namespace $TARGET_NAMESPACE created${NC}\n"
fi

# Step 9: Create ExternalSecret for Datadog credentials
echo -e "${YELLOW}Step 9: Creating ExternalSecret for Datadog credentials...${NC}"
cat <<EOF | oc apply --force-conflicts --server-side -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: datadog-credentials
  namespace: $TARGET_NAMESPACE
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: $CLUSTER_SECRET_STORE_NAME
    kind: ClusterSecretStore
  target:
    name: datadog-credentials
    creationPolicy: Owner
  data:
  - secretKey: api-key
    remoteRef:
      key: datadog-api-key
  - secretKey: app-key
    remoteRef:
      key: datadog-app-key
EOF
echo -e "${GREEN}✓ ExternalSecret datadog-credentials created in $TARGET_NAMESPACE namespace${NC}\n"

# Summary
echo -e "${BLUE}=== Setup Complete ===${NC}\n"
echo -e "${GREEN}Summary:${NC}"
echo -e "  Resource Group:       $RESOURCE_GROUP"
echo -e "  Managed Identity:     $IDENTITY_NAME"
echo -e "  Client ID:            $CLIENT_ID"
echo -e "  Tenant ID:            $TENANT_ID"
echo -e "  SA Namespace:         $NAMESPACE"
echo -e "  Service Account:      $SERVICE_ACCOUNT_NAME"
echo -e "  ClusterSecretStore:   $CLUSTER_SECRET_STORE_NAME"
echo -e "  Target Namespace:     $TARGET_NAMESPACE"
echo -e "  ExternalSecret:       datadog-credentials"
echo -e "  Key Vault URL:        $KEYVAULT_URL"
echo -e "  OIDC Issuer:          $ISSUER_URL"

echo -e "\n${YELLOW}To verify the setup:${NC}"
echo -e "  oc get serviceaccount $SERVICE_ACCOUNT_NAME -n $NAMESPACE -o yaml"
echo -e "  oc get clustersecretstore $CLUSTER_SECRET_STORE_NAME -o yaml"
echo -e "  oc get externalsecret datadog-credentials -n $TARGET_NAMESPACE -o yaml"
echo -e "  oc get secret datadog-credentials -n $TARGET_NAMESPACE -o yaml"

echo -e "\n${YELLOW}To check ExternalSecret sync status:${NC}"
echo -e "  oc get externalsecret datadog-credentials -n $TARGET_NAMESPACE"

echo -e "\n${YELLOW}To clean up:${NC}"
echo -e "  oc delete externalsecret datadog-credentials -n $TARGET_NAMESPACE"
echo -e "  oc delete clustersecretstore $CLUSTER_SECRET_STORE_NAME"
echo -e "  oc delete serviceaccount $SERVICE_ACCOUNT_NAME -n $NAMESPACE"
echo -e "  az group delete --name $RESOURCE_GROUP --yes --no-wait"
