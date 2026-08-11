// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V3TestBase, ForeverLibraryV3} from "./V3TestBase.sol";

/// @dev Delegate powers: append, slice/edit OWN shards (while still the
///      current delegate), select. NOT: lock, delegation changes, royalty
///      changes. Creator overrides any shard in window.
contract DelegateMatrixTest is V3TestBase {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = mintOnchain(creator, bytes('{"name":"Delegated"}'));
        vm.prank(creator);
        fl.setDelegate(id, delegate);
    }

    function test_DelegateAppendsSlicesEditsOwnShard() public {
        vm.prank(delegate);
        fl.appendShard(id, onchain(bytes('{"name":"ByDelegate"')));
        assertEq(fl.getShard(id, 1).addedBy, delegate, "provenance records appender");

        vm.prank(delegate);
        fl.appendSlice(id, 1, bytes(",...}"));

        vm.prank(delegate);
        fl.editShard(id, 1, pointer("ar://delegate-edit"));
        assertEq(fl.getShard(id, 1).addedBy, delegate, "provenance survives edit");
    }

    function test_DelegateCanSelect() public {
        vm.prank(delegate);
        fl.appendShard(id, pointer("ipfs://QmAlt"));
        vm.prank(delegate);
        fl.selectShard(id, 1);
        assertEq(fl.selectedShardIndex(id), 1);
    }

    function test_DelegateCannotTouchCreatorsShard() public {
        vm.expectRevert(ForeverLibraryV3.NotOriginalAppender.selector);
        vm.prank(delegate);
        fl.editShard(id, 0, pointer("ipfs://QmTakeover"));

        vm.expectRevert(ForeverLibraryV3.NotOriginalAppender.selector);
        vm.prank(delegate);
        fl.appendSlice(id, 0, bytes("x"));
    }

    function test_DelegateCannotTouchAnotherAppendersShard() public {
        // delegate appends shard 1, then is replaced by delegate2.
        vm.prank(delegate);
        fl.appendShard(id, onchain(bytes('{"name":"D1"}')));
        vm.prank(creator);
        fl.setDelegate(id, delegate2);

        // delegate2 is current but did not append shard 1.
        vm.expectRevert(ForeverLibraryV3.NotOriginalAppender.selector);
        vm.prank(delegate2);
        fl.editShard(id, 1, pointer("ipfs://QmSteal"));
    }

    function test_CreatorOverridesAnyShardInWindow() public {
        vm.prank(delegate);
        fl.appendShard(id, onchain(bytes('{"name":"D1"}')));

        vm.prank(creator);
        fl.editShard(id, 1, pointer("ipfs://QmCreatorOverride"));
        assertEq(fl.getShard(id, 1).addedBy, delegate, "override does not rewrite provenance");
    }

    function test_RevokedDelegateLosesAccessImmediately_EvenOnOwnShard() public {
        vm.prank(delegate);
        fl.appendShard(id, onchain(bytes('{"name":"D1"}')));

        // Revoke mid-window (shard 1 is fresh).
        vm.prank(creator);
        fl.setDelegate(id, address(0));

        vm.expectRevert(ForeverLibraryV3.NotAuthorized.selector);
        vm.prank(delegate);
        fl.editShard(id, 1, pointer("ipfs://QmStale"));

        vm.expectRevert(ForeverLibraryV3.NotAuthorized.selector);
        vm.prank(delegate);
        fl.appendSlice(id, 1, bytes("x"));

        vm.expectRevert(ForeverLibraryV3.NotAuthorized.selector);
        vm.prank(delegate);
        fl.appendShard(id, pointer("ipfs://QmMore"));

        vm.expectRevert(ForeverLibraryV3.NotAuthorized.selector);
        vm.prank(delegate);
        fl.selectShard(id, 1);
    }

    function test_SelfDelegationReverts() public {
        vm.expectRevert(ForeverLibraryV3.SelfDelegation.selector);
        vm.prank(creator);
        fl.setDelegate(id, creator);
    }

    function test_DelegateCannotLockOrDelegateOrSetRoyalty() public {
        vm.expectRevert(ForeverLibraryV3.NotTokenCreator.selector);
        vm.prank(delegate);
        fl.lockShards(id, ForeverLibraryV3.LockGuard(0, bytes32(0), 1, 0));

        vm.expectRevert(ForeverLibraryV3.NotTokenCreator.selector);
        vm.prank(delegate);
        fl.setDelegate(id, delegate2);

        vm.expectRevert(ForeverLibraryV3.NotTokenCreator.selector);
        vm.prank(delegate);
        fl.updateTokenRoyalty(id, delegate, 100);
    }

    function test_DelegateSetEventAndView() public {
        assertEq(fl.delegateOf(id), delegate);
        vm.expectEmit(true, true, true, true);
        emit DelegateSet(id, delegate, delegate2, creator);
        vm.prank(creator);
        fl.setDelegate(id, delegate2);
        assertEq(fl.delegateOf(id), delegate2);
    }

    /*//////////////////////// batch path ////////////////////////*/

    function test_BatchAuthorizesPerToken() public {
        // stranger owns a second token; creator cannot delegate it.
        uint256 other = mintOnchain(stranger, bytes('{"name":"NotYours"}'));

        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = other;
        address[] memory ds = new address[](2);
        ds[0] = delegate2;
        ds[1] = delegate2;

        vm.expectRevert(ForeverLibraryV3.NotTokenCreator.selector);
        vm.prank(creator);
        fl.setDelegatesBatch(ids, ds);

        // Atomic: the valid first entry must not have taken effect.
        assertEq(fl.delegateOf(id), delegate);
    }

    function test_BatchLengthMismatch() public {
        uint256[] memory ids = new uint256[](2);
        address[] memory ds = new address[](1);
        vm.expectRevert(ForeverLibraryV3.LengthMismatch.selector);
        vm.prank(creator);
        fl.setDelegatesBatch(ids, ds);
    }

    function test_BatchNonexistentToken() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 999;
        address[] memory ds = new address[](1);
        ds[0] = delegate2;
        vm.expectRevert(ForeverLibraryV3.TokenNotFound.selector);
        vm.prank(creator);
        fl.setDelegatesBatch(ids, ds);
    }

    /// @dev Guard order in the batch loop: locked precedes creator auth —
    ///      a non-creator probing a locked token sees ShardsAreLocked.
    function test_BatchLockedPrecedesAuth() public {
        uint256 other = mintOnchain(stranger, bytes('{"name":"Sealed"}'));
        lockNow(stranger, other);

        uint256[] memory ids = new uint256[](1);
        ids[0] = other;
        address[] memory ds = new address[](1);
        ds[0] = delegate2;

        vm.expectRevert(ForeverLibraryV3.ShardsAreLocked.selector);
        vm.prank(creator);
        fl.setDelegatesBatch(ids, ds);
    }

    function test_BatchHappyPath() public {
        uint256 second = mintOnchain(creator, bytes('{"name":"Second"}'));

        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = second;
        address[] memory ds = new address[](2);
        ds[0] = delegate2;
        ds[1] = address(0); // revocation via batch

        vm.prank(creator);
        fl.setDelegatesBatch(ids, ds);
        assertEq(fl.delegateOf(id), delegate2);
        assertEq(fl.delegateOf(second), address(0));
    }
}
