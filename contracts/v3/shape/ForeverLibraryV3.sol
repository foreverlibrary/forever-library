// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ============================================================================
// ForeverLibraryV3 — the deployed 3.0.0 source, SHAPE VARIANT (readable
// copy). Live on Shape (chain 360); the canonical form for every other
// chain is contracts/v3/ForeverLibraryV3.sol, and this file diverges from
// it only in the gasback-recipient seat (see the divergence header below).
// Addresses and verification: INTEGRATION.md §2. Full Foundry test suite:
// test/ (run by CI). Review history and audit status: SECURITY.md — not
// audited by an external professional firm. Design decisions were reviewed
// and resolved: the original five carry `RESOLVED:` comments at their
// sites; later decisions are documented at their sites throughout.
//
// NOTE on the explorer-verified source: the byte-exact deployed source
// lives in contracts/v3/flattened/shape/ (sha256-pinned; never edited).
// Its comment header predates deployment ("final pre-deployment source ...
// NOT yet deployed") and is frozen forever — verification requires the
// source to hash-match the metadata sealed into the on-chain bytecode, so
// that text can never be corrected on the explorers. Comments compile to
// nothing; only this readable copy can carry the current header.
//
// V3 unifies the V1 minting contract and the external shard renderer into a
// single contract, porting the architecture proven by Forever Library Tezos
// v2 (forever_library_fa2.py) back to the EVM:
//
//   - Shard 0 IS the mint metadata. One shard model, one 24h window rule,
//     applied uniformly. No renderer pointer, no toggle, no blank-URI
//     intermediate states, no materialization — the V1 M1–M3 failure class
//     is structurally absent.
//   - Onchain shards store the COMPLETE token-metadata JSON as opaque bytes.
//     The contract never synthesizes JSON (no escaping, no attribute
//     building, no EthFS). metadataHash is a hash of exactly what is stored.
//   - Byte storage is internal SSTORE2: each slice is deployed as an
//     immutable data-contract (~200 gas/byte vs ~640 for storage slots);
//     a shard holds an ordered array of chunk addresses. Self-contained:
//     no external registry dependency.
//   - Slice assembly (`appendSlice`) lets shard content grow across
//     transactions, with the Tezos rolling-hash scheme:
//     hash = keccak(prevHash ++ slice), replayable off-chain.
//   - A per-token `revision` counter is bumped by every shard-state
//     mutation; `lockShards` pins it (plus selected/hash/count) so the
//     creator locks exactly the state they reviewed.
//   - Renderer shards (decision 8) restore V1's per-token external
//     renderer capability as an ordinary shard kind: window-governed
//     binding, direct staticcall at read time, honest revert on breakage
//     (recovery = append a replacement and re-select), set-time probe.
//     Any shard MAY be a Renderer, including shard 0 (V1 blank-URI parity):
//     the contract does not force a static genesis shard. Permanence is a
//     creator choice — an Onchain shard is truly permanent; a Pointer or
//     Renderer shard 0 may reference perishable/external content, an
//     accepted user action (a renderer-only token has no static fallback).
//   - Multicall (decision 9): OZ `Multicall` lets a frontend batch several
//     calls into one atomic transaction (e.g. appendShard + selectShard, or
//     editShard + selectShard) from ANY wallet. It self-delegatecalls, so
//     `msg.sender` is preserved and every batched call keeps its own
//     authorization — multicall grants NO new capability, only atomicity.
//     Safe here specifically: the contract is fully non-payable (no
//     msg.value double-spend surface) and the delegatecall target is always
//     `address(this)` (never caller-supplied). nonReentrant on mints is not
//     bypassable (sequential self-delegatecalls share the guard slot).
//
// SHAPE-ONLY DIVERGENCE (2026-07-09, sanctioned): this variant adds a
// gasbackRecipient — Shape's Gasback pays 80% of sequencer fees to a
// contract's owner(), and the canonical contract is ownerless, which would
// strand that revenue. The recipient is exposed via an Ownable-compatible
// owner() getter and can rotate ITSELF (recipient-only, never zero). It
// grants ZERO ON-CHAIN powers over tokens, shards, locks, delegation, or
// royalties — nothing else in the contract reads it. OFF-CHAIN (cold review
// 2026-07-09, L-1): marketplaces resolve collection-admin via owner(), and
// that seat can typically edit the collection page AND marketplace-level
// royalty routing for the WHOLE collection — so the recipient wallet must
// be a governed, trusted address (e.g. a multisig), never a casual one.
// All other logic remains byte-identical to canonical fl-eth-v3.
//
// Carried from V1 unchanged: open permissionless minting, fixed supply at
// mint (single field — V1's maxSupply/currentSupply pair removed), soulbound
// via the _update hook, ERC-2981, ether rejection, no admin/pause/upgrade.
// ============================================================================

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

/// @notice Interface a Renderer shard's target must implement — identical
///         shape to V1's IExternalRenderer, so renderer authors carry over
///         unchanged. Called via staticcall from `uri()` / `shardURI()`.
interface IExternalRenderer {
    function uri(uint256 tokenId) external view returns (string memory);
}

