// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {GotchiFeeHook} from "./GotchiFeeHook.sol";

/// @title GotchiHookDeployer
/// @notice Deploys GotchiFeeHook with CREATE2 at a mined, flag-valid address and wires its FeeSink in the
/// same transaction, so there is no window in which a stranger could wire a different sink.
/// @dev v4 reads a hook's permissions from the low 14 bits of its address, so the salt must be mined
/// (`findSalt`, or off-chain). The hook's constructor sees this contract as msg.sender and records it as
/// DEPLOYER; that is the only address allowed to call `hook.wire`, and this contract only ever calls it
/// here. Owner-only so nobody else can burn the mined salt.
contract GotchiHookDeployer {
    /// @notice The operator allowed to deploy.
    address public immutable OWNER;

    /// @notice Flags GotchiFeeHook needs in its address.
    uint160 public constant REQUIRED_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    event HookDeployed(address indexed hook, bytes32 salt, address indexed poolManager, address indexed feeSink);

    error NotOwner();
    error ZeroAddress();
    error SaltNotFound(uint256 tried);

    constructor(address owner) {
        if (owner == address(0)) revert ZeroAddress();
        OWNER = owner;
    }

    /// @notice Deploy the hook for `poolManager` at `salt` and wire `feeSink`.
    function deploy(bytes32 salt, address poolManager, address feeSink) external returns (GotchiFeeHook hook) {
        if (msg.sender != OWNER) revert NotOwner();
        hook = new GotchiFeeHook{salt: salt}(poolManager);
        hook.wire(feeSink);
        emit HookDeployed(address(hook), salt, poolManager, feeSink);
    }

    /// @notice The address `deploy(salt, poolManager, ...)` would create.
    function computeAddress(bytes32 salt, address poolManager) external view returns (address) {
        return _create2Address(salt, _initCodeHash(poolManager));
    }

    /// @notice keccak256 of the hook init code (creation code + encoded constructor argument).
    function _initCodeHash(address poolManager) private pure returns (bytes32) {
        return keccak256(bytes.concat(type(GotchiFeeHook).creationCode, abi.encode(poolManager)));
    }

    function _create2Address(bytes32 salt, bytes32 initCodeHash) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    /// @notice Whether an address carries exactly the flags GotchiFeeHook needs.
    function hasRequiredFlags(address hook) public pure returns (bool) {
        return uint160(hook) & Hooks.ALL_HOOK_MASK == REQUIRED_FLAGS;
    }

    /// @notice Mine a salt in [start, start + maxTries) whose address carries the required flags.
    function findSalt(address poolManager, uint256 start, uint256 maxTries)
        external
        view
        returns (bytes32 salt, address hook)
    {
        bytes32 initCodeHash = _initCodeHash(poolManager);
        for (uint256 i = 0; i < maxTries; ++i) {
            salt = bytes32(start + i);
            hook = _create2Address(salt, initCodeHash);
            if (hasRequiredFlags(hook)) return (salt, hook);
        }
        revert SaltNotFound(maxTries);
    }
}
