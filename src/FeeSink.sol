// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFeeSink} from "./interfaces/IFeeSink.sol";
import {IMockBaazaar} from "./interfaces/IMockBaazaar.sol";
import {IFlipEscrow} from "./interfaces/IFlipEscrow.sol";
import {IGotchiEvents} from "./interfaces/IGotchiEvents.sol";
import {GotchiConfig} from "./GotchiConfig.sol";

/// @title FeeSink
/// @notice Receives the ETH the hook skims and, once it holds at least MIN_BUY_THRESHOLD, buys the cheapest
/// MockBaazaar listing and hands the NFT to FlipEscrow.
/// @dev Reentrancy: `tryBuy` is `nonReentrant`, follows checks-effects-interactions, and the only
/// ETH-bearing call it makes is to the immutable market. `receive()` only accounts. There is no sweep,
/// withdraw or treasury: every wei that arrives is spent on listings or waits for the next one.
/// Roles: `owner` (Ownable2Step) wires the hook once and may trigger `tryBuy`; the hook triggers `tryBuy`
/// after every swap. Nothing else is privileged.
contract FeeSink is IFeeSink, IGotchiEvents, Ownable2Step, ReentrancyGuard {
    /// @notice Purchases start once the balance reaches this.
    uint256 public constant MIN_BUY_THRESHOLD = GotchiConfig.MIN_BUY_THRESHOLD;

    IMockBaazaar public immutable MARKET;
    IFlipEscrow public immutable ESCROW;

    /// @notice The hook allowed to trigger purchases. Set once by the owner.
    address public hook;

    /// @notice Lifetime ETH received.
    uint256 public totalReceived;

    /// @notice Lifetime ETH spent on listings.
    uint256 public totalSpent;

    /// @notice Lifetime purchases.
    uint256 public buyCount;

    event FeeReceived(address indexed from, uint256 amount);
    event HookSet(address indexed hook);
    event BuyForwarded(uint256 indexed acquisitionId, uint256 indexed tokenId);

    error ZeroAddress();
    error AlreadySet();
    error NotTrigger();

    constructor(address owner_, address market, address escrow) Ownable(owner_) {
        if (market == address(0) || escrow == address(0)) revert ZeroAddress();
        MARKET = IMockBaazaar(market);
        ESCROW = IFlipEscrow(escrow);
    }

    /// @notice Accept skimmed fees (and any donation).
    receive() external payable {
        totalReceived += msg.value;
        emit FeeReceived(msg.sender, msg.value);
    }

    /// @notice One-shot wiring of the hook that may trigger purchases.
    function setHook(address hook_) external onlyOwner {
        if (hook_ == address(0)) revert ZeroAddress();
        if (hook != address(0)) revert AlreadySet();
        hook = hook_;
        emit HookSet(hook_);
    }

    /// @inheritdoc IFeeSink
    /// @dev Callable by the hook (automatically after each swap) or the owner (manual retry). Never
    /// reverts on a no-op so the hook's call cannot break a swap.
    function tryBuy() external nonReentrant returns (bool bought) {
        if (msg.sender != hook && msg.sender != owner()) revert NotTrigger();
        uint256 balance = address(this).balance;
        if (balance < MIN_BUY_THRESHOLD) return false;
        IMockBaazaar.Listing memory cheapest = MARKET.cheapest();
        if (!cheapest.active || cheapest.price > balance) return false;

        buyCount += 1;
        totalSpent += cheapest.price;
        emit BuyTriggered(cheapest.listingId, cheapest.price, cheapest.tokenId);

        uint256 tokenId = MARKET.buyCheapest{value: cheapest.price}(cheapest.listingId, address(ESCROW));
        uint256 acquisitionId = ESCROW.requestFlip(tokenId);
        emit BuyForwarded(acquisitionId, tokenId);
        return true;
    }

    /// @notice What `tryBuy` would do right now: whether a purchase is possible and the listing it targets.
    function pendingBuy() external view returns (bool possible, IMockBaazaar.Listing memory cheapest) {
        uint256 balance = address(this).balance;
        cheapest = MARKET.cheapest();
        possible = balance >= MIN_BUY_THRESHOLD && cheapest.active && cheapest.price <= balance;
    }
}
