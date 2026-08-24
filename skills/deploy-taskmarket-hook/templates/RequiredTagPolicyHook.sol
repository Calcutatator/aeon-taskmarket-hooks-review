// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTMPHook} from "./BaseTMPHook.sol";
import {ITMPCore} from "@taskmarket/contracts/src/interfaces/ITMPCore.sol";

/// @notice Reference template: rejects funding unless the task carries one tag.
/// @dev Copy to src/Hook.sol, rename to Hook, and set REQUIRED_TAG to the brief's tag.
contract RequiredTagPolicyHook is BaseTMPHook {
    bytes32 public constant REQUIRED_TAG = keccak256("replace-me");
    uint256 public constant MAX_TAGS = 32;

    constructor(address diamond_) BaseTMPHook(diamond_) {}

    function _checkFund(bytes32, ITMPCore.TaskContext calldata ctx, bytes calldata)
        internal
        pure
        override
        returns (bool)
    {
        if (ctx.tags.length > MAX_TAGS) return false;
        for (uint256 i; i < ctx.tags.length; ++i) {
            if (ctx.tags[i] == REQUIRED_TAG) return true;
        }
        return false;
    }
}
