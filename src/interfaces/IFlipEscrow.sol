// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The part of FlipEscrow FeeSink depends on.
interface IFlipEscrow {
    /// @notice Register an NFT already held by the escrow for a 50/50 flip. Only the configured FeeSink.
    function requestFlip(uint256 tokenId) external returns (uint256 acquisitionId);
}
