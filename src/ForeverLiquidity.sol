// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Slot0, Slot0Library} from "v4-core/types/Slot0.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {GotchiConfig} from "./GotchiConfig.sol";

/// @title ForeverLiquidity
/// @notice Opens the ETH/$GOTCHI pool with GotchiFeeHook and holds full-range liquidity that can never be
/// removed: there is no function that decreases liquidity or collects, so whatever is seeded stays.
/// @dev Anyone may `seed` (adding permanent liquidity is a gift to the pool). The caller passes a price
/// band; if the pool already exists at a price outside the band the call reverts, so a front-run swap on
/// an empty pool cannot make a seeder deposit at a manipulated price. Unused ETH and tokens are refunded.
/// No admin role.
contract ForeverLiquidity is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using Slot0Library for Slot0;

    struct SeedData {
        address seeder;
        uint128 liquidity;
        uint256 maxEth;
        uint256 maxTokens;
    }

    IPoolManager public immutable POOL_MANAGER;
    IERC20 public immutable TOKEN;
    IHooks public immutable HOOK;

    uint24 public constant LP_FEE = GotchiConfig.POOL_LP_FEE;
    int24 public constant TICK_SPACING = GotchiConfig.POOL_TICK_SPACING;
    int24 public immutable TICK_LOWER;
    int24 public immutable TICK_UPPER;

    /// @notice Liquidity this contract has locked forever.
    uint128 public totalLiquidity;

    event PoolInitialized(PoolId indexed poolId, uint160 sqrtPriceX96, int24 tick);
    event LiquiditySeeded(address indexed seeder, uint128 liquidity, uint256 ethUsed, uint256 tokensUsed);
    event PositionIncreased(uint128 liquidity, BalanceDelta delta, BalanceDelta feesAccrued);

    error ZeroAddress();
    error NotPoolManager();
    error PriceOutOfBand(uint160 current, uint160 min, uint160 max);
    error InvalidBand();
    error NothingToSeed();
    error RefundFailed();
    error SettleMismatch();

    constructor(address poolManager, address token, address hook) {
        if (poolManager == address(0) || token == address(0) || hook == address(0)) revert ZeroAddress();
        POOL_MANAGER = IPoolManager(poolManager);
        TOKEN = IERC20(token);
        HOOK = IHooks(hook);
        TICK_LOWER = TickMath.minUsableTick(GotchiConfig.POOL_TICK_SPACING);
        TICK_UPPER = TickMath.maxUsableTick(GotchiConfig.POOL_TICK_SPACING);
    }

    /// @notice The pool key of the forever pool (ETH is currency0 by construction).
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(TOKEN)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: HOOK
        });
    }

    /// @notice Current sqrt price of the pool, 0 when not initialized.
    function currentSqrtPriceX96() public view returns (uint160) {
        bytes32 slot = StateLibrary._getPoolStateSlot(poolKey().toId());
        return Slot0.wrap(POOL_MANAGER.extsload(slot)).sqrtPriceX96();
    }

    /// @notice sqrtPriceX96 implied by seeding `tokenAmount` against `ethAmount`.
    function sqrtPriceFromAmounts(uint256 ethAmount, uint256 tokenAmount) external pure returns (uint160) {
        if (ethAmount < 1 || tokenAmount < 1) revert NothingToSeed();
        uint256 ratioX192 = FullMath.mulDiv(tokenAmount, 1 << 192, ethAmount);
        return uint160(Math.sqrt(ratioX192));
    }

    /// @notice Initialize the pool if needed and add full-range liquidity. Pass ETH as msg.value and
    /// approve `tokenAmount` beforehand. Reverts unless the pool price ends up inside
    /// [minSqrtPriceX96, maxSqrtPriceX96]. Leftovers are refunded.
    function seed(uint160 initialSqrtPriceX96, uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96, uint256 tokenAmount)
        external
        payable
        nonReentrant
        returns (uint128 liquidity)
    {
        if (minSqrtPriceX96 > maxSqrtPriceX96) revert InvalidBand();
        PoolKey memory key = poolKey();
        uint160 price = currentSqrtPriceX96();
        if (price < 1) {
            int24 tick = POOL_MANAGER.initialize(key, initialSqrtPriceX96);
            emit PoolInitialized(key.toId(), initialSqrtPriceX96, tick);
            price = initialSqrtPriceX96;
        }
        if (price < minSqrtPriceX96 || price > maxSqrtPriceX96) {
            revert PriceOutOfBand(price, minSqrtPriceX96, maxSqrtPriceX96);
        }
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            price,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            msg.value,
            tokenAmount
        );
        if (liquidity < 1) revert NothingToSeed();
        if (tokenAmount > 0) TOKEN.safeTransferFrom(msg.sender, address(this), tokenAmount);
        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(SeedData({seeder: msg.sender, liquidity: liquidity, maxEth: msg.value, maxTokens: tokenAmount}))
        );
        (uint256 ethUsed, uint256 tokensUsed) = abi.decode(result, (uint256, uint256));
        emit LiquiditySeeded(msg.sender, liquidity, ethUsed, tokensUsed);
        uint256 tokenRefund = tokenAmount - tokensUsed;
        if (tokenRefund > 0) TOKEN.safeTransfer(msg.sender, tokenRefund);
        uint256 ethRefund = msg.value - ethUsed;
        if (ethRefund > 0) {
            (bool ok,) = payable(msg.sender).call{value: ethRefund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        SeedData memory seedData = abi.decode(data, (SeedData));
        totalLiquidity += seedData.liquidity;
        PoolKey memory key = poolKey();
        (BalanceDelta delta, BalanceDelta feesAccrued) = POOL_MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(seedData.liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        emit PositionIncreased(seedData.liquidity, delta, feesAccrued);
        uint256 ethOwed = delta.amount0() < 0 ? uint256(uint128(-delta.amount0())) : 0;
        uint256 tokensOwed = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;
        if (ethOwed > seedData.maxEth || tokensOwed > seedData.maxTokens) revert SettleMismatch();
        if (ethOwed > 0) {
            uint256 paidEth = POOL_MANAGER.settle{value: ethOwed}();
            if (paidEth != ethOwed) revert SettleMismatch();
        }
        if (tokensOwed > 0) {
            POOL_MANAGER.sync(key.currency1);
            TOKEN.safeTransfer(address(POOL_MANAGER), tokensOwed);
            uint256 paidTokens = POOL_MANAGER.settle();
            if (paidTokens != tokensOwed) revert SettleMismatch();
        }
        return abi.encode(ethOwed, tokensOwed);
    }
}
