// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {HolderWeightedPicker} from "../../src/HolderWeightedPicker.sol";

/// @notice Token transfers versus airdrop weight: exclusions, boundaries of the cumulative table, and
/// registry bookkeeping under eviction.
contract HolderWeightedPickerEdgeTest is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant MIN = 1_000e18;

    LaunchToken internal token;
    HolderWeightedPicker internal picker;
    address internal a = makeAddr("a");
    address internal b = makeAddr("b");
    address internal c = makeAddr("c");

    function setUp() public {
        token = new LaunchToken();
        picker = new HolderWeightedPicker(address(token));
    }

    function _enroll(address who, uint256 amount) internal {
        token.transfer(who, amount);
        vm.prank(who);
        picker.enroll();
    }

    // ---- enrolment boundaries ----

    function test_enrollAtExactlyTheMinimumAndOneWeiBelow() public {
        token.transfer(a, MIN - 1);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.BelowMinimumBalance.selector, MIN - 1, MIN));
        picker.enroll();
        token.transfer(a, 1);
        vm.prank(a);
        picker.enroll();
        assertTrue(picker.isEnrolled(a));
    }

    function test_evictionBoundaryIsOneWeiBelowTheMinimum() public {
        _enroll(a, MIN);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.StillEligible.selector, a, MIN));
        picker.evict(a);
        vm.prank(a);
        token.transfer(b, 1);
        vm.prank(c); // anyone
        picker.evict(a);
        assertFalse(picker.isEnrolled(a));
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NotEnrolled.selector, a));
        picker.evict(a);
    }

    function test_evictNeverEnrolledAndZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NotEnrolled.selector, b));
        picker.evict(b);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NotEnrolled.selector, address(0)));
        picker.evict(address(0));
    }

    function test_evictingFirstMiddleAndLastKeepsTheRegistryConsistent() public {
        address[5] memory hs = [makeAddr("h0"), makeAddr("h1"), makeAddr("h2"), makeAddr("h3"), makeAddr("h4")];
        for (uint256 i = 0; i < 5; ++i) {
            _enroll(hs[i], MIN);
        }
        uint256[3] memory order = [uint256(2), 0, 4]; // middle, first, last
        for (uint256 k = 0; k < 3; ++k) {
            address gone = hs[order[k]];
            vm.prank(gone);
            token.transfer(address(this), MIN);
            picker.evict(gone);
            assertFalse(picker.isEnrolled(gone));
            for (uint256 i = 0; i < picker.holderCount(); ++i) {
                address h = picker.holderAt(i);
                assertTrue(picker.isEnrolled(h));
                assertTrue(h != gone);
            }
        }
        assertEq(picker.holderCount(), 2);
        // the survivors are still evictable by index: the moved entries kept valid indexes
        vm.prank(hs[1]);
        token.transfer(address(this), MIN);
        picker.evict(hs[1]);
        assertEq(picker.holderCount(), 1);
        assertEq(picker.holderAt(0), hs[3]);
    }

    function test_evictedHolderCanEnrollAgain() public {
        _enroll(a, MIN);
        vm.prank(a);
        token.transfer(address(this), MIN);
        picker.evict(a);
        _enroll(a, 5 * MIN);
        assertEq(picker.holderCount(), 1);
        uint256 id = picker.snapshot();
        (address winner, uint256 weight) = picker.pick(id, 0);
        assertEq(winner, a);
        assertEq(weight, 5 * MIN);
    }

    // ---- weight exclusions ----

    function test_tokensSentToTheBurnAddressCarryNoWeight() public {
        _enroll(a, MIN);
        token.transfer(DEAD, 900_000_000e18); // 90% of the supply is "burned"
        vm.prank(DEAD);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.ExcludedAddress.selector, DEAD));
        picker.enroll();
        uint256 id = picker.snapshot();
        assertEq(picker.snapshotInfo(id).totalWeight, MIN);
        for (uint256 i = 0; i < 50; ++i) {
            (address winner,) = picker.pick(id, uint256(keccak256(abi.encode(i))));
            assertEq(winner, a);
        }
    }

    function test_unenrolledWhaleCarriesNoWeight() public {
        _enroll(a, MIN);
        token.transfer(b, 500_000_000e18); // never opts in
        uint256 id = picker.snapshot();
        assertEq(picker.snapshotInfo(id).entryCount, 1);
        (address winner,) = picker.pick(id, type(uint256).max);
        assertEq(winner, a);
    }

    function test_enrolledHolderWhoSoldEverythingIsSkipped() public {
        _enroll(a, 2 * MIN);
        _enroll(b, 3 * MIN);
        _enroll(c, 4 * MIN);
        vm.prank(b);
        token.transfer(address(this), 3 * MIN);
        uint256 id = picker.snapshot();
        HolderWeightedPicker.SnapshotMeta memory meta = picker.snapshotInfo(id);
        assertEq(meta.entryCount, 2);
        assertEq(meta.totalWeight, 6 * MIN);
        for (uint256 w = 0; w < 6; ++w) {
            (address winner,) = picker.pick(id, w * MIN);
            assertTrue(winner == a || winner == c, "zero-balance holder won");
        }
    }

    function test_holderBelowMinimumButNotEvictedKeepsTheirRemainingWeight() public {
        _enroll(a, MIN);
        _enroll(b, MIN);
        vm.prank(a);
        token.transfer(address(this), MIN - 7); // 7 wei left, below the minimum, not yet evicted
        uint256 id = picker.snapshot();
        assertEq(picker.snapshotInfo(id).totalWeight, MIN + 7);
        (address w0, uint256 weight0) = picker.pick(id, 6);
        (address w1,) = picker.pick(id, 7);
        assertEq(w0, a);
        assertEq(weight0, 7);
        assertEq(w1, b);
    }

    function test_everyHolderAtZeroYieldsAnEmptySnapshot() public {
        _enroll(a, MIN);
        vm.prank(a);
        token.transfer(address(this), MIN);
        uint256 id = picker.snapshot();
        assertEq(picker.snapshotInfo(id).entryCount, 0);
        (address winner, uint256 weight) = picker.pick(id, 123);
        assertEq(winner, address(0));
        assertEq(weight, 0);
    }

    // ---- cumulative table boundaries ----

    function test_pickAtEveryBoundaryOfTheTable() public {
        _enroll(a, 1 * MIN);
        _enroll(b, 2 * MIN);
        _enroll(c, 3 * MIN);
        uint256 id = picker.snapshot();
        uint256 total = 6 * MIN;
        _expect(id, 0, a, 1 * MIN);
        _expect(id, MIN - 1, a, 1 * MIN);
        _expect(id, MIN, b, 2 * MIN);
        _expect(id, 3 * MIN - 1, b, 2 * MIN);
        _expect(id, 3 * MIN, c, 3 * MIN);
        _expect(id, total - 1, c, 3 * MIN);
        _expect(id, total, a, 1 * MIN); // wraps
        _expect(id, type(uint256).max, _linear(type(uint256).max % total), 0);
    }

    function _linear(uint256 target) internal view returns (address) {
        if (target < MIN) return a;
        if (target < 3 * MIN) return b;
        return c;
    }

    function _expect(uint256 id, uint256 word, address who, uint256 weight) internal view {
        (address winner, uint256 got) = picker.pick(id, word);
        assertEq(winner, who);
        if (weight > 0) assertEq(got, weight);
    }

    function test_singleHolderAlwaysWins() public {
        _enroll(a, MIN);
        uint256 id = picker.snapshot();
        uint256[4] memory words = [uint256(0), 1, MIN, type(uint256).max];
        for (uint256 i = 0; i < 4; ++i) {
            (address winner, uint256 weight) = picker.pick(id, words[i]);
            assertEq(winner, a);
            assertEq(weight, MIN);
        }
    }

    function test_wholeSupplyInOneWalletFitsTheWeightType() public {
        token.transfer(a, token.totalSupply());
        vm.prank(a);
        picker.enroll();
        uint256 id = picker.snapshot();
        assertEq(picker.snapshotInfo(id).totalWeight, 1_000_000_000e18);
        (address winner, uint256 weight) = picker.pick(id, type(uint256).max);
        assertEq(winner, a);
        assertEq(weight, 1_000_000_000e18);
    }

    // ---- snapshots ----

    function test_snapshotsAreIndependentAndIdsAreSequential() public {
        _enroll(a, MIN);
        uint256 first = picker.snapshot();
        _enroll(b, 9 * MIN);
        vm.prank(c);
        uint256 second = picker.snapshot(); // permissionless
        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(picker.snapshotInfo(first).totalWeight, MIN);
        assertEq(picker.snapshotInfo(second).totalWeight, 10 * MIN);
        (address w1,) = picker.pick(first, 5 * MIN);
        (address w2,) = picker.pick(second, 5 * MIN);
        assertEq(w1, a, "an old snapshot is not rewritten by a later one");
        assertEq(w2, b);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.UnknownSnapshot.selector, 0));
        picker.pick(0, 1);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.UnknownSnapshot.selector, 3));
        picker.pick(3, 1);
    }

    function test_transfersAfterTheSnapshotDoNotMoveWeight() public {
        _enroll(a, 4 * MIN);
        _enroll(b, MIN);
        uint256 id = picker.snapshot();
        vm.prank(a);
        token.transfer(b, 4 * MIN); // a exits entirely after the freeze
        (address winner, uint256 weight) = picker.pick(id, 0);
        assertEq(winner, a);
        assertEq(weight, 4 * MIN);
        (address live,) = picker.pick(picker.snapshot(), 0);
        assertEq(live, b, "a fresh snapshot sees the new balances");
    }

    // ---- properties ----

    /// Each holder's share of the outcome space is exactly their balance: counting winners over one full
    /// period of the table reproduces the balances.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_winnerOwnsExactlyTheirBalanceRange(uint256 wa, uint256 wb, uint256 wc, uint256 word) public {
        wa = bound(wa, MIN, 1_000_000e18);
        wb = bound(wb, MIN, 1_000_000e18);
        wc = bound(wc, MIN, 1_000_000e18);
        _enroll(a, wa);
        _enroll(b, wb);
        _enroll(c, wc);
        uint256 id = picker.snapshot();
        uint256 target = word % (wa + wb + wc);
        address expected = target < wa ? a : (target < wa + wb ? b : c);
        uint256 expectedWeight = expected == a ? wa : (expected == b ? wb : wc);
        (address winner, uint256 weight) = picker.pick(id, word);
        assertEq(winner, expected);
        assertEq(weight, expectedWeight);
        // deterministic: same inputs, same answer
        (address again,) = picker.pick(id, word);
        assertEq(again, winner);
        _assertRangeEdges(id, wa, wb);
    }

    /// @dev The last unit of each range still belongs to its holder.
    function _assertRangeEdges(uint256 id, uint256 wa, uint256 wb) internal view {
        (address endA,) = picker.pick(id, wa - 1);
        (address startB,) = picker.pick(id, wa);
        (address endB,) = picker.pick(id, wa + wb - 1);
        (address startC,) = picker.pick(id, wa + wb);
        assertEq(endA, a);
        assertEq(startB, b);
        assertEq(endB, b);
        assertEq(startC, c);
    }

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_snapshotTotalIsTheSumOfEnrolledBalances(uint8 count, uint256 seed, uint8 drained) public {
        count = uint8(bound(count, 1, 24));
        uint256 sum = 0;
        uint256 entries = 0;
        for (uint256 i = 0; i < count; ++i) {
            address h = address(uint160(0xA000 + i));
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i))), MIN, 2_000_000e18);
            _enroll(h, amount);
            if (i == uint256(drained) % count) {
                vm.prank(h);
                token.transfer(DEAD, amount); // drained to the burn address: weight must vanish
            } else {
                sum += amount;
                entries += 1;
            }
        }
        uint256 id = picker.snapshot();
        HolderWeightedPicker.SnapshotMeta memory meta = picker.snapshotInfo(id);
        assertEq(meta.totalWeight, sum);
        assertEq(meta.entryCount, entries);
        assertEq(meta.blockNumber, block.number);
    }

    // ---- recorded weights, maturity, trim and displacement ----

    uint256 internal constant MATURITY = 300;

    function test_tokensReceivedAfterEnrollingAddNoWeightUntilRefreshed() public {
        _enroll(a, MIN);
        token.transfer(a, 99 * MIN);
        uint256 id = picker.snapshot();
        assertEq(picker.snapshotInfo(id).totalWeight, MIN, "recorded weight caps the live balance");
        assertEq(picker.weightOf(a, type(uint256).max), MIN);
        vm.prank(a);
        picker.refresh();
        assertEq(picker.weightOf(a, type(uint256).max), 100 * MIN);
        assertEq(picker.weightOf(a, block.number + MATURITY - 1), 0, "raised weight is immature again");
        assertEq(picker.weightOf(a, block.number + MATURITY), 100 * MIN);
    }

    function test_refreshAtAnUnchangedBalanceKeepsTheMaturity() public {
        _enroll(a, MIN);
        (, uint256 since) = picker.registrationOf(a);
        vm.roll(block.number + 50);
        vm.prank(a);
        picker.refresh();
        (uint256 weight, uint256 sinceAfter) = picker.registrationOf(a);
        assertEq(weight, MIN);
        assertEq(sinceAfter, since, "equal balance: no maturity restart");
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NothingToTrim.selector, a, MIN));
        picker.trim(a);
    }

    function test_trimDownToZeroLeavesTheSlotButNoWeight() public {
        _enroll(a, 5 * MIN);
        _enroll(b, MIN);
        vm.prank(a);
        token.transfer(address(this), 5 * MIN);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NothingToTrim.selector, b, MIN));
        picker.trim(b);
        vm.prank(c); // anyone
        picker.trim(a);
        (uint256 weight,) = picker.registrationOf(a);
        assertEq(weight, 0);
        assertTrue(picker.isEnrolled(a), "trim is not eviction");
        assertEq(picker.lowestHolder(), a);
        uint256 id = picker.snapshot();
        assertEq(picker.snapshotInfo(id).entryCount, 1);
        (address winner,) = picker.pick(id, 7);
        assertEq(winner, b);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NothingToTrim.selector, a, 0));
        picker.trim(a);
        vm.expectRevert(HolderWeightedPicker.ZeroAddress.selector);
        picker.trim(address(0));
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NotEnrolled.selector, c));
        picker.trim(c);
    }

    function test_refreshBelowMinimumIsRefusedButTrimStillWorks() public {
        _enroll(a, 2 * MIN);
        vm.prank(a);
        token.transfer(address(this), MIN + 1);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.BelowMinimumBalance.selector, MIN - 1, MIN));
        picker.refresh();
        picker.trim(a);
        (uint256 weight,) = picker.registrationOf(a);
        assertEq(weight, MIN - 1);
    }

    /// A full registry: the predicted victim is always the holder `lowestHolder()` names, whose weight is
    /// the minimum; a newcomer at or below that weight is refused; above it, exactly that holder leaves.
    /// forge-config: default.fuzz.runs = 60
    function testFuzz_displacementAtTheCapFollowsTheModel(uint256 seed, uint8 newcomers) public {
        uint256 cap = picker.MAX_HOLDERS();
        for (uint256 i = 0; i < cap; ++i) {
            address h = address(uint160(0xB000 + i));
            _enroll(h, MIN + bound(uint256(keccak256(abi.encode(seed, "w", i))), 0, 5));
        }
        newcomers = uint8(bound(newcomers, 1, 16));
        for (uint256 n = 0; n < newcomers; ++n) {
            address victim = picker.lowestHolder();
            (uint256 victimWeight,) = picker.registrationOf(victim);
            assertEq(victimWeight, _minRecordedWeight(), "lowestHolder is not a minimum");
            address newcomer = address(uint160(0xC000 + n));
            uint256 balance = MIN + bound(uint256(keccak256(abi.encode(seed, "n", n))), 0, 7);
            token.transfer(newcomer, balance);
            vm.prank(newcomer);
            if (balance <= victimWeight) {
                vm.expectRevert(HolderWeightedPicker.RegistryFull.selector);
                picker.enroll();
                assertTrue(picker.isEnrolled(victim));
                continue;
            }
            picker.enroll();
            assertFalse(picker.isEnrolled(victim), "the predicted victim stayed");
            assertTrue(picker.isEnrolled(newcomer));
            assertEq(picker.holderCount(), cap);
            (uint256 w, uint256 since) = picker.registrationOf(newcomer);
            assertEq(w, balance);
            assertEq(since, block.number);
            // the displaced holder can come straight back by beating the new minimum
            uint256 minNow = _minRecordedWeight();
            uint256 victimBalance = token.balanceOf(victim);
            if (victimBalance <= minNow) token.transfer(victim, minNow + 1 - victimBalance);
            vm.prank(victim);
            picker.enroll();
            assertTrue(picker.isEnrolled(victim));
            assertEq(picker.holderCount(), cap);
        }
        _assertRegistryConsistent();
    }

    /// Random enrol / transfer / refresh / trim / evict / roll sequences: recorded weights, the lowest
    /// entry and both snapshot flavours agree with an independent model (kept in storage).
    /// forge-config: default.fuzz.runs = 120
    function testFuzz_registryBookkeepingMatchesAModel(uint256 seed, uint8 steps) public {
        _modelHolders = [a, b, c, makeAddr("d"), makeAddr("e"), makeAddr("f")];
        steps = uint8(bound(steps, 1, 40));
        for (uint256 s = 0; s < steps; ++s) {
            _modelStep(uint256(keccak256(abi.encode(seed, s))));
            _modelCheck();
        }
        _assertRegistryConsistent();
    }

    address[6] internal _modelHolders;
    uint256[6] internal _modelRecorded;
    uint256[6] internal _modelSince;
    bool[6] internal _modelEnrolled;

    function _modelStep(uint256 r) internal {
        uint256 i = r % 6;
        address h = _modelHolders[i];
        uint256 op = (r >> 8) % 7;
        uint256 amount = bound(r >> 16, 0, 4 * MIN);
        if (op == 0) {
            token.transfer(h, amount);
            _modelEnroll(i, h);
        } else if (op == 1) {
            uint256 bal = token.balanceOf(h);
            vm.prank(h);
            token.transfer(address(this), amount > bal ? bal : amount);
        } else if (op == 2) {
            token.transfer(h, amount);
        } else if (op == 3) {
            _modelRefresh(i, h);
        } else if (op == 4) {
            _modelTrim(i, h);
        } else if (op == 5) {
            _modelEvict(i, h);
        } else {
            vm.roll(block.number + bound(r >> 32, 1, 200));
        }
    }

    function _modelEnroll(uint256 i, address h) internal {
        uint256 bal = token.balanceOf(h);
        vm.prank(h);
        if (_modelEnrolled[i]) {
            vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.AlreadyEnrolled.selector, h));
            picker.enroll();
        } else if (bal < MIN) {
            vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.BelowMinimumBalance.selector, bal, MIN));
            picker.enroll();
        } else {
            picker.enroll();
            _modelEnrolled[i] = true;
            _modelRecorded[i] = bal;
            _modelSince[i] = block.number;
        }
    }

    function _modelRefresh(uint256 i, address h) internal {
        uint256 bal = token.balanceOf(h);
        vm.prank(h);
        if (!_modelEnrolled[i]) {
            vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NotEnrolled.selector, h));
            picker.refresh();
        } else if (bal < MIN) {
            vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.BelowMinimumBalance.selector, bal, MIN));
            picker.refresh();
        } else {
            picker.refresh();
            if (bal > _modelRecorded[i]) _modelSince[i] = block.number;
            _modelRecorded[i] = bal;
        }
    }

    function _modelTrim(uint256 i, address h) internal {
        uint256 bal = token.balanceOf(h);
        if (!_modelEnrolled[i]) {
            vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NotEnrolled.selector, h));
            picker.trim(h);
        } else if (bal >= _modelRecorded[i]) {
            vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NothingToTrim.selector, h, bal));
            picker.trim(h);
        } else {
            picker.trim(h);
            _modelRecorded[i] = bal;
        }
    }

    function _modelEvict(uint256 i, address h) internal {
        uint256 bal = token.balanceOf(h);
        if (!_modelEnrolled[i]) {
            vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NotEnrolled.selector, h));
            picker.evict(h);
        } else if (bal >= MIN) {
            vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.StillEligible.selector, h, bal));
            picker.evict(h);
        } else {
            picker.evict(h);
            _modelEnrolled[i] = false;
            _modelRecorded[i] = 0;
            _modelSince[i] = 0;
        }
    }

    function _modelCheck() internal {
        uint256 count = 0;
        uint256 minWeight = type(uint256).max;
        uint256 liveSum = 0;
        uint256 matureSum = 0;
        for (uint256 k = 0; k < 6; ++k) {
            address h = _modelHolders[k];
            assertEq(picker.isEnrolled(h), _modelEnrolled[k], "enrolment flag");
            if (!_modelEnrolled[k]) continue;
            count += 1;
            (uint256 w, uint256 sb) = picker.registrationOf(h);
            assertEq(w, _modelRecorded[k], "recorded weight");
            assertEq(sb, _modelSince[k], "maturity block");
            if (w < minWeight) minWeight = w;
            uint256 live = token.balanceOf(h);
            uint256 eff = live < w ? live : w;
            bool mature = _modelSince[k] + MATURITY <= block.number;
            liveSum += eff;
            if (mature) matureSum += eff;
            assertEq(picker.weightOf(h, type(uint256).max), eff, "live weight");
            assertEq(picker.weightOf(h, block.number), mature ? eff : 0, "mature weight");
        }
        assertEq(picker.holderCount(), count);
        address lowest = picker.lowestHolder();
        if (count == 0) {
            assertEq(lowest, address(0));
        } else {
            assertTrue(picker.isEnrolled(lowest), "lowest is not enrolled");
            (uint256 lw,) = picker.registrationOf(lowest);
            assertEq(lw, minWeight, "lowest is not the minimum recorded weight");
        }
        assertEq(picker.snapshotInfo(picker.snapshot()).totalWeight, liveSum, "live snapshot total");
        assertEq(picker.snapshotInfo(picker.snapshotFor(block.number)).totalWeight, matureSum, "mature total");
    }

    function _minRecordedWeight() internal view returns (uint256 minWeight) {
        minWeight = type(uint256).max;
        for (uint256 i = 0; i < picker.holderCount(); ++i) {
            (uint256 w,) = picker.registrationOf(picker.holderAt(i));
            if (w < minWeight) minWeight = w;
        }
    }

    function _assertRegistryConsistent() internal view {
        uint256 n = picker.holderCount();
        for (uint256 i = 0; i < n; ++i) {
            address h = picker.holderAt(i);
            assertTrue(picker.isEnrolled(h));
            for (uint256 j = i + 1; j < n; ++j) {
                assertTrue(picker.holderAt(j) != h, "duplicate registry entry");
            }
        }
    }
}
