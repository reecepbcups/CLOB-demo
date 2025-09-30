# [WAVS](https://docs.wavs.xyz) Symbient

TOP SECRET: a collection of fundraising, governance, and incentive mechanisms for cybernetic organisms.

### Solidity

Install the required packages to build the Solidity contracts. This project supports both [submodules](./.gitmodules) and [npm packages](./package.json).

```bash
# Install packages (npm & submodules)
task setup

# Build the contracts
task build:forge

# Run the solidity tests
# task test
```

## Build WASI components

Now build the WASI components into the `compiled` output directory.

> \[!WARNING]
> If you get: `error: no registry configured for namespace "wavs"`
>
> run, `wkg config --default-registry wa.dev`

> \[!WARNING]
> If you get: `failed to find the 'wasm32-wasip1' target and 'rustup' is not available`
>
> `brew uninstall rust` & install it from <https://rustup.rs>

```bash
task build:wasi
```

## Testing the Price Feed Component Locally

```bash
# task wasi:exec COMPONENT_FILENAME=component.wasm INPUT_DATA="test-string"
```

## WAVS

## Start Environment

Start an ethereum node (anvil), the WAVS service, and deploy AVS contracts to the local network.

### Enable Telemetry (optional)

Set Log Level:

- Open the `.env` file.
- Set the `log_level` variable for wavs to debug to ensure detailed logs are captured.

> \[!NOTE]
> To see details on how to access both traces and metrics, please check out [Telemetry Documentation](telemetry/telemetry.md).

### Start the backend

```bash docci-background docci-delay-after=5
# This must remain running in your terminal. Use another terminal to run other commands.
# You can stop the services with `ctrl+c`. Some MacOS terminals require pressing it twice.
cp .env.example .env

# update the .env for either LOCAL or TESTNET

# Starts anvil + IPFS, WARG, Jaeger, and prometheus.
task start-all-local
```

## WAVS Deployment Script

This script automates the complete WAVS deployment process in a single command:

```bash
# export SKIP_COMPONENT_UPLOAD=true && export SKIP_CONTRACT_UPLOAD=true
task deploy:full && task deploy:single-operator-poa-local
```

## Clob Setup

```bash
FUNDED_KEY=$(task config:funded-key)
CLOB_ADDR=`jq -rc .clob.address .docker/deployment_summary.json`

echo "Deploying Token A (BASE)..."
OUTPUT_A=`forge script script/DeployTestToken.s.sol:DeployTestToken --rpc-url http://localhost:8545 --private-key $FUNDED_KEY --broadcast`
TOKEN_A=`echo "$OUTPUT_A" | grep 'Token Address: 0x' | awk '{print $3}'`

echo "Deploying Token B (QUOTE)..."
OUTPUT_B=`forge script script/DeployTestToken.s.sol:DeployTestToken --rpc-url http://localhost:8545 --private-key $FUNDED_KEY --broadcast`
TOKEN_B=`echo "$OUTPUT_B" | grep 'Token Address: 0x' | awk '{print $3}'`

echo "TOKEN_A (Base): $TOKEN_A"
echo "TOKEN_B (Quote): $TOKEN_B"

# Approve tokens for CLOB contract
echo "Approving tokens for CLOB..."
cast send $TOKEN_A "approve(address,uint256)" $CLOB_ADDR 1000000000000000000000000 --rpc-url http://localhost:8545 --private-key $FUNDED_KEY &> /dev/null
cast send $TOKEN_B "approve(address,uint256)" $CLOB_ADDR 1000000000000000000000000 --rpc-url http://localhost:8545 --private-key $FUNDED_KEY &> /dev/null
```

## Clob Perform Logic

```bash
# Place a SELL order (selling 100 TOKEN_A for 2 TOKEN_B each)
echo "Placing SELL order: 100 TOKEN_A at price 2e18..."
SELL_ORDER=`cast send $CLOB_ADDR "placeOrder(uint8,address,address,uint256,uint256)" 1 $TOKEN_A $TOKEN_B 2000000000000000000 100000000000000000000 --rpc-url http://localhost:8545 --private-key $FUNDED_KEY --json`
echo "Sell order transaction: $SELL_ORDER"
# docker logs wavs-1

# Place a BUY order (buying 50 TOKEN_A for 2 TOKEN_B each)
echo "Placing BUY order: 50 TOKEN_A at price 2e18..."
BUY_ORDER=`cast send $CLOB_ADDR "placeOrder(uint8,address,address,uint256,uint256)" 0 $TOKEN_A $TOKEN_B 2000000000000000000 50000000000000000000 --rpc-url http://localhost:8545 --private-key $FUNDED_KEY --json`
echo "Buy order transaction: $BUY_ORDER"

# wait a second for WAVS to process the order
sleep 3
docker logs wavs-1

# Check orders
echo "Checking order #1:"
ORDER_1=`cast call $CLOB_ADDR "getOrder(uint256)" 1 --rpc-url http://localhost:8545`
sh decode_order.sh "$ORDER_1"

  echo "Checking order #2:"
  ORDER_2=`cast call $CLOB_ADDR "getOrder(uint256)" 2 --rpc-url http://localhost:8545`
  sh decode_order.sh "$ORDER_1"

  # Check escrow balances
  TRADER=`cast wallet address --private-key $FUNDED_KEY`
  echo "Trader address: $TRADER"
  echo "Escrow balance TOKEN_A:"
  cast call $CLOB_ADDR "getEscrowBalance(address,address)" $TRADER $TOKEN_A --rpc-url http://localhost:8545
  echo "Escrow balance TOKEN_B:"
  cast call $CLOB_ADDR "getEscrowBalance(address,address)" $TRADER $TOKEN_B --rpc-url http://localhost:8545
```

### Claude Code

To spin up a sandboxed instance of [Claude Code](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview) in a Docker container that only has access to this project's files, run the following command:

```bash docci-ignore
npm run claude-code
# or with no restrictions (--dangerously-skip-permissions)
npm run claude-code:unrestricted
```
