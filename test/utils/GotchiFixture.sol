// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {GotchiDeployment} from "../../script/GotchiDeployment.sol";
import {GotchiConfig} from "../../src/GotchiConfig.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {MockGotchiNFT} from "../../src/MockGotchiNFT.sol";
import {MockBaazaar} from "../../src/MockBaazaar.sol";
import {HolderWeightedPicker} from "../../src/HolderWeightedPicker.sol";
import {FlipEscrow} from "../../src/FlipEscrow.sol";
import {FeeSink} from "../../src/FeeSink.sol";
import {GotchiHookDeployer} from "../../src/GotchiHookDeployer.sol";
import {GotchiFeeHook} from "../../src/GotchiFeeHook.sol";
import {ForeverLiquidity} from "../../src/ForeverLiquidity.sol";
import {SwapRouterHarness} from "./SwapRouterHarness.sol";

/// @notice Deploys the whole system against a local PoolManager through the same recipe the script uses,
/// seeds the forever pool with the configured liquidity, and offers swap/flip helpers.
abstract contract GotchiFixture is Test, GotchiDeployment {
    PoolManager internal manager;
    LaunchToken internal token;
    MockGotchiNFT internal nft;
    MockBaazaar internal market;
    HolderWeightedPicker internal picker;
    FlipEscrow internal escrow;
    FeeSink internal feeSink;
    GotchiHookDeployer internal hookDeployer;
    GotchiFeeHook internal hook;
    ForeverLiquidity internal forever;
    SwapRouterHarness internal router;
    PoolKey internal key;
    uint160 internal initialSqrtPrice;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal seller = makeAddr("seller");
    address internal stranger = makeAddr("stranger");

    receive() external payable {}

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        token = new LaunchToken();
        Deployment memory d = deployAll(
            Config({
                owner: address(this),
                operator: address(this),
                poolManager: address(manager),
                token: address(token),
                saltStart: 0
            })
        );
        nft = d.nft;
        market = d.market;
        picker = d.picker;
        escrow = d.escrow;
        feeSink = d.feeSink;
        hookDeployer = d.hookDeployer;
        hook = d.hook;
        forever = d.forever;
        router = new SwapRouterHarness(manager);
        key = forever.poolKey();

        initialSqrtPrice =
            forever.sqrtPriceFromAmounts(GotchiConfig.INITIAL_LIQUIDITY_ETH, GotchiConfig.INITIAL_LIQUIDITY_TOKENS);
        token.approve(address(forever), GotchiConfig.INITIAL_LIQUIDITY_TOKENS);
        forever.seed{value: GotchiConfig.INITIAL_LIQUIDITY_ETH}(
            initialSqrtPrice, initialSqrtPrice, initialSqrtPrice, GotchiConfig.INITIAL_LIQUIDITY_TOKENS
        );

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(seller, 1 ether);
        vm.deal(stranger, 100 ether);
    }

    // ---- swaps ----

    function swapAs(address who, bool zeroForOne, int256 amountSpecified, uint256 ethValue)
        internal
        returns (BalanceDelta delta)
    {
        vm.startPrank(who);
        if (!zeroForOne) token.approve(address(router), type(uint256).max);
        delta = router.swap{value: ethValue}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        vm.stopPrank();
    }

    /// @dev ETH exact-in: buy $GOTCHI with `ethIn` wei.
    function buyTokens(address who, uint256 ethIn) internal returns (BalanceDelta) {
        return swapAs(who, true, -int256(ethIn), ethIn);
    }

    /// @dev Token exact-in: sell `tokensIn` for ETH.
    function sellTokens(address who, uint256 tokensIn) internal returns (BalanceDelta) {
        return swapAs(who, false, -int256(tokensIn), 0);
    }

    // ---- market ----

    function listNft(address who, uint256 price) internal returns (uint256 listingId, uint256 tokenId) {
        tokenId = nft.mint(who);
        vm.startPrank(who);
        nft.approve(address(market), tokenId);
        listingId = market.list(tokenId, price);
        vm.stopPrank();
    }

    // ---- holders ----

    function giveAndEnroll(address who, uint256 amount) internal {
        token.transfer(who, amount);
        vm.prank(who);
        picker.enroll();
    }

    // ---- flips ----

    /// @dev Commit for `acquisitionId`, then fix the entropy block hash so the reveal lands on `wantBurn`.
    function commitAndSteer(uint256 acquisitionId, bool wantBurn) internal returns (bytes32 seed) {
        seed = keccak256(abi.encode("seed", acquisitionId));
        escrow.commit(acquisitionId, escrow.commitmentFor(seed));
        FlipEscrow.Acquisition memory a = escrow.getAcquisition(acquisitionId);
        uint256 entropyBlock = uint256(a.commitBlock) + 1;
        vm.roll(uint256(a.commitBlock) + escrow.REVEAL_DELAY_BLOCKS());
        for (uint256 i = 1; i < 1000; ++i) {
            bytes32 candidate = keccak256(abi.encode("entropy", i));
            uint256 word = uint256(keccak256(abi.encode(seed, candidate, acquisitionId, a.tokenId)));
            bool burns = escrow.burnsFor(word);
            if (burns == wantBurn) {
                vm.setBlockhash(entropyBlock, candidate);
                break;
            }
        }
    }

    function fundSink(uint256 amount) internal {
        vm.deal(stranger, stranger.balance + amount);
        vm.prank(stranger);
        (bool ok,) = address(feeSink).call{value: amount}("");
        require(ok, "fund failed");
    }
}
