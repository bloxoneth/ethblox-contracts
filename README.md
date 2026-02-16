## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### ETHBLOX Environment Split

- Local development runs on Anvil (`31337`)
- Deployments run on Base Sepolia

Setup:

```shell
cp .env.example .env
```

Local:

```shell
npm run local:up
npm run test
npm run sim:local
```

Persistent local state:

```shell
npm run local:status
npm run local:stop
```

`local:up` starts Anvil with persisted state at `.anvil/state.json` and only deploys BLOX + protocol contracts if they are missing on the current local chain. It writes deployment addresses to `deployments/anvil.contracts.json`.

Sepolia deploy:

```shell
npm run deploy:sepolia
```

### Go-Live Checklist (Contracts)

- Remove all local-only deployment assumptions (Anvil default keys, local treasury/receiver).
- Confirm production BLOX address and treasury/liquidity receiver env values are final.
- Re-run full test suite and invariant/economic tests against release commit.
- Freeze and verify constructor params used in deployment script before broadcasting.
- Verify deployed addresses and ABIs are exported to app config exactly once.
- Lock down owner/admin permissions and document any retained emergency controls.
- Archive deployment artifacts (tx hashes, bytecode, addresses) for audit trail.
- Do one final dry run on testnet with production-like env before mainnet deploy.

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
