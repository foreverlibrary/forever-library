# Changelog

Notable changes to this repository. The deployed contracts are immutable — this log tracks the repository around them (documentation, ABIs, tests, CI), never the contracts themselves.

## [Unreleased]

### Added
- Full Foundry test suites, published from the per-chain contract repos: [`contracts/v3/test/`](contracts/v3/test/) (canonical, 117 tests) and [`contracts/v3/shape/test/`](contracts/v3/shape/test/) (Shape variant, 117 tests), plus opt-in gas studies (`FL_GAS=true`). CI runs both on every push.
- Stateful invariant suite ([`contracts/v3/test/invariant/`](contracts/v3/test/invariant/)): 8 invariants over fuzzed operation sequences — lock finality, provenance immutability, exact revision accounting, metadata-hash replay, supply conservation, soulbound immobility, royalty bounds — with expected-revert probes and `fail_on_revert` differential spec checking.
- `forge-std` v1.11.0 and `openzeppelin-contracts` v5.1.0 as pinned git submodules.
- `CHANGELOG.md`, issue templates, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`.
- Accurate deployed-status headers on the readable contract sources, including a note about the pre-deployment header frozen into the explorer-verified sources.

### Changed
- CI: Foundry toolchain pinned to v1.7.1 (was floating).

## [3.0.0] — 2026-08-11

First versioned release of this repository. The tag matches the deployed contract `VERSION` (`"3.0.0"`); the contracts themselves went live per chain in July 2026 (deploy blocks in [INTEGRATION.md §2](INTEGRATION.md#2-contract-addresses--networks)).

### Added
- [`INTEGRATION.md`](INTEGRATION.md) — the developer integration guide.
- [`contracts/v3/`](contracts/v3/) — canonical and Shape sources, per-chain flattened deployed sources, sha256 checksums.
- [`abi/`](abi/) — canonical, Shape-variant, and `IExternalRenderer` ABIs (also attached to the release).
- [`SECURITY.md`](SECURITY.md) — disclosure contact and audit status.
- CI (`verify`): deployed-source checksum verification and ABI reproducibility rebuild on every push.
- Runtime bytecode hash table (keccak256 per deployment) in INTEGRATION.md §2.
- Shape deployment source-verified on shapescan (full match).

### Changed
- Repository restructured: previous-generation contract sources moved to [`legacy/`](legacy/), chain marks to [`assets/chain-marks/`](assets/chain-marks/), README rewritten around V3.
