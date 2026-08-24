// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTMPHook} from "./BaseTMPHook.sol";
import {ITMPCore} from "@taskmarket/contracts/src/interfaces/ITMPCore.sol";

/// @notice Brief-driven TaskMarket lifecycle hook scaffold.
/// @dev Keep the contract name and constructor shape. BaseTMPHook enforces the
///      immutable Diamond caller boundary and the canonical ITMPHook interface.
contract Hook is BaseTMPHook {
    mapping(bytes32 taskId => bytes32 evidenceHash) public completionEvidence;
    mapping(bytes32 taskId => bool observed) public completionObserved;

    event CompletionObserved(bytes32 indexed taskId, address indexed requester, bytes32 evidenceHash);

    constructor(address diamond_) BaseTMPHook(diamond_) {}

    // --- AEON:BODY START ---
    // Default = a best-effort completion receipt. Replace this region with the
    // smallest policy that satisfies the brief. Override internal _check* methods
    // for blocking policy and _on* methods for best-effort effects; never redefine
    // the external callbacks or the BaseTMPHook caller guard.
    function _onComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict)
        internal
        override
    {
        if (completionObserved[taskId]) return;
        completionObserved[taskId] = true;
        completionEvidence[taskId] = verdict.evidenceHash;
        emit CompletionObserved(taskId, ctx.requester, verdict.evidenceHash);
    }
    // --- AEON:BODY END ---
}
