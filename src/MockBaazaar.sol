// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMockBaazaar} from "./interfaces/IMockBaazaar.sol";
import {IGotchiEvents} from "./interfaces/IGotchiEvents.sol";
import {GotchiConfig} from "./GotchiConfig.sol";

/// @title MockBaazaar
/// @notice A minimal ETH-priced ERC-721 marketplace that mimics the Aavegotchi Baazaar for Sepolia.
/// @dev Sellers escrow the NFT here while listed. Buyers pay ETH; proceeds are credited to the seller and
/// withdrawn with `withdrawProceeds` (pull payments, so a reverting seller can never block a purchase).
/// Listings are bounded by MAX_ACTIVE_LISTINGS so the `cheapest()` scan has a hard gas ceiling.
/// No admin role.
contract MockBaazaar is IMockBaazaar, IGotchiEvents, ReentrancyGuard {
    /// @notice The mock NFT collection traded here.
    IERC721 public immutable NFT;

    /// @notice Hard cap on simultaneously active listings.
    uint256 public constant MAX_ACTIVE_LISTINGS = GotchiConfig.MAX_ACTIVE_LISTINGS;

    /// @notice Next listing id (ids start at 1).
    uint256 public nextListingId = 1;

    /// @notice ETH credited to sellers, withdrawable with `withdrawProceeds`.
    mapping(address seller => uint256 amount) public proceeds;

    mapping(uint256 listingId => Listing listing) private _listings;
    uint256[] private _activeIds;
    mapping(uint256 listingId => uint256 indexPlusOne) private _activeIndex;

    event ListingCancelled(uint256 indexed listingId, uint256 tokenId);
    event ListingSold(uint256 indexed listingId, uint256 tokenId, uint256 price, address indexed buyer, address to);
    event ProceedsWithdrawn(address indexed seller, uint256 amount);

    error ZeroAddress();
    error InvalidPrice();
    error MarketFull();
    error NoListings();
    error NotSeller();
    error CheapestChanged(uint256 expected, uint256 actual);
    error InsufficientPayment(uint256 price, uint256 paid);
    error NothingToWithdraw();
    error WithdrawFailed();

    constructor(address nft) {
        if (nft == address(0)) revert ZeroAddress();
        NFT = IERC721(nft);
    }

    /// @notice List `tokenId` for `price` wei. The caller must own it and have approved this contract.
    function list(uint256 tokenId, uint256 price) external nonReentrant returns (uint256 listingId) {
        if (price < 1) revert InvalidPrice();
        if (_activeIds.length >= MAX_ACTIVE_LISTINGS) revert MarketFull();
        listingId = nextListingId;
        nextListingId = listingId + 1;
        _listings[listingId] =
            Listing({listingId: listingId, tokenId: tokenId, price: price, seller: msg.sender, active: true});
        _activeIds.push(listingId);
        _activeIndex[listingId] = _activeIds.length;
        emit ListingMocked(listingId, tokenId, price);
        NFT.transferFrom(msg.sender, address(this), tokenId);
    }

    /// @notice Cancel an active listing and take the NFT back. Seller only.
    function cancel(uint256 listingId) external nonReentrant {
        Listing memory listing = _listings[listingId];
        if (!listing.active) revert NoListings();
        if (listing.seller != msg.sender) revert NotSeller();
        _deactivate(listingId);
        emit ListingCancelled(listingId, listing.tokenId);
        NFT.transferFrom(address(this), msg.sender, listing.tokenId);
    }

    /// @inheritdoc IMockBaazaar
    function buyCheapest(uint256 expectedListingId, address to)
        external
        payable
        nonReentrant
        returns (uint256 tokenId)
    {
        if (to == address(0)) revert ZeroAddress();
        Listing memory best = cheapest();
        if (!best.active) revert NoListings();
        if (best.listingId != expectedListingId) revert CheapestChanged(expectedListingId, best.listingId);
        if (msg.value < best.price) revert InsufficientPayment(best.price, msg.value);
        _deactivate(best.listingId);
        proceeds[best.seller] += msg.value;
        emit ListingSold(best.listingId, best.tokenId, best.price, msg.sender, to);
        NFT.transferFrom(address(this), to, best.tokenId);
        return best.tokenId;
    }

    /// @notice Withdraw ETH credited from sales.
    function withdrawProceeds() external nonReentrant {
        uint256 amount = proceeds[msg.sender];
        if (amount < 1) revert NothingToWithdraw();
        proceeds[msg.sender] = 0;
        emit ProceedsWithdrawn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert WithdrawFailed();
    }

    /// @inheritdoc IMockBaazaar
    function cheapest() public view returns (Listing memory best) {
        best = Listing({listingId: 0, tokenId: 0, price: 0, seller: address(0), active: false});
        uint256 count = _activeIds.length;
        for (uint256 i = 0; i < count; ++i) {
            Listing memory candidate = _listings[_activeIds[i]];
            if (
                !best.active || candidate.price < best.price
                    || (candidate.price == best.price && candidate.listingId < best.listingId)
            ) {
                best = candidate;
            }
        }
    }

    /// @notice A listing by id (inactive listings keep their data with `active == false`).
    function getListing(uint256 listingId) external view returns (Listing memory) {
        return _listings[listingId];
    }

    /// @notice Number of active listings.
    function activeCount() external view returns (uint256) {
        return _activeIds.length;
    }

    /// @notice Active listing id at position `index`.
    function activeIdAt(uint256 index) external view returns (uint256) {
        return _activeIds[index];
    }

    function _deactivate(uint256 listingId) private {
        _listings[listingId].active = false;
        uint256 index = _activeIndex[listingId] - 1;
        uint256 lastIndex = _activeIds.length - 1;
        if (index != lastIndex) {
            uint256 movedId = _activeIds[lastIndex];
            _activeIds[index] = movedId;
            _activeIndex[movedId] = index + 1;
        }
        _activeIds.pop();
        delete _activeIndex[listingId];
    }
}
