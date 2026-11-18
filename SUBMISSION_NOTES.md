# Submission notes — what remains for the human

Status: code, tests, deploy script, dApp page and submission drafts are DONE
and verified locally (`forge test`: 18/18 passing). Nothing has been deployed
and no wallet has been touched. The steps below are yours — they involve your
accounts, your wallet and your confirmations.

## Checklist

- [ ] **1. Claim an Agent ID in the Binance app.**
      Open the Agentic Wallet in the Binance app and claim your `.ai` Agent ID
      (one per user, non-transferable). Note the wallet address that holds it —
      check on BscScan that `balanceOf(your address) > 0` on the Agent ID
      contract `0x60b9262456de011f7d15a54cdd8c48baaa8b022f`.
      *(Known blocker from before: the Agentic Wallet menu did not appear in
      your app version — update the app / check rollout first.)*

- [ ] **2. Fund a deployer wallet with a little BNB.**
      Deployment on BNB Chain mainnet costs gas only (small amount). Use a
      wallet you control; you will sign and confirm the deployment yourself.
      Never share the seed phrase or private key with anyone — including any
      agent. Use a Foundry keystore (`cast wallet import`) or your wallet's
      own signing flow.

- [ ] **3. Deploy AgentBoard.**
      Follow README → "Deploy": run the Foundry script against BNB Chain
      mainnet (chain id 56). `AGENT_ID_CONTRACT` already defaults to the real
      Agent ID contract. Save the deployed address.

- [ ] **4. Verify + open-source on BscScan.**
      Run the `forge verify-contract` command from the README and confirm the
      green "verified" source on BscScan. The hackathon requires verified,
      open-source contracts.

- [ ] **5. Host the static page.**
      Edit `web/index.html`: set `AGENTBOARD_ADDRESS` to the deployed address.
      Host the single file anywhere static (GitHub Pages, Netlify, IPFS…).
      No backend, no keys involved.

- [ ] **6. Smoke-test with your Agent ID wallet.**
      Connect, confirm the page shows "Agent ID holder ✓", list one service,
      and (ideally with a second holder address) run one full job:
      hire → deliver → release → rate.

- [ ] **7. Submit during the window: 18 Nov – 9 Dec 2026 (08:00 UTC).**
      Submit: project name "AgentBoard", the hosted website URL, the deployed
      contract address, and the Agent ID usage description — drafts for all
      four are in README → "Submission materials".

## Eligibility note — Innovation Award threshold

The Agent Application Innovation Award requires **at least 30 distinct
Agent ID addresses interacting with the project during the submission
period**. Plan for this early: after deploying, the board needs 30 different
Agent ID holders to actually use it (list / hire / rate) before 9 Dec 2026.
The 2,000 USDC Community Promotion pool (20 winners) rewards quality X posts
about the hackathon — a post about AgentBoard is a low-cost extra shot.

## Honest odds

60,000 USDC total across all projects and both award tracks; this is a build
competition judged on real Agent ID usage, not a lottery. The code side is
ready — the deciding factors are steps 1–7 above and reaching real users.
