# Forever Library V3: architecture and security review brief

This brief describes the logic of Forever Library V3 for independent technical
review. It identifies the components that enforce permanence, the remaining
trust assumptions, known limitations, and areas where security feedback would
be most useful.

The primary scope is the canonical EVM artifact contract and the web
application. The Tezos artifact contract and the EVM and Tezos profile
registries are separate implementations. They are identified where they affect
system boundaries, but each requires its own code review.

This brief reflects the production web application at commit `a88ce6512668`
on 2026-08-30. The deployed contract source is the final authority on contract
behavior. Supporting references appear at the end.

## 1. Architecture and trust boundaries

Forever Library V3 has five principal components:

| Component | Role | Authority and dependency |
| --- | --- | --- |
| EVM artifact contracts | ERC-1155 tokens with ERC-2981 royalties and append-only metadata shards | Immutable contracts with no administrative token authority |
| Tezos artifact contracts | Parallel FA2 implementation with equivalent durability conventions | Separate SmartPy contracts and entrypoints |
| Profile registries | Mutable profile documents on MegaETH and Tezos | Separate contract family; profiles are not permanent artifact metadata |
| Web application | Authoring, storage, reading, rendering, and verification | Static and replaceable; it reads and writes chains directly from the browser |
| Serverless functions | Upload authorization, sponsored profile saves, and social cards | Operator-run conveniences with no authority over artifact contract state |

There is no application database. The artifact contracts do not depend on a
Forever Library API to read or verify their state.

Permanence depends on the shard type selected by the creator. An Onchain shard
stores its complete metadata bytes in contract-controlled code. A Pointer shard
stores a URI whose target remains externally hosted. A Renderer shard stores a
contract address whose output can change or fail. The contract permanently
preserves each shard and its provenance, but it cannot make external content or
renderer output permanent.

## 2. EVM artifact contract

### 2.1 Shards and token state

Each token has an append-only array of metadata shards. A shard has one of
three forms:

| Kind | Stored commitment | Main limitation |
| --- | --- | --- |
| `Onchain` | Complete metadata bytes, stored through SSTORE2 data contracts | Higher transaction cost and multiple signatures for large payloads |
| `Pointer` | URI string | The hash commits to the URI, not the referenced content or its availability |
| `Renderer` | Renderer contract address | The address is fixed, but its code or output may change or fail |

Shard 0 is created at mint. Creators and authorized delegates can append more
shards and select which shard `uri()` serves. Non-selected shards remain
readable through `shardURI(tokenId, index)`.

Each shard records the account that added it, its timestamp, block number,
kind, and metadata hash. These provenance fields do not change when shard
content is edited. The contract does not parse or normalize metadata JSON.
Byte order, whitespace, and slice boundaries therefore affect the stored hash.

Supply is fixed at mint. The contract has no burn or additional-mint path.
Soulbound tokens cannot be transferred or burned.

### 2.2 Write authority and finality

The relevant state transitions are:

- Minting is permissionless and non-payable. Royalty basis points are capped
  at 10,000, and the initial royalty receiver is the minter.
- A creator or delegate can append and select shards until the token is
  locked. Selection is not limited by the edit window.
- A creator can edit any shard during that shard's 24-hour edit window. A
  delegate can edit only a shard that delegate appended, within the same
  window. Onchain slices follow the same access rule.
- Only the creator can set delegates or lock the shard state.
- `lockShards` is irreversible. Its guard includes the expected selected
  shard, hash, shard count, and revision, so the transaction fails if the
  state changed after the creator read it.
- Locking freezes shard writes, selection, and delegation. The creator can
  still update royalties because royalties are not treated as artifact
  metadata.

Delegation is a trust grant. Revocation prevents future writes but cannot
remove an appended shard. A delegate can also delay a revision-pinned lock by
continuing to change the revision. The safe sequence is to revoke delegates,
read the current state, and then lock.

### 2.3 Integrity and reads

The metadata hash is defined by shard kind:

