// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TMP_BOUNTY, TMP_CLAIM} from "@taskmarket/contracts/src/interfaces/ITMPModes.sol";
import {BaseTMPHook} from "./BaseTMPHook.sol";
import {ITMPCore} from "@taskmarket/contracts/src/interfaces/ITMPCore.sol";

/// @notice Reference template: immutable worker admission for Bounty and Claim.
/// @dev Pitch, Benchmark, and Auction are rejected at funding because their entry
///      paths can bypass claim/select. This mirrors the reviewed PR #599 behavior.
contract AllowlistedWorkerHook is BaseTMPHook {
    address public constant ALLOWED_WORKER = 0x1111111111111111111111111111111111111111;
    uint256 public constant MAX_AWARDS = 32;

    constructor(address diamond_) BaseTMPHook(diamond_) {}

    function _checkFund(bytes32, ITMPCore.TaskContext calldata ctx, bytes calldata)
        internal
        pure
        override
        returns (bool)
    {
        return ctx.mode == TMP_BOUNTY || ctx.mode == TMP_CLAIM;
    }

    function _checkClaim(bytes32, ITMPCore.TaskContext calldata, address worker) internal pure override returns (bool) {
        return worker == ALLOWED_WORKER;
    }

    function _checkSelectWorker(bytes32, ITMPCore.TaskContext calldata, address worker)
        internal
        pure
        override
        returns (bool)
    {
        return worker == ALLOWED_WORKER;
    }

    function _checkSubmit(bytes32, ITMPCore.TaskContext calldata, address worker, bytes32)
        internal
        pure
        override
        returns (bool)
    {
        return worker == ALLOWED_WORKER;
    }

    function _checkComplete(bytes32, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata verdict)
        internal
        pure
        override
        returns (bool)
    {
        if (verdict.awards.length > MAX_AWARDS) return false;
        for (uint256 i; i < verdict.awards.length; ++i) {
            if (verdict.awards[i].worker != ALLOWED_WORKER) return false;
        }
        return true;
    }
}
