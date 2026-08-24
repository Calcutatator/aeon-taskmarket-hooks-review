// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ITMPCore} from "@taskmarket/contracts/src/interfaces/ITMPCore.sol";
import {ITMPHook} from "@taskmarket/contracts/src/interfaces/ITMPHook.sol";
import {BaseTMPHook} from "../src/BaseTMPHook.sol";
import {Hook} from "../src/Hook.sol";

/// @notice Target-chain rehearsal: binds the generated hook to the exact live Diamond.
contract HookForkRehearsalTest is Test {
    function testForkTargetAndCallerBoundary() public {
        address diamond = vm.envAddress("TASKMARKET_DIAMOND");
        uint256 expectedChainId = vm.envUint("TASKMARKET_CHAIN_ID");
        bytes32 expectedCodehash = vm.envBytes32("TASKMARKET_DIAMOND_CODEHASH");

        assertEq(block.chainid, expectedChainId, "wrong RPC chain");
        assertGt(diamond.code.length, 0, "TaskMarket Diamond has no code");
        assertEq(diamond.codehash, expectedCodehash, "unexpected TaskMarket Diamond runtime");

        Hook hook = new Hook(diamond);
        assertEq(hook.diamond(), diamond);
        assertTrue(hook.supportsInterface(type(ITMPHook).interfaceId));
        assertLt(address(hook).code.length, 24_576, "hook exceeds EIP-170 runtime limit");

        ITMPCore.TaskContext memory ctx;
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHook.BaseTMPHook__UnauthorizedCaller.selector, address(this)));
        hook.checkFund(bytes32(0), ctx, bytes(""));
    }
}
