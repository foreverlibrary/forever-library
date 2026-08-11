// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V3TestBase, ForeverLibraryV3} from "./V3TestBase.sol";

/// @dev Decision 11: DEPLOYER (immutable provenance) + owner() (rotatable
///      marketplace pointer). The pointer must carry ZERO on-chain
///      authority, rotate only by its own hand, and never zero.
contract OwnershipTest is V3TestBase {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function test_DeployerAndOwnerInitialized() public view {
        // The test contract deployed fl in setUp.
        assertEq(fl.DEPLOYER(), address(this), "DEPLOYER = deploying wallet");
        assertEq(fl.owner(), address(this), "owner initialized to deployer");
    }

    function test_ConstructorEmitsOwnershipTransferred() public {
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(address(0), address(this));
        new ForeverLibraryV3();
    }

    function test_TransferOwnership() public {
        address next = makeAddr("nextOwner");

        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(address(this), next);
        fl.transferOwnership(next);

        assertEq(fl.owner(), next);
        // Provenance is immutable — rotation never touches DEPLOYER.
        assertEq(fl.DEPLOYER(), address(this));

        // Old holder is locked out...
        vm.expectRevert(ForeverLibraryV3.NotContractOwner.selector);
        fl.transferOwnership(address(this));

        // ...and the new holder has the seat.
        vm.prank(next);
        fl.transferOwnership(address(this));
        assertEq(fl.owner(), address(this));
    }

    function test_NonOwnerCannotTransfer() public {
        vm.expectRevert(ForeverLibraryV3.NotContractOwner.selector);
        vm.prank(stranger);
        fl.transferOwnership(stranger);

        // A token creator has no say either.
        mintOnchain(creator, bytes('{"name":"x"}'));
        vm.expectRevert(ForeverLibraryV3.NotContractOwner.selector);
        vm.prank(creator);
        fl.transferOwnership(creator);
    }

    function test_ZeroOwnerReverts() public {
        vm.expectRevert(ForeverLibraryV3.ZeroOwner.selector);
        fl.transferOwnership(address(0));
    }

    /// @dev The seat is a pointer, not an admin: it holds none of the
    ///      creator or delegate powers on anyone's token.
    function test_OwnerHasNoContractPowers() public {
        address seat = makeAddr("marketplaceSeat");
        fl.transferOwnership(seat);
        uint256 id = mintOnchain(creator, bytes('{"name":"NotYours"}'));

        vm.startPrank(seat);

        vm.expectRevert(ForeverLibraryV3.NotAuthorized.selector);
        fl.editShard(id, 0, pointer("ipfs://QmTakeover"));

        vm.expectRevert(ForeverLibraryV3.NotAuthorized.selector);
        fl.appendShard(id, pointer("ipfs://QmNo"));

        vm.expectRevert(ForeverLibraryV3.NotAuthorized.selector);
        fl.selectShard(id, 0);

        vm.expectRevert(ForeverLibraryV3.NotTokenCreator.selector);
        fl.lockShards(id, ForeverLibraryV3.LockGuard(0, bytes32(0), 1, 0));

        vm.expectRevert(ForeverLibraryV3.NotTokenCreator.selector);
        fl.setDelegate(id, seat);

        vm.expectRevert(ForeverLibraryV3.NotTokenCreator.selector);
        fl.updateTokenRoyalty(id, seat, 100);

        vm.stopPrank();
    }

    /// @dev Rotation composes with multicall — msg.sender preserved.
    function test_TransferViaMulticall() public {
        address next = makeAddr("nextOwner");
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(fl.transferOwnership, (next));

        vm.expectRevert(ForeverLibraryV3.NotContractOwner.selector);
        vm.prank(stranger);
        fl.multicall(calls);

        fl.multicall(calls); // called by the owner (this contract)
        assertEq(fl.owner(), next);
    }

    function test_ERC5313Advertised() public view {
        assertTrue(fl.supportsInterface(0x8da5cb5b), "ERC-5313 owner()");
    }
}
