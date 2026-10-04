// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHolderWeightedPicker} from "./interfaces/IHolderWeightedPicker.sol";
import {GotchiConfig} from "./GotchiConfig.sol";

/// @title HolderWeightedPicker
/// @notice Selects an airdrop recipient with probability proportional to $GOTCHI balance.
/// @dev Weighting model: SNAPSHOT of HELD balances, not live. Holders opt in with `enroll()` (self only,
/// so pool, hook, sink and other contracts are never candidates), which records their balance at that
/// block. A holder's weight in a snapshot is `min(recorded balance, balance when the snapshot is taken)`:
/// tokens bought after enrolling add nothing until the holder calls `refresh()`, and tokens sold count
/// against them at once. When FlipEscrow commits to a flip it calls `snapshotFor(purchase block)`, which
/// only counts holders whose recorded balance was in place ENROLL_MATURITY_BLOCKS before the NFT was
/// bought. Buying tokens around the commit transaction therefore buys no odds: weight has to be recorded
/// and held from well before the purchase until the commit. `pick()` later maps a random word onto the
/// frozen table, so balance moves after the commit cannot change the outcome either.
///
/// Exclusions: zero balances (weight 0, skipped), the burn/dead address and address(0) (cannot enrol),
/// balances below MIN_ENROLL_BALANCE (cannot enrol; anyone may `evict` a holder that dropped below it).
///
/// Capacity: the registry is capped at MAX_HOLDERS so a snapshot is one bounded transaction. The cap is
/// not first-come: when the registry is full, a caller whose balance is strictly larger than the smallest
/// recorded weight displaces that entry, so the registry converges on the largest opted-in holders and
/// filling it with dust addresses locks nobody out. The smallest entry is tracked incrementally, so a
/// refused enrolment costs a constant amount of gas. A recorded weight cannot be kept above the balance
/// behind it: anyone may `trim` an entry down to its holder's live balance, which also makes it
/// displaceable. A displaced holder may enrol again whenever their balance beats the then-smallest
/// weight (their maturity restarts). No admin role.
contract HolderWeightedPicker is IHolderWeightedPicker, ReentrancyGuard {
    using SafeCast for uint256;

    struct Entry {
        address holder;
        uint96 cumulative;
    }

    struct SnapshotMeta {
        uint64 blockNumber;
        uint96 totalWeight;
        uint32 entryCount;
    }

    /// @notice The token whose balances weight the pick.
    IERC20 public immutable TOKEN;

    /// @notice Burned NFTs go here and this address can never be a recipient.
    address public constant BURN_ADDRESS = GotchiConfig.BURN_ADDRESS;

    /// @notice Minimum balance to enrol.
    uint256 public constant MIN_ENROLL_BALANCE = GotchiConfig.MIN_ENROLL_BALANCE;

    /// @notice Registry cap.
    uint256 public constant MAX_HOLDERS = GotchiConfig.MAX_HOLDERS;

    /// @notice Number of snapshots taken (ids start at 1).
    uint256 public snapshotCount;

    struct Registration {
        uint96 weight;
        uint64 sinceBlock;
        uint32 indexPlusOne;
    }

    /// @notice Blocks a recorded weight must predate a reference block to count in `snapshotFor`.
    uint256 public constant ENROLL_MATURITY_BLOCKS = GotchiConfig.ENROLL_MATURITY_BLOCKS;

    address[] private _holders;

    /// @dev The enrolled holder with the smallest recorded weight; address(0) when nobody is enrolled.
    address private _lowest;

    mapping(address holder => Registration registration) private _registrations;
    mapping(uint256 snapshotId => SnapshotMeta meta) private _snapshotMeta;
    mapping(uint256 snapshotId => Entry[] entries) private _snapshotEntries;

    event HolderEnrolled(address indexed holder, uint256 balance);
    event HolderEvicted(address indexed holder, uint256 balance, address indexed by);
    event HolderDisplaced(address indexed holder, uint256 weight, address indexed by);
    event HolderRefreshed(address indexed holder, uint256 weight, uint256 sinceBlock);
    event SnapshotTaken(uint256 indexed snapshotId, uint256 blockNumber, uint256 holders, uint256 totalWeight);

    error ZeroAddress();
    error ExcludedAddress(address holder);
    error AlreadyEnrolled(address holder);
    error NotEnrolled(address holder);
    error BelowMinimumBalance(uint256 balance, uint256 minimum);
    error StillEligible(address holder, uint256 balance);
    error RegistryFull();
    error NothingToTrim(address holder, uint256 balance);
    error UnknownSnapshot(uint256 snapshotId);

    constructor(address token) {
        if (token == address(0)) revert ZeroAddress();
        TOKEN = IERC20(token);
    }

    /// @notice Enrol the caller as an airdrop candidate and record their balance as their weight.
    /// Requires MIN_ENROLL_BALANCE. When the registry is full the caller must hold strictly more than the
    /// smallest current weight, and takes that entry's place.
    function enroll() external nonReentrant {
        address holder = msg.sender;
        if (holder == BURN_ADDRESS) revert ExcludedAddress(holder);
        if (_registrations[holder].indexPlusOne != 0) revert AlreadyEnrolled(holder);
        uint256 balance = TOKEN.balanceOf(holder);
        if (balance < MIN_ENROLL_BALANCE) revert BelowMinimumBalance(balance, MIN_ENROLL_BALANCE);
        if (_holders.length >= MAX_HOLDERS) {
            address smallest = _lowest;
            uint256 smallestWeight = _registrations[smallest].weight;
            if (balance <= smallestWeight) revert RegistryFull();
            _remove(smallest);
            emit HolderDisplaced(smallest, smallestWeight, holder);
        }
        _holders.push(holder);
        _registrations[holder] = Registration({
            weight: balance.toUint96(), sinceBlock: uint64(block.number), indexPlusOne: _holders.length.toUint32()
        });
        address lowest = _lowest;
        if (lowest == address(0) || balance < _registrations[lowest].weight) _lowest = holder;
        emit HolderEnrolled(holder, balance);
    }

    /// @notice Re-record the caller's balance as their weight. Raising the weight restarts its maturity
    /// (the new weight counts only for purchases ENROLL_MATURITY_BLOCKS later); lowering it does not.
    function refresh() external nonReentrant {
        address holder = msg.sender;
        Registration storage registration = _registrations[holder];
        if (registration.indexPlusOne < 1) revert NotEnrolled(holder);
        uint256 balance = TOKEN.balanceOf(holder);
        if (balance < MIN_ENROLL_BALANCE) revert BelowMinimumBalance(balance, MIN_ENROLL_BALANCE);
        if (balance > registration.weight) registration.sinceBlock = uint64(block.number);
        registration.weight = balance.toUint96();
        _lowest = _findLowest();
        emit HolderRefreshed(holder, balance, registration.sinceBlock);
    }

    /// @notice Lower an enrolled holder's recorded weight to their live balance. Anyone may call.
    /// @dev Never raises a weight and never touches its maturity. Keeps recorded weights honest, so an
    /// address that enrolled with a large balance and sold cannot hold a registry slot against others.
    function trim(address holder) external nonReentrant {
        if (holder == address(0)) revert ZeroAddress();
        Registration storage registration = _registrations[holder];
        if (registration.indexPlusOne < 1) revert NotEnrolled(holder);
        uint256 balance = TOKEN.balanceOf(holder);
        if (balance >= registration.weight) revert NothingToTrim(holder, balance);
        registration.weight = balance.toUint96();
        if (balance < _registrations[_lowest].weight) _lowest = holder;
        emit HolderRefreshed(holder, balance, registration.sinceBlock);
    }

    /// @notice Remove an enrolled holder whose balance fell below MIN_ENROLL_BALANCE. Anyone may call.
    function evict(address holder) external nonReentrant {
        if (_registrations[holder].indexPlusOne < 1) revert NotEnrolled(holder);
        uint256 balance = TOKEN.balanceOf(holder);
        if (balance >= MIN_ENROLL_BALANCE) revert StillEligible(holder, balance);
        _remove(holder);
        emit HolderEvicted(holder, balance, msg.sender);
    }

    /// @notice Freeze the current weight of every enrolled holder, whatever its age.
    /// @dev Permissionless: a caller only spends their own gas to freeze a table nobody else references.
    function snapshot() external nonReentrant returns (uint256 snapshotId) {
        return _snapshot(type(uint256).max);
    }

    /// @inheritdoc IHolderWeightedPicker
    /// @dev Permissionless for the same reason as `snapshot`. FlipEscrow passes the block of the NFT
    /// purchase, so only weight recorded ENROLL_MATURITY_BLOCKS before that purchase counts.
    function snapshotFor(uint256 referenceBlock) external nonReentrant returns (uint256 snapshotId) {
        return _snapshot(referenceBlock);
    }

    /// @notice The weight `holder` would carry in a snapshot taken now for `referenceBlock`.
    function weightOf(address holder, uint256 referenceBlock) external view returns (uint256) {
        return _weight(holder, referenceBlock);
    }

    /// @inheritdoc IHolderWeightedPicker
    /// @dev `randomWord % totalWeight` selects a point on the cumulative table; the first entry whose
    /// cumulative weight exceeds it wins. Modulo bias is negligible for a 256-bit word against weights
    /// bounded by the token supply.
    function pick(uint256 snapshotId, uint256 randomWord) external view returns (address holder, uint256 weight) {
        if (snapshotId < 1 || snapshotId > snapshotCount) revert UnknownSnapshot(snapshotId);
        Entry[] storage entries = _snapshotEntries[snapshotId];
        uint256 count = entries.length;
        if (count < 1) return (address(0), 0);
        uint256 total = _snapshotMeta[snapshotId].totalWeight;
        uint256 target = randomWord % total;
        uint256 low = 0;
        uint256 high = count - 1;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (entries[mid].cumulative > target) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        uint256 previous = low > 0 ? entries[low - 1].cumulative : 0;
        return (entries[low].holder, uint256(entries[low].cumulative) - previous);
    }

    function _snapshot(uint256 referenceBlock) private returns (uint256 snapshotId) {
        snapshotId = snapshotCount + 1;
        snapshotCount = snapshotId;
        uint256 running = 0;
        uint256 entryCount = 0;
        uint256 count = _holders.length;
        for (uint256 i = 0; i < count; ++i) {
            address holder = _holders[i];
            uint256 weight = _weight(holder, referenceBlock);
            if (weight > 0) {
                running += weight;
                entryCount += 1;
                _snapshotEntries[snapshotId].push(Entry({holder: holder, cumulative: running.toUint96()}));
            }
        }
        _snapshotMeta[snapshotId] = SnapshotMeta({
            blockNumber: uint64(block.number), totalWeight: running.toUint96(), entryCount: entryCount.toUint32()
        });
        emit SnapshotTaken(snapshotId, block.number, entryCount, running);
    }

    /// @dev min(recorded weight, live balance), or 0 while the recorded weight is younger than
    /// ENROLL_MATURITY_BLOCKS at `referenceBlock`. `type(uint256).max` disables the age test.
    function _weight(address holder, uint256 referenceBlock) private view returns (uint256) {
        Registration memory registration = _registrations[holder];
        if (registration.indexPlusOne < 1) return 0;
        if (referenceBlock != type(uint256).max) {
            if (uint256(registration.sinceBlock) + ENROLL_MATURITY_BLOCKS > referenceBlock) return 0;
        }
        uint256 balance = TOKEN.balanceOf(holder);
        return balance < registration.weight ? balance : registration.weight;
    }

    /// @dev Remove `holder`, keeping `_lowest` correct.
    function _remove(address holder) private {
        uint256 index = uint256(_registrations[holder].indexPlusOne) - 1;
        uint256 lastIndex = _holders.length - 1;
        if (index != lastIndex) {
            address moved = _holders[lastIndex];
            _holders[index] = moved;
            _registrations[moved].indexPlusOne = (index + 1).toUint32();
        }
        _holders.pop();
        delete _registrations[holder];
        if (holder == _lowest) _lowest = _findLowest();
    }

    /// @dev The enrolled holder with the smallest recorded weight (first on a tie), address(0) if none.
    /// Reads storage only; runs on the paths that change the registry, never on a refused enrolment.
    function _findLowest() private view returns (address lowest) {
        uint256 lowestWeight = type(uint256).max;
        uint256 count = _holders.length;
        for (uint256 i = 0; i < count; ++i) {
            address holder = _holders[i];
            uint256 weight = _registrations[holder].weight;
            if (weight < lowestWeight) {
                lowestWeight = weight;
                lowest = holder;
            }
        }
    }

    /// @notice Number of enrolled holders.
    function holderCount() external view returns (uint256) {
        return _holders.length;
    }

    /// @notice Enrolled holder at `index`.
    function holderAt(uint256 index) external view returns (address) {
        return _holders[index];
    }

    /// @notice The enrolled holder with the smallest recorded weight: the entry a larger newcomer displaces
    /// when the registry is full. address(0) when nobody is enrolled.
    function lowestHolder() external view returns (address) {
        return _lowest;
    }

    /// @notice Whether `holder` is enrolled.
    function isEnrolled(address holder) external view returns (bool) {
        return _registrations[holder].indexPlusOne != 0;
    }

    /// @notice The recorded weight of `holder` and the block it was last raised.
    function registrationOf(address holder) external view returns (uint256 weight, uint256 sinceBlock) {
        Registration memory registration = _registrations[holder];
        return (registration.weight, registration.sinceBlock);
    }

    /// @notice Snapshot metadata.
    function snapshotInfo(uint256 snapshotId) external view returns (SnapshotMeta memory) {
        return _snapshotMeta[snapshotId];
    }

    /// @notice Entry `index` of a snapshot (holder and cumulative weight).
    function snapshotEntry(uint256 snapshotId, uint256 index) external view returns (Entry memory) {
        return _snapshotEntries[snapshotId][index];
    }
}
