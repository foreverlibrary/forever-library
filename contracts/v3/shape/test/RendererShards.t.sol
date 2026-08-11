// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {V3TestBase, ForeverLibraryV3} from "./V3TestBase.sol";

/// @dev Decision 8: per-token external renderers as an ordinary shard
///      kind. Window-governed binding, set-time probe, direct call with
///      honest revert, shard 0 always static, recovery via the sharding
///      system itself (append replacement, re-select).

contract HealthyRenderer {
    string internal output;

    constructor(string memory o) {
        output = o;
    }

    function uri(uint256) external view returns (string memory) {
        return output;
    }
}

contract BreakableRenderer {
    string internal output;
    bool public broken;

    constructor(string memory o) {
        output = o;
    }

    function breakIt() external {
        broken = true;
    }

    function uri(uint256) external view returns (string memory) {
        require(!broken, "renderer dead");
        return output;
    }
}

contract RevertingRenderer {
    function uri(uint256) external pure returns (string memory) {
        revert("always broken");
    }
}

contract EmptyRenderer {
    function uri(uint256) external pure returns (string memory) {
        return "";
    }
}

/// @dev Passes the set-time probe (non-empty) but returns "" afterward —
///      exercises the L-4 read-time honest revert.
contract GoesEmptyRenderer {
    bool public empty;

    function goEmpty() external {
        empty = true;
    }

    function uri(uint256) external view returns (string memory) {
        return empty ? "" : "data:application/json;base64,aGVsbG8=";
    }
}

/// @dev Returns 32 bytes — too short to be an ABI-encoded string. Must yield
///      RendererProbeFailed (L-7), never an abi.decode Panic.
contract ShortReturnRenderer {
    function uri(uint256) external pure returns (string memory) {
        assembly {
            mstore(0, 0xdead)
            return(0, 32)
        }
    }
}

/// @dev Returns 64 bytes with a non-canonical offset word (0x40, not 0x20).
///      Must yield RendererProbeFailed (L-7), never a Panic.
contract BadOffsetRenderer {
    function uri(uint256) external pure returns (string memory) {
        assembly {
            mstore(0, 0x40)
            mstore(0x20, 0)
            return(0, 64)
        }
    }
}

/// @dev Attempts a state change during the probe; the probe's staticcall
///      context must make this fail at set time.
contract StateChangingRenderer {
    ForeverLibraryV3 internal fl;

    constructor(ForeverLibraryV3 fl_) {
        fl = fl_;
    }

    function uri(uint256 tokenId) external returns (string memory) {
        fl.selectShard(tokenId, 0);
        return "never reached";
    }
}

/// @dev The V3-aware composition pattern: renders from the token's own
///      static shards. Impossible in V1 (renderers saw one URI string).
contract CompositeRenderer {
    ForeverLibraryV3 internal fl;

    constructor(ForeverLibraryV3 fl_) {
        fl = fl_;
    }

    function uri(uint256 tokenId) external view returns (string memory) {
        return string(abi.encodePacked("composed:", fl.readShardBytes(tokenId, 0)));
    }
}

