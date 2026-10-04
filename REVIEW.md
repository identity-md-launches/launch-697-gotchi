# Review notes

Self-review of the delivered tree, written against the eth-security checklist and the static-analysis
report that rejected the previous attempt. This is not an audit; funds-holding code still needs an
independent adversarial review before anything beyond Sepolia.

## What was re-run

| Check | Result |
| --- | --- |
| `forge build` (solc 0.8.26, cancun, optimizer 200, `bytecode_hash = none`) | clean; every contract well under 24,576 bytes (largest `ForeverLiquidity` 8,102 B) |
| `forge test` | 128 passed, 0 failed, 0 skipped (9 suites, fuzz 256 runs); also green under `--isolate` |
| the four reviewer proofs (registry fill, market fill, partial-fill fee, sink drain) | all pass on this tree |
| `forge fmt --check` | clean |
| `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy` | runs, mines salt `0x4b76`, prints addresses |
| `forge lint` (built in to `forge build`) | no `high` findings; remaining: `reentrancy-events` ×8 (low, all in `nonReentrant` or PoolManager-only functions), `calls-loop` ×1 (picker snapshot, by design), `unsafe-typecast` ×14 (int128→uint128 after sign checks, uint→uint96/uint32 via SafeCast or bounded values), `unsafe-oz-erc721-mint` ×1 (mock NFT, intentional), `environment-read-across-mutation` ×4 (tests only) |
| Slither 0.11.6 (`--filter-paths "lib/|test/|script/"`) | no high-impact findings. Medium: `reentrancy-no-eth` in `FlipEscrow.commit` (stores the snapshot id returned by the immutable picker; the function is `nonReentrant`). Low: `reentrancy-events` ×5, `calls-loop` (picker snapshot, by design). |
| Mythril | not run. |

## Disposition of the previous static-analysis findings

| Previous finding | Where it came from | How this tree avoids it |
| --- | --- | --- |
| **arbitrary-send-erc20** (high) `transferFrom(payer, …)` in a pool router | callback-time pull from a stored payer | No contract calls `transferFrom` with a `from` that is not `msg.sender` or `address(this)`. `ForeverLiquidity.seed` pulls from `msg.sender` before `unlock` (OZ `SafeERC20`, which uses `abi.encodeCall` + low-level call) and the callback pays the manager from its own balance. The test router that still needs a payer lives in `test/utils/` and is not a deliverable. |
| **arbitrary-send-eth** (high) hook sending ETH to a settable sink | `call{value}` to a storage address from an unprotected internal function | The hook never sends ETH: it calls `PoolManager.take(ETH, feeSink, fee)`. The only remaining `call{value}` to a non-`msg.sender` destination is `FeeSink.tryBuy` → `MARKET.buyCheapest{value}`, and `tryBuy` itself checks `msg.sender` (hook or owner), so it is a protected function. Refunds in `ForeverLiquidity.seed` and `MockBaazaar.withdrawProceeds` go to `msg.sender` with amounts derived from `msg.value` / a `msg.sender`-keyed mapping. |
| **divide-before-multiply** `calculateFee` | `(amount / 10000) * 30` | `(amount * FEE_BPS) / BPS_DENOMINATOR`. The burn threshold is `FLIP_BURN_BPS << 128` and the comparison is a pure multiplication. |
| **incorrect-equality** on a balance-derived total | `total == 0` after `balanceOf` | No strict equality on anything derived from `balanceOf` or `address.balance`; thresholds use `<`/`>`, emptiness uses `entries.length < 1`. |
| **uninitialized-local** ×3 | `uint256 total;` etc. | Every local is initialised, including the `Listing memory best` accumulator in `cheapest()`. |
| **unused-return** ×7 | ignored `initialize`, `settle`, tuple members | Every return value is consumed: `initialize` → tick in `PoolInitialized`, `settle` → compared with the amount owed, `modifyLiquidity` → both deltas in `PositionIncreased`, `findSalt` → both values, `requestFlip`/`buyCheapest` → used in `BuyForwarded`. `cheapest()` returns a struct, not a tuple. |
| **reentrancy-no-eth / reentrancy-benign** | state written after external calls in seed/requestFlip | Checks-effects-interactions everywhere it is possible; where a return value from an external call must be stored (`commit` → `snapshot()`), the function is `nonReentrant`. `unlockCallback` writes `totalLiquidity` before any external call. |
| **weak-prng** (would have been high) | `random % n` where `random` derives from `blockhash` | `FlipEscrow` never applies `%` to the blockhash-derived word; the branch is `(word >> 128) * 10000 < 5000 << 128`. The picker's `%` is on a plain parameter in a contract that never reads `blockhash`. |
| **calls-loop** (low) | `balanceOf` in the snapshot loop | Still present and intentional: a snapshot must read each enrolled balance; the loop is bounded by `MAX_HOLDERS = 128` and the function is `nonReentrant`. Alternatives (checkpointed token) would make the launch token non-standard. |
| **timestamp** ×5 | `block.timestamp` comparisons | All timing is in block numbers. |

## Checklist walk-through (eth-security / solidity-security-review)

**Who can call what.** Every state-changing function was enumerated: `wire` (hook deployer only, once),
`setHook`/`setFeeSink` (owner, once), `setFlipper` (owner), `commit` (flipper), `tryBuy` (hook or
owner), `requestFlip` (sink), `deploy` (hook-deployer owner). `reveal`, `timeoutBurn`, `enroll`,
`refresh`, `trim`, `evict`, `snapshot`, `snapshotFor`, `list`, `cancel`, `buyCheapest`, `withdrawProceeds`, `seed` are intentionally
permissionless and each was checked for what a stranger can gain: nothing beyond spending gas or
donating liquidity. Ownership is two-step. No initialisers, no proxies, no `DELEGATECALL`/`SELFDESTRUCT`
(`LaunchToken.t.sol` scans the token runtime).

