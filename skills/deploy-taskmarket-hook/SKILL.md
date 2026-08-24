---
name: deploy-taskmarket-hook
description: Turn one brief into a direct immutable TaskMarket V1 hook, then static-audit, behavior-test, exercise a local lifecycle, fork-simulate, and optionally deploy it deterministically. Dry-run by default.
metadata:
  title: Deploy TaskMarket Hook
  category: crypto
  var: "arm: to broadcast (default dry-run), template:tag|allowlist|receipt|freeform, chain:base-sepolia|base, then one hook brief. Empty prints help."
  tags:
    - crypto
    - dev
    - onchain
  requires:
    - HOOK_DEPLOYER_PRIVATE_KEY?
    - ALCHEMY_API_KEY?
    - ETHERSCAN_API_KEY?
  capabilities:
    - external_api
    - onchain_writes
    - writes_external_host
    - sends_notifications
---

> **${var}** — one hook brief. Grammar: `[arm:] [template:<tag|allowlist|receipt|freeform>] [chain:<base-sepolia|base>] <brief>`
>
> - Empty → print this grammar and exit `DEPLOY_TASKMARKET_HOOK_EMPTY`.
> - `<brief>` → generate, audit, test, run the local lifecycle, and fork-simulate. **Never broadcast. This is the default.**
> - `arm:<brief>` → run every dry-run gate first, then broadcast only the hook deployment.
> - Chain defaults to `base-sepolia`. `base` is mainnet and must be explicit.
> - Omit `template:` to auto-pick a reference shape; unmatched behavior uses `freeform`.

Today is ${today}. Turn one concrete brief into a TaskMarket hook that implements the deployed V1 interface, prove the stated behavior at four gates, and only then deploy the contract. A “live hook” here means confirmed runtime bytecode at an address; explorer source verification is reported separately and is best-effort. This skill does **not** attach it to a task, change protocol defaults, create/fund a task, submit registry metadata, or spend USDC.

## Canonical target and source pins

Resolve targets only through the staged runner; never accept a model-invented Diamond address.

| chain | chain ID | canonical TaskMarket Diamond | expected proxy runtime codehash | current default hook |
|---|---:|---|---|---|
| `base-sepolia` | 84532 | `0x0A24E9c3b9E31B8258329e187470ACc16497Cec7` | `0x04304a177e7ca8d5bf728ec3a4ae834f3af28925140c6613ee6cfb4574d1b75d` | `0x0F40337879feE4074E4f4B77e0de8623b85Ca8f7` |
| `base` | 8453 | `0xDDc6cC3e4D11c1f3527B867C7DAD4ED9869C33f7` | `0x04304a177e7ca8d5bf728ec3a4ae834f3af28925140c6613ee6cfb4574d1b75d` | `0x8e28bb2c54443F54030Ff9F2bc1F1794c017F0ca` |

The workflow stages a Foundry project at `$TASKMARKET_HOOKBUILD_DIR` and a secret-expansion-safe cooperative runner at `./taskmarket-hook-deploy.sh`. Its contract source is pinned to `daydreamsai/taskmarket-contracts@657b9f74478bdf71c3c1b5e0d2dde7197aba56cb`, with exact dependency pins:

- OpenZeppelin Contracts `fcbae5394ae8ad52d8e580a3477db99814b9d565`
- OpenZeppelin Contracts Upgradeable `7bf4727aacdbfaa0f36cbd664654d0c9e1dc52bf`
- forge-std `1801b0541f4fda118a10798fd3486bb7051c5dd6`

That public TaskMarket pin does not contain the proposed `BaseTMPHook` or a complete `.gitmodules`. The staged project installs all four pins directly and vendors the reviewed PR #597 `BaseTMPHook` alongside the generated source. Generated hooks inherit that staged local file; never import a `BaseTMPHook` from an unpinned branch or package path.

## V1 behavior that every build must respect

- `ITMPHook` has interface ID `0x2187b4de`.
- Blocking checks: `checkFund`, `checkClaim`, `checkSelectWorker`, `checkSubmit`, `checkEvaluate`, `checkComplete`. `false` or revert vetoes the transition.
- Best-effort callbacks: `onComplete`, `onForfeit`, `onCancel`, `onExpire`. Failures are swallowed and have no replay guarantee.
- Every external callback must accept only the immutable canonical Diamond as `msg.sender`.
- Checks see committed state before TaskMarket's outbound payout; rejection reverts the transition. `checkFund` is called after the PGTR forwarder may already have moved USDC.
- Hook calls have a 1,000,000-gas stipend and only 32 bytes of return data are copied.
- Hooks are invoked in order, with live protocol defaults first, and the complete task list is capped at eight. Query `getDefaultHooks()` on the target fork; do not assume the one address in the table remains the only default.
- `hookData` is one shared blob and only enters `checkFund`. Domain-separate it and persist any later-needed configuration in the hook.
- There is no typed mutation response: a hook can veto or observe, not rewrite TaskMarket reward, fees, recipients, deliverables, verdicts, or core state.

