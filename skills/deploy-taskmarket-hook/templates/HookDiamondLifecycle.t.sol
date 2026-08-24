// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {ITMPCore} from "@taskmarket/contracts/src/interfaces/ITMPCore.sol";
import {ITMPDiamond} from "@taskmarket/contracts/src/interfaces/ITMPDiamond.sol";
import {
    TMP_BOUNTY,
    TMP_CLAIM,
    TMP_PITCH,
    TMP_BENCHMARK,
    TMP_AUCTION
} from "@taskmarket/contracts/src/interfaces/ITMPModes.sol";
import {MockERC20} from "@taskmarket/contracts/src/mocks/MockERC20.sol";
import {DiamondTestHelper} from "@taskmarket/contracts/test/helpers/DiamondTestHelper.sol";
import {noEvaluatorConfig} from "@taskmarket/contracts/test/helpers/EvaluatorConfigHelper.sol";
import {MockPGTRForwarder} from "@taskmarket/contracts/test/mocks/MockPGTRForwarder.sol";
import {BaseTMPHook} from "../src/BaseTMPHook.sol";
import {Hook} from "../src/Hook.sol";
import {HookFixture} from "./HookFixture.sol";

contract RecordingAfterHook is BaseTMPHook {
    mapping(bytes32 taskId => uint256 calls) public completionCalls;

    constructor(address diamond_) BaseTMPHook(diamond_) {}

    function _onComplete(bytes32 taskId, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata) internal override {
        ++completionCalls[taskId];
    }
}

contract RevertingAfterHook is BaseTMPHook {
    constructor(address diamond_) BaseTMPHook(diamond_) {}

    function _onComplete(bytes32, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata) internal pure override {
        revert("expected onComplete failure");
    }
}

contract ExpiryHostileHook is BaseTMPHook {
    constructor(address diamond_) BaseTMPHook(diamond_) {}

    function _onExpire(bytes32, ITMPCore.TaskContext calldata) internal pure override {
        revert("expected onExpire failure");
    }
}

contract RejectFundHook is BaseTMPHook {
    constructor(address diamond_) BaseTMPHook(diamond_) {}

    function _checkFund(bytes32, ITMPCore.TaskContext calldata, bytes calldata) internal pure override returns (bool) {
        return false;
    }
}

