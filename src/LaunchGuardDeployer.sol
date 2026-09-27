// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LaunchGuard} from "./LaunchGuard.sol";

/// @notice Permissionless CREATE2 deployment. No privilege is assigned to the caller or deployer.
contract LaunchGuardDeployer {
    event Deployed(address indexed hook, address indexed manager, bytes32 salt);

    function deploy(IPoolManager manager, bytes32 salt) external returns (LaunchGuard hook) {
        hook = new LaunchGuard{salt: salt}(manager);
        emit Deployed(address(hook), address(manager), salt);
    }

    function initCodeHash(IPoolManager manager) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(type(LaunchGuard).creationCode, abi.encode(manager)));
    }

    function predict(IPoolManager manager, bytes32 salt) external view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash(manager)))))
        );
    }
}