No direct callback exists for `assignEvaluator`, `updateTask`, `submitPitch`, `submitProof`, `submitBid`, `rejectSubmission`, `appeal`, `evaluatorTimeout`, or `rateTask`. `checkEvaluate` does not receive a proposed verdict. `refundExpired` cannot be gated. A claimed Auction task with a deliverable may expire through auto-pay and `onComplete` without `checkComplete`. If the brief depends on any contrary assumption, stop with `DEPLOY_TASKMARKET_HOOK_BAD_BRIEF` rather than approximating it.

## Safety contract

1. **Dry-run is the default.** Only a leading `arm:` authorizes a deployment transaction. The runner independently checks the raw workflow input in `HOOK_REQUEST_VAR`; the model's choice of runner mode is not sufficient authorization.
2. **Mainnet has a triple lock.** Broadcasting to Base requires all three: leading `arm:`, explicit `chain:base`, and repo variable `HOOK_MAINNET_OK=1`. Missing any one exits `DEPLOY_TASKMARKET_HOOK_MAINNET_NOT_AUTHORIZED`.
3. **One side effect only.** The armed path may deploy and verify hook bytecode. It must not attach the address to a task, call `setDefaultHooks`, create/fund a task, approve or transfer ERC-20s, open a registry PR, or submit metadata. Fork tests may simulate those calls with cheatcode-funded test accounts; broadcasts may not.
4. **Gas-only burner and explicit trust boundary.** `HOOK_DEPLOYER_PRIVATE_KEY` must belong to a dedicated deployer holding only gas float. Never print it or expand it in a command; invoke only `./taskmarket-hook-deploy.sh` for deployment. In the matched `deploy-uni-hook` architecture, Aeon's write-mode agent receives this optional burner and is trusted: the runner prevents command-text secret expansion and adds cooperative checks, but is not signer isolation or an enforceable custody boundary. Enforced isolation requires a separate workflow-owned or brokered signer redesign outside this skill.
5. **All gates are mandatory before broadcast.** Static audit, behavioral tests, local lifecycle integration, and target-chain fork simulation must all pass against the exact generated bytecode.
6. **Direct immutable code by default.** Proxy hooks and upgradeable delegates undermine the immutable-per-task address guarantee. Reject them unless the brief explicitly requires mutability and the operator explicitly accepts it; even then, stop at dry-run and mark the manifest high-risk. `arm:` alone does not approve a proxy.
7. **Ambiguous writes are never retried.** If broadcast times out or loses the receipt, query the deterministic address and transaction sender nonce. Record `ambiguous` and stop; never send a second transaction automatically.

## Template picker

| Brief | Template | Reference behavior |
|---|---|---|
| requires a tag, task category, credential tag | `tag` | `RequiredTagPolicyHook` |
| restricts eligible/selected workers | `allowlist` | `AllowlistedWorkerHook` |
| emits an immutable completion receipt | `receipt` | `CompletionReceiptHook` |
| anything else | `freeform` | `BaseTMPHook` scaffold with exact `ITMPHook` callbacks |

The three reference shapes are starting points, not audit certifications. Edit only their marked logic/test regions. Freeform may replace the complete hook body, but must keep the pinned imports, constructor-bound Diamond, ERC-165 response, exact callback signatures, and test harness.

## Steps

### 0. Parse, deduplicate, and initialize an attempt

Parse `arm:`, `template:`, `chain:`, and the remaining brief once. Reject an unknown template/chain or empty brief. Read `STRATEGY.md`, `memory/MEMORY.md`, `memory/state/taskmarket-hook-ideas.json`, `memory/state/taskmarket-hook-deploys.json`, and the last three days of both TaskMarket hook log blocks.

Compute an attempt fingerprint from normalized brief, template, chain ID, canonical Diamond, compiler/settings, pinned dependency commits, constructor arguments, and generated source hash. Append an attempt record to `memory/state/taskmarket-hook-deploys.json` **before any broadcast** with status `started`. Every exit, including compile/test/fork/broadcast failure, must update that record with final stage, exact reason, timestamp, source/runtime hashes, predicted address when available, and `retryOf` when applicable. Failed attempts remain in the ledger.

