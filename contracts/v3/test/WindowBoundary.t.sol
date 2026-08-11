// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V3TestBase, ForeverLibraryV3} from "./V3TestBase.sol";

/// @dev Design decision 5: the edit window is EXCLUSIVE — open while
///      block.timestamp < timestamp + 24h, closed at exactly +24h.
///      `shardEditTimeRemaining == 0 ⇔ mutations rejected` at every second.
contract WindowBoundaryTest is V3TestBase {
    bytes internal json = bytes('{"name":"Boundary"}');

    function test_EditAndSliceSucceedAtLastOpenSecond() public {
        uint256 t0 = block.timestamp;
        uint256 id = mintOnchain(creator, json);

        vm.warp(t0 + 86_399);
        assertEq(fl.shardEditTimeRemaining(id, 0), 1, "one second left");

        vm.prank(creator);
        fl.editShard(id, 0, onchain(bytes('{"name":"Edited"}')));

        vm.prank(creator);
        fl.appendSlice(id, 0, bytes(" trailing"));
    }

    function test_EditAndSliceRevertAtExactlyPlus24h() public {
        uint256 t0 = block.timestamp;
        uint256 id = mintOnchain(creator, json);

        vm.warp(t0 + 86_400);
        assertEq(fl.shardEditTimeRemaining(id, 0), 0, "window closed at exactly +24h");

        vm.expectRevert(ForeverLibraryV3.ShardEditWindowClosed.selector);
        vm.prank(creator);
        fl.editShard(id, 0, onchain(bytes('{"name":"TooLate"}')));

        vm.expectRevert(ForeverLibraryV3.ShardEditWindowClosed.selector);
        vm.prank(creator);
        fl.appendSlice(id, 0, bytes(" late"));
    }

    function test_EditDoesNotExtendWindow() public {
        uint256 t0 = block.timestamp;
        uint256 id = mintOnchain(creator, json);

        // Edit mid-window; provenance timestamp must not move.
        vm.warp(t0 + 12 hours);
        vm.prank(creator);
        fl.editShard(id, 0, onchain(bytes('{"name":"MidWindow"}')));
        assertEq(fl.getShard(id, 0).timestamp, uint64(t0), "provenance timestamp write-once");

        // Window still closes at t0 + 24h, not t0 + 36h.
        vm.warp(t0 + 86_400);
        vm.expectRevert(ForeverLibraryV3.ShardEditWindowClosed.selector);
        vm.prank(creator);
        fl.editShard(id, 0, onchain(bytes('{"name":"Late"}')));
    }

    function test_AppendedShardHasItsOwnWindow() public {
        uint256 t0 = block.timestamp;
        uint256 id = mintOnchain(creator, json);

        // Append is not window-gated; shard 1 appended after shard 0 closed.
        vm.warp(t0 + 30 hours);
        vm.prank(creator);
        fl.appendShard(id, onchain(bytes('{"name":"Second"}')));

        // Shard 0 is closed, shard 1 is open, independently.
        assertEq(fl.shardEditTimeRemaining(id, 0), 0);
        assertEq(fl.shardEditTimeRemaining(id, 1), 24 hours);

        vm.prank(creator);
        fl.editShard(id, 1, onchain(bytes('{"name":"Second, edited"}')));

        vm.expectRevert(ForeverLibraryV3.ShardEditWindowClosed.selector);
        vm.prank(creator);
        fl.editShard(id, 0, onchain(bytes('{"name":"Nope"}')));
    }

    function test_TimeRemainingZeroOnceLocked_AnyIndex() public {
        uint256 id = mintOnchain(creator, json);
        lockNow(creator, id);
        // Locked short-circuits before range (mirrors mutating guard order).
        assertEq(fl.shardEditTimeRemaining(id, 0), 0);
        assertEq(fl.shardEditTimeRemaining(id, 42), 0);
    }

    function test_TimeRemainingRevertsOutOfRange_WhenUnlocked() public {
        uint256 id = mintOnchain(creator, json);
        vm.expectRevert(ForeverLibraryV3.ShardOutOfRange.selector);
        fl.shardEditTimeRemaining(id, 42);
    }
}
