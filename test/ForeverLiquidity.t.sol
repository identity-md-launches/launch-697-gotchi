// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GotchiFixture} from "./utils/GotchiFixture.sol";
import {ForeverLiquidity} from "../src/ForeverLiquidity.sol";
import {GotchiConfig} from "../src/GotchiConfig.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract ForeverLiquidityTest is GotchiFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function test_poolKeyAndPrice() public view {
        assertEq(Currency.unwrap(key.currency0), address(0), "ETH is currency0");
        assertEq(Currency.unwrap(key.currency1), address(token));
        assertEq(address(key.hooks), address(hook));
        assertEq(key.fee, GotchiConfig.POOL_LP_FEE);
        assertEq(key.tickSpacing, GotchiConfig.POOL_TICK_SPACING);
        assertEq(forever.currentSqrtPriceX96(), initialSqrtPrice);
        assertEq(forever.TICK_LOWER(), TickMath.minUsableTick(60));
        assertEq(forever.TICK_UPPER(), TickMath.maxUsableTick(60));
    }

    function test_sqrtPriceFromAmountsMatchesRatio() public view {
        // 500M tokens per 1 ETH -> price 5e8 -> sqrt 22360.679...
        uint160 p = forever.sqrtPriceFromAmounts(1 ether, 500_000_000e18);
        uint256 priceX192 = uint256(p) * uint256(p);
        uint256 price = priceX192 / (1 << 192);
        assertApproxEqRel(price, 500_000_000, 0.0001e18);
        assertEq(p, initialSqrtPrice);
    }

    function test_seedLockedTheConfiguredLiquidity() public view {
        assertGt(forever.totalLiquidity(), 0);
        bytes32 positionId =
            Position.calculatePositionKey(address(forever), forever.TICK_LOWER(), forever.TICK_UPPER(), bytes32(0));
        uint128 liquidity = IPoolManager(address(manager)).getPositionLiquidity(key.toId(), positionId);
        assertEq(liquidity, forever.totalLiquidity());
        assertApproxEqAbs(
            address(manager).balance, GotchiConfig.INITIAL_LIQUIDITY_ETH, 1e6, "ETH went in (minus rounding dust)"
        );
        assertApproxEqRel(token.balanceOf(address(manager)), GotchiConfig.INITIAL_LIQUIDITY_TOKENS, 0.001e18);
        assertEq(address(forever).balance, 0, "no ETH stuck in the seeder");
        assertEq(token.balanceOf(address(forever)), 0, "no tokens stuck in the seeder");
    }

    function test_anyoneCanSeedMoreAndLeftoversAreRefunded() public {
        token.transfer(alice, 1_000_000e18);
        uint256 ethBefore = alice.balance;
        vm.startPrank(alice);
        token.approve(address(forever), 1_000_000e18);
        // far more ETH than the tokens justify at this price: most ETH comes back
        uint128 added =
            forever.seed{value: 1 ether}(initialSqrtPrice, initialSqrtPrice - 1, initialSqrtPrice + 1, 1_000_000e18);
        vm.stopPrank();
        assertGt(added, 0);
        assertGt(alice.balance, ethBefore - 1 ether, "ETH refunded");
        assertLt(alice.balance, ethBefore, "some ETH used");
        assertEq(address(forever).balance, 0);
        assertEq(token.balanceOf(address(forever)), 0);
    }

    function test_seedRevertsOutsidePriceBand() public {
        token.approve(address(forever), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                ForeverLiquidity.PriceOutOfBand.selector, initialSqrtPrice, initialSqrtPrice + 1, initialSqrtPrice + 2
            )
        );
        forever.seed{value: 1e15}(initialSqrtPrice, initialSqrtPrice + 1, initialSqrtPrice + 2, 1e18);
        vm.expectRevert(ForeverLiquidity.InvalidBand.selector);
        forever.seed{value: 1e15}(initialSqrtPrice, initialSqrtPrice + 2, initialSqrtPrice + 1, 1e18);
    }

    function test_seedRevertsOnNothing() public {
        vm.expectRevert(ForeverLiquidity.NothingToSeed.selector);
        forever.seed(initialSqrtPrice, initialSqrtPrice, initialSqrtPrice, 0);
        vm.expectRevert(ForeverLiquidity.NothingToSeed.selector);
        forever.sqrtPriceFromAmounts(0, 1);
    }

    function test_callbackRejectsNonManager() public {
        vm.expectRevert(ForeverLiquidity.NotPoolManager.selector);
        forever.unlockCallback("");
    }

    function test_noWayToRemoveLiquidity() public {
        string[5] memory signatures =
            ["withdraw()", "removeLiquidity(uint128)", "collect()", "burn(uint128)", "sweep(address)"];
        for (uint256 i = 0; i < signatures.length; ++i) {
            (bool ok,) = address(forever).call(abi.encodeWithSignature(signatures[i], uint128(1)));
            assertFalse(ok, signatures[i]);
        }
    }

    function test_freshSeederInitializesAnEmptyPool() public {
        ForeverLiquidity fresh = new ForeverLiquidity(address(manager), address(token), address(hook));
        // the pool key is identical, so the pool already exists at the current price
        assertEq(fresh.currentSqrtPriceX96(), initialSqrtPrice);
        vm.expectRevert(ForeverLiquidity.ZeroAddress.selector);
        new ForeverLiquidity(address(0), address(token), address(hook));
    }
}
