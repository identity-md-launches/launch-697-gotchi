// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GotchiFixture} from "./utils/GotchiFixture.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FeeSink} from "../src/FeeSink.sol";
import {FlipEscrow} from "../src/FlipEscrow.sol";
import {MockGotchiNFT} from "../src/MockGotchiNFT.sol";
import {IMockBaazaar} from "../src/interfaces/IMockBaazaar.sol";
import {GotchiConfig} from "../src/GotchiConfig.sol";

contract FeeSinkTest is GotchiFixture {
    event BuyTriggered(uint256 indexed listingId, uint256 priceEth, uint256 tokenId);
    event FeeReceived(address indexed from, uint256 amount);

    uint256 internal constant THRESHOLD = GotchiConfig.MIN_BUY_THRESHOLD;

    function test_constructorRejectsZero() public {
        vm.expectRevert(FeeSink.ZeroAddress.selector);
        new FeeSink(address(this), address(0), address(escrow));
        vm.expectRevert(FeeSink.ZeroAddress.selector);
        new FeeSink(address(this), address(market), address(0));
    }

    function test_wiringAndRoles() public view {
        assertEq(feeSink.owner(), address(this));
        assertEq(feeSink.hook(), address(hook));
        assertEq(address(feeSink.MARKET()), address(market));
        assertEq(address(feeSink.ESCROW()), address(escrow));
        assertEq(feeSink.MIN_BUY_THRESHOLD(), 0.01 ether);
    }

    function test_setHookIsOwnerOnlyAndOneShot() public {
        FeeSink fresh = new FeeSink(address(this), address(market), address(escrow));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fresh.setHook(address(hook));
        vm.expectRevert(FeeSink.ZeroAddress.selector);
        fresh.setHook(address(0));
        fresh.setHook(address(hook));
        vm.expectRevert(FeeSink.AlreadySet.selector);
        fresh.setHook(address(hook));
    }

    function test_receiveAccountsAndEmits() public {
        vm.expectEmit(true, false, false, true, address(feeSink));
        emit FeeReceived(stranger, 1 ether);
        fundSink(1 ether);
        assertEq(feeSink.totalReceived(), 1 ether);
        assertEq(address(feeSink).balance, 1 ether);
    }

    function test_tryBuyIsHookOrOwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(FeeSink.NotTrigger.selector);
        feeSink.tryBuy();
        // owner (this) and hook both allowed; nothing to buy so both return false
        assertFalse(feeSink.tryBuy());
        vm.prank(address(hook));
        assertFalse(feeSink.tryBuy());
    }

    function test_noBuyBelowThreshold() public {
        listNft(seller, 0.001 ether);
        fundSink(THRESHOLD - 1);
        assertFalse(feeSink.tryBuy());
        assertEq(feeSink.buyCount(), 0);
        assertEq(address(feeSink).balance, THRESHOLD - 1);
        assertEq(market.activeCount(), 1);
        (bool possible,) = feeSink.pendingBuy();
        assertFalse(possible);
    }

    function test_noBuyWithoutListing() public {
        fundSink(1 ether);
        assertFalse(feeSink.tryBuy());
        assertEq(address(feeSink).balance, 1 ether);
    }

    function test_noBuyWhenCheapestCostsMoreThanBalance() public {
        listNft(seller, 0.05 ether);
        fundSink(0.02 ether);
        assertFalse(feeSink.tryBuy());
        assertEq(address(feeSink).balance, 0.02 ether);
        assertEq(market.activeCount(), 1);
    }

    function test_buysCheapestAtThresholdAndForwardsToEscrow() public {
        (uint256 expensiveId,) = listNft(seller, 0.009 ether);
        (uint256 cheapId, uint256 cheapToken) = listNft(seller, 0.004 ether);
        fundSink(THRESHOLD);
        (bool possible, IMockBaazaar.Listing memory target) = feeSink.pendingBuy();
        assertTrue(possible);
        assertEq(target.listingId, cheapId);

        vm.expectEmit(true, false, false, true, address(feeSink));
        emit BuyTriggered(cheapId, 0.004 ether, cheapToken);
        assertTrue(feeSink.tryBuy());

        assertEq(feeSink.buyCount(), 1);
        assertEq(feeSink.totalSpent(), 0.004 ether);
        assertEq(address(feeSink).balance, THRESHOLD - 0.004 ether);
        assertEq(nft.ownerOf(cheapToken), address(escrow));
        assertEq(market.proceeds(seller), 0.004 ether);
        assertEq(escrow.acquisitionCount(), 1);
        assertEq(escrow.openAcquisitionOf(cheapToken), 1);
        assertTrue(market.getListing(expensiveId).active);
        // balance now below threshold: a second call is a no-op
        assertFalse(feeSink.tryBuy());
        assertEq(feeSink.buyCount(), 1);
    }

    function test_repeatedBuysWhileFundsLast() public {
        listNft(seller, 0.003 ether);
        listNft(seller, 0.004 ether);
        listNft(seller, 0.005 ether);
        fundSink(0.03 ether);
        assertTrue(feeSink.tryBuy()); // 0.003 -> 0.027
        assertTrue(feeSink.tryBuy()); // 0.004 -> 0.023
        assertTrue(feeSink.tryBuy()); // 0.005 -> 0.018
        assertFalse(feeSink.tryBuy()); // nothing left to buy
        assertEq(feeSink.buyCount(), 3);
        assertEq(address(feeSink).balance, 0.018 ether);
        assertEq(escrow.acquisitionCount(), 3);
    }

    function test_noWithdrawOrSweepSurface() public {
        fundSink(1 ether);
        string[5] memory signatures =
            ["withdraw()", "withdraw(uint256)", "sweep(address)", "rescueETH(address,uint256)", "setTreasury(address)"];
        for (uint256 i = 0; i < signatures.length; ++i) {
            (bool ok,) = address(feeSink).call(abi.encodeWithSignature(signatures[i], address(this), uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(address(feeSink).balance, 1 ether);
    }

    // ---- reentrancy ----

    function test_reentrantMarketCannotTriggerASecondBuy() public {
        (FeeSink sink, ReentrantMarket evil) = _sinkWithEvilMarket(false);
        uint256 tokenId = evil.prepare(0.004 ether);
        vm.deal(address(sink), THRESHOLD * 10);

        assertTrue(sink.tryBuy());
        assertEq(evil.reentryFailed(), 1, "the nested tryBuy was rejected by the guard");
        assertEq(sink.buyCount(), 1, "exactly one purchase accounted");
        assertEq(sink.totalSpent(), 0.004 ether);
        assertEq(evil.nft().ownerOf(tokenId), address(sink.ESCROW()));
    }

    function test_reentrantMarketThatDoesNotCatchRevertsTheWholeBuy() public {
        (FeeSink sink, ReentrantMarket evil) = _sinkWithEvilMarket(true);
        evil.prepare(0.004 ether);
        vm.deal(address(sink), THRESHOLD * 10);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        sink.tryBuy();
        assertEq(sink.buyCount(), 0);
        assertEq(address(sink).balance, THRESHOLD * 10, "no ETH left the sink");
    }

    function _sinkWithEvilMarket(bool bubble) internal returns (FeeSink sink, ReentrantMarket evil) {
        MockGotchiNFT evilNft = new MockGotchiNFT();
        evil = new ReentrantMarket(evilNft, bubble);
        FlipEscrow evilEscrow = new FlipEscrow(address(this), address(evilNft), address(picker));
        sink = new FeeSink(address(this), address(evil), address(evilEscrow));
        evilEscrow.setFeeSink(address(sink));
        sink.setHook(address(hook));
        evil.setEscrow(address(evilEscrow));
    }
}

/// @dev A marketplace that re-enters FeeSink.tryBuy while being paid.
contract ReentrantMarket is IMockBaazaar {
    MockGotchiNFT public nft;
    bool public bubble;
    uint256 public reentryFailed;
    address public escrow;
    Listing private _listing;

    constructor(MockGotchiNFT nft_, bool bubble_) {
        nft = nft_;
        bubble = bubble_;
    }

    function setEscrow(address escrow_) external {
        escrow = escrow_;
    }

    function prepare(uint256 price) external returns (uint256 tokenId) {
        tokenId = nft.mint(address(this));
        _listing = Listing({listingId: 1, tokenId: tokenId, price: price, seller: msg.sender, active: true});
    }

    function cheapest() external view returns (Listing memory) {
        return _listing;
    }

    function buyCheapest(uint256, address to) external payable returns (uint256 tokenId) {
        if (bubble) {
            FeeSink(payable(msg.sender)).tryBuy();
        } else {
            try FeeSink(payable(msg.sender)).tryBuy() {}
            catch {
                reentryFailed += 1;
            }
        }
        tokenId = _listing.tokenId;
        _listing.active = false;
        nft.transferFrom(address(this), to, tokenId);
    }
}
