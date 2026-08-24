#!/usr/bin/env bash
# taskmarket-hook-deploy.sh — secret-expansion-safe TaskMarket hook pipeline.
#
# Usage:
#   ./taskmarket-hook-deploy.sh simulate [base-sepolia|base]
#   ./taskmarket-hook-deploy.sh broadcast <base-sepolia|base>
#   ./taskmarket-hook-deploy.sh chains
#
# The workflow stages this file at the repository root. It reads the burner key
# internally, so the agent never expands a secret in its analyzed command text.
# This is a cooperative guardrail for Aeon's trusted write-mode agent, not an
# isolated signer or an enforceable key-custody boundary.
set -euo pipefail

MODE="${1:?usage: taskmarket-hook-deploy.sh <simulate|broadcast|chains> [chain]}"
CHAIN="${2:-base-sepolia}"
CHAIN_EXPLICIT=0
[ "$#" -ge 2 ] && CHAIN_EXPLICIT=1
DIR="${TASKMARKET_HOOKBUILD_DIR:-$HOME/taskmarket-hookbuild}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ITMP_HOOK_INTERFACE_ID="0x2187b4de"
TASKMARKET_PIN="657b9f74478bdf71c3c1b5e0d2dde7197aba56cb"
OPENZEPPELIN_PIN="fcbae5394ae8ad52d8e580a3477db99814b9d565"
OPENZEPPELIN_UPGRADEABLE_PIN="7bf4727aacdbfaa0f36cbd664654d0c9e1dc52bf"
FORGE_STD_PIN="1801b0541f4fda118a10798fd3486bb7051c5dd6"
CREATE2_FACTORY="0x4e59b44847b379578588920cA78FbF26c0B4956C"
BASE_HOOK_SHA256="9189c4098ee16b4b3d5b0d96d50278ab834b121f5d44376ac4a677d82f344705"
DEPLOY_SCRIPT_SHA256="b535d4e2b472824741cdd4d2012685e4ead19b62037df4c80ffca3e7dfd9a9d0"
FOUNDRY_CONFIG_SHA256="90ced724393dc3ff0a2754f0ba881aee444533eaa2fe1f67f2880548f0b7fe2b"
REMAPPINGS_SHA256="a7e3c537fcb2ca2d83d7d385b2650551e4d9b9fb329c437d16576bb3923b42b8"
CHAINS_SHA256="3305392fa326bb97fea6b7b51ba44794bbc1730333343c6d8f919e696750df02"
CALLBACK_HARNESS_SHA256="7217fa109c2ef7bc48b694911d84f53966b7516b23167076ac8ed0d14622dc76"
DIAMOND_HARNESS_SHA256="5e838673830bb77ac969ff7c53244a356838ace090992c501bda730975ecd954"
FORK_HARNESS_SHA256="24f37d10ccef7211e1fd1a3a11f23be602ef51021b66c6f747e42ca74879d1d8"

case "$MODE" in simulate|broadcast|chains) ;; *) echo "unknown mode: $MODE" >&2; exit 2 ;; esac

# Resolve the repository root whether invoked from skills/... or from the staged root copy.
if [ -d "$SCRIPT_DIR/skills/deploy-taskmarket-hook" ]; then
  ROOT="$SCRIPT_DIR"
else
  ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
OUTPUT_ROOT="${TASKMARKET_HOOK_OUTPUT_ROOT:-$ROOT/output/taskmarket-hooks}"

CHAINS="${TASKMARKET_CHAINS_FILE:-}"
for cand in "$CHAINS" "$SCRIPT_DIR/taskmarket-chains.tsv" "$DIR/taskmarket-chains.tsv" \
  "$ROOT/skills/deploy-taskmarket-hook/templates/chains.tsv"; do
  [ -n "$cand" ] && [ -f "$cand" ] && { CHAINS="$cand"; break; }
done
[ -f "$CHAINS" ] || { echo "TaskMarket chains registry not found" >&2; exit 3; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "no SHA-256 utility available" >&2
    return 1
  fi
}

dependency_tree_sha256() {
  local listing
  listing="$(mktemp)" || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    find lib -type f -exec sha256sum {} + | LC_ALL=C sort > "$listing" || { rm -f "$listing"; return 1; }
    sha256sum "$listing" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    find lib -type f -exec shasum -a 256 {} + | LC_ALL=C sort > "$listing" || { rm -f "$listing"; return 1; }
    shasum -a 256 "$listing" | awk '{print $1}'
  else
    rm -f "$listing"
    return 1
  fi
  rm -f "$listing"
}

assert_static_file() {
  local path="$1" expected="$2" label="$3" observed
  [ -f "$path" ] || { echo "missing immutable $label: $path" >&2; return 1; }
  observed="$(sha256_file "$path")" || return 1
  [ "$observed" = "$expected" ] || {
    echo "immutable $label hash mismatch; refusing key-bearing execution" >&2
    echo "  expected $expected" >&2
    echo "  observed $observed" >&2
    return 1
  }
}

assert_static_file "$CHAINS" "$CHAINS_SHA256" "chain registry" || exit 5

list_chains() {
  awk -F'\t' '!/^#/ && NF>=7 {printf "  %-14s chain=%-7s %s diamond=%s\n", $1, $2, ($3=="true"?"testnet":"MAINNET"), $4}' "$CHAINS"
}
if [ "$MODE" = "chains" ]; then
  echo "known TaskMarket hook targets:"
  list_chains
  exit 0
fi

case "$CHAIN" in base-mainnet|mainnet) CHAIN=base ;; sepolia) CHAIN=base-sepolia ;; esac
row="$(awk -F'\t' -v c="$CHAIN" '!/^#/ && $1==c {print; exit}' "$CHAINS")"
if [ -z "$row" ]; then
  { echo "unknown TaskMarket chain: $CHAIN"; list_chains; } >&2
  exit 4