/// @notice PR #609 local integration: fresh Diamond, PGTR funding, one default
///         and three custom hooks, ordered attachment, submit, accept, completion.
contract HookDiamondLifecycleTest is DiamondTestHelper {
    bytes32 private constant HOOK_REGISTERED = keccak256("HookRegistered(bytes32,address)");
    uint256 private constant REWARD = 100e6;

    address private constant OWNER = address(1);
    address private constant FEE_RECIPIENT = address(2);
    address private constant REQUESTER = address(3);

    ITMPDiamond private market;
    MockERC20 private usdc;
    MockPGTRForwarder private forwarder;

    function setUp() public {
        vm.startPrank(OWNER);
        usdc = new MockERC20("Mock USDC", "USDC", 6, OWNER);
        market = deployDiamond(OWNER, address(usdc), FEE_RECIPIENT, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        usdc.mint(address(forwarder), 10_000e6);
        vm.stopPrank();
    }

    function testGeneratedHookCompletesRealLocalDiamondLifecycle() public {
        address worker = HookFixture.worker();
        ITMPCore.TaskConfig memory config = HookFixture.taskConfig();
        RecordingAfterHook defaultHook = new RecordingAfterHook(address(market));
        Hook generatedHook = new Hook(address(market));
        RevertingAfterHook revertingHook = new RevertingAfterHook(address(market));
        RecordingAfterHook finalHook = new RecordingAfterHook(address(market));
        address[] memory hooks = new address[](3);
        hooks[0] = address(generatedHook);
        hooks[1] = address(revertingHook);
        hooks[2] = address(finalHook);

        address[] memory defaults = new address[](1);
        defaults[0] = address(defaultHook);
        vm.prank(OWNER);
        market.setDefaultHooks(defaults);

        vm.recordLogs();
        bytes32 taskId = abi.decode(
            forwarder.relay(
                address(market),
                REQUESTER,
                config.reward,
                abi.encodeCall(
                    market.createTask,
                    (
                        config,
                        ITMPCore.StakeConfig({required: false, bps: 0}),
                        ITMPCore.HookConfig({contracts: hooks, data: HookFixture.hookData()}),
                        ITMPCore.TaskContent({contentHash: bytes32(0), contentURI: "", tags: HookFixture.tags()}),
                        noEvaluatorConfig()
                    )
                )
            ),
            (bytes32)
        );

        address[] memory registered = _decodeRegisteredHooks(taskId, 4);
        assertEq(registered[0], address(defaultHook), "default HookRegistered first");
        assertEq(registered[1], address(generatedHook), "generated HookRegistered second");
        assertEq(registered[2], address(revertingHook), "reverting HookRegistered third");
        assertEq(registered[3], address(finalHook), "final HookRegistered fourth");

        address[] memory attached = market.getTaskHooks(taskId);
        assertEq(attached.length, 4, "default and three custom hooks attached");
        assertEq(attached[0], address(defaultHook), "default hook attached first");
        assertEq(attached[1], address(generatedHook), "generated hook attached second");
        assertEq(attached[2], address(revertingHook), "reverting hook attached third");
        assertEq(attached[3], address(finalHook), "final hook attached fourth");

        bytes32 deliverable = HookFixture.deliverable();
        _reachSubmittedState(taskId, config, worker, deliverable);
        forwarder.relay(
            address(market), REQUESTER, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, deliverable, 0))
        );
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted), "task accepted");
        assertEq(defaultHook.completionCalls(taskId), 1, "default terminal callback ran");
        assertEq(finalHook.completionCalls(taskId), 1, "later callback continued after revert");
    }

    function testRejectingCheckRollsBackForwardedFunding() public {
        RejectFundHook rejectingHook = new RejectFundHook(address(market));
        address[] memory hooks = new address[](1);
        hooks[0] = address(rejectingHook);
        uint256 forwarderBalanceBefore = usdc.balanceOf(address(forwarder));
        bytes4 mode = market.BOUNTY();
        bytes memory createCall = _createTaskCalldata(hooks, mode);

        vm.expectRevert(ITMPCore.HookCheckFundRejected.selector);
        forwarder.relay(address(market), REQUESTER, REWARD, createCall);

        assertEq(usdc.balanceOf(address(market)), 0, "escrow transfer rolled back");
        assertEq(usdc.balanceOf(address(forwarder)), forwarderBalanceBefore, "forwarder balance restored");
    }

    function testRefundExpiredSurvivesRevertingAfterHook() public {
        ExpiryHostileHook hostileHook = new ExpiryHostileHook(address(market));
        address[] memory hooks = new address[](1);
        hooks[0] = address(hostileHook);
        bytes32 taskId = _createTask(hooks, market.BOUNTY());

        vm.warp(block.timestamp + 1 days + 1);
        market.refundExpired(taskId, 0);

        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Expired), "task expired");
        assertEq(usdc.balanceOf(REQUESTER), REWARD, "requester refund remains reachable");
    }

    function _createTask(address[] memory hooks, bytes4 mode) private returns (bytes32 taskId) {
        taskId = abi.decode(
            forwarder.relay(address(market), REQUESTER, REWARD, _createTaskCalldata(hooks, mode)), (bytes32)
        );
    }

    function _createTaskCalldata(address[] memory hooks, bytes4 mode) private view returns (bytes memory) {
        ITMPCore.TaskConfig memory config;
        config.reward = REWARD;
        config.duration = 1 days;
        config.mode = mode;
        return abi.encodeCall(
            market.createTask,
            (
                config,
                ITMPCore.StakeConfig({required: false, bps: 0}),
                ITMPCore.HookConfig({contracts: hooks, data: HookFixture.hookData()}),
                ITMPCore.TaskContent({contentHash: bytes32(0), contentURI: "", tags: HookFixture.tags()}),
                noEvaluatorConfig()
            )
        );
    }

    function _reachSubmittedState(
        bytes32 taskId,
        ITMPCore.TaskConfig memory config,
        address worker,
        bytes32 deliverable
    ) private {
        if (config.mode == TMP_CLAIM) {
            forwarder.relay(address(market), worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        } else if (config.mode == TMP_PITCH) {
            forwarder.relay(
                address(market), worker, 0, abi.encodeCall(market.submitPitch, (taskId, keccak256("fixture-pitch")))
            );
            forwarder.relay(address(market), REQUESTER, 0, abi.encodeCall(market.selectWorker, (taskId, worker)));
        } else if (config.mode == TMP_AUCTION) {
            forwarder.relay(
                address(market), worker, 0, abi.encodeCall(market.submitBid, (taskId, HookFixture.bidAmount()))
            );
            vm.warp(block.timestamp + config.bidDeadline);
            forwarder.relay(address(market), REQUESTER, 0, abi.encodeCall(market.selectLowestBidder, (taskId)));
        } else {
            require(config.mode == TMP_BOUNTY || config.mode == TMP_BENCHMARK, "unsupported fixture mode");
        }

        forwarder.relay(address(market), worker, 0, abi.encodeCall(market.submitWork, (taskId, deliverable)));
    }

    function _decodeRegisteredHooks(bytes32 taskId, uint256 expected) private returns (address[] memory registered) {
        registered = new address[](expected);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter == address(market) && entry.topics.length == 2 && entry.topics[0] == HOOK_REGISTERED) {
                assertEq(entry.topics[1], taskId, "HookRegistered task ID");
                if (found < expected) registered[found] = abi.decode(entry.data, (address));
                ++found;
            }
        }
        assertEq(found, expected, "expected HookRegistered events");
    }
}