contract ForeverLibraryV3 is ERC1155, ERC2981, ReentrancyGuard, Multicall {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    string public constant VERSION = "3.0.0";

    /// @notice Collection name/symbol. ERC-1155 defines no native
    ///         name/symbol (unlike ERC-721), so explorers fall back to
    ///         manual labels without these getters — the V1 1155
    ///         deployments needed exactly that on Etherscan. Lowercase
    ///         identifiers are required for the conventional ABI surface.
    string public constant name = "Forever Library V3";
    string public constant symbol = "FLV3";

    /// @notice Per-shard mutation window, measured from the shard's append
    ///         (mint, for shard 0). Applies uniformly to edits and slices.
    ///         Boundary convention: the window is OPEN while
    ///         `block.timestamp < timestamp + SHARD_EDIT_WINDOW` and CLOSED
    ///         at exactly +24h. `shardEditTimeRemaining` uses the same
    ///         boundary. (Resolves the 1-second discrepancy noted between
    ///         the Tezos contract and the V1 renderer.)
    uint256 public constant SHARD_EDIT_WINDOW = 24 hours;

    // NOTE: Pointer URIs are deliberately UNCAPPED in length (the V1
    // MAX_URI_LENGTH = 65535 bound was removed 2026-07-08). A Pointer is a
    // storage string written atomically in one transaction, so per-
    // transaction GAS is its natural and self-limiting ceiling — an oversize
    // pointer is self-harm the minter pays for, bounded by the block gas
    // limit and previewed by the wallet before signing. A fixed constant on
    // an immutable contract can only lag the movable gas ceiling; capping is
    // neither a security nor a standard-NFT measure (OZ's URIStorage doesn't
    // cap either). Only presence (non-empty) is validated, not length.

    /// @notice Max bytes per slice. EIP-170 caps deployed code at 24,576
    ///         bytes; one byte is spent on the STOP prefix. (This one IS a
    ///         hard limit: Onchain slices become deployed contract code.)
    uint256 public constant MAX_SLICE_BYTES = 24_575;

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Shard content modes. Onchain/Pointer mirror the Tezos
    ///         variant; Renderer is EVM-only (decision 8, V1 parity).
    ///         Onchain = complete metadata JSON stored in chunk contracts.
    ///         Pointer = a URI string to off-chain JSON (ipfs://, ar://,
    ///         https://, or a data: URI the caller pre-built).
    ///         Renderer = a contract implementing IExternalRenderer,
    ///         resolved by live staticcall at read time. May be ANY shard,
    ///         including shard 0 (decision 8 revised) — a renderer-only
    ///         token has no static fallback, the creator's accepted choice.
    enum ShardKind {
        Onchain,
        Pointer,
        Renderer
    }

    /// @notice Caller-submitted shard payload (Solidity's stand-in for the
    ///         Tezos `payload_t` variant). Exactly one of `data` /
    ///         `pointerURI` / `renderer` must be set, matching `kind`.
    struct ShardInput {
        ShardKind kind;
        bytes data;        // Onchain: first (or only) slice of the JSON
        string pointerURI; // Pointer: the URI
        address renderer;  // Renderer: the IExternalRenderer contract
    }

    /// @dev Stored shard record. Field order packs the fixed fields into
    ///      three slots:
    ///        slot 1: addedBy (20) + timestamp (8) + kind (1)
    ///        slot 2: blockNumber (8) + totalBytes (16)
    ///        slot 3: metadataHash
    ///      Provenance (`addedBy`, `timestamp`, `blockNumber`) is set at
    ///      append and never rewritten, including by edits (V1 semantics).
    ///
    ///      metadataHash semantics (Tezos parity for the static kinds):
    ///        - Pointer: keccak256(bytes(pointerURI)).
    ///        - Onchain, single slice: keccak256(json).
    ///        - Onchain, multi-slice: rolling — keccak(prevHash ++ slice),
    ///          replayable off-chain from keccak(firstSlice).
    ///        - An edit resets the chain to keccak256(newData).
    ///        - Renderer: keccak256(abi.encodePacked(renderer)) — commits
    ///          the bound ADDRESS (the presentation delegation), not output
    ///          bytes and not code. A renderer's code/output can change
    ///          externally at any time (upgradeable proxy, EIP-7702
    ///          delegation, metamorphic CREATE2), including after lock. This
    ///          is an ACCEPTED PRIMITIVE: a renderer is a creator-chosen live
    ///          view, so lock freezes the selection and the address, never
    ///          the rendered output. Permanence is a per-shard creator
    ///          choice, not a contract guarantee — only an Onchain shard is
    ///          truly permanent; `kind` lets any consumer see whether a
    ///          shard (including shard 0) is a stored artifact, a Pointer, or
    ///          a dynamic renderer view.
    struct Shard {
        address addedBy;
        uint64 timestamp;
        ShardKind kind;
        uint64 blockNumber;
        uint128 totalBytes;   // Onchain only; supports resumable uploads
        bytes32 metadataHash;
        string pointerURI;    // Pointer only
        address[] chunks;     // Onchain only; SSTORE2 data-contract addrs
        address renderer;     // Renderer only; IExternalRenderer target
    }

    /// @notice Per-token mint record. Timestamp/block live in shard 0
    ///         (identical at mint), so they are not duplicated here.
    struct MintData {
        address creator;
        bool soulbound;
        uint256 supply; // fixed forever at mint; no burn, no mint-more
    }

    /// @notice Expected-state bundle for `lockShards` (Tezos parity).
    ///         `expectedRevision` is the strongest guard — it pins ALL shard
    ///         state including edits to non-selected archival shards, which
    ///         the other three alone would not catch. The redundant guards
    ///         are kept for precise revert reasons in the frontend.
    struct LockGuard {
        uint256 expectedSelected;
        bytes32 expectedHash;
        uint256 expectedShardCount;
        uint256 expectedRevision;
    }

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    uint256 private _nextTokenId = 1; // V1 EVM convention (Tezos starts at 0)

    mapping(uint256 => MintData) private _mintData;

    /// @dev Uniform shard storage; array index == external shard index.
    ///      Shard 0 is written at mint. No separate shard-0 machinery.
    mapping(uint256 => Shard[]) private _shards;

    mapping(uint256 => uint256) private _selectedShard; // defaults to 0
    mapping(uint256 => bool) private _locked;
    mapping(uint256 => address) private _delegate;

    /// @dev Monotonic per-token counter, bumped by every shard-state
    ///      mutation (append / edit / slice / select).
    mapping(uint256 => uint256) private _revision;

    string private _collectionName;
    string private _collectionDescription;
    string private _collectionImage;

    /// @notice The wallet that deployed this contract — an immutable
    ///         provenance fact (V1 parity; decision 11). Never an admin.
    ///         (On Shape, the marketplace owner() seat is the gasback
    ///         recipient below, not the deployer.)
    address public immutable DEPLOYER;

    /// @notice SHAPE DIVERGENCE — where Shape's Gasback should pay. Exposed
    ///         as owner() purely so the Gasback registry resolves the NFT
    ///         recipient; carries NO authority inside this contract.
    address public gasbackRecipient;

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev RESOLVED: V1's event-only `title`/`mediaType` params are
    ///      dropped (Tezos parity and EVM norms — the metadata JSON is the
    ///      single authoritative source for name and media typing; nothing
    ///      on-chain validated that the event copies matched it). Indexers
    ///      read titles from the JSON: `readShardBytes` for onchain shards,
    ///      or the pointer URI (typically a data: URI for FL tokens).
    event TokenMinted(
        address indexed creator,
        uint256 indexed tokenId,
        ShardKind kind,
        bytes32 metadataHash,
        uint256 supply,
        bool soulbound
    );

    event ShardAppended(
        uint256 indexed tokenId,
        uint256 indexed shardIndex,
        ShardKind kind,
        bytes32 metadataHash,
        address indexed by
    );

    event ShardEdited(
        uint256 indexed tokenId,
        uint256 indexed shardIndex,
        ShardKind kind,
        bytes32 metadataHash,
        address indexed by
    );

    /// @notice Emitted per slice; `totalBytes` lets an interrupted upload
    ///         resume by diffing against bytes already on-chain (Tezos
    ///         parity), and `newHash` checkpoints the rolling hash.
    event SliceAppended(
        uint256 indexed tokenId,
        uint256 indexed shardIndex,
        address indexed by,
        uint256 totalBytes,
        bytes32 newHash
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
    event TokenSoulbound(uint256 indexed tokenId, address indexed creator);
    event GasbackRecipientChanged(address indexed previousRecipient, address indexed newRecipient);

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error TokenNotFound();
    error NotTokenCreator();
    error NotAuthorized();
    error NotOriginalAppender();
    error ShardsAreLocked();
    error ShardEditWindowClosed();
    error ShardOutOfRange();
    error InvalidRange();
    error InvalidShardInput();     // kind/field mismatch in ShardInput
    error EmptyPayload();
    error SliceTooLarge();
    error NotOnchainShard();
    error RendererNotContract();
    error RendererProbeFailed();
    error RendererReturnedEmpty();
    error ZeroSupply();
    error InvalidRoyalty();
    error SelfDelegation();
    error LengthMismatch();
    error UnexpectedSelectedShard();
    error UnexpectedMetadataHash();
    error UnexpectedShardCount();
    error UnexpectedRevision();
    error ChunkWriteFailed();
    error TokenIsSoulbound();
    error EtherNotAccepted();
    error NotGasbackRecipient();
    error ZeroGasbackRecipient();

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address initialGasbackRecipient) ERC1155("") {
        if (initialGasbackRecipient == address(0)) revert ZeroGasbackRecipient();
        DEPLOYER = msg.sender;
        gasbackRecipient = initialGasbackRecipient;
        // Review I-1: emit at construction so pure event-sourced indexers
        // can reconstruct the recipient from genesis.
        emit GasbackRecipientChanged(address(0), initialGasbackRecipient);

        _collectionName = "Forever Library V3";
        _collectionDescription =
            "A fully immutable, non-upgradeable NFT contract with open minting, permanent metadata, parallel storage backups, fully onchain file uploads, soulbound tokens, and per-token external renderers.";
        // Collection icon: FL mark (#ffffff) on Shape field (#111111) — per-chain
        // branding only; contract logic is byte-identical to canonical fl-eth-v3.
        _collectionImage = "data:image/svg+xml;base64,PHN2ZyB2ZXJzaW9uPSIxLjIiIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyIgdmlld0JveD0iMCAwIDEwMjQgMTAyNCIgd2lkdGg9IjEwMjQiIGhlaWdodD0iMTAyNCI+Cgk8dGl0bGU+Rm9yZXZlciBMaWJyYXJ5IFYzIFNoYXBlPC90aXRsZT4KCTxyZWN0IHdpZHRoPSIxMDI0IiBoZWlnaHQ9IjEwMjQiIGZpbGw9IiMxMTExMTEiLz4KCTxnIGlkPSJsb2dvIj4KCQk8cGF0aCBmaWxsPSIjZmZmZmZmIiBkPSJtNjU5LjMyIDIzNS40MWMtNC4wMy0xLjQ4LTIwLjQtNS40Ni0zOC4xMi00LjYtMTcuNDggMC44NS0zNi4xNSA1LjQxLTQ1LjU0IDkuNjItNDcuOTUgMjEuNTQtNzIuMjEgNTEuMzgtNzYuNjIgOTEuMDNsLTIyLjE5IDIwNC42N2MtMy40MSAyLjE2LTYuODQgNC4zMy0xMC4xNSA2LjQzLTMwLjc3IDE5LjQ0LTU3LjM0IDM2LjIzLTcxLjQgNDYuODQtNjQuMjggNTAuNDgtNjYuNjggODcuNTUtNzAuMjYgMTE4Ljc2LTguMzIgNzIuNjkgNTEuNDUgODQuMTEgNTYuNyA4NC45N3YwLjA4YzAuMjkgMC4wNCAwLjQ4IDAuMDUgMC43OCAwLjA5IDMzLjc3IDMuNzUgNjMuOTQtMTUuNjMgODcuODMtNDEuODggNS4yNC01LjE3IDEwLjU4LTEwLjg4IDE2LjAzLTE3LjQ0IDMxLjAzLTM3LjM5IDQzLjI1LTgzLjQzIDQ4LjQyLTExNi40NHYtMC4wMmMyLjQtMTUuMzIgMy4yOC0yNy44NCAzLjgzLTM1LjM1di0wLjAybDguNjYtODBxLTAuNDggMC4yMy0wLjk2IDAuNDYgMC40OC0wLjIzIDAuOTYtMC40NmwwLjAzLTAuMjFjMjMuMTctMTUuNDggNDQuMjgtMzAuNDcgNTkuMzEtNDMuMTUgOS41Ny02LjAyIDE1LjkzLTE1LjY5IDE3Ljg4LTIzLjc0IDMuMDktMTIuNzMtMC44Ni0yMi40Mi01LjgxLTI4LjM2LTYuNzMtOC4wNS0yOC41LTguMjktMjEuNzEgMTguMDMgNC4wNCAxNS42NS0xLjg0IDI4LjEtNi4xNiAzNC42OS0xMS45MSA5LjMtMjYuNDYgMTkuNTktNDIuMTggMzAuMjJsMTUuOTItMTQ2Ljk1YzIuNDctMjIuMyA3LjU5LTQ1LjA3IDE2LjMtNjQuMTkgNi4xMi0xMy40NCAyMy41My0zNy40OSA1Ni4xOC0zNy40OSAyNC42NiAwIDQyLjY1IDM0LjkgMzQuNDMgNTAuMzItMTIuNzkgMjMuOTkgOC40MyAyOC44NyAxNi44NiAyMi42MiA2LjItNC42IDEyLjQ3LTEzLjEgMTIuMy0yNi4xOS0wLjExLTkuNTctNy42LTM5LjkzLTQxLjMyLTUyLjM0em0tMjA0LjU1IDUwNC41MWMtMS42NiAxNi4xMi0yMi42OSAzMC45Ni0zNC4yOCAzNS44Mi0xMi4xMiA1LjA5LTM3LjA0IDUuMDMtMzUuNDEtOC42OSAxLjY0LTEzLjczIDE2Ljk4LTE1Ni42MiAxNi45OC0xNTYuNjIgMCAwIDEuNDMtOC42IDQuNjQtMTIuOTcgMi45NS00LjAxIDYuODItOS4zOCAxMy4wMS0xMy41IDE0LTkuMzIgMzIuMTEtMjAuNzcgNTIuMDctMzMuMzkgMS4yNC0wLjc5IDIuNTItMS41OSAzLjc5LTIuMzktMC4wMyAwLTE5LjEyIDE3NS42MS0yMC44IDE5MS43NHoiLz4KCTwvZz4KPC9zdmc+Cg==";
    }

    /*//////////////////////////////////////////////////////////////
                    SHAPE GASBACK (chain-specific divergence)
    //////////////////////////////////////////////////////////////*/

    /// @notice Ownable-compatible getter for Shape's Gasback system, which
    ///         resolves a registered contract's NFT recipient via owner().
    ///         This is NOT an admin: no function in this contract gates on
    ///         it except `setGasbackRecipient` below. SIDE EFFECT (review
    ///         L-1): marketplaces that read owner() for collection admin
    ///         will treat this wallet as the collection manager on Shape —
    ///         including marketplace-level royalty routing for the whole
    ///         collection. On-chain royaltyInfo() is untouched, but the
    ///         seat is real: govern this wallet accordingly.
    function owner() external view returns (address) {
        return gasbackRecipient;
    }

    /// @notice Rotate the gasback recipient. Only the CURRENT recipient may
    ///         rotate, and never to zero (a zeroed recipient could never be
    ///         recovered — no other party can set it). NOTE (review L-3):
    ///         zero is only the narrowest unrecoverable case — rotating to
    ///         ANY address you cannot sign for (typo, burn address, a
    ///         contract that cannot call this function) is equally
    ///         irreversible. Verify control of the new address first. Note: once the
    ///         Gasback NFT is minted, the claim right lives in that NFT and
    ///         moves by transferring it; this field matters at registration
    ///         time and for any registry re-reads of owner().
    function setGasbackRecipient(address newRecipient) external {
        if (msg.sender != gasbackRecipient) revert NotGasbackRecipient();
        if (newRecipient == address(0)) revert ZeroGasbackRecipient();
        address previous = gasbackRecipient;
        gasbackRecipient = newRecipient;
        emit GasbackRecipientChanged(previous, newRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                              AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    modifier tokenExists(uint256 tokenId) {
        if (_mintData[tokenId].creator == address(0)) revert TokenNotFound();
        _;
    }

    modifier notLocked(uint256 tokenId) {
        if (_locked[tokenId]) revert ShardsAreLocked();
        _;
    }

    modifier onlyTokenCreator(uint256 tokenId) {
        if (msg.sender != _mintData[tokenId].creator) revert NotTokenCreator();
        _;
    }

    modifier onlyCreatorOrDelegate(uint256 tokenId) {
        if (msg.sender != _mintData[tokenId].creator && msg.sender != _delegate[tokenId]) {
            revert NotAuthorized();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                MINTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint a token type with its full, fixed supply. `shard`
    ///         becomes shard 0 and the initially selected metadata.
    /// @dev    Shard 0's 24h edit window starts now, same as any shard.
    ///         Guard order (all entrypoints): existence → locked → auth →
    ///         range → window → payload validation.
    function mint(ShardInput calldata shard, uint256 supply, uint96 royaltyBps)
        external
        nonReentrant
    {
        if (supply == 0) revert ZeroSupply();
        _mintCore(shard, supply, false, royaltyBps);
    }

    /// @notice Mint a single non-transferable (soulbound) token.
    function mintSoulbound(ShardInput calldata shard, uint96 royaltyBps) external nonReentrant {
        _mintCore(shard, 1, true, royaltyBps);
    }

    function _mintCore(ShardInput calldata shard, uint256 supply, bool soulbound, uint96 royaltyBps)
        internal
        returns (uint256 tokenId)
    {
        if (royaltyBps > 10000) revert InvalidRoyalty();
        // RESOLVED (decision 8, revised): shard 0 may be ANY kind, including
        // Renderer — the contract does not force a static genesis shard.
        // Permanence is a creator choice, not an enforced guarantee: an
        // Onchain shard 0 is truly permanent, a Pointer commits only its URI
        // (the referenced document can perish), and a Renderer commits only
        // the address (output is a live external view). A renderer-only token
        // therefore has no static fallback — the same accepted class as an
        // unpinned Pointer. If Renderer, `_storeNewShard` probes it here.
        //
        // Mid-mint probe state (cold review 3, L-2): a shard-0 renderer is
        // probed while the token exists with ZERO shards (mintData written;
        // shard not yet pushed; royalty not yet set). A probe-time read of
        // shardCount returns 0, getShard/shardURI revert ShardOutOfRange,
        // and uri() Panics(0x32) on the empty array. Consequence: a
        // COMPOSITE renderer that reads its own token's shards cannot be
        // shard 0 at mint (its probe reverts) — mint static first, then
        // append + select the composite. Only the probed renderer can ever
        // observe this state (staticcall); no integrity impact.

        tokenId = _nextTokenId;
        unchecked {
            _nextTokenId++;
        }

        _mintData[tokenId] = MintData({creator: msg.sender, soulbound: soulbound, supply: supply});

        bytes32 h = _storeNewShard(tokenId, shard); // writes shard 0
        // _selectedShard defaults to 0; _revision starts at 0 (Tezos parity)

        _setTokenRoyalty(tokenId, msg.sender, royaltyBps);

        // All mint events are emitted BEFORE `_mint`: its ERC1155 receiver
        // callback hands control to the creator, who may reenter other
        // entrypoints (state is already consistent — only nonReentrant
        // mints are guarded). Emitting first guarantees no shard event can
        // reach the log ahead of TokenMinted for the same token.
        emit TokenMinted(msg.sender, tokenId, shard.kind, h, supply, soulbound);
        if (soulbound) emit TokenSoulbound(tokenId, msg.sender);
        _emitURIIfCheap(tokenId, 0);

        _mint(msg.sender, tokenId, supply, "");
    }

    /*//////////////////////////////////////////////////////////////
                            SHARD MUTATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Append a new shard (either kind). Creator or delegate,
    ///         until locked. The shard gets its own 24h edit window.
    function appendShard(uint256 tokenId, ShardInput calldata shard)
        external
        tokenExists(tokenId)
        notLocked(tokenId)
        onlyCreatorOrDelegate(tokenId)
    {
        if (_shards[tokenId].length >= type(uint64).max) revert ShardOutOfRange(); // unreachable sanity
        bytes32 h = _storeNewShard(tokenId, shard);
        uint256 idx = _shards[tokenId].length - 1;
        _bumpRevision(tokenId);
        emit ShardAppended(tokenId, idx, shard.kind, h, msg.sender);
    }

    /// @notice Replace a shard's content within its 24h window. The creator
    ///         may edit any shard (including shard 0 and delegate-appended
    ///         shards); a delegate may edit only shards they appended, and
    ///         only while still the current delegate. A shard may change
    ///         kind; switching Onchain → Pointer abandons its chunks.
    /// @dev    Resets the hash chain to keccak256(new content). Provenance
    ///         fields are preserved; the edit window is NOT extended.
    ///         Abandoned chunk contracts remain on-chain but unreferenced
    ///         (no EVM deletion analogue to the Tezos `del`; harmless).
    function editShard(uint256 tokenId, uint256 shardIndex, ShardInput calldata shard)
        external
        tokenExists(tokenId)
        notLocked(tokenId)
    {
        Shard storage s = _shardForEdit(tokenId, shardIndex);
        // Any shard, including shard 0, may change to any kind (decision 8
        // revised — no static-genesis constraint). A Renderer edit probes
        // the new address in the Renderer branch below.
        _validateInput(shard);

        if (shard.kind == ShardKind.Onchain) {
            delete s.chunks; // abandon prior chunks (if any)
            s.pointerURI = "";
            s.renderer = address(0);
            address chunk = _writeChunk(shard.data);
            s.chunks.push(chunk);
            s.totalBytes = uint128(shard.data.length);
            s.metadataHash = keccak256(shard.data);
        } else if (shard.kind == ShardKind.Pointer) {
            delete s.chunks;
            s.totalBytes = 0;
            s.renderer = address(0);
            s.pointerURI = shard.pointerURI;
            s.metadataHash = keccak256(bytes(shard.pointerURI));
        } else {
            _checkRenderer(tokenId, shard.renderer);
            delete s.chunks;
            s.totalBytes = 0;
            s.pointerURI = "";
            s.renderer = shard.renderer;
            s.metadataHash = keccak256(abi.encodePacked(shard.renderer));
        }
        s.kind = shard.kind;

        _bumpRevision(tokenId);
        emit ShardEdited(tokenId, shardIndex, shard.kind, s.metadataHash, msg.sender);
        if (_selectedShard[tokenId] == shardIndex) _emitURIIfCheap(tokenId, shardIndex);
    }

    /// @notice Extend an onchain shard's stored JSON with another slice.
    ///         Lets content grow past per-transaction limits: mint or append
    ///         the shard with its first slice, then call this with each
    ///         remaining slice in order.
    /// @dev    Authorization and the 24h window mirror `editShard`; the
    ///         window runs from the shard's creation and is NOT extended by
    ///         slices, so an upload must complete within the original
    ///         window. metadataHash becomes the rolling
    ///         keccak(prevHash ++ slice). Each slice bumps `revision`, so a
    ///         `lockShards` pinned to a reviewed revision cannot freeze a
    ///         half-uploaded shard.
    function appendSlice(uint256 tokenId, uint256 shardIndex, bytes calldata data)
        external
        tokenExists(tokenId)
        notLocked(tokenId)
    {
        Shard storage s = _shardForEdit(tokenId, shardIndex);
        if (s.kind != ShardKind.Onchain) revert NotOnchainShard();
        if (data.length == 0) revert EmptyPayload();
        if (data.length > MAX_SLICE_BYTES) revert SliceTooLarge();

        address chunk = _writeChunk(data);
        s.chunks.push(chunk);
        s.totalBytes += uint128(data.length);
        s.metadataHash = keccak256(abi.encodePacked(s.metadataHash, data));

        _bumpRevision(tokenId);
        emit SliceAppended(tokenId, shardIndex, msg.sender, s.totalBytes, s.metadataHash);
        // No URI event: the canonical URI for an onchain shard is derived at
        // read time; emitting multi-KB payloads per slice would be log-cost
        // prohibitive.
    }

    /// @notice Set which shard `uri()` serves. Creator or delegate, until
    ///         locked. Non-selected shards persist (URI-sharding redundancy).
    function selectShard(uint256 tokenId, uint256 shardIndex)
        external
        tokenExists(tokenId)
        notLocked(tokenId)
        onlyCreatorOrDelegate(tokenId)
    {
        if (shardIndex >= _shards[tokenId].length) revert ShardOutOfRange();
        _selectedShard[tokenId] = shardIndex;
        _bumpRevision(tokenId);
        emit ShardSelected(tokenId, shardIndex, msg.sender);
        _emitURIIfCheap(tokenId, shardIndex);
    }

    /*//////////////////////////////////////////////////////////////
                                LOCKING
    //////////////////////////////////////////////////////////////*/

    /// @notice Permanently and irreversibly lock a token (creator only).
    ///         All four expected-state guards must match current state;
    ///         read `revisionOf` immediately before calling and pass it as
    ///         `expectedRevision` to pin the exact reviewed state.
    /// @dev    No materialization step exists in V3 — shard 0 already lives
    ///         in this contract's storage — so lock is a pure flag write.
    ///         Locking also freezes delegation. Royalties remain
    ///         creator-mutable after lock (see `updateTokenRoyalty`).
    ///
    ///         L-1 — PROCEDURE against an adversarial delegate: a live
    ///         delegate can bump `revision` every block (append / select /
    ///         edit-or-slice their own shard) and grief a revision-pinned
    ///         lock into reverting indefinitely. Revoking the delegate does
    ///         NOT bump revision, so the safe sequence is:
    ///           1. `setDelegate(tokenId, address(0))`
    ///           2. read `revisionOf(tokenId)`
    ///           3. `lockShards(tokenId, g)` with that revision
    ///         Use a private mempool for step 1 if delegate compromise is
    ///         suspected, so the revocation itself cannot be front-run.
    function lockShards(uint256 tokenId, LockGuard calldata g)
        external
        tokenExists(tokenId)
        notLocked(tokenId)
        onlyTokenCreator(tokenId)
    {
        if (_shards[tokenId].length != g.expectedShardCount) revert UnexpectedShardCount();
        if (_revision[tokenId] != g.expectedRevision) revert UnexpectedRevision();
        if (_selectedShard[tokenId] != g.expectedSelected) revert UnexpectedSelectedShard();
        if (_shards[tokenId][g.expectedSelected].metadataHash != g.expectedHash) {
            revert UnexpectedMetadataHash();
        }
        _locked[tokenId] = true;
        emit ShardsLocked(tokenId, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                               DELEGATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set or revoke (address(0)) the delegate for a token.
    ///         Creator only, until locked. A delegate may append, slice and
    ///         edit their own shards, and select — but not lock, not change
    ///         delegation, and not update royalties.
    /// @dev    L-A — delegation is a trust grant with a 24-hour response
    ///         window, NOT a fully reversible one. Shards are append-only and
    ///         undeletable, and the creator's override to edit a shard expires
    ///         at that shard's own +24h boundary. So a shard a delegate
    ///         appends becomes PERMANENT once its window closes: revoking the
    ///         delegate stops future appends but cannot remove or edit what
    ///         was already added (the creator can only select away from it and
    ///         lock). A compromised delegate key left unwatched for 24h can
    ///         therefore attach permanent unwanted content. Frontends should
    ///         monitor `ShardAppended` on delegated tokens in near-real-time,
    ///         not only at lock time.
    function setDelegate(uint256 tokenId, address newDelegate)
        external
        tokenExists(tokenId)
        notLocked(tokenId)
        onlyTokenCreator(tokenId)
    {
        _setDelegate(tokenId, newDelegate);
    }

    /// @dev The argument-shape check precedes the loop; per-token guards
    ///      then run in invariant order (existence → locked → auth).
    function setDelegatesBatch(uint256[] calldata tokenIds, address[] calldata delegates) external {
        if (tokenIds.length != delegates.length) revert LengthMismatch();
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (_mintData[tokenId].creator == address(0)) revert TokenNotFound();
            if (_locked[tokenId]) revert ShardsAreLocked();
            if (msg.sender != _mintData[tokenId].creator) revert NotTokenCreator();
            _setDelegate(tokenId, delegates[i]);
        }
    }

    /// @dev Callers enforce existence/locked/auth in invariant order;
    ///      only the payload check lives here.
    function _setDelegate(uint256 tokenId, address newDelegate) internal {
        if (newDelegate == msg.sender) revert SelfDelegation();
        address previous = _delegate[tokenId];
        _delegate[tokenId] = newDelegate;
        emit DelegateSet(tokenId, previous, newDelegate, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                                ROYALTIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Update the ERC-2981 royalty for a token: receiver AND bps.
    ///         Creator only.
    /// @dev    RESOLVED (decision 1, revised 2026-07-09): royalties remain
    ///         creator-mutable forever, independent of `lockShards` — lock
    ///         finality applies to metadata shards only; royalty is
    ///         commercial configuration, not part of the preserved artifact.
    ///         The receiver is a PARAMETER (it was pinned to the creator):
    ///         on an immutable contract the pin permanently bricked wallet
    ///         rotation, estates, and post-mint split retrofits, while its
    ///         only protection was the one-bad-signature phishing case —
    ///         full key compromise defeats the pin anyway (the attacker
    ///         controls the receiving wallet). Provenance (`creator`,
    ///         `addedBy`) is untouched by receiver changes. Zero receiver
    ///         reverts in OZ `_setTokenRoyalty`
    ///         (ERC2981InvalidTokenRoyaltyReceiver). Mint still defaults
    ///         the receiver to the creator. The Tezos contract instead
    ///         delegates royalties to the metadata JSON (TZIP-21); on the
    ///         EVM, ERC-2981 stays on-chain because marketplaces query it
    ///         directly. Frontends: display the current receiver
    ///         prominently and confirm receiver changes explicitly.
    function updateTokenRoyalty(uint256 tokenId, address receiver, uint96 royaltyBps)
        external
        tokenExists(tokenId)
        onlyTokenCreator(tokenId)
    {
        if (royaltyBps > 10000) revert InvalidRoyalty();
        _setTokenRoyalty(tokenId, receiver, royaltyBps);
        emit RoyaltyUpdated(tokenId, receiver, royaltyBps);
    }

    /*//////////////////////////////////////////////////////////////
                            METADATA / READS
    //////////////////////////////////////////////////////////////*/

    /// @notice The canonical token URI: the selected shard, resolved.
    ///         Pointer shards return their URI verbatim; onchain shards are
    ///         assembled from chunks and served as
    ///         `data:application/json;base64,...`.
    /// @dev    RESOLVED: shard size is deliberately UNCAPPED (Tezos parity;
    ///         only the creator/delegate pays to grow their own shard). The
    ///         read path is tiered instead. RPC providers cap eth_call gas
    ///         (commonly 25–50M) and memory expansion is quadratic.
    ///         Measured 2026-07-07 (test/GasMeasurement.t.sol):
    ///           tier 1: uri()            — ~300 KB at a 30M cap
    ///                                      (~450 KB at 50M)
    ///           tier 2: readShardBytes() — ~1.05 MB at 30M, ~1.4 MB at 50M
    ///           tier 3: eth_getCode per chunk address from getShard(),
    ///                   strip the 1-byte STOP prefix, concatenate, verify
    ///                   against the rolling metadataHash — pure RPC reads,
    ///                   no execution, no size limit. This is the EVM
    ///                   equivalent of Tezos tezos-storage: big_map reads.
    ///         Content is therefore always retrievable; oversize shards only
    ///         lose tier-1 marketplace rendering. Frontends should warn when
    ///         a shard grows past the tier-1 line.
    function uri(uint256 tokenId) public view override returns (string memory) {
        if (_mintData[tokenId].creator == address(0)) revert TokenNotFound();
        return _resolveShard(tokenId, _selectedShard[tokenId]);
    }

    /// @notice Resolve ANY shard (selected or not) to its URI — the
    ///         URI-sharding redundancy property. Equivalent of the Tezos
    ///         `get_shard_uri` view, except onchain shards return the full
    ///         data URI (the EVM has no `tezos-storage:` indirection).
    function shardURI(uint256 tokenId, uint256 shardIndex)
        external
        view
        tokenExists(tokenId)
        returns (string memory)
    {
        if (shardIndex >= _shards[tokenId].length) revert ShardOutOfRange();
        return _resolveShard(tokenId, shardIndex);
    }

    /// @notice Raw stored JSON bytes of an onchain shard (assembled across
    ///         slices), without data-URI wrapping. Reverts for pointer
    ///         shards. Equivalent of the Tezos `get_shard_metadata` view;
    ///         also the cheapest read path for indexers (skips Base64).
    function readShardBytes(uint256 tokenId, uint256 shardIndex)
        external
        view
        tokenExists(tokenId)
        returns (bytes memory)
    {
        if (shardIndex >= _shards[tokenId].length) revert ShardOutOfRange();
        Shard storage s = _shards[tokenId][shardIndex];
        if (s.kind != ShardKind.Onchain) revert NotOnchainShard();
        return _assembleChunks(s.chunks);
    }

    /// @notice Shard record by index (chunk addresses included; content via
    ///         `readShardBytes` / `shardURI`).
    function getShard(uint256 tokenId, uint256 shardIndex)
        external
        view
        tokenExists(tokenId)
        returns (Shard memory)
    {
        if (shardIndex >= _shards[tokenId].length) revert ShardOutOfRange();
        return _shards[tokenId][shardIndex];
    }

    /// @notice Paginated shard records `[from, to)`.
    function getShardRange(uint256 tokenId, uint256 from, uint256 to)
        external
        view
        tokenExists(tokenId)
        returns (Shard[] memory result)
    {
        uint256 total = _shards[tokenId].length;
        if (from >= to || to > total) revert InvalidRange();
        result = new Shard[](to - from);
        for (uint256 i = 0; i < result.length; ++i) {
            result[i] = _shards[tokenId][from + i];
        }
    }

    function shardCount(uint256 tokenId) external view tokenExists(tokenId) returns (uint256) {
        return _shards[tokenId].length; // includes shard 0
    }

    function selectedShardIndex(uint256 tokenId) external view tokenExists(tokenId) returns (uint256) {
        return _selectedShard[tokenId];
    }

    function isLocked(uint256 tokenId) external view tokenExists(tokenId) returns (bool) {
        return _locked[tokenId];
    }

    function delegateOf(uint256 tokenId) external view tokenExists(tokenId) returns (address) {
        return _delegate[tokenId];
    }

    /// @notice Read immediately before `lockShards`; pass as expectedRevision.
    function revisionOf(uint256 tokenId) external view tokenExists(tokenId) returns (uint256) {
        return _revision[tokenId];
    }

    function shardEditTimeRemaining(uint256 tokenId, uint256 shardIndex)
        external
        view
        tokenExists(tokenId)
        returns (uint256)
    {
        // Locked short-circuits before the range check, mirroring the
        // mutating entrypoints (locked precedes range there too), so
        // `0 ⇔ mutations rejected` holds for any index once locked.
        if (_locked[tokenId]) return 0;
        if (shardIndex >= _shards[tokenId].length) revert ShardOutOfRange();
        uint256 closesAt = uint256(_shards[tokenId][shardIndex].timestamp) + SHARD_EDIT_WINDOW;
        return block.timestamp >= closesAt ? 0 : closesAt - block.timestamp;
    }

    function getMintData(uint256 tokenId) external view tokenExists(tokenId) returns (MintData memory) {
        return _mintData[tokenId];
    }

    function totalSupply(uint256 tokenId) external view tokenExists(tokenId) returns (uint256) {
        return _mintData[tokenId].supply;
    }

    function isSoulbound(uint256 tokenId) external view tokenExists(tokenId) returns (bool) {
        return _mintData[tokenId].soulbound;
    }

    function totalTokenTypes() external view returns (uint256) {
        return _nextTokenId - 1;
    }

    function contractURI() public view returns (string memory) {
        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(
                    bytes(
                        abi.encodePacked(
                            '{"name":"', _collectionName,
                            '","description":"', _collectionDescription,
                            '","image":"', _collectionImage, '"}'
                        )
                    )
                )
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL: SHARD WRITES
    //////////////////////////////////////////////////////////////*/

    /// @dev Validates and stores a brand-new shard (mint shard 0 or append),
    ///      recording provenance from the current call context.
    function _storeNewShard(uint256 tokenId, ShardInput calldata input) internal returns (bytes32 h) {
        _validateInput(input);
        // L-6: probe the renderer BEFORE pushing the shard, so a re-entrant
        // read from the probed contract cannot observe a half-initialized
        // shard (inflated shardCount, zero renderer/hash). Probe needs only
        // the tokenId and address, so it is safe to run first.
        if (input.kind == ShardKind.Renderer) _checkRenderer(tokenId, input.renderer);

        Shard storage s = _shards[tokenId].push();
        s.addedBy = msg.sender;
        s.timestamp = uint64(block.timestamp);
        s.blockNumber = uint64(block.number);
        s.kind = input.kind;

        if (input.kind == ShardKind.Onchain) {
            address chunk = _writeChunk(input.data);
            s.chunks.push(chunk);
            s.totalBytes = uint128(input.data.length);
            h = keccak256(input.data);
        } else if (input.kind == ShardKind.Pointer) {
            s.pointerURI = input.pointerURI;
            h = keccak256(bytes(input.pointerURI));
        } else {
            s.renderer = input.renderer;
            h = keccak256(abi.encodePacked(input.renderer));
        }
        s.metadataHash = h;
    }

    /// @dev Exactly one payload field may be set, matching `kind`.
    function _validateInput(ShardInput calldata input) internal pure {
        if (input.kind == ShardKind.Onchain) {
            if (input.data.length == 0) revert EmptyPayload();
            if (input.data.length > MAX_SLICE_BYTES) revert SliceTooLarge();
            if (bytes(input.pointerURI).length != 0 || input.renderer != address(0)) {
                revert InvalidShardInput();
            }
        } else if (input.kind == ShardKind.Pointer) {
            // Presence only — pointer length is uncapped (gas is the limiter;
            // see the pointer-cap-removal note in CONSTANTS).
            if (bytes(input.pointerURI).length == 0) revert EmptyPayload();
            if (input.data.length != 0 || input.renderer != address(0)) revert InvalidShardInput();
        } else {
            if (input.renderer == address(0)) revert EmptyPayload();
            if (input.data.length != 0 || bytes(input.pointerURI).length != 0) {
                revert InvalidShardInput();
            }
        }
    }

    /// @dev Set-time sanity for a renderer binding (decision 8): must be a
    ///      deployed contract and must answer `uri(tokenId)` with a
    ///      non-empty string in this very transaction — catches the V1 M1
    ///      misconfiguration class (wrong/typo'd address, wrong contract)
    ///      at the moment of setting, and rejects blank output (the V1
    ///      blank-URI state). A probe cannot guarantee future behavior: a
    ///      later-broken renderer reverts at read time, and the remedy is
    ///      the sharding system itself — append a replacement, re-select.
    ///      Staticcall: a renderer attempting state changes fails here.
    /// @dev  L-7: the returned data is validated as a well-formed, non-empty
    ///       ABI-encoded string WITHOUT `abi.decode`, so a malformed return
    ///       yields `RendererProbeFailed` rather than an abi.decode Panic.
    ///       Canonical string layout: offset word (==0x20) + length word +
    ///       padded data.
    /// @dev  L-B: `address(this)` is rejected — a self-bound renderer would
    ///       pass the probe (it resolves the currently-selected static shard)
    ///       but, once selected, make `uri()` recurse into itself until it
    ///       exhausts gas. That is still a revert, but a gas-EXHAUSTING one
    ///       rather than the cheap honest revert elsewhere; a two-contract
    ///       renderer cycle cannot be prevented at bind time.
    ///       ON-CHAIN CONSUMERS of `uri()` (cold review 3, L-3): a gas-capped
    ///       sub-call alone is NOT sufficient against a hostile renderer —
    ///       a huge returned string is copied and ABI-decoded in the CALLER's
    ///       frame, outside the sub-call's gas cap (quadratic memory cost).
    ///       Contracts reading untrusted tokens must use a low-level
    ///       staticcall with BOTH a gas cap AND a returndata-size bound
    ///       (returndatasize check before returndatacopy). EOA/eth_call
    ///       readers are unaffected.
    function _checkRenderer(uint256 tokenId, address renderer) internal view {
        if (renderer.code.length == 0) revert RendererNotContract();
        if (renderer == address(this)) revert RendererProbeFailed();
        (bool ok, bytes memory ret) =
            renderer.staticcall(abi.encodeWithSelector(IExternalRenderer.uri.selector, tokenId));
        if (!ok || ret.length < 64) revert RendererProbeFailed();
        uint256 strOffset;
        uint256 strLen;
        assembly ("memory-safe") {
            strOffset := mload(add(ret, 0x20))
            strLen := mload(add(ret, 0x40))
        }
        // offset must be canonical (0x20); length non-zero and within buffer.
        // `ret.length - 64` cannot underflow (ret.length >= 64 above).
        if (strOffset != 0x20 || strLen == 0 || strLen > ret.length - 64) {
            revert RendererProbeFailed();
        }
    }

    /// @dev Resolves a shard for mutation (edit/slice), in invariant guard
    ///      order: token-level authorization (creator or current delegate;
    ///      strangers and revoked delegates get NotAuthorized) → range →
    ///      shard-level authorization (a delegate may touch only shards
    ///      they appended; the creator may touch any) → window. The
    ///      appender check is the one authorization component that must
    ///      follow the range check, since it reads the target shard.
    function _shardForEdit(uint256 tokenId, uint256 shardIndex) internal view returns (Shard storage) {
        address creator = _mintData[tokenId].creator;
        if (msg.sender != creator && msg.sender != _delegate[tokenId]) revert NotAuthorized();
        if (shardIndex >= _shards[tokenId].length) revert ShardOutOfRange();
        Shard storage s = _shards[tokenId][shardIndex];

        if (msg.sender != creator && msg.sender != s.addedBy) revert NotOriginalAppender();
        if (block.timestamp >= uint256(s.timestamp) + SHARD_EDIT_WINDOW) {
            revert ShardEditWindowClosed();
        }
        return s;
    }

    function _bumpRevision(uint256 tokenId) internal {
        unchecked {
            _revision[tokenId]++;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL: SSTORE2 CHUNKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploys `data` as an immutable data-contract (SSTORE2 pattern,
    ///      after solmate/0xSequence). Runtime code = 0x00 (STOP) prefix +
    ///      data, so the chunk can never execute meaningfully. ~200 gas/byte
    ///      vs ~640 for storage slots. Chunks are permanent: no SELFDESTRUCT
    ///      path exists, and post-Dencun none could remove code anyway —
    ///      the preservation property holds at the EVM level.
    function _writeChunk(bytes calldata data) internal returns (address chunk) {
        bytes memory creationCode = abi.encodePacked(
            //---------------------------------------------------------------
            // 0x600B    PUSH1 0x0B     // creation code is 11 bytes
            // 0x59      MSIZE          // 0
            // 0x81      DUP2           // 0x0B
            // 0x38      CODESIZE
            // 0x03      SUB            // runtime length
            // 0x80      DUP1
            // 0x92      SWAP3
            // 0x59      MSIZE          // 0 (destOffset)
            // 0x39      CODECOPY
            // 0xF3      RETURN
            //---------------------------------------------------------------
            hex"600B5981380380925939F3",
            hex"00", // STOP prefix
            data
        );
        assembly {
            chunk := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        if (chunk == address(0)) revert ChunkWriteFailed();
    }

    /// @dev Concatenates all chunk contents (skipping each STOP prefix).
    function _assembleChunks(address[] storage chunks) internal view returns (bytes memory out) {
        uint256 n = chunks.length;
        uint256 total;
        uint256[] memory sizes = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 sz = chunks[i].code.length - 1;
            sizes[i] = sz;
            total += sz;
        }
        out = new bytes(total);
        uint256 offset = 0x20;
        for (uint256 i = 0; i < n; ++i) {
            address c = chunks[i];
            uint256 sz = sizes[i];
            assembly {
                extcodecopy(c, add(out, offset), 1, sz)
            }
            offset += sz;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL: RESOLUTION
    //////////////////////////////////////////////////////////////*/

    function _resolveShard(uint256 tokenId, uint256 shardIndex) internal view returns (string memory) {
        Shard storage s = _shards[tokenId][shardIndex];
        if (s.kind == ShardKind.Pointer) {
            return s.pointerURI;
        }
        if (s.kind == ShardKind.Renderer) {
            // Direct call, no catch (decision 8, V1 parity): a broken
            // renderer reverts loudly rather than serving stale or wrong
            // content. Recovery pre-lock is the sharding system (append a
            // replacement shard, re-select — selection is never
            // window-gated). ANY static shards a token holds remain readable
            // via shardURI / readShardBytes / eth_getCode regardless of
            // renderer health — but a renderer-only token has none (the
            // creator's accepted choice; no static fallback exists).
            string memory rendered = IExternalRenderer(s.renderer).uri(tokenId);
            // L-4: empty output is the one failure mode that would otherwise
            // be silent (serving ""). Route it into the same honest revert as
            // any other renderer breakage — consistent with the set-time
            // probe's non-empty rule. A renderer legitimately returning empty
            // has no valid use; recovery is append-a-replacement as usual.
            if (bytes(rendered).length == 0) revert RendererReturnedEmpty();
            return rendered;
        }
        bytes memory json = _assembleChunks(s.chunks);
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
    }

    /// @dev Emits the ERC-1155 `URI` event for indexers that follow it
    ///      (fixes a V1 informational finding) — but only for Pointer
    ///      shards, where the value is bounded. For Onchain shards the
    ///      derived data URI can be megabytes; log data at 8 gas/byte makes
    ///      emitting it prohibitive, so indexers should call `uri()`.
    ///      RESOLVED: the asymmetry stands. Onchain-shard consumers react
    ///      to ShardSelected/ShardEdited (which carry metadataHash) and call
    ///      uri(); this mirrors Tezos, where indexers observe big_map diffs
    ///      rather than events — the EVM has no storage-diff channel, so
    ///      hash-bearing custom events are the substitute.
    function _emitURIIfCheap(uint256 tokenId, uint256 shardIndex) internal {
        Shard storage s = _shards[tokenId][shardIndex];
        if (s.kind == ShardKind.Pointer) {
            emit URI(s.pointerURI, tokenId);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        TRANSFER HOOK / MISC
    //////////////////////////////////////////////////////////////*/

    /// @dev Blocks all post-mint movement of soulbound tokens (transfers
    ///      AND burns — V1 semantics; a soulbound token has no exit).
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155)
    {
        if (from != address(0)) {
            uint256 length = ids.length;
            for (uint256 i = 0; i < length; i++) {
                if (_mintData[ids[i]].soulbound) revert TokenIsSoulbound();
            }
        }
        super._update(from, to, ids, values);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, ERC2981) returns (bool) {
        // Note: V1 also claimed 0xe8a3d485 (the contractURI() selector) as an
        // "ERC-7572 interface id". ERC-7572 defines no ERC-165 id; V3 drops
        // the nonstandard claim. contractURI() itself is still served.
        // ERC-5313 (Light Contract Ownership, id 0x8da5cb5b = owner()
        // selector) IS a real standard id and is advertised — on Shape,
        // owner() resolves the gasback recipient (see divergence header).
        return interfaceId == 0x8da5cb5b || super.supportsInterface(interfaceId);
    }

    receive() external payable {
        revert EtherNotAccepted();
    }

    fallback() external payable {
        revert EtherNotAccepted();
    }
}
