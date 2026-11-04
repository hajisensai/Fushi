#!/usr/bin/env bash
# Repo-wide `cargo fmt` over every tracked Rust crate under native/.
#
#   bash tool/rust_format.sh check   # CI gate: exit 1 and print the diff if any crate is unformatted
#   bash tool/rust_format.sh fix     # format them in place
#
# Rust counterpart of tool/dart_format.sh. Style comes from the repo-root
# rustfmt.toml (style_edition pinned); CI runs this in
# .github/workflows/rust-format.yml.
#
# Crate discovery: every tracked native/**/Cargo.toml.
#   * A crate that sits under a Cargo.toml declaring [workspace] is skipped:
#     the workspace root runs `cargo fmt --all`, which already covers its
#     members (no crate is formatted twice).
#   * Other crates run plain `cargo fmt` (current package only). `--all` there
#     would also walk local path dependencies (e.g. fushi_ios_umbrella ->
#     fushi_fsrs) and format those crates a second time.
#
# Out of scope (never handed to rustfmt):
#   native/fushidicts, native/fushi_torrent, native/galgame_hook, native/fushi_aacs
#       C/C++ modules (no Rust today). Listed explicitly so a Cargo.toml ever
#       vendored into them (third-party sources) is not reformatted.
#   native/fushi_rwkv/tools/oracle: its `mod rwkv` pulls upstream code verbatim
#       from an untracked ./upstream checkout; that declaration carries
#       #[rustfmt::skip], so only the oracle's own files are formatted.
set -euo pipefail

mode="${1:-}"
case "$mode" in
  check) extra=(--check) ;;
  fix) extra=() ;;
  *)
    echo "usage: bash tool/rust_format.sh check|fix" >&2
    exit 64
    ;;
esac

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

manifests=()
while IFS= read -r -d '' m; do
  manifests+=("$m")
done < <(git ls-files -z -- 'native/**Cargo.toml' \
  ':(exclude)native/fushidicts/**' \
  ':(exclude)native/fushi_torrent/**' \
  ':(exclude)native/galgame_hook/**' \
  ':(exclude)native/fushi_aacs/**')

if [ "${#manifests[@]}" -eq 0 ]; then
  echo "rust_format: no Cargo.toml selected (pathspec broken?)" >&2
  exit 1
fi

declares_workspace() {
  grep -q '^[[:space:]]*\[workspace\]' "$1"
}

# True when some ancestor directory of $1 (strictly above its own, up to native/)
# holds a Cargo.toml with [workspace]; that root's `cargo fmt --all` owns it.
inside_workspace() {
  local dir
  dir="$(dirname "$(dirname "$1")")"
  while [ "$dir" != "native" ] && [ "$dir" != "." ]; do
    if [ -f "$dir/Cargo.toml" ] && declares_workspace "$dir/Cargo.toml"; then
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

failed=()
count=0
for manifest in "${manifests[@]}"; do
  if inside_workspace "$manifest"; then
    continue
  fi
  scope=()
  if declares_workspace "$manifest"; then
    scope=(--all)
  fi
  count=$((count + 1))
  echo "== cargo fmt ${scope[*]:-} ${extra[*]:-} ($manifest)"
  if ! cargo fmt --manifest-path "$manifest" "${scope[@]}" "${extra[@]}"; then
    failed+=("$manifest")
  fi
done

echo "rust_format: $mode ran on $count crate(s)"
if [ "${#failed[@]}" -ne 0 ]; then
  printf 'rust_format: failed: %s\n' "${failed[@]}" >&2
  if [ "$mode" = check ]; then
    echo "::error title=rustfmt::Unformatted Rust code above. Run: bash tool/rust_format.sh fix" >&2
  fi
  exit 1
fi
