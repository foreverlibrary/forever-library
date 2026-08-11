// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {V3TestBase, ForeverLibraryV3} from "./V3TestBase.sol";

contract TrivialRenderer {
    function uri(uint256) external pure returns (string memory) {
        return "data:application/json;base64,c29tZSBzbWFsbCByZW5kZXJlZCBvdXRwdXQ=";
    }
}

/// @dev Open-work item 3: gas measurement. Skipped by default so the fast
///      suite stays fast; run with:
///          FL_GAS=true forge test --match-contract GasMeasurement -vv
///
///      Numbers are EXECUTION gas measured around an external call from
///      the test contract (includes the CALL hop, ~2.6k). Transaction-
///      level writes add 21k intrinsic + calldata (~16/byte non-zero).
///      Reads are staticcalls without binding returndata, approximating a
///      top-level eth_call.
contract GasMeasurementTest is V3TestBase {
    bool internal runGas;

    function setUp() public override {
        super.setUp();
        runGas = vm.envOr("FL_GAS", false);
    }

    function _writeGas(bytes memory cd) internal returns (uint256 used) {
        vm.prank(creator);
        uint256 g0 = gasleft();
        (bool ok,) = address(fl).call(cd);
        used = g0 - gasleft();
        require(ok, "write failed");
    }

    function _readGas(bytes memory cd) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        (bool ok,) = address(fl).staticcall(cd);
        used = g0 - gasleft();
        require(ok, "read failed");
    }

    function _growTo(uint256 tokenId, uint256 targetBytes) internal {
        uint256 current = fl.getShard(tokenId, 0).totalBytes;
        while (current < targetBytes) {
            uint256 n = targetBytes - current;
            if (n > 24_575) n = 24_575;
            vm.prank(creator);
            fl.appendSlice(tokenId, 0, new bytes(n));
            current += n;
        }
    }

    function test_Gas_Writes() public {
        vm.skip(!runGas);

        console2.log("=== writes (execution gas; tx adds 21k + calldata) ===");

        uint256 g = _writeGas(
            abi.encodeWithSelector(fl.mint.selector, pointer("ipfs://QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco"), uint256(10), uint96(500))
        );
        console2.log("mint Pointer (52B URI):", g);

        g = _writeGas(abi.encodeWithSelector(fl.mint.selector, onchain(new bytes(1_024)), uint256(10), uint96(500)));
        console2.log("mint Onchain 1,024 B:", g);

        g = _writeGas(abi.encodeWithSelector(fl.mint.selector, onchain(new bytes(24_575)), uint256(10), uint96(500)));
        console2.log("mint Onchain 24,575 B (max single slice):", g);

        uint256 id = fl.totalTokenTypes();

        g = _writeGas(abi.encodeWithSelector(fl.appendShard.selector, id, pointer("ar://some-arweave-tx-id-of-typical-length-here")));
        console2.log("appendShard Pointer:", g);

        TrivialRenderer r = new TrivialRenderer();
        g = _writeGas(abi.encodeWithSelector(fl.appendShard.selector, id, rendererInput(address(r))));
        console2.log("appendShard Renderer (incl. probe):", g);

        console2.log("--- appendSlice ladder (marginal rate check) ---");
        uint256[6] memory sizes = [uint256(256), 1_024, 4_096, 8_192, 16_384, 24_575];
        uint256[6] memory used;
        for (uint256 i = 0; i < sizes.length; i++) {
            used[i] = _writeGas(abi.encodeWithSelector(fl.appendSlice.selector, id, 0, new bytes(sizes[i])));
            console2.log("appendSlice bytes:", sizes[i]);
            console2.log("            gas:  ", used[i]);
        }

        // Marginal per-byte rate from the two largest points; the docs
        // claim ~200 gas/byte for SSTORE2 (deposit) + copy overhead.
        uint256 marginal = (used[5] - used[4]) * 1000 / (sizes[5] - sizes[4]);
        console2.log("marginal milli-gas/byte (16,384 -> 24,575):", marginal);
        assertGt(marginal, 150_000, "per-byte rate implausibly low");
        assertLt(marginal, 300_000, "per-byte rate implausibly high");
    }

    function test_Gas_ReadCurve() public {
        vm.skip(!runGas);

        uint256 id = mintOnchain(creator, new bytes(1_024));

        // Small sizes first, then grow the same shard through checkpoints.
        // 344,050 and 1,474,500 pin the tier-1 (~30M) and tier-2 (~50M)
        // cap crossings; growth beyond ~2 MB is pointless (already past
        // every RPC cap; the quadratic memory term dominates).
        uint256[10] memory checkpoints = [
            uint256(1_024),
            10_240,
            24_575,
            98_300,
            245_750,
            344_050,
            491_500,
            983_000,
            1_474_500,
            1_966_000
        ];

        console2.log("=== read curve: content bytes -> gas ===");
        vm.pauseGasMetering();
        for (uint256 i = 0; i < checkpoints.length; i++) {
            _growTo(id, checkpoints[i]);
            vm.resumeGasMetering();

            uint256 gBytes = _readGas(abi.encodeWithSelector(fl.readShardBytes.selector, id, uint256(0)));
            console2.log("content bytes:      ", checkpoints[i]);
            console2.log("  readShardBytes gas:", gBytes);

            // uri() at ~2 MB costs ~433M gas (measured once) — skip it
            // there so the metered test budget covers the whole ladder.
            if (checkpoints[i] <= 1_474_500) {
                uint256 gUri = _readGas(abi.encodeWithSelector(fl.uri.selector, id));
                console2.log("  uri (base64) gas:  ", gUri);
            }

            vm.pauseGasMetering();
        }
        vm.resumeGasMetering();
    }

    function test_Gas_RendererReadHop() public {
        vm.skip(!runGas);

        uint256 id = mintOnchain(creator, bytes('{"name":"x"}'));
        TrivialRenderer r = new TrivialRenderer();
        vm.startPrank(creator);
        fl.appendShard(id, rendererInput(address(r)));
        fl.selectShard(id, 1);
        vm.stopPrank();

        uint256 g = _readGas(abi.encodeWithSelector(fl.uri.selector, id));
        console2.log("uri() via trivial renderer (hop overhead):", g);
    }
}
