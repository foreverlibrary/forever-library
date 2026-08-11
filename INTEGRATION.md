# Integrating with Forever Library V3

> `ForeverLibraryV3` · `VERSION 3.0.0` · solc `0.8.28+commit.7893614a` · OpenZeppelin 5.1.0 · optimizer 200 runs · EVM `cancun`
>
> Source: [`contracts/v3/`](contracts/v3/) · ABI: [`abi/`](abi/) · License: MIT

## 1. Overview

Forever Library V3 is a single immutable ERC-1155 contract, deployed once per chain, with open permissionless minting: anyone can call `mint` and create a token type, and no address can stop them. There is no pause, no upgrade path, no proxy, no admin role over tokens, no allowlist, and no fee — the contract is entirely non-payable and rejects ether. Each token carries an array of *shards*, any one of which can serve as its metadata; a shard is either `Onchain` (the complete metadata JSON stored as EVM code via SSTORE2), `Pointer` (a URI string), or `Renderer` (another contract resolved by staticcall at read time). The creator selects which shard `uri()` serves, may append more shards forever (until locked), and may permanently lock the set. This document is written for people building their own minting UI, indexer, gallery, or renderer against those contracts directly. The contracts are the API; nothing here requires the Forever Library website, an API key, or our permission.

---

## 2. Contract addresses & networks

