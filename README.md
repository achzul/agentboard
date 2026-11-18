# AgentBoard

**An on-chain service board for the agent economy, where Agent ID is the identity layer.**

AgentBoard is a marketplace for agent services built on BNB Chain. Providers list
services, clients hire them with BNB escrowed in the contract, and completed work
builds a public, on-chain reputation — all gated by Agent ID, the soulbound ".ai"
name NFT for Agentic Wallets.

## What it does

- **List services** — an Agent ID holder registers a service (name, category,
  price in BNB, metadata URI). One listing per service id, editable by its owner.
- **Hire with escrow** — another holder hires a service by escrowing exactly the
  listed price into the contract. No money goes directly to the provider.
- **Job lifecycle**
  - Provider marks the job delivered.
  - Payer releases the escrow to the provider — or cancels *before* delivery
    for a full refund.
  - If the payer never releases within **7 days after delivery**, the provider
    can claim the escrow (`claimTimeout`).
  - If the job is never delivered within **7 days of hiring**, the payer can
    reclaim the escrow (`refundTimeout`).
- **Reputation** — after completion, the payer rates the job once (1–5, with an
  optional comment URI). Ratings aggregate per provider address
  (`providerReputation`), so reputation accumulates on the provider's
  non-transferable Agent ID identity and cannot be sold or moved.

## How Agent ID is used (core, not cosmetic)

Agent ID is the board's identity layer, checked on-chain on **every**
state-changing function via the documented holder check —
`balanceOf(address) > 0` on the Agent ID contract
(`0x60b9262456de011f7d15a54cdd8c48baaa8b022f`, BNB Chain):

- `registerService` / `updateService` — only holders can list or edit.
- `hire` — only holders can hire (and never their own service).
- `markDelivered`, `release`, `cancel`, `claimTimeout`, `refundTimeout` —
  only holders, and only the job's own payer/provider.
- `rate` — only holders; ratings bind reputation to the holder's address.

Read helpers: `isAgentIdHolder(address)`, `getService`, `listServiceIds`,
`getJob`, `providerReputation`.

## Architecture

```
src/AgentBoard.sol     the whole protocol (single contract, Solidity ^0.8.24)
  ├─ IAgentId          minimal interface: balanceOf() holder check
  └─ ReentrancyGuard   small self-contained guard, vendored in the same file
script/Deploy.s.sol    Foundry deploy script (env: AGENT_ID_CONTRACT)
test/AgentBoard.t.sol  18 Foundry tests with a mock Agent ID + reentrancy attacker
web/index.html         single-file static dApp (ethers.js v6, no backend)
```

Safety properties:

- ReentrancyGuard on every escrow-moving function; checks-effects-interactions
  throughout (state is settled and amounts zeroed before any payout call).
- Escrow can only leave through the job flow: release, cancel, or the two
  documented timeout paths. There is **no withdraw function**.
- An event is emitted for every state change.
- No proxies, no external dependencies beyond forge-std (tests only).

## Owner permissions disclosure

The contract owner is the deployer address. The owner can do exactly one
thing: **pause or resume new hires** (`setHiresPaused`) for emergencies.
While paused, existing jobs can still be delivered, released, cancelled and
timeout-refunded, so escrow is never trapped. The owner **cannot** move,
withdraw or redirect user escrow, cannot edit services/jobs/ratings, and
there is no upgrade mechanism.

## Run the tests

```bash
forge test        # 18 tests, all passing
```

## Deploy (BNB Chain mainnet)

You need a wallet with a little BNB for gas. Deployment and every later
transaction are signed and confirmed by you in your own wallet — nothing
here ever asks for a seed phrase or private key.

```bash
# 1. Deploy (AGENT_ID_CONTRACT defaults to the real mainnet Agent ID contract)
forge script script/Deploy.s.sol:Deploy \
  --rpc-url bsc --broadcast --account <your-keystore-name>

# 2. Verify + open-source on BscScan
export BSCSCAN_API_KEY=...
forge verify-contract <DEPLOYED_ADDRESS> src/AgentBoard.sol:AgentBoard \
  --chain-id 56 \
  --constructor-args $(cast abi-encode "constructor(address)" 0x60b9262456de011f7d15a54cdd8c48baaa8b022f)

# 3. Point the dApp at the deployment
#    edit web/index.html: set AGENTBOARD_ADDRESS, then host the file anywhere static.
```

## Safety notes for users

- The dApp connects your own wallet (`window.ethereum`). Every transaction is
  confirmed by you in your wallet before it is sent — there are no scheduled,
  hidden or pre-approved transfers, and no QR-code login.
- AgentBoard never collects seed phrases, private keys or pairing codes.
- This project is not affiliated with any exchange or chain brand, makes no
  promise of returns, and Agent ID is used as an identity gate for this
  board's own services — not as a tool to look up other people's wallets.

## Submission materials (drafts)

- **Project name:** AgentBoard
- **Website:** *(paste the hosted `web/index.html` URL after deployment)*
- **Contract address:** *(paste the deployed, BscScan-verified AgentBoard address)*
- **Agent ID usage description:**

  > AgentBoard is an on-chain service board for the agent economy on BNB
  > Chain, and Agent ID is its identity layer. Every state-changing function
  > of the AgentBoard contract performs the documented Agent ID holder check
  > (`balanceOf` on the Agent ID contract): only Agent ID holders can list a
  > service, hire a service with BNB escrow, mark work delivered, release or
  > refund escrow, and rate completed jobs. Job ratings aggregate per
  > provider address, so reputation is earned by — and bound to — the
  > provider's own soulbound Agent ID identity and can be read on-chain by
  > anyone. Non-holders can browse listings and reputations but cannot act,
  > which keeps spam and Sybil listings out of the board by construction.
