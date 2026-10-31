#!/bin/sh
# Installs (or refreshes) the fushi gen-i18n block in the repository's
# post-checkout and post-merge hooks, so a branch switch or merge regenerates
# the untracked fushi/lib/i18n/strings.g.dart (tool/git_hooks/gen_i18n.sh).
#
#   sh tool/git_hooks/install.sh        (tool/setup_worktree.ps1 / bootstrap.sh run it)
#
# The hooks directory is `git rev-parse --git-path hooks`: the common git dir
# shared by the main checkout and every worktree, or core.hooksPath when one is
# set. Existing hooks are kept: the block sits between marker lines right
# after the shebang (so an `exit` further down cannot skip it), is replaced in
# place on a re-run and never touches the lines outside it. A hook that is not
# a sh / bash script is left alone with a warning. The block only calls the
# tracked script when the checked-out tree has it (older refs have none).
set -eu

hooks=$(git rev-parse --path-format=absolute --git-path hooks)
mkdir -p "$hooks"
begin='# >>> fushi gen-i18n (tool/git_hooks/install.sh rewrites this block) >>>'
end='# <<< fushi gen-i18n <<<'

for name in post-checkout post-merge; do
  f="$hooks/$name"
  block=$(cat <<EOF
$begin
_fushi_gen_i18n="\$(git rev-parse --show-toplevel 2>/dev/null)/tool/git_hooks/gen_i18n.sh"
if [ -f "\$_fushi_gen_i18n" ]; then
  sh "\$_fushi_gen_i18n" $name "\$@"
fi
$end
EOF
)
  if [ ! -f "$f" ]; then
    printf '#!/bin/sh\n%s\n' "$block" > "$f"
    chmod +x "$f"
    echo "OK $f: created with the fushi gen-i18n block"
    continue
  fi
  first=$(head -n 1 "$f")
  case "$first" in
    '#!'*/sh | '#!'*/sh' '* | '#!'*/bash | '#!'*/bash' '* | '#!'*'env sh'* | '#!'*'env bash'*) ;;
    *)
      echo "WARN $f is not a sh / bash script ('$first'); not adding the fushi gen-i18n block -- call 'sh tool/git_hooks/gen_i18n.sh $name \"\$@\"' from it yourself" >&2
      continue
      ;;
  esac
  tmp="$f.fushi-tmp.$$"
  {
    echo "$first"
    echo "$block"
    tail -n +2 "$f" | awk -v b="$begin" -v e="$end" '
      $0 == b { skip = 1; next }
      skip && $0 == e { skip = 0; next }
      !skip { print }
    '
  } > "$tmp"
  if cmp -s "$tmp" "$f"; then
    rm -f "$tmp"
    echo "OK $f: fushi gen-i18n block up to date"
  else
    cat "$tmp" > "$f"
    rm -f "$tmp"
    chmod +x "$f"
    echo "OK $f: fushi gen-i18n block written (other lines kept)"
  fi
done
