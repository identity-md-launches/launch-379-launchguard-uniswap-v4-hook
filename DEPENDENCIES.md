# Vendored dependencies

Only Solidity source trees and upstream licenses are included; upstream test trees and unrelated tooling are omitted. Files are ordinary source files, not gitlinks. No install command runs during verification.

| Package | Revision | Included paths |
| --- | --- | --- |
| [Uniswap v4-core](https://github.com/Uniswap/v4-core/tree/e50237c43811bd9b526eff40f26772152a42daba) (`v4.0.0`) | `e50237c43811bd9b526eff40f26772152a42daba` | `src/` excluding `src/test/`, `licenses/` |
| [forge-std](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) (`v1.9.7`) | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | `src/`, license files |
| [Solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) (v4-core's pinned dependency) | `4b47a19038b798b4a33d9749d25e570443520647` | `src/` excluding `src/test/`, `LICENSE` |

Uniswap core retains its BUSL-1.1 and MIT notices; forge-std retains MIT/Apache-2.0 notices; this Solmate revision retains AGPL-3.0-only notices. New source files are MIT-licensed; upstream licenses remain applicable to combined distributions. License texts are present beside vendored sources. No upstream Solidity source has been edited.
