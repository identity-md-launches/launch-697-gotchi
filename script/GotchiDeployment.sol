// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchToken} from "../src/LaunchToken.sol";
import {MockGotchiNFT} from "../src/MockGotchiNFT.sol";
import {MockBaazaar} from "../src/MockBaazaar.sol";
import {HolderWeightedPicker} from "../src/HolderWeightedPicker.sol";
import {FlipEscrow} from "../src/FlipEscrow.sol";
import {FeeSink} from "../src/FeeSink.sol";
import {GotchiHookDeployer} from "../src/GotchiHookDeployer.sol";
import {GotchiFeeHook} from "../src/GotchiFeeHook.sol";
import {ForeverLiquidity} from "../src/ForeverLiquidity.sol";

/// @title GotchiDeployment
/// @notice The deployment recipe, written once and shared by the Sepolia script (`Deploy.s.sol`) and the
/// tests, which inherit it and call `deployAll` directly with an explicit config (no environment reads).
/// @dev Order: token (optional) -> NFT -> market -> picker -> escrow -> FeeSink -> hook deployer -> hook
/// (CREATE2 with a mined salt, wired to FeeSink in the same transaction) -> ForeverLiquidity. The two
/// owner-only wiring calls (escrow.setFeeSink, feeSink.setHook) run here only when the owner is the
/// account executing the recipe; otherwise the owner performs them afterwards.
abstract contract GotchiDeployment {
    struct Config {
        /// Owner of FlipEscrow and FeeSink (Ownable2Step). Use the policy owner in a launch.
        address owner;
        /// The account executing the recipe (broadcaster or test contract). Owns GotchiHookDeployer.
        address operator;
        /// Uniswap v4 PoolManager. GotchiConfig.POOL_MANAGER on Sepolia.
        address poolManager;
        /// Existing $GOTCHI token, or address(0) to deploy a fresh LaunchToken (minted to the operator).
        address token;
        /// First salt tried while mining the hook address.
        uint256 saltStart;
    }

    struct Deployment {
        LaunchToken token;
        MockGotchiNFT nft;
        MockBaazaar market;
        HolderWeightedPicker picker;
        FlipEscrow escrow;
        FeeSink feeSink;
        GotchiHookDeployer hookDeployer;
        GotchiFeeHook hook;
        ForeverLiquidity forever;
        bytes32 hookSalt;
        bool ownerWired;
    }

    /// @notice Upper bound on CREATE2 salts tried (expected ~16k for 14 flag bits).
    uint256 internal constant SALT_TRIES = 1_000_000;

    error HookAddressMismatch(address predicted, address deployed);

    function deployAll(Config memory cfg) internal returns (Deployment memory d) {
        d.token = cfg.token == address(0) ? new LaunchToken() : LaunchToken(cfg.token);
        d.nft = new MockGotchiNFT();
        d.market = new MockBaazaar(address(d.nft));
        d.picker = new HolderWeightedPicker(address(d.token));
        d.escrow = new FlipEscrow(cfg.owner, address(d.nft), address(d.picker));
        d.feeSink = new FeeSink(cfg.owner, address(d.market), address(d.escrow));
        d.hookDeployer = new GotchiHookDeployer(cfg.operator);
        (bytes32 salt, address predicted) = d.hookDeployer.findSalt(cfg.poolManager, cfg.saltStart, SALT_TRIES);
        d.hookSalt = salt;
        d.hook = d.hookDeployer.deploy(salt, cfg.poolManager, address(d.feeSink));
        if (address(d.hook) != predicted) revert HookAddressMismatch(predicted, address(d.hook));
        d.forever = new ForeverLiquidity(cfg.poolManager, address(d.token), address(d.hook));
        if (cfg.owner == cfg.operator) {
            d.escrow.setFeeSink(address(d.feeSink));
            d.feeSink.setHook(address(d.hook));
            d.ownerWired = true;
        }
    }
}
