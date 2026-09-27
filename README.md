# LaunchGuard

A Uniswap v4 launch hook with immutable buy limits, a declining launch fee, and surplus fees donated to liquidity providers. Includes an authenticated router, CREATE2 deployment tooling, a fixed-supply `LaunchToken`, and tests against the real, locally deployed v4 `PoolManager`.

**Deployment status: tested locally; not broadcast to Sepolia.** No funded signer was supplied. `deployments/sepolia.json` records the deployment parameters and mined candidate, not a transaction receipt. The demo deployment is a separate guarded pool; a network factory that creates an ordinary unhooked pool does not activate LaunchGuard.

The complete deployment script also passed a simulation against live Sepolia state without broadcasting. The mined hook candidate is **`0x3b605700BA467BE757db2007756b37C2d2ea60cC`**, with permission mask `0x20cc`. [VALIDATION.md](VALIDATION.md) records the 35 passing local tests and deployment checks.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

Solidity is pinned to **0.8.26**, with the Cancun EVM, optimization and IR compilation enabled, and metadata bytecode hashing disabled. Dependencies are vendored as ordinary files under `lib/`; no submodules, downloads, FFI, filesystem cheatcodes, RPC, environment variables or wallet credentials are needed by the tests. The compiler itself must be installed by the build environment. See [DEPENDENCIES.md](DEPENDENCIES.md) for pinned revisions and licenses.

## Launch rules

