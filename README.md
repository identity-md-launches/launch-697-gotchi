# $GOTCHI — forever pool, fee hook, Baazaar flips (Sepolia)

A standalone Foundry project. `$GOTCHI` (contract `LaunchToken`) trades against ETH in a permanent
full-range Uniswap v4 pool. A v4 hook skims 0.30% of the ETH side of every swap into `FeeSink`.
Whenever the sink holds at least 0.01 ETH it buys the cheapest listed mock Aavegotchi from
`MockBaazaar` (inside a per-purchase price band of 0.001 to 0.05 ETH) and hands it to `FlipEscrow`, which resolves each acquisition 50/50 under a
commit-reveal mock randomness: burn it to `0x…dEaD`, or airdrop it to a `$GOTCHI` holder picked by
`HolderWeightedPicker` in proportion to balance. Every hop emits an event for a future UI.

```
swap ──► GotchiFeeHook ──take(ETH)──► FeeSink ──buyCheapest──► MockBaazaar
                                        │                           │ NFT
                                        └──requestFlip──► FlipEscrow ◄┘
                                                             │ commit / reveal (or timeout)
                                              ┌──────────────┴──────────────┐
                                           burn → 0xdEaD          airdrop → HolderWeightedPicker.pick
```

Sepolia only (chain id 11155111). No Base work, no live Baazaar, no real Aavegotchi contracts, no
launchpad / bonding-curve / graduation mechanics, no website.

## Contracts (`src/`)

| Contract | Role | Admin surface |
| --- | --- | --- |
| `LaunchToken` | `$GOTCHI`: fixed 1,000,000,000 × 10^18 supply minted to the deployer, name and symbol `GOTCHI`. No mint, owner, pause, blocklist, fee or upgrade. | none |
| `GotchiFeeHook` | v4 hook (`beforeSwap`, `afterSwap`, both return-delta flags, address low 14 bits = `0x00CC`). Skims `FEE_BPS` of the ETH amount of each swap on any ETH-paired pool, `take`s it straight to `FeeSink`, then pokes `FeeSink.tryBuy()` inside try/catch with a gas stipend. Constructor arg: the PoolManager address only. | `DEPLOYER` (constructor `msg.sender`) calls `wire(feeSink)` once |
| `GotchiHookDeployer` | CREATE2 deployer for the hook: mines a flag-valid salt (`findSalt`), deploys and wires the sink in one transaction so nobody can race the wiring. | `OWNER` may call `deploy` |
| `FeeSink` | Receives ETH. `tryBuy()` buys the cheapest listing once balance ≥ `MIN_BUY_THRESHOLD`, provided its price is within `MIN_LIST_PRICE`…`MAX_BUY_PRICE`, delivers the NFT to `FlipEscrow` and registers the flip. `nonReentrant`, checks-effects-interactions, no withdraw/sweep/treasury. | `owner` (Ownable2Step): `setHook` once; may call `tryBuy` as a keeper |
| `MockBaazaar` | Mock ETH-priced ERC-721 marketplace: `list`, `cancel`, `cheapest()`, `buyCheapest(expectedListingId, to)`. Seller proceeds are pull payments (`withdrawProceeds`). Prices below `MIN_LIST_PRICE` are refused. Active listings capped at 64; when full, a strictly cheaper listing evicts the most expensive one (NFT returned to its seller). | none |
| `MockGotchiNFT` | Mock Aavegotchi ERC-721, permissionless `mint`. | none |
| `FlipEscrow` | Holds acquired NFTs; commit-reveal resolution; burn or weighted airdrop; timeouts. | `owner` (Ownable2Step): `setFeeSink` once, `setFlipper`; `flipper` commits |
| `HolderWeightedPicker` | Opt-in holder registry (`enroll`, `refresh`, `trim`, `evict`), snapshots of held balances, deterministic weighted `pick`. When full, a larger holder displaces the smallest entry. | none |
| `ForeverLiquidity` | Opens the ETH/`$GOTCHI` pool with the hook and holds full-range liquidity that has no removal path. Anyone may `seed` more. Re-aligns an empty pool that a stranger initialized at another price; donates accrued fees back to the pool. | none |
| `GotchiConfig` | All constants (library). | n/a |

### Parameters (`src/GotchiConfig.sol`)

