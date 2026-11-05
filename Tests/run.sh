#!/bin/zsh
# Offline regression checks; requests use URLProtocol mocks, never a real API key.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/sttark-rewrite-tests.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT
sources=(Sources/*.swift)
sources=(${sources:#Sources/main.swift})
for suite in Rewrites Undo; do
  swiftc -swift-version 5 "${sources[@]}" "Tests/$suite/main.swift" -o "$TEST_BUILD/$suite"
  "$TEST_BUILD/$suite"
done
