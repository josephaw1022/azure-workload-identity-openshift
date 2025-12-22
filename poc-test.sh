#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Azure Workload Identity PoC Test ===${NC}\n"

# Variables
PROJECT_NAME="wi-poc-test"
SERVICE_ACCOUNT_NAME="wi-test-sa"
RESOURCE_GROUP="wi-poc-rg"
LOCATION="eastus"
IDENTITY_NAME="wi-poc-identity"
ISSUER_URL="https://oidcissuer2aa6a2e6.z13.web.core.windows.net"

# Step 1: Create OpenShift project
echo -e "${YELLOW}Step 1: Creating OpenShift project...${NC}"
if oc get project $PROJECT_NAME &>/dev/null; then
  echo -e "${GREEN}✓ Project $PROJECT_NAME already exists${NC}\n"
  oc project $PROJECT_NAME &>/dev/null
else
  oc new-project $PROJECT_NAME --skip-config-write
  echo -e "${GREEN}✓ Project $PROJECT_NAME created${NC}\n"
fi

# Step 2: Create service account
echo -e "${YELLOW}Step 2: Creating service account...${NC}"
cat <<EOF | oc apply --force-conflicts --server-side -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICE_ACCOUNT_NAME
  namespace: $PROJECT_NAME
  annotations:
    azure.workload.identity/client-id: "PLACEHOLDER"
EOF
echo -e "${GREEN}✓ Service account ready${NC}\n"

# Step 3: Create Azure resource group
echo -e "${YELLOW}Step 3: Creating Azure resource group...${NC}"
if az group show --name $RESOURCE_GROUP &>/dev/null; then
  echo -e "${GREEN}✓ Resource group $RESOURCE_GROUP already exists${NC}\n"
else
  az group create --name $RESOURCE_GROUP --location $LOCATION -o none
  echo -e "${GREEN}✓ Resource group $RESOURCE_GROUP created${NC}\n"
fi

# Step 4: Create user-assigned managed identity
echo -e "${YELLOW}Step 4: Creating user-assigned managed identity...${NC}"
if az identity show --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP &>/dev/null; then
  echo -e "${GREEN}✓ Managed identity $IDENTITY_NAME already exists${NC}"
else
  az identity create --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP --location $LOCATION -o none
  echo -e "${GREEN}✓ Managed identity created${NC}"
fi
CLIENT_ID=$(az identity show --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP --query clientId -o tsv)
echo -e "  Client ID: ${BLUE}$CLIENT_ID${NC}\n"

# Step 5: Create federated identity credential
echo -e "${YELLOW}Step 5: Creating federated identity credential...${NC}"
SUBJECT="system:serviceaccount:${PROJECT_NAME}:${SERVICE_ACCOUNT_NAME}"
FED_CRED_NAME="kubernetes-federated-${PROJECT_NAME}"
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

# Step 6: Update service account with actual client ID
echo -e "${YELLOW}Step 6: Updating service account with client ID...${NC}"
oc annotate serviceaccount $SERVICE_ACCOUNT_NAME \
  -n $PROJECT_NAME \
  azure.workload.identity/client-id=$CLIENT_ID \
  --overwrite
echo -e "${GREEN}✓ Service account annotated${NC}\n"

# Step 7: Deploy test deployment
echo -e "${YELLOW}Step 7: Deploying test deployment...${NC}"
cat <<EOF | oc apply --force-conflicts --server-side -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wi-test
  namespace: $PROJECT_NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: wi-test
  template:
    metadata:
      labels:
        app: wi-test
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: $SERVICE_ACCOUNT_NAME
      containers:
      - name: nginx
        image: nginx:alpine
        command: ["sleep", "infinity"]
EOF
echo -e "${GREEN}✓ Test deployment ready${NC}\n"

# Step 8: Wait for pod and check mutation
echo -e "${YELLOW}Step 8: Waiting for deployment to be ready...${NC}"
oc rollout status deployment/wi-test -n $PROJECT_NAME --timeout=60s || true
POD_NAME=$(oc get pods -n $PROJECT_NAME -l app=wi-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD_NAME" ]; then
  echo -e "${RED}✗ No pod found for deployment${NC}"
  exit 1
fi
echo ""

# Step 9: Verify the webhook mutated the pod
echo -e "${YELLOW}Step 9: Checking if webhook mutated the pod...${NC}"
echo -e "\n${BLUE}Environment variables injected:${NC}"
oc get pod $POD_NAME -n $PROJECT_NAME -o jsonpath='{.spec.containers[0].env[*].name}' | tr ' ' '\n' | grep -E "AZURE|IDENTITY" || echo "(none found)"

echo -e "\n${BLUE}Volume mounts:${NC}"
oc get pod $POD_NAME -n $PROJECT_NAME -o jsonpath='{.spec.containers[0].volumeMounts[*].name}' | tr ' ' '\n' | grep -i azure || echo "(none found)"

echo -e "\n${BLUE}Projected token volume:${NC}"
oc get pod $POD_NAME -n $PROJECT_NAME -o jsonpath='{.spec.volumes[*].name}' | tr ' ' '\n' | grep -i azure || echo "(none found)"

# Step 10: Check for token file inside pod
echo -e "\n${YELLOW}Step 10: Checking for token inside pod...${NC}"
TOKEN_PATH=$(oc get pod $POD_NAME -n $PROJECT_NAME -o jsonpath='{.spec.containers[0].volumeMounts[?(@.name=="azure-identity-token")].mountPath}' 2>/dev/null)
if [ -n "$TOKEN_PATH" ]; then
  echo -e "${GREEN}✓ Token mount found at: $TOKEN_PATH${NC}"
  echo -e "\n${BLUE}Token file contents (first 100 chars):${NC}"
  oc exec $POD_NAME -n $PROJECT_NAME -- cat ${TOKEN_PATH}/azure-identity-token 2>/dev/null | head -c 100 && echo "..."
else
  echo -e "${RED}✗ No azure-identity-token volume mount found${NC}"
  echo -e "${YELLOW}The webhook may not have mutated the pod correctly${NC}"
fi

echo -e "\n${BLUE}=== Summary ===${NC}"
echo -e "Project:          $PROJECT_NAME"
echo -e "Service Account:  $SERVICE_ACCOUNT_NAME"
echo -e "Resource Group:   $RESOURCE_GROUP"
echo -e "Managed Identity: $IDENTITY_NAME"
echo -e "Client ID:        $CLIENT_ID"
echo -e "Issuer:           $ISSUER_URL"

echo -e "\n${YELLOW}To test Azure auth manually, exec into the pod:${NC}"
echo -e "  oc exec -it \$(oc get pods -n $PROJECT_NAME -l app=wi-test -o jsonpath='{.items[0].metadata.name}') -n $PROJECT_NAME -- sh"
echo -e "\n${YELLOW}To clean up:${NC}"
echo -e "  oc delete project $PROJECT_NAME"
echo -e "  az group delete --name $RESOURCE_GROUP --yes --no-wait"