| Constant | Value | Notes |
| --- | --- | --- |
| `POOL_MANAGER` | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` | Sepolia v4 PoolManager; the hook's only constructor argument |
| `FEE_BPS` | 30 | of the swapper-facing ETH amount, rounded down |
| `MIN_BUY_THRESHOLD` | 0.01 ETH | |
| `FLIP_BURN_BPS` | 5000 | exact 50/50 |
| `BURN_ADDRESS` | `0x000000000000000000000000000000000000dEaD` | |
| `TOKEN_SUPPLY` | 1,000,000,000 × 10^18 | fixed by the launch-token rules (see below) |
| `MAX_BUY_PRICE` / `MIN_LIST_PRICE` | 0.05 ETH / 0.001 ETH | the most and the least `FeeSink` pays for one NFT; the market refuses listings under the minimum |
| `INITIAL_LIQUIDITY_ETH` / `INITIAL_LIQUIDITY_TOKENS` | 0.1 ETH / 50,000,000 GOTCHI | **configurable**; implied opening price 2 × 10⁻⁹ ETH per GOTCHI, implied FDV 2 ETH. Sized to fit the requester wallet after a default factory launch (see Deployment) |
| `POOL_LP_FEE` / `POOL_TICK_SPACING` | 0 / 60 | configurable; with LP fee 0 the hook fee is the only fee a swapper pays |
| `MIN_ENROLL_BALANCE` / `MAX_HOLDERS` | 1,000 GOTCHI / 128 | picker registry bounds, configurable |
| `ENROLL_MATURITY_BLOCKS` | 300 | a recorded weight counts only for NFTs bought at least this many blocks later (about one hour) |
| `MAX_ACTIVE_LISTINGS` | 64 | market bound |
| `TRIGGER_GAS` | 1,000,000 | gas stipend for the in-swap purchase attempt; a purchase with all 64 slots active measures about 485k |
| `REVEAL_DELAY_BLOCKS` / `REVEAL_WINDOW_BLOCKS` / `COMMIT_TIMEOUT_BLOCKS` | 2 / 200 / 7200 | flip timing |

To change a value: edit the library, rebuild, redeploy. Nothing is settable after deployment.

### What the brief asked that the token does not do

The brief lists `TOKEN_SUPPLY/mcap` as configurable. The launch token rules fix the supply at exactly
10^27 minor units minted to the deployer with no other behaviour, so `LaunchToken` is that standard
token and the supply is not a knob. Opening price and implied market cap remain configurable through
`INITIAL_LIQUIDITY_ETH` and `INITIAL_LIQUIDITY_TOKENS`.

## Fee mechanics

The fee is always ETH (currency0 of an ETH pair; ETH sorts first so this holds for every ETH pool).

| Swap | Specified currency | Where the fee is taken |
| --- | --- | --- |
| ETH exact-in | ETH | `beforeSwap` returns `+fee` on the specified side; pool swaps `in − fee` |
| ETH exact-out | ETH | `beforeSwap` returns `+fee`; pool outputs `out + fee`, swapper receives `out` |
| token exact-in | token | `afterSwap` reads the ETH output from the delta and returns `+fee`; swapper receives `out − fee` |
| token exact-out | token | `afterSwap` reads the ETH input and returns `+fee`; swapper pays `in + fee` |

In every case the hook calls `PoolManager.take(ETH, feeSink, fee)` so the ETH goes
PoolManager → FeeSink directly and the hook never holds ETH. `FeesCollected(pool, amountEth)` is
emitted with `pool = PoolManager` (v4 pools have no address); the companion
`SwapFeeSkimmed(poolId, swapper, amountEth, viaBeforeSwap)` carries the `PoolId`.

**Fee basis per shape.** The fee is 30 bps of the amount named in the table. ETH exact-in and token
exact-in therefore pay 30 bps of the gross ETH that crosses the swap. ETH exact-out pays 30 bps of the
net ETH received and token exact-out pays 30 bps on top of the pool's ETH input, which is 29.91 bps of
the gross in both cases. The same gross ETH routed as exact-in or exact-out pays a slightly different
fee, and `FeesCollected` amounts follow the per-shape basis.

**Partial fills.** A v4 swap stops at its `sqrtPriceLimitX96`. For token-specified swaps the fee is
computed from the ETH that actually moved, so a partial fill pays 30 bps of the filled amount. For
ETH-specified swaps the fee is taken in `beforeSwap` from the requested amount and v4 gives a hook no
way to return part of a specified-currency delta afterwards, so `afterSwap` reverts with
`PartialFillUnsupported` unless the pool swapped the whole request. An ETH-specified swap fills
completely or not at all; nobody is charged on ETH that did not move. Routers that bound slippage with
minimum-out / maximum-in amounts and leave the price limit open are unaffected.

**Large ETH exact-in swaps.** The `beforeSwap` fee is taken from the PoolManager before the swapper
settles, so it must fit in the ETH the PoolManager already holds across all pools. On Sepolia's shared
PoolManager that is not a practical limit; on a private PoolManager holding only this pool it is.

A pool whose currency0 is not native ETH, or a hook that has not been wired, charges nothing.
There is no `beforeInitialize` gate and no liquidity gate: anyone may open ETH/anything pools with this
hook (they would only feed the sink) and anyone may add liquidity.

## Purchase and flip flow

1. `afterSwap` calls `FeeSink.tryBuy()` with `TRIGGER_GAS` inside try/catch. `tryBuy` returns `false`
   without reverting when the balance is below threshold, nothing is listed, or the cheapest listing
   costs more than the balance or lies outside the price band (below `MIN_LIST_PRICE` or above
   `MAX_BUY_PRICE`). A revert or out-of-gas inside the sink is swallowed; the swap always
   succeeds as long as the sink can receive ETH. The owner may also call `tryBuy()` as a keeper (for
   example when a listing appears while no swaps happen).
2. `tryBuy` emits `BuyTriggered(listingId, priceEth, tokenId)`, pays exactly the listing price to
   `MockBaazaar.buyCheapest(listingId, escrow)` (the market re-checks that this listing is still the
   cheapest, credits the seller, transfers the NFT to the escrow) and calls `FlipEscrow.requestFlip`,
   which emits `FlipRequested(acquisitionId, tokenId, requestId)`.
3. The flipper calls `commit(acquisitionId, keccak256(abi.encode(seed)))`. The commit freezes the holder
   snapshot (`HolderWeightedPicker.snapshotFor(requestBlock)`), so balance moves after this point do
   not matter, and only weight recorded 300 blocks before the purchase counts.
4. From `commitBlock + 2` up to `commitBlock + 202`, anyone who knows the seed calls
   `reveal(acquisitionId, seed)`. Random word = `keccak256(seed, blockhash(commitBlock + 1),
   acquisitionId, tokenId)`. Burn iff the top 128 bits × 10,000 < 5000 × 2^128 (an exact half, no
   modulo). Otherwise `pick(snapshotId, word)` chooses the recipient; if the snapshot is empty the NFT
   is burned instead. Emits `FlipResolved` then `Burned` or `Airdropped(tokenId, recipient, weight)`.
5. If nobody commits within 7200 blocks of the request, or the reveal window passes, anyone may call
   `timeoutBurn`, which burns.

### Randomness: what this is and is not

This is the brief's **commit-reveal mock**. The flipper cannot know `blockhash(commitBlock + 1)` when
committing, and a block builder does not know the seed, so neither alone steers the result. A flipper
who dislikes an outcome can withhold the reveal, but that only ever produces the burn branch, never an
airdrop to a chosen address. A colluding flipper-and-builder could bias results. Chainlink VRF was not
wired because no subscription keys are available to this task; migrating means replacing steps 3–4 with
a VRF request/fulfil pair and keeping `FlipRequested.requestId` as the VRF request id (README TODO).

### Purchase price band and what the mock market can and cannot do

`MockGotchiNFT.mint` is free and `MockBaazaar.list` is open to anyone, so a listing proves nothing about
value. The ETH the sink spends is therefore bounded per purchase, not trusted to the market:

- **Ceiling.** `FeeSink` never pays more than `MAX_BUY_PRICE` (0.05 ETH, five thresholds) for one NFT,
  whatever its balance. A listing priced at the whole accumulated pot is simply not bought.
- **Floor.** `MockBaazaar` refuses listings under `MIN_LIST_PRICE` (0.001 ETH) and the sink would skip
  them as well, so dust listings cannot turn every swap into a purchase. One threshold of fees funds at
  most ten purchases.
- **No freezing.** The 64 slots are not first-come. When the market is full a strictly cheaper listing
  evicts the most expensive one, so unaffordable listings cannot keep cheaper sellers out.
- **Remaining trust assumption.** Inside the band any seller of a free mock mint can be paid from the
  fees. That is inherent to a mock collection anyone can mint. The band limits each payment; it does
  not make mock NFTs valuable. A live Baazaar integration should keep the band and add a collection
  allowlist.

### Holder weighting: snapshot of held balances, opt-in, exclusions

- **Snapshot, not live.** A holder's weight in a flip is `min(recorded balance, balance at the commit)`.
  The recorded balance is what the holder held when they called `enroll()` (or last called `refresh()`).
  Tokens bought later add nothing until `refresh()`; tokens sold count against the holder at once.
- **Maturity.** FlipEscrow snapshots with `snapshotFor(purchase block)`: a recorded weight counts only if
  it was in place `ENROLL_MATURITY_BLOCKS` (300) before the NFT was bought. Raising a weight with
  `refresh()` restarts its maturity; lowering does not. Buying tokens around the commit transaction and
  selling them afterwards therefore buys no odds. To gain weight someone has to hold the tokens from an
  hour before the purchase until the commit, which is holding, not a round trip.
- **After the commit** nothing changes the table: a holder who sells can still win that flip, a buyer
  cannot join it.
- **Opt-in.** Holders call `enroll()` themselves (minimum 1,000 GOTCHI). Contracts that never call it
  (PoolManager, hook, sink, escrow, market) are never candidates.
- **Excluded always:** zero balances (skipped when the snapshot is built), `0x…dEaD` and `address(0)`
  (cannot enrol). Anyone may `evict` a holder whose balance fell below the minimum.
- **Bounded, not first-come.** At most 128 enrolled holders, so a snapshot is one bounded transaction.
  When the registry is full, a caller whose balance is strictly larger than the smallest recorded weight
  is admitted (anyone at or below it is refused in constant gas) and displaces the entry with the
  smallest *effective* weight, `min(recorded, live balance)`. The displacement scans the registry once
  (at most 128 `balanceOf` reads, about 1.2M gas) and trims every stale recorded weight it passes down
  to the live balance. The registry therefore converges on the 128 largest opted-in holders, dust
  addresses cannot lock anyone out, and an address that enrolled and then moved its tokens on is the
  next entry displaced, not an honest holder. Anyone may also `trim(holder)` a single recorded weight
  down to the holder's live balance at any time, which lowers the bar the constant-gas test uses.
- **Residual griefing.** With a full registry, someone who temporarily holds more than the smallest
  entry can displace it and then sell. One pile of tokens displaces at most one entry smaller than
  itself however many fresh addresses it is hopped through: every later hop evicts the previous hop
  address, whose live balance is zero. The displaced holder can re-enrol once the intruder's entry is
  trimmed (or displaced), but their maturity restarts. Each such displacement costs the attacker a pool
  round trip (two hook fees) per pile and only ever affects the smallest entry of a full registry.
- **Deterministic.** `pick` maps `word % totalWeight` onto the cumulative table with a binary search.
- `snapshot()` (no maturity filter) remains available to anyone for inspection; FlipEscrow never uses it.

## Events for the UI (indexed fields are stable)

```solidity
event FeesCollected(address indexed pool, uint256 amountEth);                       // GotchiFeeHook
event BuyTriggered(uint256 indexed listingId, uint256 priceEth, uint256 tokenId);   // FeeSink
event FlipRequested(uint256 indexed acquisitionId, uint256 tokenId, bytes32 requestId); // FlipEscrow
event FlipResolved(uint256 indexed acquisitionId, uint256 tokenId, bool burned, address indexed recipient);
event Burned(uint256 indexed tokenId, address indexed to);                          // FlipEscrow
event Airdropped(uint256 indexed tokenId, address indexed recipient, uint256 weight); // FlipEscrow
event ListingMocked(uint256 indexed listingId, uint256 tokenId, uint256 price);     // MockBaazaar
```

They are declared once in `src/interfaces/IGotchiEvents.sol`, so each contract's ABI lists all seven;
the emitter is given above. Supporting events: `SwapFeeSkimmed`, `BuyPoked`, `FeeReceived`,
`BuyForwarded`, `FlipCommitted`, `FlipTimedOut`, `ListingSold`, `ListingCancelled`, `ProceedsWithdrawn`,
`ListingEvicted`, `HolderEnrolled`, `HolderEvicted`, `HolderDisplaced`, `HolderRefreshed`, `SnapshotTaken`,
`PoolInitialized`, `PoolRealigned`, `LiquiditySeeded`.

ABIs: `docs/abi/<Contract>.json`.

## Build and test (offline)

Dependencies are vendored as plain files under `lib/` (forge-std 1.16.2, OpenZeppelin 5.7.0,
Uniswap v4-core 1.0.2 sources, `LiquidityAmounts` from v4-periphery, solmate `Owned`). No git
submodules, no network.

```sh
forge build          # solc 0.8.26, evm cancun (v4-core needs transient storage), bytecode_hash = none
forge test           # 128 tests: 9 suites incl. fuzz, against the real PoolManager
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy   # local dry run, mines the hook salt
```

Test coverage by requirement:

| Requirement | Tests |
| --- | --- |
| token transfer / supply / weight exclusions | `LaunchToken.t.sol`, `HolderWeightedPicker.t.sol` |
| fee calculation, hook→sink ETH flow, all four swap shapes, partial fills, in-swap purchase with a full market, fuzz | `GotchiFeeHook.t.sol` |
| threshold / no-buy, price band, reentrancy-safe FeeSink | `FeeSink.t.sol` (malicious re-entering market, catching and bubbling) |
| cheapest listing, seller payment, NFT transfer, price floor, eviction when full | `MockBaazaar.t.sol` |
| forced burn / forced airdrop / timeouts / empty snapshot | `FlipEscrow.t.sol` (block hash steered with `vm.setBlockhash`) |
| deterministic weighted picker, displacement by effective weight (hopped pile, keeper capture), maturity, trim | `HolderWeightedPicker.t.sol` (fuzz against a linear scan) |
| end-to-end fees → buy → flip with event assertions | `EndToEnd.t.sol` |
| forever liquidity, price band, refunds, donations, hostile pre-initialization | `ForeverLiquidity.t.sol` |
| deployment recipe and hook address mining | `Deployment.t.sol` |

Tests read no environment variables and do not depend on the caller address; they go through the same
`deployAll` recipe the script uses (`script/GotchiDeployment.sol`).

## Deployment (operator, optional)

The scripts read **no keys**; sign with `--ledger`, `--account <name>` or whatever the operator uses.

```sh
# 1. everything except liquidity
EXPECTED_CHAIN_ID=11155111 GOTCHI_OWNER=<owner> \
  forge script script/Deploy.s.sol:Deploy --rpc-url $SEPOLIA_RPC --broadcast --ledger
