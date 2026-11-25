#!/usr/bin/env bash
# dist_test worker: what worker_prepare.sh made, kept per content key
# (2026-11-16).
#
# A checkout goes from run to run batch by batch (worker_slot.sh `yield`), so
# two runs whose snapshots differ in a native crate or in the dependencies
# take turns on it. A single "what is here now" stamp made each turn redo the
# other run's work: a release build of every crate whose tree differs, and a
# warm-up test run for the dependencies. Instead every native library set is
# kept under the key it was built for, and the warm-up is remembered per key;
# a turn back to a key seen before copies the library set back (or skips the
# warm-up) instead of building it again.
#
# Run from the checkout root; <state> is its .git/fushi-dist.
#
#   native <state> <crate> <key> <plat> <peer checkout or ''> <build...>
#       Makes native/<crate>/prebuilt/<plat> the library set for <key>: this
#       checkout's copy for the key, else the peer slot's (DIST_NATIVE_PEER),
#       else <build...> builds it; then keeps a copy under the key.
#   native-restore <state> <crate> <key> <plat>
#       The first step alone: exit 0 when prebuilt/<plat> now holds <key>'s
#       set, 1 when this checkout has none (a Windows worker then lets
#       tool/native_libs.ps1 copy or build, and calls native-store).
#   native-store <state> <crate> <key> <plat>
#       prebuilt/<plat> now holds <key>'s libraries: keep a copy under the key
#       (none when native-restore already put this key's copy there).
#   warm <state> <key> <command...>
#       Runs <command> unless it already succeeded for <key> in this checkout.
#
# State under <state>:
#   native-<crate>.key       the key prebuilt/<plat> holds; removed before the
#                            directory changes, written once it is whole
#   native/<crate>/<key>/    a copy of prebuilt/<plat> as built for <key>
#   pub-warm/<key>           the warm-up ran for these dependencies
# Each cache keeps the KEEP most recently used keys (the mtime is the last
# use); older ones are removed.
#
# The steps run outside any `if` / `&&` (where `set -e` is off): a copy that
# fails stops the script instead of leaving the pointer on half a set.
set -euo pipefail

KEEP=${DIST_CACHE_KEEP:-3}

die() { echo "error: $*" >&2; exit 2; }

# A content key: a git object id, with `+<features>` for a feature build.
check_key() {
  printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{40,64}(\+[A-Za-z0-9_,]+)?$' ||
    die "bad key '$1'"
}

check_name() {
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_-]+$' || die "bad name '$1'"
}

nonempty() { [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]; }

# Replaces <dest> with a copy of <src> (mtimes kept: tool/native_libs.ps1's
# stamps check them); <dest> only appears once it is whole, a prepare killed
# halfway leaves a .tmp- directory, not half a library set.
copy_into() {
  local src=$1 dest=$2 tmp
  tmp="$(dirname "$dest")/.tmp-$(basename "$dest")"
  mkdir -p "$(dirname "$dest")"
  rm -rf "$tmp"
  cp -Rp "$src" "$tmp"
  rm -rf "$dest"
  mv "$tmp" "$dest"
}

# Keeps the KEEP most recently used entries of <dir> (keys: no spaces); every
# use touches its entry (copy_into keeps the source's mtime).
prune() {
  local dir=$1 n=0 e
  rm -rf "$dir"/.tmp-*
  for e in $(ls -1t "$dir"); do
    n=$((n + 1))
    [ "$n" -le "$KEEP" ] || rm -rf "${dir:?}/$e"
  done
}

# prebuilt/<plat> already holds <key>'s set.
in_place() {
  [ "$(cat "$pointer" 2>/dev/null || true)" = "$key" ] && nonempty "$out"
}

keep_in_place() {
  # Prepared before this cache existed: keep what is here under its key.
  if nonempty "$entry"; then
    touch "$entry"
  else
    copy_into "$out" "$entry"
    touch "$entry"
    prune "$cache"
  fi
  echo "==> native/$crate unchanged"
}

restore_entry() {
  copy_into "$entry" "$out"
  touch "$entry"
  echo "$key" > "$pointer"
  echo "==> native/$crate from this checkout's cache (${key:0:10})"
}

# Prints the peer slot's set for <key>: its cache entry, else what it has in
# place; nothing when it has neither.
peer_source() {
  local peer=$1
  [ -n "$peer" ] || return 0
  if nonempty "$peer/.git/fushi-dist/native/$crate/$key"; then
    echo "$peer/.git/fushi-dist/native/$crate/$key"
  elif [ "$(cat "$peer/.git/fushi-dist/native-$crate.key" 2>/dev/null || true)" = "$key" ] &&
       nonempty "$peer/$out"; then
    echo "$peer/$out"
  fi
}

native_store() {
  nonempty "$out" || die "$out is empty after the build"
  if in_place && nonempty "$entry"; then
    touch "$entry"
    return 0
  fi
  copy_into "$out" "$entry"
  touch "$entry"
  echo "$key" > "$pointer"
  prune "$cache"
}

verb=${1:-}
case "$verb" in
  native|native-restore|native-store)
    [ $# -ge 5 ] || die "usage: $verb <state> <crate> <key> <plat>"
    state=$2 crate=$3 key=$4 plat=$5
    check_name "$crate"
    check_key "$key"
    check_name "$plat"
    out="native/$crate/prebuilt/$plat"
    pointer="$state/native-$crate.key"
    cache="$state/native/$crate"
    entry="$cache/$key"
    ;;
  warm)
    [ $# -ge 4 ] || die "usage: warm <state> <key> <command...>"
    state=$2 key=$3
    check_key "$key"
    shift 3
    ;;
  *) die "usage: worker_cache.sh native|native-restore|native-store|warm ..." ;;
esac

case "$verb" in
  native|native-restore)
    if in_place; then
      keep_in_place
      exit 0
    fi
    # prebuilt/<plat> is about to change, whichever way.
    rm -f "$pointer"
    if nonempty "$entry"; then
      restore_entry
      exit 0
    fi
    [ "$verb" = native ] || exit 1
    [ $# -ge 7 ] || die "usage: native <state> <crate> <key> <plat> <peer> <build...>"
    src=$(peer_source "$6")
    shift 6
    if [ -n "$src" ]; then
      copy_into "$src" "$out"
      echo "==> copy native/$crate from $src"
    else
      "$@"
    fi
    native_store
    ;;
  native-store) native_store ;;
  warm)
    marks="$state/pub-warm"
    if [ -e "$marks/$key" ]; then
      touch "$marks/$key"
      echo "==> native-asset hooks already warm for these dependencies"
      exit 0
    fi
    "$@"
    mkdir -p "$marks"
    : > "$marks/$key"
    prune "$marks"
    ;;
esac
