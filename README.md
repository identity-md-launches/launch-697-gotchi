# $GOTCHI — forever pool, fee hook, Baazaar flips (Sepolia)

A standalone Foundry project. `$GOTCHI` (contract `LaunchToken`) trades against ETH in a permanent
full-range Uniswap v4 pool. A v4 hook skims 0.30% of the ETH side of every swap into `FeeSink`.
Whenever the sink holds at least 0.01 ETH it buys the cheapest listed mock Aavegotchi from
`MockBaazaar` and hands it to `FlipEscrow`, which resolves each acquisition 50/50 under a
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
| `FeeSink` | Receives ETH. `tryBuy()` buys the cheapest listing once balance ≥ `MIN_BUY_THRESHOLD`, delivers the NFT to `FlipEscrow` and registers the flip. `nonReentrant`, checks-effects-interactions, no withdraw/sweep/treasury. | `owner` (Ownable2Step): `setHook` once; may call `tryBuy` as a keeper |
| `MockBaazaar` | Mock ETH-priced ERC-721 marketplace: `list`, `cancel`, `cheapest()`, `buyCheapest(expectedListingId, to)`. Seller proceeds are pull payments (`withdrawProceeds`). Active listings capped at 64. | none |
| `MockGotchiNFT` | Mock Aavegotchi ERC-721, permissionless `mint`. | none |
| `FlipEscrow` | Holds acquired NFTs; commit-reveal resolution; burn or weighted airdrop; timeouts. | `owner` (Ownable2Step): `setFeeSink` once, `setFlipper`; `flipper` commits |
| `HolderWeightedPicker` | Opt-in holder registry (`enroll`, `evict`), balance snapshots, deterministic weighted `pick`. | none |
| `ForeverLiquidity` | Opens the ETH/`$GOTCHI` pool with the hook and holds full-range liquidity that has no removal path. Anyone may `seed` more. | none |
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
| `INITIAL_LIQUIDITY_ETH` / `INITIAL_LIQUIDITY_TOKENS` | 1 ETH / 500,000,000 GOTCHI | **configurable**; implied opening price 2 × 10⁻⁹ ETH per GOTCHI, implied FDV 2 ETH |
| `POOL_LP_FEE` / `POOL_TICK_SPACING` | 0 / 60 | configurable; with LP fee 0 the hook fee is the only fee a swapper pays |
| `MIN_ENROLL_BALANCE` / `MAX_HOLDERS` | 1,000 GOTCHI / 128 | picker registry bounds, configurable |
| `MAX_ACTIVE_LISTINGS` | 64 | market bound |
| `TRIGGER_GAS` | 700,000 | gas stipend for the in-swap purchase attempt |
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

A pool whose currency0 is not native ETH, or a hook that has not been wired, charges nothing.
There is no `beforeInitialize` gate and no liquidity gate: anyone may open ETH/anything pools with this
hook (they would only feed the sink) and anyone may add liquidity.

## Purchase and flip flow

1. `afterSwap` calls `FeeSink.tryBuy()` with `TRIGGER_GAS` inside try/catch. `tryBuy` returns `false`
   without reverting when the balance is below threshold, nothing is listed, or the cheapest listing
   costs more than the balance. A revert or out-of-gas inside the sink is swallowed; the swap always
   succeeds as long as the sink can receive ETH. The owner may also call `tryBuy()` as a keeper (for
   example when a listing appears while no swaps happen).
2. `tryBuy` emits `BuyTriggered(listingId, priceEth, tokenId)`, pays exactly the listing price to
   `MockBaazaar.buyCheapest(listingId, escrow)` (the market re-checks that this listing is still the
   cheapest, credits the seller, transfers the NFT to the escrow) and calls `FlipEscrow.requestFlip`,
   which emits `FlipRequested(acquisitionId, tokenId, requestId)`.
3. The flipper calls `commit(acquisitionId, keccak256(abi.encode(seed)))`. The commit freezes the holder
   snapshot (`HolderWeightedPicker.snapshot()`), so balance moves after this point do not matter.
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