fi
IFS=$'\t' read -r _CN CHAIN_ID TESTNET DIAMOND EXPECTED_DIAMOND_CODEHASH RPC EXPLORER ALCHEMY <<<"$row"

resolve_rpc() {
  [ -n "${TASKMARKET_RPC_URL:-}" ] && { echo "$TASKMARKET_RPC_URL"; return; }
  if [ -n "${ALCHEMY_API_KEY:-}" ] && [ -n "$ALCHEMY" ]; then
    echo "https://${ALCHEMY}.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
    return
  fi
  echo "$RPC"
}
RPC_URL="$(resolve_rpc)"
RPC_LABEL="$(printf '%s' "$RPC_URL" | sed -E 's#(https?://[^/]+).*#\1#')"
export FORGE_ETHERSCAN_API_KEY="${ETHERSCAN_API_KEY:-}"

[ -d "$DIR" ] || { echo "staged project missing at $DIR; run stage-deploy-taskmarket-hook.sh first" >&2; exit 3; }
[ -f "$DIR/taskmarket.commit" ] || { echo "missing staged TaskMarket dependency pin" >&2; exit 3; }
[ "$(tr -d '[:space:]' < "$DIR/taskmarket.commit")" = "$TASKMARKET_PIN" ] || {
  echo "unexpected TaskMarket dependency pin; refusing to build" >&2; exit 5;
}
command -v forge >/dev/null 2>&1 || { echo "forge is unavailable" >&2; exit 3; }
command -v cast >/dev/null 2>&1 || { echo "cast is unavailable" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "jq is unavailable" >&2; exit 3; }
cd "$DIR"

# These files own the target, dependency resolution, caller boundary, and the
# exact transaction sent by an armed run. Hook.sol and its focused fixtures are
# deliberately editable; key-bearing infrastructure is not.
assert_static_file "src/BaseTMPHook.sol" "$BASE_HOOK_SHA256" "BaseTMPHook" || exit 5
assert_static_file "script/DeployHook.s.sol" "$DEPLOY_SCRIPT_SHA256" "deploy script" || exit 5
assert_static_file "foundry.toml" "$FOUNDRY_CONFIG_SHA256" "Foundry config" || exit 5
assert_static_file "remappings.txt" "$REMAPPINGS_SHA256" "remappings" || exit 5
assert_static_file "test/HookLifecycle.t.sol" "$CALLBACK_HARNESS_SHA256" "callback harness" || exit 5
assert_static_file "test/HookDiamondLifecycle.t.sol" "$DIAMOND_HARNESS_SHA256" "Diamond harness" || exit 5
assert_static_file "test/HookFork.t.sol" "$FORK_HARNESS_SHA256" "fork harness" || exit 5

if [ "$MODE" = "broadcast" ] && [ -z "${TASKMARKET_DEPENDENCY_TREE_SHA256:-}" ]; then
  echo "missing workflow-owned dependency digest; refusing key-bearing execution" >&2
  exit 5
fi
EXPECTED_DEP_TREE="${TASKMARKET_DEPENDENCY_TREE_SHA256:-}"
if [ -z "$EXPECTED_DEP_TREE" ] && [ -f taskmarket-dependency-tree.sha256 ]; then
  EXPECTED_DEP_TREE="$(tr -d '[:space:]' < taskmarket-dependency-tree.sha256)"
fi
[ -n "$EXPECTED_DEP_TREE" ] || { echo "missing staged dependency digest" >&2; exit 5; }
OBSERVED_DEP_TREE="$(dependency_tree_sha256)" || { echo "could not hash staged dependencies" >&2; exit 5; }
[ "$OBSERVED_DEP_TREE" = "$EXPECTED_DEP_TREE" ] || {
  echo "staged dependency tree drifted from the commit-pinned workflow checkout" >&2
  echo "  expected $EXPECTED_DEP_TREE" >&2
  echo "  observed $OBSERVED_DEP_TREE" >&2
  exit 5
}

EVIDENCE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/taskmarket-hook-evidence.XXXXXX")"
cleanup_evidence_tmp() {
  rm -rf -- "$EVIDENCE_TMP"
}
trap cleanup_evidence_tmp EXIT

# Capture each gate verbatim while preserving shell-function side effects such
# as FORK_BLOCK. Avoiding a pipeline here is intentional: a piped function runs
# in a subshell and its resolved target evidence would be lost.
run_logged() {
  local log="$1"
  shift
  set +e
  "$@" >"$log" 2>&1
  local rc=$?
  set -e
  cat "$log"
  return "$rc"
}

