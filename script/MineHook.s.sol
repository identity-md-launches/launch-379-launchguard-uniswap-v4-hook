// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LaunchGuard} from "../src/LaunchGuard.sol";
import {HookMiner} from "./HookMiner.sol";
import {LaunchGuardDeployer} from "../src/LaunchGuardDeployer.sol";

/// @notice Computes a candidate for any CREATE2 deployer. No RPC, wallet, filesystem or broadcast.
contract MineHook is Script {
    function run() external pure returns (address deployer, address hook, bytes32 salt, bytes32 codeHash) {
        address proxy = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        bytes32 deployerSalt = keccak256("LaunchGuard CREATE2 deployer v1");
        deployer = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), proxy, deployerSalt, keccak256(type(LaunchGuardDeployer).creationCode)
                        )
                    )
                )
            )
        );
        console2.log("Candidate CREATE2 deployer", deployer);
        (hook, salt, codeHash) = _mine(deployer, 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    }

    function run(address deployer, address manager)
        external
        pure
        returns (address hook, bytes32 salt, bytes32 codeHash)
    {
        return _mine(deployer, manager);
    }

    function _mine(address deployer, address manager)
        private
        pure
        returns (address hook, bytes32 salt, bytes32 codeHash)
    {
        codeHash = keccak256(abi.encodePacked(type(LaunchGuard).creationCode, abi.encode(IPoolManager(manager))));
        (hook, salt) = HookMiner.find(deployer, codeHash);
        console2.log("Candidate (not a deployment)", hook);
        console2.log("Salt");
        console2.logBytes32(salt);
        console2.log("Init code hash");
        console2.logBytes32(codeHash);
    }
}
