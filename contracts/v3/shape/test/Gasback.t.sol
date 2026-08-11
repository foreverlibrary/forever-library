// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V3TestBase, ForeverLibraryV3} from "./V3TestBase.sol";

/// @dev SHAPE DIVERGENCE tests: the gasbackRecipient field exists solely so
///      Shape's Gasback system can resolve owner(); it must carry zero
///      authority over the contract, rotate only by its own hand, and never
///      be zeroable.
contract GasbackTest is V3TestBase {
    event GasbackRecipientChanged(address indexed previousRecipient, address indexed newRecipient);

    function test_ConstructorSetsRecipientAndOwnerTracks() public view {
        assertEq(fl.gasbackRecipient(), gasbackWallet);
        assertEq(fl.owner(), gasbackWallet, "owner() mirrors gasbackRecipient");
        // Decision 11: DEPLOYER is immutable provenance, distinct from the
        // owner() seat (which on Shape is the gasback recipient).
        assertEq(fl.DEPLOYER(), address(this), "deployer recorded");
        assertTrue(fl.supportsInterface(0x8da5cb5b), "ERC-5313 advertised");
    }

    /// @dev Review I-1: construction emits the event so indexers can
    ///      event-source the recipient from genesis.
    function test_ConstructorEmitsRecipientEvent() public {
        vm.expectEmit(true, true, true, true);
        emit GasbackRecipientChanged(address(0), gasbackWallet);
        new ForeverLibraryV3(gasbackWallet);
    }

    function test_ConstructorRejectsZero() public {
        vm.expectRevert(ForeverLibraryV3.ZeroGasbackRecipient.selector);
        new ForeverLibraryV3(address(0));
    }

    function test_RecipientCanRotate() public {
        address next = makeAddr("nextGasbackWallet");

        vm.expectEmit(true, true, true, true);
        emit GasbackRecipientChanged(gasbackWallet, next);
        vm.prank(gasbackWallet);
        fl.setGasbackRecipient(next);

        assertEq(fl.gasbackRecipient(), next);
        assertEq(fl.owner(), next);

        // Old recipient has lost control...
        vm.expectRevert(ForeverLibraryV3.NotGasbackRecipient.selector);
        vm.prank(gasbackWallet);
        fl.setGasbackRecipient(gasbackWallet);

        // ...and the new one has it.
        vm.prank(next);
        fl.setGasbackRecipient(gasbackWallet);
        assertEq(fl.gasbackRecipient(), gasbackWallet);
    }

    function test_OnlyRecipientRotates() public {
        vm.expectRevert(ForeverLibraryV3.NotGasbackRecipient.selector);
        vm.prank(stranger);
        fl.setGasbackRecipient(stranger);

        // A token creator has no say either.
        mintOnchain(creator, bytes('{"name":"x"}'));
        vm.expectRevert(ForeverLibraryV3.NotGasbackRecipient.selector);
        vm.prank(creator);
        fl.setGasbackRecipient(creator);
    }

    function test_RotateToZeroReverts() public {
        vm.expectRevert(ForeverLibraryV3.ZeroGasbackRecipient.selector);
        vm.prank(gasbackWallet);
        fl.setGasbackRecipient(address(0));
    }

    /// @dev The recipient is NOT an admin: it holds none of the creator or
    ///      delegate powers on anyone's token.
    function test_RecipientHasNoContractPowers() public {
        uint256 id = mintOnchain(creator, bytes('{"name":"NotYours"}'));

        vm.startPrank(gasbackWallet);

        vm.expectRevert(ForeverLibraryV3.NotAuthorized.selector);
        fl.editShard(id, 0, pointer("ipfs://QmTakeover"));

        vm.expectRevert(ForeverLibraryV3.NotAuthorized.selector);
        fl.appendShard(id, pointer("ipfs://QmNo"));

        vm.expectRevert(ForeverLibraryV3.NotAuthorized.selector);
        fl.selectShard(id, 0);

        vm.expectRevert(ForeverLibraryV3.NotTokenCreator.selector);
        fl.lockShards(id, ForeverLibraryV3.LockGuard(0, bytes32(0), 1, 0));

        vm.expectRevert(ForeverLibraryV3.NotTokenCreator.selector);
        fl.setDelegate(id, gasbackWallet);

        vm.expectRevert(ForeverLibraryV3.NotTokenCreator.selector);
        fl.updateTokenRoyalty(id, gasbackWallet, 100);

        vm.stopPrank();
    }

    /// @dev Rotation composes with multicall like everything else —
    ///      msg.sender preserved, no escalation.
    function test_RotationViaMulticall() public {
        address next = makeAddr("nextGasbackWallet");
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(fl.setGasbackRecipient, (next));

        vm.expectRevert(ForeverLibraryV3.NotGasbackRecipient.selector);
        vm.prank(stranger);
        fl.multicall(calls);

        vm.prank(gasbackWallet);
        fl.multicall(calls);
        assertEq(fl.gasbackRecipient(), next);
    }
}