scan_generated_hook() {
  local src="src/Hook.sol" generated_sources import_path fail=0 callbacks declared_positives declared_negatives
  echo "── automated security review (not a professional audit) ──"
  [ -f "$src" ] || { echo "  FAIL: src/Hook.sol missing"; return 1; }
  generated_sources="$(find src -type f -name '*.sol' ! -name 'BaseTMPHook.sol' -print)"
  grep -qE 'contract[[:space:]]+HookBehaviorTest[[:space:]]+is[[:space:]]+Test' test/HookBehavior.t.sol \
    || { echo "  FAIL: expected HookBehaviorTest contract is missing"; fail=1; }
  grep -qE 'contract[[:space:]]+Hook[[:space:]]+is[[:space:]]+BaseTMPHook' "$src" \
    || { echo "  FAIL: Hook must inherit the pinned BaseTMPHook"; fail=1; }
  grep -qE 'constructor[[:space:]]*\([[:space:]]*address[[:space:]]+diamond_' "$src" \
    || { echo "  FAIL: Hook must keep constructor(address diamond_)"; fail=1; }
  grep -qE 'BaseTMPHook[[:space:]]*\([[:space:]]*diamond_[[:space:]]*\)' "$src" \
    || { echo "  FAIL: constructor must bind BaseTMPHook(diamond_)"; fail=1; }
  grep -qE 'constructor[[:space:]]*\([[:space:]]*address[[:space:]]+diamond_[[:space:]]*\)[[:space:]]+BaseTMPHook[[:space:]]*\([[:space:]]*diamond_[[:space:]]*\)[[:space:]]*\{[[:space:]]*\}' "$src" \
    || { echo "  FAIL: generated Hook constructor must be side-effect-free"; fail=1; }

  while IFS= read -r import_path; do
    case "$import_path" in
      ./BaseTMPHook.sol|@taskmarket/contracts/src/interfaces/*|@openzeppelin/contracts/*) ;;
      *) echo "  FAIL: generated Hook import is outside the pinned allowlist: $import_path"; fail=1 ;;
    esac
  done < <(sed -nE 's/^[[:space:]]*import.*"([^"]+)".*/\1/p' "$src")

  callbacks="$(grep -cE 'function[[:space:]]+_(checkFund|checkClaim|checkSelectWorker|checkSubmit|checkEvaluate|checkComplete|onComplete|onForfeit|onCancel|onExpire)[[:space:]]*\(' "$src" || true)"
  echo "  internal lifecycle overrides: $callbacks"
  [ "$callbacks" -ge 1 ] || { echo "  FAIL: brief produced no observable policy/effect"; fail=1; }

  if grep -qE 'function[[:space:]]+(checkFund|checkClaim|checkSelectWorker|checkSubmit|checkEvaluate|checkComplete|onComplete|onForfeit|onCancel|onExpire)[[:space:]]*\(' "$src"; then
    echo "  FAIL: do not redefine external callbacks; override BaseTMPHook internal methods"
    fail=1
  fi
  grep -qE '\b(selfdestruct|suicide|delegatecall|callcode|tx\.origin)\b' $generated_sources \
    && { echo "  FAIL: destructive/delegated/tx.origin primitive present"; fail=1; }
  grep -qE '\bassembly[[:space:]]*\{' $generated_sources \
    && { echo "  FAIL: inline assembly requires manual review outside this deploy skill"; fail=1; }
  grep -qE '\.(call|staticcall)\s*(\{|\()' $generated_sources \
    && { echo "  FAIL: low-level external call requires manual review outside this deploy skill"; fail=1; }
  grep -qE '\bpayable\b' $generated_sources \
    && { echo "  FAIL: generated hooks must not receive native value"; fail=1; }
  grep -qE '\.(transfer|transferFrom|approve|safeTransfer|safeTransferFrom)[[:space:]]*\(' $generated_sources \
    && { echo "  FAIL: generated hook may not move or approve escrow-like assets"; fail=1; }
  grep -qE '\([[:space:]]*diamond[[:space:]]*\)[[:space:]]*\.' $generated_sources \
    && { echo "  FAIL: generated hook may not call back into the TaskMarket Diamond"; fail=1; }
  grep -qE '\b(new[[:space:]]+[A-Za-z_]|ERC1967|UUPS|TransparentUpgradeable|BeaconProxy|Clones\.|Ownable|AccessControl|onlyOwner)\b' $generated_sources \
    && { echo "  FAIL: child/proxy deployment requires a separate manual deployment path"; fail=1; }
  grep -qE '0x1111111111111111111111111111111111111111|replace-me|REPLACE_ME|TODO:' $generated_sources \
    && { echo "  FAIL: unresolved template placeholder in generated policy"; fail=1; }

  declared_positives="$(grep -cE 'function[[:space:]]+test[^ (]*(Positive|Allows|Accepts|Records)' test/HookBehavior.t.sol 2>/dev/null || true)"
  declared_negatives="$(grep -cE 'function[[:space:]]+test[^ (]*(Negative|Rejects|Blocks|Unauthorized)' test/HookBehavior.t.sol 2>/dev/null || true)"
  echo "  declared behavioral cases: positive=$declared_positives negative=$declared_negatives"
  [ "$declared_positives" -ge 1 ] || { echo "  FAIL: behavioral suite needs a named positive case"; fail=1; }
  [ "$declared_negatives" -ge 1 ] || { echo "  FAIL: behavioral suite needs a named negative case"; fail=1; }

  [ "$fail" -eq 0 ] && echo "  REVIEW PASS" || return 1
}

scan_built_bytecode() {
  local runtime disassembly
  runtime="$(forge inspect src/Hook.sol:Hook deployedBytecode)" || return 1
  disassembly="$(cast disassemble "$runtime")" || return 1
  if printf '%s\n' "$disassembly" | grep -qE '\b(DELEGATECALL|SELFDESTRUCT|CALLCODE)\b'; then
    echo "  FAIL: forbidden opcode in generated Hook runtime" >&2
    return 1
  fi
  echo "  runtime opcode review: PASS"
}

