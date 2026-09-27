// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LaunchRouter} from "./LaunchRouter.sol";

/// @notice Immutable launch rules, authenticated buy accounting, and surplus fees donated to LPs.
/// @dev Unimplemented callbacks have no permission bits. No owner, arbitrary calls, or withdrawal.
contract LaunchGuard {
    using StateLibrary for IPoolManager;

    uint24 public constant NORMAL_FEE = 10_000;
    uint24 public constant MAX_START_FEE = 500_000;
    uint256 public constant FEE_SCALE = 1_000_000;
    uint160 public constant FLAGS = 0x20cc;

    struct Settings {
        address token;
        uint16 windowBlocks;
        uint24 startFee;
        uint16 maxBuyBps;
        uint16 maxAddressBps;
    }

    struct Launch {
        Settings settings;
        uint256 startBlock;
        uint256 initialTokenReserve;
        uint256 maxBuy;
        uint256 maxAddress;
        bool ready;
    }

    IPoolManager public immutable manager;
    LaunchRouter public immutable router;
    mapping(PoolId => Launch) private launches;
    mapping(PoolId => mapping(address => uint256)) public bought;
    mapping(PoolId => mapping(address => uint256)) public lastBuyBlock;
    bool private initializing;

    error OnlyManager();
    error InitializeThroughHook();
    error InvalidSettings();
    error InvalidPool();
    error AlreadyInitialized();
    error UnknownPool();
    error InitializationInProgress();
    error FirstBlock();
    error UseLaunchRouter();
    error OneBuyPerBlock();
    error MaxBuyExceeded();
    error MaxAddressExceeded();
    error InvalidSwap();
    error PartialFill();
    error ProtocolFeeEnabled();

    event PoolLaunched(
        PoolId indexed id,
        address indexed creator,
        address indexed token,
        uint256 startBlock,
        uint16 windowBlocks,
        uint24 startFee,
        uint256 initialTokenReserve,
        uint256 maxBuy,
        uint256 maxAddress
    );
    event GuardedBuy(PoolId indexed id, address indexed buyer, uint256 tokensOut, uint24 fee, uint256 donated);

    constructor(IPoolManager manager_) {
        // Only bind the manager here; constructor-only deployment probes need no manager state.
        // The deployment script verifies its code, and initialize requires the real v4 interface.
        if (address(manager_) == address(0)) revert InvalidPool();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        manager = manager_;
        router = new LaunchRouter(manager_, address(this));
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    modifier onlyManager() {
        if (msg.sender != address(manager)) revert OnlyManager();
        _;
    }

    /// @notice Store immutable rules, initialize a dynamic-fee pool, and fund a real full-range position atomically.
    /// @dev Approve this hook's router for both currencies first. The caller owns the seed position.
    function initialize(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        Settings calldata settings,
        uint128 liquidity,
        uint256 maxAmount0,
        uint256 maxAmount1
    ) external returns (PoolId id) {
        if (initializing) revert InitializationInProgress();
        if (
            address(key.hooks) != address(this) || key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG
                || Currency.unwrap(key.currency0) == address(0)
                || Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)
                || (settings.token != Currency.unwrap(key.currency0)
                    && settings.token != Currency.unwrap(key.currency1))
        ) revert InvalidPool();
        if (
            settings.windowBlocks == 0 || settings.windowBlocks > 300 || settings.startFee < NORMAL_FEE
                || settings.startFee > MAX_START_FEE || settings.maxBuyBps == 0
                || settings.maxBuyBps > settings.maxAddressBps || settings.maxAddressBps > 10_000 || liquidity == 0
                || liquidity > uint128(type(int128).max)
        ) revert InvalidSettings();
        id = key.toId();
        Launch storage l = launches[id];
        if (l.initialTokenReserve != 0) revert AlreadyInitialized();
        initializing = true;
        l.settings = settings;
        l.startBlock = block.number;

        // v4's noSelfCall bypasses beforeInitialize ONLY for this call from the hook itself.
        // Every other caller hits beforeInitialize below and reverts. initialize has no hookData.
        manager.initialize(key, sqrtPriceX96);
        manager.updateDynamicLPFee(key, NORMAL_FEE);
        BalanceDelta delta = router.seed(key, msg.sender, liquidity, maxAmount0, maxAmount1);
        int128 tokenDelta = settings.token == Currency.unwrap(key.currency0) ? delta.amount0() : delta.amount1();
        if (tokenDelta >= 0) revert InvalidSettings();
        l.initialTokenReserve = uint256(-int256(tokenDelta));
        l.maxBuy = l.initialTokenReserve * settings.maxBuyBps / 10_000;
        l.maxAddress = l.initialTokenReserve * settings.maxAddressBps / 10_000;
        if (l.maxBuy == 0) revert InvalidSettings();
        l.ready = true;
        initializing = false;
        emit PoolLaunched(
            id,
            msg.sender,
            settings.token,
            block.number,
            settings.windowBlocks,
            settings.startFee,
            l.initialTokenReserve,
            l.maxBuy,
            l.maxAddress
        );
    }

    function launch(PoolId id) external view returns (Launch memory) {
        return launches[id];
    }

    /// @notice Effective LP buy fee in millionths; sells always pay NORMAL_FEE.
    function currentBuyFee(PoolId id) public view returns (uint24) {
        Launch storage l = launches[id];
        if (!l.ready) revert UnknownPool();
        uint256 elapsed = block.number - l.startBlock;
        if (elapsed >= l.settings.windowBlocks) return NORMAL_FEE;
        return uint24(
            NORMAL_FEE + uint256(l.settings.startFee - NORMAL_FEE) * (l.settings.windowBlocks - elapsed)
                / l.settings.windowBlocks
        );
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external view onlyManager returns (bytes4) {
        revert InitializeThroughHook();
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) external onlyManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId id = key.toId();
        Launch storage l = launches[id];
        if (!l.ready) revert UnknownPool();
        uint256 surcharge;
        if (_guardedBuy(l, key, params.zeroForOne)) {
            // A protocol fee would change the launch's all-in fee. Guarded buys fail closed.
            (,, uint24 protocolFee,) = manager.getSlot0(id);
            if (protocolFee != 0) revert ProtocolFeeEnabled();
            if (block.number == l.startBlock) revert FirstBlock();
            address buyer = _buyer(sender, data);
            if (lastBuyBlock[id][buyer] == block.number) revert OneBuyPerBlock();
            if (params.amountSpecified == type(int256).min || params.amountSpecified == 0) revert InvalidSwap();
            uint256 amount = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);
            if (amount > uint128(type(int128).max)) revert InvalidSwap();
            // Reserve the block before executing the swap; any revert rolls this back too.
            lastBuyBlock[id][buyer] = block.number;
            if (params.amountSpecified < 0) surcharge = _exactInputSurcharge(amount, currentBuyFee(id));
        }
        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(int128(uint128(surcharge)), 0),
            NORMAL_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external onlyManager returns (bytes4, int128) {
        PoolId id = key.toId();
        Launch storage l = launches[id];
        if (!l.ready) revert UnknownPool();
        if (!_guardedBuy(l, key, params.zeroForOne)) return (IHooks.afterSwap.selector, 0);
        address buyer = _buyer(sender, data);
        int128 output = params.zeroForOne ? delta.amount1() : delta.amount0();
        int128 input = params.zeroForOne ? delta.amount0() : delta.amount1();
        if (output <= 0 || input >= 0) revert InvalidSwap();
        uint256 received = uint128(output);
        if (received > l.maxBuy) revert MaxBuyExceeded();
        uint256 total = bought[id][buyer] + received;
        if (total > l.maxAddress) revert MaxAddressExceeded();
        bought[id][buyer] = total;
        uint24 fee = currentBuyFee(id);
        uint256 surcharge;
        int128 returned;
        if (params.amountSpecified < 0) {
            uint256 gross = uint256(-params.amountSpecified);
            surcharge = _exactInputSurcharge(gross, fee);
            if (uint256(-int256(input)) != gross - surcharge) revert PartialFill();
        } else {
            if (received != uint256(params.amountSpecified)) revert PartialFill();
            uint256 numerator = uint256(-int256(input)) * (fee - NORMAL_FEE);
            uint256 denominator = FEE_SCALE - fee;
            surcharge = (numerator + denominator - 1) / denominator;
            if (surcharge > uint128(type(int128).max)) revert InvalidSwap();
            returned = int128(uint128(surcharge));
        }
        if (surcharge != 0) {
            // donate creates a hook debt; v4 credits the returned hook delta after afterSwap.
            // These cancel exactly. No take(), token custody, claim tokens or owner payout.
            manager.donate(key, params.zeroForOne ? surcharge : 0, params.zeroForOne ? 0 : surcharge, "");
        }
        emit GuardedBuy(id, buyer, received, fee, surcharge);
        return (IHooks.afterSwap.selector, returned);
    }

    function _buyer(address sender, bytes calldata data) private view returns (address buyer) {
        if (sender != address(router) || data.length != 32) revert UseLaunchRouter();
        buyer = abi.decode(data, (address));
        if (buyer == address(0)) revert UseLaunchRouter();
    }

    function _guardedBuy(Launch storage l, PoolKey calldata key, bool zeroForOne) private view returns (bool) {
        bool buy = l.settings.token == Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
        return buy && block.number - l.startBlock < l.settings.windowBlocks;
    }

    function _exactInputSurcharge(uint256 gross, uint24 fee) private pure returns (uint256) {
        return gross * (fee - NORMAL_FEE) / (FEE_SCALE - NORMAL_FEE);
    }
}
