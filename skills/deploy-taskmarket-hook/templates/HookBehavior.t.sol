// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ITMPCore} from "@taskmarket/contracts/src/interfaces/ITMPCore.sol";
import {TMP_BOUNTY} from "@taskmarket/contracts/src/interfaces/ITMPModes.sol";
import {BaseTMPHook} from "../src/BaseTMPHook.sol";
import {Hook} from "../src/Hook.sol";

/// @notice Brief-specific behavioral gate. Replace only the AEON:ASSERT region.
contract HookBehaviorTest is Test {
    address internal constant DIAMOND = address(0xD1A);
    address internal constant REQUESTER = address(0xA11CE);
    Hook internal hook;

    function setUp() public {
        hook = new Hook(DIAMOND);
    }

    function _context() internal view returns (ITMPCore.TaskContext memory ctx) {
        ctx.taskId = keccak256("behavior-task");
        ctx.requester = REQUESTER;
        ctx.paymentToken = address(0x1234);
        ctx.reward = 1_000_000;
        ctx.submissionDeadline = block.timestamp + 1 days;
        ctx.currentState = ITMPCore.TaskStatus.Accepted;
        ctx.mode = TMP_BOUNTY;
        ctx.tags = new bytes32[](0);
    }

    function _verdict() internal pure returns (ITMPCore.Verdict memory verdict) {
        verdict.issued = true;
        verdict.verdictType = ITMPCore.VerdictType.APPROVE;
        verdict.score = 10_000;
        verdict.confidence = 10_000;
        verdict.evidenceHash = keccak256("evidence");
        verdict.criteriaFlags = new bytes32[](0);
        verdict.awards = new ITMPCore.Award[](0);
    }

    // --- AEON:ASSERT START ---
    function testPositiveRecordsCompletionEvidence() public {
        ITMPCore.TaskContext memory ctx = _context();
        ITMPCore.Verdict memory verdict = _verdict();
        vm.prank(DIAMOND);
        hook.onComplete(ctx.taskId, ctx, verdict);
        assertTrue(hook.completionObserved(ctx.taskId));
        assertEq(hook.completionEvidence(ctx.taskId), verdict.evidenceHash);

        verdict.evidenceHash = keccak256("replayed-evidence");
        vm.prank(DIAMOND);
        hook.onComplete(ctx.taskId, ctx, verdict);
        assertEq(hook.completionEvidence(ctx.taskId), keccak256("evidence"), "receipt is write-once");
    }

    function testNegativeRejectsUnauthorizedCaller() public {
        ITMPCore.TaskContext memory ctx = _context();
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHook.BaseTMPHook__UnauthorizedCaller.selector, address(this)));
        hook.checkFund(ctx.taskId, ctx, bytes(""));
    }
    // --- AEON:ASSERT END ---
}
