// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFlipEscrow} from "./interfaces/IFlipEscrow.sol";
import {IHolderWeightedPicker} from "./interfaces/IHolderWeightedPicker.sol";
import {IGotchiEvents} from "./interfaces/IGotchiEvents.sol";
import {GotchiConfig} from "./GotchiConfig.sol";

/// @title FlipEscrow
/// @notice Holds every NFT FeeSink buys and resolves it 50/50: burn, or airdrop to a $GOTCHI holder
/// selected by HolderWeightedPicker.
/// @dev Randomness is a commit-reveal MOCK, not production randomness:
///   1. `requestFlip` (FeeSink only) registers the NFT.
///   2. The flipper commits `keccak256(abi.encode(seed))`; the commit also freezes the holder snapshot,
///      counting only weight recorded ENROLL_MATURITY_BLOCKS before the purchase (see the picker).
///   3. From `commitBlock + REVEAL_DELAY_BLOCKS` the seed is revealed by anyone who knows it. The random
///      word is `keccak256(seed, blockhash(commitBlock + 1), acquisitionId, tokenId)`: the flipper cannot
///      know the block hash at commit time and a block builder does not know the seed.
///   4. Missing the reveal window, or never committing, lets anyone time the flip out, which burns.
/// A flipper who dislikes an outcome can therefore only force the burn branch, never the airdrop. A
/// Chainlink VRF subscription replaces steps 2-3 later (README TODO); the event surface does not change.
contract FlipEscrow is IFlipEscrow, IGotchiEvents, Ownable2Step, ReentrancyGuard {
    enum Status {
        None,
        Pending,
        Committed,
        Resolved
    }

    struct Acquisition {
        uint256 tokenId;
        uint256 snapshotId;
        bytes32 requestId;
        bytes32 commitment;
        uint64 requestBlock;
        uint64 commitBlock;
        Status status;
        bool burned;
        address recipient;
    }

    IERC721 public immutable NFT;
    IHolderWeightedPicker public immutable PICKER;

    uint256 public constant FLIP_BURN_BPS = GotchiConfig.FLIP_BURN_BPS;
    address public constant BURN_ADDRESS = GotchiConfig.BURN_ADDRESS;
    uint256 public constant REVEAL_DELAY_BLOCKS = GotchiConfig.REVEAL_DELAY_BLOCKS;
    uint256 public constant REVEAL_WINDOW_BLOCKS = GotchiConfig.REVEAL_WINDOW_BLOCKS;
    uint256 public constant COMMIT_TIMEOUT_BLOCKS = GotchiConfig.COMMIT_TIMEOUT_BLOCKS;

    /// @dev The top 128 bits of the random word, scaled by the bps denominator, below this burns. Pure
    /// multiplication: no modulo, no division, no rounding bias (exact for FLIP_BURN_BPS = 5000).
    uint256 public constant BURN_THRESHOLD = GotchiConfig.FLIP_BURN_BPS << 128;

    /// @notice The only address allowed to call `requestFlip`. Set once by the owner.
    address public feeSink;

    /// @notice The role that commits seeds. Defaults to the owner; the owner may rotate it.
    address public flipper;

    /// @notice Number of acquisitions (ids start at 1).
    uint256 public acquisitionCount;

    mapping(uint256 acquisitionId => Acquisition acquisition) private _acquisitions;

    /// @notice The open (unresolved) acquisition id for a token, 0 when none.
    mapping(uint256 tokenId => uint256 acquisitionId) public openAcquisitionOf;

    event FeeSinkSet(address indexed feeSink);
    event FlipperSet(address indexed flipper);
    event FlipCommitted(uint256 indexed acquisitionId, bytes32 commitment, uint256 commitBlock, uint256 snapshotId);
    event FlipTimedOut(uint256 indexed acquisitionId, uint256 tokenId);

    error ZeroAddress();
    error AlreadySet();
    error NotFeeSink();
    error NotFlipper();
    error NotEscrowed(uint256 tokenId);
    error AlreadyTracked(uint256 tokenId);
    error WrongStatus(uint256 acquisitionId, Status status);
    error EmptyCommitment();
    error RevealTooEarly(uint256 acquisitionId, uint256 revealFrom);
    error RevealTooLate(uint256 acquisitionId, uint256 revealUntil);
    error WrongSeed(uint256 acquisitionId);
    error EntropyUnavailable(uint256 acquisitionId);
    error NotTimedOut(uint256 acquisitionId);

    constructor(address owner_, address nft, address picker) Ownable(owner_) {
        if (owner_ == address(0) || nft == address(0) || picker == address(0)) revert ZeroAddress();
        NFT = IERC721(nft);
        PICKER = IHolderWeightedPicker(picker);
        flipper = owner_;
        emit FlipperSet(owner_);
    }

    modifier onlyFlipper() {
        if (msg.sender != flipper) revert NotFlipper();
        _;
    }

    /// @notice One-shot wiring of the FeeSink that may register acquisitions.
    function setFeeSink(address feeSink_) external onlyOwner {
        if (feeSink_ == address(0)) revert ZeroAddress();
        if (feeSink != address(0)) revert AlreadySet();
        feeSink = feeSink_;
        emit FeeSinkSet(feeSink_);
    }

    /// @notice Rotate the flipper role.
    function setFlipper(address flipper_) external onlyOwner {
        if (flipper_ == address(0)) revert ZeroAddress();
        flipper = flipper_;
        emit FlipperSet(flipper_);
    }

    /// @inheritdoc IFlipEscrow
    function requestFlip(uint256 tokenId) external nonReentrant returns (uint256 acquisitionId) {
        if (msg.sender != feeSink) revert NotFeeSink();
        if (openAcquisitionOf[tokenId] != 0) revert AlreadyTracked(tokenId);
        if (NFT.ownerOf(tokenId) != address(this)) revert NotEscrowed(tokenId);
        acquisitionId = acquisitionCount + 1;
        acquisitionCount = acquisitionId;
        bytes32 requestId = keccak256(abi.encode(block.chainid, address(this), acquisitionId, tokenId));
        Acquisition storage acquisition = _acquisitions[acquisitionId];
        acquisition.tokenId = tokenId;
        acquisition.requestId = requestId;
        acquisition.requestBlock = uint64(block.number);
        acquisition.status = Status.Pending;
        openAcquisitionOf[tokenId] = acquisitionId;
        emit FlipRequested(acquisitionId, tokenId, requestId);
    }

    /// @notice Commit to a secret seed for a pending acquisition and freeze the holder snapshot.
    function commit(uint256 acquisitionId, bytes32 commitment) external nonReentrant onlyFlipper {
        Acquisition storage acquisition = _acquisitions[acquisitionId];
        if (acquisition.status != Status.Pending) revert WrongStatus(acquisitionId, acquisition.status);
        if (commitment == bytes32(0)) revert EmptyCommitment();
        acquisition.status = Status.Committed;
        acquisition.commitment = commitment;
        acquisition.commitBlock = uint64(block.number);
        uint256 snapshotId = PICKER.snapshotFor(acquisition.requestBlock);
        acquisition.snapshotId = snapshotId;
        emit FlipCommitted(acquisitionId, commitment, block.number, snapshotId);
    }

    /// @notice Reveal the seed and resolve the flip. Anyone who knows the seed may call.
    function reveal(uint256 acquisitionId, bytes32 seed) external nonReentrant {
        Acquisition storage acquisition = _acquisitions[acquisitionId];
        if (acquisition.status != Status.Committed) revert WrongStatus(acquisitionId, acquisition.status);
        if (keccak256(abi.encode(seed)) != acquisition.commitment) revert WrongSeed(acquisitionId);
        uint256 revealFrom = uint256(acquisition.commitBlock) + REVEAL_DELAY_BLOCKS;
        uint256 revealUntil = revealFrom + REVEAL_WINDOW_BLOCKS;
        if (block.number < revealFrom) revert RevealTooEarly(acquisitionId, revealFrom);
        if (block.number > revealUntil) revert RevealTooLate(acquisitionId, revealUntil);
        bytes32 entropy = blockhash(uint256(acquisition.commitBlock) + 1);
        if (entropy == bytes32(0)) revert EntropyUnavailable(acquisitionId);
        uint256 randomWord = uint256(keccak256(abi.encode(seed, entropy, acquisitionId, acquisition.tokenId)));

        bool burned = burnsFor(randomWord);
        address recipient = address(0);
        uint256 weight = 0;
        if (!burned) {
            (recipient, weight) = PICKER.pick(acquisition.snapshotId, randomWord);
            if (recipient == address(0)) burned = true;
        }
        _resolve(acquisitionId, acquisition, burned, recipient, weight);
    }

    /// @notice Burn an acquisition whose flipper never committed, or never revealed in time. Anyone.
    function timeoutBurn(uint256 acquisitionId) external nonReentrant {
        Acquisition storage acquisition = _acquisitions[acquisitionId];
        if (acquisition.status == Status.Pending) {
            if (block.number <= uint256(acquisition.requestBlock) + COMMIT_TIMEOUT_BLOCKS) {
                revert NotTimedOut(acquisitionId);
            }
        } else if (acquisition.status == Status.Committed) {
            uint256 revealUntil = uint256(acquisition.commitBlock) + REVEAL_DELAY_BLOCKS + REVEAL_WINDOW_BLOCKS;
            if (block.number <= revealUntil) revert NotTimedOut(acquisitionId);
        } else {
            revert WrongStatus(acquisitionId, acquisition.status);
        }
        emit FlipTimedOut(acquisitionId, acquisition.tokenId);
        _resolve(acquisitionId, acquisition, true, address(0), 0);
    }

    /// @notice Full acquisition record.
    function getAcquisition(uint256 acquisitionId) external view returns (Acquisition memory) {
        return _acquisitions[acquisitionId];
    }

    /// @notice The commitment the flipper must submit for `seed`.
    function commitmentFor(bytes32 seed) external pure returns (bytes32) {
        return keccak256(abi.encode(seed));
    }

    /// @notice Whether a random word resolves to the burn branch (FLIP_BURN_BPS out of 10,000).
    function burnsFor(uint256 randomWord) public pure returns (bool) {
        return (randomWord >> 128) * GotchiConfig.BPS_DENOMINATOR < BURN_THRESHOLD;
    }

    function _resolve(
        uint256 acquisitionId,
        Acquisition storage acquisition,
        bool burned,
        address recipient,
        uint256 weight
    ) private {
        uint256 tokenId = acquisition.tokenId;
        acquisition.status = Status.Resolved;
        acquisition.burned = burned;
        acquisition.recipient = burned ? BURN_ADDRESS : recipient;
        delete openAcquisitionOf[tokenId];
        emit FlipResolved(acquisitionId, tokenId, burned, acquisition.recipient);
        if (burned) {
            emit Burned(tokenId, BURN_ADDRESS);
            NFT.transferFrom(address(this), BURN_ADDRESS, tokenId);
        } else {
            emit Airdropped(tokenId, recipient, weight);
            NFT.transferFrom(address(this), recipient, tokenId);
        }
    }
}
