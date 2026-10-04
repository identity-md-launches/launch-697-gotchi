// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GotchiFixture} from "../utils/GotchiFixture.sol";
import {FeeSink} from "../../src/FeeSink.sol";
import {FlipEscrow} from "../../src/FlipEscrow.sol";
import {MockBaazaar} from "../../src/MockBaazaar.sol";
import {IFlipEscrow} from "../../src/interfaces/IFlipEscrow.sol";
import {IMockBaazaar} from "../../src/interfaces/IMockBaazaar.sol";

/// @notice Threshold boundaries, hostile siblings and role handover for FeeSink.
contract FeeSinkEdgeTest is GotchiFixture {
    uint256 internal constant THRESHOLD = 0.01 ether;
    uint256 internal constant FLOOR = 0.001 ether; // MIN_LIST_PRICE == MIN_BUY_PRICE
    uint256 internal constant CEILING = 0.05 ether; // MAX_BUY_PRICE

    // ---- threshold boundaries ----

    function test_oneWeiBelowThresholdNeverBuysEvenTheCheapestAllowedListing() public {
        (uint256 id,) = listNft(seller, FLOOR);
        fundSink(THRESHOLD - 1);
        assertFalse(feeSink.tryBuy());
        assertTrue(market.getListing(id).active);
        assertEq(address(feeSink).balance, THRESHOLD - 1);
        assertEq(feeSink.totalSpent(), 0);
    }

    function test_exactlyAtThresholdBuysAListingPricedAtTheWholeBalance() public {
        (, uint256 tokenId) = listNft(seller, THRESHOLD);
        fundSink(THRESHOLD);
        assertTrue(feeSink.tryBuy());
        assertEq(address(feeSink).balance, 0);
        assertEq(feeSink.totalSpent(), THRESHOLD);
        assertEq(market.proceeds(seller), THRESHOLD);
        assertEq(nft.ownerOf(tokenId), address(escrow));
    }

    function test_listingOneWeiAboveTheBalanceIsNotBought() public {
        (uint256 id,) = listNft(seller, 0.02 ether + 1);
        fundSink(0.02 ether);
        assertFalse(feeSink.tryBuy());
        assertTrue(market.getListing(id).active);
        fundSink(1);
        assertTrue(feeSink.tryBuy());
        assertEq(address(feeSink).balance, 0);
    }

    function test_onlyOnePurchasePerCall() public {
        listNft(seller, 0.001 ether);
        listNft(seller, 0.001 ether);
        fundSink(1 ether);
        assertTrue(feeSink.tryBuy());
        assertEq(feeSink.buyCount(), 1);
        assertEq(market.activeCount(), 1);
    }

    function test_unaffordableCheapestBlocksEvenIfNothingElseIsListed() public {
        listNft(seller, 5 ether);
        fundSink(1 ether);
        (bool possible, IMockBaazaar.Listing memory c) = feeSink.pendingBuy();
        assertFalse(possible);
        assertEq(c.price, 5 ether);
        assertFalse(feeSink.tryBuy());
        assertEq(address(feeSink).balance, 1 ether);
    }

    function test_cancelledCheapestFallsThroughToTheNextListing() public {
        (uint256 cheap,) = listNft(seller, 0.001 ether);
        (, uint256 nextToken) = listNft(alice, 0.002 ether);
        fundSink(THRESHOLD);
        (, IMockBaazaar.Listing memory seen) = feeSink.pendingBuy();
        assertEq(seen.listingId, cheap);
        vm.prank(seller);
        market.cancel(cheap);
        assertTrue(feeSink.tryBuy());
        assertEq(nft.ownerOf(nextToken), address(escrow));
        assertEq(feeSink.totalSpent(), 0.002 ether);
    }

    // ---- price band boundaries ----

    function test_oneWeiAboveTheCeilingIsNeverBoughtWhateverTheBalance() public {
        (uint256 id,) = listNft(seller, CEILING + 1);
        fundSink(1 ether);
        (bool possible,) = feeSink.pendingBuy();
        assertFalse(possible);
        assertFalse(feeSink.tryBuy());
        assertTrue(market.getListing(id).active);
        assertEq(address(feeSink).balance, 1 ether, "fees keep accumulating behind an over-ceiling listing");
        // a listing at the ceiling itself is bought, and the one above it is left behind
        (, uint256 tokenId) = listNft(alice, CEILING);
        assertTrue(feeSink.tryBuy());
        assertEq(nft.ownerOf(tokenId), address(escrow));
        assertEq(feeSink.totalSpent(), CEILING);
        assertTrue(market.getListing(id).active);
        assertFalse(feeSink.tryBuy(), "the over-ceiling listing is still skipped");
    }

    function test_ceilingBindsEvenWhenTheBalanceIsFarLarger() public {
        listNft(seller, 0.5 ether);
        fundSink(10 ether);
        assertFalse(feeSink.tryBuy());
        assertEq(address(feeSink).balance, 10 ether);
        assertEq(feeSink.buyCount(), 0);
    }

    function test_cheapestAtTheFloorIsBoughtAndOneBelowCannotEvenBeListed() public {
        (, uint256 tokenId) = listNft(seller, FLOOR);
        uint256 extra = nft.mint(seller);
        vm.startPrank(seller);
        nft.approve(address(market), extra);
        vm.expectRevert(MockBaazaar.InvalidPrice.selector);
        market.list(extra, FLOOR - 1);
        vm.stopPrank();
        fundSink(THRESHOLD);
        assertTrue(feeSink.tryBuy());
        assertEq(nft.ownerOf(tokenId), address(escrow));
        assertEq(feeSink.totalSpent(), FLOOR);
        assertEq(feeSink.MIN_BUY_PRICE(), market.MIN_LIST_PRICE(), "sink floor and market floor agree");
    }

    /// The threshold is re-checked on every trigger: one 0.01 ETH funds one floor purchase and leaves
    /// 0.009 ETH idle; each further 0.001 ETH of fees funds exactly one more.
    function test_thresholdIsRecheckedOnEveryTriggerSoFloorListingsDrainOneAtATime() public {
        for (uint256 i = 0; i < 12; ++i) {
            listNft(seller, FLOOR);
        }
        fundSink(THRESHOLD);
        assertTrue(feeSink.tryBuy());
        assertFalse(feeSink.tryBuy(), "0.009 ETH left: below the threshold");
        assertEq(address(feeSink).balance, THRESHOLD - FLOOR);
        for (uint256 i = 0; i < 9; ++i) {
            fundSink(FLOOR - 1);
            assertFalse(feeSink.tryBuy(), "one wei short of the threshold");
            fundSink(1);
            assertTrue(feeSink.tryBuy());
        }
        assertEq(feeSink.buyCount(), 10);
        assertEq(feeSink.totalSpent(), 10 * FLOOR);
        assertEq(address(feeSink).balance, THRESHOLD - FLOOR, "the sink always keeps threshold minus one price");
        assertEq(market.activeCount(), 2);
        assertEq(escrow.acquisitionCount(), 10);
    }

    /// The sink buys exactly when it holds at least 0.01 ETH and the cheapest listing is inside the
    /// [0.001, 0.05] ETH band and costs no more than its balance; it then pays exactly the price.
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_buysIffThresholdMetAndAffordable(uint256 funded, uint256 price) public {
        funded = bound(funded, 0, 0.07 ether);
        price = bound(price, FLOOR, 0.06 ether);
        (uint256 id, uint256 tokenId) = listNft(seller, price);
        fundSink(funded);
        bool expected = funded >= THRESHOLD && price <= funded && price <= CEILING;
        (bool possible,) = feeSink.pendingBuy();
        assertEq(possible, expected, "pendingBuy disagrees with the rule");
        assertEq(feeSink.tryBuy(), expected, "tryBuy disagrees with the rule");
        if (expected) {
            assertEq(address(feeSink).balance, funded - price);
            assertEq(address(market).balance, price);
            assertEq(market.proceeds(seller), price);
            assertEq(nft.ownerOf(tokenId), address(escrow));
            assertEq(feeSink.buyCount(), 1);
            assertEq(escrow.openAcquisitionOf(tokenId), 1);
        } else {
            assertEq(address(feeSink).balance, funded);
            assertEq(address(market).balance, 0);
            assertTrue(market.getListing(id).active);
            assertEq(feeSink.buyCount(), 0);
            assertEq(escrow.acquisitionCount(), 0);
        }
        assertEq(feeSink.totalReceived(), funded);
        assertEq(address(feeSink).balance, feeSink.totalReceived() - feeSink.totalSpent());
    }

    // ---- ETH that bypasses receive() ----

    function test_forceFedEthIsSpendableButNotCountedAsReceived() public {
        (, uint256 tokenId) = listNft(seller, 0.015 ether);
        // what a selfdestruct beneficiary or a block reward credit does: balance without receive()
        vm.deal(address(feeSink), 0.02 ether);
        assertEq(address(feeSink).balance, 0.02 ether);
        assertEq(feeSink.totalReceived(), 0, "forced ETH bypasses receive()");
        assertTrue(feeSink.tryBuy(), "forced ETH must not brick the sink");
        assertEq(nft.ownerOf(tokenId), address(escrow));
        assertEq(address(feeSink).balance, 0.005 ether);
        assertEq(feeSink.totalSpent(), 0.015 ether);
    }

    function test_zeroValueTransferIsHarmless() public {
        vm.prank(stranger);
        (bool ok,) = address(feeSink).call{value: 0}("");
        assertTrue(ok);
        assertEq(feeSink.totalReceived(), 0);
    }

    function test_unknownSelectorsAndCalldataWithValueAreRejected() public {
        vm.prank(stranger);
        (bool ok,) = address(feeSink).call{value: 1 ether}(hex"deadbeef");
        assertFalse(ok, "no fallback: ETH with calldata must not be accepted silently");
        assertEq(address(feeSink).balance, 0);
    }

    // ---- hostile or mis-wired siblings ----

    function test_escrowThatReentersTryBuyRevertsTheWholePurchase() public {
        ReentrantEscrow evil = new ReentrantEscrow();
        FeeSink sink = new FeeSink(address(this), address(market), address(evil));
        sink.setHook(address(hook));
        evil.setSink(sink);
        (uint256 id, uint256 tokenId) = listNft(seller, 0.004 ether);
        listNft(seller, 0.005 ether);
        vm.deal(address(sink), 1 ether);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        sink.tryBuy();
        assertEq(address(sink).balance, 1 ether, "no ETH left the sink");
        assertEq(sink.buyCount(), 0);
        assertEq(sink.totalSpent(), 0);
        assertTrue(market.getListing(id).active, "the listing was not consumed");
        assertEq(nft.ownerOf(tokenId), address(market));
        assertEq(market.proceeds(seller), 0);
    }

    function test_escrowThatSwallowsTheReentryStillOnlyBuysOnce() public {
        ReentrantEscrow evil = new ReentrantEscrow();
        evil.setSwallow(true);
        FeeSink sink = new FeeSink(address(this), address(market), address(evil));
        sink.setHook(address(hook));
        evil.setSink(sink);
        listNft(seller, 0.004 ether);
        listNft(seller, 0.005 ether);
        vm.deal(address(sink), 1 ether);

        assertTrue(sink.tryBuy());
        assertEq(evil.blocked(), 1, "nested tryBuy hit the guard");
        assertEq(sink.buyCount(), 1);
        assertEq(address(sink).balance, 1 ether - 0.004 ether);
        assertEq(market.activeCount(), 1);
    }

    function test_unwiredEscrowMakesTheBuyRevertWithoutLosingEth() public {
        FlipEscrow unwired = new FlipEscrow(address(this), address(nft), address(picker));
        FeeSink sink = new FeeSink(address(this), address(market), address(unwired));
        (uint256 id,) = listNft(seller, 0.004 ether);
        vm.deal(address(sink), THRESHOLD);
        vm.expectRevert(FlipEscrow.NotFeeSink.selector);
        sink.tryBuy();
        assertEq(address(sink).balance, THRESHOLD);
        assertTrue(market.getListing(id).active);
    }

    function test_sellerThatRejectsEthCannotBlockThePurchase() public {
        EthRejectingSeller bad = new EthRejectingSeller();
        uint256 tokenId = nft.mint(address(bad));
        bad.list(market, MockGotchiNFTLike(address(nft)), tokenId, 0.004 ether);
        fundSink(THRESHOLD);
        assertTrue(feeSink.tryBuy());
        assertEq(nft.ownerOf(tokenId), address(escrow));
        assertEq(market.proceeds(address(bad)), 0.004 ether);
    }

    // ---- roles ----

    function test_ownershipHandoverMovesTheManualTrigger() public {
        feeSink.transferOwnership(carol);
        vm.prank(carol);
        vm.expectRevert(FeeSink.NotTrigger.selector);
        feeSink.tryBuy(); // pending owner has no power yet
        vm.prank(carol);
        feeSink.acceptOwnership();
        vm.expectRevert(FeeSink.NotTrigger.selector);
        feeSink.tryBuy(); // the old owner lost the trigger
        vm.prank(carol);
        assertFalse(feeSink.tryBuy());
        vm.prank(carol);
        vm.expectRevert(FeeSink.AlreadySet.selector);
        feeSink.setHook(carol); // the new owner cannot repoint the hook
    }

    function test_renouncedOwnerLeavesOnlyTheHookAsTrigger() public {
        feeSink.renounceOwnership();
        listNft(seller, 0.004 ether);
        fundSink(THRESHOLD);
        vm.expectRevert(FeeSink.NotTrigger.selector);
        feeSink.tryBuy();
        vm.prank(address(hook));
        assertTrue(feeSink.tryBuy());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        feeSink.setHook(address(1));
    }

    function test_sinkWithNoHookWiredStillRejectsStrangers() public {
        FeeSink fresh = new FeeSink(carol, address(market), address(escrow));
        assertEq(fresh.hook(), address(0));
        vm.prank(stranger);
        vm.expectRevert(FeeSink.NotTrigger.selector);
        fresh.tryBuy();
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new FeeSink(address(0), address(market), address(escrow));
    }
}

/// @dev An escrow that re-enters FeeSink.tryBuy from requestFlip.
contract ReentrantEscrow is IFlipEscrow {
    FeeSink internal sink;
    bool internal swallow;
    uint256 public blocked;

    function setSink(FeeSink sink_) external {
        sink = sink_;
    }

    function setSwallow(bool value) external {
        swallow = value;
    }

    function requestFlip(uint256) external returns (uint256) {
        if (swallow) {
            try sink.tryBuy() {}
            catch {
                blocked += 1;
            }
        } else {
            sink.tryBuy();
        }
        return 1;
    }
}

contract EthRejectingSeller {
    function list(MockBaazaar market, MockGotchiNFTLike nft, uint256 tokenId, uint256 price) external {
        nft.approve(address(market), tokenId);
        market.list(tokenId, price);
    }
}

interface MockGotchiNFTLike {
    function approve(address to, uint256 tokenId) external;
}
