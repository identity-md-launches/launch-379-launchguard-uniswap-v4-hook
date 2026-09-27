# Validation record

Final source validation on 2026-09-27, using Foundry 1.8.3 and Solidity 0.8.26:

| Check | Result |
| --- | --- |
| `forge build` | Passed; compiler successful. Static lint warnings remain, primarily checked casts and guarded external calls. |
| `forge test -vv` | **35 passed, 0 failed, 0 skipped**, across 3 suites. |
| `forge fmt --check` | Passed. |
| Vendored source integrity | All 98 vendored files match their pinned upstream archives. |
| Offline salt mining | Passed; candidate hook `0x3b605700BA467BE757db2007756b37C2d2ea60cC`, mask `0x20cc`. |
| Sepolia deployment simulation | Passed against the live Sepolia PoolManager; no `--broadcast`, wallet or private key. |
| Live Sepolia deployment | **Not performed**; requires a funded signer. |

The tests do not use network forks, environment reads, file access or FFI. Three fuzz tests each run 256 cases: exact-input fee parity against a real v4 control pool, exact-output fee parity, and monotonic fee decay over randomly selected windows and starting fees. Tests also cover atomic initialization, measured seed reserves, immutable settings, first-block rejection, actual-output caps, cumulative caps in both swap modes, sell behavior, block limits, expiry, untrusted routers, callback authorization, LP collection and ownership, both token orderings, donation events, payment/slippage rollback, tiny amounts and partial-fill rejection.

The local integration deploys a real `PoolManager` and a CREATE2-mined hook. The demo deployment function is separately tested. Runtime scans reproduce the protected opcode restrictions for token, hook, router and deployer and enforce the EIP-170 limit:

| Contract | Runtime bytes |
| --- | ---: |
| LaunchToken | 2,483 |
| LaunchGuard | 6,322 |
| LaunchRouter | 4,288 |
| LaunchGuardDeployer | 12,119 |

The Sepolia simulation deployed both demo currencies and the mined hook in forked state, initialized and funded its pool, and revoked the seed approvals. Its CREATE2 hook and deployer addresses match the offline miner. Its approximate gas estimate was 9,447,624; fees and estimates may change. This simulation produced no live transactions or launch pool.

Self-review focused on caller-authenticated payer and buyer identity, v4's self-call hook bypass, donation debt/credit cancellation, rollback across settlement, the two token orientations, immutable cap denominators, and routing after expiry. This is not an independent audit. The remaining operational and economic limits are documented in the README.
