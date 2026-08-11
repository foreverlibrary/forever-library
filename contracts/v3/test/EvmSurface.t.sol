// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {V3TestBase, ForeverLibraryV3} from "./V3TestBase.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @dev Reenters `appendShard` from the ERC1155 receiver callback during
///      its own mint, to prove mint-event ordering holds under reentrancy.
contract ReentrantCreator {
    ForeverLibraryV3 internal immutable fl;
    bool internal done;

    constructor(ForeverLibraryV3 fl_) {
        fl = fl_;
    }

    function doMint(bytes memory data) external {
        fl.mint(
            ForeverLibraryV3.ShardInput({
                kind: ForeverLibraryV3.ShardKind.Onchain,
                data: data,
                pointerURI: "",
                renderer: address(0)
            }),
            3,
            0
        );
    }

    function onERC1155Received(address, address, uint256 id, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        if (!done) {
            done = true;
            fl.appendShard(
                id,
                ForeverLibraryV3.ShardInput({
                    kind: ForeverLibraryV3.ShardKind.Pointer,
                    data: "",
                    pointerURI: "ipfs://QmReentered",
                    renderer: address(0)
                })
            );
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

contract EvmSurfaceTest is V3TestBase {
    /*//////////////////// ShardInput validation matrix ////////////////////*/

    function test_ValidationMatrix_Mint() public {
        vm.startPrank(creator);

        // Onchain: empty data.
        vm.expectRevert(ForeverLibraryV3.EmptyPayload.selector);
        fl.mint(onchain(""), 1, 0);

        // Onchain: pointer field also set.
        ForeverLibraryV3.ShardInput memory bad = onchain(bytes("{}"));
        bad.pointerURI = "ipfs://QmSmuggled";
        vm.expectRevert(ForeverLibraryV3.InvalidShardInput.selector);
        fl.mint(bad, 1, 0);

        // Onchain: first slice over the cap.
        vm.expectRevert(ForeverLibraryV3.SliceTooLarge.selector);
        fl.mint(onchain(new bytes(24_576)), 1, 0);

        // Pointer: empty URI.
        vm.expectRevert(ForeverLibraryV3.EmptyPayload.selector);
        fl.mint(pointer(""), 1, 0);

        // Pointer: data field also set.
        bad = pointer("ipfs://QmOk");
        bad.data = bytes("{}");
        vm.expectRevert(ForeverLibraryV3.InvalidShardInput.selector);
        fl.mint(bad, 1, 0);

        // Same validator guards appendShard (spot check).
        fl.mint(onchain(bytes("{}")), 1, 0);
        uint256 id = fl.totalTokenTypes();
        vm.expectRevert(ForeverLibraryV3.EmptyPayload.selector);
        fl.appendShard(id, onchain(""));

        vm.stopPrank();
    }

    function test_MintGuards() public {
        vm.startPrank(creator);

        vm.expectRevert(ForeverLibraryV3.ZeroSupply.selector);
        fl.mint(onchain(bytes("{}")), 0, 0);

        vm.expectRevert(ForeverLibraryV3.InvalidRoyalty.selector);
        fl.mint(onchain(bytes("{}")), 1, 10_001);

        vm.stopPrank();
    }

    /*//////////////////////// chunks & reads ////////////////////////*/

    function test_ChunkIsStopPrefixedDataContract() public {
        bytes memory data = bytes('{"name":"chunked"}');
        uint256 id = mintOnchain(creator, data);

        address chunk = fl.getShard(id, 0).chunks[0];
        bytes memory code = chunk.code;
        assertEq(code.length, data.length + 1, "runtime = STOP + data");
        assertEq(uint8(code[0]), 0x00, "STOP prefix");
        for (uint256 i = 0; i < data.length; i++) {
            assertEq(code[i + 1], data[i]);
        }
        assertEq(fl.readShardBytes(id, 0), data);
    }

    function testFuzz_ChunkRoundTrip(bytes memory data) public {
        vm.assume(data.length > 0 && data.length <= 24_575);
        uint256 id = mintOnchain(creator, data);
        assertEq(fl.readShardBytes(id, 0), data, "write-read byte equality");
    }

    function test_AssembleManySingleByteChunks() public {
        uint256 id = mintOnchain(creator, bytes("A"));
        bytes memory expected = bytes("A");
        for (uint256 i = 0; i < 16; i++) {
            bytes memory slice = abi.encodePacked(bytes1(uint8(0x41 + i + 1)));
            vm.prank(creator);
            fl.appendSlice(id, 0, slice);
            expected = bytes.concat(expected, slice);
        }
        assertEq(fl.getShard(id, 0).chunks.length, 17);
        assertEq(fl.readShardBytes(id, 0), expected);
    }

    function test_UriEncodesStoredJsonExactly() public {
        bytes memory json = bytes('{"name":"Exact","attributes":[{"trait_type":"x","value":"y"}]}');
        uint256 id = mintOnchain(creator, json);
        assertEq(
            fl.uri(id),
            string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)))
        );
    }

    function test_UriPointerVerbatim() public {
        uint256 id = mintPointer(creator, "ar://tx-id-here");
        assertEq(fl.uri(id), "ar://tx-id-here");
    }

    /// @dev Pointer URIs are uncapped (the old 65,535 limit was removed). A
    ///      pointer one byte over the former cap is accepted; gas is the only
    ///      limiter. Validation still rejects an EMPTY pointer.
    function test_PointerLengthUncapped() public {
        bytes memory big = new bytes(65_536); // one over the old MAX
        for (uint256 i = 0; i < big.length; i++) big[i] = "a";
        uint256 id = mintPointer(creator, string(big));
        assertEq(fl.getShard(id, 0).metadataHash, keccak256(big));
        assertEq(bytes(fl.uri(id)).length, 65_536);

        // presence check survives: empty pointer still reverts
        vm.expectRevert(ForeverLibraryV3.EmptyPayload.selector);
        vm.prank(creator);
        fl.mint(pointer(""), 1, 0);
    }

    function test_ShardURIResolvesNonSelectedShards() public {
        uint256 id = mintPointer(creator, "ipfs://QmPrimary");
        vm.prank(creator);
        fl.appendShard(id, pointer("ar://backup"));

        assertEq(fl.selectedShardIndex(id), 0, "append does not change selection");
        assertEq(fl.shardURI(id, 0), "ipfs://QmPrimary");
        assertEq(fl.shardURI(id, 1), "ar://backup");
        assertEq(fl.uri(id), "ipfs://QmPrimary");
    }

    function test_EditToPointerAbandonsChunks() public {
        uint256 id = mintOnchain(creator, bytes('{"name":"WasOnchain"}'));
        address chunk = fl.getShard(id, 0).chunks[0];

        vm.prank(creator);
        fl.editShard(id, 0, pointer("ipfs://QmNowPointer"));

        ForeverLibraryV3.Shard memory s = fl.getShard(id, 0);
        assertEq(uint8(s.kind), uint8(ForeverLibraryV3.ShardKind.Pointer));
        assertEq(s.chunks.length, 0);
        assertEq(s.totalBytes, 0);
        assertEq(s.metadataHash, keccak256(bytes("ipfs://QmNowPointer")));

        // Abandoned chunk remains on-chain, unreferenced (by design).
        assertGt(chunk.code.length, 0);

        vm.expectRevert(ForeverLibraryV3.NotOnchainShard.selector);
        fl.readShardBytes(id, 0);
    }

    function test_GetShardRange() public {
        uint256 id = mintPointer(creator, "ipfs://Qm0");
        vm.startPrank(creator);
        fl.appendShard(id, pointer("ipfs://Qm1"));
        fl.appendShard(id, pointer("ipfs://Qm2"));
        vm.stopPrank();

        ForeverLibraryV3.Shard[] memory page = fl.getShardRange(id, 1, 3);
        assertEq(page.length, 2);
        assertEq(page[0].pointerURI, "ipfs://Qm1");
        assertEq(page[1].pointerURI, "ipfs://Qm2");

        vm.expectRevert(ForeverLibraryV3.InvalidRange.selector);
        fl.getShardRange(id, 2, 2);
        vm.expectRevert(ForeverLibraryV3.InvalidRange.selector);
        fl.getShardRange(id, 0, 4);
    }

    /*//////////////////////// events & shapes ////////////////////////*/

    function test_TokenMintedShape() public {
        bytes memory json = bytes('{"name":"Shaped"}');
        vm.expectEmit(true, true, true, true);
        emit TokenMinted(
            creator, 1, ForeverLibraryV3.ShardKind.Onchain, keccak256(json), 7, false
        );
        vm.prank(creator);
        fl.mint(onchain(json), 7, 250);

        ForeverLibraryV3.Shard memory s = fl.getShard(1, 0);
        assertEq(s.addedBy, creator);
        assertEq(s.blockNumber, uint64(block.number), "provenance block");
        assertEq(fl.totalSupply(1), 7);
        (address rcv, uint256 amt) = fl.royaltyInfo(1, 10_000);
        assertEq(rcv, creator);
        assertEq(amt, 250);
    }

    /// @dev Decision 3: URI event only for Pointer shards.
    function test_URIEventAsymmetry() public {
        bytes32 uriTopic = keccak256("URI(string,uint256)");

        vm.recordLogs();
        mintOnchain(creator, bytes("{}"));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != uriTopic, "no URI event for onchain mint");
        }

        vm.expectEmit(true, true, true, true);
        emit URI("ipfs://QmLoud", 2);
        mintPointer(creator, "ipfs://QmLoud");
    }

    function test_MintEventOrder_UnderReceiverReentrancy() public {
        ReentrantCreator rc = new ReentrantCreator(fl);
        vm.recordLogs();
        rc.doMint(bytes('{"name":"Reentrant"}'));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 tMinted = keccak256("TokenMinted(address,uint256,uint8,bytes32,uint256,bool)");
        bytes32 tTransfer = keccak256("TransferSingle(address,address,address,uint256,uint256)");
        bytes32 tAppended = keccak256("ShardAppended(uint256,uint256,uint8,bytes32,address)");

        uint256 iMinted = type(uint256).max;
        uint256 iTransfer = type(uint256).max;
        uint256 iAppended = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(fl)) continue;
            if (logs[i].topics[0] == tMinted && iMinted == type(uint256).max) iMinted = i;
            if (logs[i].topics[0] == tTransfer && iTransfer == type(uint256).max) iTransfer = i;
            if (logs[i].topics[0] == tAppended && iAppended == type(uint256).max) iAppended = i;
        }

        assertTrue(iMinted != type(uint256).max, "TokenMinted present");
        assertTrue(iTransfer != type(uint256).max, "TransferSingle present");
        assertTrue(iAppended != type(uint256).max, "reentrant ShardAppended present");
        assertLt(iMinted, iTransfer, "TokenMinted precedes the transfer/callback");
        assertLt(iTransfer, iAppended, "reentrant append lands after, never before");
    }

    function test_RevisionArithmeticExact() public {
        uint256 id = mintOnchain(creator, bytes("{}"));
        assertEq(fl.revisionOf(id), 0);

        vm.startPrank(creator);
        fl.appendShard(id, pointer("ipfs://Qm1")); // +1
        assertEq(fl.revisionOf(id), 1);
        fl.appendSlice(id, 0, bytes("x")); // +1
        assertEq(fl.revisionOf(id), 2);
        fl.selectShard(id, 1); // +1
        assertEq(fl.revisionOf(id), 3);
        fl.editShard(id, 1, pointer("ipfs://Qm2")); // +1
        assertEq(fl.revisionOf(id), 4);
        // Delegation changes do NOT bump revision.
        fl.setDelegate(id, delegate);
        assertEq(fl.revisionOf(id), 4);
        vm.stopPrank();
    }

    /*//////////////////////// identity & ERC165 ////////////////////////*/

    function test_NameSymbolVersion() public view {
        assertEq(fl.name(), "Forever Library V3");
        assertEq(fl.symbol(), "FLV3");
        assertEq(fl.VERSION(), "3.0.0");
    }

    function test_ContractURI() public view {
        string memory expected = string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(
                    bytes(
                        '{"name":"Forever Library V3","description":"A fully immutable, non-upgradeable NFT contract with open minting, permanent metadata, parallel storage backups, fully onchain file uploads, soulbound tokens, and per-token external renderers.","image":"data:image/svg+xml;base64,PHN2ZyB2ZXJzaW9uPSIxLjIiIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyIgdmlld0JveD0iMCAwIDEwMjQgMTAyNCIgd2lkdGg9IjEwMjQiIGhlaWdodD0iMTAyNCI+Cgk8dGl0bGU+Rm9yZXZlciBMaWJyYXJ5IFYzIEV0aGVyZXVtPC90aXRsZT4KCTxyZWN0IHdpZHRoPSIxMDI0IiBoZWlnaHQ9IjEwMjQiIGZpbGw9IiM2MjdFRUEiLz4KCTxnIGlkPSJsb2dvIj4KCQk8cGF0aCBmaWxsPSIjZmZmZmZmIiBkPSJtNjU5LjMyIDIzNS40MWMtNC4wMy0xLjQ4LTIwLjQtNS40Ni0zOC4xMi00LjYtMTcuNDggMC44NS0zNi4xNSA1LjQxLTQ1LjU0IDkuNjItNDcuOTUgMjEuNTQtNzIuMjEgNTEuMzgtNzYuNjIgOTEuMDNsLTIyLjE5IDIwNC42N2MtMy40MSAyLjE2LTYuODQgNC4zMy0xMC4xNSA2LjQzLTMwLjc3IDE5LjQ0LTU3LjM0IDM2LjIzLTcxLjQgNDYuODQtNjQuMjggNTAuNDgtNjYuNjggODcuNTUtNzAuMjYgMTE4Ljc2LTguMzIgNzIuNjkgNTEuNDUgODQuMTEgNTYuNyA4NC45N3YwLjA4YzAuMjkgMC4wNCAwLjQ4IDAuMDUgMC43OCAwLjA5IDMzLjc3IDMuNzUgNjMuOTQtMTUuNjMgODcuODMtNDEuODggNS4yNC01LjE3IDEwLjU4LTEwLjg4IDE2LjAzLTE3LjQ0IDMxLjAzLTM3LjM5IDQzLjI1LTgzLjQzIDQ4LjQyLTExNi40NHYtMC4wMmMyLjQtMTUuMzIgMy4yOC0yNy44NCAzLjgzLTM1LjM1di0wLjAybDguNjYtODBxLTAuNDggMC4yMy0wLjk2IDAuNDYgMC40OC0wLjIzIDAuOTYtMC40NmwwLjAzLTAuMjFjMjMuMTctMTUuNDggNDQuMjgtMzAuNDcgNTkuMzEtNDMuMTUgOS41Ny02LjAyIDE1LjkzLTE1LjY5IDE3Ljg4LTIzLjc0IDMuMDktMTIuNzMtMC44Ni0yMi40Mi01LjgxLTI4LjM2LTYuNzMtOC4wNS0yOC41LTguMjktMjEuNzEgMTguMDMgNC4wNCAxNS42NS0xLjg0IDI4LjEtNi4xNiAzNC42OS0xMS45MSA5LjMtMjYuNDYgMTkuNTktNDIuMTggMzAuMjJsMTUuOTItMTQ2Ljk1YzIuNDctMjIuMyA3LjU5LTQ1LjA3IDE2LjMtNjQuMTkgNi4xMi0xMy40NCAyMy41My0zNy40OSA1Ni4xOC0zNy40OSAyNC42NiAwIDQyLjY1IDM0LjkgMzQuNDMgNTAuMzItMTIuNzkgMjMuOTkgOC40MyAyOC44NyAxNi44NiAyMi42MiA2LjItNC42IDEyLjQ3LTEzLjEgMTIuMy0yNi4xOS0wLjExLTkuNTctNy42LTM5LjkzLTQxLjMyLTUyLjM0em0tMjA0LjU1IDUwNC41MWMtMS42NiAxNi4xMi0yMi42OSAzMC45Ni0zNC4yOCAzNS44Mi0xMi4xMiA1LjA5LTM3LjA0IDUuMDMtMzUuNDEtOC42OSAxLjY0LTEzLjczIDE2Ljk4LTE1Ni42MiAxNi45OC0xNTYuNjIgMCAwIDEuNDMtOC42IDQuNjQtMTIuOTcgMi45NS00LjAxIDYuODItOS4zOCAxMy4wMS0xMy41IDE0LTkuMzIgMzIuMTEtMjAuNzcgNTIuMDctMzMuMzkgMS4yNC0wLjc5IDIuNTItMS41OSAzLjc5LTIuMzktMC4wMyAwLTE5LjEyIDE3NS42MS0yMC44IDE5MS43NHoiLz4KCTwvZz4KPC9zdmc+Cg=="}'
                    )
                )
            )
        );
        assertEq(fl.contractURI(), expected);
    }

    function test_ERC165Surface() public view {
        assertTrue(fl.supportsInterface(0x01ffc9a7), "ERC165");
        assertTrue(fl.supportsInterface(0xd9b67a26), "ERC1155");
        assertTrue(fl.supportsInterface(0x0e89341c), "ERC1155MetadataURI");
        assertTrue(fl.supportsInterface(0x2a55205a), "ERC2981");
        assertTrue(fl.supportsInterface(0x8da5cb5b), "ERC-5313 owner()");
        assertFalse(fl.supportsInterface(0xe8a3d485), "V1's bogus ERC-7572 id dropped");
        assertFalse(fl.supportsInterface(0xffffffff));
    }

    /*//////////////////////// ether rejection ////////////////////////*/

    function test_EtherRejectedEverywhere() public {
        // On a mainnet fork the deterministic test address can hold a
        // pre-existing balance (force-fed/pre-existing ether is inert by
        // design) — the invariant is that no call path can ADD ether.
        uint256 balBefore = address(fl).balance;
        vm.deal(stranger, 1 ether);
        vm.startPrank(stranger);

        // Bare send → receive() reverts.
        (bool ok,) = address(fl).call{value: 1 wei}("");
        assertFalse(ok, "receive() rejects");

        // Unknown selector with value → fallback reverts.
        (ok,) = address(fl).call{value: 1 wei}(hex"deadbeef");
        assertFalse(ok, "fallback rejects value");

        // Unknown selector without value → fallback still reverts.
        (ok,) = address(fl).call(hex"deadbeef");
        assertFalse(ok, "fallback rejects calls");

        // Value on a real, non-payable entrypoint → reverts at dispatch.
        (ok,) = address(fl).call{value: 1 wei}(
            abi.encodeWithSelector(fl.mint.selector, onchain(bytes("{}")), uint256(1), uint96(0))
        );
        assertFalse(ok, "non-payable mint rejects value");

        vm.stopPrank();
        assertEq(address(fl).balance, balBefore, "no call path may add ether");
    }

    /*//////////////////////// nonexistent-token views ////////////////////////*/

    function test_ViewsRevertOnNonexistentToken() public {
        uint256 ghost = 999;
        bytes4 nf = ForeverLibraryV3.TokenNotFound.selector;

        vm.expectRevert(nf);
        fl.uri(ghost);
        vm.expectRevert(nf);
        fl.shardURI(ghost, 0);
        vm.expectRevert(nf);
        fl.readShardBytes(ghost, 0);
        vm.expectRevert(nf);
        fl.getShard(ghost, 0);
        vm.expectRevert(nf);
        fl.getShardRange(ghost, 0, 1);
        vm.expectRevert(nf);
        fl.shardCount(ghost);
        vm.expectRevert(nf);
        fl.selectedShardIndex(ghost);
        vm.expectRevert(nf);
        fl.isLocked(ghost);
        vm.expectRevert(nf);
        fl.delegateOf(ghost);
        vm.expectRevert(nf);
        fl.revisionOf(ghost);
        vm.expectRevert(nf);
        fl.shardEditTimeRemaining(ghost, 0);
        vm.expectRevert(nf);
        fl.getMintData(ghost);
        vm.expectRevert(nf);
        fl.totalSupply(ghost);
        vm.expectRevert(nf);
        fl.isSoulbound(ghost);
    }

    function test_TokenIdsStartAtOne() public {
        assertEq(fl.totalTokenTypes(), 0);
        uint256 id = mintOnchain(creator, bytes("{}"));
        assertEq(id, 1, "V1 EVM convention: ids start at 1");
        assertEq(fl.totalTokenTypes(), 1);
    }
}
