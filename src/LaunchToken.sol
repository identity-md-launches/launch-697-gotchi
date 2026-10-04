// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LaunchToken ($GOTCHI)
/// @notice The GOTCHI launch token: a plain fixed-supply ERC-20.
/// @dev This is the "GotchiToken" module of the brief. Exactly 1,000,000,000 tokens (10^27 minor units,
/// 18 decimals) are minted once to the deployer in the constructor. There is no mint, owner, pause,
/// blocklist, fee, hook or upgrade path: the holder registry used for airdrop weighting lives in
/// HolderWeightedPicker and reads balances through the standard interface, so transfers stay plain.
contract LaunchToken is ERC20 {
    /// @notice Fixed total supply in minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor() ERC20("GOTCHI", "GOTCHI") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
