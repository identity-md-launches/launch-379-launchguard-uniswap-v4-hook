// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

/// @notice Single-pool, fill-or-kill swaps. The payer, buyer identity and recipient are msg.sender.
/// @dev Only ERC-20 currencies. No arbitrary hookData, external calls, recipient or payer overrides.
contract LaunchRouter is IUnlockCallback {
    using SafeTransferLib for ERC20;

    IPoolManager public immutable manager;
    address public immutable hook;
    mapping(PoolId => mapping(address => uint128)) public liquidityOf;
    bool private entered;

    struct Request {
        bool swap;
        PoolKey key;
        address account;
        IPoolManager.SwapParams params;
        int256 liquidityDelta;
        uint256 limit0;
        uint256 limit1;
    }

    error Unauthorized();
    error Reentrancy();
    error WrongPool();
    error Slippage();
    error PartialFill();
    error Expired();
    error InvalidAmount();
    error InsufficientLiquidity();

    constructor(IPoolManager manager_, address hook_) {
        manager = manager_;
        hook = hook_;
    }

    modifier nonReentrant() {
        if (entered) revert Reentrancy();
        entered = true;
        _;
        entered = false;
    }

    /// @param limit Minimum output for exact input; maximum input for exact output.
    function swap(PoolKey calldata key, IPoolManager.SwapParams calldata params, uint256 limit, uint256 deadline)
        external
        nonReentrant
        returns (BalanceDelta)
    {
        if (block.timestamp > deadline) revert Expired();
        if (params.amountSpecified == 0 || params.amountSpecified == type(int256).min) revert InvalidAmount();
        Request memory r;
        r.swap = true;
        r.key = key;
        r.account = msg.sender;
        r.params = params;
        r.limit0 = limit;
        return _unlock(r);
    }

    /// @dev Called only by the hook during its atomic initialize-and-seed operation.
    function seed(PoolKey calldata key, address payer, uint128 liquidity, uint256 max0, uint256 max1)
        external
        nonReentrant
        returns (BalanceDelta)
    {
        if (msg.sender != hook) revert Unauthorized();
        return _modify(key, payer, int256(uint256(liquidity)), max0, max1);
    }

    /// @notice Manage ONLY your own full-range position. A zero delta collects your accrued fees.
    /// @param limit0 Maximum currency0 paid on addition; minimum received on removal/collection.
    /// @param limit1 Maximum currency1 paid on addition; minimum received on removal/collection.
    function modifyLiquidity(
        PoolKey calldata key,
        int256 liquidityDelta,
        uint256 limit0,
        uint256 limit1,
        uint256 deadline
    ) external nonReentrant returns (BalanceDelta) {
        if (block.timestamp > deadline) revert Expired();
        return _modify(key, msg.sender, liquidityDelta, limit0, limit1);
    }

    function _modify(PoolKey memory key, address account, int256 amount, uint256 limit0, uint256 limit1)
        private
        returns (BalanceDelta)
    {
        if (amount > type(int128).max || amount < -int256(type(int128).max)) revert InvalidAmount();
        uint128 current = liquidityOf[key.toId()][account];
        if (amount < 0 && uint256(-amount) > current) revert InsufficientLiquidity();
        uint256 next = uint256(current);
        next = amount < 0 ? next - uint256(-amount) : next + uint256(amount);
        if (next > uint128(type(int128).max)) revert InvalidAmount();
        liquidityOf[key.toId()][account] = uint128(next);
        Request memory r;
        r.key = key;
        r.account = account;
        r.liquidityDelta = amount;
        r.limit0 = limit0;
        r.limit1 = limit1;
        return _unlock(r);
    }

    function _unlock(Request memory r) private returns (BalanceDelta) {
        if (address(r.key.hooks) != hook || Currency.unwrap(r.key.currency0) == address(0)) revert WrongPool();
        return abi.decode(manager.unlock(abi.encode(r)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || !entered) revert Unauthorized();
        Request memory r = abi.decode(data, (Request));
        BalanceDelta delta;
        if (r.swap) {
            delta = manager.swap(r.key, r.params, abi.encode(r.account));
            int128 input = r.params.zeroForOne ? delta.amount0() : delta.amount1();
            int128 output = r.params.zeroForOne ? delta.amount1() : delta.amount0();
            if (input > 0 || output < 0) revert InvalidAmount();
            uint256 paid = uint256(-int256(input));
            uint256 received = uint128(output);
            if (r.params.amountSpecified < 0) {
                if (paid != uint256(-r.params.amountSpecified)) revert PartialFill();
                if (received < r.limit0) revert Slippage();
            } else {
                if (received != uint256(r.params.amountSpecified)) revert PartialFill();
                if (paid > r.limit0) revert Slippage();
            }
        } else {
            (delta,) = manager.modifyLiquidity(
                r.key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: TickMath.minUsableTick(r.key.tickSpacing),
                    tickUpper: TickMath.maxUsableTick(r.key.tickSpacing),
                    liquidityDelta: r.liquidityDelta,
                    salt: bytes32(uint256(uint160(r.account)))
                }),
                ""
            );
            _checkLiquidityLimit(delta.amount0(), r.limit0, r.liquidityDelta > 0);
            _checkLiquidityLimit(delta.amount1(), r.limit1, r.liquidityDelta > 0);
        }
        _settle(r.key.currency0, r.account, delta.amount0());
        _settle(r.key.currency1, r.account, delta.amount1());
        return abi.encode(delta);
    }

    function _checkLiquidityLimit(int128 delta, uint256 limit, bool adding) private pure {
        if (adding) {
            if (delta < 0 && uint256(-int256(delta)) > limit) revert Slippage();
        } else if (delta < 0 || uint128(delta) < limit) {
            revert Slippage();
        }
    }

    function _settle(Currency currency, address account, int128 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            ERC20(Currency.unwrap(currency)).safeTransferFrom(account, address(manager), uint256(-int256(delta)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, account, uint128(delta));
        }
    }
}