- Pointer: `keccak256(bytes(uri))`
- Onchain, one slice: `keccak256(data)`
- Onchain, multiple slices:
  `h[0] = keccak256(slice[0])`, then
  `h[i] = keccak256(h[i-1] || slice[i])`
- Renderer: `keccak256(abi.encodePacked(rendererAddress))`

Onchain slice data can be verified through an RPC node by reading each data
contract with `eth_getCode`, removing its one-byte prefix, replaying the
rolling hash, and comparing the result with `metadataHash`.

The application uses three read paths: `uri()` or `shardURI()`, raw shard
bytes, and data-contract reassembly. Batched reader contracts improve gallery
performance but do not become a trust source. Metadata still passes the
contract hash check before display. The token page's verification indicator
uses data-contract reassembly.

Renderer targets are probed when bound: the address must contain code, must
not be the artifact contract, and must return a non-empty string. Resolution
does not catch later renderer failures. A locked renderer-only token can
therefore become unreadable.

### 2.4 Other contract review notes

Mint functions use a reentrancy guard. Mint events are emitted before the
ERC-1155 receiver callback so a receiver cannot place another shard event
ahead of `TokenMinted` for the same token.

Canonical EVM deployments report version 3.0.0 and share the same logic apart
from collection-image constants and the documented Shape ownership-pointer
variation. Consumers must identify a deployment by chain ID and address.

## 3. Application security

### 3.1 Untrusted artwork

The application treats minted HTML as arbitrary code. Interactive works render
through a dedicated middle frame with `sandbox allow-scripts`. The nested
artwork document has an opaque origin, with no access to application cookies,
storage, navigation, or same-origin state.

The middle frame accepts commissioning data only from its direct parent. It
relays a small, source-checked message allowlist for readiness and capture.
The outer application cannot itself be framed. Production, development, and
browser tests use matching frame and content-security policies.

Zipped HTML projects are inspected for structure and bounded decompression,
then uploaded as IPFS directories. The original zip is retained as a source
representation but is never executed. Directory projects render in a
sandboxed cross-origin gateway frame.

### 3.2 Serverless functions

The static application uses three Vercel functions:

- **`/api/upload-token`** exchanges a recent wallet signature for a scoped
  Pinata upload credential. File bytes go directly from the browser to
  Pinata. The endpoint enforces a five-minute signature window and a 250 MB
  maximum. Folder uploads receive a one-use key with file-pinning permission
  only. Pinata credentials remain server-side. EIP-1271 upload signatures are
  not supported; affected wallets use the manual storage path.
- **`/api/relay-profile`** pays gas for an EIP-712-authorized profile update.
  The registry validates the signer, nonce, deadline, and expected document
  version. The endpoint accepts only the `profile` key, limits documents to
  64 KiB, and rejects deadlines more than one hour away. The relayer key can
  pay gas but cannot authorize a document change.
- **`/api/og`** renders social cards from attacker-controlled token metadata.
  Reads have byte and time limits. The endpoint rejects local and
  private-shaped hosts, IP literals, and dotless names; it rechecks each
  redirect target. SVG rasterization has pixel and node limits and does not
  resolve external images. Failures return a generic card. A remaining risk
  is that a public hostname may resolve to a private address because the
  endpoint does not resolve and pin DNS before fetching.

### 3.3 Storage, recovery, and operator services

Hosted IPFS uses a Forever Library Pinata account, so availability depends on
continued pinning or an independent copy. The user-paid Arweave path is signed
by the artist and does not place funds or a storage wallet under Forever
Library control. Fully onchain uploads place the metadata and work bytes in
data contracts indexed by the artifact contract. The application never sends
value to the artifact contract.

Mint and sliced-upload flows create local checkpoints before requesting a
signature. Reloaded sessions determine transaction status from chain data. An
RPC failure remains classified as pending because treating an uncertain
transaction as dropped could create a duplicate mint. A cross-tab lock reduces
the risk of concurrent mints from the same browser and wallet.

