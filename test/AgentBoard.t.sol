// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBoard} from "../src/AgentBoard.sol";

/// @notice Tiny mock of the Agent ID ERC-721 for the holder gate.
///         Only `balanceOf` matters to AgentBoard.
contract MockAgentId {
    mapping(address => uint256) public balanceOf;

    function mint(address to) external {
        balanceOf[to] += 1;
    }
}

/// @notice Malicious provider that tries to reenter `release` while the
///         escrow payout lands in its receive() hook.
contract ReentrantProvider {
    AgentBoard public board;
    uint256 public jobId;
    bool public attacked;

    constructor(AgentBoard _board) {
        board = _board;
    }

    function register() external {
        board.registerService("Evil Service", "test", 1 ether, "ipfs://evil");
    }

    function deliver(uint256 _jobId) external {
        jobId = _jobId;
        board.markDelivered(_jobId);
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            // Reentrancy attempt: try to release the same job again.
            try board.release(jobId) {} catch {}
        }
    }
}

contract AgentBoardTest is Test {
    MockAgentId internal agentId;
    AgentBoard internal board;

    address internal provider = makeAddr("provider");
    address internal payer = makeAddr("payer");
    address internal stranger = makeAddr("stranger"); // no Agent ID

    uint256 internal constant PRICE = 1 ether;

    function setUp() public {
        agentId = new MockAgentId();
        board = new AgentBoard(address(agentId));

        agentId.mint(provider);
        agentId.mint(payer);
        // stranger intentionally gets no Agent ID.

        vm.deal(provider, 10 ether);
        vm.deal(payer, 10 ether);
        vm.deal(stranger, 10 ether);
    }

    // --------------------------------------------------------------
    // Helpers
    // --------------------------------------------------------------

    function _register() internal returns (uint256 serviceId) {
        vm.prank(provider);
        serviceId = board.registerService("Logo Design", "design", PRICE, "ipfs://logo");
    }

    function _hire() internal returns (uint256 jobId) {
        uint256 serviceId = _register();
        vm.prank(payer);
        jobId = board.hire{value: PRICE}(serviceId);
    }

    function _complete() internal returns (uint256 jobId) {
        jobId = _hire();
        vm.prank(provider);
        board.markDelivered(jobId);
        vm.prank(payer);
        board.release(jobId);
    }

    // --------------------------------------------------------------
    // Gate: non-holders cannot act
    // --------------------------------------------------------------

    function test_NonHolderCannotRegister() public {
        vm.prank(stranger);
        vm.expectRevert("AgentBoard: not an Agent ID holder");
        board.registerService("X", "misc", PRICE, "ipfs://x");
    }

    function test_NonHolderCannotHire() public {
        uint256 serviceId = _register();
        vm.prank(stranger);
        vm.expectRevert("AgentBoard: not an Agent ID holder");
        board.hire{value: PRICE}(serviceId);
    }

    function test_NonHolderCannotRate() public {
        uint256 jobId = _complete();
        vm.prank(stranger);
        vm.expectRevert("AgentBoard: not an Agent ID holder");
        board.rate(jobId, 5, "ipfs://great");
    }

    function test_IsAgentIdHolder() public view {
        assertTrue(board.isAgentIdHolder(provider));
        assertFalse(board.isAgentIdHolder(stranger));
    }

    // --------------------------------------------------------------
    // Happy path: register -> hire -> deliver -> release
    // --------------------------------------------------------------

    function test_HappyPathBalancesMove() public {
        uint256 jobId = _hire();

        // Escrow is locked in the contract after hiring.
        assertEq(address(board).balance, PRICE);
        AgentBoard.Job memory job = board.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgentBoard.JobStatus.Open));
        assertEq(job.amount, PRICE);
        assertEq(job.payer, payer);
        assertEq(job.provider, provider);

        vm.prank(provider);
        board.markDelivered(jobId);
        job = board.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgentBoard.JobStatus.Delivered));

        uint256 providerBefore = provider.balance;
        vm.prank(payer);
        board.release(jobId);

        assertEq(provider.balance, providerBefore + PRICE);
        assertEq(address(board).balance, 0);
        job = board.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgentBoard.JobStatus.Completed));
    }

    function test_ServiceReadableAndEditableByOwnerOnly() public {
        uint256 serviceId = _register();
        AgentBoard.Service memory svc = board.getService(serviceId);
        assertEq(svc.owner, provider);
        assertEq(svc.priceWei, PRICE);
        assertTrue(svc.active);
        assertEq(board.listServiceIds().length, 1);

        vm.prank(payer);
        vm.expectRevert("AgentBoard: not service owner");
        board.updateService(serviceId, "Hijack", "design", PRICE, "ipfs://x", true);

        vm.prank(provider);
        board.updateService(serviceId, "Logo Design v2", "design", 2 ether, "ipfs://logo2", true);
        svc = board.getService(serviceId);
        assertEq(svc.name, "Logo Design v2");
        assertEq(svc.priceWei, 2 ether);
    }

    function test_CannotHireOwnService() public {
        uint256 serviceId = _register();
        vm.prank(provider);
        vm.expectRevert("AgentBoard: cannot hire own service");
        board.hire{value: PRICE}(serviceId);
    }

    function test_HireRequiresExactPrice() public {
        uint256 serviceId = _register();
        vm.prank(payer);
        vm.expectRevert("AgentBoard: must escrow exact price");
        board.hire{value: PRICE - 1}(serviceId);
    }

    // --------------------------------------------------------------
    // Cancel before delivery refunds in full
    // --------------------------------------------------------------

    function test_CancelBeforeDeliveryRefunds() public {
        uint256 jobId = _hire();
        uint256 payerBefore = payer.balance;

        vm.prank(payer);
        board.cancel(jobId);

        assertEq(payer.balance, payerBefore + PRICE);
        assertEq(address(board).balance, 0);
        AgentBoard.Job memory job = board.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgentBoard.JobStatus.Cancelled));
    }

    function test_CannotCancelAfterDelivery() public {
        uint256 jobId = _hire();
        vm.prank(provider);
        board.markDelivered(jobId);

        vm.prank(payer);
        vm.expectRevert("AgentBoard: job already delivered");
        board.cancel(jobId);
    }

    // --------------------------------------------------------------
    // Timeout paths
    // --------------------------------------------------------------

    function test_ClaimTimeoutAfterDelivery() public {
        uint256 jobId = _hire();
        vm.prank(provider);
        board.markDelivered(jobId);

        // Too early: payer still has the release window.
        vm.prank(provider);
        vm.expectRevert("AgentBoard: release window not over");
        board.claimTimeout(jobId);

        vm.warp(block.timestamp + 7 days);
        uint256 providerBefore = provider.balance;
        vm.prank(provider);
        board.claimTimeout(jobId);

        assertEq(provider.balance, providerBefore + PRICE);
        AgentBoard.Job memory job = board.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgentBoard.JobStatus.Completed));
    }

    function test_RefundTimeoutWhenNeverDelivered() public {
        uint256 jobId = _hire();

        vm.prank(payer);
        vm.expectRevert("AgentBoard: delivery window not over");
        board.refundTimeout(jobId);

        vm.warp(block.timestamp + 7 days);
        uint256 payerBefore = payer.balance;
        vm.prank(payer);
        board.refundTimeout(jobId);

        assertEq(payer.balance, payerBefore + PRICE);
        AgentBoard.Job memory job = board.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgentBoard.JobStatus.Cancelled));
    }

    // --------------------------------------------------------------
    // Ratings
    // --------------------------------------------------------------

    function test_RateOnlyAfterCompletionAndOnlyOnce() public {
        uint256 jobId = _hire();

        // Not completed yet.
        vm.prank(payer);
        vm.expectRevert("AgentBoard: job not completed");
        board.rate(jobId, 5, "ipfs://early");

        vm.prank(provider);
        board.markDelivered(jobId);
        vm.prank(payer);
        board.release(jobId);

        vm.prank(payer);
        board.rate(jobId, 4, "ipfs://good");

        (uint256 count, uint256 total) = board.providerReputation(provider);
        assertEq(count, 1);
        assertEq(total, 4);

        // Second rating on the same job must revert.
        vm.prank(payer);
        vm.expectRevert("AgentBoard: job already rated");
        board.rate(jobId, 5, "ipfs://again");
    }

    function test_RateScoreBounds() public {
        uint256 jobId = _complete();
        vm.prank(payer);
        vm.expectRevert("AgentBoard: score must be 1-5");
        board.rate(jobId, 0, "ipfs://zero");
        vm.prank(payer);
        vm.expectRevert("AgentBoard: score must be 1-5");
        board.rate(jobId, 6, "ipfs://six");
    }

    function test_OnlyPayerCanRate() public {
        uint256 jobId = _complete();
        vm.prank(provider);
        vm.expectRevert("AgentBoard: not job payer");
        board.rate(jobId, 5, "ipfs://self");
    }

    // --------------------------------------------------------------
    // Owner pause: blocks new hires, never traps escrow
    // --------------------------------------------------------------

    function test_OwnerPauseBlocksHiresButNotRelease() public {
        uint256 jobId = _hire();

        board.setHiresPaused(true); // test contract is the owner/deployer
        uint256 serviceId = _register();
        vm.prank(payer);
        vm.expectRevert("AgentBoard: hires paused");
        board.hire{value: PRICE}(serviceId);

        // Existing job still settles while paused.
        vm.prank(provider);
        board.markDelivered(jobId);
        vm.prank(payer);
        board.release(jobId);
        assertEq(address(board).balance, 0);
    }

    function test_NonOwnerCannotPause() public {
        vm.prank(payer);
        vm.expectRevert("AgentBoard: not owner");
        board.setHiresPaused(true);
    }

    // --------------------------------------------------------------
    // Reentrancy: provider receive() hook cannot double-release
    // --------------------------------------------------------------

    function test_ReentrantProviderCannotDoubleRelease() public {
        ReentrantProvider attacker = new ReentrantProvider(board);
        agentId.mint(address(attacker));
        vm.deal(address(attacker), 1 ether);

        attacker.register(); // service id 1 in this fresh board state
        uint256 serviceId = board.serviceCount();

        vm.prank(payer);
        uint256 jobId = board.hire{value: PRICE}(serviceId);

        attacker.deliver(jobId);

        vm.prank(payer);
        board.release(jobId);

        assertTrue(attacker.attacked(), "attacker should have attempted reentry");
        // Paid exactly once: escrow was 1 ether, attacker started with 1.
        assertEq(address(attacker).balance, 2 ether);
        assertEq(address(board).balance, 0);
    }
}
