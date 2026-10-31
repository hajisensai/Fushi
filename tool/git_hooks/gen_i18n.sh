#!/bin/sh
# Regenerates the untracked fushi/lib/i18n/strings.g.dart in the current
# worktree with fushi/tool/gen_i18n.dart (stamped: a hash and exit when
# nothing changed).
#
#   sh tool/git_hooks/gen_i18n.sh post-checkout <prev> <new> <branch-flag>
#   sh tool/git_hooks/gen_i18n.sh post-merge <squash-flag>
#   sh tool/git_hooks/gen_i18n.sh setup
#
# post-checkout / post-merge: called by the hook block tool/git_hooks/install.sh
# writes. A branch switch or merge deletes or outdates the generated file;
# this puts it back. git cannot undo a checkout or merge because of a hook,
# and a non-zero post-checkout only turns `git checkout` / `git worktree add`
# red after the fact, so here a failure is reported loudly and the hook exits
# 0 -- the hard gate is tool/heavy.dart, which regenerates (and fails on a
# failed generation) before every local analyze / test / build in fushi/.
#
# setup: tool/setup_worktree.ps1 -SkipBootstrap; a failed generation fails.
#
# Skipped, with a line saying why, when the workspace is not resolved yet (a
# fresh `git worktree add`: tool/setup_worktree.ps1 / bootstrap generates it
# after pub get) or the dependencies changed since the last pub get (`dart run
# slang` would resolve them itself, from the network, without the pub-cache
# patches -- run the bootstrap instead). Nothing to do on a ref that still
# tracks strings.g.dart (no fushi/tool/gen_i18n.dart).
kind=${1:-setup}
[ $# -gt 0 ] && shift
case "$kind" in
  post-checkout)
    # 3rd argument 0 = a file checkout (`git checkout -- <path>`): same branch.
    [ "${3:-1}" = 1 ] || exit 0
    ;;
  post-merge | setup) ;;
  *)
    echo "usage: sh tool/git_hooks/gen_i18n.sh post-checkout|post-merge|setup [hook args]" >&2
    exit 64
    ;;
esac

say() { echo "fushi gen-i18n ($kind): $*" >&2; }
hook_exit() { if [ "$kind" = setup ]; then exit "$1"; else exit 0; fi; }

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
gen="$root/fushi/tool/gen_i18n.dart"
[ -f "$gen" ] || exit 0
cfg="$root/.dart_tool/package_config.json"
if [ ! -f "$cfg" ]; then
  say "workspace not resolved yet (no .dart_tool/package_config.json); tool/setup_worktree.ps1 or tool/bootstrap.sh generates strings.g.dart after pub get"
  exit 0
fi
# A changed lockfile = new / different packages: `dart run slang` would fetch
# them itself (network, no pub-cache patches). A pubspec.yaml that only moved
# the +build number re-resolves offline from the lockfile, so it is not a stop.
if [ "$root/pubspec.lock" -nt "$cfg" ]; then
  say "pubspec.lock changed since the last pub get; run tool/setup_worktree.ps1 (or tool/bootstrap.sh) -- it resolves, patches and regenerates strings.g.dart"
  hook_exit 0
fi

# The SDK pub get used (flutterRoot), so the stamp's Dart version and the
# formatter match what analyze / test / build of this checkout run with.
sdk=$(sed -n 's|.*"flutterRoot": *"file://\([^"]*\)".*|\1|p' "$cfg" | head -n 1 |
  sed -e 's|%20| |g' -e 's|^/\([A-Za-z]:\)|\1|')
dart=
for candidate in "$sdk/bin/cache/dart-sdk/bin/dart.exe" "$sdk/bin/cache/dart-sdk/bin/dart"; do
  if [ -n "$sdk" ] && [ -f "$candidate" ]; then
    dart=$candidate
    break
  fi
done
if [ -z "$dart" ]; then
  say "no Dart SDK under flutterRoot '$sdk' of .dart_tool/package_config.json; strings.g.dart NOT regenerated -- run: dart fushi/tool/gen_i18n.dart"
  hook_exit 1
fi

"$dart" "$gen"
rc=$?
if [ "$rc" -ne 0 ]; then
  say "fushi/tool/gen_i18n.dart failed (exit $rc); strings.g.dart is missing or stale -- rerun: dart fushi/tool/gen_i18n.dart"
  hook_exit "$rc"
fi
exit 0