Generator previews can use a separate registrable domain with one random
subdomain per project. That deployment contains no wallet application, API
routes, secrets, or cookies. Preview documents cannot access external
networks, and unpublished worlds expire after 24 hours. This service supports
authoring and is not required to resolve a minted project.

## 4. Generative protocol

The generative protocol adds project and output conventions without changing
the artifact contracts. A generator is an HTML project that receives a
chain-derived 32-byte seed.

Seed derivation is fixed by `flv3-mintblock-v1`:

- EVM:
  `keccak256(abi.encodePacked(chainId, contract, tokenId, mintBlockHash))`
- Tezos:
  `keccak256("tezos:<network>:<contract>:<tokenId>:<blockHash>")`

The block hash prevents the minter from grinding transaction hashes before
broadcast. It does not provide unbiased randomness. An artist can mint, view
an output, discard it, and mint again. Public minting that requires stronger
randomness would need a different contract, such as a VRF or commit-reveal
design.

After confirmation, the application fetches the receipt again, derives the
seed, renders the output, and writes a metadata stamp. The stamp may use the
24-hour edit window or append and select a new shard later. It is applied to
the metadata read back from the chain so unrelated fields are preserved.

The stamped seed is a creator claim. Anyone can recompute it from the mint
receipt, but the EVM contract cannot verify an old block hash. The declared
maximum output count is also a creator promise enforced by the application,
not by the artifact contract.

The bundled `fl.js` seed script has no network dependency. Registration tests
scan for common nondeterministic inputs and compare two fresh renders of the
same seed. These tests usually warn rather than reject because source analysis
and image comparison cannot prove general determinism.

## 5. Guarantees and limitations

| Property | Basis | Limitation |
| --- | --- | --- |
| Onchain shard bytes and provenance | Artifact contract state and code | Chain availability remains an external dependency |
| Append-only history and irreversible locks | Artifact contract access control | Royalties remain creator-editable after lock |
| Pointer identity | Hash of the stored URI | Does not prove target content or availability |
| Renderer identity | Hash of the renderer address | Does not fix code, configuration, or output |
| Generative seed | Published derivation from permanent chain facts | The stamp is creator-attested and the randomness is biasable |
| Names, creators, rights, dates, features, and fixity claims | Creator-authored metadata | The contract does not verify these statements |
| Application verification | Open-source readers and contract hash checks | Depends on an available chain RPC |
| Hosted IPFS availability | Forever Library's Pinata account and other pins | Content can become unavailable if no copy remains pinned |

The web application, serverless functions, social-card renderer, and preview
world are replaceable. The chains, RPC providers, indexers, gateways, Pinata,
ArDrive Turbo, and wallet infrastructure remain third-party dependencies.

The Tezos artifact contract and both profile registries have different storage
and authority models. Findings about the EVM artifact contract should not be
assumed to apply to them.

## 6. Suggested review focus

Reviewer attention would be most useful in these areas:

1. EVM contract access control across creators, delegates, edit windows,
   selection, and locking.
2. Rolling-hash and SSTORE2 accounting, renderer return-data bounds, and
   failure behavior.
3. `/api/og` SSRF controls, redirect handling, and SVG resource limits.
4. Wallet-signature authorization in the upload and profile-relay endpoints,
   including Tezos verification and scoped folder credentials.
5. Frame message validation and origin assumptions for hostile HTML projects.
6. Checkpoint and generative-stamp recovery, especially any state
   classification that could duplicate a permanent mint.

The Tezos artifact contract and profile registries warrant separate reviews.

## References

- [Contract integration reference](./INTEGRATION.md), including deployments,
  ABI, shard hashes, events, guarantees, and security notes
- Generative protocol specification in the production web application
  repository (`docs/generative.md`)
- Isolated-origin preview architecture in the production web application
  repository (`docs/isolated-origin-world.md`)
- Production web application source and tests at commit `a88ce6512668`
- Verified source for each deployed contract in
  [`contracts/v3/flattened/`](./contracts/v3/flattened/)