preflight_target() {
  local actual_chain code codehash defaults default_count remaining hook hook_code hook_support
  actual_chain="$(cast chain-id --rpc-url "$RPC_URL")"
  [ "$actual_chain" = "$CHAIN_ID" ] || {
    echo "RPC chain mismatch: expected $CHAIN_ID, got $actual_chain" >&2; return 1;
  }
  FORK_BLOCK="$(cast block-number --rpc-url "$RPC_URL")"
  [ -n "$FORK_BLOCK" ] || { echo "could not resolve a fork block" >&2; return 1; }
  FORK_BLOCK_HASH="$(cast block "$FORK_BLOCK" --field hash --rpc-url "$RPC_URL")"
  [ -n "$FORK_BLOCK_HASH" ] || { echo "could not resolve fork block hash" >&2; return 1; }
  code="$(cast code "$DIAMOND" --block "$FORK_BLOCK" --rpc-url "$RPC_URL")"
  [ "$code" != "0x" ] && [ -n "$code" ] || {
    echo "no code at configured TaskMarket Diamond $DIAMOND" >&2; return 1;
  }
  # Hash the already-fetched runtime locally. This avoids a second RPC method and
  # proved more reliable than eth_getCode through `cast codehash` on Base public RPC.
  codehash="$(cast keccak "$code" | tr '[:upper:]' '[:lower:]')"
  [ "$codehash" = "$(printf '%s' "$EXPECTED_DIAMOND_CODEHASH" | tr '[:upper:]' '[:lower:]')" ] || {
    echo "TaskMarket Diamond codehash mismatch" >&2
    echo "  expected $EXPECTED_DIAMOND_CODEHASH" >&2
    echo "  observed $codehash" >&2
    return 1
  }
  echo "target: $CHAIN chainId=$CHAIN_ID diamond=$DIAMOND codehash=$codehash forkBlock=$FORK_BLOCK forkHash=$FORK_BLOCK_HASH rpc=$RPC_LABEL"
  defaults="$(cast call "$DIAMOND" 'getDefaultHooks()(address[])' --block "$FORK_BLOCK" --rpc-url "$RPC_URL")" || {
    echo "could not read live protocol default hooks" >&2; return 1;
  }
  default_count="$(awk -v value="$defaults" 'BEGIN { print split(value, parts, "0x") - 1 }')"
  [ "$default_count" -le 8 ] || { echo "live default-hook list exceeds TaskMarket cap" >&2; return 1; }
  remaining=$((8 - default_count))
  LIVE_DEFAULT_HOOKS="$defaults"
  LIVE_DEFAULT_COUNT="$default_count"
  LIVE_CUSTOM_SLOTS="$remaining"
  echo "current protocol default hooks: $defaults (count=$default_count customSlots=$remaining)"
  for hook in $(printf '%s' "$defaults" | grep -oE '0x[a-fA-F0-9]{40}' || true); do
    hook_code="$(cast code "$hook" --block "$FORK_BLOCK" --rpc-url "$RPC_URL")"
    [ -n "$hook_code" ] && [ "$hook_code" != "0x" ] || {
      echo "default hook has no code: $hook" >&2; return 1;
    }
    hook_support="$(cast call "$hook" 'supportsInterface(bytes4)(bool)' "$ITMP_HOOK_INTERFACE_ID" \
      --block "$FORK_BLOCK" --rpc-url "$RPC_URL")" || {
      echo "default hook interface probe failed: $hook" >&2; return 1;
    }
    [ "$hook_support" = "true" ] || {
      echo "default hook does not support ITMPHook: $hook" >&2; return 1;
    }
  done
}

run_logged "$EVIDENCE_TMP/source-review.log" scan_generated_hook \
  || { echo "automated security review failed; refusing to $MODE" >&2; exit 5; }
run_logged "$EVIDENCE_TMP/format.log" forge fmt --check \
  || { echo "forge fmt check failed" >&2; exit 5; }
run_logged "$EVIDENCE_TMP/build.log" forge build --sizes \
  || { echo "compile/size gate failed" >&2; exit 6; }
run_logged "$EVIDENCE_TMP/runtime-review.log" scan_built_bytecode \
  || { echo "runtime bytecode review failed" >&2; exit 5; }

echo "── behavioral tests ──"
run_logged "$EVIDENCE_TMP/behavior-test.log" env NO_COLOR=1 \
  FOUNDRY_ALLOW_FAILURE=false \
  forge test --match-contract '^HookBehaviorTest$' -vv \
  || { echo "brief-specific behavioral tests failed" >&2; exit 6; }
BEHAVIOR_PASS_NAMES="$(sed -nE 's/^[[:space:]]*\[PASS\][[:space:]]+(test[^ (]+)\(.*/\1/p' "$EVIDENCE_TMP/behavior-test.log")"
BEHAVIOR_POSITIVE_PASSED="$(printf '%s\n' "$BEHAVIOR_PASS_NAMES" | grep -Ec '(Positive|Allows|Accepts|Records)' || true)"
BEHAVIOR_NEGATIVE_PASSED="$(printf '%s\n' "$BEHAVIOR_PASS_NAMES" | grep -Ec '(Negative|Rejects|Blocks|Unauthorized)' || true)"
if [ "$BEHAVIOR_POSITIVE_PASSED" -lt 1 ] || [ "$BEHAVIOR_NEGATIVE_PASSED" -lt 1 ]; then
  echo "brief-specific behavioral tests did not execute a passing named positive and negative case" >&2
  echo "  executed positive=$BEHAVIOR_POSITIVE_PASSED negative=$BEHAVIOR_NEGATIVE_PASSED" >&2
  exit 6
fi
printf '  executed behavioral cases: positive=%s negative=%s\n' \
  "$BEHAVIOR_POSITIVE_PASSED" "$BEHAVIOR_NEGATIVE_PASSED"
echo "── callback ABI + 1,000,000 gas ceiling ──"
run_logged "$EVIDENCE_TMP/callback-conformance.log" env NO_COLOR=1 \
  forge test --match-contract '^HookCallbackConformanceTest$' -vv \
  || { echo "callback conformance failed" >&2; exit 6; }
sed -nE 's/^[[:space:]]*([^:]+ gas):[[:space:]]*([0-9]+)$/\1\t\2/p' \
  "$EVIDENCE_TMP/callback-conformance.log" > "$EVIDENCE_TMP/callback-gas.tsv"
CALLBACK_GAS_COUNT="$(wc -l < "$EVIDENCE_TMP/callback-gas.tsv" | tr -d '[:space:]')"
[ "$CALLBACK_GAS_COUNT" -eq 10 ] \
  || { echo "callback conformance did not emit all 10 callback gas measurements" >&2; exit 6; }
MAX_CALLBACK_GAS="$(awk -F '\t' '$2 + 0 > max { max = $2 + 0 } END { print max + 0 }' "$EVIDENCE_TMP/callback-gas.tsv")"
echo "── local Diamond + PGTR + ordered-hook lifecycle integration ──"
run_logged "$EVIDENCE_TMP/local-diamond-lifecycle.log" env NO_COLOR=1 \
  forge test --match-contract '^HookDiamondLifecycleTest$' -vv \
  || { echo "local TaskMarket Diamond lifecycle integration failed" >&2; exit 6; }