#    optional: GOTCHI_TOKEN=<existing LaunchToken> to reuse a token instead of deploying one

# 2. open the pool and lock INITIAL_LIQUIDITY_ETH + INITIAL_LIQUIDITY_TOKENS forever
FOREVER_LIQUIDITY=<address printed above> EXPECTED_CHAIN_ID=11155111 \
  forge script script/SeedPool.s.sol:SeedPool --rpc-url $SEPOLIA_RPC --broadcast --ledger
```

Order inside `Deploy`: `LaunchToken` (unless `GOTCHI_TOKEN`) → `MockGotchiNFT` → `MockBaazaar(nft)` →
`HolderWeightedPicker(token)` → `FlipEscrow(owner, nft, picker)` → `FeeSink(owner, market, escrow)` →
`GotchiHookDeployer(broadcaster)` → `hookDeployer.deploy(minedSalt, POOL_MANAGER, feeSink)` →
`ForeverLiquidity(POOL_MANAGER, token, hook)`. If `GOTCHI_OWNER` is the broadcaster the script also
runs the two owner-only wiring calls `escrow.setFeeSink(feeSink)` and `feeSink.setHook(hook)`;
otherwise the owner must send them (the script prints a reminder). Until both are done the sink cannot
register flips and the hook's pokes are rejected (fees still accumulate safely).

**Seeding after a factory launch.** With the default launch split the factory routes 80% of the supply
to its own unhooked pool and 10% to the swarm, leaving the requester wallet 100,000,000 GOTCHI.
`SeedPool` pulls `INITIAL_LIQUIDITY_TOKENS` = 50,000,000 GOTCHI and 0.1 ETH from that wallet, which
fits. To seed deeper, either choose a smaller factory pool share at launch or raise both constants in
proportion (the ratio sets the price). Only the hooked forever pool feeds `FeeSink`; trades on the
factory's unhooked launch pool pay no hook fee and trigger no purchases.

**If someone initializes the pool first.** `PoolManager.initialize` is permissionless and the brief
forbids an initialize gate, so a stranger can open the forever pool key at any price before `SeedPool`
runs. While that pool is empty, `seed` moves it to the requested opening price itself (a swap on an empty
pool exchanges nothing) and then adds liquidity, so `SeedPool` works unchanged. If a stranger also added
liquidity at a price outside the band, `seed` reverts `PriceOutOfBand`; arbitrage against that
liquidity (or a wider `PRICE_BAND_BPS`) resolves it.

**Hook address.** v4 reads permissions from the hook address, so `GotchiFeeHook` must live at an
address whose low 14 bits are exactly `0x00CC`; its constructor reverts otherwise. `GotchiHookDeployer`
mines the CREATE2 salt on-chain (`findSalt`, ~16k keccaks expected) and is the hook's `DEPLOYER`. A
deployer that cannot choose the salt (for example a generic factory) cannot deploy this hook; deploy it
through the hook deployer and leave the hook's `constructorArgs` as `[POOL_MANAGER]`.

**Launch-factory note.** In an IMD project launch the factory deploys `LaunchToken` and may deploy the
application contracts whose constructors take only addresses (`MockGotchiNFT`, `MockBaazaar`,
`HolderWeightedPicker`, `FlipEscrow` with `$owner`, `FeeSink` with `$owner`, `GotchiHookDeployer` with
`$owner`). The hook and `ForeverLiquidity` are then deployed by the owner through
`GotchiHookDeployer.deploy` and a plain `new`, followed by the two wiring calls. The factory's own
launch pool (with its `PoolInitializationGuard`) is separate from the hooked forever pool described here.

## Operational responsibilities

| Who | What |
| --- | --- |
| Owner of `FeeSink` / `FlipEscrow` | one-shot wiring; keeper calls to `tryBuy` when needed; rotating the flipper; two-step ownership transfer. Cannot withdraw ETH or NFTs. |
| Flipper | commit a fresh secret seed per acquisition promptly, reveal between `commitBlock+2` and `commitBlock+202`. Missing it burns the NFT (anyone can `timeoutBurn`). Never reuse a seed. |
| Hook deployer owner | run `deploy` once with the mined salt. |
| Pool seeder | `SeedPool` once; liquidity is unrecoverable by design. |
| Holders | `enroll` at least 300 blocks before the purchases they want to count for; `refresh` after buying more (restarts maturity). |
| Anyone | `enroll` / `trim` / `evict`, `list` mock gotchis, `withdrawProceeds`, `timeoutBurn`, add forever liquidity. |

## Known limitations and TODOs

- **Mock randomness.** Replace commit-reveal with Chainlink VRF v2.5 on Sepolia once a subscription
  exists; `FlipRequested.requestId` becomes the VRF request id, `commit`/`reveal` are replaced by
  `requestRandomWords`/`fulfillRandomWords`, events unchanged.
- **Mock market and NFT.** Later Base / Aavegotchi Diamond / live Baazaar integration is out of scope
  here; the `IMockBaazaar` surface (`cheapest`, `buyCheapest(id, to)`) is the seam to re-implement.
- **In-swap purchases cost the swapper gas** (bounded by `TRIGGER_GAS`); a swap that triggers a purchase
  is ~250k gas heavier with a few listings and up to ~485k with all 64 slots active.
- **ETH-specified swaps do not partially fill** (see Fee mechanics); they revert at the price limit.
- **Mock NFTs are free to mint**, so fees can be spent on worthless listings inside the price band.
- **Donated or accrued pool fees** are re-donated to the pool on each `seed`; a liquidity provider who
  adds in-range liquidity just before a `seed` would share in that re-donation.
- **Stray NFTs** sent straight to `FlipEscrow` outside the sink flow are not tracked and stay there.
- **Airdrop to contracts** uses `transferFrom` (no receiver check) so a recipient that cannot handle
  ERC-721 cannot block resolution; a contract wallet that enrols must be able to move ERC-721s.
- **Registry displacement griefing** on a full registry costs the attacker pool fees per pile of tokens
  and only resets the maturity of the single smallest entry per pile; hopping one pile through fresh
  addresses evicts the previous hop address, not further holders (see holder weighting).
- Slither 0.11.6 was run on the previous revision (not available on the machine that made the
  displacement-scan change): no high-impact findings; one medium (`reentrancy-no-eth` in
  `FlipEscrow.commit`, which is `nonReentrant` and calls only the immutable picker). See `REVIEW.md`.
