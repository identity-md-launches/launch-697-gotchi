// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GotchiFixture} from "./utils/GotchiFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FlipEscrow} from "../src/FlipEscrow.sol";
import {GotchiConfig} from "../src/GotchiConfig.sol";

contract FlipEscrowTest is GotchiFixture {
    event FlipRequested(uint256 indexed acquisitionId, uint256 tokenId, bytes32 requestId);
    event FlipResolved(uint256 indexed acquisitionId, uint256 tokenId, bool burned, address indexed recipient);
    event Burned(uint256 indexed tokenId, address indexed to);
    event Airdropped(uint256 indexed tokenId, address indexed recipient, uint256 weight);
    event FlipTimedOut(uint256 indexed acquisitionId, uint256 tokenId);

    address internal constant DEAD = GotchiConfig.BURN_ADDRESS;

    function setUp() public override {
        super.setUp();
        giveAndEnroll(alice, 1_000e18);
        giveAndEnroll(bob, 3_000e18);
    }

    /// @dev Buys one listing through the real sink so the escrow holds a tracked NFT.
    function _acquire(uint256 price) internal returns (uint256 acquisitionId, uint256 tokenId) {
        (, tokenId) = listNft(seller, price);
        fundSink(GotchiConfig.MIN_BUY_THRESHOLD);
        assertTrue(feeSink.tryBuy());
        acquisitionId = escrow.acquisitionCount();
    }

    // ---- wiring and roles ----

    function test_constructorAndWiring() public view {
        assertEq(escrow.owner(), address(this));
        assertEq(escrow.flipper(), address(this));
        assertEq(escrow.feeSink(), address(feeSink));
        assertEq(address(escrow.NFT()), address(nft));
        assertEq(address(escrow.PICKER()), address(picker));
        assertEq(escrow.FLIP_BURN_BPS(), 5000);
        assertEq(escrow.BURN_ADDRESS(), DEAD);
        assertEq(escrow.BURN_THRESHOLD(), 5000 << 128);
    }

    function test_burnsForIsAnExactHalfSplit() public view {
        assertTrue(escrow.burnsFor(0));
        assertTrue(escrow.burnsFor((1 << 255) - 1));
        assertFalse(escrow.burnsFor(1 << 255));
        assertFalse(escrow.burnsFor(type(uint256).max));
    }

    function testFuzz_burnsForMatchesTopBit(uint256 word) public view {
        assertEq(escrow.burnsFor(word), word >> 255 == 0);
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(FlipEscrow.ZeroAddress.selector);
        new FlipEscrow(address(this), address(0), address(picker));
        vm.expectRevert(FlipEscrow.ZeroAddress.selector);
        new FlipEscrow(address(this), address(nft), address(0));
    }

    function test_setFeeSinkOwnerOnlyOneShot() public {
        FlipEscrow fresh = new FlipEscrow(address(this), address(nft), address(picker));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fresh.setFeeSink(address(feeSink));
        vm.expectRevert(FlipEscrow.ZeroAddress.selector);
        fresh.setFeeSink(address(0));
        fresh.setFeeSink(address(feeSink));
        vm.expectRevert(FlipEscrow.AlreadySet.selector);
        fresh.setFeeSink(address(feeSink));
    }

    function test_setFlipper() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        escrow.setFlipper(stranger);
        vm.expectRevert(FlipEscrow.ZeroAddress.selector);
        escrow.setFlipper(address(0));
        escrow.setFlipper(carol);
        assertEq(escrow.flipper(), carol);
        vm.expectRevert(FlipEscrow.NotFlipper.selector);
        escrow.commit(1, bytes32(uint256(1)));
    }

    // ---- requestFlip ----

    function test_requestFlipOnlyFromSinkAndOnlyForHeldTokens() public {
        uint256 tokenId = nft.mint(address(escrow));
        vm.expectRevert(FlipEscrow.NotFeeSink.selector);
        escrow.requestFlip(tokenId);

        uint256 elsewhere = nft.mint(alice);
        vm.prank(address(feeSink));
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.NotEscrowed.selector, elsewhere));
        escrow.requestFlip(elsewhere);

        bytes32 requestId = keccak256(abi.encode(block.chainid, address(escrow), 1, tokenId));
        vm.prank(address(feeSink));
        vm.expectEmit(true, false, false, true, address(escrow));
        emit FlipRequested(1, tokenId, requestId);
        uint256 id = escrow.requestFlip(tokenId);
        assertEq(id, 1);
        FlipEscrow.Acquisition memory a = escrow.getAcquisition(id);
        assertEq(a.tokenId, tokenId);
        assertEq(a.requestId, requestId);
        assertEq(uint8(a.status), uint8(FlipEscrow.Status.Pending));
        assertEq(a.requestBlock, block.number);

        vm.prank(address(feeSink));
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.AlreadyTracked.selector, tokenId));
        escrow.requestFlip(tokenId);
    }

    // ---- commit ----

    function test_commitTakesSnapshotAndRecordsBlock() public {
        (uint256 id,) = _acquire(0.002 ether);
        bytes32 commitment = escrow.commitmentFor(bytes32("s"));
        vm.expectRevert(FlipEscrow.EmptyCommitment.selector);
        escrow.commit(id, bytes32(0));
        escrow.commit(id, commitment);
        FlipEscrow.Acquisition memory a = escrow.getAcquisition(id);
        assertEq(uint8(a.status), uint8(FlipEscrow.Status.Committed));
        assertEq(a.commitment, commitment);
        assertEq(a.commitBlock, block.number);
        assertEq(a.snapshotId, 1);
        assertEq(picker.snapshotInfo(1).totalWeight, 4_000e18);

        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.WrongStatus.selector, id, FlipEscrow.Status.Committed));
        escrow.commit(id, commitment);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.WrongStatus.selector, 99, FlipEscrow.Status.None));
        escrow.commit(99, commitment);
    }

    // ---- reveal: timing and seed checks ----

    function test_revealTooEarlyWrongSeedTooLate() public {
        (uint256 id,) = _acquire(0.002 ether);
        bytes32 seed = bytes32("secret");
        escrow.commit(id, escrow.commitmentFor(seed));
        uint256 commitBlock = block.number;

        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.RevealTooEarly.selector, id, commitBlock + 2));
        escrow.reveal(id, seed);

        vm.roll(commitBlock + 2);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.WrongSeed.selector, id));
        escrow.reveal(id, bytes32("wrong"));

        vm.roll(commitBlock + 2 + 200 + 1);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.RevealTooLate.selector, id, commitBlock + 202));
        escrow.reveal(id, seed);

        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.WrongStatus.selector, 99, FlipEscrow.Status.None));
        escrow.reveal(99, seed);
    }

    function test_revealNeedsEntropy() public {
        (uint256 id,) = _acquire(0.002 ether);
        bytes32 seed = bytes32("secret");
        escrow.commit(id, escrow.commitmentFor(seed));
        uint256 commitBlock = block.number;
        vm.roll(commitBlock + 2);
        vm.setBlockhash(commitBlock + 1, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.EntropyUnavailable.selector, id));
        escrow.reveal(id, seed);
    }

    // ---- forced outcomes ----

    function test_forcedBurnPath() public {
        (uint256 id, uint256 tokenId) = _acquire(0.002 ether);
        bytes32 seed = commitAndSteer(id, true);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipResolved(id, tokenId, true, DEAD);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit Burned(tokenId, DEAD);
        vm.prank(stranger); // anyone who knows the seed may reveal
        escrow.reveal(id, seed);

        assertEq(nft.ownerOf(tokenId), DEAD);
        FlipEscrow.Acquisition memory a = escrow.getAcquisition(id);
        assertTrue(a.burned);
        assertEq(a.recipient, DEAD);
        assertEq(uint8(a.status), uint8(FlipEscrow.Status.Resolved));
        assertEq(escrow.openAcquisitionOf(tokenId), 0);

        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.WrongStatus.selector, id, FlipEscrow.Status.Resolved));
        escrow.reveal(id, seed);
    }

    function test_forcedAirdropPath() public {
        (uint256 id, uint256 tokenId) = _acquire(0.002 ether);
        bytes32 seed = commitAndSteer(id, false);

        vm.recordLogs();
        escrow.reveal(id, seed);

        FlipEscrow.Acquisition memory a = escrow.getAcquisition(id);
        assertFalse(a.burned);
        assertTrue(a.recipient == alice || a.recipient == bob, "recipient is an enrolled holder");
        assertEq(nft.ownerOf(tokenId), a.recipient);
        assertEq(uint8(a.status), uint8(FlipEscrow.Status.Resolved));

        // the Airdropped event carries the winner's frozen weight
        uint256 expectedWeight = a.recipient == alice ? 1_000e18 : 3_000e18;
        bool sawAirdrop = false;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == Airdropped.selector) {
                assertEq(uint256(logs[i].topics[1]), tokenId);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), a.recipient);
                assertEq(abi.decode(logs[i].data, (uint256)), expectedWeight);
                sawAirdrop = true;
            }
        }
        assertTrue(sawAirdrop);
    }

    function test_airdropFallsBackToBurnWithoutEligibleHolders() public {
        // both holders dump before the commit: the snapshot is empty
        vm.prank(alice);
        token.transfer(address(this), 1_000e18);
        vm.prank(bob);
        token.transfer(address(this), 3_000e18);
        (uint256 id, uint256 tokenId) = _acquire(0.002 ether);
        bytes32 seed = commitAndSteer(id, false);
        escrow.reveal(id, seed);
        assertTrue(escrow.getAcquisition(id).burned);
        assertEq(nft.ownerOf(tokenId), DEAD);
    }

    function test_snapshotAtCommitIgnoresLaterBalanceMoves() public {
        (uint256 id, uint256 tokenId) = _acquire(0.002 ether);
        bytes32 seed = commitAndSteer(id, false);
        // after the commit carol buys a huge stake and enrols: too late for this flip
        token.transfer(carol, 400_000_000e18);
        vm.prank(carol);
        picker.enroll();
        escrow.reveal(id, seed);
        address recipient = escrow.getAcquisition(id).recipient;
        assertTrue(recipient == alice || recipient == bob);
        assertEq(nft.ownerOf(tokenId), recipient);
    }

    function test_randomnessIsCommitBound() public {
        // the same seed on two different acquisitions does not force the same branch
        (uint256 id1,) = _acquire(0.002 ether);
        (uint256 id2,) = _acquire(0.002 ether);
        bytes32 seed1 = commitAndSteer(id1, true);
        bytes32 seed2 = commitAndSteer(id2, false);
        escrow.reveal(id1, seed1);
        escrow.reveal(id2, seed2);
        assertTrue(escrow.getAcquisition(id1).burned);
        assertFalse(escrow.getAcquisition(id2).burned);
    }

    function test_buyingAroundTheCommitBuysNoOdds() public {
        // alice (1,000) and bob (3,000) enrolled long ago. bob buys a huge stake right before the commit.
        (uint256 id,) = _acquire(0.002 ether);
        token.transfer(bob, 250_000_000e18);
        escrow.commit(id, escrow.commitmentFor(bytes32("s")));
        uint256 snapshotId = escrow.getAcquisition(id).snapshotId;
        assertEq(picker.snapshotInfo(snapshotId).totalWeight, 4_000e18, "bob still weighs his recorded 3,000");

        // refreshing records the new balance, but it only counts for purchases a maturity period later
        vm.prank(bob);
        picker.refresh();
        (uint256 id2,) = _acquire(0.002 ether);
        escrow.commit(id2, escrow.commitmentFor(bytes32("t")));
        uint256 snapshot2 = escrow.getAcquisition(id2).snapshotId;
        assertEq(picker.snapshotInfo(snapshot2).totalWeight, 1_000e18, "bob's raised weight is not mature");
        assertEq(picker.snapshotInfo(snapshot2).entryCount, 1);
    }

    function test_holderEnrolledAfterThePurchaseCarriesNoWeightInItsFlip() public {
        (uint256 id,) = _acquire(0.002 ether);
        token.transfer(carol, 400_000_000e18);
        vm.prank(carol);
        picker.enroll();
        vm.roll(block.number + picker.ENROLL_MATURITY_BLOCKS());
        escrow.commit(id, escrow.commitmentFor(bytes32("s")));
        uint256 snapshotId = escrow.getAcquisition(id).snapshotId;
        assertEq(picker.snapshotInfo(snapshotId).totalWeight, 4_000e18, "only weight recorded before the purchase");
    }

    // ---- timeouts ----

    function test_timeoutBurnWhenNeverCommitted() public {
        (uint256 id, uint256 tokenId) = _acquire(0.002 ether);
        uint256 requestBlock = block.number;
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.NotTimedOut.selector, id));
        escrow.timeoutBurn(id);
        vm.roll(requestBlock + 7200);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.NotTimedOut.selector, id));
        escrow.timeoutBurn(id);

        vm.roll(requestBlock + 7201);
        vm.prank(stranger);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit FlipTimedOut(id, tokenId);
        escrow.timeoutBurn(id);
        assertEq(nft.ownerOf(tokenId), DEAD);
        assertTrue(escrow.getAcquisition(id).burned);
    }

    function test_timeoutBurnWhenRevealMissed() public {
        (uint256 id, uint256 tokenId) = _acquire(0.002 ether);
        bytes32 seed = bytes32("s");
        escrow.commit(id, escrow.commitmentFor(seed));
        uint256 commitBlock = block.number;
        vm.roll(commitBlock + 202);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.NotTimedOut.selector, id));
        escrow.timeoutBurn(id);
        vm.roll(commitBlock + 203);
        vm.prank(stranger);
        escrow.timeoutBurn(id);
        assertEq(nft.ownerOf(tokenId), DEAD);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.WrongStatus.selector, id, FlipEscrow.Status.Resolved));
        escrow.timeoutBurn(id);
    }

    function test_resolvedTokenCanBeAcquiredAgain() public {
        (uint256 id, uint256 tokenId) = _acquire(0.002 ether);
        bytes32 seed = commitAndSteer(id, false);
        escrow.reveal(id, seed);
        address winner = escrow.getAcquisition(id).recipient;
        // the winner relists it, the sink buys it again: a fresh acquisition is opened
        vm.startPrank(winner);
        nft.approve(address(market), tokenId);
        market.list(tokenId, 0.002 ether);
        vm.stopPrank();
        fundSink(GotchiConfig.MIN_BUY_THRESHOLD);
        assertTrue(feeSink.tryBuy());
        assertEq(escrow.openAcquisitionOf(tokenId), 2);
    }
}
