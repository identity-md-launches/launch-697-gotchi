// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

/// @notice Test-only swap router: swaps on behalf of msg.sender, settling ETH from msg.value and tokens
/// from the swapper's allowance, and taking outputs to the swapper. Not part of the deliverable.
contract SwapRouterHarness is IUnlockCallback {
    IPoolManager public immutable manager;

    struct Data {
        address swapper;
        PoolKey key;
        SwapParams params;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function swap(PoolKey memory key, SwapParams memory params) external payable returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(Data(msg.sender, key, params))), (BalanceDelta));
        uint256 leftover = address(this).balance;
        if (leftover > 0) {
            (bool ok,) = payable(msg.sender).call{value: leftover}("");
            require(ok, "refund failed");
        }
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        Data memory data = abi.decode(raw, (Data));
        BalanceDelta delta = manager.swap(data.key, data.params, "");
        _settle(data.key.currency0, data.swapper, delta.amount0());
        _settle(data.key.currency1, data.swapper, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, address swapper, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                IERC20(Currency.unwrap(currency)).transferFrom(swapper, address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, swapper, uint256(uint128(amount)));
        }
    }
}
