// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {GotchiFixture} from "../utils/GotchiFixture.sol";
import {SystemHandler} from "./SystemHandler.sol";
import {FlipEscrow} from "../../src/FlipEscrow.sol";
import {HolderWeightedPicker} from "../../src/HolderWeightedPicker.sol";
import {IMockBaazaar} from "../../src/interfaces/IMockBaazaar.sol";

/// @notice Invariants over random call sequences against the fully wired system: a real v4 PoolManager,
/// the hook, FeeSink, MockBaazaar, FlipEscrow and the picker, driven by five actors.
contract SystemInvariantTest is GotchiFixture {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    SystemHandler internal handler;
    address[] internal actors;
    address[] internal ethHolders;
    uint256 internal initialEth;
    uint128 internal initialLiquidity;

    function setUp() public override {
        super.setUp();
        for (uint256 i = 0; i < 5; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            vm.deal(a, 30 ether);
        }
        // three funded holders, one dust holder below the enrolment minimum, one with nothing
        token.transfer(actors[0], 20_000_000e18);
        token.transfer(actors[1], 5_000_000e18);
        token.transfer(actors[2], 1_000e18);
        token.transfer(actors[3], 999e18);

        handler = new SystemHandler(
            SystemHandler.Refs({
                manager: manager,
                token: token,
                nft: nft,
                market: market,
                picker: picker,
                escrow: escrow,
                feeSink: feeSink,
                hook: hook,
                forever: forever,
                router: router,
                owner: address(this)
            }),
            actors
        );
        initialLiquidity = forever.totalLiquidity();
        // token float the handler hands to registry fillers (never swapped, so ETH accounting is untouched)
        token.transfer(address(handler), 3_000_000e18);

        for (uint256 i = 0; i < actors.length; ++i) {
            ethHolders.push(actors[i]);
        }
        ethHolders.push(address(manager));
        ethHolders.push(address(feeSink));
        ethHolders.push(address(market));
        ethHolders.push(address(forever));
        ethHolders.push(address(router));
        ethHolders.push(address(hook));
        ethHolders.push(address(escrow));
        ethHolders.push(address(picker));
        ethHolders.push(address(handler));
        initialEth = _totalEth();

        // Start every run from a live system rather than an empty one: enrolled holders, listings, fees
        // in the sink, one pending and one committed flip. All through the handler so the ghosts agree.
        handler.enroll(0);
        handler.enroll(1);
        handler.list(0, 0.004 ether);
        handler.list(1, 0.006 ether);
        handler.list(2, 0.008 ether);
        handler.list(3, 0.02 ether);
        handler.buyExactEthIn(1, 1.999 ether + 1);
        handler.donateToSink(1, 0.025 ether + 1);
        handler.keeperTryBuy();
        handler.keeperTryBuy();
        handler.commit(1, bytes32("setup"));
        require(escrow.acquisitionCount() >= 2, "setup: expected two acquisitions");

        targetContract(address(handler));
    }

    function _totalEth() internal view returns (uint256 total) {
        for (uint256 i = 0; i < ethHolders.length; ++i) {
            total += ethHolders[i].balance;
        }
    }

    // ---------------------------------------------------------------- FeeSink

    /// The sink holds exactly what it received minus what it spent, and it received exactly the hook's
    /// fees plus direct donations: no ETH leaks and none is created.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 150
    function invariant_sinkBalanceIsReceivedMinusSpent() public view {
        assertEq(address(feeSink).balance, feeSink.totalReceived() - feeSink.totalSpent(), "sink solvency");
        assertEq(feeSink.totalReceived(), hook.totalFeesCollected() + handler.ghostDonated(), "sink inflow");
        assertEq(hook.totalFeesCollected(), handler.ghostFees(), "hook fees equal the sum of 30 bps skims");
        assertEq(feeSink.buyCount(), escrow.acquisitionCount(), "every purchase became exactly one acquisition");
    }

    /// Every purchase paid a price inside [MIN_BUY_PRICE, MAX_BUY_PRICE], so lifetime spend is bounded
    /// by the purchase count on both sides (per-purchase bounds are asserted in the handler).
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 150
    function invariant_sinkSpendStaysInsideThePriceBand() public view {
        uint256 buys = feeSink.buyCount();
        assertGe(feeSink.totalSpent(), buys * 0.001 ether, "a purchase below the floor");
        assertLe(feeSink.totalSpent(), buys * 0.05 ether, "a purchase above the ceiling");
    }

    // ---------------------------------------------------------------- market

    /// The market's ETH is exactly the sellers' unwithdrawn credit, and everything ever paid in is either
    /// still credited or was withdrawn by a seller.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 150
    function invariant_marketEthEqualsSellerCredits() public view {
        uint256 credits = 0;
        for (uint256 i = 0; i < actors.length; ++i) {
            credits += market.proceeds(actors[i]);
        }
        assertEq(address(market).balance, credits, "market ETH equals what it owes sellers");
        assertEq(
            credits + handler.ghostWithdrawn(),
            feeSink.totalSpent() + handler.ghostDirectPaid(),
            "paid in equals credited plus withdrawn"
        );
    }

    /// Every active listing is backed by an NFT in the market's custody, the active set has no
    /// duplicates or stale entries, and `cheapest()` is the true minimum (lowest id on ties).
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 150
    function invariant_marketListingsAreBackedAndCheapestIsMinimal() public view {
        uint256 active = market.activeCount();
        assertLe(active, 64, "listing cap");
        assertEq(nft.balanceOf(address(market)), active, "one escrowed NFT per active listing");
        IMockBaazaar.Listing memory best = market.cheapest();
        assertEq(best.active, active > 0, "cheapest is active iff something is listed");
        for (uint256 i = 0; i < active; ++i) {
            uint256 id = market.activeIdAt(i);
            IMockBaazaar.Listing memory l = market.getListing(id);
            assertTrue(l.active, "active set holds only active listings");
            assertEq(l.listingId, id);
            assertGe(l.price, 0.001 ether, "listing below the floor");
            assertLt(id, market.nextListingId());
            assertEq(nft.ownerOf(l.tokenId), address(market), "listed NFT is in custody");
            assertTrue(
                best.price < l.price || (best.price == l.price && best.listingId <= id), "cheapest is not minimal"
            );
            for (uint256 j = i + 1; j < active; ++j) {
                assertTrue(market.activeIdAt(j) != id, "duplicate active id");
            }
        }
    }

    // ---------------------------------------------------------------- escrow

    /// The escrow holds exactly the NFTs of open flips; a resolved flip never reopens and its NFT sits
    /// with the recorded recipient at resolution (burn address for burns, never for airdrops).
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 150
    function invariant_escrowCustodyMatchesOpenFlips() public view {
        uint256 count = escrow.acquisitionCount();
        uint256 open = 0;
        uint256 burned = 0;
        uint256 airdropped = 0;
        for (uint256 id = 1; id <= count; ++id) {
            FlipEscrow.Acquisition memory a = escrow.getAcquisition(id);
            assertTrue(a.status != FlipEscrow.Status.None, "counted acquisition without a record");
            if (a.status == FlipEscrow.Status.Resolved) {
                assertTrue(handler.ghostResolved(id), "resolved without a reveal or timeout");
                assertEq(a.recipient, handler.ghostRecipient(id), "recipient changed after resolution");
                if (a.burned) {
                    burned += 1;
                    assertEq(a.recipient, DEAD, "burned flips record the burn address");
                    assertEq(nft.ownerOf(a.tokenId), DEAD, "burned NFT left the burn address");
                } else {
                    airdropped += 1;
                    assertTrue(a.recipient != DEAD && a.recipient != address(0), "airdrop to an excluded address");
                }
            } else {
                open += 1;
                assertFalse(handler.ghostResolved(id), "a finished flip reopened");
                assertEq(nft.ownerOf(a.tokenId), address(escrow), "open flip without its NFT");
                assertEq(escrow.openAcquisitionOf(a.tokenId), id, "open flip not indexed by token");
                assertEq(a.recipient, address(0));
                assertFalse(a.burned);
            }
        }
        assertEq(nft.balanceOf(address(escrow)), open, "escrow NFT count equals open flips");
        assertEq(burned, handler.ghostBurns() + handler.ghostTimeouts(), "burn count");
        assertEq(airdropped, handler.ghostAirdrops(), "airdrop count");
        assertEq(escrow.getAcquisition(count + 1).requestBlock, 0, "no record beyond the counter");
    }

    // ---------------------------------------------------------------- conservation

    /// ETH is neither created nor destroyed, the hook/escrow/picker/router never hold any, the token
    /// supply is fixed and the hook never holds tokens.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 150
    function invariant_ethAndSupplyAreConserved() public view {
        assertEq(_totalEth(), initialEth, "system ETH conserved");
        assertEq(address(hook).balance, 0, "hook holds no ETH");
        assertEq(address(escrow).balance, 0, "escrow holds no ETH");
        assertEq(address(picker).balance, 0, "picker holds no ETH");
        assertEq(address(router).balance, 0, "router refunds everything");
        assertEq(address(forever).balance, 0, "liquidity locker refunds everything");
        assertEq(token.totalSupply(), SUPPLY, "fixed supply");
        assertEq(token.balanceOf(address(hook)), 0, "hook holds no tokens");
        assertEq(token.balanceOf(address(feeSink)), 0, "sink holds no tokens");
        assertEq(token.balanceOf(address(forever)), 0, "locker keeps no token leftovers");
    }

    // ---------------------------------------------------------------- liquidity

    /// Forever liquidity never decreases and matches the position the PoolManager records for the locker.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 150
    function invariant_foreverLiquidityNeverDecreases() public view {
        uint128 locked = forever.totalLiquidity();
        assertGe(locked, initialLiquidity, "liquidity below the initial seed");
        assertEq(locked, handler.ghostLiquidityFloor(), "liquidity changed outside seed()");
        PoolId id = key.toId();
        bytes32 positionId =
            Position.calculatePositionKey(address(forever), forever.TICK_LOWER(), forever.TICK_UPPER(), bytes32(0));
        assertEq(
            StateLibrary.getPositionLiquidity(IPoolManager(address(manager)), id, positionId),
            locked,
            "locker position mismatch"
        );
        assertEq(StateLibrary.getLiquidity(IPoolManager(address(manager)), id), locked, "pool liquidity mismatch");
    }

    // ---------------------------------------------------------------- picker

    /// The registry is a duplicate-free set of opted-in holders within the cap; every snapshot is a
    /// strictly increasing cumulative table with no zero weights and no burn/zero address.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 150
    function invariant_registryAndSnapshotsAreWellFormed() public view {
        uint256 holders = picker.holderCount();
        assertLe(holders, 128, "registry cap");
        // read the registry once, then sort in memory so the duplicate check costs no external calls
        address[] memory listed = new address[](holders);
        for (uint256 i = 0; i < holders; ++i) {
            address h = picker.holderAt(i);
            assertTrue(picker.isEnrolled(h), "listed holder not enrolled");
            assertTrue(h != DEAD && h != address(0), "excluded address enrolled");
            uint256 j = i;
            while (j > 0 && listed[j - 1] > h) {
                listed[j] = listed[j - 1];
                j -= 1;
            }
            listed[j] = h;
        }
        for (uint256 i = 1; i < holders; ++i) {
            assertTrue(listed[i - 1] != listed[i], "holder enrolled twice");
        }
        uint256 enrolledActors = 0;
        uint256 minWeight = type(uint256).max;
        for (uint256 i = 0; i < actors.length; ++i) {
            if (!picker.isEnrolled(actors[i])) continue;
            enrolledActors += 1;
            (uint256 w,) = picker.registrationOf(actors[i]);
            if (w < minWeight) minWeight = w;
        }
        address[] memory fillers = handler.fillers();
        for (uint256 i = 0; i < fillers.length; ++i) {
            if (!picker.isEnrolled(fillers[i])) continue;
            enrolledActors += 1;
            (uint256 w,) = picker.registrationOf(fillers[i]);
            if (w < minWeight) minWeight = w;
        }
        assertEq(enrolledActors, holders, "enrolled flag without a registry slot");
        address lowest = picker.lowestHolder();
        if (holders == 0) {
            assertEq(lowest, address(0), "lowest holder on an empty registry");
        } else {
            assertTrue(picker.isEnrolled(lowest), "lowest holder is not enrolled");
            (uint256 lw,) = picker.registrationOf(lowest);
            assertEq(lw, minWeight, "lowest holder does not carry the minimum recorded weight");
        }

        uint256 snapshots = picker.snapshotCount();
        uint256 from = snapshots > 4 ? snapshots - 3 : 1; // the most recent tables
        for (uint256 s = from; s <= snapshots; ++s) {
            HolderWeightedPicker.SnapshotMeta memory meta = picker.snapshotInfo(s);
            uint256 previous = 0;
            for (uint256 i = 0; i < meta.entryCount; ++i) {
                HolderWeightedPicker.Entry memory e = picker.snapshotEntry(s, i);
                assertGt(e.cumulative, previous, "zero-weight entry in a snapshot");
                assertTrue(e.holder != DEAD && e.holder != address(0), "excluded address in a snapshot");
                previous = e.cumulative;
            }
            assertEq(previous, meta.totalWeight, "total weight is the last cumulative");
            assertLe(meta.totalWeight, SUPPLY, "weight above supply");
            if (meta.entryCount > 0) {
                // both ends of the table are reachable and never resolve to an excluded address
                (address first,) = picker.pick(s, 0);
                (address last,) = picker.pick(s, uint256(meta.totalWeight) - 1);
                assertEq(first, picker.snapshotEntry(s, 0).holder);
                assertEq(last, picker.snapshotEntry(s, meta.entryCount - 1).holder);
            } else {
                (address nobody, uint256 weight) = picker.pick(s, 12345);
                assertEq(nobody, address(0));
                assertEq(weight, 0);
            }
        }
    }

    // ---------------------------------------------------------------- handler coverage

    /// A scripted pass through the handler, so the invariants above are known not to be vacuous: fees are
    /// skimmed, a purchase happens, and all three resolution paths (burn, airdrop, timeout) are reached.
    function test_handlerReachesEveryPath() public {
        handler.enroll(0);
        handler.enroll(1);
        handler.enroll(2);
        handler.enroll(3); // 999 tokens: must be refused (asserted inside)
        handler.list(0, 0.004 ether);
        handler.list(1, 0.02 ether);
        handler.buyExactEthIn(2, 1.999 ether + 1);
        handler.buyExactEthIn(3, 1.999 ether + 1); // 0.012 ETH of fees: the cheapest listing is bought in-swap
        assertGt(feeSink.buyCount(), 2, "in-swap purchase");
        handler.sellExactTokensIn(2, type(uint256).max);
        handler.buyExactTokensOut(4, 1_000_000e18 + 1);
        handler.sellForExactEthOut(0, 0.01 ether + 1);
        handler.donateToSink(4, 0.02 ether + 1);
        handler.keeperTryBuy();
        handler.strangerTryBuy(1);
        handler.underpay(2);
        handler.cancelByNonSeller(3, 0);
        handler.withdraw(0);
        handler.withdraw(4); // nothing credited: revert asserted inside
        handler.listBelowFloor(0, 5);
        handler.listAboveCeiling(1, 0.2 ether);
        handler.partialTokenExactIn(0, 1e22, 1_000_000e18);
        handler.partialEthExactIn(1, 1e22, 0.01 ether);
        assertGt(handler.ghostPartialFills() + handler.ghostRefusedPartials(), 0, "partial fill paths");
        handler.refresh(0); // enrolled, balance changed by the swaps above
        handler.refresh(4); // never enrolled: revert asserted inside
        handler.trim(3, 1); // actor 1 sold tokens above: stale weight trimmed
        handler.trim(3, 4); // not enrolled: revert asserted inside

        // the registry must mature before airdrops can happen: purchases from here on count the holders
        vm.roll(block.number + 301);

        // resolve acquisitions until both branches have been seen
        uint256 guard = 0;
        while ((handler.ghostBurns() < 1 || handler.ghostAirdrops() < 1) && guard < 64) {
            guard += 1;
            handler.list(guard, 0.001 ether);
            handler.donateToSink(4, 0.02 ether + 1);
            handler.keeperTryBuy();
            uint256 id = escrow.acquisitionCount();
            handler.commitByNonFlipper(1, id);
            handler.commit(id, bytes32(guard));
            handler.revealWrongSeed(id, bytes32("nope"));
            handler.reveal(guard, id, keccak256(abi.encode("entropy", guard)));
            handler.roll(3);
        }
        assertGt(handler.ghostBurns(), 0, "burn branch reached");
        assertGt(handler.ghostAirdrops(), 0, "airdrop branch reached");

        handler.relistAirdropped(0, 0.002 ether);
        handler.list(0, 0.001 ether);
        handler.donateToSink(4, 0.02 ether + 1);
        handler.keeperTryBuy();
        handler.timeoutBurn(0, escrow.acquisitionCount()); // too early: asserted inside
        handler.rollPastCommitTimeout(0);
        handler.timeoutBurn(0, escrow.acquisitionCount());
        assertGt(handler.ghostTimeouts(), 0, "timeout branch reached");

        handler.transferTokens(0, 9, 1e18); // to the burn address
        handler.transferTokens(2, 1, type(uint256).max);
        handler.evict(0, 2);
        handler.snapshot();

        // fill the registry, then exercise the displacement scan: a refused newcomer, an admitted one that
        // removes the smallest filler, a drained filler that the next scan must trim and remove, and an
        // actor whose balance is far above the bar
        handler.fillRegistry(0);
        assertEq(picker.holderCount(), 128, "registry filled");
        handler.displaceWithFiller(0); // at the bar: RegistryFull (asserted inside)
        handler.displaceWithFiller(type(uint256).max); // above it: displaces
        handler.drainFiller(3, 3); // amount % 3 == 0: the filler sells everything
        handler.trim(1, 5 + 3); // participant index 5 + 3 is filler 3: stale weight trimmed to zero
        handler.drainFiller(4, 3);
        handler.displaceWithFiller(type(uint256).max); // the scan trims filler 4 and removes a zero entry
        handler.enroll(2); // actor 2 was evicted above and now holds nothing: refused
        handler.evict(1, 5 + 4); // filler 4 holds nothing: evictable by anyone
        handler.fillRegistry(8); // refills the freed slot
        assertGe(handler.ghostDisplacements(), 2, "displacement path reached");
        assertGe(handler.ghostRefusedFull(), 1, "constant-gas refusal reached");
        handler.snapshot();
        handler.seedMore(0, 0.1 ether);
        handler.buyDirect(1, 5);
        handler.cancel(0);
        handler.rollPastMaturity(8);

        // fill the market, then evict through a cheaper listing and be refused with an equal one
        while (market.activeCount() < 64) {
            handler.list(guard, 0.02 ether);
        }
        handler.listNearFloor(1, 0); // strictly cheaper: evicts the dearest
        handler.list(2, 0.02 ether); // not cheaper: refused (asserted inside)
        assertGt(handler.ghostEvictions(), 0, "eviction path reached");

        invariant_sinkSpendStaysInsideThePriceBand();
        invariant_sinkBalanceIsReceivedMinusSpent();
        invariant_marketEthEqualsSellerCredits();
        invariant_marketListingsAreBackedAndCheapestIsMinimal();
        invariant_escrowCustodyMatchesOpenFlips();
        invariant_ethAndSupplyAreConserved();
        invariant_foreverLiquidityNeverDecreases();
        invariant_registryAndSnapshotsAreWellFormed();
    }
}
