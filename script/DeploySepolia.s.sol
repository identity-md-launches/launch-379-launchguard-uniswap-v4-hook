// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LaunchGuard} from "../src/LaunchGuard.sol";
import {LaunchGuardDeployer} from "../src/LaunchGuardDeployer.sol";
import {HookMiner} from "./HookMiner.sol";
import {DemoQuote} from "./DemoQuote.sol";

/// @notice Operator supplies a signer through Foundry CLI; no keys or environment reads in Solidity.
contract DeploySepolia is Script {
    IPoolManager public constant SEPOLIA_MANAGER = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    uint160 public constant INITIAL_PRICE = 79228162514264337593543950336;
    uint128 public constant INITIAL_LIQUIDITY = 1_000_000 ether;
    bytes32 public constant DEPLOYER_SALT = keccak256("LaunchGuard CREATE2 deployer v1");

    struct Deployment {
        LaunchToken token;
        DemoQuote quote;
        LaunchGuardDeployer deployer;
        LaunchGuard hook;
        PoolKey key;
        PoolId poolId;
        bytes32 salt;
    }

    function run(address operator) external returns (Deployment memory result) {
        require(block.chainid == 11155111, "Sepolia only");
        require(operator != address(0), "missing operator");
        vm.startBroadcast(operator);
        result = deployDemo(SEPOLIA_MANAGER);
        vm.stopBroadcast();
        console2.log("LaunchToken", address(result.token));
        console2.log("DemoQuote", address(result.quote));
        console2.log("CREATE2 deployer", address(result.deployer));
        console2.log("LaunchGuard", address(result.hook));
        console2.log("LaunchRouter", address(result.hook.router()));
        console2.log("Hook salt");
        console2.logBytes32(result.salt);
        console2.log("Pool id");
        console2.logBytes32(PoolId.unwrap(result.poolId));
    }

    /// @dev This exact deployment path is tested against a fresh local PoolManager, without broadcast or env.
    function deployDemo(IPoolManager manager) public returns (Deployment memory d) {
        require(address(manager).code.length != 0, "missing PoolManager code");
        d.token = new LaunchToken();
        d.quote = new DemoQuote();
        // Foundry uses its canonical CREATE2 proxy for this creation while broadcasting.
        // Normal Solidity callers (including tests) use their own address as the CREATE2 deployer.
        d.deployer = new LaunchGuardDeployer{salt: DEPLOYER_SALT}();
        (address predicted, bytes32 salt) = HookMiner.find(address(d.deployer), d.deployer.initCodeHash(manager));
        d.salt = salt;
        d.hook = d.deployer.deploy(manager, salt);
        require(address(d.hook) == predicted, "CREATE2 mismatch");
        address a = address(d.token);
        address b = address(d.quote);
        d.key = PoolKey(
            Currency.wrap(a < b ? a : b),
            Currency.wrap(a < b ? b : a),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(d.hook))
        );
        // Exact, bounded approvals; initialization measures the real token reserve, not this allowance.
        d.token.approve(address(d.hook.router()), INITIAL_LIQUIDITY);
        d.quote.approve(address(d.hook.router()), INITIAL_LIQUIDITY);
        d.poolId = d.hook
            .initialize(
                d.key,
                INITIAL_PRICE,
                LaunchGuard.Settings(a, 100, 500_000, 50, 100),
                INITIAL_LIQUIDITY,
                INITIAL_LIQUIDITY,
                INITIAL_LIQUIDITY
            );
        d.token.approve(address(d.hook.router()), 0);
        d.quote.approve(address(d.hook.router()), 0);
    }
}