run_logged "$EVIDENCE_TMP/target-preflight.log" preflight_target \
  || { echo "live target preflight failed" >&2; exit 7; }
echo "── fork rehearsal against live TaskMarket Diamond ──"
run_logged "$EVIDENCE_TMP/fork-rehearsal.log" env NO_COLOR=1 \
  TASKMARKET_DIAMOND="$DIAMOND" TASKMARKET_CHAIN_ID="$CHAIN_ID" \
  TASKMARKET_DIAMOND_CODEHASH="$EXPECTED_DIAMOND_CODEHASH" \
  forge test --fork-url "$RPC_URL" --match-contract '^HookForkRehearsalTest$' -vv \
  --fork-block-number "$FORK_BLOCK" \
  || { echo "fork rehearsal failed" >&2; exit 7; }

# Simulation always uses Anvil's public throwaway key. The real burner is not
# read until after the raw workflow arm proof has passed.
SIMULATION_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

run_script() {
  local broadcast="$1" log="$2" signing_key="$3"
  local args=(script script/DeployHook.s.sol:DeployHook --rpc-url "$RPC_URL" --fork-block-number "$FORK_BLOCK" --private-key "$signing_key")
  [ "$broadcast" = "true" ] && args+=(--broadcast --slow)
  set +e
  TASKMARKET_DIAMOND="$DIAMOND" forge "${args[@]}" 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

SIM_LOG="$EVIDENCE_TMP/deterministic-simulation.log"
echo "── deterministic CREATE2 fork simulation ──"
run_script false "$SIM_LOG" "$SIMULATION_KEY" || {
  rc=$?; rm -f "$SIM_LOG"; echo "deployment simulation failed" >&2; exit "$rc";
}
SIM_ADDR="$(grep -oE '0x[a-fA-F0-9]{40}' <(grep -E '(^|[[:space:]])(hook|ALREADY_DEPLOYED)([[:space:]]|$)' "$SIM_LOG") | head -1 || true)"
SIM_CODEHASH="$(grep -oE '0x[a-fA-F0-9]{64}' "$SIM_LOG" | tail -1 | tr '[:upper:]' '[:lower:]' || true)"
SIM_SALT="$(grep -oE '0x[a-fA-F0-9]{64}' "$SIM_LOG" | tail -2 | head -1 | tr '[:upper:]' '[:lower:]' || true)"
if [ -z "$SIM_ADDR" ] || [ -z "$SIM_CODEHASH" ] || [ -z "$SIM_SALT" ]; then
  rm -f "$SIM_LOG"; echo "simulation produced incomplete address/codehash evidence" >&2; exit 8
fi
echo "simulation receipt: hook=$SIM_ADDR runtimeCodehash=$SIM_CODEHASH diamond=$DIAMOND forkBlock=$FORK_BLOCK forkHash=$FORK_BLOCK_HASH explorer=$EXPLORER/address/$SIM_ADDR"

persist_simulation_evidence() {
  local sim_addr_lower out constructor_args creation_bytecode init_code_hash calculated_address
  local behavior_names_json callback_gas_json defaults_json generated_at evidence_json_tmp
  sim_addr_lower="$(printf '%s' "$SIM_ADDR" | tr '[:upper:]' '[:lower:]')"
  out="$OUTPUT_ROOT/$CHAIN_ID/$sim_addr_lower"
  mkdir -p "$out"

  cp src/Hook.sol src/BaseTMPHook.sol "$out/"
  cp test/HookBehavior.t.sol test/HookFixture.sol test/HookLifecycle.t.sol \
    test/HookDiamondLifecycle.t.sol test/HookFork.t.sol "$out/"
  cp script/DeployHook.s.sol foundry.toml remappings.txt taskmarket.commit taskmarket-chains.tsv "$out/"
  printf '%s\n' "$EXPECTED_DEP_TREE" > "$out/dependency-tree.sha256"
  {
    forge --version
    printf 'solc=0.8.24\nevm_version=cancun\noptimizer=true\noptimizer_runs=200\nvia_ir=true\n'
  } > "$out/toolchain.txt"

  cp "$EVIDENCE_TMP/source-review.log" "$out/source-review.log"
  cp "$EVIDENCE_TMP/format.log" "$out/format.log"
  cp "$EVIDENCE_TMP/build.log" "$out/build.log"
  cp "$EVIDENCE_TMP/runtime-review.log" "$out/runtime-review.log"
  cp "$EVIDENCE_TMP/behavior-test.log" "$out/behavior-test.log"
  cp "$EVIDENCE_TMP/callback-conformance.log" "$out/callback-conformance.log"
  cp "$EVIDENCE_TMP/callback-gas.tsv" "$out/callback-gas.tsv"
  cp "$EVIDENCE_TMP/local-diamond-lifecycle.log" "$out/local-diamond-lifecycle.log"
  cp "$EVIDENCE_TMP/target-preflight.log" "$out/target-preflight.log"
  cp "$EVIDENCE_TMP/fork-rehearsal.log" "$out/fork-rehearsal.log"
  cp "$SIM_LOG" "$out/deterministic-simulation.log"

  constructor_args="$(cast abi-encode 'constructor(address)' "$DIAMOND")"
  creation_bytecode="$(forge inspect src/Hook.sol:Hook bytecode)"
  init_code_hash="$(cast keccak "${creation_bytecode}${constructor_args#0x}" | tr '[:upper:]' '[:lower:]')"
  calculated_address="$(cast create2 --deployer "$CREATE2_FACTORY" --salt "$SIM_SALT" --init-code-hash "$init_code_hash")"
  [ "$(printf '%s' "$calculated_address" | tr '[:upper:]' '[:lower:]')" = "$sim_addr_lower" ] || {
    echo "simulation CREATE2 address does not match independently recomputed evidence" >&2
    return 1
  }
  behavior_names_json="$(jq -Rn --arg names "$BEHAVIOR_PASS_NAMES" '$names | split("\n") | map(select(length > 0))')"
  callback_gas_json="$(jq -Rn '[inputs | select(length > 0) | split("\t") | {callback: .[0], gas: (.[1] | tonumber)}]' < "$EVIDENCE_TMP/callback-gas.tsv")"
  defaults_json="$(jq -Rn --arg hooks "$LIVE_DEFAULT_HOOKS" '[$hooks | scan("0x[a-fA-F0-9]{40}")]')"
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  evidence_json_tmp="$out/.simulation-evidence.$$.json"
  jq -n \
    --arg generatedAt "$generated_at" --arg chain "$CHAIN" --argjson chainId "$CHAIN_ID" \
    --arg rpc "$RPC_LABEL" --arg explorer "$EXPLORER/address/$SIM_ADDR" \
    --arg diamond "$DIAMOND" --arg diamondCodehash "$EXPECTED_DIAMOND_CODEHASH" \
    --argjson forkBlock "$FORK_BLOCK" --arg forkBlockHash "$FORK_BLOCK_HASH" \
    --arg hook "$SIM_ADDR" --arg create2Factory "$CREATE2_FACTORY" --arg create2Salt "$SIM_SALT" \
    --arg initCodeHash "$init_code_hash" --arg runtimeCodehash "$SIM_CODEHASH" \
    --arg interfaceId "$ITMP_HOOK_INTERFACE_ID" --argjson defaults "$defaults_json" \
    --argjson defaultCount "$LIVE_DEFAULT_COUNT" --argjson customSlots "$LIVE_CUSTOM_SLOTS" \
    --argjson behaviorNames "$behavior_names_json" \
    --argjson positivePassed "$BEHAVIOR_POSITIVE_PASSED" --argjson negativePassed "$BEHAVIOR_NEGATIVE_PASSED" \
    --argjson callbackGas "$callback_gas_json" --argjson maxCallbackGas "$MAX_CALLBACK_GAS" \
    --arg taskmarketPin "$TASKMARKET_PIN" --arg openzeppelinPin "$OPENZEPPELIN_PIN" \
    --arg openzeppelinUpgradeablePin "$OPENZEPPELIN_UPGRADEABLE_PIN" --arg forgeStdPin "$FORGE_STD_PIN" \
    --arg dependencyTreeSha256 "$EXPECTED_DEP_TREE" --arg hookSourceSha256 "$(sha256_file src/Hook.sol)" \
    --arg behaviorSourceSha256 "$(sha256_file test/HookBehavior.t.sol)" \
    '{schemaVersion:1,mode:"simulate",status:"passed",broadcast:false,generatedAt:$generatedAt,chain:$chain,chainId:$chainId,rpc:$rpc,explorer:$explorer,taskmarketDiamond:$diamond,taskmarketDiamondRuntimeCodehash:$diamondCodehash,fork:{block:$forkBlock,blockHash:$forkBlockHash},liveDefaults:{hooks:$defaults,count:$defaultCount,customSlotsRemaining:$customSlots},deployment:{predictedHook:$hook,create2Factory:$create2Factory,salt:$create2Salt,initCodeHash:$initCodeHash,runtimeCodehash:$runtimeCodehash,itmpHookInterfaceId:$interfaceId},gates:{sourceReview:"passed",format:"passed",build:"passed",runtimeReview:"passed",behavior:{status:"passed",executedTests:$behaviorNames,positivePassed:$positivePassed,negativePassed:$negativePassed},callbackConformance:{status:"passed",measurements:$callbackGas,maximumMeasuredGas:$maxCallbackGas},localDiamondLifecycle:"passed",forkRehearsal:"passed",deterministicDeployment:"passed"},pins:{taskmarketContracts:$taskmarketPin,openzeppelinContracts:$openzeppelinPin,openzeppelinContractsUpgradeable:$openzeppelinUpgradeablePin,forgeStd:$forgeStdPin,dependencyTreeSha256:$dependencyTreeSha256},sourceHashes:{hookSol:$hookSourceSha256,hookBehaviorTest:$behaviorSourceSha256},securityReview:"automated-only",registryStatus:"unlisted",sourceVerification:false,protocolDefault:false}' \
    > "$evidence_json_tmp"
  mv "$evidence_json_tmp" "$out/simulation-evidence.json"
  echo "dry-run evidence: $out"
}

persist_simulation_evidence
if [ "$MODE" = "simulate" ]; then
  echo "DRY RUN COMPLETE — no transaction broadcast"
  exit 0
fi
rm -f "$SIM_LOG"

case "${HOOK_REQUEST_VAR:-}" in
  arm:*) ;;
  *) echo "broadcast blocked: workflow input did not begin with arm:" >&2; exit 9 ;;
