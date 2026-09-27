// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {DeploySepolia} from "../script/DeploySepolia.s.sol";
import {LaunchGuard} from "../src/LaunchGuard.sol";

contract DeploymentTest is Test {
    function test_ExactDemoDeploymentPathAndRuntimeConstraints() public {
        IPoolManager manager = IPoolManager(address(new PoolManager(address(this))));
        DeploySepolia script = new DeploySepolia();
        DeploySepolia.Deployment memory d = script.deployDemo(manager);
        assertEq(d.token.totalSupply(), 1_000_000_000 ether);
        assertEq(uint160(address(d.hook)) & 0x3fff, 0x20cc);
        assertEq(address(d.hook.manager()), address(manager));
        assertEq(address(d.hook.router().manager()), address(manager));
        assertEq(d.hook.router().hook(), address(d.hook));
        assertEq(d.deployer.predict(manager, d.salt), address(d.hook));
        LaunchGuard.Launch memory l = d.hook.launch(d.poolId);
        assertEq(l.initialTokenReserve, d.token.balanceOf(address(manager)));
        assertEq(l.settings.token, address(d.token));
        assertTrue(l.ready);
        assertEq(d.hook.router().liquidityOf(d.poolId, address(script)), 1_000_000 ether);
        assertEq(d.token.allowance(address(script), address(d.hook.router())), 0);
        _runtime(address(d.token));
        _runtime(address(d.hook));
        _runtime(address(d.hook.router()));
        _runtime(address(d.deployer));
    }

    function _runtime(address target) internal view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
