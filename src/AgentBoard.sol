// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal read interface for the Agent ID contract (SPACE ID ".ai"
///         name NFT for Agentic Wallets on BNB Chain). The officially
///         documented holder check is `balanceOf(address) > 0`.
interface IAgentId {
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice Minimal self-contained reentrancy guard (OpenZeppelin-style),
///         vendored here so the project has zero external dependencies.
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "AgentBoard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/// @title AgentBoard
/// @notice An on-chain service board for the agent economy. Agent ID (the
///         soulbound ".ai" name NFT for Agentic Wallets) is the identity
///         layer: only Agent ID holders can list services, hire, deliver,
///         release, cancel or rate. Payments are escrowed in BNB inside
///         this contract and released only through the job flow below.
///         Reputation (ratings) is aggregated per provider address, so it
///         is bound to a non-transferable identity.
///
/// @dev Owner permissions (deliberately minimal, see README):
///      - The deployer is `owner`. The owner can ONLY pause/unpause new
///        hires in an emergency (`setHiresPaused`). The owner has NO
///        function that can move, withdraw or redirect user escrow, and
///        cannot edit services, jobs or ratings.
contract AgentBoard is ReentrancyGuard {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum JobStatus {
        Open, // hired, escrow locked, not yet delivered
        Delivered, // provider marked delivered, awaiting payer release
        Completed, // provider paid
        Cancelled // escrow refunded to payer
    }

    struct Service {
        uint256 id;
        address owner; // provider (Agent ID holder)
        string name;
        string category;
        uint256 priceWei;
        string metadataURI;
        bool active;
    }

    struct Job {
        uint256 id;
        uint256 serviceId;
        address payer;
        address provider;
        uint256 amount; // escrowed BNB (wei)
        JobStatus status;
        uint256 hiredAt;
        uint256 deliveredAt; // 0 until delivered
        bool rated;
    }

    // ------------------------------------------------------------------
    // Constants & state
    // ------------------------------------------------------------------

    /// @notice If a job is not delivered within this window after hiring,
    ///         the payer can reclaim the escrow (`refundTimeout`).
    uint256 public constant DELIVERY_WINDOW = 7 days;

    /// @notice If the payer does not release within this window after
    ///         delivery, the provider can claim the escrow
    ///         (`claimTimeout`).
    uint256 public constant RELEASE_WINDOW = 7 days;

    /// @notice The Agent ID contract used for the holder gate.
    IAgentId public immutable agentId;

    /// @notice Deployer. Can only pause/unpause new hires (see header).
    address public immutable owner;

    /// @notice Emergency switch: when true, `hire` reverts. Existing jobs
    ///         can still be delivered, released, cancelled and refunded,
    ///         so escrow is never trapped by a pause.
    bool public hiresPaused;

    uint256 public serviceCount;
    uint256 public jobCount;

    mapping(uint256 => Service) private _services;
    mapping(uint256 => Job) private _jobs;

    // Reputation, aggregated per provider address.
    mapping(address => uint256) private _ratingCount;
    mapping(address => uint256) private _ratingTotal;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event ServiceRegistered(
        uint256 indexed serviceId, address indexed provider, string name, string category, uint256 priceWei, string metadataURI
    );
    event ServiceUpdated(
        uint256 indexed serviceId, address indexed provider, string name, string category, uint256 priceWei, string metadataURI, bool active
    );
    event JobCreated(uint256 indexed jobId, uint256 indexed serviceId, address indexed payer, address provider, uint256 amount);
    event JobDelivered(uint256 indexed jobId, address indexed provider);
    event JobReleased(uint256 indexed jobId, address indexed provider, uint256 amount);
    event JobCancelled(uint256 indexed jobId, address indexed payer, uint256 amount);
    event JobTimeoutClaimed(uint256 indexed jobId, address indexed provider, uint256 amount);
    event JobTimeoutRefunded(uint256 indexed jobId, address indexed payer, uint256 amount);
    event JobRated(uint256 indexed jobId, address indexed provider, address indexed payer, uint8 score, string commentURI);
    event HiresPausedSet(bool paused);

    // ------------------------------------------------------------------
    // Construction & gate
    // ------------------------------------------------------------------

    constructor(address agentIdContract) {
        require(agentIdContract != address(0), "AgentBoard: zero agent id contract");
        agentId = IAgentId(agentIdContract);
        owner = msg.sender;
    }

    /// @notice True if `account` holds an Agent ID (balanceOf > 0).
    function isAgentIdHolder(address account) public view returns (bool) {
        return agentId.balanceOf(account) > 0;
    }

    /// @dev Every state-changing user function is behind this gate:
    ///      only Agent ID holders may act on the board.
    modifier onlyAgentIdHolder() {
        require(isAgentIdHolder(msg.sender), "AgentBoard: not an Agent ID holder");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "AgentBoard: not owner");
        _;
    }

