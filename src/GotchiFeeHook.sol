// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {IFeeSink} from "./interfaces/IFeeSink.sol";
import {IGotchiEvents} from "./interfaces/IGotchiEvents.sol";
import {GotchiConfig} from "./GotchiConfig.sol";

/// @title GotchiFeeHook
/// @notice Uniswap v4 hook that skims FEE_BPS of the ETH side of every swap into FeeSink.
/// @dev Permissions: beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta (address flags
/// 0x00CC). No initialize or liquidity gates: anyone may open an ETH-paired pool with this hook and anyone
/// may add liquidity. Pools whose currency0 is not native ETH are passed through without a fee.
///
/// Fee mechanics. The fee is always denominated in ETH (currency0 of an ETH pair):
///  - ETH is the specified currency (ETH exact-in, or ETH exact-out): beforeSwap returns a positive
///    specified delta of `fee` and takes it from the PoolManager straight to FeeSink.
///  - ETH is the unspecified currency (token exact-in, or token exact-out): afterSwap reads the ETH
///    amount from the swap delta, returns `fee` as the hook's unspecified delta and takes it.
/// The ETH moves PoolManager -> FeeSink by `take` (no ETH ever sits in the hook).
///
/// Partial fills. v4 stops a swap at `sqrtPriceLimitX96`. When ETH is the unspecified currency the fee
/// is sized from the realised ETH amount, so a partial fill pays FEE_BPS of what actually moved. When
/// ETH is the specified currency the fee was sized from the request in beforeSwap, and v4 gives a hook
/// no way to hand part of a specified-currency delta back afterwards, so afterSwap REVERTS
/// (`PartialFillUnsupported`) unless the pool swapped exactly the requested amount net of the fee. An
/// ETH-specified swap therefore fills completely or not at all, and the fee is always FEE_BPS of the
/// ETH that moved. Routers that bound slippage with amount limits (the usual way) are unaffected.
///
/// Fee basis. The fee is FEE_BPS of the amount named in the swap for ETH-specified swaps and FEE_BPS of
/// the pool's ETH leg otherwise. So ETH exact-in and token exact-in pay 30 bps of the gross ETH, while
/// ETH exact-out pays 30 bps of the net ETH received and token exact-out pays 30 bps on top of the
/// pool's ETH input (both 29.91 bps of the gross). FeesCollected amounts follow that per-shape basis.
///
/// afterSwap then pokes
/// FeeSink.tryBuy() with a bounded gas stipend inside try/catch so a purchase, a full market or a
/// reverting sink can never make a swap fail.
///
/// Wiring. The constructor takes only the PoolManager. `DEPLOYER` (the constructor's msg.sender, meant
/// to be GotchiHookDeployer) wires the FeeSink exactly once; until then the hook charges nothing.
contract GotchiFeeHook is IHooks, IGotchiEvents {
    using Hooks for IHooks;
    using SafeCast for uint256;

    /// @notice The v4 PoolManager this hook serves.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice The address that deployed the hook and may wire the sink once.
    address public immutable DEPLOYER;

    uint256 public constant FEE_BPS = GotchiConfig.FEE_BPS;
    uint256 public constant BPS_DENOMINATOR = GotchiConfig.BPS_DENOMINATOR;
    uint256 public constant TRIGGER_GAS = GotchiConfig.TRIGGER_GAS;

    /// @notice Where skimmed ETH goes. Zero until wired.
    IFeeSink public feeSink;

    /// @notice Lifetime ETH skimmed.
    uint256 public totalFeesCollected;

    event FeeSinkWired(address indexed feeSink);
    event SwapFeeSkimmed(PoolId indexed poolId, address indexed swapper, uint256 amountEth, bool viaBeforeSwap);
    event BuyPoked(bool bought);

    error NotPoolManager();
    error NotDeployer();
    error ZeroAddress();
    error AlreadyWired();
    error HookNotImplemented();
    error PartialFillUnsupported(uint256 requestedEth, uint256 filledEth);

    constructor(address poolManager) {
        if (poolManager == address(0)) revert ZeroAddress();
        POOL_MANAGER = IPoolManager(poolManager);
        DEPLOYER = msg.sender;
        IHooks(this).validateHookPermissions(getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    /// @notice The permissions encoded in this hook's address.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice One-shot wiring of the FeeSink by the deployer.
    function wire(address feeSink_) external {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (feeSink_ == address(0)) revert ZeroAddress();
        if (address(feeSink) != address(0)) revert AlreadyWired();
        feeSink = IFeeSink(feeSink_);
        emit FeeSinkWired(feeSink_);
    }

    /// @notice FEE_BPS of `ethAmount`, rounded down.
    function calculateFee(uint256 ethAmount) public pure returns (uint256) {
        return (ethAmount * FEE_BPS) / BPS_DENOMINATOR;
    }

    /// @notice True when the ETH side (currency0) is the swap's specified amount.
    function ethIsSpecified(SwapParams calldata params) public pure returns (bool) {
        // exact input (amountSpecified < 0) specifies the input currency: currency0 iff zeroForOne.
        // exact output specifies the output currency: currency0 iff !zeroForOne.
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    /// @inheritdoc IHooks
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_charges(key) || !ethIsSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 ethAmount =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = calculateFee(ethAmount);
        if (fee < 1) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        _skim(key, sender, fee, true);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (!_charges(key)) return (IHooks.afterSwap.selector, 0);
        int128 ethDelta = delta.amount0();
        uint256 ethMoved = ethDelta < 0 ? uint256(uint128(-ethDelta)) : uint256(uint128(ethDelta));
        uint256 fee = 0;
        if (ethIsSpecified(params)) {
            // The fee was taken in beforeSwap from the requested amount. Accept the swap only when the
            // pool moved the whole request net of that fee, so the fee is never charged on unfilled ETH.
            // Exact-in: the pool received request - fee. Exact-out: the pool paid out request + fee.
            bool exactIn = params.amountSpecified < 0;
            uint256 requested = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 preFee = calculateFee(requested);
            uint256 filled = exactIn ? ethMoved + preFee : (ethMoved > preFee ? ethMoved - preFee : 0);
            if (filled != requested) revert PartialFillUnsupported(requested, filled);
        } else {
            fee = calculateFee(ethMoved);
            if (fee > 0) _skim(key, sender, fee, false);
        }
        _poke();
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    /// @dev Effects and events first, then the single interaction (take to the sink).
    function _skim(PoolKey calldata key, address swapper, uint256 fee, bool viaBeforeSwap) private {
        totalFeesCollected += fee;
        emit FeesCollected(address(POOL_MANAGER), fee);
        emit SwapFeeSkimmed(key.toId(), swapper, fee, viaBeforeSwap);
        POOL_MANAGER.take(key.currency0, address(feeSink), fee);
    }

    /// @dev Best-effort purchase trigger. A revert or out-of-gas inside the sink is swallowed.
    function _poke() private {
        try feeSink.tryBuy{gas: TRIGGER_GAS}() returns (bool bought) {
            emit BuyPoked(bought);
        } catch {
            emit BuyPoked(false);
        }
    }

    function _charges(PoolKey calldata key) private view returns (bool) {
        return address(feeSink) != address(0) && key.currency0.isAddressZero();
    }

    // ---- hooks this contract does not implement (their address flags are off) ----

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
