// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V3TestBase, ForeverLibraryV3} from "./V3TestBase.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Port of the Tezos transfer_soulbound scenarios. Soulbound = no
///      exit: transfers AND burns blocked post-mint via the _update hook.
contract SoulboundTest is V3TestBase {
    uint256 internal normalId;
    uint256 internal sbId;

    function setUp() public override {
        super.setUp();
        normalId = mintOnchain(creator, bytes('{"name":"Transferable"}'));

        vm.prank(creator);
        fl.mintSoulbound(pointer("ipfs://QmSoul"), 0);
        sbId = fl.totalTokenTypes();
    }

    function test_SoulboundMintShape() public view {
        assertTrue(fl.isSoulbound(sbId));
        assertEq(fl.totalSupply(sbId), 1, "soulbound supply hardcoded to 1");
        assertEq(fl.balanceOf(creator, sbId), 1);
        assertEq(fl.getMintData(sbId).creator, creator);
    }

    function test_NormalTransferMovesBalance() public {
        vm.prank(creator);
        fl.safeTransferFrom(creator, collector, normalId, 4, "");
        assertEq(fl.balanceOf(creator, normalId), 6);
        assertEq(fl.balanceOf(collector, normalId), 4);
    }

    function test_NormalOperatorTransfer() public {
        vm.prank(creator);
        fl.setApprovalForAll(operator, true);
        vm.prank(operator);
        fl.safeTransferFrom(creator, collector, normalId, 2, "");
        assertEq(fl.balanceOf(collector, normalId), 2);
    }

    function test_SoulboundTransferRejected_Owner() public {
        vm.expectRevert(ForeverLibraryV3.TokenIsSoulbound.selector);
        vm.prank(creator);
        fl.safeTransferFrom(creator, collector, sbId, 1, "");
    }

    function test_SoulboundTransferRejected_ApprovedOperator() public {
        vm.prank(creator);
        fl.setApprovalForAll(operator, true);

        // Approval layer passes; the soulbound hook still rejects.
        vm.expectRevert(ForeverLibraryV3.TokenIsSoulbound.selector);
        vm.prank(operator);
        fl.safeTransferFrom(creator, collector, sbId, 1, "");
    }

    function test_UnapprovedOperatorStillFailsAtApprovalLayer() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155MissingApprovalForAll.selector, stranger, creator
            )
        );
        vm.prank(stranger);
        fl.safeTransferFrom(creator, collector, sbId, 1, "");
    }

    function test_BatchTransferContainingSoulboundRejected() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = normalId;
        ids[1] = sbId;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1;

        vm.expectRevert(ForeverLibraryV3.TokenIsSoulbound.selector);
        vm.prank(creator);
        fl.safeBatchTransferFrom(creator, collector, ids, amounts, "");
    }

    /// @dev No burn path exists: there is no burn selector, and a
    ///      transfer to address(0) is rejected by ERC1155 itself before
    ///      the hook could even be consulted.
    function test_BurnUnreachable_ZeroAddressTransferRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(0))
        );
        vm.prank(creator);
        fl.safeTransferFrom(creator, address(0), sbId, 1, "");

        // Same for the non-soulbound token: supply is fixed forever.
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(0))
        );
        vm.prank(creator);
        fl.safeTransferFrom(creator, address(0), normalId, 1, "");
    }

    function test_ApprovalOnSoulboundSucceedsHarmlessly() public {
        vm.prank(creator);
        fl.setApprovalForAll(operator, true);
        assertTrue(fl.isApprovedForAll(creator, operator));
        // Harmless: operator still cannot move the soulbound token
        // (covered above); approval state itself is unrestricted.
    }

    function test_SoulboundMetadataStillMutableInWindow() public {
        // Soulbound restricts movement, not the shard system.
        vm.prank(creator);
        fl.editShard(sbId, 0, pointer("ipfs://QmSoulEdit"));
        assertEq(fl.uri(sbId), "ipfs://QmSoulEdit");
    }
}
