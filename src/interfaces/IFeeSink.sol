// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The part of FeeSink the hook depends on.
interface IFeeSink {
    /// @notice Attempt a purchase of the cheapest listing. Returns false (without reverting) when the
    /// balance is below threshold, there is no listing, or the cheapest listing costs more than the balance.
    function tryBuy() external returns (bool bought);
}
