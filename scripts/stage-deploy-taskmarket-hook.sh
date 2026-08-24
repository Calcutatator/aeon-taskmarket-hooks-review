#!/usr/bin/env bash
# Stage Foundry and a commit-pinned TaskMarket hook project before the agent run.
# No-op for other skills; best-effort so the skill can emit NO_TOOLCHAIN cleanly.
set -uo pipefail

SKILL="${1:-}"
[ "$SKILL" = "deploy-taskmarket-hook" ] || exit 0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${TASKMARKET_HOOKBUILD_DIR:-$HOME/taskmarket-hookbuild}"
TPL="$ROOT/skills/deploy-taskmarket-hook/templates"
TASKMARKET_PIN="657b9f74478bdf71c3c1b5e0d2dde7197aba56cb"
OPENZEPPELIN_PIN="fcbae5394ae8ad52d8e580a3477db99814b9d565"
OPENZEPPELIN_UPGRADEABLE_PIN="7bf4727aacdbfaa0f36cbd664654d0c9e1dc52bf"
FORGE_STD_PIN="1801b0541f4fda118a10798fd3486bb7051c5dd6"

log() { echo "stage-deploy-taskmarket-hook: $*"; }

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

# This directory is intentionally rebuilt from immutable pins. Resolve and reject
# broad or ambiguous targets before the only destructive operation in this script.
if [ -z "$DIR" ] || [ "$DIR" = "/" ] || [ "$DIR" = "." ]; then
  log "REFUSE unsafe TASKMARKET_HOOKBUILD_DIR=$DIR"
  exit 1
fi
if [ -e "$DIR" ]; then
  DIR="$(cd "$DIR" && pwd -P)" || { log "REFUSE unresolved build directory"; exit 1; }
else
  DIR_PARENT="$(cd "$(dirname "$DIR")" && pwd -P)" || { log "REFUSE unresolved build-directory parent"; exit 1; }
  DIR="$DIR_PARENT/$(basename "$DIR")"
fi
case "$DIR" in
  /|"$HOME"|"$ROOT") log "REFUSE unsafe TASKMARKET_HOOKBUILD_DIR=$DIR"; exit 1 ;;
  "$ROOT"/*) log "REFUSE build directory inside repository: $DIR"; exit 1 ;;
esac
[ "${#DIR}" -ge 12 ] || { log "REFUSE suspiciously broad TASKMARKET_HOOKBUILD_DIR=$DIR"; exit 1; }
case "$(basename "$DIR")" in
  taskmarket-hookbuild|aeon-taskmarket-hookbuild) ;;
  *) log "REFUSE non-dedicated build directory name: $DIR"; exit 1 ;;
esac

if ! command -v forge >/dev/null 2>&1; then
  log "forge not on PATH; falling back to the official installer"
  curl -L https://foundry.paradigm.xyz | bash || log "WARN Foundry installer failed"
  "$HOME/.foundry/bin/foundryup" || log "WARN foundryup failed"
fi
if [ -x "$HOME/.foundry/bin/forge" ]; then
  export PATH="$HOME/.foundry/bin:$PATH"
  [ -n "${GITHUB_PATH:-}" ] && echo "$HOME/.foundry/bin" >> "$GITHUB_PATH"
fi
if ! command -v forge >/dev/null 2>&1; then
  log "WARN forge unavailable; skill will degrade to DEPLOY_TASKMARKET_HOOK_NO_TOOLCHAIN"
  exit 0
fi
log "forge $(forge --version 2>/dev/null | head -1)"

rm -rf "$DIR"
mkdir -p "$DIR/src" "$DIR/test" "$DIR/script" "$DIR/lib"
cd "$DIR"

# Match the public create-taskmarket-hook scaffold exactly. These immutable pins
# keep the ITMPHook ABI stable across fresh, headless runs.
forge install --no-git "daydreamsai/taskmarket-contracts@$TASKMARKET_PIN" \
  || { log "WARN TaskMarket dependency install failed"; exit 0; }
forge install --no-git "OpenZeppelin/openzeppelin-contracts@$OPENZEPPELIN_PIN" \
  || { log "WARN OpenZeppelin dependency install failed"; exit 0; }
forge install --no-git "OpenZeppelin/openzeppelin-contracts-upgradeable@$OPENZEPPELIN_UPGRADEABLE_PIN" \
  || { log "WARN OpenZeppelin upgradeable dependency install failed"; exit 0; }
forge install --no-git "foundry-rs/forge-std@$FORGE_STD_PIN" \
  || { log "WARN forge-std dependency install failed"; exit 0; }

cp "$TPL/foundry.toml" "$TPL/remappings.txt" .
cp "$TPL/Hook.sol" "$TPL/BaseTMPHook.sol" src/
cp "$TPL/DeployHook.s.sol" script/
cp "$TPL/HookBehavior.t.sol" "$TPL/HookFixture.sol" "$TPL/HookLifecycle.t.sol" \
  "$TPL/HookDiamondLifecycle.t.sol" "$TPL/HookFork.t.sol" test/
cp "$TPL/chains.tsv" taskmarket-chains.tsv
printf '%s\n' "$TASKMARKET_PIN" > taskmarket.commit

if forge build >/dev/null 2>&1; then
  log "pinned project built at $DIR"
else
  log "WARN initial build failed; generated source may need repair"
fi

# Lock the complete installed dependency trees after the pinned checkout. The
# workflow exports the digest outside the model's files; an armed runner refuses
# to use a key without that workflow-owned value.
DEP_TREE_SHA256="$(dependency_tree_sha256)" || {
  log "WARN could not hash staged dependencies; armed runs will fail closed"
  DEP_TREE_SHA256=""
}
if [ -n "$DEP_TREE_SHA256" ]; then
  printf '%s\n' "$DEP_TREE_SHA256" > taskmarket-dependency-tree.sha256
  [ -n "${GITHUB_ENV:-}" ] && echo "TASKMARKET_DEPENDENCY_TREE_SHA256=$DEP_TREE_SHA256" >> "$GITHUB_ENV"
  log "dependency tree locked: $DEP_TREE_SHA256"
fi

# Secret-expansion-safe root runner and registry. The runner keeps the burner out
# of model-authored command text; it is not a signer-isolation boundary. Both are
# runtime copies and should remain ignored.
cp "$ROOT/skills/deploy-taskmarket-hook/taskmarket-hook-deploy.sh" "$ROOT/taskmarket-hook-deploy.sh"
chmod +x "$ROOT/taskmarket-hook-deploy.sh"
cp "$TPL/chains.tsv" "$ROOT/taskmarket-chains.tsv"
[ -n "${GITHUB_ENV:-}" ] && echo "TASKMARKET_HOOKBUILD_DIR=$DIR" >> "$GITHUB_ENV"
log "staged ./taskmarket-hook-deploy.sh + taskmarket-chains.tsv + TASKMARKET_HOOKBUILD_DIR=$DIR"
exit 0
