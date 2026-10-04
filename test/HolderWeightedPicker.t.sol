// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {HolderWeightedPicker} from "../src/HolderWeightedPicker.sol";
import {GotchiConfig} from "../src/GotchiConfig.sol";

contract HolderWeightedPickerTest is Test {
    LaunchToken internal token;
    HolderWeightedPicker internal picker;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dead = GotchiConfig.BURN_ADDRESS;

    uint256 internal constant MIN = GotchiConfig.MIN_ENROLL_BALANCE;

    event HolderDisplaced(address indexed holder, uint256 weight, address indexed by);
    event HolderRefreshed(address indexed holder, uint256 weight, uint256 sinceBlock);
    event SnapshotTaken(uint256 indexed snapshotId, uint256 blockNumber, uint256 holders, uint256 totalWeight);

    function setUp() public {
        token = new LaunchToken();
        picker = new HolderWeightedPicker(address(token));
    }

    function _enroll(address who, uint256 amount) internal {
        token.transfer(who, amount);
        vm.prank(who);
        picker.enroll();
    }

    // ---- enrolment and exclusions ----

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(HolderWeightedPicker.ZeroAddress.selector);
        new HolderWeightedPicker(address(0));
    }

    function test_enrollRequiresMinimumBalance() public {
        token.transfer(alice, MIN - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.BelowMinimumBalance.selector, MIN - 1, MIN));
        picker.enroll();

        token.transfer(alice, 1);
        vm.prank(alice);
        picker.enroll();
        assertTrue(picker.isEnrolled(alice));
        assertEq(picker.holderCount(), 1);
        assertEq(picker.holderAt(0), alice);
    }

    function test_zeroBalanceCannotEnroll() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.BelowMinimumBalance.selector, 0, MIN));
        picker.enroll();
    }

    function test_burnAddressCannotEnrollEvenWithBalance() public {
        token.transfer(dead, 10 * MIN);
        vm.prank(dead);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.ExcludedAddress.selector, dead));
        picker.enroll();
    }

    function test_doubleEnrollReverts() public {
        _enroll(alice, MIN);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.AlreadyEnrolled.selector, alice));
        picker.enroll();
    }

    function test_fullRegistryRefusesAnEqualBalanceCheaply() public {
        for (uint256 i = 0; i < GotchiConfig.MAX_HOLDERS; ++i) {
            _enroll(address(uint160(0xBEEF00 + i)), MIN);
        }
        token.transfer(alice, MIN);
        vm.prank(alice);
        vm.expectRevert(HolderWeightedPicker.RegistryFull.selector);
        picker.enroll{gas: 60_000}(); // constant cost: no scan on the refused path
    }

    function test_fullRegistryLetsALargerHolderDisplaceTheSmallest() public {
        for (uint256 i = 0; i < GotchiConfig.MAX_HOLDERS; ++i) {
            _enroll(address(uint160(0xBEEF00 + i)), MIN + (i == 77 ? 0 : 5e18));
        }
        address smallest = address(uint160(0xBEEF00 + 77));
        assertEq(picker.lowestHolder(), smallest);

        token.transfer(alice, 100_000_000e18);
        vm.expectEmit(true, true, false, true, address(picker));
        emit HolderDisplaced(smallest, MIN, alice);
        vm.prank(alice);
        picker.enroll();

        assertTrue(picker.isEnrolled(alice));
        assertFalse(picker.isEnrolled(smallest));
        assertEq(picker.holderCount(), GotchiConfig.MAX_HOLDERS);
        assertTrue(picker.lowestHolder() != smallest && picker.lowestHolder() != alice);

        uint256 id = picker.snapshot();
        uint256 total = picker.snapshotInfo(id).totalWeight;
        assertEq(total, 100_000_000e18 + 127 * (MIN + 5e18));
        (address top, uint256 weight) = picker.pick(id, total - 1);
        assertEq(top, alice);
        assertEq(weight, 100_000_000e18);

        // the displaced holder can come back by beating the new smallest weight
        token.transfer(smallest, 10e18);
        vm.prank(smallest);
        picker.enroll();
        assertTrue(picker.isEnrolled(smallest));
    }

    function test_weightIsTheLesserOfRecordedAndLiveBalance() public {
        _enroll(alice, 5 * MIN);
        _enroll(bob, 2 * MIN);
        // alice receives more after enrolling: no extra weight until she refreshes
        token.transfer(alice, 100 * MIN);
        // bob sells half: counts against him at once
        vm.prank(bob);
        token.transfer(carol, MIN);
        assertEq(picker.weightOf(alice, type(uint256).max), 5 * MIN);
        assertEq(picker.weightOf(bob, type(uint256).max), MIN);
        assertEq(picker.weightOf(carol, type(uint256).max), 0, "not enrolled");
        uint256 id = picker.snapshot();
        assertEq(picker.snapshotInfo(id).totalWeight, 6 * MIN);
    }

    function test_refreshRecordsTheBalanceAndRestartsMaturityOnlyWhenRaising() public {
        _enroll(alice, 5 * MIN);
        uint256 enrolledAt = block.number;
        vm.roll(enrolledAt + 10);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NotEnrolled.selector, bob));
        picker.refresh();

        // lowering keeps the original maturity
        vm.prank(alice);
        token.transfer(carol, MIN);
        vm.prank(alice);
        picker.refresh();
        (uint256 weight, uint256 since) = picker.registrationOf(alice);
        assertEq(weight, 4 * MIN);
        assertEq(since, enrolledAt);

        // raising restarts it
        token.transfer(alice, 6 * MIN);
        vm.expectEmit(true, false, false, true, address(picker));
        emit HolderRefreshed(alice, 10 * MIN, enrolledAt + 10);
        vm.prank(alice);
        picker.refresh();
        (weight, since) = picker.registrationOf(alice);
        assertEq(weight, 10 * MIN);
        assertEq(since, enrolledAt + 10);

        // below the minimum there is nothing to record
        vm.prank(alice);
        token.transfer(carol, 10 * MIN - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.BelowMinimumBalance.selector, 1, MIN));
        picker.refresh();
    }

    function test_snapshotForCountsOnlyMatureWeight() public {
        uint256 maturity = GotchiConfig.ENROLL_MATURITY_BLOCKS;
        _enroll(alice, 5 * MIN);
        uint256 aliceBlock = block.number;
        vm.roll(aliceBlock + 100);
        _enroll(bob, 20 * MIN);

        // a purchase one block short of alice's maturity: nobody counts
        uint256 id = picker.snapshotFor(aliceBlock + maturity - 1);
        assertEq(picker.snapshotInfo(id).totalWeight, 0);
        (address none,) = picker.pick(id, 1);
        assertEq(none, address(0));

        // exactly at alice's maturity: alice only
        id = picker.snapshotFor(aliceBlock + maturity);
        assertEq(picker.snapshotInfo(id).totalWeight, 5 * MIN);
        assertEq(picker.weightOf(bob, aliceBlock + maturity), 0);

        // once bob matured too: both
        id = picker.snapshotFor(aliceBlock + 100 + maturity);
        assertEq(picker.snapshotInfo(id).totalWeight, 25 * MIN);

        // the unrestricted snapshot ignores age
        id = picker.snapshot();
        assertEq(picker.snapshotInfo(id).totalWeight, 25 * MIN);
    }

    function test_trimLowersAStaleWeightSoItCanBeDisplaced() public {
        // a squatter enrols 128 addresses with a large balance each (the same tokens, passed along)
        uint256 big = 1_000_000e18;
        address previous = address(this);
        for (uint256 i = 0; i < GotchiConfig.MAX_HOLDERS; ++i) {
            address squatter = address(uint160(0x5A00 + i));
            vm.prank(previous);
            token.transfer(squatter, big + MIN * (GotchiConfig.MAX_HOLDERS - i));
            vm.prank(squatter);
            picker.enroll();
            previous = squatter;
        }
        // every squatter but the last now holds far less than it recorded
        address first = address(uint160(0x5A00));
        token.transfer(alice, 10 * MIN);
        vm.prank(alice);
        vm.expectRevert(HolderWeightedPicker.RegistryFull.selector);
        picker.enroll();

        // snapshots already ignore the stale weight
        assertEq(picker.weightOf(first, type(uint256).max), token.balanceOf(first));

        // anyone trims the stale record, which makes the slot displaceable
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NotEnrolled.selector, alice));
        picker.trim(alice);
        picker.trim(first);
        (uint256 weight,) = picker.registrationOf(first);
        assertEq(weight, token.balanceOf(first));
        assertEq(picker.lowestHolder(), first);
        vm.expectRevert(
            abi.encodeWithSelector(HolderWeightedPicker.NothingToTrim.selector, first, token.balanceOf(first))
        );
        picker.trim(first);

        vm.prank(alice);
        picker.enroll();
        assertTrue(picker.isEnrolled(alice));
        assertFalse(picker.isEnrolled(first));
    }

    function test_lowestHolderFollowsEvictionsAndRefreshes() public {
        assertEq(picker.lowestHolder(), address(0));
        _enroll(alice, 3 * MIN);
        _enroll(bob, 2 * MIN);
        _enroll(carol, 5 * MIN);
        assertEq(picker.lowestHolder(), bob);
        token.transfer(bob, 10 * MIN);
        vm.prank(bob);
        picker.refresh();
        assertEq(picker.lowestHolder(), alice);
        vm.prank(alice);
        token.transfer(dead, 3 * MIN);
        picker.evict(alice);
        assertEq(picker.lowestHolder(), carol);
        vm.prank(carol);
        token.transfer(dead, 5 * MIN);
        picker.evict(carol);
        assertEq(picker.lowestHolder(), bob);
    }

    function test_evictOnlyWhenBelowMinimum() public {
        _enroll(alice, MIN);
        _enroll(bob, MIN);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.StillEligible.selector, alice, MIN));
        picker.evict(alice);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NotEnrolled.selector, carol));
        picker.evict(carol);

        vm.prank(alice);
        token.transfer(carol, 1);
        picker.evict(alice);
        assertFalse(picker.isEnrolled(alice));
        assertEq(picker.holderCount(), 1);
        assertEq(picker.holderAt(0), bob, "swap-and-pop keeps bob");
        assertTrue(picker.isEnrolled(bob));
    }

    // ---- snapshots ----

    function test_snapshotExcludesZeroBalancesAndBurnAddress() public {
        _enroll(alice, 3 * MIN);
        _enroll(bob, MIN);
        vm.prank(bob);
        token.transfer(carol, MIN); // bob now holds zero but is still enrolled
        token.transfer(dead, 100 * MIN); // burn address holds a lot, never enrolled

        vm.expectEmit(true, false, false, true, address(picker));
        emit SnapshotTaken(1, block.number, 1, 3 * MIN);
        uint256 id = picker.snapshot();
        assertEq(id, 1);
        HolderWeightedPicker.SnapshotMeta memory meta = picker.snapshotInfo(id);
        assertEq(meta.entryCount, 1);
        assertEq(meta.totalWeight, 3 * MIN);
        assertEq(picker.snapshotEntry(id, 0).holder, alice);
        assertEq(picker.snapshotEntry(id, 0).cumulative, 3 * MIN);
    }

    function test_snapshotFreezesWeights() public {
        _enroll(alice, MIN);
        _enroll(bob, MIN);
        uint256 id = picker.snapshot();
        // alice dumps everything after the snapshot: her frozen weight still counts, bob's does not grow
        vm.prank(alice);
        token.transfer(bob, MIN);
        (address winner, uint256 weight) = picker.pick(id, 0);
        assertEq(winner, alice);
        assertEq(weight, MIN);
        (winner, weight) = picker.pick(id, MIN);
        assertEq(winner, bob);
        assertEq(weight, MIN);
    }

    function test_emptySnapshotPicksNobody() public {
        uint256 id = picker.snapshot();
        (address winner, uint256 weight) = picker.pick(id, 12345);
        assertEq(winner, address(0));
        assertEq(weight, 0);
    }

    function test_pickRejectsUnknownSnapshot() public {
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.UnknownSnapshot.selector, 0));
        picker.pick(0, 1);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.UnknownSnapshot.selector, 1));
        picker.pick(1, 1);
    }

    // ---- deterministic weighted selection ----

    function test_pickIsDeterministicAndWeighted() public {
        _enroll(alice, 1 * MIN); // cumulative [0, 1M)
        _enroll(bob, 2 * MIN); // [1M, 3M)
        _enroll(carol, 7 * MIN); // [3M, 10M)
        uint256 id = picker.snapshot();
        uint256 total = 10 * MIN;

        (address w,) = picker.pick(id, 0);
        assertEq(w, alice);
        (w,) = picker.pick(id, MIN - 1);
        assertEq(w, alice);
        (w,) = picker.pick(id, MIN);
        assertEq(w, bob);
        (w,) = picker.pick(id, 3 * MIN - 1);
        assertEq(w, bob);
        (w,) = picker.pick(id, 3 * MIN);
        assertEq(w, carol);
        (w,) = picker.pick(id, total - 1);
        assertEq(w, carol);
        (w,) = picker.pick(id, total); // wraps
        assertEq(w, alice);
        (address again,) = picker.pick(id, 3 * MIN);
        assertEq(again, carol, "same input, same output");
    }

    function testFuzz_pickMatchesLinearScan(uint256 randomWord, uint8 holders) public {
        holders = uint8(bound(holders, 1, 12));
        uint256[] memory weights = new uint256[](holders);
        for (uint256 i = 0; i < holders; ++i) {
            weights[i] = MIN * (1 + uint256(keccak256(abi.encode(randomWord, i))) % 50);
            _enroll(address(uint160(0xA11CE00 + i)), weights[i]);
        }
        uint256 id = picker.snapshot();
        uint256 total = 0;
        for (uint256 i = 0; i < holders; ++i) {
            total += weights[i];
        }
        uint256 target = randomWord % total;
        uint256 running = 0;
        address expected = address(0);
        uint256 expectedWeight = 0;
        for (uint256 i = 0; i < holders; ++i) {
            running += weights[i];
            if (target < running) {
                expected = address(uint160(0xA11CE00 + i));
                expectedWeight = weights[i];
                break;
            }
        }
        (address winner, uint256 weight) = picker.pick(id, randomWord);
        assertEq(winner, expected);
        assertEq(weight, expectedWeight);
    }

    function test_frequencyRoughlyTracksWeight() public {
        _enroll(alice, 1 * MIN);
        _enroll(bob, 3 * MIN);
        uint256 id = picker.snapshot();
        uint256 bobWins = 0;
        for (uint256 i = 0; i < 400; ++i) {
            (address w,) = picker.pick(id, uint256(keccak256(abi.encode(i))));
            if (w == bob) bobWins += 1;
        }
        // expectation 300 of 400; allow a wide band, this is a sanity check not a statistics test
        assertGt(bobWins, 250);
        assertLt(bobWins, 350);
    }
}
