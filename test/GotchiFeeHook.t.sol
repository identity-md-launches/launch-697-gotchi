// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GotchiFixture} from "./utils/GotchiFixture.sol";
import {GotchiFeeHook} from "../src/GotchiFeeHook.sol";
import {GotchiConfig} from "../src/GotchiConfig.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract GotchiFeeHookTest is GotchiFixture {
    using PoolIdLibrary for PoolKey;

    event FeesCollected(address indexed pool, uint256 amountEth);
    event BuyPoked(bool bought);

    function test_addressCarriesExactlyTheSwapFlags() public view {
        uint160 flags = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(flags, hookDeployer.REQUIRED_FLAGS());
        assertEq(flags, uint160(0xCC));
        assertEq(address(hook.POOL_MANAGER()), address(manager));
        assertEq(hook.DEPLOYER(), address(hookDeployer));
        assertEq(address(hook.feeSink()), address(feeSink));
    }

    function test_constructorRejectsAnAddressWithoutTheFlags() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new GotchiFeeHook(address(manager));
    }

    function test_constructorRejectsZeroPoolManager() public {
        vm.expectRevert(GotchiFeeHook.ZeroAddress.selector);
        new GotchiFeeHook(address(0));
    }

    function test_wireIsDeployerOnlyAndOneShot() public {
        vm.prank(stranger);
        vm.expectRevert(GotchiFeeHook.NotDeployer.selector);
        hook.wire(stranger);

        GotchiFeeHook fresh =
            _deployUnwiredHook(address(uint160(0x1000000000000000000000000000000000000000) | uint160(0xCC)));
        vm.expectRevert(GotchiFeeHook.ZeroAddress.selector);
        fresh.wire(address(0));
        fresh.wire(address(feeSink));
        assertEq(address(fresh.feeSink()), address(feeSink));
        vm.expectRevert(GotchiFeeHook.AlreadyWired.selector);
        fresh.wire(address(feeSink));
    }

    function test_hookCallbacksRejectNonPoolManager() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        vm.expectRevert(GotchiFeeHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(GotchiFeeHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDeltaLibrary.ZERO_DELTA, "");
    }

    function testFuzz_calculateFeeIsThirtyBpsRoundedDown(uint256 amount) public view {
        amount = bound(amount, 0, type(uint128).max);
        assertEq(hook.calculateFee(amount), (amount * 30) / 10_000);
    }

    function test_calculateFeeExamples() public view {
        assertEq(hook.calculateFee(1 ether), 0.003 ether);
        assertEq(hook.calculateFee(0.01 ether), 0.00003 ether);
        assertEq(hook.calculateFee(333), 0); // rounds down, no fee on dust
        assertEq(hook.calculateFee(334), 1);
    }

    // ---- the four swap shapes, fee always in ETH, ETH always lands in FeeSink ----

    function test_ethExactInSkimsFeeFromInput() public {
        uint256 ethIn = 1 ether;
        uint256 fee = hook.calculateFee(ethIn);
        uint256 managerBefore = address(manager).balance;

        vm.expectEmit(true, false, false, true, address(hook));
        emit FeesCollected(address(manager), fee);
        BalanceDelta delta = buyTokens(alice, ethIn);

        assertEq(delta.amount0(), -int256(ethIn), "swapper pays exactly the input");
        assertGt(delta.amount1(), 0, "swapper receives tokens");
        assertEq(alice.balance, 100 ether - ethIn);
        assertEq(address(feeSink).balance, fee, "fee lands in the sink");
        assertEq(address(manager).balance, managerBefore + ethIn - fee, "pool keeps input minus fee");
        assertEq(address(hook).balance, 0, "hook never holds ETH");
        assertEq(hook.totalFeesCollected(), fee);
        assertEq(feeSink.totalReceived(), fee);
    }

    function test_tokenExactInSkimsFeeFromEthOutput() public {
        token.transfer(bob, 10_000_000e18);
        uint256 managerBefore = address(manager).balance;
        BalanceDelta delta = sellTokens(bob, 10_000_000e18);

        uint256 received = uint256(uint128(delta.amount0()));
        uint256 fee = address(feeSink).balance;
        assertGt(received, 0);
        assertEq(fee, hook.calculateFee(received + fee), "fee is 30 bps of the gross ETH output");
        assertEq(bob.balance, 100 ether + received);
        assertEq(address(manager).balance, managerBefore - received - fee);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_tokenExactOutChargesFeeOnTopOfEthInput() public {
        int256 tokensOut = 1_000_000e18;
        BalanceDelta delta = swapAs(carol, true, tokensOut, 5 ether);

        uint256 paid = uint256(uint128(-delta.amount0()));
        uint256 fee = address(feeSink).balance;
        assertEq(delta.amount1(), tokensOut, "exact output honoured");
        assertEq(token.balanceOf(carol), uint256(tokensOut));
        assertEq(fee, hook.calculateFee(paid - fee), "fee is 30 bps of the pool's ETH input");
        assertEq(carol.balance, 100 ether - paid, "unused ETH refunded");
    }

    function test_ethExactOutDeliversExactEthAndSkimsFee() public {
        token.transfer(bob, 200_000_000e18);
        int256 ethOut = 0.1 ether;
        uint256 fee = hook.calculateFee(uint256(ethOut));
        BalanceDelta delta = swapAs(bob, false, ethOut, 0);

        assertEq(delta.amount0(), ethOut, "swapper receives exactly the requested ETH");
        assertEq(bob.balance, 100 ether + uint256(ethOut));
        assertEq(address(feeSink).balance, fee);
    }

    function testFuzz_ethExactInFeeMatchesCalculateFee(uint256 ethIn) public {
        ethIn = bound(ethIn, 1, 50 ether);
        buyTokens(alice, ethIn);
        assertEq(address(feeSink).balance, hook.calculateFee(ethIn));
        assertEq(alice.balance, 100 ether - ethIn);
    }

    function test_feesAccumulateAcrossSwaps() public {
        buyTokens(alice, 1 ether);
        buyTokens(bob, 2 ether);
        assertEq(address(feeSink).balance, hook.calculateFee(1 ether) + hook.calculateFee(2 ether));
        assertEq(hook.totalFeesCollected(), address(feeSink).balance);
    }

    function test_dustSwapChargesNothing() public {
        buyTokens(alice, 100); // 100 wei * 30 / 10000 == 0
        assertEq(address(feeSink).balance, 0);
        assertEq(hook.totalFeesCollected(), 0);
    }

    function test_unwiredHookChargesNoFee() public {
        GotchiFeeHook fresh =
            _deployUnwiredHook(address(uint160(0x2000000000000000000000000000000000000000) | uint160(0xCC)));
        PoolKey memory freshKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(fresh))
        });
        manager.initialize(freshKey, initialSqrtPrice);
        // no liquidity: a swap moves price only, but the hook still runs
        vm.prank(alice);
        router.swap{value: 1 ether}(
            freshKey, SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: initialSqrtPrice - 1})
        );
        assertEq(fresh.totalFeesCollected(), 0);
        assertEq(address(feeSink).balance, 0);
    }

    function test_nonEthPoolIsPassedThroughWithoutFee() public {
        IERC20 other = IERC20(address(new MockOther()));
        (Currency c0, Currency c1) = address(other) < address(token)
            ? (Currency.wrap(address(other)), Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), Currency.wrap(address(other)));
        PoolKey memory otherKey =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))});
        manager.initialize(otherKey, TickMath.getSqrtPriceAtTick(0));
        token.approve(address(router), type(uint256).max);
        other.approve(address(router), type(uint256).max);
        router.swap(
            otherKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1})
        );
        assertEq(hook.totalFeesCollected(), 0);
        assertEq(address(feeSink).balance, 0);
    }

    function test_afterSwapPokesTheSinkAndBuysInsideTheSwap() public {
        (uint256 listingId, uint256 tokenId) = listNft(seller, 0.002 ether);
        assertEq(listingId, 1);
        // 4 ETH in -> 0.012 ETH fee >= threshold -> purchase happens inside afterSwap
        buyTokens(alice, 4 ether);
        assertEq(feeSink.buyCount(), 1);
        assertEq(nft.ownerOf(tokenId), address(escrow));
        assertEq(market.proceeds(seller), 0.002 ether);
        assertEq(escrow.acquisitionCount(), 1);
        assertEq(address(feeSink).balance, hook.calculateFee(4 ether) - 0.002 ether);
    }

    function test_swapSucceedsWhenTheSinkTryBuyReverts() public {
        // A sink whose tryBuy always reverts (or burns all its gas): afterSwap's try/catch must swallow it.
        RevertingSink badSink = new RevertingSink();
        GotchiFeeHook fresh =
            _deployUnwiredHook(address(uint160(0x3000000000000000000000000000000000000000) | uint160(0xCC)));
        fresh.wire(address(badSink));
        PoolKey memory freshKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(fresh))
        });
        manager.initialize(freshKey, initialSqrtPrice);
        vm.prank(alice);
        vm.expectEmit(false, false, false, true, address(fresh));
        emit BuyPoked(false);
        router.swap{value: 1 ether}(
            freshKey, SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: initialSqrtPrice - 1})
        );
        // with no liquidity nothing is swapped, but the fee on the specified ETH input is still taken
        uint256 fee = hook.calculateFee(1 ether);
        assertEq(address(badSink).balance, fee, "fee delivered even though tryBuy reverted");
        assertEq(fresh.totalFeesCollected(), fee);

        badSink.setMode(RevertingSink.Mode.BurnGas);
        vm.prank(alice);
        vm.expectEmit(false, false, false, true, address(fresh));
        emit BuyPoked(false);
        router.swap{value: 1 ether}(
            freshKey, SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: initialSqrtPrice - 2})
        );
        assertEq(address(badSink).balance, 2 * fee, "out-of-gas inside the stipend is swallowed too");
    }

    function test_feeSinkRejectingEthRevertsTheSwap() public {
        // The sink must accept ETH; if it cannot, PoolManager.take fails and the whole swap reverts.
        vm.etch(address(feeSink), hex"60006000fd"); // PUSH1 0 PUSH1 0 REVERT
        vm.prank(alice);
        vm.expectRevert();
        router.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1})
        );
    }

    // ---- helpers ----

    /// @dev Runs the hook constructor at `where` (a flag-valid address) with this test as DEPLOYER.
    function _deployUnwiredHook(address where) internal returns (GotchiFeeHook) {
        bytes memory initCode = bytes.concat(type(GotchiFeeHook).creationCode, abi.encode(address(manager)));
        vm.etch(where, initCode);
        (bool ok, bytes memory runtime) = where.call("");
        require(ok, "constructor failed");
        vm.etch(where, runtime);
        return GotchiFeeHook(where);
    }
}

contract RevertingSink {
    enum Mode {
        Revert,
        BurnGas
    }

    Mode public mode = Mode.Revert;
    uint256 public calls;
    uint256[] private _junk;

    receive() external payable {}

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function tryBuy() external returns (bool) {
        calls += 1;
        if (mode == Mode.Revert) revert("sink broken");
        while (true) {
            _junk.push(1);
        }
        return true;
    }
}

contract MockOther is IERC20 {
    string public constant name = "Other";
    string public constant symbol = "OTHER";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        totalSupply = 1e27;
        balanceOf[msg.sender] = 1e27;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
