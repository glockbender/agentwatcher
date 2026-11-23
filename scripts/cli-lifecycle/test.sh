#!/bin/bash
# Closes a chat in each real client while a deletion waits for approval. The runner refuses to
# start outside a disposable macOS guest, because the confirmation windows open on its screen.
set -euo pipefail
cd "$(dirname "$0")/../.."
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
    CARGO_TARGET_DIR="$target" rustup run 1.98.1 cargo run --locked --quiet \
        --manifest-path native/git-protection-e2e/Cargo.toml -- \
        close "$client" --binary "$binary" --windows "$probe"
done
