// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {GotchiFixture} from "../utils/GotchiFixture.sol";
import {GotchiFeeHook} from "../../src/GotchiFeeHook.sol";

/// @notice Fee arithmetic of the hook checked against an independent 30 bps formula for all four swap
/// shapes, plus the ETH path hook -> FeeSink and the properties a swapper relies on.
contract HookFeePropertiesTest is GotchiFixture {
    bytes32 internal constant FEES_COLLECTED = keccak256("FeesCollected(address,uint256)");

    function _bps30(uint256 amount) internal pure returns (uint256) {
        return (amount * 30) / 10_000;
    }

    function _systemEth() internal view returns (uint256) {
        return address(manager).balance + address(feeSink).balance + address(market).balance;
    }

    // ---- the four swap shapes ----

    /// forge-config: default.fuzz.runs = 400
    function testFuzz_exactEthIn(uint256 ethIn) public {
        ethIn = bound(ethIn, 1, 50 ether);
        uint256 before = alice.balance;
        uint256 poolBefore = address(manager).balance;
        BalanceDelta d = buyTokens(alice, ethIn);
        uint256 fee = _bps30(ethIn);
        assertEq(before - alice.balance, ethIn, "swapper pays exactly the input");
        assertEq(address(feeSink).balance, fee, "sink holds the fee");
        assertEq(hook.totalFeesCollected(), fee);
        assertEq(address(manager).balance - poolBefore, ethIn - fee, "pool receives input minus fee");
        assertEq(uint256(uint128(d.amount1())), token.balanceOf(alice), "tokens delivered");
        assertEq(address(hook).balance, 0);
    }

    /// forge-config: default.fuzz.runs = 400
    function testFuzz_exactTokensOut(uint256 tokensOut) public {
        tokensOut = bound(tokensOut, 1, 400_000_000e18);
        uint256 before = alice.balance;
        uint256 poolBefore = address(manager).balance;
        swapAs(alice, true, int256(tokensOut), before);
        uint256 paid = before - alice.balance;
        uint256 poolLeg = address(manager).balance - poolBefore;
        uint256 fee = address(feeSink).balance;
        assertEq(token.balanceOf(alice), tokensOut, "exact output delivered");
        assertEq(paid, poolLeg + fee, "swapper pays pool leg plus fee, nothing else");
        assertEq(fee, _bps30(poolLeg), "fee is 30 bps of the ETH the pool took");
        assertEq(hook.totalFeesCollected(), fee);
    }

    /// forge-config: default.fuzz.runs = 400
    function testFuzz_exactTokensIn(uint256 tokensIn) public {
        tokensIn = bound(tokensIn, 1, 400_000_000e18);
        token.transfer(alice, tokensIn);
        uint256 before = alice.balance;
        uint256 poolBefore = address(manager).balance;
        sellTokens(alice, tokensIn);
        uint256 got = alice.balance - before;
        uint256 poolLeg = poolBefore - address(manager).balance;
        uint256 fee = address(feeSink).balance;
        assertEq(token.balanceOf(alice), 0, "exact input taken");
        assertEq(got + fee, poolLeg, "pool output is split between swapper and sink");
        assertEq(fee, _bps30(poolLeg), "fee is 30 bps of the ETH the pool paid");
        assertEq(hook.totalFeesCollected(), fee);
    }

    /// forge-config: default.fuzz.runs = 400
    function testFuzz_exactEthOut(uint256 ethOut) public {
        // 0.4 of the pool's 1 ETH costs about two thirds of the pool's tokens: alice can always afford it
        ethOut = bound(ethOut, 1, 0.4 ether);
        token.transfer(alice, 400_000_000e18);
        uint256 before = alice.balance;
        uint256 poolBefore = address(manager).balance;
        swapAs(alice, false, int256(ethOut), 0);
        uint256 fee = _bps30(ethOut);
        assertEq(alice.balance - before, ethOut, "exact ETH delivered");
        assertEq(address(feeSink).balance, fee, "fee is 30 bps of the requested output");
        assertEq(poolBefore - address(manager).balance, ethOut + fee, "pool pays output plus fee");
        assertEq(hook.totalFeesCollected(), fee);
    }

    // ---- rounding edges ----

    function test_feeRoundsDownAtTheFirstChargeableAmount() public {
        buyTokens(alice, 333); // 333 * 30 / 10000 = 0
        assertEq(address(feeSink).balance, 0);
        buyTokens(alice, 334); // 1 wei
        assertEq(address(feeSink).balance, 1);
        assertEq(hook.totalFeesCollected(), 1);
    }

    function test_oneWeiSwapsInEveryDirectionDoNotRevert() public {
        token.transfer(alice, 1e18);
        buyTokens(alice, 1);
        sellTokens(alice, 1);
        swapAs(alice, true, 1, 1 ether); // one token unit out
        assertEq(hook.totalFeesCollected(), 0);
        assertEq(address(hook).balance, 0);
    }

    /// Splitting a trade into many pieces never pays more than the single trade's fee and at most one wei
    /// less per piece (round-down dust), so splitting is not a meaningful fee dodge.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_splittingASwapSavesAtMostOneWeiPerPiece(uint256 ethIn, uint8 pieces) public {
        pieces = uint8(bound(pieces, 2, 12));
        ethIn = bound(ethIn, uint256(pieces) * 1000, 5 ether);
        uint256 each = ethIn / pieces;
        for (uint256 i = 0; i < pieces; ++i) {
            buyTokens(alice, each);
        }
        uint256 single = _bps30(each * pieces);
        assertLe(address(feeSink).balance, single);
        assertGe(address(feeSink).balance + pieces, single);
    }

    // ---- what a swapper relies on ----

    /// Buying then immediately selling everything back never returns more ETH than went in: the loss is at
    /// least the two fees the sink received.
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_roundTripLosesAtLeastTheFees(uint256 ethIn) public {
        ethIn = bound(ethIn, 1000, 20 ether);
        uint256 before = alice.balance;
        buyTokens(alice, ethIn);
        sellTokens(alice, token.balanceOf(alice));
        assertLe(alice.balance, before, "round trip profit");
        assertGe(before - alice.balance, address(feeSink).balance, "loss covers the skimmed fees");
        assertEq(hook.totalFeesCollected(), address(feeSink).balance);
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_ethIsConservedAcrossASwap(uint256 ethIn, bool withListing) public {
        ethIn = bound(ethIn, 1, 20 ether);
        if (withListing) listNft(seller, 0.002 ether);
        uint256 systemBefore = _systemEth();
        uint256 before = alice.balance;
        buyTokens(alice, ethIn);
        assertEq(_systemEth() - systemBefore, before - alice.balance, "every wei paid is accounted for");
        assertEq(address(hook).balance, 0);
        assertEq(address(router).balance, 0);
        assertEq(address(escrow).balance, 0);
    }

    function test_inSwapPurchaseDoesNotChangeWhatTheSwapperGets() public {
        uint256 snapshotId = vm.snapshotState();
        buyTokens(alice, 5 ether);
        uint256 tokensWithoutListing = token.balanceOf(alice);
        uint256 ethWithoutListing = alice.balance;
        assertEq(feeSink.buyCount(), 0);
        vm.revertToState(snapshotId);

        listNft(seller, 0.01 ether);
        buyTokens(alice, 5 ether);
        assertEq(feeSink.buyCount(), 1, "the purchase happened inside the swap");
        assertEq(token.balanceOf(alice), tokensWithoutListing);
        assertEq(alice.balance, ethWithoutListing);
    }

    function test_swapBelowThresholdNeverBuys() public {
        (uint256 id,) = listNft(seller, 1);
        buyTokens(alice, 3.3 ether); // 0.0099 ETH fee
        assertEq(address(feeSink).balance, 0.0099 ether);
        assertEq(feeSink.buyCount(), 0);
        assertTrue(market.getListing(id).active);
        buyTokens(alice, 0.034 ether); // +0.000102: crosses 0.01
        assertEq(feeSink.buyCount(), 1);
    }

    function test_strangerCannotPushFakeFeesThroughTheHookCallbacks() public {
        SwapParams memory params = SwapParams(true, -1 ether, 0);
        vm.startPrank(stranger);
        vm.expectRevert(GotchiFeeHook.NotPoolManager.selector);
        hook.beforeSwap(stranger, key, params, "");
        vm.expectRevert(GotchiFeeHook.NotPoolManager.selector);
        hook.afterSwap(stranger, key, params, BalanceDeltaLibrary.ZERO_DELTA, "");
        vm.stopPrank();
        assertEq(hook.totalFeesCollected(), 0);
    }

    function test_unimplementedCallbacksRevertEvenForThePoolManager() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1, bytes32(0));
        vm.startPrank(address(manager));
        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, 1);
        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, 1, 0);
        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(
            address(this), key, lp, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, ""
        );
        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(
            address(this), key, lp, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, ""
        );
        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 0, 0, "");
        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 0, 0, "");
        vm.stopPrank();
    }

    // ---- event surface ----

    function test_feesCollectedIsEmittedOncePerChargedSwapWithThePoolManagerIndexed() public {
        token.transfer(alice, 10_000_000e18);
        vm.recordLogs();
        buyTokens(alice, 1 ether); // beforeSwap path
        sellTokens(alice, 5_000_000e18); // afterSwap path
        buyTokens(alice, 100); // dust: no fee, no event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen = 0;
        uint256 total = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != FEES_COLLECTED) continue;
            seen += 1;
            assertEq(logs[i].emitter, address(hook));
            assertEq(logs[i].topics.length, 2, "exactly one indexed field");
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(manager), "indexed pool");
            total += abi.decode(logs[i].data, (uint256));
        }
        assertEq(seen, 2);
        assertEq(total, address(feeSink).balance, "event amounts add up to the ETH in the sink");
        assertEq(total, hook.totalFeesCollected());
    }
}
