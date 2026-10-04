// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The part of HolderWeightedPicker FlipEscrow depends on.
interface IHolderWeightedPicker {
    /// @notice Freeze the weights of the enrolled holders into a new snapshot, counting only weight that
    /// was recorded at least the picker's maturity period before `referenceBlock`.
    function snapshotFor(uint256 referenceBlock) external returns (uint256 snapshotId);

    /// @notice Deterministically select a holder from a snapshot. Returns (address(0), 0) when the snapshot
    /// has no eligible weight.
    function pick(uint256 snapshotId, uint256 randomWord) external view returns (address holder, uint256 weight);
}