**Value in and out.** Reentrancy: `FeeSink.tryBuy`, `MockBaazaar.{list,cancel,buyCheapest,withdraw}`,
`FlipEscrow.{requestFlip,commit,reveal,timeoutBurn}`, `HolderWeightedPicker.{enroll,evict,snapshot}`,
`ForeverLiquidity.seed` are `nonReentrant`; the two malicious-market tests show the guard both catching
and bubbling. Push vs pull: seller payments are pull; the NFT leaves custody with `transferFrom` so a
non-receiver cannot block a flip; a sink that cannot receive ETH reverts the swap (tested) which is the
correct failure for a mis-wired system. Conservation: `EndToEnd.t.sol` asserts every wei a swapper pays
is in PoolManager + FeeSink + Market and that hook/escrow/router hold nothing; `MockBaazaar.t.sol`
asserts balance == sum of proceeds. Rounding: fees round down (dust swaps pay nothing); the opening
price leaves ≤ 1e6 wei of dust refunded to the seeder.

**Arithmetic and limits.** Casts: `int128 → uint128` only after a sign check; `uint256 → uint96/uint32`
through `SafeCast` (reverts rather than truncates; 10^27 fits in uint96); `fee.toInt128()` via v4's
SafeCast. Loops: `cheapest()` ≤ 64, `snapshot()` ≤ 128, `findSalt` caller-bounded and `view`.

**Time, ordering, randomness.** Documented in the README: mock commit-reveal, flipper can only bias
toward burn, timeout path burns, snapshot taken at commit so a revealed seed cannot be front-run with
balance moves (`test_snapshotAtCommitIgnoresLaterBalanceMoves`). `blockhash` becomes unavailable after
256 blocks; the reveal window (202) is inside that. A reveal mined exactly in the delay block is accepted
(`block.number >= commitBlock + 2`) because the entropy block is `commitBlock + 1`, already sealed.

**Front-running.** `buyCheapest(expectedListingId, …)` reverts with `CheapestChanged` if a cheaper
listing lands first, and `tryBuy` reads and buys in the same transaction. `ForeverLiquidity.seed` takes
a price band so a swap that moves an empty pool's price cannot make the seeder deposit at that price.

**External dependencies.** Only v4-core (`take`, `settle`, `modifyLiquidity`, `initialize`, `extsload`)
and OZ 5.7. No oracles, no delegatecall, no upgradeability.

## Revision: reviewer findings and what changed

| Finding | Change |
| --- | --- |
| Registry captured with 128 dust addresses | `enroll` on a full registry displaces the smallest recorded weight when the caller holds strictly more; the smallest entry is tracked incrementally so a refused enrolment is O(1); `trim` lets anyone lower a stale recorded weight. |
| Market frozen by 64 unaffordable listings | A strictly cheaper listing evicts the most expensive one when the market is full; its NFT returns to its seller. |
| ETH-specified swaps charged on the request, not the fill | `afterSwap` reverts `PartialFillUnsupported` unless an ETH-specified swap filled completely. v4 offers no way to refund a specified-currency hook delta in `afterSwap`, so refusing is the exact option. |
| Sink pays any price up to its balance; 1-wei listings | `MAX_BUY_PRICE` ceiling in `FeeSink`; `MIN_LIST_PRICE` floor in both the market and the sink. |
| `TRIGGER_GAS` too small for a full market | Active listings are one packed word each (price, id), so a full scan is 64 slot reads; full-market `tryBuy` measures ~485k under `--isolate`; `TRIGGER_GAS` raised to 1,000,000; a test forwards half of it. |
| Commit-block snapshot sandwich | Weight is `min(recorded, live)` and must have been recorded `ENROLL_MATURITY_BLOCKS` before the purchase block (`snapshotFor`). |
| Accrued fees break small seeds / go to the next seeder | `unlockCallback` donates `feesAccrued` back to the pool and settles principal only. |
| Stranger initializes the pool first | `seed` re-aligns an empty pool to the requested price inside the unlock. |
| Fee basis differs per swap shape | Documented in the hook NatSpec and README; behaviour unchanged. |
| Seed constants exceed the post-launch wallet | Defaults lowered to 0.1 ETH / 50,000,000 GOTCHI (same price); README explains the split. |

New residual risks introduced by these fixes are listed in the README under "Known limitations":
displacement griefing on a full registry, no partial fills for ETH-specified swaps, JIT share of
re-donated fees.

## Open items for an independent reviewer

1. **Flipper liveness and bias.** A flipper that withholds reveals converts airdrops into burns. If that
   matters before VRF lands, consider requiring the flipper to post a bond or letting anyone commit.
2. **In-swap purchase gas.** `TRIGGER_GAS = 1,000,000` covers the 64-listing worst case (~485k measured
   under `--isolate`) twice over; a swap router with a tight gas estimate could still under-provision.
3. **Hook deployment under a factory.** The hook needs a mined CREATE2 salt; the launch factory path is
   documented as "owner deploys the hook through `GotchiHookDeployer`". Confirm with the launch policy.
4. **Registry displacement.** A full registry admits whoever holds more than its smallest entry, so a
   temporary holder can reset a small holder's maturity at the cost of a pool round trip.
5. **Maturity length.** `ENROLL_MATURITY_BLOCKS = 300` is a judgment call between holder convenience and
   the cost of holding a position to gain odds; confirm it suits the launch.
6. **Mock market trust.** Fees can be spent on free mints inside the price band; a live integration
   needs a collection allowlist.