esac

if [ -z "${HOOK_DEPLOYER_PRIVATE_KEY:-}" ]; then
  echo "set HOOK_DEPLOYER_PRIVATE_KEY to broadcast" >&2
  exit 9
fi
KEY="$HOOK_DEPLOYER_PRIVATE_KEY"

# Triple mainnet lock: broadcast mode (arm:) + explicit chain + operator variable.
if [ "$TESTNET" != "true" ]; then
  [ "$CHAIN_EXPLICIT" = "1" ] || {
    echo "mainnet blocked: request must include an explicit chain:base" >&2; exit 9;
  }
  REQUESTED_MAINNET="$(printf '%s\n' "${HOOK_REQUEST_VAR#arm:}" | awk '{for (i=1; i<=NF; i++) if ($i=="chain:base") {print $i; exit}}')"
  [ "$REQUESTED_MAINNET" = "chain:base" ] || {
    echo "mainnet blocked: raw workflow input lacks the exact chain:base token" >&2; exit 9;
  }
  [ "${HOOK_MAINNET_OK:-}" = "1" ] || {
    echo "mainnet blocked: set HOOK_MAINNET_OK=1 as a repo variable" >&2; exit 9;
  }
  echo "!! MAINNET broadcast authorized: $CHAIN ($CHAIN_ID), gas only"
fi

# Re-read the chain, Diamond codehash, and live default list immediately before
# the irreversible call so target drift invalidates the earlier rehearsal.
preflight_target || { echo "target changed after rehearsal; broadcast cancelled" >&2; exit 7; }

DEPLOYER="$(cast wallet address --private-key "$KEY")"
BAL_WEI="$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL")"
[ "$BAL_WEI" != "0" ] || { echo "deployer $DEPLOYER is unfunded on $CHAIN" >&2; exit 10; }
echo "deployer=$DEPLOYER balanceWei=$BAL_WEI"
if [ -n "${MAX_GAS_GWEI:-}" ]; then
  GAS_WEI="$(cast gas-price --rpc-url "$RPC_URL")"
  awk -v gas="$GAS_WEI" -v cap="$MAX_GAS_GWEI" 'BEGIN { exit !((gas / 1000000000) > cap) }' && {
    echo "gas price exceeds MAX_GAS_GWEI=$MAX_GAS_GWEI" >&2; exit 10;
  }
