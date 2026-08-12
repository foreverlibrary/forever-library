# Forever Library

**A public onchain commons for registering and minting creative work.**

Forever Library is an open-source protocol for building provenance of digital media through immutable, permissionless smart contracts. There is no gatekeeper, no API key, and no off switch: the contracts are the API. Anyone can mint, anyone can read, anyone can build on top — including without us.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-363636.svg)](contracts/v3/ForeverLibraryV3.sol)
[![verify](https://github.com/foreverlibrary/forever-library/actions/workflows/verify.yml/badge.svg)](https://github.com/foreverlibrary/forever-library/actions/workflows/verify.yml)

---

## Forever Library V3 (current)

`ForeverLibraryV3` is a single immutable ERC-1155 contract deployed once per chain: open permissionless minting, fully onchain metadata storage (SSTORE2), parallel metadata shards with per-token locking, soulbound tokens, per-token external renderers, ERC-2981 royalties. No admin, no pause, no upgrade path, no fees.

**→ [INTEGRATION.md](INTEGRATION.md) — the developer guide: addresses, ABIs, metadata standard, minting code, indexing, guarantees.**

### Live deployments

| Network | Chain ID | Address |
| --- | --- | --- |
| Ethereum | 1 | [`0xbfF70A12896b6cc6902DA43bad4725B0cdA62A43`](https://etherscan.io/address/0xbfF70A12896b6cc6902DA43bad4725B0cdA62A43) |
| Base | 8453 | [`0xBe186b03A9397daeEBee393946D65c1D114C81b9`](https://basescan.org/address/0xBe186b03A9397daeEBee393946D65c1D114C81b9) |
| Arbitrum One | 42161 | [`0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F`](https://arbiscan.io/address/0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F) |
| Soneium | 1868 | [`0x01E843E56c764e9a21cA5db6F10361B6eDab3DE5`](https://soneium.blockscout.com/address/0x01E843E56c764e9a21cA5db6F10361B6eDab3DE5) |
| Shape | 360 | [`0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F`](https://shapescan.xyz/address/0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F) |
| MegaETH | 4326 | [`0xC41D915178DC27151511F7044541aCa93Ec73392`](https://mega.etherscan.io/address/0xC41D915178DC27151511F7044541aCa93Ec73392) |
| Robinhood Chain | 4663 | [`0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F`](https://robinhoodchain.blockscout.com/address/0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F) |
| Sepolia (testnet) | 11155111 | [`0xd0478Da800Ed1A7cC1127A19858211d399BdEa90`](https://sepolia.etherscan.io/address/0xd0478Da800Ed1A7cC1127A19858211d399BdEa90) |
| Base Sepolia (testnet) | 84532 | [`0xb9D5207dF3602f8d5825be4D6bb6fE1e53cB7787`](https://sepolia.basescan.org/address/0xb9D5207dF3602f8d5825be4D6bb6fE1e53cB7787) |

> ⚠️ `0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F` appears on four chains and is **not** the same contract on all of them — on MegaETH it is a previous-generation contract. Always pair an address with its chain ID. Details in [INTEGRATION.md §2](INTEGRATION.md#2-contract-addresses--networks).

A separate Forever Library FA2 contract lives on Tezos at `KT1Tsqqffsf5H5KAWFasAiMajzqP71VqA9YD`.

### Repository contents

| Path | Contents |
| --- | --- |
| [`INTEGRATION.md`](INTEGRATION.md) | Developer integration guide |
| [`SECURITY.md`](SECURITY.md) | Vulnerability reporting and audit status |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`CHANGELOG.md`](CHANGELOG.md) | How to contribute; repository history |
| [`contracts/v3/`](contracts/v3/) | V3 source — canonical, Shape variant, per-chain flattened deployed sources, sha256 checksums |
| [`contracts/v3/test/`](contracts/v3/test/) | Full Foundry test suites (canonical + [Shape variant](contracts/v3/shape/test/)), run by CI on every push |
| [`abi/`](abi/) | ABIs: canonical, Shape variant, `IExternalRenderer` |
| [`legacy/`](legacy/) | Previous-generation contract sources |
| [`assets/chain-marks/`](assets/chain-marks/) | Per-chain collection marks (SVG) |

---

## Previous generations

Earlier Forever Library contracts remain live and immutable; their tokens stand permanently alongside V3's.

| Generation | Network | Address | Standard |
| --- | --- | --- | --- |
| V2 | Ethereum | [`0xd574aB9774955a582571910C70C4B0dad228F1Af`](https://etherscan.io/address/0xd574aB9774955a582571910C70C4B0dad228F1Af) | ERC-1155 |
| V1 | Ethereum | [`0x6132b7299Bf2d822932469ebD087a10695C9dFD1`](https://etherscan.io/address/0x6132b7299Bf2d822932469ebD087a10695C9dFD1) | ERC-721 |
| V2-family | Base | [`0x736b65E1858D981342D9998a24a2974e29F9508e`](https://basescan.org/address/0x736b65E1858D981342D9998a24a2974e29F9508e) | ERC-1155 |
| V2-family | MegaETH | [`0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F`](https://mega.etherscan.io/address/0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F) | ERC-1155 |
| V2-family | Soneium | [`0x1936416Ef80385f5839d986cCf88F51c79E6B95E`](https://soneium.blockscout.com/address/0x1936416Ef80385f5839d986cCf88F51c79E6B95E) | ERC-1155 |

Sources for the ERC-1155 generation are in [`legacy/`](legacy/); the ERC-721 contract lives in [`forever-library-smart-contract`](https://github.com/foreverlibrary/forever-library-smart-contract).

## Related repositories

- [`forever-library-smart-contract`](https://github.com/foreverlibrary/forever-library-smart-contract) — the original ERC-721 shared minting contract
- [`forever-library-contract-drafts`](https://github.com/foreverlibrary/forever-library-contract-drafts) — early Solidity prototypes
- [`forever-library-frontend-draft`](https://github.com/foreverlibrary/forever-library-frontend-draft) — pre-production frontend prototype
- `fl-eth-v3-mint` — the production V3 app (private); it holds no privileged access to the contracts, and everything it does is documented in [INTEGRATION.md](INTEGRATION.md)

## About

- Website: [foreverlibrary.xyz](https://foreverlibrary.xyz)
- Documentation: [Forever Library Docs](https://gleaming-polyester-5ee.notion.site/Forever-Library-Documentation-1d78cb99bdf28049857de54a2e48cc4c)

All code is [MIT licensed](LICENSE) and open for public review and reuse.
