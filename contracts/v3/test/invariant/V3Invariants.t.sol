// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ForeverLibraryV3} from "../../ForeverLibraryV3.sol";
import {V3Handler} from "./V3Handler.sol";

/// @dev Stateful invariants over ForeverLibraryV3's core promises. The
///      fuzzer drives random sequences of V3Handler actions (mints, edits,
///      slices, selections, locks, delegation, transfers, time warps) and
///      each invariant below must hold after EVERY step. Runs with
///      `fail_on_revert = true`: the handler re-states the contract's rules
///      as preconditions, so an unexpected revert is itself a failure.
contract V3InvariantTest is Test {
    ForeverLibraryV3 internal fl;
    V3Handler internal handler;

    function setUp() public {
        fl = new ForeverLibraryV3();
        handler = new V3Handler(fl);
        targetContract(address(handler));
    }

    /// Every id in 1..totalTokenTypes() exists exactly as the handler minted
    /// it: dense ids, non-zero creator, shard 0 present, and the mint facts
    /// (creator / soulbound / supply) never drift.
    function invariant_tokenLedgerMatchesGhost() public view {
        uint256 n = fl.totalTokenTypes();
        assertEq(n, handler.ghostTokenCount(), "token count drifted");
        for (uint256 t = 1; t <= n; t++) {
            ForeverLibraryV3.MintData memory md = fl.getMintData(t);
            assertEq(md.creator, handler.ghostCreator(t), "creator drifted");
            assertEq(md.soulbound, handler.ghostSoulbound(t), "soulbound flag drifted");
            assertEq(md.supply, handler.ghostSupply(t), "supply drifted");
            assertGe(fl.shardCount(t), 1, "shard 0 missing");
        }
    }

    /// revisionOf equals the handler's differential count exactly:
    /// append/edit/slice/select bump it by one; mint, lock, delegation and
    /// royalty changes never do.
    function invariant_revisionIsExactMutationCount() public view {
        uint256 n = fl.totalTokenTypes();
        for (uint256 t = 1; t <= n; t++) {
            assertEq(fl.revisionOf(t), handler.ghostRevision(t), "revision != mutation count");
        }
    }

    /// The selected shard index is always in range.
    function invariant_selectedShardInRange() public view {
        uint256 n = fl.totalTokenTypes();
        for (uint256 t = 1; t <= n; t++) {
            assertLt(fl.selectedShardIndex(t), fl.shardCount(t), "selected out of range");
        }
    }

    /// Lock is final: once locked, shard count, selection, revision, every
    /// shard's metadataHash, and the delegate are frozen at their lock-time
    /// values, forever.
    function invariant_lockFreezesAllShardState() public view {
        uint256 n = fl.totalTokenTypes();
        for (uint256 t = 1; t <= n; t++) {
            (bool locked, uint256 count, uint256 selected, uint256 revision, address delegate_) =
                handler.lockSnapAt(t);
            if (!locked) continue;
            assertTrue(fl.isLocked(t), "lock flag cleared");
            assertEq(fl.shardCount(t), count, "post-lock shard append");
            assertEq(fl.selectedShardIndex(t), selected, "post-lock selection change");
            assertEq(fl.revisionOf(t), revision, "post-lock revision bump");
            assertEq(fl.delegateOf(t), delegate_, "post-lock delegate change");
            for (uint256 i = 0; i < count; i++) {
                assertEq(fl.getShard(t, i).metadataHash, handler.lockHashAt(t, i), "post-lock content change");
            }
        }
    }

    /// Provenance is written once: addedBy / timestamp / blockNumber of every
    /// shard never change after append — edits included.
    function invariant_provenanceNeverRewritten() public view {
        uint256 n = fl.totalTokenTypes();
        for (uint256 t = 1; t <= n; t++) {
            uint256 count = fl.shardCount(t);
            for (uint256 i = 0; i < count; i++) {
                (bool recorded, address addedBy, uint64 ts, uint64 bn) = handler.provAt(t, i);
                assertTrue(recorded, "shard the handler never saw");
                ForeverLibraryV3.Shard memory s = fl.getShard(t, i);
                assertEq(s.addedBy, addedBy, "addedBy rewritten");
                assertEq(s.timestamp, ts, "timestamp rewritten");
                assertEq(s.blockNumber, bn, "blockNumber rewritten");
            }
        }
    }

    /// Every shard's metadataHash replays from independently-read state:
    /// Pointer hashes commit to the URI, Renderer hashes to the address, and
    /// Onchain hashes replay the rolling scheme over the SSTORE2 chunks'
    /// code (STOP prefix stripped) — the exact check an indexer performs.
    function invariant_metadataHashReplays() public view {
        uint256 n = fl.totalTokenTypes();
        for (uint256 t = 1; t <= n; t++) {
            uint256 count = fl.shardCount(t);
            for (uint256 i = 0; i < count; i++) {
                ForeverLibraryV3.Shard memory s = fl.getShard(t, i);
                if (s.kind == ForeverLibraryV3.ShardKind.Pointer) {
                    assertEq(s.metadataHash, keccak256(bytes(s.pointerURI)), "pointer hash mismatch");
                } else if (s.kind == ForeverLibraryV3.ShardKind.Renderer) {
                    assertEq(s.metadataHash, keccak256(abi.encodePacked(s.renderer)), "renderer hash mismatch");
                } else {
                    assertGt(s.chunks.length, 0, "onchain shard without chunks");
                    bytes32 h;
                    uint256 total;
                    for (uint256 c = 0; c < s.chunks.length; c++) {
                        bytes memory slice = _chunkData(s.chunks[c]);
                        total += slice.length;
                        h = c == 0 ? keccak256(slice) : keccak256(abi.encodePacked(h, slice));
                    }
                    assertEq(s.metadataHash, h, "rolling hash does not replay");
                    assertEq(uint256(s.totalBytes), total, "totalBytes != chunk bytes");
                }
            }
        }
    }

    /// Supply is conserved and immobile where promised: total balances across
    /// all participants always equal the fixed mint supply, and a soulbound
    /// token's entire supply never leaves its creator.
    function invariant_supplyConservedAndSoulboundImmobile() public view {
        uint256 n = fl.totalTokenTypes();
        for (uint256 t = 1; t <= n; t++) {
            uint256 supply = handler.ghostSupply(t);
            assertEq(fl.totalSupply(t), supply, "totalSupply drifted");
            uint256 sum;
            for (uint256 a = 0; a < 3; a++) {
                sum += fl.balanceOf(handler.actorAt(a), t);
            }
            sum += fl.balanceOf(handler.mallory(), t);
            assertEq(sum, supply, "balances do not sum to supply");
            if (handler.ghostSoulbound(t)) {
                assertEq(fl.balanceOf(handler.ghostCreator(t), t), supply, "soulbound token moved");
            }
        }
    }

    /// ERC-2981 royalties never exceed the sale price (bps hard-capped at
    /// 10000 on every path).
    function invariant_royaltyNeverExceedsSale() public view {
        uint256 n = fl.totalTokenTypes();
        for (uint256 t = 1; t <= n; t++) {
            (, uint256 amount) = fl.royaltyInfo(t, 1 ether);
            assertLe(amount, 1 ether, "royalty exceeds sale price");
        }
    }

    /// @dev Chunk runtime code minus the 0x00 STOP prefix.
    function _chunkData(address chunk) internal view returns (bytes memory data) {
        bytes memory code = chunk.code;
        require(code.length >= 1, "empty chunk");
        data = new bytes(code.length - 1);
        for (uint256 i = 0; i < data.length; i++) {
            data[i] = code[i + 1];
        }
    }
}
