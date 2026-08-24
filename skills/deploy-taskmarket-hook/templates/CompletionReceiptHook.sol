// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTMPHook} from "./BaseTMPHook.sol";
import {ITMPCore} from "@taskmarket/contracts/src/interfaces/ITMPCore.sol";

/// @notice Reference template: records completion evidence without blocking payout.
/// @dev Copy to src/Hook.sol and rename the contract to Hook before deployment.
contract CompletionReceiptHook is BaseTMPHook {
    mapping(bytes32 taskId => bytes32 evidenceHash) public completionEvidence;
    mapping(bytes32 taskId => bool observed) public completionObserved;

    event CompletionObserved(bytes32 indexed taskId, address indexed requester, bytes32 evidenceHash);

    constructor(address diamond_) BaseTMPHook(diamond_) {}

    function _onComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict)
        internal
        override
    {
        if (completionObserved[taskId]) return;
        completionObserved[taskId] = true;
        completionEvidence[taskId] = verdict.evidenceHash;
        emit CompletionObserved(taskId, ctx.requester, verdict.evidenceHash);
    }
}
