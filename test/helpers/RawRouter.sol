// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @dev Deliberately accepts arbitrary hookData, demonstrating why untrusted router identities fail.
contract RawRouter is IUnlockCallback {
    IPoolManager immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(true, msg.sender, key, params, hookData, uint128(0))), (BalanceDelta)
        );
    }

    function seed(PoolKey memory key, uint128 liquidity) external {
        IPoolManager.SwapParams memory empty;
        manager.unlock(abi.encode(false, msg.sender, key, empty, bytes(""), liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (
            bool isSwap,
            address payer,
            PoolKey memory key,
            IPoolManager.SwapParams memory params,
            bytes memory hookData,
            uint128 liquidity
        ) = abi.decode(data, (bool, address, PoolKey, IPoolManager.SwapParams, bytes, uint128));
        BalanceDelta delta;
        if (isSwap) {
            delta = manager.swap(key, params, hookData);
        } else {
            (delta,) = manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams(
                    TickMath.minUsableTick(key.tickSpacing),
                    TickMath.maxUsableTick(key.tickSpacing),
                    int256(uint256(liquidity)),
                    bytes32(uint256(uint160(payer)))
                ),
                ""
            );
        }
        _settle(key.currency0, payer, delta.amount0());
        _settle(key.currency1, payer, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency c, address payer, int128 delta) private {
        if (delta < 0) {
            manager.sync(c);
            require(ERC20(Currency.unwrap(c)).transferFrom(payer, address(manager), uint256(-int256(delta))));
            manager.settle();
        } else if (delta > 0) {
            manager.take(c, payer, uint128(delta));
        }
    }
}
