// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITMPCore} from "@taskmarket/contracts/src/interfaces/ITMPCore.sol";
import {TMP_BOUNTY, TMP_AUCTION_ENGLISH} from "@taskmarket/contracts/src/interfaces/ITMPModes.sol";

/// @notice The only editable positive-path fixture shared by the immutable
///         callback-gas and real-Diamond lifecycle harnesses.
library HookFixture {
    // --- AEON:FIXTURE START ---
    function worker() internal pure returns (address) {
        return address(0xBEEF);
    }

    function evaluator() internal pure returns (address) {
        return address(0xE1A1);
    }

    function hookData() internal pure returns (bytes memory) {
        return hex"";
    }

    function taskConfig() internal pure returns (ITMPCore.TaskConfig memory config) {
        config.reward = 100e6;
        config.duration = 1 days;
        config.mode = TMP_BOUNTY;
        // Set these when selecting Pitch or Auction mode.
        config.pitchDeadline = 0;
        config.bidDeadline = 0;
        config.auctionSubtype = TMP_AUCTION_ENGLISH;
    }

    function deliverable() internal pure returns (bytes32) {
        return keccak256("aeon-generated-hook-lifecycle-deliverable");
    }

    function bidAmount() internal pure returns (uint256) {
        return 50e6;
    }

    function tags() internal pure returns (bytes32[] memory values) {
        values = new bytes32[](0);
    }

    function callbackFixture()
        internal
        view
        returns (ITMPCore.TaskContext memory ctx, ITMPCore.Verdict memory verdict)
    {
        ctx.taskId = keccak256("lifecycle-task");
        ctx.requester = address(0xA11CE);
        ctx.evaluator = evaluator();
        ctx.paymentToken = address(0x1234);
        ITMPCore.TaskConfig memory config = taskConfig();
        ctx.reward = config.reward;
        ctx.submissionDeadline = block.timestamp + 1 days;
        ctx.evaluationWindow = 1 days;
        ctx.appealWindow = 1 days;
        ctx.mode = config.mode;
        ctx.tags = tags();
        verdict.issued = true;
        verdict.verdictType = ITMPCore.VerdictType.APPROVE;
        verdict.score = 10_000;
        verdict.confidence = 10_000;
        verdict.evidenceHash = keccak256("evidence");
        verdict.criteriaFlags = new bytes32[](0);
        verdict.awards = new ITMPCore.Award[](0);
    }
    // --- AEON:FIXTURE END ---
}
