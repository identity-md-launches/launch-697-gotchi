// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GotchiFixture} from "../utils/GotchiFixture.sol";
import {FlipEscrow} from "../../src/FlipEscrow.sol";

/// @notice Boundary blocks, wrong-state calls and role edges of FlipEscrow that the happy-path suite
/// does not reach.
contract FlipEscrowEdgeTest is GotchiFixture {
    event FlipResolved(uint256 indexed acquisitionId, uint256 tokenId, bool burned, address indexed recipient);
    event Burned(uint256 indexed tokenId, address indexed to);
    event Airdropped(uint256 indexed tokenId, address indexed recipient, uint256 weight);

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public override {
        super.setUp();
        giveAndEnroll(alice, 1_000e18);
        giveAndEnroll(bob, 3_000e18);
    }

    function _acquire() internal returns (uint256 id, uint256 tokenId) {
        (, tokenId) = listNft(seller, 0.002 ether);
        fundSink(0.01 ether);
        assertTrue(feeSink.tryBuy());
        id = escrow.acquisitionCount();
    }

    function _commit(uint256 id, bytes32 seed) internal returns (uint256 commitBlock) {
        escrow.commit(id, keccak256(abi.encode(seed)));
        commitBlock = block.number;
    }

    // ---- reveal window boundaries ----

    function test_revealOneBlockBeforeTheDelayReverts() public {
        (uint256 id,) = _acquire();
        uint256 commitBlock = _commit(id, "s");
        vm.roll(commitBlock + 1);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.RevealTooEarly.selector, id, commitBlock + 2));
        escrow.reveal(id, "s");
    }

    function test_revealAtTheFirstAllowedBlockSucceeds() public {
        (uint256 id,) = _acquire();
        uint256 commitBlock = _commit(id, "s");
        vm.roll(commitBlock + 2);
        vm.setBlockhash(commitBlock + 1, keccak256("h"));
        escrow.reveal(id, "s");
        assertEq(uint8(escrow.getAcquisition(id).status), uint8(FlipEscrow.Status.Resolved));
    }

    function test_revealAtTheLastAllowedBlockSucceedsAndTimeoutIsStillRefused() public {
        (uint256 id,) = _acquire();
        uint256 commitBlock = _commit(id, "s");
        vm.roll(commitBlock + 202);
        vm.setBlockhash(commitBlock + 1, keccak256("h"));
        // reveal and timeout windows must not overlap: at the last reveal block the timeout is refused
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.NotTimedOut.selector, id));
        escrow.timeoutBurn(id);
        escrow.reveal(id, "s");
        assertEq(uint8(escrow.getAcquisition(id).status), uint8(FlipEscrow.Status.Resolved));
    }

    function test_oneBlockAfterTheWindowOnlyTimeoutWorks() public {
        (uint256 id, uint256 tokenId) = _acquire();
        uint256 commitBlock = _commit(id, "s");
        vm.roll(commitBlock + 203);
        vm.setBlockhash(commitBlock + 1, keccak256("h"));
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.RevealTooLate.selector, id, commitBlock + 202));
        escrow.reveal(id, "s");
        vm.prank(stranger);
        escrow.timeoutBurn(id);
        assertEq(nft.ownerOf(tokenId), DEAD);
    }

    function test_commitTimeoutBoundary() public {
        (uint256 id, uint256 tokenId) = _acquire();
        uint256 requestBlock = block.number;
        vm.roll(requestBlock + 7200);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.NotTimedOut.selector, id));
        escrow.timeoutBurn(id);
        vm.roll(requestBlock + 7201);
        vm.prank(stranger);
        escrow.timeoutBurn(id);
        assertEq(nft.ownerOf(tokenId), DEAD);
        assertTrue(escrow.getAcquisition(id).burned);
    }

    // ---- wrong state ----

    function test_resolvedFlipCannotBeTouchedAgain() public {
        (uint256 id,) = _acquire();
        bytes32 seed = commitAndSteer(id, true);
        escrow.reveal(id, seed);
        bytes memory wrong = abi.encodeWithSelector(FlipEscrow.WrongStatus.selector, id, FlipEscrow.Status.Resolved);
        vm.expectRevert(wrong);
        escrow.reveal(id, seed);
        vm.expectRevert(wrong);
        escrow.commit(id, keccak256("again"));
        vm.roll(block.number + 10_000);
        vm.expectRevert(wrong);
        escrow.timeoutBurn(id);
    }

    function test_timedOutFlipCannotBeRevealedOrTimedOutTwice() public {
        (uint256 id,) = _acquire();
        uint256 commitBlock = _commit(id, "s");
        vm.roll(commitBlock + 203);
        escrow.timeoutBurn(id);
        bytes memory wrong = abi.encodeWithSelector(FlipEscrow.WrongStatus.selector, id, FlipEscrow.Status.Resolved);
        vm.expectRevert(wrong);
        escrow.timeoutBurn(id);
        vm.expectRevert(wrong);
        escrow.reveal(id, "s");
    }

    function test_unknownIdsAreRejectedEverywhere() public {
        _acquire();
        uint256[3] memory ids = [uint256(0), 2, type(uint256).max];
        for (uint256 i = 0; i < ids.length; ++i) {
            bytes memory wrong = abi.encodeWithSelector(FlipEscrow.WrongStatus.selector, ids[i], FlipEscrow.Status.None);
            vm.expectRevert(wrong);
            escrow.commit(ids[i], keccak256("c"));
            vm.expectRevert(wrong);
            escrow.reveal(ids[i], "s");
            vm.expectRevert(wrong);
            escrow.timeoutBurn(ids[i]);
        }
    }

    function test_revealBeforeCommitReverts() public {
        (uint256 id,) = _acquire();
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.WrongStatus.selector, id, FlipEscrow.Status.Pending));
        escrow.reveal(id, "s");
    }

    function test_wrongSeedDoesNotConsumeTheFlip() public {
        (uint256 id, uint256 tokenId) = _acquire();
        uint256 commitBlock = _commit(id, "s");
        vm.roll(commitBlock + 2);
        vm.setBlockhash(commitBlock + 1, keccak256("h"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.WrongSeed.selector, id));
        escrow.reveal(id, bytes32(0));
        assertEq(nft.ownerOf(tokenId), address(escrow));
        escrow.reveal(id, "s");
    }

    // ---- roles ----

    function test_strangerWhoKnowsTheSeedMayReveal() public {
        (uint256 id,) = _acquire();
        bytes32 seed = commitAndSteer(id, true);
        vm.prank(stranger);
        escrow.reveal(id, seed);
        assertTrue(escrow.getAcquisition(id).burned);
    }

    function test_rotatedFlipperReplacesTheOldOne() public {
        (uint256 id,) = _acquire();
        escrow.setFlipper(carol);
        vm.expectRevert(FlipEscrow.NotFlipper.selector);
        escrow.commit(id, keccak256("c")); // the owner is no longer the flipper
        vm.prank(carol);
        escrow.commit(id, keccak256("c"));
        assertEq(uint8(escrow.getAcquisition(id).status), uint8(FlipEscrow.Status.Committed));
    }

    function test_ownershipHandoverIsTwoStepAndDoesNotMoveTheFlipperRole() public {
        escrow.transferOwnership(carol);
        assertEq(escrow.owner(), address(this), "pending owner has no power yet");
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        escrow.setFlipper(carol);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        escrow.acceptOwnership();
        vm.prank(carol);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), carol);
        assertEq(escrow.flipper(), address(this), "flipper is a separate role");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        escrow.setFlipper(address(this));
    }

    function test_escrowRejectsPlainEth() public {
        vm.prank(stranger);
        (bool ok,) = address(escrow).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(escrow).balance, 0);
    }

    function test_donatedNftIsNotAnAcquisition() public {
        uint256 tokenId = nft.mint(stranger);
        vm.prank(stranger);
        nft.transferFrom(stranger, address(escrow), tokenId);
        assertEq(escrow.acquisitionCount(), 0);
        assertEq(escrow.openAcquisitionOf(tokenId), 0);
        vm.prank(stranger);
        vm.expectRevert(FlipEscrow.NotFeeSink.selector);
        escrow.requestFlip(tokenId);
    }

    // ---- outcomes ----

    /// The outcome of a reveal is a pure function of (seed, entropy block hash, id, token): the burn branch
    /// is the lower half of the word and the airdrop recipient is the picker's choice for that word.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_revealOutcomeFollowsTheRandomWord(bytes32 seed, bytes32 entropy) public {
        if (entropy == bytes32(0)) entropy = bytes32(uint256(1)); // a zero hash means "unavailable"
        (uint256 id, uint256 tokenId) = _acquire();
        uint256 commitBlock = _commit(id, seed);
        vm.roll(commitBlock + 2);
        vm.setBlockhash(commitBlock + 1, entropy);
        uint256 word = uint256(keccak256(abi.encode(seed, entropy, id, tokenId)));
        bool expectBurn = word < (1 << 255);
        address expectRecipient = DEAD;
        uint256 weight = 0;
        if (!expectBurn) {
            // alice holds 1,000 and bob 3,000 (enrolled in that order): alice owns [0, 1000e18)
            expectRecipient = word % 4_000e18 < 1_000e18 ? alice : bob;
            weight = expectRecipient == alice ? 1_000e18 : 3_000e18;
        }
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipResolved(id, tokenId, expectBurn, expectRecipient);
        if (expectBurn) {
            vm.expectEmit(true, true, false, true, address(escrow));
            emit Burned(tokenId, DEAD);
        } else {
            vm.expectEmit(true, true, false, true, address(escrow));
            emit Airdropped(tokenId, expectRecipient, weight);
        }
        escrow.reveal(id, seed);
        assertEq(nft.ownerOf(tokenId), expectRecipient);
        FlipEscrow.Acquisition memory a = escrow.getAcquisition(id);
        assertEq(a.burned, expectBurn);
        assertEq(a.recipient, expectRecipient);
    }

    /// Over many independent flips both branches occur at roughly even odds (FLIP_BURN_BPS = 5000).
    function test_bothBranchesOccurAtRoughlyEvenOdds() public {
        uint256 burns = 0;
        uint256 flips = 120;
        for (uint256 i = 0; i < flips; ++i) {
            (uint256 id,) = _acquire();
            bytes32 seed = keccak256(abi.encode("seed", i));
            uint256 commitBlock = _commit(id, seed);
            vm.roll(commitBlock + 2);
            vm.setBlockhash(commitBlock + 1, keccak256(abi.encode("hash", i)));
            escrow.reveal(id, seed);
            if (escrow.getAcquisition(id).burned) burns += 1;
        }
        // 120 fair flips: [36, 84] is beyond 4 standard deviations either side
        assertGt(burns, 36, "burn branch starved");
        assertLt(burns, 84, "airdrop branch starved");
    }

    function test_airdropToAContractThatCannotReceiveErc721StillResolves() public {
        NoReceiver winner = new NoReceiver();
        token.transfer(address(winner), 500_000_000e18 - 4_000e18);
        winner.enroll(HolderWeightedPickerLike(address(picker)));
        (uint256 id, uint256 tokenId) = _acquire();
        bytes32 seed = commitAndSteer(id, false);
        escrow.reveal(id, seed);
        address recipient = escrow.getAcquisition(id).recipient;
        assertEq(nft.ownerOf(tokenId), recipient, "a non-receiver winner cannot block the flip");
        assertFalse(escrow.getAcquisition(id).burned);
    }

    function test_holderWhoEmptiedTheirWalletBeforeCommitIsNotPicked() public {
        vm.prank(bob);
        token.transfer(carol, 3_000e18); // bob stays enrolled with a zero balance
        (uint256 id, uint256 tokenId) = _acquire();
        bytes32 seed = commitAndSteer(id, false);
        escrow.reveal(id, seed);
        assertEq(nft.ownerOf(tokenId), alice, "only alice carries weight");
    }

    function test_sameTokenCannotBeTrackedTwiceWhileOpen() public {
        (, uint256 tokenId) = _acquire();
        vm.prank(address(feeSink));
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.AlreadyTracked.selector, tokenId));
        escrow.requestFlip(tokenId);
        assertEq(escrow.acquisitionCount(), 1);
    }

    // ---- maturity on the purchase path ----

    /// A holder whose weight was recorded exactly ENROLL_MATURITY_BLOCKS before the purchase block counts
    /// in that purchase's flip; one block later does not. The commit block is irrelevant.
    function test_maturityIsMeasuredAgainstThePurchaseBlockNotTheCommitBlock() public {
        token.transfer(carol, 1_000_000e18);
        vm.prank(carol);
        picker.enroll();
        uint256 enrolBlock = block.number;
        uint256 maturity = picker.ENROLL_MATURITY_BLOCKS();

        vm.roll(enrolBlock + maturity - 1);
        (uint256 early,) = _acquire(); // purchased one block short of carol's maturity
        vm.roll(enrolBlock + maturity);
        (uint256 onTime,) = _acquire(); // purchased exactly at maturity

        vm.roll(block.number + 10_000); // committing much later changes nothing
        escrow.commit(early, keccak256("e"));
        escrow.commit(onTime, keccak256("o"));
        uint256 earlySnap = escrow.getAcquisition(early).snapshotId;
        uint256 onTimeSnap = escrow.getAcquisition(onTime).snapshotId;
        assertEq(picker.snapshotInfo(earlySnap).totalWeight, 4_000e18, "only alice and bob count");
        assertEq(picker.snapshotInfo(earlySnap).entryCount, 2);
        assertEq(picker.snapshotInfo(onTimeSnap).totalWeight, 1_004_000e18, "carol counts at maturity");
        assertEq(picker.snapshotInfo(onTimeSnap).entryCount, 3);
        (address w,) = picker.pick(onTimeSnap, 4_000e18); // first unit past alice and bob
        assertEq(w, carol);
    }

    /// When every enrolled holder is immature (or empty) at the purchase block the airdrop branch has
    /// nobody to pay and the flip burns, with the burn events and a burn-address recipient.
    function test_airdropCoinWithOnlyImmatureHoldersBurns() public {
        vm.prank(alice);
        token.transfer(address(this), 1_000e18);
        vm.prank(bob);
        token.transfer(address(this), 3_000e18); // the mature holders now carry no weight
        token.transfer(carol, 5_000_000e18);
        vm.prank(carol);
        picker.enroll(); // immature: enrolled in the purchase block
        (uint256 id, uint256 tokenId) = _acquire();
        bytes32 seed = commitAndSteer(id, false); // the coin says airdrop
        assertEq(picker.snapshotInfo(escrow.getAcquisition(id).snapshotId).entryCount, 0);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipResolved(id, tokenId, true, DEAD);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit Burned(tokenId, DEAD);
        escrow.reveal(id, seed);
        assertEq(nft.ownerOf(tokenId), DEAD);
        assertTrue(escrow.getAcquisition(id).burned);
        assertEq(escrow.getAcquisition(id).recipient, DEAD);
    }

    /// Selling after the commit does not change the outcome; selling before it removes the weight even
    /// though the recorded weight is untouched.
    function test_sellingBeforeTheCommitRemovesWeightSellingAfterDoesNot() public {
        (uint256 first,) = _acquire();
        vm.prank(bob);
        token.transfer(carol, 3_000e18); // bob leaves before the commit
        bytes32 seed = commitAndSteer(first, false);
        (uint256 w,) = picker.registrationOf(bob);
        assertEq(w, 3_000e18, "recorded weight is stale but harmless");
        assertEq(picker.snapshotInfo(escrow.getAcquisition(first).snapshotId).totalWeight, 1_000e18);
        escrow.reveal(first, seed);
        assertEq(escrow.getAcquisition(first).recipient, alice);

        vm.prank(carol);
        token.transfer(bob, 3_000e18);
        vm.roll(block.number + picker.ENROLL_MATURITY_BLOCKS());
        (uint256 second,) = _acquire();
        seed = commitAndSteer(second, false);
        vm.prank(bob);
        token.transfer(carol, 3_000e18); // bob leaves after the commit: frozen table still names him
        assertEq(picker.snapshotInfo(escrow.getAcquisition(second).snapshotId).totalWeight, 4_000e18);
        escrow.reveal(second, seed);
        address recipient = escrow.getAcquisition(second).recipient;
        assertTrue(recipient == alice || recipient == bob);
    }

    function test_requestIdBindsChainEscrowAcquisitionAndToken() public {
        vm.recordLogs();
        (uint256 id, uint256 tokenId) = _acquire();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 expected = keccak256(abi.encode(block.chainid, address(escrow), id, tokenId));
        bool seen = false;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("FlipRequested(uint256,uint256,bytes32)")) {
                (uint256 loggedToken, bytes32 requestId) = abi.decode(logs[i].data, (uint256, bytes32));
                assertEq(logs[i].emitter, address(escrow));
                assertEq(uint256(logs[i].topics[1]), id);
                assertEq(loggedToken, tokenId);
                assertEq(requestId, expected);
                seen = true;
            }
        }
        assertTrue(seen, "FlipRequested not emitted");
        assertEq(escrow.getAcquisition(id).requestId, expected);
    }
}

contract NoReceiver {
    function enroll(HolderWeightedPickerLike picker) external {
        picker.enroll();
    }
}

interface HolderWeightedPickerLike {
    function enroll() external;
}
