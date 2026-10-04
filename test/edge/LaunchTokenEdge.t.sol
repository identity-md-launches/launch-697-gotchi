// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";

/// @notice $GOTCHI transfer edges: allowances, zero and self transfers, excluded destinations.
contract LaunchTokenEdgeTest is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    LaunchToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new LaunchToken();
    }

    function test_nameSymbolAreGotchi() public view {
        assertEq(token.name(), "GOTCHI");
        assertEq(token.symbol(), "GOTCHI");
        assertEq(token.decimals(), 18);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferToBurnAddressKeepsSupplyButParksTheTokens() public {
        token.transfer(DEAD, 1_000e18);
        assertEq(token.balanceOf(DEAD), 1_000e18);
        assertEq(token.totalSupply(), SUPPLY, "sending to the dead address is not a supply burn");
    }

    function test_zeroAndSelfTransfersAreNoOps() public {
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(alice), 0);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0), "an empty wallet may still send zero");
    }

    function test_oneWeiOverBalanceReverts() public {
        token.transfer(alice, 5);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5, 6));
        token.transfer(bob, 6);
    }

    function test_transferFromNeedsAllowanceAndSpendsIt() public {
        token.transfer(alice, 100);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
        vm.prank(alice);
        token.approve(bob, 60);
        vm.prank(bob);
        token.transferFrom(alice, bob, 60);
        assertEq(token.allowance(alice, bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 40);
        assertEq(token.balanceOf(bob), 60);
    }

    function test_noBurnSurface() public {
        string[3] memory signatures = ["burn(uint256)", "burnFrom(address,uint256)", "burn(address,uint256)"];
        for (uint256 i = 0; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], address(this), uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_transferFromMovesExactlyAndConservesSupply(uint256 held, uint256 approved, uint256 amount)
        public
    {
        held = bound(held, 0, SUPPLY);
        approved = bound(approved, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, approved);
        vm.prank(bob);
        if (amount > approved || amount > held) {
            vm.expectRevert();
            token.transferFrom(alice, bob, amount);
            assertEq(token.balanceOf(alice), held);
            assertEq(token.balanceOf(bob), 0);
        } else {
            token.transferFrom(alice, bob, amount);
            assertEq(token.balanceOf(alice), held - amount);
            assertEq(token.balanceOf(bob), amount);
            assertEq(token.allowance(alice, bob), approved - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
    }
}
