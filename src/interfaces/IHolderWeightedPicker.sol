// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The part of HolderWeightedPicker FlipEscrow depends on.
interface IHolderWeightedPicker {
    /// @notice Freeze the balances of every enrolled holder into a new snapshot.
    function snapshot() external returns (uint256 snapshotId);

    /// @notice Deterministically select a holder from a snapshot. Returns (address(0), 0) when the snapshot
    /// has no eligible weight.
    function pick(uint256 snapshotId, uint256 randomWord) external view returns (address holder, uint256 weight);
}
