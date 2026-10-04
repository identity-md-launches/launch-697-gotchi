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
/// Listings are bounded by MAX_ACTIVE_LISTINGS so the `cheapest()` scan has a hard gas ceiling, and each
/// active listing is one packed storage word (price, then id), so a full scan reads 64 slots.
/// Nobody can freeze the market: when it is full, a strictly cheaper listing evicts the most expensive
/// one (its NFT goes back to its seller), so the slots always belong to the cheapest offers. Prices
/// below MIN_LIST_PRICE are refused so dust listings cannot turn every swap into a purchase.
/// Trust: the mock collection mints for free, so a listing proves nothing about value. FeeSink bounds
/// what it pays per NFT (MIN_LIST_PRICE to MAX_BUY_PRICE); within that band any seller can be paid.
/// No admin role.
contract MockBaazaar is IMockBaazaar, IGotchiEvents, ReentrancyGuard {
    /// @notice The mock NFT collection traded here.
    IERC721 public immutable NFT;

    /// @notice Hard cap on simultaneously active listings.
    uint256 public constant MAX_ACTIVE_LISTINGS = GotchiConfig.MAX_ACTIVE_LISTINGS;

    /// @notice Lowest accepted listing price.
    uint256 public constant MIN_LIST_PRICE = GotchiConfig.MIN_LIST_PRICE;

    /// @dev Listing ids occupy the low 64 bits of a packed key, the price the 192 bits above them, so
    /// comparing keys orders by price and then by listing id.
    uint256 private constant ID_BITS = 64;
    uint256 private constant ID_MASK = (1 << ID_BITS) - 1;
    uint256 private constant MAX_PRICE = type(uint192).max;

    /// @notice Next listing id (ids start at 1).
    uint256 public nextListingId = 1;

    /// @notice ETH credited to sellers, withdrawable with `withdrawProceeds`.
    mapping(address seller => uint256 amount) public proceeds;

    mapping(uint256 listingId => Listing listing) private _listings;
    uint256[] private _activeKeys;
    mapping(uint256 listingId => uint256 indexPlusOne) private _activeIndex;

    event ListingCancelled(uint256 indexed listingId, uint256 tokenId);
    event ListingEvicted(uint256 indexed listingId, uint256 tokenId, uint256 indexed byListingId);
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
    /// @dev When MAX_ACTIVE_LISTINGS are active, the new listing must be strictly cheaper than the most
    /// expensive one, which is then evicted and its NFT returned to its seller.
    function list(uint256 tokenId, uint256 price) external nonReentrant returns (uint256 listingId) {
        if (price < MIN_LIST_PRICE || price > MAX_PRICE) revert InvalidPrice();
        listingId = nextListingId;
        nextListingId = listingId + 1;
        uint256 evictedTokenId = 0;
        address evictedSeller = address(0);
        if (_activeKeys.length >= MAX_ACTIVE_LISTINGS) {
            uint256 evictedId = _mostExpensiveId();
            Listing memory evicted = _listings[evictedId];
            if (price >= evicted.price) revert MarketFull();
            _deactivate(evictedId);
            evictedTokenId = evicted.tokenId;
            evictedSeller = evicted.seller;
            emit ListingEvicted(evictedId, evictedTokenId, listingId);
        }
        _listings[listingId] =
            Listing({listingId: listingId, tokenId: tokenId, price: price, seller: msg.sender, active: true});
        _activeKeys.push((price << ID_BITS) | listingId);
        _activeIndex[listingId] = _activeKeys.length;
        emit ListingMocked(listingId, tokenId, price);
        NFT.transferFrom(msg.sender, address(this), tokenId);
        if (evictedSeller != address(0)) NFT.transferFrom(address(this), evictedSeller, evictedTokenId);
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
        uint256 count = _activeKeys.length;
        if (count < 1) return Listing({listingId: 0, tokenId: 0, price: 0, seller: address(0), active: false});
        uint256 lowest = _activeKeys[0];
        for (uint256 i = 1; i < count; ++i) {
            uint256 candidate = _activeKeys[i];
            if (candidate < lowest) lowest = candidate;
        }
        return _listings[lowest & ID_MASK];
    }

    /// @notice A listing by id (inactive listings keep their data with `active == false`).
    function getListing(uint256 listingId) external view returns (Listing memory) {
        return _listings[listingId];
    }

    /// @notice Number of active listings.
    function activeCount() external view returns (uint256) {
        return _activeKeys.length;
    }

    /// @notice Active listing id at position `index`.
    function activeIdAt(uint256 index) external view returns (uint256) {
        return _activeKeys[index] & ID_MASK;
    }

    /// @dev Highest price among the active listings, the newest of them on a tie. Only called when full.
    function _mostExpensiveId() private view returns (uint256) {
        uint256 count = _activeKeys.length;
        uint256 highest = _activeKeys[0];
        for (uint256 i = 1; i < count; ++i) {
            uint256 candidate = _activeKeys[i];
            if (candidate > highest) highest = candidate;
        }
        return highest & ID_MASK;
    }

    function _deactivate(uint256 listingId) private {
        _listings[listingId].active = false;
        uint256 index = _activeIndex[listingId] - 1;
        uint256 lastIndex = _activeKeys.length - 1;
        if (index != lastIndex) {
            uint256 movedKey = _activeKeys[lastIndex];
            _activeKeys[index] = movedKey;
            _activeIndex[movedKey & ID_MASK] = index + 1;
        }
        _activeKeys.pop();
        delete _activeIndex[listingId];
    }
}
