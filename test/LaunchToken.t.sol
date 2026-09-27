// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    function test_FixedSupplyTransferAndAllowance() public {
        LaunchToken token = new LaunchToken();
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "LaunchGuard");
        assertEq(token.symbol(), "GUARD");
        token.transfer(address(1), 100 ether);
        assertEq(token.balanceOf(address(1)), 100 ether);
        token.approve(address(2), 50 ether);
        vm.prank(address(2));
        token.transferFrom(address(this), address(1), 50 ether);
        assertEq(token.balanceOf(address(1)), 150 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        vm.prank(address(2));
        vm.expectRevert();
        token.transferFrom(address(this), address(1), 1);
    }

    function test_NoAdminOrMintEntrypoints() public {
        LaunchToken token = new LaunchToken();
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("transferOwnership(address)", address(1)));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