fi
if [ "$TESTNET" != "true" ]; then
  FLOAT_CEIL="${HOOK_MAX_FLOAT_ETH:-0.1}"
  awk -v wei="$BAL_WEI" -v cap="$FLOAT_CEIL" 'BEGIN { exit !((wei / 1000000000000000000) > cap) }' && {
    echo "WARN: deployer balance exceeds HOOK_MAX_FLOAT_ETH=$FLOAT_CEIL; keep deployment keys gas-only" >&2
  }
fi

SIM_ADDR_LOWER="$(printf '%s' "$SIM_ADDR" | tr '[:upper:]' '[:lower:]')"
ATTEMPT_OUT="$OUTPUT_ROOT/$CHAIN_ID/$SIM_ADDR_LOWER"
RUNJSON="broadcast/DeployHook.s.sol/$CHAIN_ID/run-latest.json"
PRE_NONCE="$(cast nonce "$DEPLOYER" --rpc-url "$RPC_URL")"
PRE_PENDING_NONCE="$(cast nonce "$DEPLOYER" --block pending --rpc-url "$RPC_URL")"
PRE_CODE="$(cast code "$SIM_ADDR" --rpc-url "$RPC_URL")"
BROADCAST_STATUS="submitted"
BROADCAST_LOG="$(mktemp)"

preserve_broadcast_attempt() {
  mkdir -p "$ATTEMPT_OUT"
  cp "$BROADCAST_LOG" "$ATTEMPT_OUT/broadcast-attempt.log"
  [ -f "$RUNJSON" ] && cp "$RUNJSON" "$ATTEMPT_OUT/run-latest.json"
}

if [ -n "$PRE_CODE" ] && [ "$PRE_CODE" != "0x" ]; then
  PRE_CODEHASH="$(cast keccak "$PRE_CODE" | tr '[:upper:]' '[:lower:]')"
  if [ "$PRE_CODEHASH" != "$SIM_CODEHASH" ]; then
    rm -f "$BROADCAST_LOG"
    echo "DEPLOY_TASKMARKET_HOOK_ADDRESS_COLLISION: predicted address contains different runtime" >&2
    exit 11
  fi
  printf 'ALREADY_DEPLOYED %s\n' "$SIM_ADDR" | tee "$BROADCAST_LOG"
  HOOK_ADDR="$SIM_ADDR"
  BROADCAST_STATUS="already-deployed"
else
  echo "── broadcast ──"
  if run_script true "$BROADCAST_LOG" "$KEY"; then
    BROADCAST_RC=0
  else
    BROADCAST_RC=$?
  fi
  HOOK_ADDR="$(grep -oE '0x[a-fA-F0-9]{40}' <(grep -E '(^|[[:space:]])(hook|ALREADY_DEPLOYED)([[:space:]]|$)' "$BROADCAST_LOG") | head -1 || true)"
  POST_CODE="$(cast code "$SIM_ADDR" --rpc-url "$RPC_URL" 2>/dev/null || true)"
  POST_NONCE="$(cast nonce "$DEPLOYER" --rpc-url "$RPC_URL" 2>/dev/null || true)"
  POST_PENDING_NONCE="$(cast nonce "$DEPLOYER" --block pending --rpc-url "$RPC_URL" 2>/dev/null || true)"
  POST_CODEHASH=""
  [ -n "$POST_CODE" ] && [ "$POST_CODE" != "0x" ] \
    && POST_CODEHASH="$(cast keccak "$POST_CODE" | tr '[:upper:]' '[:lower:]')"

  if [ "$BROADCAST_RC" -ne 0 ] || [ -z "$HOOK_ADDR" ]; then
    preserve_broadcast_attempt
    if [ "$POST_CODEHASH" = "$SIM_CODEHASH" ]; then
      echo "broadcast command lost its receipt, but exact runtime is confirmed at $SIM_ADDR" >&2
      HOOK_ADDR="$SIM_ADDR"
      BROADCAST_STATUS="confirmed-after-command-error"
    else
      echo "DEPLOY_TASKMARKET_HOOK_BROADCAST_AMBIGUOUS: receipt/code unresolved; latestNonce=$PRE_NONCE->$POST_NONCE pendingNonce=$PRE_PENDING_NONCE->$POST_PENDING_NONCE; preserved $ATTEMPT_OUT" >&2
      exit 12
    fi
  fi
fi

