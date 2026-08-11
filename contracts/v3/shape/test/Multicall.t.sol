// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V3TestBase, ForeverLibraryV3} from "./V3TestBase.sol";

/// @dev Reenters a mint THROUGH multicall from the ERC1155 receiver callback,
///      to prove multicall cannot bypass the nonReentrant guard on mints.
contract ReentrantMulticaller {
    ForeverLibraryV3 internal immutable fl;
    bool public innerReverted;
    bool internal done;

    constructor(ForeverLibraryV3 fl_) {
        fl = fl_;
    }

    function _input() internal pure returns (ForeverLibraryV3.ShardInput memory) {
        return ForeverLibraryV3.ShardInput({
            kind: ForeverLibraryV3.ShardKind.Onchain,
            data: bytes("{}"),
            pointerURI: "",
            renderer: address(0)
        });
    }

    function doMint() external {
        fl.mint(_input(), 1, 0);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        if (!done) {
            done = true;
            bytes[] memory calls = new bytes[](1);
            calls[0] = abi.encodeCall(fl.mint, (_input(), 1, 0));
            try fl.multicall(calls) {
                // must not reach: reentrant mint is guarded
            } catch {
                innerReverted = true;
            }
        }
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}

/// @dev Decision 9: OZ Multicall batching. Covers the two target frontend
///      scenarios and the security-relevant properties (msg.sender
///      preserved via self-delegatecall, non-payable, all-or-nothing
///      atomicity, no authorization escalation, nonReentrant still holds).
contract MulticallTest is V3TestBase {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = mintOnchain(creator, bytes('{"name":"Genesis"}'));
    }

    /*//////////////////// target scenario 1: append + select ////////////////////*/

    function test_Batch_AppendBackupThenSelect() public {
        // Backup will land at index 1 (current shardCount). Batch appends it
        // AND selects it in one atomic call.
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(fl.appendShard, (id, pointer("ar://backup")));
        calls[1] = abi.encodeCall(fl.selectShard, (id, 1));

        vm.prank(creator);
        fl.multicall(calls);

        assertEq(fl.shardCount(id), 2);
        assertEq(fl.selectedShardIndex(id), 1);
        assertEq(fl.uri(id), "ar://backup");
        // provenance is the real creator, not the contract (msg.sender kept)
        assertEq(fl.getShard(id, 1).addedBy, creator);
    }

    /*//////////////////// target scenario 2: edit + select ////////////////////*/

    function test_Batch_EditThenSelect() public {
        // Append a second shard, then in one batch edit it (within window)
        // and make it the selected shard.
        vm.prank(creator);
        fl.appendShard(id, pointer("ipfs://old"));

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(fl.editShard, (id, 1, pointer("ipfs://edited")));
        calls[1] = abi.encodeCall(fl.selectShard, (id, 1));

        vm.prank(creator);
        fl.multicall(calls);

        assertEq(fl.selectedShardIndex(id), 1);
        assertEq(fl.uri(id), "ipfs://edited");
    }

    /*//////////////////// msg.sender preservation ////////////////////*/

    function test_Batch_DelegatePreservesSender() public {
        vm.prank(creator);
        fl.setDelegate(id, delegate);

        // Delegate batches append-own-shard + select, as themselves.
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(fl.appendShard, (id, pointer("ar://by-delegate")));
        calls[1] = abi.encodeCall(fl.selectShard, (id, 1));

        vm.prank(delegate);
        fl.multicall(calls);

        assertEq(fl.getShard(id, 1).addedBy, delegate, "sender preserved through delegatecall");
        assertEq(fl.selectedShardIndex(id), 1);
    }

    /// @dev Multicall grants no authority: a stranger batching a creator-only
    ///      op is still rejected, exactly as a direct call would be.
    function test_Batch_StrangerStillUnauthorized() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(fl.selectShard, (id, 0));

        vm.expectRevert(ForeverLibraryV3.NotAuthorized.selector);
        vm.prank(stranger);
        fl.multicall(calls);
    }

    /*//////////////////// atomicity ////////////////////*/

    /// @dev All-or-nothing: a failing call reverts the whole batch, leaving
    ///      no partial state (the successful append is rolled back).
    function test_Batch_RevertsAtomically() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(fl.appendShard, (id, pointer("ar://backup")));
        // index 2 doesn't exist yet -> ShardOutOfRange -> whole batch reverts
        calls[1] = abi.encodeCall(fl.selectShard, (id, 2));

        vm.expectRevert(ForeverLibraryV3.ShardOutOfRange.selector);
        vm.prank(creator);
        fl.multicall(calls);

        // The append did not persist.
        assertEq(fl.shardCount(id), 1);
        assertEq(fl.selectedShardIndex(id), 0);
    }

    /*//////////////////// non-payable ////////////////////*/

    /// @dev multicall is not payable; sending value reverts (no msg.value
    ///      double-spend surface can exist).
    function test_Batch_RejectsEther() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(fl.selectShard, (id, 0));

        vm.deal(creator, 1 ether);
        vm.prank(creator);
        (bool ok,) = address(fl).call{value: 1 wei}(
            abi.encodeCall(fl.multicall, (calls))
        );
        assertFalse(ok, "multicall must reject value");
    }

    /*//////////////////// lock interaction ////////////////////*/

    /// @dev Batching append + select + lock in one atomic transaction works
    ///      when the caller pins the post-batch revision/count/hash.
    function test_Batch_AppendSelectLock() public {
        uint256 rev = fl.revisionOf(id); // 0
        bytes32 hash1 = keccak256(bytes("ar://final"));

        // After append (+1 rev) and select (+1 rev): revision = rev + 2,
        // count = 2, selected = 1, selected hash = keccak(uri).
        ForeverLibraryV3.LockGuard memory g = ForeverLibraryV3.LockGuard({
            expectedSelected: 1,
            expectedHash: hash1,
            expectedShardCount: 2,
            expectedRevision: rev + 2
        });

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(fl.appendShard, (id, pointer("ar://final")));
        calls[1] = abi.encodeCall(fl.selectShard, (id, 1));
        calls[2] = abi.encodeCall(fl.lockShards, (id, g));

        vm.prank(creator);
        fl.multicall(calls);

        assertTrue(fl.isLocked(id));
        assertEq(fl.selectedShardIndex(id), 1);
        assertEq(fl.uri(id), "ar://final");
    }

    /*//////////////////// post-lock ////////////////////*/

    function test_Batch_PostLockStillReverts() public {
        lockNow(creator, id);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(fl.appendShard, (id, pointer("ar://no")));

        vm.expectRevert(ForeverLibraryV3.ShardsAreLocked.selector);
        vm.prank(creator);
        fl.multicall(calls);
    }

    /*//////////////////// reentrancy: multicall cannot bypass nonReentrant ////////////////////*/

    /// @dev A mint reentered THROUGH multicall from the receiver callback
    ///      still hits the shared nonReentrant guard and reverts. The outer
    ///      mint completes; the inner (batched) mint is blocked.
    function test_Batch_CannotBypassReentrancyGuardOnMint() public {
        ReentrantMulticaller rc = new ReentrantMulticaller(fl);
        rc.doMint();

        assertTrue(rc.innerReverted(), "reentrant mint via multicall must revert");
        // The outer mint still succeeded exactly once.
        assertEq(fl.totalTokenTypes(), 2, "only the setUp token + outer mint exist");
        assertEq(fl.balanceOf(address(rc), 2), 1);
    }
}
