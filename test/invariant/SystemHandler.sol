// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {MockGotchiNFT} from "../../src/MockGotchiNFT.sol";
import {MockBaazaar} from "../../src/MockBaazaar.sol";
import {HolderWeightedPicker} from "../../src/HolderWeightedPicker.sol";
import {FlipEscrow} from "../../src/FlipEscrow.sol";
import {FeeSink} from "../../src/FeeSink.sol";
import {GotchiFeeHook} from "../../src/GotchiFeeHook.sol";
import {ForeverLiquidity} from "../../src/ForeverLiquidity.sol";
import {IMockBaazaar} from "../../src/interfaces/IMockBaazaar.sol";
import {SwapRouterHarness} from "../utils/SwapRouterHarness.sol";

/// @notice Drives the whole $GOTCHI system with several actors and bounded inputs. Every action checks
/// its own post-conditions (assertion mode); the invariant contract checks the global properties.
/// @dev Expected outcomes are computed here from first principles (30 bps, 0.01 ETH threshold, top bit of
/// the random word, block windows) rather than by calling the contracts' own helpers.
contract SystemHandler is Test {
    struct Refs {
        PoolManager manager;
        LaunchToken token;
        MockGotchiNFT nft;
        MockBaazaar market;
        HolderWeightedPicker picker;
        FlipEscrow escrow;
        FeeSink feeSink;
        GotchiFeeHook hook;
        ForeverLiquidity forever;
        SwapRouterHarness router;
        address owner;
    }

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant THRESHOLD = 0.01 ether;
    uint256 internal constant FLOOR = 0.001 ether; // MIN_LIST_PRICE == MIN_BUY_PRICE
    uint256 internal constant CEILING = 0.05 ether; // MAX_BUY_PRICE
    uint256 internal constant MIN_ENROLL = 1_000e18;
    uint256 internal constant MAX_HOLDERS = 128;
    uint256 internal constant MAX_LISTINGS = 64;
    uint256 internal constant MATURITY = 300;

    Refs internal r;
    PoolKey internal key;
    address[] internal _actors;

    // ---- ghosts ----
    uint256 public ghostDonated; // ETH sent straight to the sink
    uint256 public ghostFees; // ETH the hook skimmed, summed from each swap's independently computed fee
    uint256 public ghostDirectPaid; // ETH actors paid the market directly
    uint256 public ghostWithdrawn; // ETH sellers withdrew
    uint256 public ghostBurns;
    uint256 public ghostAirdrops;
    uint256 public ghostTimeouts;
    uint256 public ghostSwaps;
    uint256 public ghostPartialFills; // token-specified swaps that stopped at their limit
    uint256 public ghostRefusedPartials; // ETH-specified swaps refused at their limit
    uint256 public ghostEvictions; // listings displaced by a cheaper one on a full market
    uint256 public ghostLiquidityFloor; // forever liquidity never drops below this
    uint256 public ghostDisplacements; // enrolments on a full registry that removed an entry
    uint256 public ghostRefusedFull; // enrolments refused by the constant-gas RegistryFull test
    address[] internal _fillers; // registry fillers (small holders) created on demand
    mapping(uint256 acquisitionId => bytes32 seed) public seedOf;
    mapping(uint256 acquisitionId => bool resolved) public ghostResolved;
    mapping(uint256 acquisitionId => address recipient) public ghostRecipient;
    uint256[] internal _airdroppedTokens;

    constructor(Refs memory refs, address[] memory actors_) {
        r = refs;
        key = refs.forever.poolKey();
        _actors = actors_;
        ghostLiquidityFloor = refs.forever.totalLiquidity();
        for (uint256 i = 0; i < actors_.length; ++i) {
            vm.startPrank(actors_[i]);
            refs.token.approve(address(refs.router), type(uint256).max);
            refs.token.approve(address(refs.forever), type(uint256).max);
            refs.nft.setApprovalForAll(address(refs.market), true);
            vm.stopPrank();
        }
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }

    /// @notice Every address that may hold a registry slot: the actors plus the fillers created so far.
    function fillers() external view returns (address[] memory) {
        return _fillers;
    }

    /// @dev An actor or a filler: the registry actions target both so displaced, drained and trimmed
    /// fillers are exercised like actors.
    function _participant(uint256 seed) internal view returns (address) {
        uint256 i = seed % (_actors.length + _fillers.length);
        return i < _actors.length ? _actors[i] : _fillers[i - _actors.length];
    }

    /// @dev A fresh address funded with `amount` tokens from the handler's float.
    function _newFiller(uint256 amount) internal returns (address filler) {
        filler = address(uint160(0xF111_0000 + _fillers.length));
        _fillers.push(filler);
        r.token.transfer(filler, amount);
    }

    /// @dev One input in four stays in the dust range (edge cases: zero fee, one wei); the rest are sized
    /// so that fees actually reach the purchase threshold within a run.
    function _sized(uint256 x, uint256 dustMax, uint256 low, uint256 high) internal pure returns (uint256) {
        return x % 4 == 0 ? bound(x, 1, dustMax) : bound(x, low, high);
    }

    function _bps30(uint256 amount) internal pure returns (uint256) {
        return (amount * 30) / 10_000;
    }

    /// @dev True when the 4-byte `selector` appears anywhere in `reason` (v4 wraps hook reverts twice).
    function _contains(bytes memory reason, bytes4 selector) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 <= reason.length; ++i) {
            if (
                reason[i] == selector[0] && reason[i + 1] == selector[1] && reason[i + 2] == selector[2]
                    && reason[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }

    /// @dev One swap pokes the sink once, so it buys at most one NFT, inside the price band and within
    /// what the sink held.
    function _checkInSwapPurchase(uint256 buysBefore, uint256 spentBefore, uint256 sinkBefore, uint256 fee)
        internal
        view
    {
        uint256 buys = r.feeSink.buyCount() - buysBefore;
        assertLe(buys, 1, "a swap bought more than one NFT");
        if (buys == 1) {
            uint256 price = r.feeSink.totalSpent() - spentBefore;
            assertGe(price, FLOOR, "in-swap purchase below the floor");
            assertLe(price, CEILING, "in-swap purchase above the ceiling");
            assertLe(price, sinkBefore + fee, "in-swap purchase spent more than the sink held");
            assertGe(sinkBefore + fee, THRESHOLD, "in-swap purchase below the threshold");
        }
    }

    // ---------------------------------------------------------------- swaps

    /// ETH exact-in: the fee is 30 bps of the ETH the swapper sends, and they pay exactly `ethIn`.
    function buyExactEthIn(uint256 actorSeed, uint256 ethIn) external {
        address a = _actor(actorSeed);
        ethIn = _sized(ethIn, 1000, 0.05 ether, 2 ether);
        if (a.balance < ethIn) return;
        uint256 feesBefore = r.hook.totalFeesCollected();
        uint256 receivedBefore = r.feeSink.totalReceived();
        uint256 ethBefore = a.balance;
        (uint256 buysBefore, uint256 spentBefore, uint256 sinkBefore) =
            (r.feeSink.buyCount(), r.feeSink.totalSpent(), address(r.feeSink).balance);
        vm.prank(a);
        r.router.swap{value: ethIn}(key, SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1));
        uint256 fee = r.hook.totalFeesCollected() - feesBefore;
        assertEq(fee, _bps30(ethIn), "exact ETH in: fee is 30 bps of the input");
        assertEq(r.feeSink.totalReceived() - receivedBefore, fee, "exact ETH in: sink received the fee");
        assertEq(ethBefore - a.balance, ethIn, "exact ETH in: swapper paid exactly the input");
        _checkInSwapPurchase(buysBefore, spentBefore, sinkBefore, fee);
        ghostFees += fee;
        ghostSwaps += 1;
    }

    /// Token exact-in that stops at a price limit: the fee is 30 bps of the ETH that actually left the pool.
    function partialTokenExactIn(uint256 actorSeed, uint256 delta, uint256 tokensIn) external {
        address a = _actor(actorSeed);
        uint256 balance = r.token.balanceOf(a);
        if (balance < 1000) return;
        uint160 current = r.forever.currentSqrtPriceX96();
        uint160 limit = uint160(uint256(current) + bound(delta, 1, uint256(current) / 8));
        tokensIn = bound(tokensIn, 1000, balance);
        uint256 feesBefore = r.hook.totalFeesCollected();
        uint256 ethBefore = a.balance;
        uint256 poolBefore = address(r.manager).balance;
        (uint256 buysBefore, uint256 spentBefore, uint256 sinkBefore) =
            (r.feeSink.buyCount(), r.feeSink.totalSpent(), address(r.feeSink).balance);
        vm.prank(a);
        r.router.swap(key, SwapParams(false, -int256(tokensIn), limit));
        uint256 fee = r.hook.totalFeesCollected() - feesBefore;
        uint256 consumed = balance - r.token.balanceOf(a);
        uint256 poolLeg = poolBefore - address(r.manager).balance;
        assertLe(consumed, tokensIn, "partial token in: consumed more than offered");
        assertEq(fee, _bps30(poolLeg), "partial token in: fee is 30 bps of the realised ETH leg");
        assertEq(a.balance - ethBefore, poolLeg - fee, "partial token in: swapper got the leg minus the fee");
        assertLe(r.forever.currentSqrtPriceX96(), limit, "partial token in: price beyond the limit");
        _checkInSwapPurchase(buysBefore, spentBefore, sinkBefore, fee);
        if (consumed < tokensIn) ghostPartialFills += 1;
        ghostFees += fee;
        ghostSwaps += 1;
    }

    /// ETH exact-in that would stop at a price limit is refused as a whole and leaves no trace.
    function partialEthExactIn(uint256 actorSeed, uint256 delta, uint256 extra) external {
        address a = _actor(actorSeed);
        uint160 current = r.forever.currentSqrtPriceX96();
        uint160 limit = uint160(uint256(current) - bound(delta, 1, uint256(current) / 8));
        uint256 needed = SqrtPriceMath.getAmount0Delta(limit, current, r.forever.totalLiquidity(), true);
        uint256 ethIn = ((needed + bound(extra, 1000, 0.2 ether)) * 10_000) / 9_970 + 2;
        if (a.balance < ethIn) return;
        uint256 feesBefore = r.hook.totalFeesCollected();
        uint256 receivedBefore = r.feeSink.totalReceived();
        uint256 buysBefore = r.feeSink.buyCount();
        uint256 ethBefore = a.balance;
        uint256 tokensBefore = r.token.balanceOf(a);
        vm.prank(a);
        try r.router.swap{value: ethIn}(key, SwapParams(true, -int256(ethIn), limit)) {
            fail("partial ETH in: must revert");
        } catch (bytes memory reason) {
            assertTrue(_contains(reason, GotchiFeeHook.PartialFillUnsupported.selector), "partial ETH in: reason");
        }
        assertEq(r.hook.totalFeesCollected(), feesBefore, "partial ETH in: fee kept");
        assertEq(r.feeSink.totalReceived(), receivedBefore, "partial ETH in: sink received");
        assertEq(r.feeSink.buyCount(), buysBefore, "partial ETH in: a purchase survived the revert");
        assertEq(a.balance, ethBefore, "partial ETH in: swapper lost ETH");
        assertEq(r.token.balanceOf(a), tokensBefore);
        assertEq(r.forever.currentSqrtPriceX96(), current, "partial ETH in: price moved");
        ghostRefusedPartials += 1;
    }

    /// Token exact-out bought with ETH: the fee is charged on top of the ETH the pool takes.
    function buyExactTokensOut(uint256 actorSeed, uint256 tokensOut) external {
        address a = _actor(actorSeed);
        uint256 poolTokens = r.token.balanceOf(address(r.manager));
        tokensOut = _sized(tokensOut, 1000, poolTokens / 1000, poolTokens / 8);
        uint256 feesBefore = r.hook.totalFeesCollected();
        uint256 receivedBefore = r.feeSink.totalReceived();
        uint256 ethBefore = a.balance;
        uint256 tokensBefore = r.token.balanceOf(a);
        (uint256 buysBefore, uint256 spentBefore, uint256 sinkBefore) =
            (r.feeSink.buyCount(), r.feeSink.totalSpent(), address(r.feeSink).balance);
        vm.prank(a);
        try r.router.swap{value: ethBefore}(key, SwapParams(true, int256(tokensOut), TickMath.MIN_SQRT_PRICE + 1)) {}
        catch {
            return; // not enough ETH for this size
        }
        uint256 fee = r.hook.totalFeesCollected() - feesBefore;
        uint256 paid = ethBefore - a.balance;
        assertEq(r.token.balanceOf(a) - tokensBefore, tokensOut, "exact tokens out: delivered exactly");
        assertEq(fee, _bps30(paid - fee), "exact tokens out: fee is 30 bps of the pool's ETH leg");
        assertEq(r.feeSink.totalReceived() - receivedBefore, fee, "exact tokens out: sink received the fee");
        _checkInSwapPurchase(buysBefore, spentBefore, sinkBefore, fee);
        ghostFees += fee;
        ghostSwaps += 1;
    }

    /// Token exact-in sold for ETH: the fee comes out of the ETH the pool pays.
    function sellExactTokensIn(uint256 actorSeed, uint256 tokensIn) external {
        address a = _actor(actorSeed);
        uint256 balance = r.token.balanceOf(a);
        if (balance < 1) return;
        tokensIn = _sized(tokensIn, balance < 1000 ? balance : 1000, (balance + 9) / 10, balance);
        uint256 feesBefore = r.hook.totalFeesCollected();
        uint256 receivedBefore = r.feeSink.totalReceived();
        uint256 ethBefore = a.balance;
        (uint256 buysBefore, uint256 spentBefore, uint256 sinkBefore) =
            (r.feeSink.buyCount(), r.feeSink.totalSpent(), address(r.feeSink).balance);
        vm.prank(a);
        r.router.swap(key, SwapParams(false, -int256(tokensIn), TickMath.MAX_SQRT_PRICE - 1));
        uint256 fee = r.hook.totalFeesCollected() - feesBefore;
        uint256 got = a.balance - ethBefore;
        assertEq(balance - r.token.balanceOf(a), tokensIn, "exact tokens in: paid exactly");
        assertEq(fee, _bps30(got + fee), "exact tokens in: fee is 30 bps of the pool's ETH leg");
        assertEq(r.feeSink.totalReceived() - receivedBefore, fee, "exact tokens in: sink received the fee");
        _checkInSwapPurchase(buysBefore, spentBefore, sinkBefore, fee);
        ghostFees += fee;
        ghostSwaps += 1;
    }

    /// ETH exact-out sold from tokens: the swapper receives exactly `ethOut`, the fee is 30 bps of it.
    function sellForExactEthOut(uint256 actorSeed, uint256 ethOut) external {
        address a = _actor(actorSeed);
        ethOut = _sized(ethOut, 1000, address(r.manager).balance / 1000, address(r.manager).balance / 8);
        uint256 feesBefore = r.hook.totalFeesCollected();
        uint256 receivedBefore = r.feeSink.totalReceived();
        uint256 ethBefore = a.balance;
        (uint256 buysBefore, uint256 spentBefore, uint256 sinkBefore) =
            (r.feeSink.buyCount(), r.feeSink.totalSpent(), address(r.feeSink).balance);
        vm.prank(a);
        try r.router.swap(key, SwapParams(false, int256(ethOut), TickMath.MAX_SQRT_PRICE - 1)) {}
        catch {
            return; // not enough tokens for this size
        }
        uint256 fee = r.hook.totalFeesCollected() - feesBefore;
        assertEq(a.balance - ethBefore, ethOut, "exact ETH out: delivered exactly");
        assertEq(fee, _bps30(ethOut), "exact ETH out: fee is 30 bps of the output");
        assertEq(r.feeSink.totalReceived() - receivedBefore, fee, "exact ETH out: sink received the fee");
        _checkInSwapPurchase(buysBefore, spentBefore, sinkBefore, fee);
        ghostFees += fee;
        ghostSwaps += 1;
    }

    // ---------------------------------------------------------------- sink

    function donateToSink(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = amount % 4 == 0 ? bound(amount, 0, 1000) : bound(amount, 0.002 ether, 0.03 ether);
        if (a.balance < amount) return;
        vm.prank(a);
        (bool ok,) = address(r.feeSink).call{value: amount}("");
        assertTrue(ok, "sink accepts ETH");
        ghostDonated += amount;
    }

    /// The owner's manual trigger buys exactly when balance >= 0.01 ETH and the cheapest listing is inside
    /// the [0.001, 0.05] ETH band and affordable.
    function keeperTryBuy() external {
        uint256 balance = address(r.feeSink).balance;
        IMockBaazaar.Listing memory c = r.market.cheapest();
        bool expected = balance >= THRESHOLD && c.active && c.price <= balance && c.price >= FLOOR && c.price <= CEILING;
        uint256 buysBefore = r.feeSink.buyCount();
        uint256 creditBefore = r.market.proceeds(c.seller);
        vm.prank(r.owner);
        bool bought = r.feeSink.tryBuy();
        assertEq(bought, expected, "tryBuy buys iff threshold met and cheapest affordable");
        if (bought) {
            assertEq(address(r.feeSink).balance, balance - c.price, "sink paid exactly the listing price");
            assertEq(r.market.proceeds(c.seller) - creditBefore, c.price, "seller credited the price");
            assertEq(r.nft.ownerOf(c.tokenId), address(r.escrow), "NFT went to the escrow");
            assertEq(r.feeSink.buyCount(), buysBefore + 1);
            assertEq(r.escrow.openAcquisitionOf(c.tokenId), r.escrow.acquisitionCount(), "flip requested");
        } else {
            assertEq(address(r.feeSink).balance, balance, "no-buy leaves the balance untouched");
            assertEq(r.feeSink.buyCount(), buysBefore);
        }
    }

    function strangerTryBuy(uint256 actorSeed) external {
        vm.prank(_actor(actorSeed));
        vm.expectRevert(FeeSink.NotTrigger.selector);
        r.feeSink.tryBuy();
    }

    // ---------------------------------------------------------------- market

    /// Prices from the floor up to 0.03 ETH.
    function list(uint256 actorSeed, uint256 price) external {
        address a = _actor(actorSeed);
        _list(a, r.nft.mint(a), bound(price, FLOOR, 0.03 ether));
    }

    /// Prices within a few wei of the floor: plenty of ties for `cheapest()` and eviction ordering.
    function listNearFloor(uint256 actorSeed, uint256 offset) external {
        address a = _actor(actorSeed);
        _list(a, r.nft.mint(a), FLOOR + bound(offset, 0, 5));
    }

    /// Prices above the sink's ceiling: listable, never bought by the sink, evictable by anything cheaper.
    function listAboveCeiling(uint256 actorSeed, uint256 price) external {
        address a = _actor(actorSeed);
        _list(a, r.nft.mint(a), bound(price, CEILING + 1, 1 ether));
    }

    /// Below the floor nothing can be listed, whoever asks, and no id or NFT moves.
    function listBelowFloor(uint256 actorSeed, uint256 price) external {
        address a = _actor(actorSeed);
        price = bound(price, 0, FLOOR - 1);
        uint256 tokenId = r.nft.mint(a);
        uint256 nextBefore = r.market.nextListingId();
        vm.prank(a);
        vm.expectRevert(MockBaazaar.InvalidPrice.selector);
        r.market.list(tokenId, price);
        assertEq(r.nft.ownerOf(tokenId), a);
        assertEq(r.market.nextListingId(), nextBefore);
    }

    /// An airdrop winner lists the NFT they received, so the same token id can be bought again.
    function relistAirdropped(uint256 index, uint256 price) external {
        if (_airdroppedTokens.length < 1) return;
        uint256 tokenId = _airdroppedTokens[index % _airdroppedTokens.length];
        address owner = r.nft.ownerOf(tokenId);
        if (owner == address(r.market) || owner == address(r.escrow) || owner == DEAD) return;
        _list(owner, tokenId, bound(price, FLOOR, 0.03 ether));
    }

    /// @dev The listing a full market would evict: highest price, highest id on a tie.
    function _mostExpensive() internal view returns (IMockBaazaar.Listing memory dearest) {
        uint256 active = r.market.activeCount();
        for (uint256 i = 0; i < active; ++i) {
            IMockBaazaar.Listing memory l = r.market.getListing(r.market.activeIdAt(i));
            if (i == 0 || l.price > dearest.price || (l.price == dearest.price && l.listingId > dearest.listingId)) {
                dearest = l;
            }
        }
    }

    function _list(address a, uint256 tokenId, uint256 price) internal {
        uint256 active = r.market.activeCount();
        uint256 expectedId = r.market.nextListingId();
        IMockBaazaar.Listing memory victim;
        bool evicts = false;
        if (active >= MAX_LISTINGS) {
            victim = _mostExpensive();
            if (price >= victim.price) {
                vm.prank(a);
                vm.expectRevert(MockBaazaar.MarketFull.selector);
                r.market.list(tokenId, price);
                assertEq(r.market.nextListingId(), expectedId, "refused listing consumed an id");
                assertEq(r.nft.ownerOf(tokenId), a);
                return;
            }
            evicts = true;
        }
        vm.prank(a);
        uint256 id = r.market.list(tokenId, price);
        assertEq(id, expectedId, "listing ids are sequential");
        assertEq(r.nft.ownerOf(tokenId), address(r.market), "listed NFT is escrowed by the market");
        if (evicts) {
            assertEq(r.market.activeCount(), active, "eviction keeps the market full");
            assertFalse(r.market.getListing(victim.listingId).active, "the dearest listing survived");
            assertEq(r.nft.ownerOf(victim.tokenId), victim.seller, "evicted NFT not returned to its seller");
            ghostEvictions += 1;
        } else {
            assertEq(r.market.activeCount(), active + 1);
        }
    }

    function cancel(uint256 index) external {
        uint256 active = r.market.activeCount();
        if (active < 1) return;
        uint256 id = r.market.activeIdAt(index % active);
        IMockBaazaar.Listing memory l = r.market.getListing(id);
        vm.prank(l.seller);
        r.market.cancel(id);
        assertEq(r.nft.ownerOf(l.tokenId), l.seller, "cancel returns the NFT");
        assertFalse(r.market.getListing(id).active);
        assertEq(r.market.activeCount(), active - 1);
    }

    function cancelByNonSeller(uint256 actorSeed, uint256 index) external {
        uint256 active = r.market.activeCount();
        if (active < 1) return;
        uint256 id = r.market.activeIdAt(index % active);
        address a = _actor(actorSeed);
        if (a == r.market.getListing(id).seller) return;
        vm.prank(a);
        vm.expectRevert(MockBaazaar.NotSeller.selector);
        r.market.cancel(id);
    }

    function buyDirect(uint256 actorSeed, uint256 overpay) external {
        address a = _actor(actorSeed);
        IMockBaazaar.Listing memory c = r.market.cheapest();
        if (!c.active) return;
        uint256 pay = c.price + bound(overpay, 0, 0.001 ether);
        if (a.balance < pay) return;
        uint256 creditBefore = r.market.proceeds(c.seller);
        vm.prank(a);
        uint256 tokenId = r.market.buyCheapest{value: pay}(c.listingId, a);
        assertEq(tokenId, c.tokenId);
        assertEq(r.nft.ownerOf(tokenId), a, "buyer received the NFT");
        assertEq(r.market.proceeds(c.seller) - creditBefore, pay, "seller credited everything sent");
        ghostDirectPaid += pay;
    }

    function underpay(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        IMockBaazaar.Listing memory c = r.market.cheapest();
        if (!c.active || a.balance < c.price) return;
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.InsufficientPayment.selector, c.price, c.price - 1));
        r.market.buyCheapest{value: c.price - 1}(c.listingId, a);
    }

    function withdraw(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        uint256 credit = r.market.proceeds(a);
        uint256 before = a.balance;
        vm.prank(a);
        if (credit < 1) {
            vm.expectRevert(MockBaazaar.NothingToWithdraw.selector);
            r.market.withdrawProceeds();
            return;
        }
        r.market.withdrawProceeds();
        assertEq(a.balance, before + credit, "seller withdrew exactly their credit");
        assertEq(r.market.proceeds(a), 0);
        ghostWithdrawn += credit;
    }

    // ---------------------------------------------------------------- flips

    function _acquisition(uint256 idSeed) internal view returns (uint256 id, FlipEscrow.Acquisition memory a) {
        uint256 count = r.escrow.acquisitionCount();
        if (count < 1) return (0, a);
        id = bound(idSeed, 1, count);
        a = r.escrow.getAcquisition(id);
    }

    /// @dev The acquisition in `wanted` status nearest to the fuzzed id (searching upward, wrapping), so
    /// commits and reveals land on live flips instead of mostly missing them. Falls back to the fuzzed id.
    function _acquisitionIn(uint256 idSeed, FlipEscrow.Status wanted)
        internal
        view
        returns (uint256 id, FlipEscrow.Acquisition memory a)
    {
        uint256 count = r.escrow.acquisitionCount();
        if (count < 1) return (0, a);
        uint256 start = bound(idSeed, 1, count);
        uint256 span = count < 48 ? count : 48;
        for (uint256 i = 0; i < span; ++i) {
            id = ((start - 1 + i) % count) + 1;
            a = r.escrow.getAcquisition(id);
            if (a.status == wanted) return (id, a);
        }
        id = start;
        a = r.escrow.getAcquisition(id);
    }

    function commit(uint256 idSeed, bytes32 salt) external {
        (uint256 id, FlipEscrow.Acquisition memory a) = _acquisitionIn(idSeed, FlipEscrow.Status.Pending);
        if (id < 1 || a.status != FlipEscrow.Status.Pending) return;
        bytes32 seed = keccak256(abi.encode(salt, id));
        uint256 snapshotsBefore = r.picker.snapshotCount();
        vm.prank(r.owner);
        r.escrow.commit(id, keccak256(abi.encode(seed)));
        seedOf[id] = seed;
        a = r.escrow.getAcquisition(id);
        assertEq(a.snapshotId, snapshotsBefore + 1, "commit freezes a fresh snapshot");
        assertEq(a.commitBlock, vm.getBlockNumber());
    }

    function commitByNonFlipper(uint256 actorSeed, uint256 idSeed) external {
        (uint256 id,) = _acquisition(idSeed);
        vm.prank(_actor(actorSeed));
        vm.expectRevert(FlipEscrow.NotFlipper.selector);
        r.escrow.commit(id, bytes32(uint256(1)));
    }

    function reveal(uint256 actorSeed, uint256 idSeed, bytes32 entropy) external {
        (uint256 id, FlipEscrow.Acquisition memory a) = _acquisitionIn(idSeed, FlipEscrow.Status.Committed);
        if (id < 1 || a.status != FlipEscrow.Status.Committed) return;
        uint256 from = uint256(a.commitBlock) + 2;
        uint256 current = vm.getBlockNumber();
        if (current > from + 200) return; // window missed: only timeoutBurn can resolve it
        if (current < from) {
            vm.roll(from);
        }
        uint256 entropyBlock = uint256(a.commitBlock) + 1;
        if (blockhash(entropyBlock) == bytes32(0)) {
            vm.setBlockhash(entropyBlock, entropy == bytes32(0) ? bytes32(uint256(1)) : entropy);
        }
        bytes32 seed = seedOf[id];
        uint256 word = uint256(keccak256(abi.encode(seed, blockhash(entropyBlock), id, a.tokenId)));
        bool expectBurn = word >> 255 == 0; // FLIP_BURN_BPS = 5000: the lower half burns
        address expectRecipient = DEAD;
        if (!expectBurn) {
            (address picked, uint256 weight) = r.picker.pick(a.snapshotId, word);
            if (picked == address(0)) {
                expectBurn = true;
            } else {
                expectRecipient = picked;
                assertGt(weight, 0, "a recipient always carries weight");
                assertTrue(picked != DEAD, "burn address never wins");
                assertTrue(r.picker.snapshotInfo(a.snapshotId).totalWeight >= weight);
            }
        }
        vm.prank(_actor(actorSeed)); // anyone who knows the seed may reveal
        r.escrow.reveal(id, seed);
        a = r.escrow.getAcquisition(id);
        assertEq(uint8(a.status), uint8(FlipEscrow.Status.Resolved));
        assertEq(a.burned, expectBurn, "burn branch follows the top bit of the random word");
        assertEq(a.recipient, expectRecipient);
        assertEq(r.nft.ownerOf(a.tokenId), expectRecipient, "NFT delivered to the resolved recipient");
        assertEq(r.escrow.openAcquisitionOf(a.tokenId), 0);
        ghostResolved[id] = true;
        ghostRecipient[id] = expectRecipient;
        if (expectBurn) {
            ghostBurns += 1;
        } else {
            ghostAirdrops += 1;
            _airdroppedTokens.push(a.tokenId);
        }
    }

    function revealWrongSeed(uint256 idSeed, bytes32 wrong) external {
        (uint256 id, FlipEscrow.Acquisition memory a) = _acquisitionIn(idSeed, FlipEscrow.Status.Committed);
        if (id < 1 || a.status != FlipEscrow.Status.Committed || wrong == seedOf[id]) return;
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.WrongSeed.selector, id));
        r.escrow.reveal(id, wrong);
    }

    /// Anyone may time a flip out, but only strictly after the commit timeout or the reveal window.
    function timeoutBurn(uint256 actorSeed, uint256 idSeed) external {
        (uint256 id, FlipEscrow.Acquisition memory a) = _acquisition(idSeed);
        if (id < 1) return;
        uint256 current = vm.getBlockNumber();
        bool expected;
        if (a.status == FlipEscrow.Status.Pending) {
            expected = current > uint256(a.requestBlock) + 7200;
        } else if (a.status == FlipEscrow.Status.Committed) {
            expected = current > uint256(a.commitBlock) + 202;
        }
        vm.prank(_actor(actorSeed));
        try r.escrow.timeoutBurn(id) {
            assertTrue(expected, "timeoutBurn succeeded before the deadline or on a finished flip");
            assertEq(r.nft.ownerOf(a.tokenId), DEAD, "timed-out NFT is burned");
            a = r.escrow.getAcquisition(id);
            assertTrue(a.burned);
            assertEq(a.recipient, DEAD);
            ghostResolved[id] = true;
            ghostRecipient[id] = DEAD;
            ghostTimeouts += 1;
        } catch {
            assertFalse(expected, "timeoutBurn reverted although the deadline passed");
        }
    }

    function roll(uint256 blocks) external {
        vm.roll(vm.getBlockNumber() + bound(blocks, 1, 40));
    }

    function rollPastCommitTimeout(uint256 gate) external {
        if (gate % 16 != 0) return; // rare: most runs should resolve by reveal
        vm.roll(vm.getBlockNumber() + 7201);
    }

    // ---------------------------------------------------------------- holders

    function enroll(uint256 actorSeed) external {
        _enrollAs(_participant(actorSeed));
    }

    /// @dev Enrolment modelled from first principles: refused when already enrolled, below the minimum,
    /// or (full registry) at or below the smallest recorded weight; otherwise admitted, and on a full
    /// registry the first entry with the smallest effective weight leaves and every stale entry is trimmed.
    function _enrollAs(address a) internal {
        uint256 balance = r.token.balanceOf(a);
        (uint256 lowestWeight,) = r.picker.registrationOf(r.picker.lowestHolder());
        uint256 count = r.picker.holderCount();
        bool full = count >= MAX_HOLDERS;
        bool expected = !r.picker.isEnrolled(a) && balance >= MIN_ENROLL && (!full || balance > lowestWeight);
        (address victim, uint256 victimWeight) = full && expected ? _weakestEffective() : (address(0), 0);
        vm.prank(a);
        try r.picker.enroll() {
            assertTrue(expected, "enroll succeeded for an ineligible caller");
            assertTrue(r.picker.isEnrolled(a));
            (uint256 weight, uint256 since) = r.picker.registrationOf(a);
            assertEq(weight, balance, "enroll records the live balance");
            assertEq(since, vm.getBlockNumber(), "enroll starts maturity now");
            if (full) {
                ghostDisplacements += 1;
                assertEq(r.picker.holderCount(), MAX_HOLDERS, "displacement changed the count");
                assertFalse(r.picker.isEnrolled(victim), "the weakest effective entry survived a displacement");
                assertLt(victimWeight, balance, "displaced an entry at least as heavy as the newcomer");
                _assertNoStaleWeights();
            } else {
                assertEq(r.picker.holderCount(), count + 1);
            }
        } catch {
            assertFalse(expected, "enroll reverted for an eligible caller");
            if (full && !r.picker.isEnrolled(a) && balance >= MIN_ENROLL) ghostRefusedFull += 1;
        }
    }

    /// @dev First registry slot with the smallest min(recorded, live): the entry a displacement must remove.
    function _weakestEffective() internal view returns (address weakest, uint256 weakestWeight) {
        weakestWeight = type(uint256).max;
        uint256 count = r.picker.holderCount();
        for (uint256 i = 0; i < count; ++i) {
            address h = r.picker.holderAt(i);
            (uint256 w,) = r.picker.registrationOf(h);
            uint256 live = r.token.balanceOf(h);
            uint256 eff = live < w ? live : w;
            if (eff < weakestWeight) {
                weakestWeight = eff;
                weakest = h;
            }
        }
    }

    /// @dev Right after a displacement scan no recorded weight exceeds its live balance.
    function _assertNoStaleWeights() internal view {
        uint256 count = r.picker.holderCount();
        for (uint256 i = 0; i < count; ++i) {
            address h = r.picker.holderAt(i);
            (uint256 w,) = r.picker.registrationOf(h);
            assertLe(w, r.token.balanceOf(h), "a stale weight survived the displacement scan");
        }
    }

    /// Occasionally pack the registry to its cap with small fresh holders, so later enrolments have to
    /// displace somebody and snapshots run at full size.
    function fillRegistry(uint256 gate) external {
        if (gate % 8 != 0) return;
        uint256 i = 0;
        while (r.picker.holderCount() < MAX_HOLDERS) {
            address filler = _newFiller(MIN_ENROLL + (i % 7) * 1e18);
            _enrollAs(filler);
            i += 1;
        }
    }

    /// A fresh holder sized around the smallest recorded weight tries to enrol: at or below it the
    /// constant-gas refusal fires, above it the displacement scan runs (modelled in `_enrollAs`).
    function displaceWithFiller(uint256 amountSeed) external {
        (uint256 lowestWeight,) = r.picker.registrationOf(r.picker.lowestHolder());
        uint256 low = lowestWeight > 5e18 ? lowestWeight - 5e18 : 0;
        uint256 high = lowestWeight + 5e18;
        if (low < MIN_ENROLL) low = MIN_ENROLL;
        if (high < low) high = low;
        if (high > 100 * MIN_ENROLL) high = 100 * MIN_ENROLL; // the float is finite; above this nothing new is learnt
        if (low > high) low = high;
        _enrollAs(_newFiller(bound(amountSeed, low, high)));
    }

    /// A filler moves some or all of its tokens back to the float: its recorded weight goes stale, which
    /// the next displacement scan (or anyone's `trim`) must correct, and below the minimum it is evictable.
    function drainFiller(uint256 fillerSeed, uint256 amount) external {
        if (_fillers.length == 0) return;
        address filler = _fillers[fillerSeed % _fillers.length];
        uint256 balance = r.token.balanceOf(filler);
        amount = amount % 3 == 0 ? balance : bound(amount, 0, balance);
        vm.prank(filler);
        r.token.transfer(address(this), amount);
        assertEq(r.token.balanceOf(filler), balance - amount);
    }

    /// Refresh re-records the balance; raising it restarts maturity, lowering it keeps it.
    function refresh(uint256 actorSeed) external {
        address a = _participant(actorSeed);
        uint256 balance = r.token.balanceOf(a);
        bool enrolled = r.picker.isEnrolled(a);
        (uint256 weightBefore, uint256 sinceBefore) = r.picker.registrationOf(a);
        bool expected = enrolled && balance >= MIN_ENROLL;
        vm.prank(a);
        try r.picker.refresh() {
            assertTrue(expected, "refresh succeeded for an ineligible caller");
            (uint256 weight, uint256 since) = r.picker.registrationOf(a);
            assertEq(weight, balance, "refresh records the live balance");
            assertEq(since, balance > weightBefore ? vm.getBlockNumber() : sinceBefore, "maturity rule");
        } catch {
            assertFalse(expected, "refresh reverted for an eligible caller");
        }
    }

    /// Anyone may trim a recorded weight down to the live balance, never up, never touching maturity.
    function trim(uint256 actorSeed, uint256 targetSeed) external {
        address target = _participant(targetSeed);
        uint256 balance = r.token.balanceOf(target);
        (uint256 weightBefore, uint256 sinceBefore) = r.picker.registrationOf(target);
        bool expected = r.picker.isEnrolled(target) && balance < weightBefore;
        vm.prank(_actor(actorSeed));
        try r.picker.trim(target) {
            assertTrue(expected, "trim succeeded although nothing was stale");
            (uint256 weight, uint256 since) = r.picker.registrationOf(target);
            assertEq(weight, balance, "trim records the live balance");
            assertEq(since, sinceBefore, "trim touched maturity");
            assertTrue(r.picker.isEnrolled(target), "trim evicted");
        } catch {
            assertFalse(expected, "trim reverted on a stale weight");
        }
    }

    /// Occasionally jump past the maturity period so recorded weights start counting in flips.
    function rollPastMaturity(uint256 gate) external {
        if (gate % 8 != 0) return;
        vm.roll(vm.getBlockNumber() + MATURITY + 1);
    }

    function evict(uint256 actorSeed, uint256 targetSeed) external {
        address target = _participant(targetSeed);
        bool expected = r.picker.isEnrolled(target) && r.token.balanceOf(target) < MIN_ENROLL;
        vm.prank(_actor(actorSeed));
        try r.picker.evict(target) {
            assertTrue(expected, "evicted a holder that is still eligible");
            assertFalse(r.picker.isEnrolled(target));
        } catch {
            assertFalse(expected, "could not evict a holder below the minimum");
        }
    }

    function transferTokens(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = toSeed % 9 == 0 ? DEAD : _actor(toSeed);
        uint256 balance = r.token.balanceOf(from);
        amount = bound(amount, 0, balance);
        uint256 toBefore = r.token.balanceOf(to);
        vm.prank(from);
        r.token.transfer(to, amount);
        if (from != to) {
            assertEq(r.token.balanceOf(from), balance - amount);
            assertEq(r.token.balanceOf(to), toBefore + amount);
        } else {
            assertEq(r.token.balanceOf(from), balance);
        }
    }

    function snapshot() external {
        r.picker.snapshot();
    }

    // ---------------------------------------------------------------- liquidity

    function seedMore(uint256 actorSeed, uint256 ethAmount) external {
        address a = _actor(actorSeed);
        ethAmount = bound(ethAmount, 0.001 ether, 0.5 ether);
        uint256 tokens = r.token.balanceOf(a);
        if (a.balance < ethAmount || tokens < 1) return;
        uint128 before = r.forever.totalLiquidity();
        vm.prank(a);
        try r.forever.seed{value: ethAmount}(
            TickMath.MIN_SQRT_PRICE, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, tokens
        ) returns (
            uint128 added
        ) {
            assertEq(r.forever.totalLiquidity(), before + added, "liquidity only ever grows");
            ghostLiquidityFloor = r.forever.totalLiquidity();
        } catch {}
    }
}