If the same fingerprint already has a confirmed deployment and the deterministic address still has the recorded runtime codehash, return `ALREADY_DEPLOYED`; do not redeploy. A failed prior attempt may be retried as a new linked attempt.

### 1. Verify the staged toolchain and target identity

Require `forge`, `cast`, `jq`, `$TASKMARKET_HOOKBUILD_DIR`, and `./taskmarket-hook-deploy.sh`. Do not install dependencies in-run. Missing tooling emits the generated brief/source plan and exits `DEPLOY_TASKMARKET_HOOK_NO_TOOLCHAIN`.

Resolve the row with:

```bash
./taskmarket-hook-deploy.sh chains
```

The mandatory `simulate` gate below checks `eth_chainId`, Diamond runtime codehash, the live default hook list, generated-hook `supportsInterface(0x2187b4de)`, and the immutable caller boundary. A matching proxy codehash establishes target identity, not facet correctness; record the fork block and live default observations. Any mismatch exits `DEPLOY_TASKMARKET_HOOK_TARGET_MISMATCH`.

### 2. Generate the contract and specific tests

Write the selected contract in `$TASKMARKET_HOOKBUILD_DIR/src/Hook.sol`, its focused assertions in `$TASKMARKET_HOOKBUILD_DIR/test/HookBehavior.t.sol`, and all positive-path values needed by both immutable harnesses in `$TASKMARKET_HOOKBUILD_DIR/test/HookFixture.sol`. Do not edit `HookLifecycle.t.sol`, `HookDiamondLifecycle.t.sol`, `HookFork.t.sol`, the deploy script, base hook, Foundry config, remappings, or chain registry; the runner hash-pins them and fails closed on drift.

Contract requirements:

- Inherit the staged `BaseTMPHook`, which implements the pinned `ITMPHook`, ERC-165 support for `0x2187b4de`/`IERC165`, the immutable Diamond, and the caller guard.
- Override only the internal `_check*` and `_on*` methods needed by the brief. The base supplies exact external signatures, permissive unused checks, and explicit no-op unused callbacks; never redefine an external callback or invent a selector.
- Validate `hookData` length/version/domain in `checkFund` before decoding. Persist only what later callbacks need and emit a configuration event because core does not store/emit the blob for the hook.
- Keep each path under the 1,000,000-gas stipend with cold-storage headroom. Avoid unbounded iteration over user-controlled arrays.
- Never call back into TaskMarket, transfer or approve core escrow assets, use `delegatecall`, `selfdestruct`, `tx.origin`, arbitrary raw calls, inline assembly, or an unpinned external implementation.
- Do not claim access to a proposed verdict in `checkEvaluate`, do not gate expiry, and do not use `checkComplete` as the sole Auction payout control.

Tests must assert the brief, not merely compilation:

- At least one positive and one negative case per blocking rule.
- Exact ERC-165 support and rejection of direct calls from any non-Diamond address.
- Invalid/misdirected/replayed `hookData`, duplicate hook invocation, and task-ID isolation.
- Observable/idempotent behavior for every used `on*` callback, including that a callback revert cannot be relied on for rollback or replay.
- Gas measured for every used callback, including the coldest state path; fail at or above 1,000,000 and flag anything above 800,000 for review.
- The Auction deliverable-expiry auto-pay path whenever the design concerns completion or payout eligibility.

Compile/fix at most three times. A fourth compile failure exits `DEPLOY_TASKMARKET_HOOK_COMPILE_FAILED`.

### 3. Static review gate

Do not invoke a separate audit command. `./taskmarket-hook-deploy.sh simulate <chain>` owns the automated portion and runs it before tests or deployment rehearsal. It confirms the staged source pin, local `BaseTMPHook` inheritance and immutable Diamond constructor binding, formatting/build/size, brief-specific positive and negative tests, forbidden source patterns across generated files, and forbidden runtime opcodes. Independently inspect all generated logic and external dependencies for owner/admin powers, oracle freshness, reentrancy, storage growth, denial-of-service, task-ID/config isolation, and gas-bound risks before calling the runner. Label this gate `automated review`, never an independent professional audit.

