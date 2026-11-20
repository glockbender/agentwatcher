#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
for client in "${CLAUDE_BIN:-claude}" "${CODEX_BIN:-codex}"; do
    "$client" --version
done

target="${CARGO_TARGET_DIR:-$PWD/.build/git-protection}"
binary="${AGENT_WATCH_TEST_GIT_BIN:-}"
if [[ -z "$binary" ]]; then
    rustup run 1.98.1 cargo build --locked --release \
        --manifest-path native/git-protection/Cargo.toml --target-dir "$target"
    binary="$target/release/agent-watch-git"
fi
mkdir -p .build/cli-lifecycle
probe="$PWD/.build/cli-lifecycle/windows"
xcrun swiftc -O scripts/cli-lifecycle/windows.swift -o "$probe"
for client in codex claude; do
    python3 -Bu scripts/cli-lifecycle/run.py "$client" --binary "$binary" --windows "$probe"
done
