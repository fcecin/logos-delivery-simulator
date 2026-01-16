#!/bin/sh

set -e

# 1. Install foundry and pnpm
curl -L https://foundry.paradigm.xyz | bash && . /root/.bashrc && foundryup --install 1.5.0 && export PATH=$PATH:$HOME/.foundry/bin

echo "installing pnpm..."
npm i -g pnpm@10.23.0

# 2. Clone and build the repository
if [ ! -d "waku-rlnv2-contract" ]; then
    git clone https://github.com/waku-org/waku-rlnv2-contract.git
fi

if [ -z "$RLN_CONTRACT_REPO_COMMIT" ]; then
    echo "RLN_CONTRACT_REPO_COMMIT is not set"
    exit 1
fi

cd /waku-rlnv2-contract
git checkout $RLN_CONTRACT_REPO_COMMIT
# git checkout temp-with-imt-dep
ls
# 3. Compile Contract Repo
echo "forge install..."
forge install
echo "pnpm install..."
pnpm install
echo "forge build..."
forge build

# 4. Export environment variables
export RCL_URL=$RCL_URL
export PRIVATE_KEY=$PRIVATE_KEY
export ETH_FROM=$ETH_FROM
# Dummy values
export API_KEY_ETHERSCAN=123
export API_KEY_CARDONA=123
export API_KEY_LINEASCAN=123

# Helper function to validate Ethereum addresses
validate_address() {
    local address="$1"
    local name="$2"
    
    if [ -z "$address" ]; then
        echo "Error: Failed to extract $name address"
        exit 1
    fi
    
    if ! echo "$address" | grep -qE "^0x[a-fA-F0-9]{40}$"; then
        echo "Error: Invalid $name address format: $address"
        exit 1
    fi
    
    echo "Successfully extracted $name address: $address"
}