### Holder weighting: snapshot, opt-in, exclusions

- **Snapshot, not live.** Weights are the enrolled holders' balances at the commit block. A holder who
  sells after the commit can still win that flip; a buyer who enrols after the commit cannot.
- **Opt-in.** Holders call `enroll()` themselves (minimum 1,000 GOTCHI). Contracts that never call it
  (PoolManager, hook, sink, escrow, market) are never candidates.
- **Excluded always:** zero balances (skipped when the snapshot is built), `0x…dEaD` and `address(0)`
  (cannot enrol). Anyone may `evict` a holder whose balance fell below the minimum.
- **Bounded.** At most 128 enrolled holders, so a snapshot is one bounded transaction (one storage
  write per holder). A griefer filling the registry needs 128 × 1,000 GOTCHI held across addresses.
- **Deterministic.** `pick` maps `word % totalWeight` onto the cumulative table with a binary search.

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
`HolderEnrolled`, `HolderEvicted`, `SnapshotTaken`, `PoolInitialized`, `LiquiditySeeded`.

ABIs: `docs/abi/<Contract>.json`.

## Build and test (offline)

Dependencies are vendored as plain files under `lib/` (forge-std 1.16.2, OpenZeppelin 5.7.0,
Uniswap v4-core 1.0.2 sources, `LiquidityAmounts` from v4-periphery, solmate `Owned`). No git
submodules, no network.

```sh
forge build          # solc 0.8.26, evm cancun (v4-core needs transient storage), bytecode_hash = none
forge test           # 102 tests: 9 suites incl. fuzz, against the real PoolManager
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy   # local dry run, mines the hook salt
```

Test coverage by requirement:

| Requirement | Tests |
| --- | --- |
| token transfer / supply / weight exclusions | `LaunchToken.t.sol`, `HolderWeightedPicker.t.sol` |
| fee calculation, hook→sink ETH flow, all four swap shapes, fuzz | `GotchiFeeHook.t.sol` |
| threshold / no-buy, reentrancy-safe FeeSink | `FeeSink.t.sol` (malicious re-entering market, catching and bubbling) |
| cheapest listing, seller payment, NFT transfer | `MockBaazaar.t.sol` |
| forced burn / forced airdrop / timeouts / empty snapshot | `FlipEscrow.t.sol` (block hash steered with `vm.setBlockhash`) |
| deterministic weighted picker | `HolderWeightedPicker.t.sol` (fuzz against a linear scan) |
| end-to-end fees → buy → flip with event assertions | `EndToEnd.t.sol` |
| forever liquidity, price band, refunds | `ForeverLiquidity.t.sol` |
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
| Anyone | `enroll` / `evict`, `list` mock gotchis, `withdrawProceeds`, `timeoutBurn`, add forever liquidity. |

## Known limitations and TODOs

- **Mock randomness.** Replace commit-reveal with Chainlink VRF v2.5 on Sepolia once a subscription
  exists; `FlipRequested.requestId` becomes the VRF request id, `commit`/`reveal` are replaced by
  `requestRandomWords`/`fulfillRandomWords`, events unchanged.
- **Mock market and NFT.** Later Base / Aavegotchi Diamond / live Baazaar integration is out of scope
  here; the `IMockBaazaar` surface (`cheapest`, `buyCheapest(id, to)`) is the seam to re-implement.
- **In-swap purchases cost the swapper gas** (bounded by `TRIGGER_GAS`); a swap that triggers a purchase
  is ~250k gas heavier.
- **Stray NFTs** sent straight to `FlipEscrow` outside the sink flow are not tracked and stay there.
- **Airdrop to contracts** uses `transferFrom` (no receiver check) so a recipient that cannot handle
  ERC-721 cannot block resolution; a contract wallet that enrols must be able to move ERC-721s.
- **Registry griefing** is bounded, not prevented (see holder weighting).
- Slither was not available on the build box; `forge lint` ran clean of correctness classes (see `REVIEW.md`).
