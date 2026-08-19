# Forever Library — Brand & Media Kit

Everything needed to refer to, write about, or show Forever Library.
Questions or requests for other formats: open an issue on this repo.

- Website: [foreverlibrary.xyz](https://foreverlibrary.xyz)
- Code: [github.com/foreverlibrary](https://github.com/foreverlibrary)

## Name

The name is **Forever Library**, two words, both capitalized. Not
"ForeverLibrary" (that spelling is reserved for contract and code
identifiers like `ForeverLibraryV3`), not "the Forever Library" in
headlines. The protocol's deployed contract family is referred to as
ForeverLibraryV3 or "the V3 contracts" when the technical distinction
matters.

## Boilerplate

Short (one line):

> Forever Library is an open-source protocol for building provenance of
> digital media via immutable Ethereum NFTs.

Long (one paragraph):

> Forever Library is a series of immutable smart contracts, live on
> Ethereum and several L2s, preserving digital culture through open,
> verifiable, and permanent minting. The contracts are admin-less and
> non-payable; records carry explicit rights, format identification, and
> onchain proofs, with fallback storage across IPFS, Arweave, and the
> chain itself. Anyone can mint through the Forever Library app or
> directly from the contracts.

## Logo

The mark is a white long-s "∫" glyph on a filled roundel. The default
roundel is the Ethereum roundel blue `#627EEA`; inside the app the
roundel re-keys to the active chain's accent.

| file | use |
|---|---|
| `logo/fl-mark.svg` | default: blue roundel, white glyph |
| `logo/fl-mark-ink.svg` | monochrome contexts, light backgrounds |
| `logo/fl-mark-paper.svg` | monochrome contexts, dark backgrounds |
| `logo/fl-glyph-black.svg` | glyph only, black on transparent |
| `logo/fl-glyph-white.svg` | glyph only, white on transparent |

Chain-branded variants (the same mark with the roundel re-keyed to the
chain's accent) already live in this repository at
[`assets/chain-marks/v3/`](../assets/chain-marks/v3/). Use these only
where the chain context is explicit.

PNG exports sit next to each SVG (`-1024`, `-256`, plus a `-64` favicon
size for the default mark). Use the SVG whenever the medium allows.

Rules:

- Do not redraw, stretch, rotate, or recolor the mark. The blue is the
  brand color, not a suggestion, except where a chain-branded context
  re-keys it (see Color below).
- Keep clear space around the roundel of at least a quarter of its
  diameter.
- The mark is always circular; do not crop it into another shape.

## Color

The palette is gallery-minimal: near-monochrome ink on paper, one
accent. The artwork on screen is the only other color.

Light theme:

| token | hex | role |
|---|---|---|
| paper | `#FAFAFA` | background |
| ink | `#111113` | primary text and marks |
| ink 2 | `#55555C` | secondary text |
| hairline | `#E8E8EC` | borders |
| accent | `#627EEA` | the brand blue (Ethereum roundel blue) |
| accent ink | `#4560C8` | accent for text on paper |
| write | `#FF6B9D` | reserved for write/sign actions |

Dark theme: paper `#0A0A0C`, ink `#F2F2F5`, accent `#7B94F2`.

Chain-branded accents (used only where the chain context is explicit):
Tezos `#0F61FF`, Base `#0052FF`, Arbitrum `#12AAFF`, Soneium `#5B6B7F`,
Shape `#17171A`, MegaETH `#111113`, Robinhood `#CCFF00`.

## Typography

- **Inter Variable** — interface and body text.
- **Instrument Serif** — display and editorial headlines.
- **JetBrains Mono** — addresses, hashes, code, and data.

All three are open-licensed and self-hosted in the app via Fontsource.
Fallbacks: system-ui sans, Georgia serif, ui-monospace.

## Voice and copy style

- Plain language. Provenance-and-agency framing: the story is that
  creators keep control of their record, not that a platform grants it.
- The words "free" and "lock" do not appear in marketing surfaces.
  Locking is a quiet Studio capability, described with plain verbs like
  "finalize."
- No em dashes. Use a period, colon, comma, or the · separator.
- Never rewrite artist-supplied text. Descriptions and token metadata
  are the artist's words, punctuation included.

## License

All Forever Library code is MIT licensed. The mark and this kit are
provided for editorial, community, and integration use; do not use them
to imply endorsement or official status for an unrelated product.
