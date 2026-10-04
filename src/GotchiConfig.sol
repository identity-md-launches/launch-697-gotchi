// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title GotchiConfig
/// @notice Compile-time parameters shared by every $GOTCHI contract, the deploy script and the tests.
/// @dev Everything here is a constant on purpose: there is no post-deploy admin setter for any of these
/// values. Change a number, rebuild, redeploy. Values marked "configurable" are the launch knobs the
/// brief left open (initial liquidity, implied market cap); the rest are the brief's fixed parameters.
library GotchiConfig {
    /// @notice Uniswap v4 PoolManager on Sepolia (chain id 11155111). The only hook constructor argument.
    address internal constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    /// @notice Target chain for the optional deploy script.
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    /// @notice Hook fee skimmed in ETH on every swap of an ETH-paired pool, in basis points.
    uint256 internal constant FEE_BPS = 30;

    /// @notice Basis-point denominator.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice FeeSink attempts a Baazaar purchase only once its balance reaches this amount.
    uint256 internal constant MIN_BUY_THRESHOLD = 0.01 ether;

    /// @notice Probability, in basis points, that a FlipEscrow resolution burns the NFT (the rest airdrop).
    uint256 internal constant FLIP_BURN_BPS = 5000;

    /// @notice Where burned NFTs are sent. Excluded from holder weighting.
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Fixed $GOTCHI supply (18 decimals). Fixed by the launch token rules, not configurable.
    uint256 internal constant TOKEN_SUPPLY = 1_000_000_000e18;

    /// @notice Purchase band of FeeSink: it never pays more than this for one NFT, whatever it holds.
    /// @dev Five thresholds. Bounds what a single listing can take out of the accumulated fees.
    uint256 internal constant MAX_BUY_PRICE = 0.05 ether;

    /// @notice Lowest price MockBaazaar accepts for a listing and FeeSink pays for one NFT.
    /// @dev A tenth of the threshold, so one threshold of fees funds at most ten purchases.
    uint256 internal constant MIN_LIST_PRICE = 0.001 ether;

    /// @notice Configurable: ETH the operator seeds the forever pool with.
    uint256 internal constant INITIAL_LIQUIDITY_ETH = 0.1 ether;

    /// @notice Configurable: $GOTCHI the operator seeds the forever pool with.
    /// @dev Implied opening price = INITIAL_LIQUIDITY_ETH / INITIAL_LIQUIDITY_TOKENS per token, so the
    /// implied fully-diluted market cap is TOKEN_SUPPLY * INITIAL_LIQUIDITY_ETH / INITIAL_LIQUIDITY_TOKENS
    /// = 2 ETH with the defaults. Sized to half of the 100,000,000 $GOTCHI (10% of supply) a requester
    /// wallet holds after a default factory launch, so SeedPool can run without changing the split.
    uint256 internal constant INITIAL_LIQUIDITY_TOKENS = 50_000_000e18;

    /// @notice LP fee of the forever pool (pips). 0: the locked position earns nothing, the hook fee is the
    /// only fee a swapper pays. Configurable.
    uint24 internal constant POOL_LP_FEE = 0;

    /// @notice Tick spacing of the forever pool.
    int24 internal constant POOL_TICK_SPACING = 60;

    /// @notice Minimum $GOTCHI balance to enrol in the holder registry (anti-dust). Configurable.
    uint256 internal constant MIN_ENROLL_BALANCE = 1_000e18;

    /// @notice Upper bound on enrolled holders so a snapshot fits comfortably in one transaction.
    /// @dev When the registry is full a larger holder displaces the smallest entry, so the cap selects
    /// the largest opted-in holders instead of the first ones.
    uint256 internal constant MAX_HOLDERS = 128;

    /// @notice Blocks a holder's recorded weight must have been in place before an NFT purchase for it
    /// to count in that purchase's flip (about one hour on Sepolia). Configurable.
    uint256 internal constant ENROLL_MATURITY_BLOCKS = 300;

    /// @notice Upper bound on simultaneously active mock listings so `cheapest()` is bounded.
    /// @dev When the market is full a strictly cheaper listing evicts the most expensive one.
    uint256 internal constant MAX_ACTIVE_LISTINGS = 64;

    /// @notice Gas forwarded by the hook to FeeSink.tryBuy() inside afterSwap. Bounds the swapper's cost.
    /// @dev Sized for a full market: tryBuy with MAX_ACTIVE_LISTINGS listings is measured in
    /// test/GotchiFeeHook.t.sol and must stay well under this.
    uint256 internal constant TRIGGER_GAS = 1_000_000;

    /// @notice Blocks after the commit block before a reveal is accepted (entropy block = commit + 1).
    uint256 internal constant REVEAL_DELAY_BLOCKS = 2;

    /// @notice Blocks (after the delay) during which the reveal is accepted; afterwards anyone may time out.
    uint256 internal constant REVEAL_WINDOW_BLOCKS = 200;

    /// @notice Blocks after a FlipRequested without a commit before anyone may time the flip out (burn).
    uint256 internal constant COMMIT_TIMEOUT_BLOCKS = 7200;
}
