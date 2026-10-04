// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForeverLiquidity} from "../src/ForeverLiquidity.sol";
import {GotchiConfig} from "../src/GotchiConfig.sol";

/// @title SeedPool
/// @notice Opens the ETH/$GOTCHI forever pool and locks INITIAL_LIQUIDITY_ETH + INITIAL_LIQUIDITY_TOKENS.
/// Run after Deploy by an account holding both. Reads no keys.
///
/// Environment:
///   FOREVER_LIQUIDITY   address printed by Deploy (required)
///   EXPECTED_CHAIN_ID   as in Deploy
///   PRICE_BAND_BPS      allowed deviation of an already-initialized pool from the implied price (default 100)
contract SeedPool is Script {
    error ChainMismatch(uint256 actual, uint256 expected);

    function run() external {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", GotchiConfig.SEPOLIA_CHAIN_ID);
        if (expected != 0 && block.chainid != expected) revert ChainMismatch(block.chainid, expected);
        ForeverLiquidity forever = ForeverLiquidity(vm.envAddress("FOREVER_LIQUIDITY"));
        uint256 bandBps = vm.envOr("PRICE_BAND_BPS", uint256(100));
        (uint160 target, uint160 minPrice, uint160 maxPrice) = priceBand(forever, bandBps);

        vm.startBroadcast();
        IERC20(address(forever.TOKEN())).approve(address(forever), GotchiConfig.INITIAL_LIQUIDITY_TOKENS);
        uint128 liquidity = forever.seed{value: GotchiConfig.INITIAL_LIQUIDITY_ETH}(
            target, minPrice, maxPrice, GotchiConfig.INITIAL_LIQUIDITY_TOKENS
        );
        vm.stopBroadcast();
        console.log("liquidity locked forever", liquidity);
    }

    /// @notice The implied opening sqrt price and the band accepted around it.
    function priceBand(ForeverLiquidity forever, uint256 bandBps)
        public
        pure
        returns (uint160 target, uint160 minPrice, uint160 maxPrice)
    {
        target = forever.sqrtPriceFromAmounts(GotchiConfig.INITIAL_LIQUIDITY_ETH, GotchiConfig.INITIAL_LIQUIDITY_TOKENS);
        minPrice = uint160((uint256(target) * (GotchiConfig.BPS_DENOMINATOR - bandBps)) / GotchiConfig.BPS_DENOMINATOR);
        maxPrice = uint160((uint256(target) * (GotchiConfig.BPS_DENOMINATOR + bandBps)) / GotchiConfig.BPS_DENOMINATOR);
    }
}