contract RendererShardsTest is V3TestBase {
    uint256 internal id;
    HealthyRenderer internal healthy;

    function setUp() public override {
        super.setUp();
        id = mintOnchain(creator, bytes('{"name":"Genesis"}'));
        healthy = new HealthyRenderer("data:application/json;base64,rendered");
    }

    /*//////////////////////// happy path ////////////////////////*/

    function test_AppendSelectServe() public {
        vm.expectEmit(true, true, true, true);
        emit ShardAppended(
            id,
            1,
            ForeverLibraryV3.ShardKind.Renderer,
            keccak256(abi.encodePacked(address(healthy))),
            creator
        );
        vm.prank(creator);
        fl.appendShard(id, rendererInput(address(healthy)));

        ForeverLibraryV3.Shard memory s = fl.getShard(id, 1);
        assertEq(uint8(s.kind), uint8(ForeverLibraryV3.ShardKind.Renderer));
        assertEq(s.renderer, address(healthy));
        assertEq(s.metadataHash, keccak256(abi.encodePacked(address(healthy))));
        assertEq(s.addedBy, creator);

        vm.prank(creator);
        fl.selectShard(id, 1);
        assertEq(fl.uri(id), "data:application/json;base64,rendered");
        assertEq(fl.shardURI(id, 1), "data:application/json;base64,rendered");

        // The genesis artifact is untouched and still resolvable.
        assertEq(fl.readShardBytes(id, 0), bytes('{"name":"Genesis"}'));
    }

    function test_CompositeRendererReadsOwnShards() public {
        CompositeRenderer comp = new CompositeRenderer(fl);
        vm.startPrank(creator);
        fl.appendShard(id, rendererInput(address(comp)));
        fl.selectShard(id, 1);
        vm.stopPrank();
        assertEq(fl.uri(id), 'composed:{"name":"Genesis"}');
    }

    /*//////////////////////// shard 0 may be any kind (decision 8 revised) ////////////////////////*/

    /// @dev A token can be minted directly into renderer mode — shard 0 is a
    ///      Renderer, no static content (V1 blank-URI parity). The probe still
    ///      runs at mint, so the address must answer at bind time.
    function test_MintRendererShard0Serves() public {
        vm.prank(creator);
        fl.mint(rendererInput(address(healthy)), 5, 0);
        uint256 t = fl.totalTokenTypes();

        ForeverLibraryV3.Shard memory s = fl.getShard(t, 0);
        assertEq(uint8(s.kind), uint8(ForeverLibraryV3.ShardKind.Renderer));
        assertEq(s.renderer, address(healthy));
        assertEq(s.metadataHash, keccak256(abi.encodePacked(address(healthy))));
        assertEq(fl.uri(t), "data:application/json;base64,rendered");
        // No static content exists — readShardBytes rejects it.
        vm.expectRevert(ForeverLibraryV3.NotOnchainShard.selector);
        fl.readShardBytes(t, 0);
    }

    function test_MintSoulboundRendererShard0() public {
        vm.prank(creator);
        fl.mintSoulbound(rendererInput(address(healthy)), 0);
        uint256 t = fl.totalTokenTypes();
        assertTrue(fl.isSoulbound(t));
        assertEq(fl.uri(t), "data:application/json;base64,rendered");
    }

    /// @dev A renderer as shard 0 must still pass the set-time probe.
    function test_MintRendererShard0RejectsBadRenderer() public {
        RevertingRenderer bad = new RevertingRenderer();
        vm.expectRevert(ForeverLibraryV3.RendererProbeFailed.selector);
        vm.prank(creator);
        fl.mint(rendererInput(address(bad)), 1, 0);

        // ...and cannot be the contract itself (L-B self-reference guard).
        vm.expectRevert(ForeverLibraryV3.RendererProbeFailed.selector);
        vm.prank(creator);
        fl.mint(rendererInput(address(fl)), 1, 0);
    }

    /// @dev Shard 0 can be converted to a renderer within its window, and back.
    function test_EditShard0ToRendererAndBack() public {
        vm.startPrank(creator);
        fl.editShard(id, 0, rendererInput(address(healthy)));
        ForeverLibraryV3.Shard memory s = fl.getShard(id, 0);
        assertEq(uint8(s.kind), uint8(ForeverLibraryV3.ShardKind.Renderer));
        assertEq(s.renderer, address(healthy));
        assertEq(fl.uri(id), "data:application/json;base64,rendered");

        // Convert shard 0 back to static; renderer binding cleared.
        fl.editShard(id, 0, onchain(bytes('{"name":"BackToStatic"}')));
        s = fl.getShard(id, 0);
        assertEq(uint8(s.kind), uint8(ForeverLibraryV3.ShardKind.Onchain));
        assertEq(s.renderer, address(0));
        assertEq(fl.readShardBytes(id, 0), bytes('{"name":"BackToStatic"}'));
        vm.stopPrank();
    }

    /// @dev Renderer-only token, locked, then broken: uri() reverts forever
    ///      with no fallback — the creator's accepted choice under the revised
    ///      decision 8 (same class as a locked Pointer to unpinned content).
    function test_LockedRendererOnlyTokenHasNoFallback() public {
        BreakableRenderer r = new BreakableRenderer("only content");
        vm.prank(creator);
        fl.mint(rendererInput(address(r)), 1, 0);
        uint256 t = fl.totalTokenTypes();
        lockNow(creator, t);
        assertEq(fl.uri(t), "only content");

        r.breakIt();
        vm.expectRevert(bytes("renderer dead"));
        fl.uri(t);
        // No static shard exists to fall back to.
        vm.expectRevert(ForeverLibraryV3.NotOnchainShard.selector);
        fl.readShardBytes(t, 0);
    }

    /*//////////////////////// validation & probe ////////////////////////*/

    function test_ValidationMatrix_RendererKind() public {
        vm.startPrank(creator);

        // Zero address = empty payload.
        vm.expectRevert(ForeverLibraryV3.EmptyPayload.selector);
        fl.appendShard(id, rendererInput(address(0)));

        // Renderer kind with data smuggled in.
        ForeverLibraryV3.ShardInput memory bad = rendererInput(address(healthy));
        bad.data = bytes("{}");
        vm.expectRevert(ForeverLibraryV3.InvalidShardInput.selector);
        fl.appendShard(id, bad);

        // Renderer kind with pointerURI smuggled in.
        bad = rendererInput(address(healthy));
        bad.pointerURI = "ipfs://QmSmuggled";
        vm.expectRevert(ForeverLibraryV3.InvalidShardInput.selector);
        fl.appendShard(id, bad);

        // Renderer address smuggled into the static kinds.
        bad = onchain(bytes("{}"));
        bad.renderer = address(healthy);
        vm.expectRevert(ForeverLibraryV3.InvalidShardInput.selector);
        fl.appendShard(id, bad);

        bad = pointer("ipfs://QmOk");
        bad.renderer = address(healthy);
        vm.expectRevert(ForeverLibraryV3.InvalidShardInput.selector);
        fl.appendShard(id, bad);

        vm.stopPrank();
    }

    function test_ProbeRejectsNonContract() public {
        // makeAddr derives from a publicly-known key; on live-chain forks
        // such addresses can carry EIP-7702 delegations (observed on Base:
        // 0xef0100... designator, 23 bytes of code). Force code-free so
        // this always exercises the no-code rejection path.
        address eoa = makeAddr("eoa");
        vm.etch(eoa, "");
        vm.expectRevert(ForeverLibraryV3.RendererNotContract.selector);
        vm.prank(creator);
        fl.appendShard(id, rendererInput(eoa));
    }

    /// @dev L-B: a renderer bound to the contract itself would pass a naive
    ///      probe (it resolves the selected static shard) but recurse to gas
    ///      exhaustion once selected. Rejected at bind time.
    function test_ProbeRejectsSelfReference() public {
        vm.expectRevert(ForeverLibraryV3.RendererProbeFailed.selector);
        vm.prank(creator);
        fl.appendShard(id, rendererInput(address(fl)));

        // Same guard on the editShard renderer path.
        vm.prank(creator);
        fl.appendShard(id, pointer("ipfs://QmStatic"));
        vm.expectRevert(ForeverLibraryV3.RendererProbeFailed.selector);
        vm.prank(creator);
        fl.editShard(id, 1, rendererInput(address(fl)));
    }

    function test_ProbeRejectsRevertingRenderer() public {
        RevertingRenderer r = new RevertingRenderer();
        vm.expectRevert(ForeverLibraryV3.RendererProbeFailed.selector);
        vm.prank(creator);
        fl.appendShard(id, rendererInput(address(r)));
    }

    function test_ProbeRejectsEmptyOutput() public {
        EmptyRenderer r = new EmptyRenderer();
        vm.expectRevert(ForeverLibraryV3.RendererProbeFailed.selector);
        vm.prank(creator);
        fl.appendShard(id, rendererInput(address(r)));
    }

    /// @dev L-7: malformed returns fail cleanly with RendererProbeFailed,
    ///      not an abi.decode Panic.
    function test_ProbeRejectsShortReturn() public {
        ShortReturnRenderer r = new ShortReturnRenderer();
        vm.expectRevert(ForeverLibraryV3.RendererProbeFailed.selector);
        vm.prank(creator);
        fl.appendShard(id, rendererInput(address(r)));
    }

    function test_ProbeRejectsBadOffsetReturn() public {
        BadOffsetRenderer r = new BadOffsetRenderer();
        vm.expectRevert(ForeverLibraryV3.RendererProbeFailed.selector);
        vm.prank(creator);
        fl.appendShard(id, rendererInput(address(r)));
    }

    /// @dev L-4: a renderer that passes the probe then returns "" makes
    ///      uri() revert honestly (RendererReturnedEmpty) instead of serving
    ///      an empty string. Static content stays readable; recovery is the
    ///      usual append-a-replacement.
    function test_ReadTimeEmptyRevertsHonestly() public {
        GoesEmptyRenderer r = new GoesEmptyRenderer();
        vm.startPrank(creator);
        fl.appendShard(id, rendererInput(address(r)));
        fl.selectShard(id, 1);
        vm.stopPrank();
        assertEq(fl.uri(id), "data:application/json;base64,aGVsbG8=");

        r.goEmpty();
        vm.expectRevert(ForeverLibraryV3.RendererReturnedEmpty.selector);
        fl.uri(id);
        vm.expectRevert(ForeverLibraryV3.RendererReturnedEmpty.selector);
        fl.shardURI(id, 1);

        // Genesis artifact unaffected; recover by appending a healthy renderer.
        assertEq(fl.readShardBytes(id, 0), bytes('{"name":"Genesis"}'));
        vm.startPrank(creator);
        fl.appendShard(id, rendererInput(address(healthy)));
        fl.selectShard(id, 2);
        vm.stopPrank();
        assertEq(fl.uri(id), "data:application/json;base64,rendered");
    }

    function test_ProbeRejectsStateChangingRenderer() public {
        StateChangingRenderer r = new StateChangingRenderer(fl);
        vm.expectRevert(ForeverLibraryV3.RendererProbeFailed.selector);
        vm.prank(creator);
        fl.appendShard(id, rendererInput(address(r)));
    }

    /*//////////////////////// window governs the binding ////////////////////////*/

    function test_RendererEditWindowBoundary() public {
        uint256 t0 = block.timestamp;
        vm.prank(creator);
        fl.appendShard(id, rendererInput(address(healthy)));

        // Rebind within the shard's own window: allowed.
        HealthyRenderer second = new HealthyRenderer("v2 output");
        vm.warp(t0 + 86_399);
        vm.prank(creator);
        fl.editShard(id, 1, rendererInput(address(second)));
        assertEq(fl.getShard(id, 1).renderer, address(second));

        // At exactly +24h the binding is frozen (V1 parity, exclusive).
        vm.warp(t0 + 86_400);
        vm.expectRevert(ForeverLibraryV3.ShardEditWindowClosed.selector);
        vm.prank(creator);
        fl.editShard(id, 1, rendererInput(address(healthy)));
    }

    function test_KindConversionBothWaysAboveShard0() public {
        vm.startPrank(creator);
        fl.appendShard(id, pointer("ipfs://QmStatic"));

        // Static → renderer within window; pointer payload cleared.
        fl.editShard(id, 1, rendererInput(address(healthy)));
        ForeverLibraryV3.Shard memory s = fl.getShard(id, 1);
        assertEq(uint8(s.kind), uint8(ForeverLibraryV3.ShardKind.Renderer));
        assertEq(s.pointerURI, "");
        assertEq(s.renderer, address(healthy));

        // Renderer → static within window; renderer binding cleared.
        fl.editShard(id, 1, pointer("ar://back-to-static"));
        s = fl.getShard(id, 1);
        assertEq(uint8(s.kind), uint8(ForeverLibraryV3.ShardKind.Pointer));
        assertEq(s.renderer, address(0));
        assertEq(fl.shardURI(id, 1), "ar://back-to-static");
        vm.stopPrank();
    }

    /*//////////////////////// honest failure & recovery ////////////////////////*/

    function test_BrokenRendererRevertsAndShardingRecovers() public {
        BreakableRenderer r = new BreakableRenderer("alive");
        vm.startPrank(creator);
        fl.appendShard(id, rendererInput(address(r)));
        fl.selectShard(id, 1);
        vm.stopPrank();
        assertEq(fl.uri(id), "alive");

        // Renderer breaks after being set: uri() reverts honestly.
        r.breakIt();
        vm.expectRevert(bytes("renderer dead"));
        fl.uri(id);

        // Static content is unaffected — the preservation invariant never
        // depended on the renderer.
        assertEq(fl.shardURI(id, 0), fl.shardURI(id, 0)); // resolves, no revert
        assertEq(fl.readShardBytes(id, 0), bytes('{"name":"Genesis"}'));

        // Recovery is the sharding system: append a replacement, select.
        // (Works past the broken shard's window — appends are never
        // window-gated, selection is never window-gated.)
        vm.warp(block.timestamp + 48 hours);
        vm.startPrank(creator);
        fl.appendShard(id, rendererInput(address(healthy)));
        fl.selectShard(id, 2);
        vm.stopPrank();
        assertEq(fl.uri(id), "data:application/json;base64,rendered");
    }

    function test_PostLockBrokenRendererIsAcceptedTradeoff() public {
        BreakableRenderer r = new BreakableRenderer("locked output");
        vm.startPrank(creator);
        fl.appendShard(id, rendererInput(address(r)));
        fl.selectShard(id, 1);
        vm.stopPrank();
        lockNow(creator, id);

        assertEq(fl.uri(id), "locked output");

        // Post-lock breakage: uri() reverts, selection is immutable — the
        // creator locked a code binding and that commitment stands.
        r.breakIt();
        vm.expectRevert(bytes("renderer dead"));
        fl.uri(id);
        vm.expectRevert(ForeverLibraryV3.ShardsAreLocked.selector);
        vm.prank(creator);
        fl.selectShard(id, 0);

        // The genesis artifact remains retrievable forever.
        assertEq(fl.readShardBytes(id, 0), bytes('{"name":"Genesis"}'));
    }

    /*//////////////////////// existing machinery applies ////////////////////////*/

    function test_DelegateRendererShardRules() public {
        vm.prank(creator);
        fl.setDelegate(id, delegate);

        // Delegate appends and rebinds their own renderer shard.
        vm.prank(delegate);
        fl.appendShard(id, rendererInput(address(healthy)));
        HealthyRenderer second = new HealthyRenderer("delegate v2");
        vm.prank(delegate);
        fl.editShard(id, 1, rendererInput(address(second)));

        // Creator override still applies.
        vm.prank(creator);
        fl.editShard(id, 1, rendererInput(address(healthy)));

        // Another party cannot touch it; revoked delegate loses access.
        vm.expectRevert(ForeverLibraryV3.NotAuthorized.selector);
        vm.prank(stranger);
        fl.editShard(id, 1, rendererInput(address(second)));

        vm.prank(creator);
        fl.setDelegate(id, address(0));
        vm.expectRevert(ForeverLibraryV3.NotAuthorized.selector);
        vm.prank(delegate);
        fl.editShard(id, 1, rendererInput(address(second)));
    }

    function test_SliceAndBytesRejectRendererShard() public {
        vm.startPrank(creator);
        fl.appendShard(id, rendererInput(address(healthy)));

        vm.expectRevert(ForeverLibraryV3.NotOnchainShard.selector);
        fl.appendSlice(id, 1, bytes("x"));
        vm.stopPrank();

        vm.expectRevert(ForeverLibraryV3.NotOnchainShard.selector);
        fl.readShardBytes(id, 1);
    }

    /// @dev URI event asymmetry extends to renderers: like Onchain
    ///      (decision 3), no URI event — the payload is dynamic and
    ///      unbounded. ShardSelected/ShardAppended carry the hash.
    function test_NoURIEventForRendererShards() public {
        bytes32 uriTopic = keccak256("URI(string,uint256)");
        bytes32 selectedTopic = keccak256("ShardSelected(uint256,uint256,address)");

        vm.startPrank(creator);
        fl.appendShard(id, rendererInput(address(healthy)));
        vm.recordLogs();
        fl.selectShard(id, 1);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawSelected;
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != uriTopic, "no URI event for renderer select");
            if (logs[i].topics[0] == selectedTopic) sawSelected = true;
        }
        assertTrue(sawSelected, "ShardSelected fired");
    }

    function test_RevisionPinsRendererStateInLock() public {
        vm.prank(creator);
        fl.setDelegate(id, delegate);

        uint256 rev = fl.revisionOf(id);

        // Delegate slips a renderer shard in before the creator's lock.
        vm.prank(delegate);
        fl.appendShard(id, rendererInput(address(healthy)));

        ForeverLibraryV3.LockGuard memory g = ForeverLibraryV3.LockGuard({
            expectedSelected: 0,
            expectedHash: fl.getShard(id, 0).metadataHash,
            expectedShardCount: 1,
            expectedRevision: rev
        });
        vm.expectRevert(ForeverLibraryV3.UnexpectedShardCount.selector);
        vm.prank(creator);
        fl.lockShards(id, g);
    }
}
