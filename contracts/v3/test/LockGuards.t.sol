// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V3TestBase, ForeverLibraryV3} from "./V3TestBase.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";

/// @dev LockGuard: each of the four fields individually wrong → its
///      specific revert; all correct → locked forever. Post-lock every
///      mutation reverts except updateTokenRoyalty (decision 1).
contract LockGuardsTest is V3TestBase {
    uint256 internal id;
    bytes32 internal h0;

    function setUp() public override {
        super.setUp();
        id = mintOnchain(creator, bytes('{"name":"ToSeal"}'));
        h0 = fl.getShard(id, 0).metadataHash;
        // Correct state at this point: selected=0, hash=h0, count=1, rev=0.
    }

    function _guard(uint256 sel, bytes32 h, uint256 count, uint256 rev)
        internal
        pure
        returns (ForeverLibraryV3.LockGuard memory)
    {
        return ForeverLibraryV3.LockGuard({
            expectedSelected: sel,
            expectedHash: h,
            expectedShardCount: count,
            expectedRevision: rev
        });
    }

    function test_WrongShardCount() public {
        vm.expectRevert(ForeverLibraryV3.UnexpectedShardCount.selector);
        vm.prank(creator);
        fl.lockShards(id, _guard(0, h0, 2, 0));
    }

    function test_WrongRevision() public {
        vm.expectRevert(ForeverLibraryV3.UnexpectedRevision.selector);
        vm.prank(creator);
        fl.lockShards(id, _guard(0, h0, 1, 7));
    }

    /// @dev Reachable only via internally inconsistent caller args (if the
    ///      revision matches, selected cannot have drifted) — its purpose
    ///      is a precise revert for frontend bugs. Also a regression test:
    ///      a bogus expectedSelected must revert cleanly here, never panic
    ///      on out-of-bounds indexing in the hash guard.
    function test_WrongSelected() public {
        vm.expectRevert(ForeverLibraryV3.UnexpectedSelectedShard.selector);
        vm.prank(creator);
        fl.lockShards(id, _guard(5, h0, 1, 0));
    }

    function test_WrongHash() public {
        vm.expectRevert(ForeverLibraryV3.UnexpectedMetadataHash.selector);
        vm.prank(creator);
        fl.lockShards(id, _guard(0, keccak256("wrong"), 1, 0));
    }

    function test_AllCorrectLocks() public {
        vm.expectEmit(true, true, true, true);
        emit ShardsLocked(id, creator);
        vm.prank(creator);
        fl.lockShards(id, _guard(0, h0, 1, 0));
        assertTrue(fl.isLocked(id));
    }

    function test_OnlyCreatorCanLock() public {
        vm.expectRevert(ForeverLibraryV3.NotTokenCreator.selector);
        vm.prank(stranger);
        fl.lockShards(id, _guard(0, h0, 1, 0));
    }

    function test_LockNonexistentToken() public {
        vm.expectRevert(ForeverLibraryV3.TokenNotFound.selector);
        vm.prank(creator);
        fl.lockShards(999, _guard(0, h0, 1, 0));
    }

    /*//////////////////////// post-lock ////////////////////////*/

    function test_PostLockEveryMutationReverts() public {
        vm.prank(creator);
        fl.setDelegate(id, delegate);
        lockNow(creator, id);

        vm.startPrank(creator);

        vm.expectRevert(ForeverLibraryV3.ShardsAreLocked.selector);
        fl.appendShard(id, pointer("ipfs://QmNo"));

        vm.expectRevert(ForeverLibraryV3.ShardsAreLocked.selector);
        fl.editShard(id, 0, pointer("ipfs://QmNo"));

        vm.expectRevert(ForeverLibraryV3.ShardsAreLocked.selector);
        fl.appendSlice(id, 0, bytes("x"));

        vm.expectRevert(ForeverLibraryV3.ShardsAreLocked.selector);
        fl.selectShard(id, 0);

        vm.expectRevert(ForeverLibraryV3.ShardsAreLocked.selector);
        fl.setDelegate(id, delegate2);

        vm.expectRevert(ForeverLibraryV3.ShardsAreLocked.selector);
        fl.lockShards(id, _guard(0, h0, 1, 0));

        vm.stopPrank();

        // The live delegate is frozen out too.
        vm.expectRevert(ForeverLibraryV3.ShardsAreLocked.selector);
        vm.prank(delegate);
        fl.selectShard(id, 0);
    }

    /// @dev Decision 1 (revised): royalty is commercial configuration, not
    ///      part of the preserved artifact — creator-mutable after lock,
    ///      including the receiver.
    function test_RoyaltyStillMutablePostLock() public {
        lockNow(creator, id);

        vm.expectEmit(true, true, true, true);
        emit RoyaltyUpdated(id, creator, 750);
        vm.prank(creator);
        fl.updateTokenRoyalty(id, creator, 750);

        (address receiver, uint256 amount) = fl.royaltyInfo(id, 10_000);
        assertEq(receiver, creator);
        assertEq(amount, 750);

        vm.expectRevert(ForeverLibraryV3.InvalidRoyalty.selector);
        vm.prank(creator);
        fl.updateTokenRoyalty(id, creator, 10_001);
    }

    /// @dev Decision 1 revision (2026-07-09): the receiver is a parameter —
    ///      wallet rotation, estates, and split retrofits work forever,
    ///      including post-lock. Provenance is untouched.
    function test_RoyaltyReceiverChange() public {
        address split = makeAddr("splitContract");

        vm.expectEmit(true, true, true, true);
        emit RoyaltyUpdated(id, split, 800);
        vm.prank(creator);
        fl.updateTokenRoyalty(id, split, 800);

        (address rcv, uint256 amt) = fl.royaltyInfo(id, 10_000);
        assertEq(rcv, split);
        assertEq(amt, 800);

        // Provenance is untouched by receiver changes.
        assertEq(fl.getMintData(id).creator, creator);
        assertEq(fl.getShard(id, 0).addedBy, creator);

        // Post-lock the receiver remains rotatable.
        lockNow(creator, id);
        address estate = makeAddr("estateWallet");
        vm.prank(creator);
        fl.updateTokenRoyalty(id, estate, 500);
        (rcv, amt) = fl.royaltyInfo(id, 10_000);
        assertEq(rcv, estate);
        assertEq(amt, 500);
    }

    function test_RoyaltyZeroReceiverReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC2981.ERC2981InvalidTokenRoyaltyReceiver.selector, id, address(0)
            )
        );
        vm.prank(creator);
        fl.updateTokenRoyalty(id, address(0), 500);
    }

    /// @dev The procedural invariant, demonstrated: a live delegate bumps
    ///      revision between the creator's read and the lock → the
    ///      revision-pinned lock reverts. Frontends must revoke first.
    function test_DelegateGriefingScenario() public {
        vm.prank(creator);
        fl.setDelegate(id, delegate);

        // Creator reads state for the lock call.
        uint256 rev = fl.revisionOf(id);

        // Delegate front-runs with any revision-bumping action
        // (re-selecting the same shard still bumps).
        vm.prank(delegate);
        fl.selectShard(id, 0);

        vm.expectRevert(ForeverLibraryV3.UnexpectedRevision.selector);
        vm.prank(creator);
        fl.lockShards(id, _guard(0, h0, 1, rev));

        // Correct sequence: revoke → re-read → lock succeeds.
        vm.prank(creator);
        fl.setDelegate(id, address(0));
        lockNow(creator, id);
        assertTrue(fl.isLocked(id));
    }
}
