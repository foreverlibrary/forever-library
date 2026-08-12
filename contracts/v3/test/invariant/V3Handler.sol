// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ForeverLibraryV3} from "../../ForeverLibraryV3.sol";

/// @dev Minimal valid IExternalRenderer target for Renderer shards. Ignores
///      the token id, so it also passes the mid-mint shard-0 probe (where the
///      token briefly exists with zero shards).
contract InvariantRenderer {
    function uri(uint256) external pure returns (string memory) {
        return "ipfs://invariant-suite-renderer";
    }
}

/// @dev Stateful-fuzz handler. The suite runs with `fail_on_revert = true`,
///      so every action here RE-STATES the contract's own rules as
///      preconditions (existence, lock, authorization, the 24h window, input
///      validation) and then expects success: any disagreement between this
///      spec-in-the-handler and the contract surfaces as a failed run.
///      The probe_* functions cover the other direction — operations that
///      MUST revert — and assert the exact custom error they get.
contract V3Handler is Test {
    ForeverLibraryV3 public fl;
    InvariantRenderer public probeRenderer;

    address[3] public actors;
    address public mallory; // never authorized for anything

    /// @dev Bounds the invariant scans; also keeps campaigns fast.
    uint256 public constant MAX_TOKENS = 16;
    uint256 public constant MAX_PAYLOAD = 400;

    // ── ghost state ─────────────────────────────────────────────────────
    uint256 public ghostTokenCount;
    mapping(uint256 => address) public ghostCreator;
    mapping(uint256 => bool) public ghostSoulbound;
    mapping(uint256 => uint256) public ghostSupply;
    /// @dev Exact expected value of revisionOf — a differential counter, not
    ///      just a monotonicity witness. append/edit/slice/select bump it;
    ///      mint, lock, delegation and royalty changes must not.
    mapping(uint256 => uint256) public ghostRevision;

    struct Prov {
        bool recorded;
        address addedBy;
        uint64 timestamp;
        uint64 blockNumber;
    }
    mapping(uint256 => mapping(uint256 => Prov)) internal _prov;
    /// @dev Who appended each shard (delegate-edit authorization rule).
    mapping(uint256 => mapping(uint256 => address)) public ghostAppender;

    struct LockSnap {
        bool locked;
        uint256 shardCount;
        uint256 selected;
        uint256 revision;
        address delegate;
    }
    mapping(uint256 => LockSnap) internal _lockSnap;
    mapping(uint256 => bytes32[]) internal _lockHashes;

    constructor(ForeverLibraryV3 _fl) {
        fl = _fl;
        probeRenderer = new InvariantRenderer();
        actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
        mallory = makeAddr("mallory");
    }

    // ── ghost getters for the invariant contract ────────────────────────
    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function provAt(uint256 tokenId, uint256 shardIndex)
        external
        view
        returns (bool recorded, address addedBy, uint64 timestamp, uint64 blockNumber)
    {
        Prov storage p = _prov[tokenId][shardIndex];
        return (p.recorded, p.addedBy, p.timestamp, p.blockNumber);
    }

    function lockSnapAt(uint256 tokenId)
        external
        view
        returns (bool locked, uint256 count, uint256 selected, uint256 revision, address delegate_)
    {
        LockSnap storage s = _lockSnap[tokenId];
        return (s.locked, s.shardCount, s.selected, s.revision, s.delegate);
    }

    function lockHashCount(uint256 tokenId) external view returns (uint256) {
        return _lockHashes[tokenId].length;
    }

    function lockHashAt(uint256 tokenId, uint256 i) external view returns (bytes32) {
        return _lockHashes[tokenId][i];
    }

    // ── internal helpers ────────────────────────────────────────────────
    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _token(uint256 seed) internal view returns (uint256) {
        return bound(seed, 1, ghostTokenCount); // caller guards count > 0
    }

    function _payload(uint256 seed) internal pure returns (bytes memory data) {
        uint256 len = bound(seed, 1, MAX_PAYLOAD);
        data = new bytes(len);
        bytes32 fill = keccak256(abi.encodePacked("inv", seed));
        for (uint256 i = 0; i < len; i++) {
            data[i] = fill[i % 32];
        }
    }

    function _shardInput(uint256 kindSeed, uint256 payloadSeed)
        internal
        view
        returns (ForeverLibraryV3.ShardInput memory)
    {
        uint256 kind = bound(kindSeed, 0, 2);
        if (kind == 0) {
            return ForeverLibraryV3.ShardInput({
                kind: ForeverLibraryV3.ShardKind.Onchain,
                data: _payload(payloadSeed),
                pointerURI: "",
                renderer: address(0)
            });
        }
        if (kind == 1) {
            return ForeverLibraryV3.ShardInput({
                kind: ForeverLibraryV3.ShardKind.Pointer,
                data: "",
                pointerURI: string(abi.encodePacked("ipfs://inv/", vm.toString(payloadSeed))),
                renderer: address(0)
            });
        }
        return ForeverLibraryV3.ShardInput({
            kind: ForeverLibraryV3.ShardKind.Renderer,
            data: "",
            pointerURI: "",
            renderer: address(probeRenderer)
        });
    }

    function _recordShard(uint256 tokenId, uint256 shardIndex, address appender) internal {
        ForeverLibraryV3.Shard memory s = fl.getShard(tokenId, shardIndex);
        _prov[tokenId][shardIndex] =
            Prov({recorded: true, addedBy: s.addedBy, timestamp: s.timestamp, blockNumber: s.blockNumber});
        ghostAppender[tokenId][shardIndex] = appender;
    }

    function _windowOpen(uint256 tokenId, uint256 shardIndex) internal view returns (bool) {
        return fl.shardEditTimeRemaining(tokenId, shardIndex) > 0;
    }

    // ── actions (preconditions re-state the contract's rules) ───────────

    function act_mint(uint256 actorSeed, uint256 kindSeed, uint256 payloadSeed, uint256 supplySeed, uint256 bpsSeed)
        external
    {
        if (ghostTokenCount >= MAX_TOKENS) return;
        address creator = _actor(actorSeed);
        bool soulbound = supplySeed % 5 == 0;
        uint256 supply = soulbound ? 1 : bound(supplySeed, 1, 40);
        uint96 bps = uint96(bound(bpsSeed, 0, 10_000));
        ForeverLibraryV3.ShardInput memory shard = _shardInput(kindSeed, payloadSeed);

        vm.prank(creator);
        if (soulbound) {
            fl.mintSoulbound(shard, bps);
        } else {
            fl.mint(shard, supply, bps);
        }

        uint256 tokenId = fl.totalTokenTypes();
        ghostTokenCount = tokenId;
        ghostCreator[tokenId] = creator;
        ghostSoulbound[tokenId] = soulbound;
        ghostSupply[tokenId] = supply;
        ghostRevision[tokenId] = 0; // mint does not bump revision
        _recordShard(tokenId, 0, creator);
    }

    function act_appendShard(uint256 tokenSeed, uint256 kindSeed, uint256 payloadSeed) external {
        if (ghostTokenCount == 0) return;
        uint256 tokenId = _token(tokenSeed);
        if (fl.isLocked(tokenId)) return;

        address creator = ghostCreator[tokenId];
        vm.prank(creator);
        fl.appendShard(tokenId, _shardInput(kindSeed, payloadSeed));

        uint256 idx = fl.shardCount(tokenId) - 1;
        ghostRevision[tokenId] += 1;
        _recordShard(tokenId, idx, creator);
    }

    function act_delegateAppendShard(uint256 tokenSeed, uint256 kindSeed, uint256 payloadSeed) external {
        if (ghostTokenCount == 0) return;
        uint256 tokenId = _token(tokenSeed);
        if (fl.isLocked(tokenId)) return;
        address delegate_ = fl.delegateOf(tokenId);
        if (delegate_ == address(0)) return;

        vm.prank(delegate_);
        fl.appendShard(tokenId, _shardInput(kindSeed, payloadSeed));

        uint256 idx = fl.shardCount(tokenId) - 1;
        ghostRevision[tokenId] += 1;
        _recordShard(tokenId, idx, delegate_);
    }

    /// @dev Creator may edit ANY shard within its window (including
    ///      delegate-appended ones); provenance must survive the edit.
    function act_editShard(uint256 tokenSeed, uint256 idxSeed, uint256 kindSeed, uint256 payloadSeed) external {
        if (ghostTokenCount == 0) return;
        uint256 tokenId = _token(tokenSeed);
        if (fl.isLocked(tokenId)) return;
        uint256 idx = bound(idxSeed, 0, fl.shardCount(tokenId) - 1);
        if (!_windowOpen(tokenId, idx)) return;

        vm.prank(ghostCreator[tokenId]);
        fl.editShard(tokenId, idx, _shardInput(kindSeed, payloadSeed));
        ghostRevision[tokenId] += 1;
        // provenance and appender deliberately NOT re-recorded: the invariant
        // asserts the chain still reports the original values.
    }

    /// @dev Delegate may edit only shards they appended, while still current.
    function act_delegateEditShard(uint256 tokenSeed, uint256 idxSeed, uint256 kindSeed, uint256 payloadSeed)
        external
    {
        if (ghostTokenCount == 0) return;
        uint256 tokenId = _token(tokenSeed);
        if (fl.isLocked(tokenId)) return;
        address delegate_ = fl.delegateOf(tokenId);
        if (delegate_ == address(0)) return;
        uint256 idx = bound(idxSeed, 0, fl.shardCount(tokenId) - 1);
        if (ghostAppender[tokenId][idx] != delegate_) return;
        if (!_windowOpen(tokenId, idx)) return;

        vm.prank(delegate_);
        fl.editShard(tokenId, idx, _shardInput(kindSeed, payloadSeed));
        ghostRevision[tokenId] += 1;
    }

    function act_appendSlice(uint256 tokenSeed, uint256 idxSeed, uint256 payloadSeed) external {
        if (ghostTokenCount == 0) return;
        uint256 tokenId = _token(tokenSeed);
        if (fl.isLocked(tokenId)) return;
        uint256 idx = bound(idxSeed, 0, fl.shardCount(tokenId) - 1);
        ForeverLibraryV3.Shard memory s = fl.getShard(tokenId, idx);
        if (s.kind != ForeverLibraryV3.ShardKind.Onchain) return;
        if (!_windowOpen(tokenId, idx)) return;

        vm.prank(ghostCreator[tokenId]);
        fl.appendSlice(tokenId, idx, _payload(payloadSeed));
        ghostRevision[tokenId] += 1;
    }

    function act_selectShard(uint256 tokenSeed, uint256 idxSeed) external {
        if (ghostTokenCount == 0) return;
        uint256 tokenId = _token(tokenSeed);
        if (fl.isLocked(tokenId)) return;
        uint256 idx = bound(idxSeed, 0, fl.shardCount(tokenId) - 1);

        vm.prank(ghostCreator[tokenId]);
        fl.selectShard(tokenId, idx);
        ghostRevision[tokenId] += 1;
    }

    function act_setDelegate(uint256 tokenSeed, uint256 delegateSeed) external {
        if (ghostTokenCount == 0) return;
        uint256 tokenId = _token(tokenSeed);
        if (fl.isLocked(tokenId)) return;
        address creator = ghostCreator[tokenId];
        // revoke sometimes, otherwise any actor except the creator
        // (SelfDelegation) — and NEVER mallory, who must stay unauthorized
        // for the stranger probes to stay sound.
        address newDelegate = delegateSeed % 4 == 0 ? address(0) : _actor(delegateSeed);
        if (newDelegate == creator) {
            newDelegate = actors[(bound(delegateSeed, 0, actors.length - 1) + 1) % actors.length];
        }

        vm.prank(creator);
        fl.setDelegate(tokenId, newDelegate);
        // setDelegate must NOT bump revision (the L-1 lock procedure depends
        // on revocation being revision-neutral) — ghost deliberately untouched.
    }

    function act_lockShards(uint256 tokenSeed) external {
        if (ghostTokenCount == 0) return;
        uint256 tokenId = _token(tokenSeed);
        if (fl.isLocked(tokenId)) return;

        uint256 selected = fl.selectedShardIndex(tokenId);
        uint256 count = fl.shardCount(tokenId);
        uint256 revision = fl.revisionOf(tokenId);
        bytes32 hash_ = fl.getShard(tokenId, selected).metadataHash;

        vm.prank(ghostCreator[tokenId]);
        fl.lockShards(
            tokenId,
            ForeverLibraryV3.LockGuard({
                expectedSelected: selected,
                expectedHash: hash_,
                expectedShardCount: count,
                expectedRevision: revision
            })
        );

        LockSnap storage snap = _lockSnap[tokenId];
        snap.locked = true;
        snap.shardCount = count;
        snap.selected = selected;
        snap.revision = revision; // lock itself must not bump revision
        snap.delegate = fl.delegateOf(tokenId);
        delete _lockHashes[tokenId];
        for (uint256 i = 0; i < count; i++) {
            _lockHashes[tokenId].push(fl.getShard(tokenId, i).metadataHash);
        }
    }

    /// @dev Royalty stays creator-mutable forever, INCLUDING after lock.
    function act_updateRoyalty(uint256 tokenSeed, uint256 receiverSeed, uint256 bpsSeed) external {
        if (ghostTokenCount == 0) return;
        uint256 tokenId = _token(tokenSeed);

        vm.prank(ghostCreator[tokenId]);
        fl.updateTokenRoyalty(tokenId, _actor(receiverSeed), uint96(bound(bpsSeed, 0, 10_000)));
        // must NOT bump revision — ghost untouched.
    }

    function act_transfer(uint256 tokenSeed, uint256 toSeed, uint256 amountSeed) external {
        if (ghostTokenCount == 0) return;
        uint256 tokenId = _token(tokenSeed);
        if (ghostSoulbound[tokenId]) return; // covered by probe_soulboundCannotMove

        address from;
        uint256 first = bound(tokenSeed, 0, actors.length - 1);
        for (uint256 i = 0; i < actors.length; i++) {
            address candidate = actors[(first + i) % actors.length];
            if (fl.balanceOf(candidate, tokenId) > 0) {
                from = candidate;
                break;
            }
        }
        if (from == address(0)) return;
        uint256 amount = bound(amountSeed, 1, fl.balanceOf(from, tokenId));

        vm.prank(from);
        fl.safeTransferFrom(from, _actor(toSeed), tokenId, amount, "");
    }

    function act_warp(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 30 minutes, 26 hours));
        vm.roll(block.number + bound(seed >> 128, 1, 7000));
    }

    // ── probes: operations that MUST revert, with the exact error ───────

    function probe_lockedRejectsMutations(uint256 tokenSeed, uint256 opSeed, uint256 payloadSeed) external {
        uint256 tokenId = _lockedToken(tokenSeed);
        if (tokenId == 0) return;
        address creator = ghostCreator[tokenId];
        uint256 op = bound(opSeed, 0, 4);
        bytes4 expected = ForeverLibraryV3.ShardsAreLocked.selector;

        vm.prank(creator);
        if (op == 0) {
            try fl.appendShard(tokenId, _shardInput(payloadSeed, payloadSeed)) {
                fail();
            } catch (bytes memory err) {
                assertEq(bytes4(err), expected, "locked appendShard: wrong error");
            }
        } else if (op == 1) {
            try fl.editShard(tokenId, 0, _shardInput(payloadSeed, payloadSeed)) {
                fail();
            } catch (bytes memory err) {
                assertEq(bytes4(err), expected, "locked editShard: wrong error");
            }
        } else if (op == 2) {
            try fl.appendSlice(tokenId, 0, _payload(payloadSeed)) {
                fail();
            } catch (bytes memory err) {
                assertEq(bytes4(err), expected, "locked appendSlice: wrong error");
            }
        } else if (op == 3) {
            try fl.selectShard(tokenId, 0) {
                fail();
            } catch (bytes memory err) {
                assertEq(bytes4(err), expected, "locked selectShard: wrong error");
            }
        } else {
            try fl.setDelegate(tokenId, mallory) {
                fail();
            } catch (bytes memory err) {
                assertEq(bytes4(err), expected, "locked setDelegate: wrong error");
            }
        }
    }

    function probe_strangerCannotMutate(uint256 tokenSeed, uint256 opSeed, uint256 payloadSeed) external {
        if (ghostTokenCount == 0) return;
        uint256 tokenId = _token(tokenSeed);
        bool locked = fl.isLocked(tokenId);
        uint256 op = bound(opSeed, 0, 3);

        vm.prank(mallory);
        if (op == 0) {
            // guard order: locked precedes auth
            try fl.appendShard(tokenId, _shardInput(payloadSeed, payloadSeed)) {
                fail();
            } catch (bytes memory err) {
                assertEq(
                    bytes4(err),
                    locked ? ForeverLibraryV3.ShardsAreLocked.selector : ForeverLibraryV3.NotAuthorized.selector,
                    "stranger appendShard: wrong error"
                );
            }
        } else if (op == 1) {
            try fl.lockShards(
                tokenId,
                ForeverLibraryV3.LockGuard({
                    expectedSelected: 0,
                    expectedHash: bytes32(0),
                    expectedShardCount: 1,
                    expectedRevision: 0
                })
            ) {
                fail();
            } catch (bytes memory err) {
                assertEq(
                    bytes4(err),
                    locked ? ForeverLibraryV3.ShardsAreLocked.selector : ForeverLibraryV3.NotTokenCreator.selector,
                    "stranger lockShards: wrong error"
                );
            }
        } else if (op == 2) {
            try fl.setDelegate(tokenId, mallory) {
                fail();
            } catch (bytes memory err) {
                // SelfDelegation is unreachable: mallory is never a creator
                assertEq(
                    bytes4(err),
                    locked ? ForeverLibraryV3.ShardsAreLocked.selector : ForeverLibraryV3.NotTokenCreator.selector,
                    "stranger setDelegate: wrong error"
                );
            }
        } else {
            // updateTokenRoyalty has NO lock gate — always NotTokenCreator
            try fl.updateTokenRoyalty(tokenId, mallory, 100) {
                fail();
            } catch (bytes memory err) {
                assertEq(
                    bytes4(err), ForeverLibraryV3.NotTokenCreator.selector, "stranger updateRoyalty: wrong error"
                );
            }
        }
    }

    function probe_soulboundCannotMove(uint256 tokenSeed, uint256 toSeed) external {
        uint256 tokenId = _soulboundToken(tokenSeed);
        if (tokenId == 0) return;
        address creator = ghostCreator[tokenId];

        vm.prank(creator);
        try fl.safeTransferFrom(creator, _actor(toSeed), tokenId, 1, "") {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), ForeverLibraryV3.TokenIsSoulbound.selector, "soulbound transfer: wrong error");
        }
    }

    function probe_windowClosedRejectsEdit(uint256 tokenSeed, uint256 payloadSeed) external {
        if (ghostTokenCount == 0) return;
        uint256 tokenId = _token(tokenSeed);
        if (fl.isLocked(tokenId)) return;
        // find a shard whose window has closed
        uint256 count = fl.shardCount(tokenId);
        for (uint256 i = 0; i < count; i++) {
            if (fl.shardEditTimeRemaining(tokenId, i) == 0) {
                vm.prank(ghostCreator[tokenId]);
                try fl.editShard(tokenId, i, _shardInput(payloadSeed, payloadSeed)) {
                    fail();
                } catch (bytes memory err) {
                    assertEq(
                        bytes4(err),
                        ForeverLibraryV3.ShardEditWindowClosed.selector,
                        "closed-window edit: wrong error"
                    );
                }
                return;
            }
        }
    }

    // ── probe helpers ────────────────────────────────────────────────────
    function _lockedToken(uint256 seed) internal view returns (uint256) {
        if (ghostTokenCount == 0) return 0;
        uint256 start = bound(seed, 1, ghostTokenCount);
        for (uint256 i = 0; i < ghostTokenCount; i++) {
            uint256 t = ((start + i - 1) % ghostTokenCount) + 1;
            if (_lockSnap[t].locked) return t;
        }
        return 0;
    }

    function _soulboundToken(uint256 seed) internal view returns (uint256) {
        if (ghostTokenCount == 0) return 0;
        uint256 start = bound(seed, 1, ghostTokenCount);
        for (uint256 i = 0; i < ghostTokenCount; i++) {
            uint256 t = ((start + i - 1) % ghostTokenCount) + 1;
            if (ghostSoulbound[t]) return t;
        }
        return 0;
    }
}