# 5. Deploy the TestToken Proxy with the TestToken implementation contracts
printf "\nDeploying TestToken Proxy (ERC20 Token Contract)...\n"
DEPLOY_TST_PROXY_OUTPUT=$(ETH_FROM=$ETH_FROM forge script script/DeployTokenWithProxy.s.sol:DeployTokenWithProxy --broadcast -vv --rpc-url http://foundry:8545 --private-key $PRIVATE_KEY)
if [ $? -ne 0 ]; then
    echo "Error: TestToken Proxy deployment failed"
    echo "Forge output: $DEPLOY_TST_PROXY_OUTPUT"
    exit 1
fi

export PROXY_TOKEN_ADDRESS=$(echo "$DEPLOY_TST_PROXY_OUTPUT" | grep -o "0: address 0x[a-fA-F0-9]\{40\}" | head -n1 | cut -d' ' -f3)
validate_address "$PROXY_TOKEN_ADDRESS" "TestToken Proxy"
export TOKEN_ADDRESS=$PROXY_TOKEN_ADDRESS

printf "\nDeploying LinearPriceCalculator Contract...\n"
forge script script/Deploy.s.sol --broadcast -vv --rpc-url http://foundry:8545 --tc DeployPriceCalculator --private-key $PRIVATE_KEY
if [ $? -ne 0 ]; then
    echo "Error: LinearPriceCalculator deployment failed"
    exit 1
fi
echo "LinearPriceCalculator deployment completed successfully"

printf "\nDeploying RLN contract...\n"
forge script script/Deploy.s.sol --broadcast -vv --rpc-url http://foundry:8545 --tc DeployWakuRlnV2 --private-key $PRIVATE_KEY
if [ $? -ne 0 ]; then
    echo "Error: RLN contract deployment failed"
    exit 1
fi
echo "RLN contract deployment completed successfully"

printf "\nDeploying Proxy contract...\n"
DEPLOY_WAKURLN_PROXY_OUTPUT=$(ETH_FROM=$ETH_FROM forge script script/Deploy.s.sol --broadcast -vvv --rpc-url http://foundry:8545 --tc DeployProxy --private-key $PRIVATE_KEY)
if [ $? -ne 0 ]; then
    echo "Error: Proxy contract deployment failed"
    echo "Forge output: $DEPLOY_WAKURLN_PROXY_OUTPUT"
    exit 1
fi

export RLN_CONTRACT_ADDRESS=$(echo "$DEPLOY_WAKURLN_PROXY_OUTPUT" | grep -o "0: address 0x[a-fA-F0-9]\{40\}" | head -n1 | cut -d' ' -f3)
validate_address "$RLN_CONTRACT_ADDRESS" "RLN Proxy"

# 6. Contract deployment completed
printf "\nContract deployment completed successfully"
printf "\nTOKEN_ADDRESS: $TOKEN_ADDRESS"
printf "\nRLN_CONTRACT_ADDRESS: $RLN_CONTRACT_ADDRESS"
printf "\nEach account registering a membership needs to first mint the token and approve the contract to spend it on their behalf."



# # 7. Run ETH-based minting for first N accounts (for debugging)
# # Disable set -e for this section so errors don't exit the script
# set +e
# printf "\n\n=== Running ETH-based token minting (DEBUG) ===\n"
# if [ -f "/shared/anvil-config.txt" ]; then
#     # Configuration
#     NUM_ACCOUNTS_TO_MINT=${NUM_ACCOUNTS_TO_MINT:-36}
#     ETH_AMOUNT_PER_MINT=${ETH_AMOUNT_PER_MINT:-5000000000000000000}  # Default: 1 ETH in wei
    
#     echo "Token contract: $TOKEN_ADDRESS"
#     echo "RPC URL: $RPC_URL"
#     echo "Number of accounts to mint: $NUM_ACCOUNTS_TO_MINT"
#     echo "ETH amount per mint: $ETH_AMOUNT_PER_MINT wei"
#     echo ""
    
#     # Install jq if not present (needed to parse JSON)
#     if ! command -v jq &> /dev/null; then
#         echo "Installing jq..."
#         apt-get update -qq && apt-get install -y -qq jq
#     fi
    
#     # Extract private keys and addresses from anvil config
#     PRIVATE_KEYS_FILE=$(mktemp)
#     ADDRESSES_FILE=$(mktemp)
#     cat /shared/anvil-config.txt | jq -r '.private_keys[]' | head -n $NUM_ACCOUNTS_TO_MINT > "$PRIVATE_KEYS_FILE"
#     cat /shared/anvil-config.txt | jq -r '.available_accounts[]' | head -n $NUM_ACCOUNTS_TO_MINT > "$ADDRESSES_FILE"
    
#     # Store the deployer's private key before we start looping
#     DEPLOYER_PRIVATE_KEY=$PRIVATE_KEY
    
#     # Create temporary files to store results
#     SUCCESS_FILE=$(mktemp)
#     FAIL_FILE=$(mktemp)
#     echo "0" > "$SUCCESS_FILE"
#     echo "0" > "$FAIL_FILE"
    
#     # Loop through each account and call mintWithETH
#     ACCOUNT_NUM=1
#     while [ $ACCOUNT_NUM -le $NUM_ACCOUNTS_TO_MINT ]; do
#         TARGET_PRIVATE_KEY=$(sed -n "${ACCOUNT_NUM}p" "$PRIVATE_KEYS_FILE")
#         TARGET_ADDRESS=$(sed -n "${ACCOUNT_NUM}p" "$ADDRESSES_FILE")
        
#         if [ -z "$TARGET_PRIVATE_KEY" ] || [ -z "$TARGET_ADDRESS" ]; then
#             echo "Warning: Missing private key or address for account $ACCOUNT_NUM"
#             ACCOUNT_NUM=$((ACCOUNT_NUM + 1))
#             continue
#         fi
        
#         echo "[$ACCOUNT_NUM/$NUM_ACCOUNTS_TO_MINT] Minting tokens with ETH for $TARGET_ADDRESS"
        
#         # Step 1: Mint tokens with ETH using the target account's private key
#         #cast send format: mintWithETH(address) <TO_ACCOUNT> --value <ETH_AMOUNT> --from <MINTING_ACCOUNT>
#         MINT_TX_OUTPUT=$(cast send $TOKEN_ADDRESS \
#             "mintWithETH(address)" \
#             $TARGET_ADDRESS \
#             --value $ETH_AMOUNT_PER_MINT \
#             --rpc-url $RPC_URL \
#             --private-key $TARGET_PRIVATE_KEY \
#             --from $TARGET_ADDRESS \
#             2>&1)
        
#         MINT_EXIT_CODE=$?

#         if [ $MINT_EXIT_CODE -eq 0 ]; then
#             MINT_TX_HASH=$(echo "$MINT_TX_OUTPUT" | grep "transactionHash" | awk '{print $2}')
#             echo "✓ [$ACCOUNT_NUM] Mint successful for $TARGET_ADDRESS"
#             echo "  Mint Transaction: $MINT_TX_HASH"
            
#             # Step 2: Approve the RLN contract to spend tokens
#             echo "  Approving RLN contract to spend tokens..."
#             # We need to calculate the approval amount (typically same as or more than mint amount)
#             # For RLN membership, we need enough tokens based on message limit
#             # Default approval amount = mint amount (can be adjusted)
#             APPROVAL_AMOUNT=$ETH_AMOUNT_PER_MINT
            
#             APPROVE_TX_OUTPUT=$(cast send $TOKEN_ADDRESS \
#                 "approve(address,uint256)" \
#                 $RLN_CONTRACT_ADDRESS \
#                 $APPROVAL_AMOUNT \
#                 --rpc-url $RPC_URL \
#                 --private-key $TARGET_PRIVATE_KEY \
#                 --from $TARGET_ADDRESS \
#                 2>&1)

#             APPROVE_EXIT_CODE=$?
            
#             if [ $APPROVE_EXIT_CODE -eq 0 ]; then
#                 APPROVE_TX_HASH=$(echo "$APPROVE_TX_OUTPUT" | grep "transactionHash" | awk '{print $2}')
#                 echo "  ✓ Approval successful"
#                 echo "    Approve Transaction: $APPROVE_TX_HASH"
#                 SUCCESS_COUNT=$(cat "$SUCCESS_FILE")
#                 echo $((SUCCESS_COUNT + 1)) > "$SUCCESS_FILE"
#             else
#                 echo "  ✗ Approval failed for $TARGET_ADDRESS"
#                 echo "    Error: $APPROVE_TX_OUTPUT"
#                 FAIL_COUNT=$(cat "$FAIL_FILE")
#                 echo $((FAIL_COUNT + 1)) > "$FAIL_FILE"
#             fi
#         else
#             echo "✗ [$ACCOUNT_NUM] Mint failed for $TARGET_ADDRESS"
#             echo "  Error: $MINT_TX_OUTPUT"
#             FAIL_COUNT=$(cat "$FAIL_FILE")
#             echo $((FAIL_COUNT + 1)) > "$FAIL_FILE"
#         fi
#         echo ""
        
#         # Small delay between transactions to avoid nonce issues
#         if [ $ACCOUNT_NUM -lt $NUM_ACCOUNTS_TO_MINT ]; then
#             sleep 2
#         fi
        
#         ACCOUNT_NUM=$((ACCOUNT_NUM + 1))
#     done
    
#     # Read final counts
#     SUCCESS_COUNT=$(cat "$SUCCESS_FILE")
#     FAIL_COUNT=$(cat "$FAIL_FILE")
    
#     # Cleanup temp files
#     rm -f "$SUCCESS_FILE" "$FAIL_FILE" "$PRIVATE_KEYS_FILE" "$ADDRESSES_FILE"
    
#     echo "============================================================"
#     echo "ETH minting completed: $SUCCESS_COUNT successful, $FAIL_COUNT failed"
#     echo "============================================================"
    
#     if [ $FAIL_COUNT -eq 0 ]; then
#         printf "\n✓ ETH-based token minting completed successfully\n"
#     else
#         printf "\n✗ Some ETH-based token mints failed ($FAIL_COUNT/$NUM_ACCOUNTS_TO_MINT)\n"
#         printf "This is a debug feature and won't fail the deployment.\n"
#     fi
# else
#     echo "Warning: anvil-config.txt not found at /shared/anvil-config.txt"
#     echo "Skipping ETH-based token minting."
# fi

# # Re-enable set -e for any subsequent commands
# set -e