    // ------------------------------------------------------------------
    // Owner (emergency pause only — cannot touch escrow)
    // ------------------------------------------------------------------

    /// @notice Pause or resume NEW hires. Does not affect delivery,
    ///         release, cancel or timeout refunds of existing jobs.
    function setHiresPaused(bool paused) external onlyOwner {
        hiresPaused = paused;
        emit HiresPausedSet(paused);
    }

    // ------------------------------------------------------------------
    // Services
    // ------------------------------------------------------------------

    /// @notice List a service under your Agent ID. One listing per
    ///         service id; the listing is editable by its owner via
    ///         `updateService`.
    function registerService(string calldata name, string calldata category, uint256 priceWei, string calldata metadataURI)
        external
        onlyAgentIdHolder
        returns (uint256 serviceId)
    {
        require(bytes(name).length > 0, "AgentBoard: empty name");
        require(priceWei > 0, "AgentBoard: price must be > 0");

        serviceId = ++serviceCount;
        _services[serviceId] = Service({
            id: serviceId,
            owner: msg.sender,
            name: name,
            category: category,
            priceWei: priceWei,
            metadataURI: metadataURI,
            active: true
        });

        emit ServiceRegistered(serviceId, msg.sender, name, category, priceWei, metadataURI);
    }

    /// @notice Edit your own listing (name, category, price, metadata,
    ///         active flag). Price changes apply only to future hires;
    ///         existing jobs keep the amount escrowed at hire time.
    function updateService(
        uint256 serviceId,
        string calldata name,
        string calldata category,
        uint256 priceWei,
        string calldata metadataURI,
        bool active
    ) external onlyAgentIdHolder {
        Service storage svc = _services[serviceId];
        require(svc.id != 0, "AgentBoard: unknown service");
        require(svc.owner == msg.sender, "AgentBoard: not service owner");
        require(bytes(name).length > 0, "AgentBoard: empty name");
        require(priceWei > 0, "AgentBoard: price must be > 0");

        svc.name = name;
        svc.category = category;
        svc.priceWei = priceWei;
        svc.metadataURI = metadataURI;
        svc.active = active;

        emit ServiceUpdated(serviceId, msg.sender, name, category, priceWei, metadataURI, active);
    }

    // ------------------------------------------------------------------
    // Jobs / escrow
    // ------------------------------------------------------------------

    /// @notice Hire a service, escrowing exactly the listed price in BNB.
    ///         The escrow stays locked in this contract until release,
    ///         cancel or a timeout path resolves the job.
    function hire(uint256 serviceId) external payable onlyAgentIdHolder nonReentrant returns (uint256 jobId) {
        require(!hiresPaused, "AgentBoard: hires paused");
        Service storage svc = _services[serviceId];
        require(svc.id != 0, "AgentBoard: unknown service");
        require(svc.active, "AgentBoard: service inactive");
        require(msg.sender != svc.owner, "AgentBoard: cannot hire own service");
        require(msg.value == svc.priceWei, "AgentBoard: must escrow exact price");

        jobId = ++jobCount;
        _jobs[jobId] = Job({
            id: jobId,
            serviceId: serviceId,
            payer: msg.sender,
            provider: svc.owner,
            amount: msg.value,
            status: JobStatus.Open,
            hiredAt: block.timestamp,
            deliveredAt: 0,
            rated: false
        });

        emit JobCreated(jobId, serviceId, msg.sender, svc.owner, msg.value);
    }

    /// @notice Provider marks a job as delivered. Starts the payer's
    ///         7-day release window.
    function markDelivered(uint256 jobId) external onlyAgentIdHolder {
        Job storage job = _jobs[jobId];
        require(job.id != 0, "AgentBoard: unknown job");
        require(job.provider == msg.sender, "AgentBoard: not job provider");
        require(job.status == JobStatus.Open, "AgentBoard: job not open");

        job.status = JobStatus.Delivered;
        job.deliveredAt = block.timestamp;

        emit JobDelivered(jobId, msg.sender);
    }

