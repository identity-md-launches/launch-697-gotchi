// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GotchiFixture} from "./utils/GotchiFixture.sol";
import {FlipEscrow} from "../src/FlipEscrow.sol";
import {GotchiConfig} from "../src/GotchiConfig.sol";

/// @notice fees -> FeeSink -> MockBaazaar.buyCheapest -> FlipEscrow -> commit/reveal -> burn or airdrop,
/// with the UI events asserted at every hop.
contract EndToEndTest is GotchiFixture {
    event FeesCollected(address indexed pool, uint256 amountEth);
    event BuyTriggered(uint256 indexed listingId, uint256 priceEth, uint256 tokenId);
    event FlipRequested(uint256 indexed acquisitionId, uint256 tokenId, bytes32 requestId);
    event FlipResolved(uint256 indexed acquisitionId, uint256 tokenId, bool burned, address indexed recipient);
    event Burned(uint256 indexed tokenId, address indexed to);
    event Airdropped(uint256 indexed tokenId, address indexed recipient, uint256 weight);
    event ListingMocked(uint256 indexed listingId, uint256 tokenId, uint256 price);

    address internal constant DEAD = GotchiConfig.BURN_ADDRESS;

    function setUp() public override {
        super.setUp();
        giveAndEnroll(alice, 10_000e18);
        giveAndEnroll(bob, 30_000e18);
    }

    function test_fullFlowToBurn() public {
        // 1. a seller lists a gotchi
        uint256 tokenId = nft.mint(seller);
        vm.startPrank(seller);
        nft.approve(address(market), tokenId);
        vm.expectEmit(true, false, false, true, address(market));
        emit ListingMocked(1, tokenId, 0.005 ether);
        market.list(tokenId, 0.005 ether);
        vm.stopPrank();

        // 2. swaps accumulate fees below the threshold: no purchase yet
        buyTokens(carol, 1 ether); // 0.003 ETH
        assertEq(address(feeSink).balance, 0.003 ether);
        assertEq(feeSink.buyCount(), 0);

        // 3. the swap that crosses the threshold triggers the purchase inside afterSwap
        uint256 fee = hook.calculateFee(3 ether); // 0.009 -> balance 0.012 >= 0.01
        bytes32 requestId = keccak256(abi.encode(block.chainid, address(escrow), 1, tokenId));
        vm.expectEmit(true, false, false, true, address(hook));
        emit FeesCollected(address(manager), fee);
        vm.expectEmit(true, false, false, true, address(feeSink));
        emit BuyTriggered(1, 0.005 ether, tokenId);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit FlipRequested(1, tokenId, requestId);
        buyTokens(carol, 3 ether);

        assertEq(feeSink.buyCount(), 1);
        assertEq(address(feeSink).balance, 0.012 ether - 0.005 ether);
        assertEq(market.proceeds(seller), 0.005 ether);
        assertEq(nft.ownerOf(tokenId), address(escrow));

        // 4. flipper commits (snapshot frozen), entropy block passes, reveal burns
        bytes32 seed = commitAndSteer(1, true);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipResolved(1, tokenId, true, DEAD);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit Burned(tokenId, DEAD);
        escrow.reveal(1, seed);
        assertEq(nft.ownerOf(tokenId), DEAD);

        // 5. the seller withdraws
        uint256 before = seller.balance;
        vm.prank(seller);
        market.withdrawProceeds();
        assertEq(seller.balance, before + 0.005 ether);
    }

    function test_fullFlowToAirdrop() public {
        (, uint256 tokenId) = listNft(seller, 0.004 ether);
        buyTokens(carol, 4 ether); // 0.012 ETH fee -> buys at 0.004
        assertEq(nft.ownerOf(tokenId), address(escrow));

        bytes32 seed = commitAndSteer(1, false);
        vm.expectEmit(true, false, false, false, address(escrow));
        emit FlipResolved(1, tokenId, false, address(0)); // recipient checked below
        escrow.reveal(1, seed);

        address recipient = escrow.getAcquisition(1).recipient;
        assertTrue(recipient == alice || recipient == bob, "airdropped to an enrolled holder");
        assertEq(nft.ownerOf(tokenId), recipient);
        assertEq(address(feeSink).balance, 0.012 ether - 0.004 ether, "change stays for the next listing");
    }

    function test_keeperPathWhenListingAppearsAfterTheSwap() public {
        // fees arrive while nothing is listed
        buyTokens(carol, 4 ether);
        assertEq(feeSink.buyCount(), 0);
        assertEq(address(feeSink).balance, 0.012 ether);
        // a listing appears later: the owner (keeper) retries without waiting for a swap
        (, uint256 tokenId) = listNft(seller, 0.01 ether);
        assertTrue(feeSink.tryBuy());
        assertEq(nft.ownerOf(tokenId), address(escrow));
        assertEq(address(feeSink).balance, 0.002 ether);
    }

    function test_multipleAcquisitionsResolveIndependently() public {
        listNft(seller, 0.003 ether);
        listNft(seller, 0.003 ether);
        buyTokens(carol, 4 ether); // 0.012: first buy inside afterSwap -> 0.009
        assertEq(feeSink.buyCount(), 1);
        sellTokens(carol, token.balanceOf(carol)); // some ETH fee, triggers the second buy
        assertEq(feeSink.buyCount(), 2);
        assertEq(escrow.acquisitionCount(), 2);

        bytes32 s1 = commitAndSteer(1, true);
        bytes32 s2 = commitAndSteer(2, false);
        escrow.reveal(2, s2);
        escrow.reveal(1, s1);
        assertTrue(escrow.getAcquisition(1).burned);
        assertFalse(escrow.getAcquisition(2).burned);
    }

    function test_ethConservationAcrossTheWholeSystem() public {
        listNft(seller, 0.004 ether);
        uint256 systemBefore = address(manager).balance + address(feeSink).balance + address(market).balance;
        uint256 carolBefore = carol.balance;
        buyTokens(carol, 4 ether);
        uint256 systemAfter = address(manager).balance + address(feeSink).balance + address(market).balance;
        assertEq(systemAfter - systemBefore, carolBefore - carol.balance, "every wei carol paid is in the system");
        assertEq(address(hook).balance, 0);
        assertEq(address(escrow).balance, 0);
        assertEq(address(router).balance, 0);
    }
}
