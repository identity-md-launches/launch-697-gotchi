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

    function test_oneWeiListingIsAllowedAndZeroIsNot() public {
        (uint256 id,) = _list(seller, 1);
        assertEq(market.cheapest().listingId, id);
        uint256 tokenId = nft.mint(seller);
        vm.prank(seller);
        vm.expectRevert(MockBaazaar.InvalidPrice.selector);
        market.list(tokenId, 0);
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

    function test_capFreesUpAfterASaleOrCancel() public {
        uint256 cap = market.MAX_ACTIVE_LISTINGS();
        uint256 firstId;
        for (uint256 i = 0; i < cap; ++i) {
            (uint256 id,) = _list(seller, 1 ether + i);
            if (i == 0) firstId = id;
        }
        uint256 extra = nft.mint(seller);
        vm.prank(seller);
        vm.expectRevert(MockBaazaar.MarketFull.selector);
        market.list(extra, 1 ether);

        vm.prank(seller);
        market.cancel(firstId);
        vm.prank(seller);
        market.list(extra, 1 ether);
        assertEq(market.activeCount(), cap);

        vm.prank(buyer);
        market.buyCheapest{value: 1 ether}(market.cheapest().listingId, buyer);
        assertEq(market.activeCount(), cap - 1);
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
            prices[i] = bound(prices[i], 1, 5); // narrow range: plenty of ties
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
        price = bound(price, 1, 50 ether);
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
