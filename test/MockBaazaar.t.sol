// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {MockGotchiNFT} from "../src/MockGotchiNFT.sol";
import {MockBaazaar} from "../src/MockBaazaar.sol";
import {IMockBaazaar} from "../src/interfaces/IMockBaazaar.sol";
import {GotchiConfig} from "../src/GotchiConfig.sol";

contract MockBaazaarTest is Test {
    MockGotchiNFT internal nft;
    MockBaazaar internal market;

    address internal seller = makeAddr("seller");
    address internal other = makeAddr("other");
    address internal buyer = makeAddr("buyer");
    address internal escrow = makeAddr("escrow");

    event ListingMocked(uint256 indexed listingId, uint256 tokenId, uint256 price);
    event ListingSold(uint256 indexed listingId, uint256 tokenId, uint256 price, address indexed buyer, address to);

    function setUp() public {
        nft = new MockGotchiNFT();
        market = new MockBaazaar(address(nft));
        vm.deal(buyer, 10 ether);
    }

    function _list(address who, uint256 price) internal returns (uint256 listingId, uint256 tokenId) {
        tokenId = nft.mint(who);
        vm.startPrank(who);
        nft.approve(address(market), tokenId);
        listingId = market.list(tokenId, price);
        vm.stopPrank();
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(MockBaazaar.ZeroAddress.selector);
        new MockBaazaar(address(0));
    }

    function test_listEscrowsNftAndEmits() public {
        uint256 tokenId = nft.mint(seller);
        vm.startPrank(seller);
        nft.approve(address(market), tokenId);
        vm.expectEmit(true, false, false, true, address(market));
        emit ListingMocked(1, tokenId, 0.5 ether);
        uint256 listingId = market.list(tokenId, 0.5 ether);
        vm.stopPrank();

        assertEq(listingId, 1);
        assertEq(nft.ownerOf(tokenId), address(market));
        IMockBaazaar.Listing memory l = market.getListing(listingId);
        assertEq(l.tokenId, tokenId);
        assertEq(l.price, 0.5 ether);
        assertEq(l.seller, seller);
        assertTrue(l.active);
        assertEq(market.activeCount(), 1);
        assertEq(market.activeIdAt(0), 1);
    }

    function test_listRejectsZeroPriceAndUnownedToken() public {
        uint256 tokenId = nft.mint(seller);
        vm.prank(seller);
        vm.expectRevert(MockBaazaar.InvalidPrice.selector);
        market.list(tokenId, 0);

        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(market), tokenId)
        );
        market.list(tokenId, 1 ether);
    }

    function test_listIsCapped() public {
        for (uint256 i = 0; i < GotchiConfig.MAX_ACTIVE_LISTINGS; ++i) {
            _list(seller, 1 ether);
        }
        uint256 tokenId = nft.mint(seller);
        vm.startPrank(seller);
        nft.approve(address(market), tokenId);
        vm.expectRevert(MockBaazaar.MarketFull.selector);
        market.list(tokenId, 1 ether);
        vm.stopPrank();
    }

    function test_cheapestPicksLowestPriceThenLowestId() public {
        (uint256 a,) = _list(seller, 3 ether);
        (uint256 b,) = _list(other, 1 ether);
        (uint256 c,) = _list(seller, 1 ether);
        assertEq(a, 1);
        assertEq(c, 3);
        IMockBaazaar.Listing memory best = market.cheapest();
        assertEq(best.listingId, b, "ties resolve to the lower listing id");
        assertEq(best.price, 1 ether);
    }

    function test_cheapestIsInactiveWhenEmpty() public view {
        assertFalse(market.cheapest().active);
    }

    function test_buyCheapestPaysSellerAndDeliversNft() public {
        (, uint256 expensive) = _list(seller, 2 ether);
        (uint256 cheapId, uint256 cheapToken) = _list(other, 1 ether);

        vm.prank(buyer);
        vm.expectEmit(true, true, false, true, address(market));
        emit ListingSold(cheapId, cheapToken, 1 ether, buyer, escrow);
        uint256 tokenId = market.buyCheapest{value: 1 ether}(cheapId, escrow);

        assertEq(tokenId, cheapToken);
        assertEq(nft.ownerOf(cheapToken), escrow, "NFT delivered to the requested recipient");
        assertEq(nft.ownerOf(expensive), address(market), "other listing untouched");
        assertEq(market.proceeds(other), 1 ether, "seller credited");
        assertEq(market.proceeds(seller), 0);
        assertFalse(market.getListing(cheapId).active);
        assertEq(market.activeCount(), 1);
        assertEq(market.cheapest().price, 2 ether);

        uint256 before = other.balance;
        vm.prank(other);
        market.withdrawProceeds();
        assertEq(other.balance, before + 1 ether, "seller paid on withdraw");
        assertEq(market.proceeds(other), 0);
        vm.prank(other);
        vm.expectRevert(MockBaazaar.NothingToWithdraw.selector);
        market.withdrawProceeds();
    }

    function test_buyCheapestFailureModes() public {
        vm.prank(buyer);
        vm.expectRevert(MockBaazaar.NoListings.selector);
        market.buyCheapest{value: 1 ether}(1, escrow);

        (uint256 id,) = _list(seller, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.InsufficientPayment.selector, 1 ether, 1 ether - 1));
        market.buyCheapest{value: 1 ether - 1}(id, escrow);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.CheapestChanged.selector, 99, id));
        market.buyCheapest{value: 1 ether}(99, escrow);

        vm.prank(buyer);
        vm.expectRevert(MockBaazaar.ZeroAddress.selector);
        market.buyCheapest{value: 1 ether}(id, address(0));
    }

    function test_overpaymentGoesToSeller() public {
        (uint256 id,) = _list(seller, 1 ether);
        vm.prank(buyer);
        market.buyCheapest{value: 1.5 ether}(id, escrow);
        assertEq(market.proceeds(seller), 1.5 ether);
    }

    function test_cancelReturnsNftToSellerOnly() public {
        (uint256 id, uint256 tokenId) = _list(seller, 1 ether);
        vm.prank(other);
        vm.expectRevert(MockBaazaar.NotSeller.selector);
        market.cancel(id);

        vm.prank(seller);
        market.cancel(id);
        assertEq(nft.ownerOf(tokenId), seller);
        assertEq(market.activeCount(), 0);
        vm.prank(seller);
        vm.expectRevert(MockBaazaar.NoListings.selector);
        market.cancel(id);
    }

    function test_withdrawToRevertingSellerFailsWithoutLosingCredit() public {
        RejectsEth bad = new RejectsEth();
        uint256 tokenId = nft.mint(address(bad));
        bad.list(nft, market, tokenId, 1 ether);
        vm.prank(buyer);
        market.buyCheapest{value: 1 ether}(1, escrow);
        assertEq(market.proceeds(address(bad)), 1 ether);
        vm.expectRevert(MockBaazaar.WithdrawFailed.selector);
        bad.withdraw(market);
        assertEq(market.proceeds(address(bad)), 1 ether, "credit intact");
    }

    function test_ethConservation() public {
        _list(seller, 1 ether);
        _list(other, 2 ether);
        vm.startPrank(buyer);
        market.buyCheapest{value: 1 ether}(1, escrow);
        market.buyCheapest{value: 2 ether}(2, escrow);
        vm.stopPrank();
        assertEq(address(market).balance, market.proceeds(seller) + market.proceeds(other));
        assertEq(address(market).balance, 3 ether);
    }
}

contract RejectsEth {
    function list(MockGotchiNFT nft, MockBaazaar market, uint256 tokenId, uint256 price) external {
        nft.approve(address(market), tokenId);
        market.list(tokenId, price);
    }

    function withdraw(MockBaazaar market) external {
        market.withdrawProceeds();
    }
}
