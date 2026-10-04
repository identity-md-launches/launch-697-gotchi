// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IGotchiEvents
/// @notice The UI-facing event surface of the $GOTCHI system. Indexed fields are stable; a future
/// cliff / flame / parachute UI subscribes to these and nothing else.
interface IGotchiEvents {
    /// @notice Emitted by GotchiFeeHook whenever ETH fees are skimmed from a swap into FeeSink.
    /// @param pool The v4 PoolManager that holds the pool (v4 pools have no address of their own).
    event FeesCollected(address indexed pool, uint256 amountEth);

    /// @notice Emitted by FeeSink when it buys the cheapest mock listing.
    event BuyTriggered(uint256 indexed listingId, uint256 priceEth, uint256 tokenId);

    /// @notice Emitted by FlipEscrow when an acquisition enters the flip queue.
    event FlipRequested(uint256 indexed acquisitionId, uint256 tokenId, bytes32 requestId);

    /// @notice Emitted by FlipEscrow when an acquisition is resolved (burned or airdropped).
    event FlipResolved(uint256 indexed acquisitionId, uint256 tokenId, bool burned, address indexed recipient);

    /// @notice Emitted by FlipEscrow after the NFT is sent to the burn address.
    event Burned(uint256 indexed tokenId, address indexed to);

    /// @notice Emitted by FlipEscrow after the NFT is airdropped to a weighted holder.
    event Airdropped(uint256 indexed tokenId, address indexed recipient, uint256 weight);

    /// @notice Emitted by MockBaazaar when a mock listing is created.
    event ListingMocked(uint256 indexed listingId, uint256 tokenId, uint256 price);
}
