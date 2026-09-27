// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Fixed supply; no administrator or post-construction mint path.
contract LaunchToken is ERC20 {
    constructor() ERC20("LaunchGuard", "GUARD", 18) {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
