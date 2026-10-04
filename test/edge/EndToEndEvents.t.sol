// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {GotchiFixture} from "../utils/GotchiFixture.sol";
import {FlipEscrow} from "../../src/FlipEscrow.sol";

/// @notice fees -> buy -> flip, driven only by swaps, with the UI event stream checked as a whole: which
/// events appear, in what order, from which contract, with which indexed fields.
contract EndToEndEventsTest is GotchiFixture {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bytes32 internal constant T_FEES = keccak256("FeesCollected(address,uint256)");
    bytes32 internal constant T_BUY = keccak256("BuyTriggered(uint256,uint256,uint256)");
    bytes32 internal constant T_REQUESTED = keccak256("FlipRequested(uint256,uint256,bytes32)");
    bytes32 internal constant T_RESOLVED = keccak256("FlipResolved(uint256,uint256,bool,address)");
    bytes32 internal constant T_BURNED = keccak256("Burned(uint256,address)");
    bytes32 internal constant T_AIRDROPPED = keccak256("Airdropped(uint256,address,uint256)");
    bytes32 internal constant T_LISTED = keccak256("ListingMocked(uint256,uint256,uint256)");

    Vm.Log[] internal ui;

    function setUp() public override {
        super.setUp();
        giveAndEnroll(alice, 10_000e18);
        giveAndEnroll(bob, 30_000e18);
    }

    function _isUi(bytes32 topic) internal pure returns (bool) {
        return topic == T_FEES || topic == T_BUY || topic == T_REQUESTED || topic == T_RESOLVED || topic == T_BURNED
            || topic == T_AIRDROPPED || topic == T_LISTED;
    }

    /// @dev Keeps only the seven UI events from the recorded logs, in emission order.
    function _collect() internal {
        delete ui;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && _isUi(logs[i].topics[0])) ui.push(logs[i]);
        }
    }

    function _expect(uint256 index, bytes32 topic, address emitter, uint256 topicCount) internal view {
        assertEq(ui[index].topics[0], topic, "unexpected event order");
        assertEq(ui[index].emitter, emitter, "unexpected emitter");
        assertEq(ui[index].topics.length, topicCount, "indexed field count changed");
    }

    function test_sellThatCrossesTheThresholdFundsABuyThatIsAirdropped() public {
        token.transfer(carol, 100_000_000e18);
        vm.recordLogs();

        (uint256 listingId, uint256 tokenId) = listNft(seller, 0.006 ether);
        buyTokens(stranger, 3 ether); // ETH exact-in: 0.009 ETH skimmed in beforeSwap, under the threshold
        uint256 firstFee = address(feeSink).balance;
        assertEq(firstFee, 0.009 ether);
        assertEq(feeSink.buyCount(), 0);
        // token exact-in: the fee comes out of the ETH output in afterSwap and crosses the threshold, so
        // the purchase happens inside this very swap
        sellTokens(carol, 100_000_000e18);
        uint256 secondFee = hook.totalFeesCollected() - firstFee;
        assertGt(secondFee, 0.001 ether);
        assertEq(feeSink.buyCount(), 1);
        assertEq(address(feeSink).balance, firstFee + secondFee - 0.006 ether);

        bytes32 seed = commitAndSteer(1, false);
        vm.prank(stranger);
        escrow.reveal(1, seed);
        address recipient = escrow.getAcquisition(1).recipient;
        assertTrue(recipient == alice || recipient == bob);
        assertEq(nft.ownerOf(tokenId), recipient);

        _collect();
        assertEq(ui.length, 7, "exactly the expected UI events");
        _expect(0, T_LISTED, address(market), 2);
        _expect(1, T_FEES, address(hook), 2);
        _expect(2, T_FEES, address(hook), 2);
        _expect(3, T_BUY, address(feeSink), 2);
        _expect(4, T_REQUESTED, address(escrow), 2);
        _expect(5, T_RESOLVED, address(escrow), 3);
        _expect(6, T_AIRDROPPED, address(escrow), 3);

        // ListingMocked(listingId indexed, tokenId, price)
        assertEq(uint256(ui[0].topics[1]), listingId);
        assertEq(abi.decode(ui[0].data, (uint256)), tokenId);
        // FeesCollected(pool indexed, amountEth)
        assertEq(address(uint160(uint256(ui[1].topics[1]))), address(manager));
        assertEq(abi.decode(ui[1].data, (uint256)), firstFee);
        assertEq(abi.decode(ui[2].data, (uint256)), secondFee);
        // BuyTriggered(listingId indexed, priceEth, tokenId)
        assertEq(uint256(ui[3].topics[1]), listingId);
        (uint256 price, uint256 boughtToken) = abi.decode(ui[3].data, (uint256, uint256));
        assertEq(price, 0.006 ether);
        assertEq(boughtToken, tokenId);
        // FlipRequested(acquisitionId indexed, tokenId, requestId)
        assertEq(uint256(ui[4].topics[1]), 1);
        (uint256 requestedToken, bytes32 requestId) = abi.decode(ui[4].data, (uint256, bytes32));
        assertEq(requestedToken, tokenId);
        assertEq(requestId, keccak256(abi.encode(block.chainid, address(escrow), uint256(1), tokenId)));
        // FlipResolved(acquisitionId indexed, tokenId, burned, recipient indexed)
        assertEq(uint256(ui[5].topics[1]), 1);
        assertEq(address(uint160(uint256(ui[5].topics[2]))), recipient);
        (uint256 resolvedToken, bool burned) = abi.decode(ui[5].data, (uint256, bool));
        assertEq(resolvedToken, tokenId);
        assertFalse(burned);
        // Airdropped(tokenId indexed, recipient indexed, weight)
        assertEq(uint256(ui[6].topics[1]), tokenId);
        assertEq(address(uint160(uint256(ui[6].topics[2]))), recipient);
        assertEq(abi.decode(ui[6].data, (uint256)), recipient == alice ? 10_000e18 : 30_000e18);
    }

    function test_buyPressureFundsABuyThatIsBurned() public {
        vm.recordLogs();
        listNft(seller, 0.02 ether); // dearer, listed first
        (uint256 cheapId, uint256 cheapToken) = listNft(seller, 0.004 ether);
        buyTokens(carol, 4 ether); // 0.012 ETH fee, crosses the threshold, buys the cheapest
        assertEq(nft.ownerOf(cheapToken), address(escrow));

        bytes32 seed = commitAndSteer(1, true);
        escrow.reveal(1, seed);
        assertEq(nft.ownerOf(cheapToken), DEAD);

        _collect();
        assertEq(ui.length, 7);
        _expect(0, T_LISTED, address(market), 2);
        _expect(1, T_LISTED, address(market), 2);
        _expect(2, T_FEES, address(hook), 2);
        _expect(3, T_BUY, address(feeSink), 2);
        _expect(4, T_REQUESTED, address(escrow), 2);
        _expect(5, T_RESOLVED, address(escrow), 3);
        _expect(6, T_BURNED, address(escrow), 3);
        assertEq(uint256(ui[3].topics[1]), cheapId, "the cheapest listing was bought, not the first");
        assertEq(address(uint160(uint256(ui[5].topics[2]))), DEAD);
        (, bool burned) = abi.decode(ui[5].data, (uint256, bool));
        assertTrue(burned);
        assertEq(uint256(ui[6].topics[1]), cheapToken);
        assertEq(address(uint160(uint256(ui[6].topics[2]))), DEAD);
    }

    function test_abandonedFlipEndsInATimeoutBurnWithTheSameEvents() public {
        (, uint256 tokenId) = listNft(seller, 0.004 ether);
        buyTokens(carol, 4 ether);
        escrow.commit(1, keccak256(abi.encode(bytes32("lost seed"))));
        vm.roll(block.number + 203);

        vm.recordLogs();
        vm.prank(stranger);
        escrow.timeoutBurn(1);
        _collect();
        assertEq(ui.length, 2);
        _expect(0, T_RESOLVED, address(escrow), 3);
        _expect(1, T_BURNED, address(escrow), 3);
        assertEq(nft.ownerOf(tokenId), DEAD);
        assertEq(uint8(escrow.getAcquisition(1).status), uint8(FlipEscrow.Status.Resolved));
    }

    function test_noUiEventsBelowTheThresholdExceptFees() public {
        listNft(seller, 0.004 ether);
        vm.recordLogs();
        buyTokens(carol, 1 ether);
        buyTokens(carol, 1 ether);
        buyTokens(carol, 1 ether); // 0.009 ETH in total
        _collect();
        assertEq(ui.length, 3);
        for (uint256 i = 0; i < 3; ++i) {
            _expect(i, T_FEES, address(hook), 2);
        }
        assertEq(escrow.acquisitionCount(), 0);
    }

    function test_airdroppedNftCanBeRelistedBoughtAgainAndThenBurned() public {
        (, uint256 tokenId) = listNft(seller, 0.004 ether);
        buyTokens(carol, 4 ether);
        bytes32 seed = commitAndSteer(1, false);
        escrow.reveal(1, seed);
        address winner = nft.ownerOf(tokenId);

        vm.startPrank(winner);
        nft.approve(address(market), tokenId);
        market.list(tokenId, 0.003 ether);
        vm.stopPrank();
        buyTokens(carol, 1 ether); // sink already holds 0.008 ETH; this swap pushes it over again
        assertEq(feeSink.buyCount(), 2);
        assertEq(escrow.openAcquisitionOf(tokenId), 2);
        assertEq(market.proceeds(winner), 0.003 ether);

        seed = commitAndSteer(2, true);
        escrow.reveal(2, seed);
        assertEq(nft.ownerOf(tokenId), DEAD);
        assertEq(escrow.getAcquisition(1).recipient, winner, "the first resolution's record is untouched");
        assertFalse(escrow.getAcquisition(1).burned);
        assertTrue(escrow.getAcquisition(2).burned);
    }

    function test_weightAtCommitDecidesNotWeightAtReveal() public {
        (, uint256 tokenId) = listNft(seller, 0.004 ether);
        buyTokens(carol, 4 ether);
        // carol becomes by far the largest enrolled holder only after the commit
        bytes32 seed = commitAndSteer(1, false);
        vm.startPrank(carol);
        picker.enroll();
        vm.stopPrank();
        escrow.reveal(1, seed);
        address winner = nft.ownerOf(tokenId);
        assertTrue(winner == alice || winner == bob, "a holder enrolled after the commit cannot win");
    }
}
