#!/bin/bash

# CLOB Contract Deployment Script
# Deploys the CLOB contract to a local Anvil instance

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}    CLOB Contract Deployment Script     ${NC}"
echo -e "${BLUE}========================================${NC}"
echo

# Default values
RPC_URL="${RPC_URL:-http://localhost:8545}"
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

# Check if anvil is running
echo -e "${YELLOW}Checking Anvil connection...${NC}"
if ! cast chain-id --rpc-url $RPC_URL &>/dev/null; then
    echo -e "${RED}Error: Cannot connect to Anvil at $RPC_URL${NC}"
    echo -e "${RED}Please ensure Anvil is running with: anvil${NC}"
    exit 1
fi

CHAIN_ID=$(cast chain-id --rpc-url $RPC_URL)
echo -e "${GREEN}✓ Connected to chain ID: $CHAIN_ID${NC}"

# Build the contracts
echo -e "${YELLOW}Building contracts...${NC}"
forge build

# Deploy CLOB contract
echo -e "${YELLOW}Deploying CLOB contract...${NC}"
DEPLOY_OUTPUT=$(forge create src/contracts/clob/CLOB.sol:CLOB --broadcast \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --json 2>/dev/null)

# Extract the deployed contract address
CLOB_ADDRESS=$(echo $DEPLOY_OUTPUT | jq -r '.deployedTo')
DEPLOYER_ADDRESS=$(echo $DEPLOY_OUTPUT | jq -r '.deployer')
TX_HASH=$(echo $DEPLOY_OUTPUT | jq -r '.transactionHash')

if [ "$CLOB_ADDRESS" == "null" ] || [ -z "$CLOB_ADDRESS" ]; then
    echo -e "${RED}Error: Failed to deploy CLOB contract${NC}"
    echo "Output: $DEPLOY_OUTPUT"
    exit 1
fi

echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    DEPLOYMENT SUCCESSFUL!              ${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo -e "${BLUE}CLOB Contract Address:${NC} $CLOB_ADDRESS"
echo -e "${BLUE}Deployer Address:${NC} $DEPLOYER_ADDRESS"
echo -e "${BLUE}Transaction Hash:${NC} $TX_HASH"
echo -e "${BLUE}RPC URL:${NC} $RPC_URL"
echo -e "${BLUE}Chain ID:${NC} $CHAIN_ID"
echo

# Save deployment info to file
# DEPLOYMENT_FILE="clob-deployment-$(date +%Y%m%d-%H%M%S).json"
# cat > $DEPLOYMENT_FILE <<EOF
# {
#   "network": "local",
#   "chainId": $CHAIN_ID,
#   "contracts": {
#     "CLOB": {
#       "address": "$CLOB_ADDRESS",
#       "deployer": "$DEPLOYER_ADDRESS",
#       "transactionHash": "$TX_HASH",
#       "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
#     }
#   },
#   "rpcUrl": "$RPC_URL"
# }
# EOF
# echo -e "${GREEN}Deployment info saved to: $DEPLOYMENT_FILE${NC}"
# echo

# Verify deployment
# echo -e "${YELLOW}Verifying deployment...${NC}"
# CODE_SIZE=$(cast code $CLOB_ADDRESS --rpc-url $RPC_URL | wc -c)
# if [ $CODE_SIZE -gt 10 ]; then
#     echo -e "${GREEN}✓ Contract deployed successfully (code size: $((CODE_SIZE/2)) bytes)${NC}"
# else
#     echo -e "${RED}⚠ Warning: Contract may not be deployed correctly${NC}"
# fi

# echo
# echo -e "${BLUE}To interact with the contract:${NC}"
# echo -e "  export CLOB_ADDRESS=$CLOB_ADDRESS"
# echo -e "  cast call \$CLOB_ADDRESS 'nextOrderId()' --rpc-url $RPC_URL"
# echo
# echo -e "${GREEN}Deployment complete!${NC}"
