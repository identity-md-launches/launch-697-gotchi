// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title MockGotchiNFT
/// @notice A stand-in for Aavegotchi ERC-721s on Sepolia. Anyone can mint; that is the point of a mock.
/// @dev Real Aavegotchi / Diamond integration is a README TODO. Nothing in the system trusts minting.
contract MockGotchiNFT is ERC721 {
    /// @notice Next token id to mint (ids start at 1).
    uint256 public nextTokenId = 1;

    event Minted(uint256 indexed tokenId, address indexed to);

    constructor() ERC721("Mock Aavegotchi", "mGOTCHI") {}

    /// @notice Mint a mock gotchi to `to`. Permissionless.
    function mint(address to) external returns (uint256 tokenId) {
        tokenId = nextTokenId;
        nextTokenId = tokenId + 1;
        emit Minted(tokenId, to);
        _mint(to, tokenId);
    }
}
