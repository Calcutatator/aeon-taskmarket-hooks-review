// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ITMPHook} from "@taskmarket/contracts/src/interfaces/ITMPHook.sol";
import {Hook} from "../src/Hook.sol";

/// @notice Deterministic CREATE2 deployment through Foundry's canonical factory.
/// @dev Run without --broadcast for the mandatory rehearsal. The salt is stable for
///      identical source + Diamond, making a repeated request address-idempotent.
contract DeployHook is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes4 internal constant EXPECTED_ITMP_HOOK_INTERFACE_ID = 0x2187b4de;

    function run() external returns (Hook hook) {
        address diamond = vm.envAddress("TASKMARKET_DIAMOND");
        bytes memory initCode = abi.encodePacked(type(Hook).creationCode, abi.encode(diamond));
        bytes32 defaultSalt =
            keccak256(abi.encode("aeon.deploy-taskmarket-hook.v1", diamond, keccak256(type(Hook).creationCode)));
        bytes32 salt = vm.envOr("TASKMARKET_HOOK_SALT", defaultSalt);
        address expected = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_DEPLOYER);
        Hook runtimeProbe = new Hook(diamond);
        bytes32 expectedRuntimeCodehash = address(runtimeProbe).codehash;

        if (expected.code.length != 0) {
            hook = Hook(expected);
            require(expected.codehash == expectedRuntimeCodehash, "CREATE2 address collision");
            require(hook.diamond() == diamond, "existing hook bound to wrong diamond");
            require(hook.supportsInterface(EXPECTED_ITMP_HOOK_INTERFACE_ID), "existing hook has wrong interface");
            console2.log("ALREADY_DEPLOYED", expected);
            console2.logBytes32(expected.codehash);
            return hook;
        }

        // Call the canonical deterministic deployment proxy explicitly. This avoids
        // relying on Forge's CREATE2 rewriting semantics and makes the address math
        // above identical in simulation and broadcast.
        vm.startBroadcast();
        (bool deployed,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        vm.stopBroadcast();
        require(deployed, "CREATE2 factory call failed");
        require(expected.code.length != 0, "CREATE2 deployment missing code");
        require(expected.codehash == expectedRuntimeCodehash, "deployed runtime mismatch");
        hook = Hook(expected);

        require(address(hook) == expected, "CREATE2 address mismatch");
        require(hook.diamond() == diamond, "hook bound to wrong diamond");
        require(hook.supportsInterface(type(ITMPHook).interfaceId), "ITMPHook ERC165 mismatch");
        require(type(ITMPHook).interfaceId == EXPECTED_ITMP_HOOK_INTERFACE_ID, "unexpected ITMPHook interface");

        console2.log("hook", address(hook));
        console2.log("diamond", diamond);
        console2.logBytes32(salt);
        console2.logBytes32(address(hook).codehash);
    }
}
