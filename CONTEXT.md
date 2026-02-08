# ETHBLOX – Project Context

This repo contains the ETHBLOX MVP contracts.

Key decisions:
- Single ERC721 (BuildNFT) represents all bricks/builds
- geometryHash is UNIQUE at mint, but FREED on burn
- Mint fee = 0.01 ETH
  - 50% to component owners (via FeeRegistry)
  - 30% liquidityReceiver
  - 20% protocolTreasury
- Mint locks BLOX = mass * 1e18
- Burn:
  - 90% BLOX returned to owner
  - 10% sent to Distributor
- No IPFS on-chain; tokenURI stored as string
- Using OpenZeppelin v5 + Foundry

Current state:
- BuildNFT.sol compiles
- Forge build passes
- Tests in progress:
  - geometry reuse after burn
  - BLOX lock/unlock assertions
  - fee routing assertions

Open questions:
- LicenseNFT (ERC1155) integration deferred
- Future mint fee may increase due to license purchases

## Metadata Schema (IPFS folder-based)
Required JSON fields: `name`, `description`, `image`, `external_url`, `attributes`.

Truth anchors (must reflect on-chain):
- `geometryHash`
- `kind`
- `mass`
- `density`
- `specKey` (kind==0 only)
- `componentsHash` (optional)
