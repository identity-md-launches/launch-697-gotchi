// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockGotchiNFT} from "../../src/MockGotchiNFT.sol";
import {MockBaazaar} from "../../src/MockBaazaar.sol";
import {IMockBaazaar} from "../../src/interfaces/IMockBaazaar.sol";

/// @notice Ordering, bookkeeping and hostile-counterparty edges of MockBaazaar.
contract MockBaazaarEdgeTest is Test {
    event ListingMocked(uint256 indexed listingId, uint256 tokenId, uint256 price);
    event ListingEvicted(uint256 indexed listingId, uint256 tokenId, uint256 indexed byListingId);

    uint256 internal constant FLOOR = 0.001 ether; // MIN_LIST_PRICE

    MockGotchiNFT internal nft;
    MockBaazaar internal market;
    address internal seller = makeAddr("seller");
    address internal other = makeAddr("other");
    address internal buyer = makeAddr("buyer");

    function setUp() public {
        nft = new MockGotchiNFT();
        market = new MockBaazaar(address(nft));
        vm.deal(buyer, 100 ether);
        vm.prank(seller);
        nft.setApprovalForAll(address(market), true);
        vm.prank(other);
        nft.setApprovalForAll(address(market), true);
    }

    function _list(address who, uint256 price) internal returns (uint256 listingId, uint256 tokenId) {
        tokenId = nft.mint(who);
        vm.prank(who);
        listingId = market.list(tokenId, price);
    }

    // ---- list ----

    function test_floorPriceIsAllowedAndBelowFloorZeroAndAboveUint192AreNot() public {
        (uint256 id,) = _list(seller, FLOOR);
        assertEq(market.cheapest().listingId, id);
        (uint256 top,) = _list(seller, type(uint192).max); // the largest price the packed key can hold
        assertEq(market.getListing(top).price, type(uint192).max);
        assertEq(market.cheapest().listingId, id, "the floor listing stays cheapest");

        uint256 tokenId = nft.mint(seller);
        vm.startPrank(seller);
        vm.expectRevert(MockBaazaar.InvalidPrice.selector);
        market.list(tokenId, FLOOR - 1);
        vm.expectRevert(MockBaazaar.InvalidPrice.selector);
        market.list(tokenId, 0);
        vm.expectRevert(MockBaazaar.InvalidPrice.selector);
        market.list(tokenId, uint256(type(uint192).max) + 1);
        vm.expectRevert(MockBaazaar.InvalidPrice.selector);
        market.list(tokenId, type(uint256).max);
        vm.stopPrank();
        assertEq(market.activeCount(), 2);
        assertEq(market.nextListingId(), 3, "refused listings consume no id");
    }

    function test_failedListLeavesNoTrace() public {
        uint256 tokenId = nft.mint(buyer); // buyer never approved the market
        uint256 nextBefore = market.nextListingId();
        vm.prank(buyer);
        vm.expectRevert();
        market.list(tokenId, 1 ether);
        assertEq(market.nextListingId(), nextBefore, "listing id consumed by a failed list");
        assertEq(market.activeCount(), 0);
        assertFalse(market.cheapest().active);
    }

    function test_cannotListSomeoneElsesToken() public {
        uint256 tokenId = nft.mint(seller); // seller approved the market for all
        vm.prank(other);
        vm.expectRevert();
        market.list(tokenId, 1 ether);
        assertEq(nft.ownerOf(tokenId), seller);
    }

    function test_cannotListATokenThatIsAlreadyListed() public {
        (, uint256 tokenId) = _list(seller, 1 ether);
        vm.prank(seller);
        vm.expectRevert();
        market.list(tokenId, 0.5 ether);
        assertEq(market.activeCount(), 1);
    }

    function test_listEmitsListingMockedWithStableIndexedId() public {
        uint256 tokenId = nft.mint(seller);
        vm.expectEmit(true, false, false, true, address(market));
        emit ListingMocked(1, tokenId, 7 ether);
        vm.prank(seller);
        market.list(tokenId, 7 ether);
    }

    function test_fullMarketEvictsOnlyForAStrictlyCheaperListing() public {
        uint256 cap = market.MAX_ACTIVE_LISTINGS();
        uint256 firstId;
        uint256 dearestId;
        uint256 dearestToken;
        for (uint256 i = 0; i < cap; ++i) {
            (uint256 id, uint256 tokenId) = _list(i == cap - 1 ? other : seller, 1 ether + i);
            if (i == 0) firstId = id;
            if (i == cap - 1) (dearestId, dearestToken) = (id, tokenId);
        }
        uint256 extra = nft.mint(seller);
        vm.startPrank(seller);
        vm.expectRevert(MockBaazaar.MarketFull.selector);
        market.list(extra, 1 ether + cap - 1); // equal to the most expensive: not strictly cheaper
        vm.expectRevert(MockBaazaar.MarketFull.selector);
        market.list(extra, 10 ether);
        assertEq(market.nextListingId(), cap + 1, "refused listings consume no id");

        // one wei cheaper than the dearest: it takes the dearest's slot and the NFT goes home
        vm.expectEmit(true, true, false, true, address(market));
        emit ListingEvicted(dearestId, dearestToken, cap + 1);
        uint256 newId = market.list(extra, 1 ether + cap - 2);
        vm.stopPrank();
        assertEq(newId, cap + 1);
        assertEq(market.activeCount(), cap);
        assertFalse(market.getListing(dearestId).active);
        assertTrue(market.getListing(newId).active);
        assertEq(nft.ownerOf(dearestToken), other, "evicted NFT returned to its seller");
        assertEq(nft.ownerOf(extra), address(market));
        assertEq(market.proceeds(other), 0, "eviction pays nobody");
        for (uint256 i = 0; i < cap; ++i) {
            assertTrue(market.activeIdAt(i) != dearestId, "evicted id still in the active set");
        }
        vm.prank(other);
        vm.expectRevert(MockBaazaar.NoListings.selector);
        market.cancel(dearestId);

        // a cancel frees a slot, after which even a dearer listing fits without evicting anyone
        vm.prank(seller);
        market.cancel(firstId);
        uint256 dear = nft.mint(seller);
        vm.prank(seller);
        market.list(dear, 10 ether);
        assertEq(market.activeCount(), cap);
        assertTrue(market.getListing(newId).active, "nothing evicted when a slot was free");

        vm.prank(buyer);
        market.buyCheapest{value: 1 ether + 1}(market.cheapest().listingId, buyer);
        assertEq(market.activeCount(), cap - 1);
    }

    function test_evictionTieGoesToTheNewestOfTheDearest() public {
        uint256 cap = market.MAX_ACTIVE_LISTINGS();
        for (uint256 i = 0; i < cap - 2; ++i) {
            _list(seller, 1 ether);
        }
        (uint256 olderDear, uint256 olderToken) = _list(seller, 3 ether);
        (uint256 newerDear, uint256 newerToken) = _list(other, 3 ether);
        (uint256 a,) = _list(seller, 2 ether);
        assertFalse(market.getListing(newerDear).active, "newest of the tied dearest goes first");
        assertTrue(market.getListing(olderDear).active);
        assertEq(nft.ownerOf(newerToken), other);
        (uint256 b,) = _list(other, 2 ether - 1);
        assertFalse(market.getListing(olderDear).active, "then the older one");
        assertEq(nft.ownerOf(olderToken), seller);
        assertTrue(market.getListing(a).active && market.getListing(b).active);
        // now the dearest is `a` at 2 ETH; an equal price is refused, the evicted seller may come back cheaper
        uint256 again = nft.mint(other);
        vm.startPrank(other);
        vm.expectRevert(MockBaazaar.MarketFull.selector);
        market.list(again, 2 ether);
        uint256 back = market.list(again, 1.5 ether);
        vm.stopPrank();
        assertFalse(market.getListing(a).active);
        assertTrue(market.getListing(back).active);
        assertEq(market.activeCount(), cap);
    }

    function test_evictedSellerCanBeTheListerThemself() public {
        uint256 cap = market.MAX_ACTIVE_LISTINGS();
        for (uint256 i = 0; i < cap - 1; ++i) {
            _list(seller, 1 ether);
        }
        (uint256 dear, uint256 dearToken) = _list(seller, 5 ether);
        (, uint256 cheapToken) = _list(seller, FLOOR);
        assertFalse(market.getListing(dear).active);
        assertEq(nft.ownerOf(dearToken), seller, "the seller got their own dear NFT back");
        assertEq(nft.ownerOf(cheapToken), address(market));
        assertEq(nft.balanceOf(address(market)), cap);
        assertEq(market.cheapest().tokenId, cheapToken);
    }

    /// A full market whose every slot sits at the floor admits nothing new until something sells or is
    /// cancelled: nothing can be strictly cheaper than the floor. Recorded as a limitation (see the
    /// findings file); this only pins the escape hatches, not the freeze itself.
    function test_floorFilledMarketUnfreezesThroughSalesAndCancels() public {
        uint256 cap = market.MAX_ACTIVE_LISTINGS();
        uint256 lastId;
        for (uint256 i = 0; i < cap; ++i) {
            (lastId,) = _list(other, FLOOR);
        }
        uint256 mine = nft.mint(seller);
        vm.prank(seller);
        vm.expectRevert(MockBaazaar.MarketFull.selector);
        market.list(mine, FLOOR);

        vm.prank(buyer);
        market.buyCheapest{value: FLOOR}(market.cheapest().listingId, buyer);
        vm.prank(seller);
        uint256 id = market.list(mine, FLOOR);
        assertTrue(market.getListing(id).active);

        vm.prank(other);
        market.cancel(lastId);
        uint256 another = nft.mint(seller);
        vm.prank(seller);
        market.list(another, 1 ether);
        assertEq(market.activeCount(), cap);
    }

    // ---- cancel ----

    function test_cancelInTheMiddleKeepsTheActiveSetConsistent() public {
        (uint256 a,) = _list(seller, 5 ether);
        (uint256 b,) = _list(seller, 1 ether);
        (uint256 c,) = _list(seller, 3 ether);
        (uint256 d,) = _list(seller, 2 ether);
        vm.prank(seller);
        market.cancel(b); // the cheapest, stored in the middle
        assertEq(market.activeCount(), 3);
        assertEq(market.cheapest().listingId, d);
        vm.prank(seller);
        market.cancel(d); // was moved into b's slot by swap-and-pop
        assertEq(market.cheapest().listingId, c);
        vm.prank(seller);
        market.cancel(c);
        assertEq(market.cheapest().listingId, a);
        vm.prank(seller);
        market.cancel(a);
        assertEq(market.activeCount(), 0);
        assertFalse(market.cheapest().active);
    }

    function test_cancelTwiceOrUnknownOrSoldReverts() public {
        (uint256 id,) = _list(seller, 1 ether);
        vm.prank(seller);
        market.cancel(id);
        vm.prank(seller);
        vm.expectRevert(MockBaazaar.NoListings.selector);
        market.cancel(id);
        vm.expectRevert(MockBaazaar.NoListings.selector);
        market.cancel(0);
        vm.expectRevert(MockBaazaar.NoListings.selector);
        market.cancel(999);

        (uint256 sold,) = _list(seller, 1 ether);
        vm.prank(buyer);
        market.buyCheapest{value: 1 ether}(sold, buyer);
        vm.prank(seller);
        vm.expectRevert(MockBaazaar.NoListings.selector);
        market.cancel(sold);
    }

    function test_cancelledListingCannotBeBought() public {
        (uint256 cheap,) = _list(seller, 1 ether);
        (uint256 dear,) = _list(other, 2 ether);
        vm.prank(seller);
        market.cancel(cheap);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.CheapestChanged.selector, cheap, dear));
        market.buyCheapest{value: 1 ether}(cheap, buyer);
    }

    // ---- buyCheapest ----

    function test_buyOnEmptyMarketReverts() public {
        vm.prank(buyer);
        vm.expectRevert(MockBaazaar.NoListings.selector);
        market.buyCheapest{value: 1 ether}(1, buyer);
        assertEq(address(market).balance, 0);
    }

    function test_underpayByOneWeiReverts() public {
        (uint256 id, uint256 tokenId) = _list(seller, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.InsufficientPayment.selector, 1 ether, 1 ether - 1));
        market.buyCheapest{value: 1 ether - 1}(id, buyer);
        assertEq(nft.ownerOf(tokenId), address(market));
        assertEq(market.proceeds(seller), 0);
    }

    function test_cheaperListingLandingFirstInvalidatesTheExpectedId() public {
        (uint256 expected,) = _list(seller, 1 ether);
        (uint256 undercut,) = _list(other, 1 ether - 1); // front-runs the buyer
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.CheapestChanged.selector, expected, undercut));
        market.buyCheapest{value: 1 ether}(expected, buyer);
    }

    function test_equalPriceTieGoesToTheOlderListing() public {
        (uint256 first, uint256 firstToken) = _list(seller, 1 ether);
        (uint256 second,) = _list(other, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.CheapestChanged.selector, second, first));
        market.buyCheapest{value: 1 ether}(second, buyer);
        vm.prank(buyer);
        assertEq(market.buyCheapest{value: 1 ether}(first, buyer), firstToken);
        assertEq(market.proceeds(seller), 1 ether);
        assertEq(market.proceeds(other), 0);
        assertEq(market.cheapest().listingId, second);
    }

    function test_soldTokenCanBeRelistedUnderANewId() public {
        (uint256 id, uint256 tokenId) = _list(seller, 1 ether);
        vm.prank(buyer);
        market.buyCheapest{value: 1 ether}(id, buyer);
        vm.startPrank(buyer);
        nft.approve(address(market), tokenId);
        uint256 relisted = market.list(tokenId, 2 ether);
        vm.stopPrank();
        assertEq(relisted, id + 1);
        IMockBaazaar.Listing memory old = market.getListing(id);
        assertFalse(old.active);
        assertEq(old.seller, seller, "history of the sold listing is kept");
        assertEq(market.getListing(relisted).seller, buyer);
    }

    function test_sellerMayBuyTheirOwnListing() public {
        (uint256 id, uint256 tokenId) = _list(seller, 1 ether);
        vm.deal(seller, 1 ether);
        vm.prank(seller);
        market.buyCheapest{value: 1 ether}(id, seller);
        assertEq(nft.ownerOf(tokenId), seller);
        vm.prank(seller);
        market.withdrawProceeds();
        assertEq(seller.balance, 1 ether);
        assertEq(address(market).balance, 0);
    }

    function test_marketRejectsPlainEth() public {
        vm.prank(buyer);
        (bool ok,) = address(market).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ---- withdraw ----

    function test_withdrawWithNothingAndWithdrawTwice() public {
        vm.prank(seller);
        vm.expectRevert(MockBaazaar.NothingToWithdraw.selector);
        market.withdrawProceeds();
        (uint256 id,) = _list(seller, 1 ether);
        vm.prank(buyer);
        market.buyCheapest{value: 1 ether}(id, buyer);
        vm.prank(seller);
        market.withdrawProceeds();
        assertEq(seller.balance, 1 ether);
        vm.prank(seller);
        vm.expectRevert(MockBaazaar.NothingToWithdraw.selector);
        market.withdrawProceeds();
        assertEq(address(market).balance, 0);
    }

    function test_withdrawCannotTouchAnotherSellersCredit() public {
        (uint256 a,) = _list(seller, 1 ether);
        _list(other, 2 ether);
        vm.prank(buyer);
        market.buyCheapest{value: 1 ether}(a, buyer);
        vm.prank(buyer);
        market.buyCheapest{value: 2 ether}(market.cheapest().listingId, buyer);
        vm.prank(seller);
        market.withdrawProceeds();
        assertEq(seller.balance, 1 ether);
        assertEq(market.proceeds(other), 2 ether);
        assertEq(address(market).balance, 2 ether);
    }

    function test_reentrantSellerCannotWithdrawTwice() public {
        ReentrantSeller evil = new ReentrantSeller(market, nft);
        uint256 evilListing = evil.listOne(1 ether);
        (uint256 honest,) = _list(seller, 2 ether);
        vm.prank(buyer);
        market.buyCheapest{value: 1 ether}(evilListing, buyer);
        vm.prank(buyer);
        market.buyCheapest{value: 2 ether}(honest, buyer);
        assertEq(address(market).balance, 3 ether);

        evil.withdraw();
        assertEq(evil.reentryBlocked(), 1, "nested withdraw must hit the guard");
        assertEq(address(evil).balance, 1 ether, "paid once");
        assertEq(address(market).balance, 2 ether, "the honest seller's credit is intact");
        assertEq(market.proceeds(seller), 2 ether);
    }

    function test_revertingSellerDoesNotBlockTheSaleOfTheirListing() public {
        ReentrantSeller evil = new ReentrantSeller(market, nft);
        evil.setRejectEth(true);
        uint256 id = evil.listOne(1 ether);
        vm.prank(buyer);
        uint256 tokenId = market.buyCheapest{value: 1 ether}(id, buyer);
        assertEq(nft.ownerOf(tokenId), buyer, "pull payments: the sale cannot be blocked by the seller");
        vm.expectRevert(MockBaazaar.WithdrawFailed.selector);
        evil.withdraw();
        assertEq(market.proceeds(address(evil)), 1 ether, "credit survives a failed withdrawal");
    }

    // ---- properties ----

    /// `cheapest()` equals a brute-force minimum (lowest price, then lowest id) after random lists,
    /// cancels and buys; sellers are credited exactly what buyers send.
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_cheapestMatchesBruteForce(uint256[12] memory prices, uint16 cancelMask, uint8 buys) public {
        uint256[12] memory ids;
        bool[12] memory live;
        for (uint256 i = 0; i < 12; ++i) {
            prices[i] = bound(prices[i], FLOOR, FLOOR + 4); // narrow range: plenty of ties
            (ids[i],) = _list(i % 2 == 0 ? seller : other, prices[i]);
            live[i] = true;
        }
        for (uint256 i = 0; i < 12; ++i) {
            if (cancelMask & (1 << i) != 0) {
                vm.prank(i % 2 == 0 ? seller : other);
                market.cancel(ids[i]);
                live[i] = false;
            }
        }
        uint256 paid = 0;
        buys = uint8(bound(buys, 0, 12));
        for (uint256 round = 0; round <= buys; ++round) {
            bool any = false;
            uint256 best = 0;
            for (uint256 i = 0; i < 12; ++i) {
                if (!live[i]) continue;
                if (!any || prices[i] < prices[best]) {
                    best = i; // ids ascend with i, so the first minimum is the lowest id
                    any = true;
                }
            }
            IMockBaazaar.Listing memory c = market.cheapest();
            assertEq(c.active, any);
            if (!any) break;
            assertEq(c.listingId, ids[best]);
            assertEq(c.price, prices[best]);
            if (round == buys) break;
            vm.prank(buyer);
            market.buyCheapest{value: prices[best]}(ids[best], buyer);
            live[best] = false;
            paid += prices[best];
        }
        assertEq(market.proceeds(seller) + market.proceeds(other), paid);
        assertEq(address(market).balance, paid);
        uint256 liveCount = 0;
        for (uint256 i = 0; i < 12; ++i) {
            if (live[i]) liveCount += 1;
        }
        assertEq(market.activeCount(), liveCount);
        assertEq(nft.balanceOf(address(market)), liveCount);
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_sellerIsCreditedExactlyWhatWasSent(uint256 price, uint256 extra) public {
        price = bound(price, FLOOR, 50 ether);
        extra = bound(extra, 0, 50 ether);
        (uint256 id, uint256 tokenId) = _list(seller, price);
        vm.prank(buyer);
        market.buyCheapest{value: price + extra}(id, other);
        assertEq(nft.ownerOf(tokenId), other, "NFT goes to `to`, not the payer");
        assertEq(market.proceeds(seller), price + extra);
        vm.prank(seller);
        market.withdrawProceeds();
        assertEq(seller.balance, price + extra);
        assertEq(address(market).balance, 0);
    }

    /// With the market full, every new listing either evicts exactly the model's "most expensive, newest
    /// on a tie" entry or is refused with MarketFull; the active set and `cheapest()` track the model.
    /// forge-config: default.fuzz.runs = 150
    function testFuzz_fullMarketEvictionFollowsTheModel(uint256 seed, uint8 rounds) public {
        uint256 cap = market.MAX_ACTIVE_LISTINGS();
        uint256[] memory ids = new uint256[](cap);
        uint256[] memory prices = new uint256[](cap);
        uint256[] memory tokens = new uint256[](cap);
        address[] memory sellers = new address[](cap);
        for (uint256 i = 0; i < cap; ++i) {
            prices[i] = FLOOR + bound(uint256(keccak256(abi.encode(seed, "p", i))), 0, 6);
            sellers[i] = i % 3 == 0 ? other : seller;
            (ids[i], tokens[i]) = _list(sellers[i], prices[i]);
        }
        rounds = uint8(bound(rounds, 1, 24));
        for (uint256 r = 0; r < rounds; ++r) {
            uint256 price = FLOOR + bound(uint256(keccak256(abi.encode(seed, "n", r))), 0, 6);
            // model: the slot that goes is the highest price, highest id on a tie
            uint256 victim = 0;
            for (uint256 i = 1; i < cap; ++i) {
                if (prices[i] > prices[victim] || (prices[i] == prices[victim] && ids[i] > ids[victim])) victim = i;
            }
            address lister = r % 2 == 0 ? seller : other;
            uint256 tokenId = nft.mint(lister);
            uint256 nextId = market.nextListingId();
            vm.prank(lister);
            if (price >= prices[victim]) {
                vm.expectRevert(MockBaazaar.MarketFull.selector);
                market.list(tokenId, price);
                assertEq(market.nextListingId(), nextId);
                continue;
            }
            uint256 newId = market.list(tokenId, price);
            assertEq(newId, nextId);
            assertFalse(market.getListing(ids[victim]).active, "model victim still active");
            assertEq(nft.ownerOf(tokens[victim]), sellers[victim], "victim's NFT not returned");
            ids[victim] = newId;
            prices[victim] = price;
            tokens[victim] = tokenId;
            sellers[victim] = lister;
            assertEq(market.activeCount(), cap);
        }
        // the live active set equals the model, and cheapest is the model minimum (lowest id on a tie)
        uint256 best = 0;
        for (uint256 i = 0; i < cap; ++i) {
            if (prices[i] < prices[best] || (prices[i] == prices[best] && ids[i] < ids[best])) best = i;
            IMockBaazaar.Listing memory l = market.getListing(ids[i]);
            assertTrue(l.active);
            assertEq(l.price, prices[i]);
            assertEq(l.seller, sellers[i]);
            assertEq(nft.ownerOf(tokens[i]), address(market));
        }
        IMockBaazaar.Listing memory c = market.cheapest();
        assertEq(c.listingId, ids[best]);
        assertEq(c.price, prices[best]);
        assertEq(nft.balanceOf(address(market)), cap);
        assertEq(address(market).balance, 0, "eviction moves no ETH");
    }
}

/// @dev A seller contract that re-enters `withdrawProceeds` from its receive hook, or rejects ETH.
contract ReentrantSeller {
    MockBaazaar internal immutable market;
    MockGotchiNFT internal immutable nft;
    uint256 public reentryBlocked;
    bool public rejectEth;
    bool internal entered;

    constructor(MockBaazaar market_, MockGotchiNFT nft_) {
        market = market_;
        nft = nft_;
        nft_.setApprovalForAll(address(market_), true);
    }

    function setRejectEth(bool value) external {
        rejectEth = value;
    }

    function listOne(uint256 price) external returns (uint256) {
        return market.list(nft.mint(address(this)), price);
    }

    function withdraw() external {
        market.withdrawProceeds();
    }

    receive() external payable {
        require(!rejectEth, "no thanks");
        if (!entered) {
            entered = true;
            try market.withdrawProceeds() {}
            catch (bytes memory reason) {
                if (bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector) reentryBlocked += 1;
            }
        }
    }
}
