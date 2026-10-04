// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHolderWeightedPicker} from "./interfaces/IHolderWeightedPicker.sol";
import {GotchiConfig} from "./GotchiConfig.sol";

/// @title HolderWeightedPicker
/// @notice Selects an airdrop recipient with probability proportional to $GOTCHI balance.
/// @dev Weighting model: SNAPSHOT, not live. Holders opt in with `enroll()` (self only, so pool, hook,
/// sink and other contracts are never candidates). When FlipEscrow commits to a flip it calls
/// `snapshot()`, which freezes every enrolled holder's current balance as a cumulative-weight table.
/// `pick()` later maps a random word onto that table, so balance moves after the commit cannot change
/// the outcome, and the random word is unknown when the table is frozen.
///
/// Exclusions: zero balances (weight 0, skipped), the burn/dead address and address(0) (cannot enrol),
/// balances below MIN_ENROLL_BALANCE (cannot enrol; anyone may `evict` a holder that dropped below it).
/// The registry is capped at MAX_HOLDERS so a snapshot is one bounded transaction. No admin role.
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

    address[] private _holders;
    mapping(address holder => uint256 indexPlusOne) private _holderIndex;
    mapping(uint256 snapshotId => SnapshotMeta meta) private _snapshotMeta;
    mapping(uint256 snapshotId => Entry[] entries) private _snapshotEntries;

    event HolderEnrolled(address indexed holder, uint256 balance);
    event HolderEvicted(address indexed holder, uint256 balance, address indexed by);
    event SnapshotTaken(uint256 indexed snapshotId, uint256 blockNumber, uint256 holders, uint256 totalWeight);

    error ZeroAddress();
    error ExcludedAddress(address holder);
    error AlreadyEnrolled(address holder);
    error NotEnrolled(address holder);
    error BelowMinimumBalance(uint256 balance, uint256 minimum);
    error StillEligible(address holder, uint256 balance);
    error RegistryFull();
    error UnknownSnapshot(uint256 snapshotId);

    constructor(address token) {
        if (token == address(0)) revert ZeroAddress();
        TOKEN = IERC20(token);
    }

    /// @notice Enrol the caller as an airdrop candidate. Requires MIN_ENROLL_BALANCE.
    function enroll() external nonReentrant {
        address holder = msg.sender;
        if (holder == BURN_ADDRESS) revert ExcludedAddress(holder);
        if (_holderIndex[holder] != 0) revert AlreadyEnrolled(holder);
        if (_holders.length >= MAX_HOLDERS) revert RegistryFull();
        uint256 balance = TOKEN.balanceOf(holder);
        if (balance < MIN_ENROLL_BALANCE) revert BelowMinimumBalance(balance, MIN_ENROLL_BALANCE);
        _holders.push(holder);
        _holderIndex[holder] = _holders.length;
        emit HolderEnrolled(holder, balance);
    }

    /// @notice Remove an enrolled holder whose balance fell below MIN_ENROLL_BALANCE. Anyone may call.
    function evict(address holder) external nonReentrant {
        uint256 indexPlusOne = _holderIndex[holder];
        if (indexPlusOne < 1) revert NotEnrolled(holder);
        uint256 balance = TOKEN.balanceOf(holder);
        if (balance >= MIN_ENROLL_BALANCE) revert StillEligible(holder, balance);
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _holders.length - 1;
        if (index != lastIndex) {
            address moved = _holders[lastIndex];
            _holders[index] = moved;
            _holderIndex[moved] = index + 1;
        }
        _holders.pop();
        delete _holderIndex[holder];
        emit HolderEvicted(holder, balance, msg.sender);
    }

    /// @inheritdoc IHolderWeightedPicker
    /// @dev Permissionless: a caller only spends their own gas to freeze a table nobody else references.
    function snapshot() external nonReentrant returns (uint256 snapshotId) {
        snapshotId = snapshotCount + 1;
        snapshotCount = snapshotId;
        Entry[] storage entries = _snapshotEntries[snapshotId];
        uint256 running = 0;
        uint256 count = _holders.length;
        for (uint256 i = 0; i < count; ++i) {
            address holder = _holders[i];
            uint256 weight = TOKEN.balanceOf(holder);
            if (weight > 0 && holder != BURN_ADDRESS) {
                running += weight;
                entries.push(Entry({holder: holder, cumulative: running.toUint96()}));
            }
        }
        _snapshotMeta[snapshotId] = SnapshotMeta({
            blockNumber: uint64(block.number), totalWeight: running.toUint96(), entryCount: entries.length.toUint32()
        });
        emit SnapshotTaken(snapshotId, block.number, entries.length, running);
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

    /// @notice Number of enrolled holders.
    function holderCount() external view returns (uint256) {
        return _holders.length;
    }

    /// @notice Enrolled holder at `index`.
    function holderAt(uint256 index) external view returns (address) {
        return _holders[index];
    }

    /// @notice Whether `holder` is enrolled.
    function isEnrolled(address holder) external view returns (bool) {
        return _holderIndex[holder] != 0;
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
