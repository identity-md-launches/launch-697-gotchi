// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The part of MockBaazaar FeeSink depends on.
interface IMockBaazaar {
    struct Listing {
        uint256 listingId;
        uint256 tokenId;
        uint256 price;
        address seller;
        bool active;
    }

    /// @notice The cheapest active listing (lowest price, then lowest listing id). `active == false` when
    /// nothing is listed.
    function cheapest() external view returns (Listing memory best);

    /// @notice Buy the cheapest listing, which must still be `expectedListingId`, delivering the NFT to `to`.
    /// `msg.value` must be at least the price; everything sent is credited to the seller.
    function buyCheapest(uint256 expectedListingId, address to) external payable returns (uint256 tokenId);
}