    /// @notice Payer releases the escrow to the provider after delivery.
    function release(uint256 jobId) external onlyAgentIdHolder nonReentrant {
        Job storage job = _jobs[jobId];
        require(job.id != 0, "AgentBoard: unknown job");
        require(job.payer == msg.sender, "AgentBoard: not job payer");
        require(job.status == JobStatus.Delivered, "AgentBoard: job not delivered");

        uint256 amount = job.amount;
        address provider = job.provider;
        // checks-effects-interactions: settle state before paying out.
        job.status = JobStatus.Completed;
        job.amount = 0;

        (bool ok,) = provider.call{value: amount}("");
        require(ok, "AgentBoard: payout failed");

        emit JobReleased(jobId, provider, amount);
    }

    /// @notice Payer cancels a job BEFORE delivery and is refunded in
    ///         full.
    function cancel(uint256 jobId) external onlyAgentIdHolder nonReentrant {
        Job storage job = _jobs[jobId];
        require(job.id != 0, "AgentBoard: unknown job");
        require(job.payer == msg.sender, "AgentBoard: not job payer");
        require(job.status == JobStatus.Open, "AgentBoard: job already delivered");

        uint256 amount = job.amount;
        job.status = JobStatus.Cancelled;
        job.amount = 0;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "AgentBoard: refund failed");

        emit JobCancelled(jobId, msg.sender, amount);
    }

    /// @notice Provider claims the escrow if the payer never released
    ///         within 7 days after delivery.
    function claimTimeout(uint256 jobId) external onlyAgentIdHolder nonReentrant {
        Job storage job = _jobs[jobId];
        require(job.id != 0, "AgentBoard: unknown job");
        require(job.provider == msg.sender, "AgentBoard: not job provider");
        require(job.status == JobStatus.Delivered, "AgentBoard: job not delivered");
        require(block.timestamp >= job.deliveredAt + RELEASE_WINDOW, "AgentBoard: release window not over");

        uint256 amount = job.amount;
        job.status = JobStatus.Completed;
        job.amount = 0;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "AgentBoard: payout failed");

        emit JobTimeoutClaimed(jobId, msg.sender, amount);
    }

    /// @notice Payer reclaims the escrow if the job was never delivered
    ///         within 7 days of hiring.
    function refundTimeout(uint256 jobId) external onlyAgentIdHolder nonReentrant {
        Job storage job = _jobs[jobId];
        require(job.id != 0, "AgentBoard: unknown job");
        require(job.payer == msg.sender, "AgentBoard: not job payer");
        require(job.status == JobStatus.Open, "AgentBoard: job not open");
        require(block.timestamp >= job.hiredAt + DELIVERY_WINDOW, "AgentBoard: delivery window not over");

        uint256 amount = job.amount;
        job.status = JobStatus.Cancelled;
        job.amount = 0;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "AgentBoard: refund failed");

        emit JobTimeoutRefunded(jobId, msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Ratings / reputation
    // ------------------------------------------------------------------

    /// @notice Rate a completed job (score 1-5). Only the job's payer,
    ///         only after completion, only once. Ratings aggregate per
    ///         provider address, i.e. per soulbound Agent ID identity.
    function rate(uint256 jobId, uint8 score, string calldata commentURI) external onlyAgentIdHolder {
        require(score >= 1 && score <= 5, "AgentBoard: score must be 1-5");
        Job storage job = _jobs[jobId];
        require(job.id != 0, "AgentBoard: unknown job");
        require(job.payer == msg.sender, "AgentBoard: not job payer");
        require(job.status == JobStatus.Completed, "AgentBoard: job not completed");
        require(!job.rated, "AgentBoard: job already rated");

        job.rated = true;
        _ratingCount[job.provider] += 1;
        _ratingTotal[job.provider] += score;

        emit JobRated(jobId, job.provider, msg.sender, score, commentURI);
    }

    /// @notice Aggregated reputation of a provider: number of ratings
    ///         and the sum of scores (average = total / count).
    function providerReputation(address provider) external view returns (uint256 count, uint256 totalScore) {
        return (_ratingCount[provider], _ratingTotal[provider]);
    }

    // ------------------------------------------------------------------
    // Reads
    // ------------------------------------------------------------------

    function getService(uint256 serviceId) external view returns (Service memory) {
        require(_services[serviceId].id != 0, "AgentBoard: unknown service");
        return _services[serviceId];
    }

    function getJob(uint256 jobId) external view returns (Job memory) {
        require(_jobs[jobId].id != 0, "AgentBoard: unknown job");
        return _jobs[jobId];
    }

    /// @notice All service ids ever registered (1..serviceCount).
    function listServiceIds() external view returns (uint256[] memory ids) {
        ids = new uint256[](serviceCount);
        for (uint256 i = 0; i < serviceCount; i++) {
            ids[i] = i + 1;
        }
    }
}
