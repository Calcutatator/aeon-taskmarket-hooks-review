// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ITMPCore} from "@taskmarket/contracts/src/interfaces/ITMPCore.sol";
import {ITMPHook} from "@taskmarket/contracts/src/interfaces/ITMPHook.sol";
import {Hook} from "../src/Hook.sol";
import {HookFixture} from "./HookFixture.sol";

/// @notice Synthetic callback ABI/gas conformance test (not the Diamond integration).
/// @dev Generated policies edit HookFixture.sol so the positive path satisfies
///      their rule. This callback order and gas ceiling stay hash-pinned.
contract HookCallbackConformanceTest is Test {
    uint256 internal constant CALLBACK_GAS_LIMIT = 1_000_000;
    address internal constant DIAMOND = address(0xD1A);
    Hook internal hook;

    function setUp() public {
        hook = new Hook(DIAMOND);
    }

    function testInterfaceIdIsPinned() public view {
        assertEq(type(ITMPHook).interfaceId, bytes4(0x2187b4de));
        assertTrue(hook.supportsInterface(type(ITMPHook).interfaceId));
        assertEq(hook.diamond(), DIAMOND);
    }

    function testPositiveLifecycleAndCallbackGasCeiling() public {
        (ITMPCore.TaskContext memory ctx, ITMPCore.Verdict memory verdict) = HookFixture.callbackFixture();
        address worker = HookFixture.worker();
        address evaluator = HookFixture.evaluator();
        ctx.currentState = ITMPCore.TaskStatus.Open;
        _measureBool("checkFund gas", abi.encodeCall(ITMPHook.checkFund, (ctx.taskId, ctx, HookFixture.hookData())));

        ctx.currentState = ITMPCore.TaskStatus.Claimed;
        _measureBool("checkClaim gas", abi.encodeCall(ITMPHook.checkClaim, (ctx.taskId, ctx, worker)));

        ctx.currentState = ITMPCore.TaskStatus.WorkerSelected;
        _measureBool("checkSelectWorker gas", abi.encodeCall(ITMPHook.checkSelectWorker, (ctx.taskId, ctx, worker)));

        ctx.currentState = ITMPCore.TaskStatus.PendingApproval;
        _measureBool(
            "checkSubmit gas", abi.encodeCall(ITMPHook.checkSubmit, (ctx.taskId, ctx, worker, keccak256("deliverable")))
        );

        ctx.currentState = ITMPCore.TaskStatus.Review;
        _measureBool("checkEvaluate gas", abi.encodeCall(ITMPHook.checkEvaluate, (ctx.taskId, ctx, evaluator)));

        ctx.currentState = ITMPCore.TaskStatus.Accepted;
        _measureBool("checkComplete gas", abi.encodeCall(ITMPHook.checkComplete, (ctx.taskId, ctx, verdict)));
        _measureVoid("onComplete gas", abi.encodeCall(ITMPHook.onComplete, (ctx.taskId, ctx, verdict)));
        _measureVoid("onForfeit gas", abi.encodeCall(ITMPHook.onForfeit, (ctx.taskId, ctx, worker)));
        _measureVoid("onCancel gas", abi.encodeCall(ITMPHook.onCancel, (ctx.taskId, ctx)));
        _measureVoid("onExpire gas", abi.encodeCall(ITMPHook.onExpire, (ctx.taskId, ctx)));
    }

    function _measureBool(string memory label, bytes memory payload) internal {
        vm.cool(address(hook));
        vm.prank(DIAMOND);
        uint256 beforeGas = gasleft();
        (bool ok, bytes memory result) = address(hook).call(payload);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint(label, used);
        if (used > 800_000) emit log_named_string("gas review", "above 800,000 headroom threshold");
        assertTrue(ok, "positive lifecycle callback reverted");
        assertTrue(abi.decode(result, (bool)), "positive lifecycle callback rejected");
        assertLt(used, CALLBACK_GAS_LIMIT, "callback exceeds TaskMarket gas stipend");
    }

    function _measureVoid(string memory label, bytes memory payload) internal {
        vm.cool(address(hook));
        vm.prank(DIAMOND);
        uint256 beforeGas = gasleft();
        (bool ok,) = address(hook).call(payload);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint(label, used);
        if (used > 800_000) emit log_named_string("gas review", "above 800,000 headroom threshold");
        assertTrue(ok, "positive lifecycle callback reverted");
        assertLt(used, CALLBACK_GAS_LIMIT, "callback exceeds TaskMarket gas stipend");
    }
}
