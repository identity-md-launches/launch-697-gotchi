// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GotchiDeployment} from "../script/GotchiDeployment.sol";
import {GotchiHookDeployer} from "../src/GotchiHookDeployer.sol";
import {GotchiFeeHook} from "../src/GotchiFeeHook.sol";
import {GotchiConfig} from "../src/GotchiConfig.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

/// @notice Exercises the deployment recipe the Sepolia script runs, with explicit config (no env reads).
contract DeploymentTest is Test, GotchiDeployment {
    address internal multisig = makeAddr("multisig");

    function test_recipeAgainstTheSepoliaPoolManagerLiteral() public {
        Deployment memory d = deployAll(
            Config({
                owner: address(this),
                operator: address(this),
                poolManager: GotchiConfig.POOL_MANAGER,
                token: address(0),
                saltStart: 0
            })
        );
        assertEq(address(d.hook.POOL_MANAGER()), 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
        assertEq(uint160(address(d.hook)) & Hooks.ALL_HOOK_MASK, uint160(0xCC));
        assertEq(d.hook.DEPLOYER(), address(d.hookDeployer));
        assertEq(address(d.hook.feeSink()), address(d.feeSink));
        assertEq(d.feeSink.hook(), address(d.hook));
        assertEq(d.escrow.feeSink(), address(d.feeSink));
        assertEq(address(d.feeSink.MARKET()), address(d.market));
        assertEq(address(d.feeSink.ESCROW()), address(d.escrow));
        assertEq(address(d.escrow.NFT()), address(d.nft));
        assertEq(address(d.escrow.PICKER()), address(d.picker));
        assertEq(address(d.picker.TOKEN()), address(d.token));
        assertEq(address(d.market.NFT()), address(d.nft));
        assertEq(address(d.forever.HOOK()), address(d.hook));
        assertEq(address(d.forever.TOKEN()), address(d.token));
        assertEq(d.token.balanceOf(address(this)), 10 ** 27, "fresh token minted to the operator");
        assertTrue(d.ownerWired);
        assertEq(d.hookDeployer.computeAddress(d.hookSalt, GotchiConfig.POOL_MANAGER), address(d.hook));
    }

    function test_recipeWithExternalOwnerLeavesOwnerWiringToTheOwner() public {
        LaunchToken existing = new LaunchToken();
        Deployment memory d = deployAll(
            Config({
                owner: multisig,
                operator: address(this),
                poolManager: GotchiConfig.POOL_MANAGER,
                token: address(existing),
                saltStart: 7
            })
        );
        assertEq(address(d.token), address(existing));
        assertFalse(d.ownerWired);
        assertEq(d.feeSink.hook(), address(0));
        assertEq(d.escrow.feeSink(), address(0));
        assertEq(d.feeSink.owner(), multisig);
        assertEq(d.escrow.owner(), multisig);
        assertEq(d.escrow.flipper(), multisig);
        // the hook itself is wired regardless: that happens inside the deployer transaction
        assertEq(address(d.hook.feeSink()), address(d.feeSink));

        vm.startPrank(multisig);
        d.escrow.setFeeSink(address(d.feeSink));
        d.feeSink.setHook(address(d.hook));
        vm.stopPrank();
        assertEq(d.feeSink.hook(), address(d.hook));
    }

    function test_hookDeployerIsOwnerOnly() public {
        GotchiHookDeployer deployer = new GotchiHookDeployer(multisig);
        (bytes32 salt, address predicted) = deployer.findSalt(GotchiConfig.POOL_MANAGER, 0, 200_000);
        assertTrue(deployer.hasRequiredFlags(predicted));
        vm.expectRevert(GotchiHookDeployer.NotOwner.selector);
        deployer.deploy(salt, GotchiConfig.POOL_MANAGER, address(1));
        vm.prank(multisig);
        GotchiFeeHook hook = deployer.deploy(salt, GotchiConfig.POOL_MANAGER, address(1));
        assertEq(address(hook), predicted);
        vm.expectRevert(GotchiHookDeployer.ZeroAddress.selector);
        new GotchiHookDeployer(address(0));
    }

    function test_findSaltRevertsWhenExhausted() public {
        GotchiHookDeployer deployer = new GotchiHookDeployer(address(this));
        vm.expectRevert(abi.encodeWithSelector(GotchiHookDeployer.SaltNotFound.selector, 3));
        deployer.findSalt(GotchiConfig.POOL_MANAGER, 0, 3);
    }

    function test_hasRequiredFlagsIsExact() public {
        GotchiHookDeployer deployer = new GotchiHookDeployer(address(this));
        assertTrue(deployer.hasRequiredFlags(address(uint160(0xCC))));
        assertTrue(deployer.hasRequiredFlags(address(uint160(0xABCDEF0000CC))));
        assertFalse(deployer.hasRequiredFlags(address(uint160(0xCD)))); // extra flag
        assertFalse(deployer.hasRequiredFlags(address(uint160(0xC8)))); // missing afterSwapReturnDelta
        assertFalse(deployer.hasRequiredFlags(address(uint160(0x20CC)))); // beforeInitialize set
    }
}
