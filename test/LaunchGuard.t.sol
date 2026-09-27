// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {LaunchGuard} from "../src/LaunchGuard.sol";
import {LaunchGuardDeployer} from "../src/LaunchGuardDeployer.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {HookMiner} from "../script/HookMiner.sol";
import {RawRouter} from "./helpers/RawRouter.sol";

contract LaunchGuardTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager manager;
    LaunchGuard hook;
    LaunchGuardDeployer deployer;
    LaunchRouter router;
    RawRouter raw;
    LaunchToken token0;
    LaunchToken token1;
    PoolKey key;
    PoolId id;
    uint256 constant START = 100;
    uint128 constant LIQUIDITY = 1_000_000 ether;
    uint160 constant PRICE = 79228162514264337593543950336;
    address constant ALICE = address(0xa11ce);
    address constant BOB = address(0xb0b);
    address constant MALLORY = address(0xbad);

    function setUp() public {
        vm.roll(START);
        manager = IPoolManager(address(new PoolManager(address(this))));
        deployer = new LaunchGuardDeployer();
        (address predicted, bytes32 salt) = HookMiner.find(address(deployer), deployer.initCodeHash(manager));
        hook = deployer.deploy(manager, salt);
        assertEq(address(hook), predicted);
        router = hook.router();
        raw = new RawRouter(manager);
        LaunchToken a = new LaunchToken();
        LaunchToken b = new LaunchToken();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        _fundAndApprove(address(this));
        _fundAndApprove(ALICE);
        _fundAndApprove(BOB);
        _fundAndApprove(MALLORY);
        key = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(hook))
        );
        id = hook.initialize(key, PRICE, _settings(address(token0)), LIQUIDITY, 2_000_000 ether, 2_000_000 ether);
    }

    function _settings(address token) internal pure returns (LaunchGuard.Settings memory) {
        return LaunchGuard.Settings(token, 100, 500_000, 50, 100);
    }

    function _fundAndApprove(address user) internal {
        if (user != address(this)) {
            token0.transfer(user, 10_000_000 ether);
            token1.transfer(user, 10_000_000 ether);
        }
        vm.startPrank(user);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(raw), type(uint256).max);
        token1.approve(address(raw), type(uint256).max);
        vm.stopPrank();
    }

    function _params(bool zeroForOne, int256 amount) internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams(
            zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _buy(address who, int256 amount) internal returns (BalanceDelta) {
        vm.prank(who);
        return router.swap(key, _params(false, amount), amount < 0 ? 0 : type(uint256).max, block.timestamp);
    }

    function _sell(address who, int256 amount) internal returns (BalanceDelta) {
        vm.prank(who);
        return router.swap(key, _params(true, amount), amount < 0 ? 0 : type(uint256).max, block.timestamp);
    }

    function _hookError(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSignature(
            "WrappedError(address,bytes4,bytes,bytes)",
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _cleanAccounting() internal view {
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
        assertEq(token0.balanceOf(address(router)), 0);
        assertEq(token1.balanceOf(address(router)), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    function test_MinedPermissionsAndActualSeedReserve() public view {
        assertEq(uint160(address(hook)) & 0x3fff, 0x20cc);
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
        LaunchGuard.Launch memory l = hook.launch(id);
        assertTrue(l.ready);
        assertEq(l.startBlock, START);
        assertEq(l.initialTokenReserve, token0.balanceOf(address(manager)));
        assertEq(l.maxBuy, l.initialTokenReserve * 50 / 10_000);
        assertEq(l.maxAddress, l.initialTokenReserve * 100 / 10_000);
        assertEq(router.liquidityOf(id, address(this)), LIQUIDITY);
        (,,, uint24 fee) = manager.getSlot0(id);
        assertEq(fee, 10_000);
    }

    function test_DirectInitializationRejected() public {
        PoolKey memory other = key;
        other.tickSpacing = 120;
        vm.expectRevert(_hookError(IHooks.beforeInitialize.selector, LaunchGuard.InitializeThroughHook.selector));
        manager.initialize(other, PRICE);
        assertFalse(hook.launch(other.toId()).ready);
    }

    function test_SettingsCannotBeChanged() public {
        LaunchGuard.Settings memory settings = _settings(address(token0));
        settings.startFee = 10_000;
        vm.expectRevert(LaunchGuard.AlreadyInitialized.selector);
        hook.initialize(key, PRICE, settings, LIQUIDITY, type(uint256).max, type(uint256).max);
        assertEq(hook.launch(id).settings.startFee, 500_000);
    }

    function test_InvalidSettingsAndStaticFeeRejected() public {
        PoolKey memory other = key;
        other.tickSpacing = 120;
        LaunchGuard.Settings memory s = _settings(address(token0));
        s.windowBlocks = 301;
        _badSettings(other, s);
        s.windowBlocks = 0;
        _badSettings(other, s);
        s.windowBlocks = 100;
        s.startFee = 500_001;
        _badSettings(other, s);
        s.startFee = 9_999;
        _badSettings(other, s);
        s.startFee = 10_000;
        s.maxBuyBps = 0;
        _badSettings(other, s);
        s.maxBuyBps = 101;
        _badSettings(other, s);
        s.maxBuyBps = 50;
        s.maxAddressBps = 10_001;
        _badSettings(other, s);
        other.fee = 10_000;
        vm.expectRevert(LaunchGuard.InvalidPool.selector);
        hook.initialize(other, PRICE, _settings(address(token0)), LIQUIDITY, type(uint256).max, type(uint256).max);
    }

    function _badSettings(PoolKey memory other, LaunchGuard.Settings memory s) internal {
        vm.expectRevert(LaunchGuard.InvalidSettings.selector);
        hook.initialize(other, PRICE, s, LIQUIDITY, type(uint256).max, type(uint256).max);
    }

    function test_FailedSeedRollsBackInitialization() public {
        PoolKey memory other = key;
        other.tickSpacing = 120;
        vm.expectRevert(LaunchRouter.Slippage.selector);
        hook.initialize(other, PRICE, _settings(address(token0)), LIQUIDITY, 1, 1);
        assertFalse(hook.launch(other.toId()).ready);
        (uint160 price,,,) = manager.getSlot0(other.toId());
        assertEq(price, 0);
        hook.initialize(other, PRICE, _settings(address(token0)), LIQUIDITY, type(uint256).max, type(uint256).max);
    }

    function test_FeeCurveEveryBlockAndEndBoundary() public {
        for (uint256 elapsed; elapsed <= 110; ++elapsed) {
            vm.roll(START + elapsed);
            uint256 expected = elapsed >= 100 ? 10_000 : 500_000 - 4_900 * elapsed;
            assertEq(hook.currentBuyFee(id), expected);
        }
    }

    function test_FirstBlockRejectsBothSwapModes() public {
        vm.expectRevert(_hookError(IHooks.beforeSwap.selector, LaunchGuard.FirstBlock.selector));
        _buy(ALICE, -int256(100 ether));
        vm.expectRevert(_hookError(IHooks.beforeSwap.selector, LaunchGuard.FirstBlock.selector));
        _buy(ALICE, int256(100 ether));
        assertEq(hook.bought(id, ALICE), 0);
    }

    function test_OneBuyPerAddressPerBlockAndIndependentAddresses() public {
        vm.roll(START + 1);
        _buy(ALICE, -int256(100 ether));
        vm.expectRevert(_hookError(IHooks.beforeSwap.selector, LaunchGuard.OneBuyPerBlock.selector));
        _buy(ALICE, int256(10 ether));
        _buy(BOB, int256(10 ether));
        vm.roll(START + 2);
        _buy(ALICE, int256(10 ether));
        assertEq(hook.bought(id, BOB), 10 ether);
        _cleanAccounting();
    }

    function test_MaxBuyExactOutputBoundaryAndRevertRollback() public {
        vm.roll(START + 1);
        uint256 cap = hook.launch(id).maxBuy;
        vm.expectRevert(_hookError(IHooks.afterSwap.selector, LaunchGuard.MaxBuyExceeded.selector));
        _buy(ALICE, int256(cap + 1));
        assertEq(hook.lastBuyBlock(id, ALICE), 0);
        assertEq(hook.bought(id, ALICE), 0);
        _buy(ALICE, int256(cap));
        assertEq(hook.bought(id, ALICE), cap);
    }

    function test_MaxBuyExactInputUsesActualTokenOutput() public {
        vm.roll(START + 1);
        vm.expectRevert(_hookError(IHooks.afterSwap.selector, LaunchGuard.MaxBuyExceeded.selector));
        _buy(ALICE, -int256(20_000 ether));
        BalanceDelta d = _buy(ALICE, -int256(100 ether));
        assertEq(hook.bought(id, ALICE), uint128(d.amount0()));
        assertEq(d.amount1(), -int128(100 ether));
    }

    function test_AddressCapAndSellingDoesNotRestoreAllowance() public {
        uint256 cap = hook.launch(id).maxBuy;
        vm.roll(START + 1);
        _buy(ALICE, int256(cap));
        _sell(ALICE, -int256(cap));
        vm.roll(START + 2);
        uint256 remainder = hook.launch(id).maxAddress - cap;
        _buy(ALICE, int256(remainder));
        vm.roll(START + 3);
        vm.expectRevert(_hookError(IHooks.afterSwap.selector, LaunchGuard.MaxAddressExceeded.selector));
        _buy(ALICE, int256(1 ether));
        assertEq(hook.bought(id, ALICE), hook.launch(id).maxAddress);
    }

    function test_UntrustedRouterCannotSpoofBuyer() public {
        vm.roll(START + 1);
        vm.prank(MALLORY);
        vm.expectRevert(_hookError(IHooks.beforeSwap.selector, LaunchGuard.UseLaunchRouter.selector));
        raw.swap(key, _params(false, int256(10 ether)), abi.encode(ALICE));
        vm.prank(MALLORY);
        vm.expectRevert(_hookError(IHooks.beforeSwap.selector, LaunchGuard.UseLaunchRouter.selector));
        raw.swap(key, _params(false, -int256(10 ether)), "");
        assertEq(hook.bought(id, ALICE), 0);
    }

    function test_CallbacksAndSeedCannotBeCalledDirectly() public {
        vm.expectRevert(LaunchGuard.OnlyManager.selector);
        hook.beforeSwap(address(router), key, _params(false, -1), abi.encode(ALICE));
        vm.expectRevert(LaunchGuard.OnlyManager.selector);
        hook.afterSwap(address(router), key, _params(false, -1), BalanceDelta.wrap(0), abi.encode(ALICE));
        vm.expectRevert(LaunchGuard.OnlyManager.selector);
        hook.beforeInitialize(address(hook), key, PRICE);
        vm.expectRevert(LaunchRouter.Unauthorized.selector);
        router.unlockCallback("");
        vm.expectRevert(LaunchRouter.Unauthorized.selector);
        router.seed(key, ALICE, 1, 1, 1);
    }

    function test_SellsFirstBlockBothModesChargeOnlyNormalFee() public {
        PoolKey memory control = _control(10_000);
        BalanceDelta expected = raw.swap(control, _params(true, -int256(100 ether)), "");
        BalanceDelta actual = _sell(ALICE, -int256(100 ether));
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected));
        expected = raw.swap(control, _params(true, int256(10 ether)), "");
        actual = _sell(ALICE, int256(10 ether));
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected));
        assertEq(hook.bought(id, ALICE), 0);
        assertEq(hook.lastBuyBlock(id, ALICE), 0);
        _cleanAccounting();
    }

    function test_ExternalRouterSellsDuringWindow() public {
        vm.prank(ALICE);
        raw.swap(key, _params(true, -int256(100 ether)), "untrusted data is irrelevant for sells");
        assertEq(hook.bought(id, ALICE), 0);
    }

    function test_AfterWindowNoLimitsAndExternalRouting() public {
        vm.roll(START + 100);
        PoolKey memory control = _control(10_000);
        for (uint256 i; i < 3; ++i) {
            BalanceDelta expected = raw.swap(control, _params(false, int256(10_000 ether)), "");
            BalanceDelta actual = _buy(ALICE, int256(10_000 ether));
            assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected));
        }
        BalanceDelta expectedIn = raw.swap(control, _params(false, -int256(100 ether)), "");
        vm.prank(ALICE);
        BalanceDelta actualIn = raw.swap(key, _params(false, -int256(100 ether)), "");
        assertEq(BalanceDelta.unwrap(actualIn), BalanceDelta.unwrap(expectedIn));
        assertEq(hook.bought(id, ALICE), 0);
        assertEq(hook.lastBuyBlock(id, ALICE), 0);
        _cleanAccounting();
    }

    function _control(uint24 fee) internal returns (PoolKey memory control) {
        control = key;
        control.hooks = IHooks(address(0));
        control.fee = fee;
        manager.initialize(control, PRICE);
        raw.seed(control, LIQUIDITY);
    }

    function testFuzz_ExactInputEffectiveFeeMatchesRealV4Fee(uint96 size, uint8 elapsed) public {
        uint256 amount = bound(uint256(size), 1e9, 4_000 ether);
        vm.roll(START + bound(uint256(elapsed), 1, 99));
        PoolKey memory control = _control(hook.currentBuyFee(id));
        BalanceDelta expected = raw.swap(control, _params(false, -int256(amount)), "");
        BalanceDelta actual = _buy(ALICE, -int256(amount));
        assertEq(actual.amount1(), -int256(amount));
        assertApproxEqAbs(uint128(actual.amount0()), uint128(expected.amount0()), 2);
        assertEq(hook.bought(id, ALICE), uint128(actual.amount0()));
        _cleanAccounting();
    }

    function testFuzz_ExactOutputEffectiveFeeMatchesRealV4Fee(uint96 size, uint8 elapsed) public {
        uint256 amount = bound(uint256(size), 1e9, 4_000 ether);
        vm.roll(START + bound(uint256(elapsed), 1, 99));
        PoolKey memory control = _control(hook.currentBuyFee(id));
        BalanceDelta expected = raw.swap(control, _params(false, int256(amount)), "");
        BalanceDelta actual = _buy(ALICE, int256(amount));
        assertEq(actual.amount0(), int256(amount));
        assertApproxEqAbs(uint256(-int256(actual.amount1())), uint256(-int256(expected.amount1())), 2);
        _cleanAccounting();
    }

    function test_SurplusDonatedAndCollectibleByLPExactInput() public {
        vm.roll(START + 1);
        uint256 gross = 1_000 ether;
        uint256 surplus = gross * (hook.currentBuyFee(id) - 10_000) / 990_000;
        vm.recordLogs();
        BalanceDelta d = _buy(ALICE, -int256(gross));
        _assertDonation(vm.getRecordedLogs(), 0, surplus);
        uint256 before = token1.balanceOf(address(this));
        BalanceDelta fees = router.modifyLiquidity(key, 0, 0, 0, block.timestamp);
        uint256 poolFee = ((gross - surplus) * 10_000 + 999_999) / 1_000_000;
        assertApproxEqAbs(uint128(fees.amount1()), surplus + poolFee, 2);
        assertEq(token1.balanceOf(address(this)) - before, uint128(fees.amount1()));
        assertEq(token0.balanceOf(address(manager)), hook.launch(id).initialTokenReserve - uint128(d.amount0()));
        _cleanAccounting();
    }

    function test_SurplusDonatedAndCollectibleByLPExactOutput() public {
        vm.roll(START + 50);
        PoolKey memory control = _control(10_000);
        BalanceDelta normal = raw.swap(control, _params(false, int256(100 ether)), "");
        uint256 coreInput = uint256(-int256(normal.amount1()));
        uint256 surplus = (coreInput * 245_000 + 744_999) / 745_000;
        vm.recordLogs();
        BalanceDelta actual = _buy(ALICE, int256(100 ether));
        _assertDonation(vm.getRecordedLogs(), 0, surplus);
        assertEq(uint256(-int256(actual.amount1())), coreInput + surplus);
        BalanceDelta fees = router.modifyLiquidity(key, 0, 0, 0, block.timestamp);
        assertGt(uint128(fees.amount1()), surplus);
        _cleanAccounting();
    }

    function _assertDonation(Vm.Log[] memory logs, uint256 amount0, uint256 amount1) internal view {
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager)
                    && logs[i].topics[0] == keccak256("Donate(bytes32,address,uint256,uint256)")
            ) {
                assertEq(logs[i].topics[1], PoolId.unwrap(id));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(hook));
                (uint256 a, uint256 b) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(a, amount0);
                assertEq(b, amount1);
                found = true;
            }
        }
        assertTrue(found, "missing PoolManager donation");
    }

    function test_ReverseTokenOrientationAndIndependentPools() public {
        PoolKey memory reverse = key;
        reverse.tickSpacing = 120;
        PoolId reverseId = hook.initialize(
            reverse, PRICE, _settings(address(token1)), LIQUIDITY, type(uint256).max, type(uint256).max
        );
        vm.roll(START + 1);
        vm.prank(ALICE);
        BalanceDelta d = router.swap(reverse, _params(true, -int256(100 ether)), 0, block.timestamp);
        assertEq(hook.bought(reverseId, ALICE), uint128(d.amount1()));
        vm.roll(START + 2);
        vm.prank(ALICE);
        d = router.swap(reverse, _params(true, int256(100 ether)), type(uint256).max, block.timestamp);
        assertEq(d.amount1(), int128(100 ether));
        _buy(ALICE, int256(100 ether));
        assertEq(hook.bought(id, ALICE), 100 ether);
        vm.prank(ALICE);
        router.swap(reverse, _params(false, -int256(100 ether)), 0, block.timestamp);
        _cleanAccounting();
    }

    function test_SlippageAndDeadlineRollbackBuyState() public {
        vm.roll(START + 1);
        vm.prank(ALICE);
        vm.expectRevert(LaunchRouter.Slippage.selector);
        router.swap(key, _params(false, -int256(100 ether)), 100 ether, block.timestamp);
        assertEq(hook.bought(id, ALICE), 0);
        vm.prank(ALICE);
        vm.expectRevert(LaunchRouter.Slippage.selector);
        router.swap(key, _params(false, int256(100 ether)), 1, block.timestamp);
        assertEq(hook.lastBuyBlock(id, ALICE), 0);
        vm.prank(ALICE);
        vm.expectRevert(LaunchRouter.Expired.selector);
        router.swap(key, _params(false, int256(100 ether)), type(uint256).max, block.timestamp - 1);
        _buy(ALICE, int256(100 ether));
    }

    function test_PartialFillsRevertForBothModes() public {
        vm.roll(START + 1);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(false, -int256(100 ether), PRICE + 1);
        vm.prank(ALICE);
        vm.expectRevert();
        router.swap(key, params, 0, block.timestamp);
        params.amountSpecified = int256(100 ether);
        vm.prank(ALICE);
        vm.expectRevert();
        router.swap(key, params, type(uint256).max, block.timestamp);
        assertEq(hook.bought(id, ALICE), 0);
        assertEq(hook.lastBuyBlock(id, ALICE), 0);
    }

    function test_OnlyLPMayRemoveItsLiquidityAndCollectItsFees() public {
        vm.roll(START + 1);
        _buy(ALICE, int256(100 ether));
        vm.prank(MALLORY);
        vm.expectRevert(LaunchRouter.InsufficientLiquidity.selector);
        router.modifyLiquidity(key, -int256(uint256(LIQUIDITY)), 0, 0, block.timestamp);
        uint256 tokenBefore = token0.balanceOf(address(this));
        router.modifyLiquidity(key, -int256(uint256(LIQUIDITY)), 0, 0, block.timestamp);
        assertGt(token0.balanceOf(address(this)), tokenBefore);
        assertEq(router.liquidityOf(id, address(this)), 0);
        _cleanAccounting();
    }

    function test_DirectTransfersAndExtraLiquidityDoNotInflateCaps() public {
        LaunchGuard.Launch memory before = hook.launch(id);
        token0.transfer(address(manager), 100_000 ether);
        router.modifyLiquidity(key, int256(uint256(LIQUIDITY)), type(uint256).max, type(uint256).max, block.timestamp);
        LaunchGuard.Launch memory after_ = hook.launch(id);
        assertEq(after_.maxBuy, before.maxBuy);
        assertEq(after_.maxAddress, before.maxAddress);
        assertEq(after_.initialTokenReserve, before.initialTokenReserve);
    }

    function test_NormalStartingFeeStillEnforcesLimitsAndDoesNotDonate() public {
        PoolKey memory other = key;
        other.tickSpacing = 120;
        LaunchGuard.Settings memory s = _settings(address(token0));
        s.startFee = 10_000;
        PoolId otherId = hook.initialize(other, PRICE, s, LIQUIDITY, type(uint256).max, type(uint256).max);
        vm.roll(START + 1);
        vm.recordLogs();
        vm.prank(ALICE);
        router.swap(other, _params(false, int256(100 ether)), type(uint256).max, block.timestamp);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != keccak256("Donate(bytes32,address,uint256,uint256)"));
        }
        assertEq(hook.bought(otherId, ALICE), 100 ether);
        assertEq(hook.currentBuyFee(otherId), 10_000);
    }

    function test_ProtocolFeeFailsClosed() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, 100);
        vm.roll(START + 1);
        vm.expectRevert(_hookError(IHooks.beforeSwap.selector, LaunchGuard.ProtocolFeeEnabled.selector));
        _buy(ALICE, int256(100 ether));
        manager.setProtocolFee(key, 0);
        _buy(ALICE, int256(100 ether));
    }

    function test_PaymentFailureRollsBackDonationAndLimits() public {
        vm.roll(START + 1);
        vm.prank(ALICE);
        token1.approve(address(router), 0);
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(id);
        (uint160 beforePrice,,,) = manager.getSlot0(id);
        vm.expectRevert("TRANSFER_FROM_FAILED");
        _buy(ALICE, int256(100 ether));
        assertEq(hook.bought(id, ALICE), 0);
        assertEq(hook.lastBuyBlock(id, ALICE), 0);
        (uint256 after0, uint256 after1) = manager.getFeeGrowthGlobals(id);
        (uint160 afterPrice,,,) = manager.getSlot0(id);
        assertEq(after0, growth0);
        assertEq(after1, growth1);
        assertEq(afterPrice, beforePrice);
        vm.prank(ALICE);
        token1.approve(address(router), type(uint256).max);
        _buy(ALICE, int256(100 ether));
        _cleanAccounting();
    }

    function test_CumulativeCapAlsoRejectsExactInput() public {
        vm.roll(START + 1);
        _buy(ALICE, int256(4_500 ether));
        vm.roll(START + 2);
        _buy(ALICE, int256(4_500 ether));
        vm.roll(START + 3);
        vm.expectRevert(_hookError(IHooks.afterSwap.selector, LaunchGuard.MaxAddressExceeded.selector));
        _buy(ALICE, -int256(4_000 ether));
        assertEq(hook.bought(id, ALICE), 9_000 ether);
        assertEq(hook.lastBuyBlock(id, ALICE), START + 2);
    }

    function test_OneBlockWindowHasOnlyFirstBlockRejection() public {
        PoolKey memory other = key;
        other.tickSpacing = 120;
        LaunchGuard.Settings memory s = _settings(address(token0));
        s.windowBlocks = 1;
        PoolId otherId = hook.initialize(other, PRICE, s, LIQUIDITY, type(uint256).max, type(uint256).max);
        vm.prank(ALICE);
        vm.expectRevert(_hookError(IHooks.beforeSwap.selector, LaunchGuard.FirstBlock.selector));
        router.swap(other, _params(false, int256(100 ether)), type(uint256).max, block.timestamp);
        vm.roll(START + 1);
        assertEq(hook.currentBuyFee(otherId), 10_000);
        vm.prank(ALICE);
        router.swap(other, _params(false, int256(20_000 ether)), type(uint256).max, block.timestamp);
        assertEq(hook.bought(otherId, ALICE), 0);
    }

    function testFuzz_FeeDecayRoundingAndMaximumWindow(uint16 window, uint24 startFee) public {
        window = uint16(bound(uint256(window), 1, 300));
        startFee = uint24(bound(uint256(startFee), 10_000, 500_000));
        PoolKey memory other = key;
        other.tickSpacing = 120;
        LaunchGuard.Settings memory s = _settings(address(token0));
        s.windowBlocks = window;
        s.startFee = startFee;
        PoolId otherId = hook.initialize(other, PRICE, s, LIQUIDITY, type(uint256).max, type(uint256).max);
        uint256 previous = startFee;
        for (uint256 elapsed; elapsed <= window; ++elapsed) {
            vm.roll(START + elapsed);
            uint256 fee = hook.currentBuyFee(otherId);
            assertLe(fee, previous);
            assertEq(fee, 10_000 + uint256(startFee - 10_000) * (window - elapsed) / window);
            previous = fee;
        }
        assertEq(previous, 10_000);
    }

    function test_TinySwapCannotCreateFreeOutput() public {
        vm.roll(START + 1);
        vm.expectRevert(_hookError(IHooks.afterSwap.selector, LaunchGuard.InvalidSwap.selector));
        _buy(ALICE, -int256(1));
        assertEq(hook.bought(id, ALICE), 0);
        BalanceDelta d = _buy(ALICE, int256(1));
        assertEq(d.amount0(), 1);
        assertGt(uint256(-int256(d.amount1())), 1);
        _cleanAccounting();
    }
}