BOUND_DIAMOND="$(cast call "$HOOK_ADDR" 'diamond()(address)' --rpc-url "$RPC_URL")"
[ "$(printf '%s' "$BOUND_DIAMOND" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$DIAMOND" | tr '[:upper:]' '[:lower:]')" ] \
  || { rm -f "$BROADCAST_LOG"; echo "deployed hook is bound to the wrong Diamond" >&2; exit 11; }
SUPPORTS="$(cast call "$HOOK_ADDR" 'supportsInterface(bytes4)(bool)' "$ITMP_HOOK_INTERFACE_ID" --rpc-url "$RPC_URL")"
[ "$SUPPORTS" = "true" ] || { rm -f "$BROADCAST_LOG"; echo "deployed hook fails ITMPHook ERC165 check" >&2; exit 11; }
HOOK_CODE="$(cast code "$HOOK_ADDR" --rpc-url "$RPC_URL")"
[ "$HOOK_CODE" != "0x" ] || { rm -f "$BROADCAST_LOG"; echo "deployed hook has no runtime code" >&2; exit 11; }
HOOK_CODEHASH="$(cast keccak "$HOOK_CODE" | tr '[:upper:]' '[:lower:]')"
[ "$HOOK_CODEHASH" = "$SIM_CODEHASH" ] || {
  preserve_broadcast_attempt
  echo "deployed hook runtime differs from the rehearsed bytecode" >&2
  exit 11
}

TX_HASHES=""
if command -v jq >/dev/null 2>&1 && [ -f "$RUNJSON" ]; then
  TX_HASHES="$(jq -r '[.transactions[]? | (.hash // .transactionHash // empty)] | unique | join(",")' "$RUNJSON")"
fi

echo "──────── TaskMarket hook deploy receipt ────────"
echo "  chain              $CHAIN ($CHAIN_ID)"
echo "  TaskMarket Diamond $DIAMOND"
echo "  Diamond codehash   $EXPECTED_DIAMOND_CODEHASH"
echo "  hook               $HOOK_ADDR"
echo "  hook codehash      $HOOK_CODEHASH"
echo "  ITMPHook interface $ITMP_HOOK_INTERFACE_ID"
echo "  broadcast status    $BROADCAST_STATUS"
echo "  transactions       ${TX_HASHES:-already deployed / unavailable}"
echo "  explorer           $EXPLORER/address/$HOOK_ADDR"

# Persist concrete deployment evidence. Registry publication remains a separate,
# reviewable action; this receipt must not be mistaken for audit/listing/default status.
HOOK_ADDR_LOWER="$(printf '%s' "$HOOK_ADDR" | tr '[:upper:]' '[:lower:]')"
OUT="$OUTPUT_ROOT/$CHAIN_ID/$HOOK_ADDR_LOWER"
mkdir -p "$OUT"
cp src/Hook.sol "$OUT/Hook.sol"
cp test/HookBehavior.t.sol "$OUT/HookBehavior.t.sol"
cp test/HookFixture.sol "$OUT/HookFixture.sol"
cp test/HookLifecycle.t.sol "$OUT/HookLifecycle.t.sol"
cp test/HookDiamondLifecycle.t.sol "$OUT/HookDiamondLifecycle.t.sol"
cp test/HookFork.t.sol "$OUT/HookFork.t.sol"
cp "$BROADCAST_LOG" "$OUT/broadcast-attempt.log"
[ -f "$RUNJSON" ] && cp "$RUNJSON" "$OUT/run-latest.json"
if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg chain "$CHAIN" --argjson chainId "$CHAIN_ID" --arg diamond "$DIAMOND" \
    --arg diamondCodehash "$EXPECTED_DIAMOND_CODEHASH" --arg hook "$HOOK_ADDR" \
    --arg hookCodehash "$HOOK_CODEHASH" --arg interfaceId "$ITMP_HOOK_INTERFACE_ID" \
    --arg broadcastStatus "$BROADCAST_STATUS" \
    --arg txHashes "$TX_HASHES" --arg explorer "$EXPLORER/address/$HOOK_ADDR" \
    --arg taskmarketSourcePin "$TASKMARKET_PIN" \
    '{schemaVersion:1,chain:$chain,chainId:$chainId,taskmarketDiamond:$diamond,taskmarketDiamondRuntimeCodehash:$diamondCodehash,hook:$hook,hookRuntimeCodehash:$hookCodehash,itmpHookInterfaceId:$interfaceId,broadcastStatus:$broadcastStatus,transactionHashes:($txHashes|split(",")|map(select(length>0))),explorer:$explorer,taskmarketSourcePin:$taskmarketSourcePin,securityReview:"automated-only",registryStatus:"unlisted"}' \
    > "$OUT/deployment-evidence.json"
fi

# Explorer verification is best effort after a completed, checked deploy.
if [ -n "${ETHERSCAN_API_KEY:-}" ]; then
  echo "── explorer source verification (best effort) ──"
  CARGS="$(cast abi-encode 'constructor(address)' "$DIAMOND")"
  verified=0
  for attempt in 1 2 3 4; do
    verify_out="$(forge verify-contract "$HOOK_ADDR" src/Hook.sol:Hook --chain-id "$CHAIN_ID" \
      --etherscan-api-key "$ETHERSCAN_API_KEY" --constructor-args "$CARGS" --watch 2>&1 || true)"
    if printf '%s' "$verify_out" | grep -qiE 'Pass - Verified|successfully verified|already verified'; then
      echo "  verified on attempt $attempt: $EXPLORER/address/$HOOK_ADDR#code"
      verified=1
      break
    fi
    echo "  attempt $attempt/4 not confirmed (explorer may still be indexing CREATE2)"
    [ "$attempt" -lt 4 ] && sleep "${HOOK_VERIFY_BACKOFF:-20}"
  done
  [ "$verified" = "1" ] || echo "  WARN: verification not confirmed; deployment remains live and source is preserved at $OUT" >&2
fi

rm -f "$BROADCAST_LOG"
exit 0