Hard-fail `delegatecall`, `selfdestruct`, a proxy/deployer indirection not explicitly accepted, missing caller guard, wrong selector/interface ID, a permissive placeholder in a selected blocking callback, unbounded user-controlled loop, callback at/over the stipend, or any path that can take/approve TaskMarket escrow. Warnings are not silently waived: keep the run dry and name the concern.

### 4. Behavioral and local lifecycle gates

Do not invoke separate test or lifecycle modes. The `simulate` runner executes the focused positive/negative Forge suite, the callback ABI/gas conformance suite, and the pinned local TaskMarket Diamond + PGTR lifecycle harness with a default followed by generated custom hooks. The local harness proves creation/funding, stored ordering, and successful progression; the brief-specific suite must carry every additional veto, failure, terminal-callback, idempotency, and expiry assertion the generated policy needs.

Use mock/test balances only. The runner parses Forge's executed `[PASS]` cases and requires at least one passing positive and one passing negative case from the exact `HookBehaviorTest` contract; source text, skipped cases, or Forge's zero-test success are not passes. Any failure exits `DEPLOY_TASKMARKET_HOOK_TEST_FAILED`.

### 5. Target fork simulation

Run:

```bash
./taskmarket-hook-deploy.sh simulate <chain>
```

Fork the selected chain at a recorded block, repeat the target identity checks, bind the exact generated hook to the canonical Diamond, verify its interface/caller boundary, then rehearse the exact deterministic CREATE2 deployment in memory. The live fork is a target-compatibility gate; the real lifecycle and ordering assertions run against the commit-pinned local Diamond fixture. It must not broadcast or spend real USDC. Record the live protocol defaults and remaining custom-hook capacity rather than assuming either.

Do not hide a default-hook failure: distinguish `custom-hook failure`, `live-default failure`, `forwarder/precondition failure`, and `RPC failure`. The current default's effective implementation is unverified, so a successful fork proves compatibility at that block, not future liveness or safety. An incomplete or reverted lifecycle exits `DEPLOY_TASKMARKET_HOOK_FORK_FAILED`.

The runner captures predicted address, CREATE2 factory/salt, init/runtime codehashes, fork block/hash, every measured callback gas value, and the complete gate/simulation logs.

### 6. Dry-run stop

After every successful rehearsal, before any arm/key check, the runner persists source, tests, compiler settings, dependency pins, every gate log, gas table, and `simulation-evidence.json` under `output/taskmarket-hooks/<chainId>/<lowercase-predicted-address>/` (or `$TASKMARKET_HOOK_OUTPUT_ROOT` when explicitly set for isolated verification). This preserves the gates even if an armed attempt later stops for authorization, key, or broadcast failure. If the input did not start with `arm:`, stop now with `DEPLOY_TASKMARKET_HOOK_DRY_RUN`; add the draft registry manifest and ledger status to that bundle, report the predicted address and every warning, and never imply the contract is deployed.

### 7. Arm checks

For any armed run:

- Require all four gates from this exact attempt to be green and their source/runtime hashes to match the bytecode about to deploy.
- Require `HOOK_DEPLOYER_PRIVATE_KEY`. Missing key degrades to the dry-run result and exits `DEPLOY_TASKMARKET_HOOK_NO_KEY`.
- For `base`, enforce the triple lock, read deployer balance, require a non-zero gas balance, enforce optional `MAX_GAS_GWEI`, and warn if the gas-only wallet exceeds `HOOK_MAX_FLOAT_ETH` (default 0.1 ETH).
- Re-read target chain ID, Diamond codehash/default list, deterministic address code, gas price, and deploy ledger immediately before broadcast. Any drift invalidates the earlier fork and requires a fresh simulation.

### 8. Broadcast one deterministic deployment

Run only:

```bash
./taskmarket-hook-deploy.sh broadcast <chain>
```

The runner owns key access and deterministic CREATE2 deployment. If the predicted address already contains the exact runtime codehash, return `ALREADY_DEPLOYED`. If it contains different code, exit `DEPLOY_TASKMARKET_HOOK_ADDRESS_COLLISION`. Never search for a different salt silently.

After a confirmed receipt, read code from the target RPC and require exact runtime-codehash equality. Explorer source verification through `ETHERSCAN_API_KEY` is best-effort and must describe its real status; verification failure does not erase a confirmed deployment. A timeout/unknown receipt is `ambiguous`, not failed, until address/nonce inspection resolves it, and is never auto-retried.

### 9. Evidence and manifest

Persist the attempt under `output/taskmarket-hooks/<chainId>/<lowercase-address>/`. The successful rehearsal's runner-owned evidence is already present there; preserve it when adding the manifest and attempt metadata:

