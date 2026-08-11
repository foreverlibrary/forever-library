// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V3TestBase, ForeverLibraryV3} from "./V3TestBase.sol";

/// @dev Port of the SmartPy slice_append scenarios: 3-slice happy path,
///      rolling hash, revision arithmetic, and the full guard matrix in
///      invariant order (existence → locked → auth → range → window →
///      kind → payload).
contract SliceAppendTest is V3TestBase {
    bytes internal s1 = bytes('{"name":"Fragment",');
    bytes internal s2 = bytes('"description":"grown across transactions",');
    bytes internal s3 = bytes('"image":"data:image/svg+xml,<svg/>"}');

    function test_ThreeSliceHappyPath() public {
        uint256 id = mintOnchain(creator, s1);
        assertEq(fl.revisionOf(id), 0, "revision starts at 0 (Tezos parity)");

        bytes32 h1 = keccak256(s1);
        assertEq(fl.getShard(id, 0).metadataHash, h1, "single write = keccak(data)");

        bytes32 h2 = roll(h1, s2);
        vm.expectEmit(true, true, true, true);
        emit SliceAppended(id, 0, creator, s1.length + s2.length, h2);
        vm.prank(creator);
        fl.appendSlice(id, 0, s2);

        bytes32 h3 = roll(h2, s3);
        vm.prank(creator);
        fl.appendSlice(id, 0, s3);

        // Content equals the concatenation, byte for byte.
        assertEq(fl.readShardBytes(id, 0), bytes.concat(s1, s2, s3));

        // Rolling hash: keccak(keccak(keccak(s1) ++ s2) ++ s3).
        ForeverLibraryV3.Shard memory s = fl.getShard(id, 0);
        assertEq(s.metadataHash, h3);
        assertEq(s.totalBytes, s1.length + s2.length + s3.length);
        assertEq(s.chunks.length, 3, "one chunk contract per slice");

        // Revision arithmetic exact: two slices after mint.
        assertEq(fl.revisionOf(id), 2);
    }

    function test_EditResetsHashChainAndChunks() public {
        uint256 id = mintOnchain(creator, s1);
        vm.prank(creator);
        fl.appendSlice(id, 0, s2);

        bytes memory replacement = bytes('{"name":"Replaced"}');
        vm.prank(creator);
        fl.editShard(id, 0, onchain(replacement));

        ForeverLibraryV3.Shard memory s = fl.getShard(id, 0);
        assertEq(s.metadataHash, keccak256(replacement), "edit resets chain to keccak(newData)");
        assertEq(s.chunks.length, 1);
        assertEq(s.totalBytes, replacement.length);
        assertEq(fl.readShardBytes(id, 0), replacement);
    }

    /*//////////////////////// guards ////////////////////////*/

    function test_RevertWhen_NonexistentToken() public {
        vm.expectRevert(ForeverLibraryV3.TokenNotFound.selector);
        vm.prank(creator);
        fl.appendSlice(999, 0, s2);
    }

    function test_RevertWhen_Stranger() public {
        uint256 id = mintOnchain(creator, s1);
        vm.expectRevert(ForeverLibraryV3.NotAuthorized.selector);
        vm.prank(stranger);
        fl.appendSlice(id, 0, s2);
    }

    /// @dev Guard precedence: auth fires before range and payload — a
    ///      stranger learns nothing from index validity or payload shape.
    function test_RevertWhen_Stranger_EvenWithBadIndexAndEmptyPayload() public {
        uint256 id = mintOnchain(creator, s1);
        vm.expectRevert(ForeverLibraryV3.NotAuthorized.selector);
        vm.prank(stranger);
        fl.appendSlice(id, 42, "");
    }

    function test_RevertWhen_OutOfRangeIndex() public {
        uint256 id = mintOnchain(creator, s1);
        vm.expectRevert(ForeverLibraryV3.ShardOutOfRange.selector);
        vm.prank(creator);
        fl.appendSlice(id, 1, s2);
    }

    function test_RevertWhen_PointerShard() public {
        uint256 id = mintPointer(creator, "ipfs://QmPointer");
        vm.expectRevert(ForeverLibraryV3.NotOnchainShard.selector);
        vm.prank(creator);
        fl.appendSlice(id, 0, s2);
    }

    /// @dev Kind check precedes payload checks: pointer shard + empty
    ///      slice reports NotOnchainShard, not EmptyPayload.
    function test_RevertWhen_PointerShard_EmptyPayload() public {
        uint256 id = mintPointer(creator, "ipfs://QmPointer");
        vm.expectRevert(ForeverLibraryV3.NotOnchainShard.selector);
        vm.prank(creator);
        fl.appendSlice(id, 0, "");
    }

    function test_RevertWhen_EmptySlice() public {
        uint256 id = mintOnchain(creator, s1);
        vm.expectRevert(ForeverLibraryV3.EmptyPayload.selector);
        vm.prank(creator);
        fl.appendSlice(id, 0, "");
    }

    function test_SliceSizeBoundary() public {
        uint256 id = mintOnchain(creator, s1);

        // 24,575 bytes: exactly MAX_SLICE_BYTES, succeeds.
        vm.prank(creator);
        fl.appendSlice(id, 0, new bytes(24_575));

        // 24,576 bytes: one over, reverts.
        vm.expectRevert(ForeverLibraryV3.SliceTooLarge.selector);
        vm.prank(creator);
        fl.appendSlice(id, 0, new bytes(24_576));
    }

    function test_RevertWhen_WindowClosed() public {
        uint256 id = mintOnchain(creator, s1);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(ForeverLibraryV3.ShardEditWindowClosed.selector);
        vm.prank(creator);
        fl.appendSlice(id, 0, s2);
    }

    /// @dev Window check precedes payload checks.
    function test_RevertWhen_WindowClosed_EmptyPayload() public {
        uint256 id = mintOnchain(creator, s1);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(ForeverLibraryV3.ShardEditWindowClosed.selector);
        vm.prank(creator);
        fl.appendSlice(id, 0, "");
    }

    /// @dev Locked precedes auth: even a stranger sees ShardsAreLocked.
    function test_RevertWhen_Locked_BeforeAuth() public {
        uint256 id = mintOnchain(creator, s1);
        lockNow(creator, id);
        vm.expectRevert(ForeverLibraryV3.ShardsAreLocked.selector);
        vm.prank(stranger);
        fl.appendSlice(id, 0, s2);
    }
}
