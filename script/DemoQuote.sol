// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Valueless fixed-supply quote token used only by the Sepolia demo.
contract DemoQuote is ERC20 {
    constructor() ERC20("LaunchGuard Demo Dollar", "dUSD", 18) {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
