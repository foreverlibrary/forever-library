# Security

## Reporting a vulnerability

Email **deployer@foreverlibrary.xyz**. Please report privately before opening a public issue, and include the chain, contract address, and a reproduction path. There is currently no formal bug bounty program.

## Audit status

Stated plainly, so you can weigh it yourself:

- The V3 contracts have been through **extensive AI-assisted security review**: repeated full-codebase audits using multiple frontier models (including Anthropic Claude, OpenAI ChatGPT, and Moonshot Kimi K3), run as independent fresh-context passes across successive revisions of the source, with findings remediated and re-reviewed. The Shape gasback variant received its own dedicated review of the divergence.
- Every deployment carries a **full Foundry test suite** (120 tests per chain repo) covering minting, shard mutation windows, slice/rolling-hash integrity, locking guards, delegation, soulbound transfer blocking, multicall atomicity, and the renderer probe surface.
- The contracts have **not been audited by an external professional security firm.**

## What the design removes from the attack surface

- The contracts are **non-payable** — they hold no funds, accept no ether, and have no withdraw path.
- There are **no admin keys, no pause, no upgrade path, no proxy**. `owner()` carries zero on-chain authority (see [INTEGRATION.md §3.1](INTEGRATION.md#31-external-surface)).
- The contracts are **immutable**: nothing can be patched in place. A confirmed vulnerability cannot be hot-fixed — which is exactly why the review history above is disclosed rather than implied.

## Verifying what's deployed

Don't take this repository's word for anything:

- Per-chain deployed sources and their sha256 checksums: [`contracts/v3/`](contracts/v3/)
- Explorer and Sourcify verification per deployment: [INTEGRATION.md §2](INTEGRATION.md#2-contract-addresses--networks)

Independent security research is welcome.
