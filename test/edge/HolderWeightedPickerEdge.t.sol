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
}
