#!/usr/bin/env bash
# Configure + build + run the whole hoshidicts native test suite via the unified
# CMake/ctest harness (tests/CMakeLists.txt). Linux/macOS.
#
# C++23 std::expected is required (the engine + glaze need it):
#   * Linux: g++-14 (set CC=gcc-14 CXX=g++-14, as CI does).
#   * macOS: a recent AppleClang.
# Override the compiler via CC/CXX env vars; override the build dir via
# HOSHI_TEST_BUILD_DIR (defaults to a short path under the system temp dir to
# stay clear of CMAKE_OBJECT_PATH_MAX on deep worktree checkouts).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="${HOSHI_TEST_BUILD_DIR:-${TMPDIR:-/tmp}/hoshi_tests_build}"

gen=()
if command -v ninja >/dev/null 2>&1; then
  gen=(-G Ninja)
fi

cmake -S "$here" -B "$build_dir" "${gen[@]}" -DCMAKE_BUILD_TYPE=Release
cmake --build "$build_dir" --config Release
ctest --test-dir "$build_dir" --output-on-failure -C Release