- `Hook.sol`, behavioral/lifecycle tests, compiler settings, dependency lock/pins.
- Static audit report, focused test output, local lifecycle output, fork block/hash and traces.
- Deployment receipt, creation/runtime codehashes, deterministic factory/salt/address, callback gas table, and explorer verification result.
- A schema-valid TaskMarket hook manifest at the canonical relative path `hook-registry/manifests/<chainId>/<lowercase-address>.json`, plus a copy with the output evidence.

The manifest schema is `https://taskmarket.dev/schemas/taskmarket-hook/1.0.0/schema.json`. Keep `valid`, `listing`, `sourceVerification`, `conformance`, `security.audits`, and `protocolDefault` as separate facts:

- `valid` means schema-valid only.
- `listing` remains unsubmitted/unlisted; this skill never publishes it.
- `sourceVerification` is true only after effective runtime source is actually verified.
- `conformance` cites the exact passing reports and pinned interface.
- `security.audits` stays empty unless a real, independent published audit URL exists. Agent static analysis is evidence, not an audit certification.
- `protocolDefault` is false; only TaskMarket governance can make it a default.
- Set `x-draft: true` until transaction hash, block, address, runtime codehash, gas evidence, source-verification status, and all required evidence links are complete. Never call a merely valid/listed hook audited, verified, safe, or endorsed.

### 10. Notify and log

Send one compact notification with mode, template, chain, predicted/deployed address, gate results, manifest draft status, and explorer link when live. For multi-line output use `./notify -f`. Deduplicate notifications against the last three days, but never suppress the ledger record.

Append exactly one block to `memory/logs/${today}.md`:

```markdown
### deploy-taskmarket-hook
- Status: <exit code>
- Mode: dry-run | armed-testnet | armed-mainnet
- Attempt: <attempt ID and fingerprint>
- Chain: <name and chain ID>; Diamond: <address>; fork block: <number/hash>
- Template: <tag|allowlist|receipt|freeform>; brief: <one line>
- Gates: audit=<pass|fail>; behavior=<pass|fail>; lifecycle=<pass|fail>; fork=<pass|fail>
- Address: <predicted or deployed>; runtime codehash: <hash or unavailable>
- Manifest: <path>; x-draft=<true|false>; listing=unsubmitted
- Broadcast: none | tx=<hash> | already-deployed | ambiguous | failed:<reason>
- Output: output/taskmarket-hooks/<chainId>/<lowercase-address>/
- Notification: sent | dedup-skipped | not-sent
```

## Exit taxonomy

- `DEPLOY_TASKMARKET_HOOK_EMPTY` / `DEPLOY_TASKMARKET_HOOK_BAD_BRIEF` — no implementable V1 brief.
- `DEPLOY_TASKMARKET_HOOK_NO_TOOLCHAIN` / `DEPLOY_TASKMARKET_HOOK_TARGET_MISMATCH` — environment or canonical target is not trustworthy.
- `DEPLOY_TASKMARKET_HOOK_COMPILE_FAILED` / `DEPLOY_TASKMARKET_HOOK_AUDIT_FAILED` / `DEPLOY_TASKMARKET_HOOK_TEST_FAILED` / `DEPLOY_TASKMARKET_HOOK_FORK_FAILED` — a mandatory pre-deploy gate failed.
- `DEPLOY_TASKMARKET_HOOK_DRY_RUN` — all available gates passed; no broadcast requested.
- `DEPLOY_TASKMARKET_HOOK_NO_KEY` — armed input, but only a dry-run was possible.
- `DEPLOY_TASKMARKET_HOOK_MAINNET_NOT_AUTHORIZED` / `DEPLOY_TASKMARKET_HOOK_UNDERFUNDED` / `DEPLOY_TASKMARKET_HOOK_GAS_TOO_HIGH` — mainnet safety lock stopped the write.
- `DEPLOY_TASKMARKET_HOOK_ADDRESS_COLLISION` / `DEPLOY_TASKMARKET_HOOK_BROADCAST_AMBIGUOUS` / `DEPLOY_TASKMARKET_HOOK_BROADCAST_FAILED` — no automatic retry.
- `DEPLOY_TASKMARKET_HOOK_ALREADY_DEPLOYED` — exact runtime code is already at the deterministic address.
- `DEPLOY_TASKMARKET_HOOK_OK` — receipt confirmed, runtime codehash matched, evidence and ledger persisted.
