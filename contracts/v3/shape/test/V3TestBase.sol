// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ForeverLibraryV3} from "../ForeverLibraryV3.sol";

/// @dev Shared fixture for the V3 suite. Actors, ShardInput builders,
///      mint/lock helpers, and redeclared events for vm.expectEmit.
abstract contract V3TestBase is Test {
    ForeverLibraryV3 internal fl;

    address internal creator = makeAddr("creator");
    address internal delegate = makeAddr("delegate");
    address internal delegate2 = makeAddr("delegate2");
    address internal stranger = makeAddr("stranger");
    address internal operator = makeAddr("operator");
    address internal collector = makeAddr("collector");
    address internal gasbackWallet = makeAddr("gasbackWallet");

    // Events redeclared with identical signatures for expectEmit.
    event TokenMinted(
        address indexed creator,
        uint256 indexed tokenId,
        ForeverLibraryV3.ShardKind kind,
        bytes32 metadataHash,
        uint256 supply,
        bool soulbound
    );
    event ShardAppended(
        uint256 indexed tokenId,
        uint256 indexed shardIndex,
        ForeverLibraryV3.ShardKind kind,
        bytes32 metadataHash,
        address indexed by
    );
    event ShardEdited(
        uint256 indexed tokenId,
        uint256 indexed shardIndex,
        ForeverLibraryV3.ShardKind kind,
        bytes32 metadataHash,
        address indexed by
    );
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
    event URI(string value, uint256 indexed id);

    function setUp() public virtual {
        fl = new ForeverLibraryV3(gasbackWallet);
    }

    function onchain(bytes memory data) internal pure returns (ForeverLibraryV3.ShardInput memory) {
        return ForeverLibraryV3.ShardInput({
            kind: ForeverLibraryV3.ShardKind.Onchain,
            data: data,
            pointerURI: "",
            renderer: address(0)
        });
    }

    function pointer(string memory uri_) internal pure returns (ForeverLibraryV3.ShardInput memory) {
        return ForeverLibraryV3.ShardInput({
            kind: ForeverLibraryV3.ShardKind.Pointer,
            data: "",
            pointerURI: uri_,
            renderer: address(0)
        });
    }

    function rendererInput(address r) internal pure returns (ForeverLibraryV3.ShardInput memory) {
        return ForeverLibraryV3.ShardInput({
            kind: ForeverLibraryV3.ShardKind.Renderer,
            data: "",
            pointerURI: "",
            renderer: r
        });
    }

    function mintOnchain(address who, bytes memory data) internal returns (uint256 tokenId) {
        vm.prank(who);
        fl.mint(onchain(data), 10, 500);
        tokenId = fl.totalTokenTypes();
    }

    function mintPointer(address who, string memory uri_) internal returns (uint256 tokenId) {
        vm.prank(who);
        fl.mint(pointer(uri_), 10, 500);
        tokenId = fl.totalTokenTypes();
    }

    /// @dev Locks with freshly read (i.e. correct) guard values.
    function lockNow(address who, uint256 tokenId) internal {
        uint256 sel = fl.selectedShardIndex(tokenId);
        ForeverLibraryV3.LockGuard memory g = ForeverLibraryV3.LockGuard({
            expectedSelected: sel,
            expectedHash: fl.getShard(tokenId, sel).metadataHash,
            expectedShardCount: fl.shardCount(tokenId),
            expectedRevision: fl.revisionOf(tokenId)
        });
        vm.prank(who);
        fl.lockShards(tokenId, g);
    }

    /// @dev Tezos rolling-hash step: keccak(prevHash ++ slice).
    function roll(bytes32 prev, bytes memory slice) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, slice));
    }
}
