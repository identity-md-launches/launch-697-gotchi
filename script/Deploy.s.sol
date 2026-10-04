// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {GotchiDeployment} from "./GotchiDeployment.sol";
import {GotchiConfig} from "../src/GotchiConfig.sol";

/// @title Deploy
/// @notice Optional Sepolia deployment of the whole $GOTCHI system. Reads no keys: sign with whatever
/// `forge script` option the operator chooses (`--ledger`, `--account`, ...).
///
/// Environment (all optional):
///   EXPECTED_CHAIN_ID  chain the script must be running on (default 11155111; 0 disables the check;
///                      only 11155111 and 31337 are accepted otherwise)
///   GOTCHI_OWNER       owner of FeeSink and FlipEscrow (default: the broadcaster)
///   GOTCHI_TOKEN       existing $GOTCHI address (default: deploy a fresh LaunchToken to the broadcaster)
///   POOL_MANAGER       PoolManager override for local forks (default: the Sepolia literal)
///
/// Dry run:   EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy
/// Sepolia:   EXPECTED_CHAIN_ID=11155111 forge script script/Deploy.s.sol:Deploy --rpc-url <sepolia> \
///            --broadcast --ledger   (or --account <name>)
contract Deploy is Script, GotchiDeployment {
    error ChainMismatch(uint256 actual, uint256 expected);
    error UnsupportedChain(uint256 chainId);

    function run() external returns (Deployment memory d) {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", GotchiConfig.SEPOLIA_CHAIN_ID);
        if (expected != 0) {
            if (expected != GotchiConfig.SEPOLIA_CHAIN_ID && expected != 31337) revert UnsupportedChain(expected);
            if (block.chainid != expected) revert ChainMismatch(block.chainid, expected);
        }
        Config memory cfg = Config({
            owner: vm.envOr("GOTCHI_OWNER", msg.sender),
            operator: msg.sender,
            poolManager: vm.envOr("POOL_MANAGER", GotchiConfig.POOL_MANAGER),
            token: vm.envOr("GOTCHI_TOKEN", address(0)),
            saltStart: 0
        });

        vm.startBroadcast();
        d = deployAll(cfg);
        vm.stopBroadcast();

        console.log("LaunchToken          ", address(d.token));
        console.log("MockGotchiNFT        ", address(d.nft));
        console.log("MockBaazaar          ", address(d.market));
        console.log("HolderWeightedPicker ", address(d.picker));
        console.log("FlipEscrow           ", address(d.escrow));
        console.log("FeeSink              ", address(d.feeSink));
        console.log("GotchiHookDeployer   ", address(d.hookDeployer));
        console.log("GotchiFeeHook        ", address(d.hook));
        console.log("ForeverLiquidity     ", address(d.forever));
        console.log("hook salt            ", vm.toString(d.hookSalt));
        if (!d.ownerWired) {
            console.log("OWNER ACTION NEEDED: escrow.setFeeSink(feeSink) and feeSink.setHook(hook)");
        }
    }
}
