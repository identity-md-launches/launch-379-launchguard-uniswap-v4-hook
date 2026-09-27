// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Offline CREATE2 salt search; also used by the integration tests.
library HookMiner {
    error SaltNotFound();

    function find(address deployer, bytes32 initCodeHash) internal pure returns (address hook, bytes32 salt) {
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            hook = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if (uint160(hook) & 0x3fff == 0x20cc) return (hook, salt);
        }
        revert SaltNotFound();
    }
}
