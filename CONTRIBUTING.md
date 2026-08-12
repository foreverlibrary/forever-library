# Contributing

Thanks for your interest. A ground rule first, because it shapes everything else:

**The deployed contracts cannot change.** They are immutable, with no upgrade path — no pull request can alter what is on-chain. The flattened sources in [`contracts/v3/flattened/`](contracts/v3/flattened/) and their checksums are byte-exact records of the deployed code and are never edited; CI fails any change to them.

## What contributions are welcome

- **Documentation** — corrections, clarity fixes, better examples in [INTEGRATION.md](INTEGRATION.md) or the README.
- **Integration examples and tooling** — indexer recipes, renderer examples, verification scripts, bindings for other languages.
- **Tests** — additional cases for the Foundry suites, especially fuzz and invariant tests.
- **Comment-level fixes to the readable sources** — the files in `contracts/v3/` (not `flattened/`) may take documentation improvements; behavior is fixed by the chain, so only comments can change meaningfully.

## Development setup

```bash
git clone --recurse-submodules https://github.com/foreverlibrary/forever-library.git
cd forever-library
forge test                              # canonical suite
forge test --root contracts/v3/shape    # Shape variant suite
```

CI runs both suites plus checksum and ABI-reproducibility checks on every push and PR — a green `verify` run is the bar for merging.

## Questions and bugs

- Integration questions and bug reports: open an issue (templates provided).
- **Security issues: do not open a public issue.** See [SECURITY.md](SECURITY.md) — email `deployer@foreverlibrary.xyz` privately first.

All contributions are accepted under the repository's [MIT license](LICENSE).