The creator approves both ERC-20 currencies to `hook.router()` and calls `LaunchGuard.initialize(key, sqrtPriceX96, settings, liquidity, maxAmount0, maxAmount1)` once. This transaction stores the settings, initializes the pool with `fee = 0x800000` (v4's dynamic-fee flag), and funds a full-range LP position owned by the creator through the router. Failed funding reverts the entire initialization.

The seed's actual token debit is the immutable initial token reserve. Limits are percentages of that deposit, **not total ERC-20 supply or the singleton PoolManager's aggregate balances**. Later liquidity additions, removals and direct transfers do not change the limits. The initial deposit must produce a nonzero limit.

| Setting | Accepted values | Demo |
| --- | --- | --- |
| New token | Either currency in the sorted pool key | GUARD |
| Launch window | 1–300 blocks | 100 blocks |
| Start fee | 10,000–500,000 millionths (1–50%) | 50% |
| Maximum buy | 1–10,000 basis points of initial token reserve; at most address cap | 50 bps (0.5%) |
| Maximum per address | At least maximum buy, at most 10,000 bps | 100 bps (1%) |
| Normal LP fee | Fixed in code | 1% |

Let `B` be the initialization block, `W` the window, and `e = block.number - B`:

- At `B`, all buys revert. Sells are allowed.
- For `0 < e < W`, buys pay `10,000 + floor((startFee - 10,000) × (W - e) / W)` millionths, with one successful buy per calling address per block. The rate at `e = 0` is the start fee, although that block cannot execute buys.
- Each successful guarded buy must fit both the per-swap cap and the address's remaining cumulative allowance. Accounting uses actual tokens received, for both exact-input and exact-output swaps. Sells never restore the allowance.
- At `e >= W`, all buy restrictions and the surplus charge disappear. Buys and sells use the normal 1% LP fee. The router still enforces its ordinary deadline, slippage and full-fill requirements.
- A one-block window therefore has first-block rejection followed immediately by normal trading. Block counts are not precise wall-clock minutes.

Settings have no setters, upgrades, owner, fee beneficiary or owner withdrawal. `beforeInitialize` rejects every external initialization; v4 deliberately skips that callback when the hook itself calls `initialize`. There is no initialization hookData dependency.

## Buyer identity and trading

During the window, a buy must use `hook.router().swap(key, params, limit, deadline)`. The router uses its immediate `msg.sender` as payer, recipient and counted buyer. It constructs the hookData itself. It accepts no arbitrary buyer or recipient field and does not use `tx.origin`. A different router cannot bypass limits by inventing hookData. EOAs and smart accounts both work; aggregators sharing a calling address share its cap and block limit. Tokens received can subsequently be transferred.

`params.amountSpecified < 0` means exact input; `limit` is minimum output. A positive amount means exact output; `limit` is maximum input including all hook charges. `sqrtPriceLimitX96` and `deadline` are also enforced. This router rejects partial fills rather than charging a surplus against unused input. Guarded buys additionally enforce this inside the hook, so the reserved input surcharge always matches a full swap. Failed slippage, price-limit, allowance or payment checks revert the donation and buyer counters as well.

Sells can use other routers from the start. After the window, other routers can buy too, with no hookData requirement. This minimal router handles one ERC-20/ERC-20 pool at a time, with no native ETH or multihop support; use a wrapped native token if needed. It has no Permit2 integration. Standard ERC-20 approvals, or the token's EIP-2612 permit, can authorize it.

## Fee accounting and LP access

Charging the entire declining fee through core's LP fee and then adding a donation would charge twice. Instead, LaunchGuard overrides the core LP fee to **1%**, reserves only the surplus through v4's custom accounting, and donates that surplus in the input currency after the swap. `currentBuyFee` is the effective combined rate; the `Swap` event's fee field is the core's 1% component. `GuardedBuy` reports the effective rate and donated amount; core also emits `Donate`.

With rates scaled by `S = 1,000,000`, normal rate `b = 10,000`, and current effective rate `f`:

| Mode | Surplus `H` | Core executes |
| --- | --- | --- |
| Exact input, gross input `G` | `floor(G × (f - b) / (S - b))` | Input `G - H`, charging its normal fee |
| Exact output, core input including its normal fee `C` | `ceil(C × (f - b) / (S - f))` | Requested output; user pays `C + H` |

Core fees and token quantities use integer arithmetic. Tiny amounts can have material percentage rounding. Fuzz tests compare both modes with real v4 pools charging `f` directly, allowing at most two minor units of rounding difference in these single-range comparisons. These are not quotes that ignore price impact.

The before-swap specified delta funds exact-input surplus; the after-swap unspecified delta funds exact-output surplus. `manager.donate` creates an equal hook debt, which core cancels against that credit. There is no hook `take`, retained fee balance, claim-token mint or withdrawal function. The donation increases fee growth for liquidity active **after** the swap, including third-party LPs. Normal fees accrue along the swap's price path. As with core fees, rounding dust may remain in PoolManager.

The router records full-range liquidity by pool and caller and uses a caller-specific position salt. `modifyLiquidity(key, delta, limit0, limit1, deadline)` adds or removes only that caller's position; zero delta collects that caller's fees. For additions, the limits are maximum token payments. For removal or collection, they are minimum receipts. This is LP access to their own assets, not a hook-owner withdrawal. LP positions are not transferable NFTs. Other position managers can also add liquidity directly to these pools.

## Known limits and responsibilities

- A sniper can split across many addresses or contracts. This is a per-address speed and size limit, not proof of humanity. It does not prevent sandwiches, private order flow, builder manipulation, wallet resale or token transfers after a buy.
- Liquidity is not locked. A creator can remove it; other LPs can add liquidity just before a trade to share donations, then withdraw it. Seed reserve caps remain fixed even if live liquidity falls. Creators must disclose their liquidity policy and initial price.
- Pools are permissionless. The initializer chooses which asset is the new token and supplies the real seed funds. There is no token-owner authentication; somebody can initialize a desired pool key first. Use a fresh hook deployment when exclusive launch configuration is needed. Other pools without this hook are unaffected.
- Fee math assumes zero core protocol fee during guarded buys. If PoolManager governance enables either directional protocol fee, guarded buys fail closed until it is disabled. Sells and post-window trading use the 1% LP fee plus whatever external core protocol fee governance configures. LaunchGuard has no authority to change protocol fees.
- Support is limited to standard, non-rebasing ERC-20 tokens with accurate balances and transfers. Fee-on-transfer, callback-driven, upgradeable or malicious currencies are not supported. The demo tokens have fixed supply and no administrator. Operators must verify currency and PoolManager implementations.
- Failed transactions still cost gas. Users should set meaningful slippage and deadline values and check remaining caps and current block before submitting. The first allowed buy is `B + 1`, not a timestamp.
- There is no pause, recovery key or upgrade path. Funds accidentally sent directly to the hook/router are not recoverable. PoolManager retains normal core custody; router allowances authorize only caller-funded operations.
- The suite is local validation, not an independent security audit. Review the hook, router, compiler settings, manager, mined address and deployment transactions independently before a valuable launch.

## Sepolia deployment

The [official Uniswap deployment list](https://developers.uniswap.org/docs/protocols/v4/deployments) lists Sepolia chain **11155111** and PoolManager **`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`**. A read-only RPC check during this task returned nonempty code (24,009 bytes). This is not evidence that LaunchGuard was deployed.

`script/DeploySepolia.s.sol` uses an explicit operator argument and no Solidity environment reads. It deploys:

1. `LaunchToken`: LaunchGuard / GUARD, 18 decimals, exactly 1,000,000,000 tokens minted to its deployer; no post-construction mint or admin powers.
2. `DemoQuote`: a valueless 18-decimal dUSD token for testnet demonstrations.
3. `LaunchGuardDeployer` with a deterministic CREATE2 salt, then a mined `LaunchGuard`. The hook constructor deploys its immutable router.
4. A GUARD/dUSD pool with dynamic fee, tick spacing 60, `sqrtPriceX96 = 79228162514264337593543950336` (1:1), 1,000,000 units of full-range liquidity in 18-decimal terms, 100 blocks, 50% start fee, 0.5% per-swap cap and 1% per-address cap. At this price the deposits are approximately one million of each token. The actual measured deposit sets the caps.

Both approvals are bounded and revoked after seeding. In a broadcast, the supplied operator receives the token supply and owns the seed LP position. `Deployment.t.sol` directly tests the same deployment function with a local PoolManager; in that test the script contract is the deployer and LP.

The permission mask is **`0x20cc`**: before-initialize, before-swap, after-swap, before-swap-return-delta, after-swap-return-delta. All other bits must be zero. The constructor validates the mask; production tests use actual mined CREATE2 deployment rather than `vm.etch` to fake a hook address.

Reproduce the candidate for Foundry's canonical CREATE2 proxy:

```sh
forge script script/MineHook.s.sol:MineHook --sig 'run()'
```

For a different deployment factory and manager, provide their addresses:

```sh
forge script script/MineHook.s.sol:MineHook \
  --sig 'run(address,address)' DEPLOYER_ADDRESS MANAGER_ADDRESS
```

The CREATE2 hash includes the full hook creation code and manager constructor argument. Changing dependencies, settings, code, compiler or deployment factory changes the candidate and requires mining again. The ordinary public deployer contract embeds hook init code; use the pinned build, not a separately compiled binary.

For a constructor-only project factory, `LaunchGuard` takes one static address argument, the PoolManager, and requires a mined factory salt. Its constructor creates the router but does not initialize a pool or move any launch tokens. The constructor rejects a zero manager; the operator must validate the nonzero manager's implementation. The demo script also checks that manager code exists. A deployment probe without live chain state can therefore execute the constructor; that alone does not test a pool launch. The creator must later approve funds and call `initialize` for the guarded pool.

An operator with Sepolia gas and a locally managed Foundry keystore can first simulate and then broadcast. Replace all uppercase placeholders; do not place keys in source or commands:

```sh
forge script script/DeploySepolia.s.sol:DeploySepolia \
  --sig 'run(address)' OPERATOR_ADDRESS \
  --rpc-url SEPOLIA_RPC_URL --account KEYSTORE_NAME

forge script script/DeploySepolia.s.sol:DeploySepolia \
  --sig 'run(address)' OPERATOR_ADDRESS \
  --rpc-url SEPOLIA_RPC_URL --account KEYSTORE_NAME --broadcast --slow
```

The deterministic proxy must be Foundry's default `0x4e59b44847b379578588920cA78FbF26c0B4956C` for the recorded candidate. A repeated deployment with the same salts fails if already deployed; inspect receipts and resume an interrupted broadcast rather than starting another launch. Initialization and seeding are atomic, while token deployments and approvals are separate transactions. The launch clock starts only with successful initialization; slow confirmations after that consume launch blocks.

After broadcast, record transaction hashes, token/router/hook addresses, pool ID and initialization block in `deployments/sepolia.json`, verify deployed code and permission bits, and confirm settings through `launch(poolId)`. Approve the quote token to the emitted router and buy after the first block. The operator remains responsible for gas, distribution of demo tokens, managing their LP, source verification and checking deployed parameters. No live address or transaction hash is asserted in this submission.
