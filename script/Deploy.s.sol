// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AgentBoard} from "../src/AgentBoard.sol";

/// @notice Deploys AgentBoard to BNB Chain mainnet (chain id 56).
///
/// Usage (the deployer wallet signs and confirms in their own wallet /
/// keystore — this script never handles raw private keys itself):
///
///   export BSCSCAN_API_KEY=...            # for verification afterwards
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url bsc --broadcast --account <keystore-name>
///
/// The Agent ID contract address is read from the AGENT_ID_CONTRACT env
/// var and defaults to the real mainnet Agent ID contract:
///   0x60b9262456de011f7d15a54cdd8c48baaa8b022f
contract Deploy is Script {
    address internal constant DEFAULT_AGENT_ID = 0x60b9262456de011f7d15a54cdd8c48baaa8b022f;

    function run() external returns (AgentBoard board) {
        address agentId = vm.envOr("AGENT_ID_CONTRACT", DEFAULT_AGENT_ID);
        require(agentId != address(0), "Deploy: zero agent id");

        vm.startBroadcast();
        board = new AgentBoard(agentId);
        vm.stopBroadcast();

        console.log("AgentBoard deployed at:", address(board));
        console.log("Agent ID contract:     ", agentId);
        console.log("Owner (deployer):      ", board.owner());
    }
}