| Network | Chain ID | Address | Deploy block | Verified |
| --- | --- | --- | --- | --- |
| Ethereum | 1 | [`0xbfF70A12896b6cc6902DA43bad4725B0cdA62A43`](https://etherscan.io/address/0xbfF70A12896b6cc6902DA43bad4725B0cdA62A43#code) | 25574371 | Etherscan, Sourcify |
| Base | 8453 | [`0xBe186b03A9397daeEBee393946D65c1D114C81b9`](https://basescan.org/address/0xBe186b03A9397daeEBee393946D65c1D114C81b9#code) | 48886862 | Basescan |
| Arbitrum One | 42161 | [`0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F`](https://arbiscan.io/address/0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F#code) | 485922302 | Sourcify (exact match) |
| Soneium | 1868 | [`0x01E843E56c764e9a21cA5db6F10361B6eDab3DE5`](https://soneium.blockscout.com/address/0x01E843E56c764e9a21cA5db6F10361B6eDab3DE5?tab=contract) | 25717391 | Blockscout |
| Shape | 360 | [`0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F`](https://shapescan.xyz/address/0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F) | 31414171 | **not yet** — source in [`contracts/v3/flattened/shape/`](contracts/v3/flattened/shape/) |
| MegaETH | 4326 | [`0xC41D915178DC27151511F7044541aCa93Ec73392`](https://mega.etherscan.io/address/0xC41D915178DC27151511F7044541aCa93Ec73392#code) | 21770463 | Etherscan (MegaETH) |
| Robinhood Chain | 4663 | [`0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F`](https://robinhoodchain.blockscout.com/address/0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F?tab=contract) | 14937202 | Blockscout |
| Sepolia (testnet) | 11155111 | [`0xd0478Da800Ed1A7cC1127A19858211d399BdEa90`](https://sepolia.etherscan.io/address/0xd0478Da800Ed1A7cC1127A19858211d399BdEa90#code) | 11247557 | Etherscan |
| Base Sepolia (testnet) | 84532 | [`0xb9D5207dF3602f8d5825be4D6bb6fE1e53cB7787`](https://sepolia.basescan.org/address/0xb9D5207dF3602f8d5825be4D6bb6fE1e53cB7787#code) | 44570445 | Sourcify (exact match) |

Every deployed source can also be checked against this repository: [`contracts/v3/DEPLOY_CHECKSUMS.txt`](contracts/v3/DEPLOY_CHECKSUMS.txt) holds the sha256 of each chain's flattened source, and the flattened files themselves are in [`contracts/v3/flattened/`](contracts/v3/flattened/).

Notes you need before you write code against these:

- **`0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F` exists on four chains and is not the same contract on all of them.** On Arbitrum, Shape, and Robinhood it is Forever Library V3 (same deployer wallet, same nonce on each chain). On **MegaETH the identical address is a previous-generation Forever Library ERC-1155** — different code, different ABI. V3 on MegaETH is `0xC41D…3392`. Always pin the chain ID alongside the address.
- **`0xE76abb5e43E7ee15B1bc9B41306d71B998C39daD` on Ethereum is NOT canonical.** It is an abandoned via-IR build. Do not index or reference it.
- **Shape's deployment diverges from the others.** See §2.1.
- The deploy block is the lower bound for `eth_getLogs` scans. Scanning from 0 wastes requests and, on rationed public RPCs, will fail.

### 2.1 Chain variants

Every chain's contract is byte-identical logic to the canonical Ethereum build **except for two things**: the `_collectionImage` constant (per-chain branding, affects `contractURI()` only), and Shape.

**Shape (chain 360) is a real ABI divergence.** Shape's Gasback pays sequencer-fee revenue to a contract's `owner()`, and the canonical contract has a plain `owner` storage variable, so the Shape fork replaces the ownership pointer with a gasback recipient:

| Canonical (all chains except Shape) | Shape |
| --- | --- |
| `address public owner` (auto-getter) | `address public gasbackRecipient` + `function owner() external view returns (address)` |
| `transferOwnership(address newOwner)` | `setGasbackRecipient(address newRecipient)` |
| `event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)` | `event GasbackRecipientChanged(address indexed previousRecipient, address indexed newRecipient)` |
| `error NotContractOwner()`, `error ZeroOwner()` | `error NotGasbackRecipient()`, `error ZeroGasbackRecipient()` |
| `constructor()` — no args | `constructor(address initialGasbackRecipient)` |

`owner()` reads correctly on both. Everything else — minting, shards, slices, locking, delegation, royalties, all events, all reads — is identical. If you touch the ownership seat on Shape, use [`abi/ForeverLibraryV3.shape.json`](abi/ForeverLibraryV3.shape.json); calling `transferOwnership` through the canonical ABI against Shape will revert.

### 2.2 Tezos

A separate Forever Library FA2 contract (the SmartPy design V3 was ported from) lives at `KT1Tsqqffsf5H5KAWFasAiMajzqP71VqA9YD` on Tezos mainnet. It is a different contract family with a different entrypoint surface, and this guide does not cover it.

---

## 3. ABIs

This repository ships the ABIs, extracted from the Foundry build artifacts of the deployed source:

- [`abi/ForeverLibraryV3.json`](abi/ForeverLibraryV3.json) — canonical, correct for every chain except Shape
- [`abi/ForeverLibraryV3.shape.json`](abi/ForeverLibraryV3.shape.json) — the Shape variant (§2.1)
- [`abi/IExternalRenderer.json`](abi/IExternalRenderer.json) — the one-function interface a Renderer shard target implements

To regenerate from source instead of trusting the checked-in copy:

```bash
git clone https://github.com/foreverlibrary/forever-library.git
cd forever-library
forge build --contracts contracts/v3/flattened/ethereum
# ABI: out/ForeverLibraryV3_flat.sol/ForeverLibraryV3.json → .abi
```

Or pull it from any explorer where the contract is verified (§2).

For TypeScript with [viem](https://viem.sh), copy the ABI into a `.ts` file `as const` to get full type inference on function names and args:

```ts
export const foreverLibraryV3Abi = [ /* contents of abi/ForeverLibraryV3.json */ ] as const
```

### 3.1 External surface

**Writes anyone can call (this is the permissionless surface):**

| Function | Notes |
| --- | --- |
| `mint((uint8,bytes,string,address) shard, uint256 supply, uint96 royaltyBps)` | `supply` must be non-zero. Royalty receiver is set to `msg.sender`. `nonReentrant`. |
| `mintSoulbound((uint8,bytes,string,address) shard, uint96 royaltyBps)` | Supply fixed at 1, non-transferable forever (transfers *and* burns revert). `nonReentrant`. |
| `multicall(bytes[] data) returns (bytes[])` | OZ `Multicall`, self-delegatecall. Preserves `msg.sender`, so each batched call keeps its own authorization. Grants atomicity only, never new capability. |

**Writes gated to the token's creator or delegate:**

| Function | Who |
| --- | --- |
| `appendShard(uint256 tokenId, (uint8,bytes,string,address) shard)` | creator or delegate, until locked |
| `editShard(uint256 tokenId, uint256 shardIndex, (uint8,bytes,string,address) shard)` | creator (any shard) or delegate (only shards they appended); within that shard's 24h window |
| `appendSlice(uint256 tokenId, uint256 shardIndex, bytes data)` | same rule as `editShard`; `Onchain` shards only |
| `selectShard(uint256 tokenId, uint256 shardIndex)` | creator or delegate, until locked. Never window-gated. |
| `lockShards(uint256 tokenId, (uint256,bytes32,uint256,uint256) g)` | creator only. Irreversible. |
| `setDelegate(uint256 tokenId, address newDelegate)` | creator only, until locked |
| `setDelegatesBatch(uint256[] tokenIds, address[] delegates)` | creator only, per token |
| `updateTokenRoyalty(uint256 tokenId, address receiver, uint96 royaltyBps)` | creator only; works **after** lock too |

**Reads:**

| Function | Returns |
| --- | --- |
| `uri(uint256 tokenId)` | `string` — the selected shard, resolved |
| `shardURI(uint256 tokenId, uint256 shardIndex)` | `string` — *any* shard, resolved |
| `readShardBytes(uint256 tokenId, uint256 shardIndex)` | `bytes` — raw stored JSON of an `Onchain` shard, no base64 wrapper. Reverts `NotOnchainShard` otherwise. |
| `getShard(uint256 tokenId, uint256 shardIndex)` | `Shard` struct — see §6.1 |
| `getShardRange(uint256 tokenId, uint256 from, uint256 to)` | `Shard[]` over `[from, to)` |
| `shardCount(uint256 tokenId)` | `uint256`, includes shard 0 |
| `selectedShardIndex(uint256 tokenId)` | `uint256` |
| `revisionOf(uint256 tokenId)` | `uint256` — monotonic; bumped by append/edit/slice/select |
| `isLocked(uint256 tokenId)` | `bool` |
| `delegateOf(uint256 tokenId)` | `address` |
| `shardEditTimeRemaining(uint256 tokenId, uint256 shardIndex)` | `uint256` seconds; `0` once locked or closed |
| `getMintData(uint256 tokenId)` | `(address creator, bool soulbound, uint256 supply)` |
| `totalSupply(uint256 tokenId)` | `uint256` — fixed at mint |
| `isSoulbound(uint256 tokenId)` | `bool` |
| `totalTokenTypes()` | `uint256` — ids run `1..totalTokenTypes()` |
| `contractURI()` | `string` — collection-level data URI |
| `DEPLOYER()` | `address` — immutable |
| `owner()` | `address` — see below |
| `VERSION()`, `name()`, `symbol()`, `SHARD_EDIT_WINDOW()`, `MAX_SLICE_BYTES()` | constants: `"3.0.0"`, `"Forever Library V3"`, `"FLV3"`, `86400`, `24575` |

Plus the standard ERC-1155 (`balanceOf`, `balanceOfBatch`, `setApprovalForAll`, `isApprovedForAll`, `safeTransferFrom`, `safeBatchTransferFrom`, `supportsInterface`) and ERC-2981 (`royaltyInfo`) surface. `supportsInterface` additionally reports `0x8da5cb5b` (ERC-5313).

**⚠ NOT for integrators — do not wire these into a UI:**

- `transferOwnership(address)` (Shape: `setGasbackRecipient(address)`) — rotates the marketplace-facing ownership pointer. It carries **zero on-chain authority**: nothing in the contract gates on `owner()` except this function itself. But the off-chain seat is real — marketplaces resolve collection-profile admin and marketplace-level royalty routing through `owner()`, and on an open-mint shared contract that seat spans *every* creator's tokens, not just the holder's. It is also irreversible in the direction of any address you can't sign for. Leave it alone.

There is deliberately **no** pause, upgrade, withdraw, burn-admin, or metadata-override function. If you're looking for one, it doesn't exist.

---

## 4. Metadata standard

An `Onchain` shard stores **the complete token-metadata JSON as opaque bytes**. The contract never synthesizes, escapes, or validates JSON — `uri()` base64-wraps exactly the bytes you gave it into `data:application/json;base64,…`. The schema below is therefore a *convention*, enforced by producers and readers, not by the chain. Nothing stops you writing different JSON; everything downstream that reads Forever Library expects this shape, and it is exactly what the Forever Library app produces.

The schema is OpenSea/ERC-1155 canon (`name`, `description`, `image`, `animation_url`, `attributes`) extended with TZIP-21 vocabulary (`rights`, `date`, `contentRating`, `creators`, `formats`) and the V1 `image_backup` / `animation_backup` convention.

### 4.1 Fields

Key order is stable and deliberate: `name`, `description`, `image`, `image_backup`, `animation_url`, `animation_backup`, `external_url`, `rights`, `date`, `contentRating`, `creators`, `attributes`, `formats`. Empty fields are **omitted**, never emitted as `""` or `null`.

| Key | Type | Meaning |
| --- | --- | --- |
| `name` | `string` | Required, non-empty. Numbered editions append ` #n/N`. |
| `description` | `string` | Optional. |
| `image` | `string` | URI: `ipfs://`, `ar://`, `https://`, or inline `data:`. |
| `image_backup` | `string` | Second retrieval road for the same bytes (V1 convention, typically an `ipfs://` CID). |
| `animation_url` | `string` | The work, when it isn't a still image. |
| `animation_backup` | `string` | As `image_backup`. |
| `external_url` | `string` | Canonical web page for the work. |
| `rights` | `string` | Rights statement as **prose**, not a URL (TZIP-21 `rights`). Mirrored as a `License` attribute. |
| `date` | `string` | ISO 8601 — when the work was **made**. Distinct from the mint timestamp, which the chain proves independently. |
| `contentRating` | `string` | `"mature"` only, when flagged. Omitted otherwise. |
| `creators` | `string[]` | Wallet addresses, minter first, deduped case-insensitively. Well-formed `0x…40` only. A **declaration**, not a proof — the chain only proves `msg.sender`. |
| `attributes` | `{trait_type, value}[]` | See order below. Numeric-looking values are emitted as JSON numbers. |
| `formats` | `object[]` | One entry per representation, carrying fixity. See §4.2. |

**Attribute order** (provenance stamps first, creator's own traits last): credit attributes (`Artist`, or a custom role per creator) → `Media Type` → `Minting Address` → `Minting Tool` → `Edition` → `License` → custom traits.

`Minting Address` is the objective fact the chain proves. The `Artist` / `creators[]` entries are the creators' claim. Keep that distinction when you display them.

### 4.2 `formats[]`

Per-entry keys, in order: `uri`, `role`, `fileName`, `mimeType`, `fileSize`, `hash`, `dimensions`, `duration`, `formatRegistry`. Entry order is `work`, `source`, `proof`, `cover`, then mirrors.

- `role` is `"proof"` | `"source"` | `"cover"`. The plain access/work entry carries **no** role. Records minted before 2026-07-28 spell `source` as `"master"` — accept both, forever.
- **Single-copy invariant:** if a representation is an inline `data:` URI, its entry is `uri`-less, so those bytes appear exactly once in the record. The one exception is `role: "proof"`, whose `data:` URI *is* the payload.
- Mirrors carry the same `hash` (and same `role`) as the entry they mirror. Pair them by hash.
- Only probed facts are emitted. A fact that can't be verified is omitted, never guessed.

### 4.3 Worked example

This is what the Forever Library app produces for a numbered edition with a co-creator, an Arweave-hosted audio work, and an IPFS mirror. Shown pretty-printed for reading:

```json
{
  "name": "Kestrel #3/10",
  "description": "Field recording, Skomer, October 2025.",
  "image": "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi",
  "image_backup": "ipfs://bafybeic26wjhjrbiclt7hzhtgqmrxmqwq6gy4vjqhcbvmzbdrbz2xzxwbi",
  "animation_url": "ar://P6PdBRLnUOAjNBUvNqPbCLmvHOaJPBBGpJPZTQMzUJ0",
  "animation_backup": "ipfs://bafybeihq2xvzqxg4ub5xzq2ihkzljpqjqmhqdmhfqz5vqbqxqzqjqzqzqa",
  "external_url": "https://foreverlibrary.xyz/token/1/1042",
  "rights": "CC BY-NC 4.0",
  "date": "2025-10-14",
  "creators": [
    "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    "0x1111111111111111111111111111111111111111"
  ],
  "attributes": [
    { "trait_type": "Artist", "value": "Studio Nouveau" },
    { "trait_type": "Field Recordist", "value": "Ada" },
    { "trait_type": "Media Type", "value": "Audio" },
    { "trait_type": "Minting Address", "value": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" },
    { "trait_type": "Minting Tool", "value": "Forever Library V3" },
    { "trait_type": "Edition", "value": "3 of 10" },
    { "trait_type": "License", "value": "CC BY-NC 4.0" },
    { "trait_type": "Location", "value": "Skomer" },
    { "trait_type": "Duration", "value": 193 }
  ],
  "formats": [
    {
      "uri": "ar://P6PdBRLnUOAjNBUvNqPbCLmvHOaJPBBGpJPZTQMzUJ0",
      "fileName": "kestrel-03.wav",
      "mimeType": "audio/wav",
      "fileSize": 34062444,
      "hash": "sha256:9f2c1d0e6b5a4938271605f4e3d2c1b0a9f8e7d6c5b4a39281706f5e4d3c2b1a",
      "duration": 193
    },
    {
      "uri": "ipfs://bafybeihq2xvzqxg4ub5xzq2ihkzljpqjqmhqdmhfqz5vqbqxqzqjqzqzqa",
      "mimeType": "audio/wav",
      "fileSize": 34062444,
      "hash": "sha256:9f2c1d0e6b5a4938271605f4e3d2c1b0a9f8e7d6c5b4a39281706f5e4d3c2b1a",
      "duration": 193
    }
  ]
}
```

### 4.4 The serialization rule that will bite you

**The exact byte string you store is what gets hashed.** `metadataHash` for an `Onchain` shard is `keccak256` over those bytes — not over a canonicalization, not over a re-parse. If you compose the JSON, store it, then later re-serialize from a parsed object to verify, key order or whitespace differences will produce a different hash and your verification will fail against a perfectly good token.

Carry the composed string verbatim. Emit compact `JSON.stringify` output (no whitespace) and thread that exact string through hashing, slicing, resume checkpoints, and verification.

---

## 5. Minting from your own app

Examples use [viem](https://viem.sh). They are plain TypeScript — no framework required. `foreverLibraryV3Abi` is the ABI from [`abi/ForeverLibraryV3.json`](abi/ForeverLibraryV3.json), imported `as const` (§3).

### 5.1 Setup

```ts
import {
  createPublicClient, createWalletClient, custom, http,
  parseEventLogs, toHex, zeroAddress, keccak256, concat, hexToBytes,
  type Hex,
} from 'viem'
import { mainnet } from 'viem/chains'
import { foreverLibraryV3Abi } from './abi/ForeverLibraryV3'

const FL = '0xbfF70A12896b6cc6902DA43bad4725B0cdA62A43' as const  // Ethereum
const chain = mainnet

const publicClient = createPublicClient({ chain, transport: http() })
const walletClient = createWalletClient({ chain, transport: custom(window.ethereum!) })

const [account] = await walletClient.requestAddresses()

// ShardKind, mirroring the contract enum
const Onchain = 0, Pointer = 1, Renderer = 2
```

Chain check before anything else — the same address exists on four chains, and on one of them it's a different contract (§2):

```ts
const walletChainId = await walletClient.getChainId()
if (walletChainId !== chain.id) {
  await walletClient.switchChain({ id: chain.id })
}
```

### 5.2 Prepare metadata

```ts
// Compose your record and KEEP THE STRING (see §4.4).
const json = JSON.stringify({
  name: 'Kestrel #3/10',
  description: 'Field recording, Skomer, October 2025.',
  image: 'ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi',
  attributes: [
    { trait_type: 'Minting Address', value: account },
    { trait_type: 'Minting Tool', value: 'my-app' },
  ],
})

const bytes = new TextEncoder().encode(json)
const MAX_SLICE_BYTES = 24_575        // EIP-170 minus the STOP prefix
```

### 5.3 Mint — fully onchain, single transaction

Works when `bytes.length <= 24575`.

```ts
const shard = {
  kind: Onchain,
  data: toHex(bytes),
  pointerURI: '',
  renderer: zeroAddress,
} as const

// Simulate first: catches every revert before the user sees a signature prompt.
const { request } = await publicClient.simulateContract({
  account,
  address: FL,
  abi: foreverLibraryV3Abi,
  functionName: 'mint',
  args: [shard, 10n, 1000n],      // supply 10, royalty 1000 bps = 10%
})

const hash = await walletClient.writeContract(request)
const receipt = await publicClient.waitForTransactionReceipt({ hash })

// NEVER predict the token id — read it from the event.
const [minted] = parseEventLogs({
  abi: foreverLibraryV3Abi,
  eventName: 'TokenMinted',
  logs: receipt.logs,
})
const tokenId = minted.args.tokenId
```

`royaltyBps` is capped at `10000` by the contract (`InvalidRoyalty` above that). The royalty receiver is set to `msg.sender` at mint; change it later with `updateTokenRoyalty`.

Exactly one payload field must match `kind`, or the call reverts `InvalidShardInput`. For `Onchain`: `data` set, `pointerURI` empty, `renderer` zero.

### 5.4 Mint — pointer

```ts
const shard = {
  kind: Pointer,
  data: '0x',
  pointerURI: 'ipfs://bafkreialbumcidgoeshere',
  renderer: zeroAddress,
} as const
```

Pointer URIs are uncapped in length — gas is the only limit. Any scheme works (`ipfs://`, `ar://`, `https://`, `data:`); the contract validates presence only.

### 5.5 Mint — renderer

```ts
const shard = {
  kind: Renderer,
  data: '0x',
  pointerURI: '',
  renderer: '0xYourRendererContract',
} as const
```

The target must implement `IExternalRenderer`:

```solidity
interface IExternalRenderer {
    function uri(uint256 tokenId) external view returns (string memory);
}
```

At bind time the contract probes it: the address must have code, must not be the FL contract itself, and must answer `uri(tokenId)` with a well-formed, non-empty ABI-encoded string **in that transaction**. Failures revert `RendererNotContract`, `RendererProbeFailed`, or `RendererReturnedEmpty`.

One structural limit worth knowing: a *composite* renderer that reads its own token's shards cannot be shard 0. At mint-probe time the token exists with zero shards, so the probe reverts. Mint a static shard 0 first, then `appendShard` the composite and `selectShard` it.

### 5.6 Mint — larger than one transaction

Mint with the first slice, then `appendSlice` the rest **in order**, within shard 0's 24-hour window. The window runs from the shard's creation and is **not** extended by slices.

```ts
function planSlices(bytes: Uint8Array, size = MAX_SLICE_BYTES): Uint8Array[] {
  const out: Uint8Array[] = []
  for (let off = 0; off < bytes.length; off += size) {
    out.push(bytes.subarray(off, Math.min(off + size, bytes.length)))
  }
  return out
}

const slices = planSlices(bytes)

// 1. Mint with slice 0.
const { request } = await publicClient.simulateContract({
  account, address: FL, abi: foreverLibraryV3Abi, functionName: 'mint',
  args: [
    { kind: Onchain, data: toHex(slices[0]), pointerURI: '', renderer: zeroAddress },
    1n, 1000n,
  ],
})
const receipt = await publicClient.waitForTransactionReceipt({
  hash: await walletClient.writeContract(request),
})
const tokenId = parseEventLogs({
  abi: foreverLibraryV3Abi, eventName: 'TokenMinted', logs: receipt.logs,
})[0].args.tokenId

// 2. Append the remainder, in order, to shard 0.
for (let i = 1; i < slices.length; i++) {
  const sim = await publicClient.simulateContract({
    account, address: FL, abi: foreverLibraryV3Abi, functionName: 'appendSlice',
    args: [tokenId, 0n, toHex(slices[i])],
  })
  await publicClient.waitForTransactionReceipt({
    hash: await walletClient.writeContract(sim.request),
  })
}
```

**Checkpoint the transaction hash the moment the wallet returns it**, before waiting for the receipt. A reload mid-confirmation otherwise leaves you unable to tell a landed mint from a dropped one, and re-minting duplicates the token. `SliceAppended` carries `totalBytes`, so an interrupted upload can resume by diffing against what's already on-chain.

### 5.7 The metadataHash scheme

You need this to verify your own writes and to verify anyone else's.

| Shard kind | `metadataHash` |
| --- | --- |
| `Pointer` | `keccak256(bytes(pointerURI))` |
| `Onchain`, single slice | `keccak256(data)` |
| `Onchain`, multi-slice | rolling: `h₀ = keccak256(slice₀)`, then `hᵢ = keccak256(hᵢ₋₁ ‖ sliceᵢ)` |
| `Renderer` | `keccak256(abi.encodePacked(renderer))` — the **address**, never the output |
| after `editShard` | chain resets to `keccak256(newData)` |

```ts
function rollingHash(slices: readonly Uint8Array[]): Hex {
  let h = keccak256(slices[0])
  for (let i = 1; i < slices.length; i++) {
    h = keccak256(concat([hexToBytes(h), slices[i]]))
  }
  return h
}
```

Slice boundaries are part of the hash. Re-slicing the same bytes differently yields a different hash.

### 5.8 Batching with `multicall`

The contract inherits OZ `Multicall`. It self-delegatecalls, so `msg.sender` is preserved and every batched call keeps its own authorization — the batch grants **atomicity only, never new capability**.

```ts
import { encodeFunctionData } from 'viem'

const calls = [
  encodeFunctionData({
    abi: foreverLibraryV3Abi, functionName: 'appendShard',
    args: [tokenId, { kind: Pointer, data: '0x', pointerURI: 'ar://…', renderer: zeroAddress }],
  }),
  encodeFunctionData({
    abi: foreverLibraryV3Abi, functionName: 'selectShard', args: [tokenId, 1n],
  }),
]

const { request } = await publicClient.simulateContract({
  account, address: FL, abi: foreverLibraryV3Abi, functionName: 'multicall', args: [calls],
})
```

Read resulting shard indices from the receipt's `ShardAppended` events. **Never predict them** — a concurrent append makes any pre-read `shardCount` stale.

### 5.9 Numbered editions

The contract has **no native edition concept**. A "series" is N independent 1/1 tokens, minted as N `mint(shard, 1, royaltyBps)` calls inside one `multicall`:

```ts
const calls = editionJsons.map((json) =>
  encodeFunctionData({
    abi: foreverLibraryV3Abi,
    functionName: 'mint',
    args: [
      { kind: Onchain, data: toHex(new TextEncoder().encode(json)), pointerURI: '', renderer: zeroAddress },
      1n, 1000n,
    ],
  }),
)
```

Each edition's record is byte-identical except the `name` suffix (` #n/N`) and the `Edition` attribute (`"n of N"`). Editions relate to each other **only** through that metadata convention — nothing on-chain links them. Read all ids from the receipt's `TokenMinted` logs.

Two practical constraints: every edition must fit a single-slice mint (sliced-large works can't batch atomically, since each would need its own slice sequence against ids that don't exist yet), and EIP-7825 caps a single transaction at 2²⁴ = 16,777,216 gas, so large sets need chunking — batches of ~25 light editions are robust.

### 5.10 Locking

Read the revision immediately before locking and pin it. `expectedRevision` is the strongest guard — it catches edits to non-selected archival shards that the other three would miss.

```ts
const [selected, revision, count] = await Promise.all([
  publicClient.readContract({ address: FL, abi: foreverLibraryV3Abi, functionName: 'selectedShardIndex', args: [tokenId] }),
  publicClient.readContract({ address: FL, abi: foreverLibraryV3Abi, functionName: 'revisionOf', args: [tokenId] }),
  publicClient.readContract({ address: FL, abi: foreverLibraryV3Abi, functionName: 'shardCount', args: [tokenId] }),
])
const shard = await publicClient.readContract({
  address: FL, abi: foreverLibraryV3Abi, functionName: 'getShard', args: [tokenId, selected],
})

const { request } = await publicClient.simulateContract({
  account, address: FL, abi: foreverLibraryV3Abi, functionName: 'lockShards',
  args: [tokenId, {
    expectedSelected: selected,
    expectedHash: shard.metadataHash,
    expectedShardCount: count,
    expectedRevision: revision,
  }],
})
```

Mismatches revert with a precise reason: `UnexpectedShardCount`, `UnexpectedRevision`, `UnexpectedSelectedShard`, `UnexpectedMetadataHash` — checked in that order.

**Lock is permanent and irreversible.** It freezes shards and delegation. It does **not** freeze royalties — `updateTokenRoyalty` still works after lock.

If the token has a live delegate, revoke first: a delegate can bump `revision` every block and grief a revision-pinned lock indefinitely. `setDelegate(tokenId, address(0))` does not itself bump revision, so the safe order is revoke → read `revisionOf` → lock.

---

## 6. Reading the Library

### 6.1 The `Shard` struct

`getShard` / `getShardRange` return:

```solidity
struct Shard {
    address   addedBy;       // provenance: never rewritten, not even by edits
    uint64    timestamp;     // provenance: append time (mint time for shard 0)
    uint8     kind;          // 0 Onchain | 1 Pointer | 2 Renderer
    uint64    blockNumber;   // provenance
    uint128   totalBytes;    // Onchain only
    bytes32   metadataHash;
    string    pointerURI;    // Pointer only
    address[] chunks;        // Onchain only — SSTORE2 data-contract addresses
    address   renderer;      // Renderer only
}
```

`addedBy`, `timestamp` and `blockNumber` are written once at append and never changed — an `editShard` rewrites content and hash but leaves provenance intact.

### 6.2 Three read tiers

Shard size is uncapped, but RPC providers cap `eth_call` gas. Treat the tiers as fallback, not prediction — catch each and demote. Measured ceilings from the contract repo's gas study:

| Tier | Call | Ceiling |
| --- | --- | --- |
| 1 | `uri()` / `shardURI()` | ~300 KB at a 30M cap (~450 KB at 50M). This is what marketplaces call. |
| 2 | `readShardBytes()` | ~1.05 MB at 30M, ~1.4 MB at 50M. Skips base64. |
| 3 | `eth_getCode` per chunk address | No limit. Pure RPC reads, no execution. |

Tier 3 is the one that always works:

```ts
const shard = await publicClient.readContract({
  address: FL, abi: foreverLibraryV3Abi, functionName: 'getShard', args: [tokenId, shardIndex],
})

const codes = await Promise.all(
  shard.chunks.map((address) => publicClient.getCode({ address })),
)
// Each chunk's runtime code is 0x00 (STOP) + data. Strip the prefix.
const slices = codes.map((code) => hexToBytes(code!).slice(1))

const total = slices.reduce((n, s) => n + s.length, 0)
const out = new Uint8Array(total)
let off = 0
for (const s of slices) { out.set(s, off); off += s.length }

const json = new TextDecoder().decode(out)
```

Chunks are 1:1 with the slices that were appended, so `rollingHash(slices)` from §5.7 replays directly over chunk contents and must equal `shard.metadataHash`. That is a complete end-to-end integrity proof requiring nothing but an RPC node.

### 6.3 Events

All of these carry `tokenId` as the first indexed argument (except `TokenMinted`, where `creator` is first).

```solidity
event TokenMinted(
    address indexed creator,
    uint256 indexed tokenId,
    uint8 kind,                  // ShardKind of shard 0
    bytes32 metadataHash,
    uint256 supply,
    bool soulbound
);

event TokenSoulbound(uint256 indexed tokenId, address indexed creator);

event ShardAppended(
    uint256 indexed tokenId,
    uint256 indexed shardIndex,
    uint8 kind,
    bytes32 metadataHash,
    address indexed by
);

event ShardEdited(
    uint256 indexed tokenId,
    uint256 indexed shardIndex,
    uint8 kind,
    bytes32 metadataHash,
    address indexed by
);

event SliceAppended(
    uint256 indexed tokenId,
    uint256 indexed shardIndex,
    address indexed by,
    uint256 totalBytes,          // cumulative — lets an upload resume
    bytes32 newHash              // rolling-hash checkpoint
);

event ShardSelected(uint256 indexed tokenId, uint256 indexed shardIndex, address indexed by);

event ShardsLocked(uint256 indexed tokenId, address indexed by);

event DelegateSet(
    uint256 indexed tokenId,
    address indexed previousDelegate,
    address indexed newDelegate,
    address by
);

event RoyaltyUpdated(uint256 indexed tokenId, address indexed receiver, uint96 royaltyBps);

event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
// Shape only:
// event GasbackRecipientChanged(address indexed previousRecipient, address indexed newRecipient);
```

Plus standard ERC-1155 `TransferSingle`, `TransferBatch`, `ApprovalForAll`, `URI`.

**Two things that will trip up an indexer:**

1. **`URI` is emitted for `Pointer` shards only.** For `Onchain` shards the derived data URI can be megabytes, and log data at 8 gas/byte makes emitting it prohibitive. React to `ShardSelected` / `ShardEdited` (both carry `metadataHash`) and call `uri()` yourself.
2. **All mint events precede the ERC-1155 `TransferSingle`.** `_mint`'s receiver callback hands control to the creator, who may re-enter — so `TokenMinted`, `TokenSoulbound` and any `URI` event are emitted first, guaranteeing no shard event can land ahead of `TokenMinted` for the same token.

Watching for new work:

```ts
publicClient.watchContractEvent({
  address: FL,
  abi: foreverLibraryV3Abi,
  eventName: 'TokenMinted',
  onLogs: (logs) => {
    for (const log of logs) {
      const { creator, tokenId, kind, metadataHash, supply, soulbound } = log.args
      // …
    }
  },
})
```

Historical scans: bound `fromBlock` by the deploy block from §2. Public RPCs ration `eth_getLogs` aggressively (Cloudflare's mainnet endpoint caps ranges at 8 blocks; Alchemy's free tier at 10), so chunk the walk — try the full span once, fall back to ~10k-block chunks walking backward from the head, bounded below by the deploy block.

### 6.4 Querying provenance

Everything you need is on-chain. For one token:

- **Who made it, and when.** `getMintData(tokenId).creator` and shard 0's `timestamp` / `blockNumber` from `getShard(tokenId, 0)`. Shard 0 is written at mint, so its provenance *is* the mint provenance.
- **Full history.** Fetch `TokenMinted`, `TokenSoulbound`, `ShardAppended`, `ShardEdited`, `SliceAppended`, `ShardSelected`, `ShardsLocked`, `DelegateSet`, `RoyaltyUpdated` filtered by `tokenId`, then merge and sort by `(blockNumber, logIndex)`. That is the complete mutation history — `revisionOf` counts exactly these state changes.
- **Who touched which shard.** `getShardRange(tokenId, 0, shardCount)` gives per-shard `addedBy` / `timestamp` / `blockNumber`, unaffected by later edits.
- **Whether it's final.** `isLocked(tokenId)`, or the presence of `ShardsLocked`.
- **Parallel versions.** Non-selected shards persist forever. `shardCount` > 1 means the token carries redundant or alternative metadata; resolve any of them with `shardURI(tokenId, i)`, independent of which is selected.
- **What each version commits to.** Compare your locally computed hash against `getShard(...).metadataHash` using §5.7. Note what each kind actually commits to: an `Onchain` hash commits to the stored bytes; a `Pointer` hash commits to the URI string, *not* the content at the other end; a `Renderer` hash commits to the address, *not* its output.

Enumerate the whole collection with `totalTokenTypes()` — ids run `1..n` contiguously.

### 6.5 Run your own indexer

Nothing above needs us. The events, the deploy blocks, the ABIs, and the tier-3 chunk reassembly are all in this document; the only external dependency is an RPC endpoint for the chain you care about. The Forever Library site runs the same logic client-side, and it holds no privileged position — there is no private API, no signing service, no allowlist, and no data we have that you can't read. If our indexer, gateway, or site goes away, everything in §6 still works.

---

## 7. Guarantees & non-guarantees

**Permanent and permissionless — the contract:**

- Anyone can mint. No allowlist, no fee, no gate, and no address can prevent it.
- No pause, no upgrade, no proxy, no admin override of any token, shard, lock, delegation, or royalty. These functions do not exist.
- The contract is entirely non-payable. `receive()` and `fallback()` revert `EtherNotAccepted`.
- Supply is fixed at mint. There is no mint-more and no burn.
- `Onchain` shard bytes are deployed as immutable data-contracts. There is no `SELFDESTRUCT` path, and post-Dencun none could remove code anyway. Those bytes persist as long as the chain does.
- Shards are append-only. Nothing can delete one.
- `lockShards` is irreversible. Nothing unlocks a token.
- Soulbound is irreversible and total — transfers *and* burns revert.
- Provenance (`creator`, per-shard `addedBy` / `timestamp` / `blockNumber`) is written once and never rewritten, including by edits.
- `DEPLOYER` is `immutable`.

**Deliberately mutable — by the creator only:**

- Shard content, within that shard's 24h window (`editShard`, `appendSlice`).
- Which shard is served (`selectShard`) — never window-gated, available until lock.
- New shards (`appendShard`) — until lock.
- Delegation (`setDelegate`) — until lock.
- Royalty receiver and bps (`updateTokenRoyalty`) — **forever, including after lock.** Lock finality covers metadata shards only; royalty is commercial configuration, not part of the preserved artifact.

**Not guaranteed by the contract, no matter what any UI implies:**

- **`Pointer` shards.** The hash commits to the URI string. Whether anything answers at that URI is somebody else's problem — `ipfs://` content is self-verifying via its CID but only while someone pins it; `https://` content is neither pinned nor verified.
- **`Renderer` shards.** The hash commits to the *address*. That contract's code and output can change at any time — upgradeable proxy, EIP-7702 delegation, metamorphic CREATE2 — **including after lock**. A renderer is a creator-chosen live view. Lock freezes the selection and the address, never the rendered output.
- **Permanence is a per-shard creator choice, not a contract guarantee.** Only an `Onchain` shard is truly permanent. Shard 0 may be *any* kind, so a token can be pointer-only or renderer-only with no static fallback. The `kind` field is how you tell; show it to your users.
- **Anything the metadata JSON claims.** The chain proves `msg.sender`. It does not verify `creators[]`, `Artist` attributes, `rights`, `date`, `hash` values in `formats[]`, or any other declaration in the record.

**Convenience tooling — ours, replaceable, not part of the guarantee:**

- The Forever Library website is one client among any number. It has no privileged access.
- Hosted IPFS pinning, the Arweave lane, gateway lists, and any indexer we run are conveniences layered on top. Every one can disappear without affecting a single token.
- This repository's ABI copies are build artifacts. The contract source is authoritative.
- The metadata schema in §4 is a producer/reader convention, not enforced on-chain.

---

## 8. Security notes

**Wrong chain.** `0x230da0D2E34Ef4a5F7c0A842b3cd9BDd6C0B0F2F` is Forever Library V3 on Arbitrum, Shape, and Robinhood — and a *previous-generation* Forever Library ERC-1155 with a different ABI on MegaETH. Always pair an address with a chain ID, verify the wallet's chain before simulating, and never reuse a token id across chains — ids are per-contract and unrelated between deployments. Also confirm you're not pointed at `0xE76abb5e43E7ee15B1bc9B41306d71B998C39daD` (abandoned Ethereum build).

**Assuming our frontend is the only path.** It isn't, and your integration shouldn't behave as if it is. Tokens minted by other tools are equally valid; tokens minted by ours carry no privilege. `Minting Tool` is a self-reported attribute — never treat it as authentication. Anyone can mint anything, including a record that impersonates another artist: `creators[]` and `Artist` attributes are *claims*. Only `getMintData(tokenId).creator` and per-shard `addedBy` are proved by the chain. If you display attribution, show the proved fact alongside the claimed one.

**Unverified metadata.** Always recompute the hash (§5.7) and compare against `getShard(...).metadataHash`. And be precise with users about what verified means for each kind: onchain bytes verified end-to-end; pointer URI verified but its content not; renderer address verified but its output live and mutable. Don't render a green check that means three different things.

**Re-serializing before hashing.** Covered in §4.4 and worth repeating: hash the bytes you actually stored, not a round-trip through `JSON.parse`/`JSON.stringify`.

**Predicting ids or shard indices.** Both are assigned by the contract under concurrency. Read `tokenId` from `TokenMinted` and `shardIndex` from `ShardAppended`, always from the receipt. A pre-read `shardCount` is stale the moment someone else's append lands in the same block.

**Duplicate mints on reload.** Checkpoint the transaction hash as soon as the wallet returns it and before awaiting the receipt. On resume, probe that hash first — a landed mint must be recovered, not re-sent. Clearing a checkpoint while its transaction is still in the mempool is how you mint the same work twice.

**Gas limits.** Set the gas limit explicitly (estimate plus your own headroom). Left implicit, wallets pad estimates themselves — MetaMask by 1.5× — which pushes batches past EIP-7825's 16,777,216 per-transaction cap and gets them rejected at broadcast. MegaETH is the exception in the other direction: its ~24× gas schedule puts ordinary mints past 2²⁴, which it does not enforce, so clamping there starves a mint mid-`CREATE`.

**Always simulate before signing.** `simulateContract` catches every revert for free, pre-signature, and the contract's custom errors map to precise causes.

**On-chain consumers of `uri()` must bound returndata.** If your *contract* reads `uri()` on untrusted tokens, a gas cap alone is not enough: a hostile renderer's huge returned string is copied and ABI-decoded in *your* frame, outside the sub-call's gas cap, at quadratic memory cost. Use a low-level `staticcall` with both a gas cap **and** a `returndatasize` check before `returndatacopy`. EOA and `eth_call` readers are unaffected.

**Broken renderers revert honestly.** There is no try/catch and no fallback — by design, so a broken renderer never serves stale or wrong content. Handle the revert in your reader (`RendererReturnedEmpty`, or an arbitrary revert from the renderer itself) rather than treating it as a missing token. Pre-lock, the creator's remedy is to append a replacement shard and re-select; `selectShard` is never window-gated. Post-lock there is no remedy — a locked renderer-only token whose renderer breaks is unrecoverable.

**Delegation is a 24-hour trust grant, not a reversible one.** Shards are append-only and undeletable, and the creator's override to edit a shard expires at *that shard's* +24h boundary. A shard a delegate appends becomes permanent once its window closes: revoking stops future appends but cannot remove what's already there. If you build delegation UI, monitor `ShardAppended` on delegated tokens in near-real-time, not just at lock time.

**The `owner()` seat is off-chain-real.** It carries zero on-chain authority, but marketplaces resolve collection-profile admin and marketplace-level royalty routing through it — and on an open-mint shared contract that spans *every* creator's tokens. Don't expose `transferOwnership` (or Shape's `setGasbackRecipient`) in an integrator UI.

**Size thresholds.** Past ~250 KB, marketplaces may fail to render the standard `uri()` call; past ~300 KB it likely exceeds public `eth_call` gas caps entirely. Content stays fully retrievable via tiers 2 and 3 — but warn users before they mint something no marketplace will display.

---

## Repository map

| What | Where |
| --- | --- |
| Canonical V3 source (all chains except Shape) | [`contracts/v3/ForeverLibraryV3.sol`](contracts/v3/ForeverLibraryV3.sol) |
| Shape variant source | [`contracts/v3/shape/ForeverLibraryV3.sol`](contracts/v3/shape/ForeverLibraryV3.sol) |
| Per-chain deployed (flattened) sources | [`contracts/v3/flattened/`](contracts/v3/flattened/) |
| sha256 checksums of the deployed sources | [`contracts/v3/DEPLOY_CHECKSUMS.txt`](contracts/v3/DEPLOY_CHECKSUMS.txt) |
| ABIs (canonical, Shape, renderer interface) | [`abi/`](abi/) |
| Previous-generation contracts | [`legacy/`](legacy/) |
| Chain marks (SVG) | [`assets/chain-marks/`](assets/chain-marks/) |

Questions, corrections, or something this guide gets wrong: open an issue on this repository.
