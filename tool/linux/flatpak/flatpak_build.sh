#!/usr/bin/env bash
# Builds and publishes the Fushi Flatpak. Runs on a Linux host with flatpak and
# flatpak-builder: natively in CI (release-desktop.yml, flatpak-baseapp.yml), or
# inside the tool/linux/flatpak/Dockerfile container (build_flatpak.sh).
#
#   flatpak_build.sh baseapp-key
#       Print the cache key of the BaseApp (hash of its manifest + patches).
#   flatpak_build.sh baseapp <out-dir>
#       Build app.fushi.reader.BaseApp into <out-dir>/app.fushi.reader.BaseApp-<key>.flatpak.
#   flatpak_build.sh app <bundle-tarball> <branch> <version> <out-dir>
#       Build app.fushi.reader on <branch> (stable / beta / debug) from the Linux
#       bundle tarball: commits into <out-dir>/repo and writes
#       <out-dir>/fushi-<version>-linux-x86_64.flatpak. The BaseApp must be
#       installed (--user) first: `flatpak install --user <baseapp .flatpak>`.
#   flatpak_build.sh publish <new-repo> <site-dir> <repo-url>
#       Assemble the published repo in <site-dir>: mirror what <repo-url> serves
#       now (the published repo is its own state), add the new commits from
#       <new-repo>, sign, prune, and write the .flatpakrepo / .flatpakref files.
#
# Signing (app / publish): FLATPAK_GPG_KEY_ID + FLATPAK_GPG_HOMEDIR. Without a key
# the app is committed unsigned and the bundle carries no repo URL (local test
# builds); publish refuses to run unsigned. FLATPAK_REPO_URL (app) is the URL the
# bundle remembers as its origin, so installs from the .flatpak self-update.
# FLATPAK_BUILDER_JOBS / FLATPAK_STATE_DIR tune flatpak-builder.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ID=app.fushi.reader
BASE_ID=app.fushi.reader.BaseApp
BASE_BRANCH=49
FLATHUB=https://dl.flathub.org/repo/flathub.flatpakrepo
STATE_DIR="${FLATPAK_STATE_DIR:-$PWD/.flatpak-builder}"
JOBS="${FLATPAK_BUILDER_JOBS:-$(nproc)}"
# Published commits kept per branch besides the newest (rollback by
# `flatpak update --commit=`); older ones are pruned to bound the repo size.
PRUNE_DEPTH="${FLATPAK_PRUNE_DEPTH:-1}"

die() { echo "flatpak_build: $*" >&2; exit 1; }

gpg_args() {
  if [[ -n "${FLATPAK_GPG_KEY_ID:-}" ]]; then
    echo "--gpg-sign=$FLATPAK_GPG_KEY_ID"
    [[ -n "${FLATPAK_GPG_HOMEDIR:-}" ]] && echo "--gpg-homedir=$FLATPAK_GPG_HOMEDIR"
  fi
  return 0
}

# Local cache key of the BaseApp (build_flatpak.sh). CI names its copy through
# .github/actions/native-store-names (`flatpak` platform), which hashes the same
# inputs: baseapp/ and the Dockerfile the build runs in.
baseapp_key() {
  (cd "$HERE" && find baseapp Dockerfile -type f -print0 | sort -z | xargs -0 sha256sum) |
    sha256sum | cut -c1-16
}

ensure_flathub() {
  flatpak remote-add --user --if-not-exists flathub "$FLATHUB"
}

cmd_baseapp() {
  local out="$1" key work
  key="$(baseapp_key)"
  work="$(mktemp -d)"
  mkdir -p "$out"
  ensure_flathub
  cp -a "$HERE/baseapp/." "$work/"
  (cd "$work" && flatpak-builder --user --install-deps-from=flathub \
      --disable-rofiles-fuse --ccache --jobs="$JOBS" --state-dir="$STATE_DIR" \
      --repo="$work/repo" --force-clean "$work/build" app.fushi.reader.BaseApp.yml)
  flatpak build-bundle --runtime-repo="$FLATHUB" "$work/repo" \
    "$out/$BASE_ID-$key.flatpak" "$BASE_ID" "$BASE_BRANCH"
  ls -lh "$out/$BASE_ID-$key.flatpak"
}

cmd_app() {
  local tarball="$1" branch="$2" version="$3" out="$4" work sha
  case "$branch" in stable|beta|debug|master) ;; *) die "unknown branch $branch" ;; esac
  [[ -f "$tarball" ]] || die "no bundle tarball at $tarball"
  flatpak info --user "$BASE_ID//$BASE_BRANCH" >/dev/null 2>&1 \
    || die "$BASE_ID//$BASE_BRANCH is not installed (--user); install its .flatpak first"
  work="$(mktemp -d)"
  mkdir -p "$out"
  ensure_flathub
  cp "$HERE/app.fushi.reader.yml" "$HERE/app.fushi.reader.desktop" "$work/"
  cp "$tarball" "$work/fushi-linux-x64.tar.gz"
  # flatpak-builder keys its module cache on the manifest, not on a local file's
  # contents: pin the tarball's hash so a rebuilt bundle is never silently reused.
  sha="$(sha256sum "$tarball" | cut -d' ' -f1)"
  sed -i -E "s|^( *)path: fushi-linux-x64\.tar\.gz$|&\n\1sha256: $sha|" "$work/app.fushi.reader.yml"
  grep -q "sha256: $sha" "$work/app.fushi.reader.yml" || die "could not pin the bundle hash"

  local -a sign=()
  mapfile -t sign < <(gpg_args)
  (cd "$work" && flatpak-builder --user --install-deps-from=flathub \
      --disable-rofiles-fuse --jobs="$JOBS" --state-dir="$STATE_DIR" \
      --default-branch="$branch" --repo="$out/repo" "${sign[@]}" \
      --force-clean "$work/build" app.fushi.reader.yml)

  local -a origin=()
  if [[ -n "${FLATPAK_GPG_KEY_ID:-}" && -n "${FLATPAK_REPO_URL:-}" ]]; then
    gpg --homedir="${FLATPAK_GPG_HOMEDIR:-$HOME/.gnupg}" --export "$FLATPAK_GPG_KEY_ID" > "$work/key.gpg"
    # The installed bundle remembers this repo as its origin (`flatpak update`
    # and the in-app updater pull from it) and trusts this key for it.
    origin=(--repo-url="$FLATPAK_REPO_URL" --gpg-keys="$work/key.gpg" "${sign[@]}")
  fi
  flatpak build-bundle --runtime-repo="$FLATHUB" "${origin[@]}" "$out/repo" \
    "$out/fushi-$version-linux-x86_64.flatpak" "$APP_ID" "$branch"
  ls -lh "$out/fushi-$version-linux-x86_64.flatpak"
}

cmd_publish() {
  local new_repo="$1" site="$2" url="$3" repo ref
  [[ -n "${FLATPAK_GPG_KEY_ID:-}" ]] || die "publish needs FLATPAK_GPG_KEY_ID: an unsigned repo cannot be trusted by clients"
  [[ -d "$new_repo/objects" ]] || die "no OSTree repo at $new_repo"
  url="${url%/}"
  repo="$site/repo"
  mkdir -p "$site"
  ostree --repo="$repo" init --mode=archive-z2
  # The live repo is the only state: mirror its branches (newest commit plus
  # PRUNE_DEPTH parents) so branches this run did not build survive the deploy.
  if curl -fsSL -o /dev/null "$url/repo/summary"; then
    ostree --repo="$repo" remote add --if-not-exists --no-gpg-verify live "$url/repo"
    ostree --repo="$repo" pull --mirror --depth="$PRUNE_DEPTH" live
    ostree --repo="$repo" remote delete live
  else
    echo "flatpak_build: nothing published at $url yet, starting a new repo"
  fi
  local -a sign=()
  mapfile -t sign < <(gpg_args)
  # Commits were signed when the app step committed them; pull-local carries
  # the detached signatures along.
  for ref in $(ostree --repo="$new_repo" refs | grep "^app/$APP_ID/"); do
    ostree --repo="$repo" pull-local "$new_repo" "$ref"
  done
  flatpak build-update-repo "${sign[@]}" --prune --prune-depth="$PRUNE_DEPTH" \
    --title="Fushi" --default-branch=stable "$repo"

  local key
  key="$(gpg --homedir="${FLATPAK_GPG_HOMEDIR:-$HOME/.gnupg}" --export "$FLATPAK_GPG_KEY_ID" | base64 -w0)"
  cat > "$site/fushi.flatpakrepo" <<EOF
[Flatpak Repo]
Title=Fushi
Url=$url/repo/
Homepage=https://github.com/hajisensai/Fushi
Comment=Official Fushi Flatpak builds
DefaultBranch=stable
RuntimeRepo=$FLATHUB
GPGKey=$key
EOF
  local branch
  for branch in stable beta debug; do
    cat > "$site/$APP_ID.$branch.flatpakref" <<EOF
[Flatpak Ref]
Name=$APP_ID
Branch=$branch
Title=Fushi ($branch)
Url=$url/repo/
SuggestRemoteName=fushi
RuntimeRepo=$FLATHUB
IsRuntime=false
GPGKey=$key
EOF
  done
  cp "$site/$APP_ID.stable.flatpakref" "$site/$APP_ID.flatpakref"
  cat > "$site/index.html" <<EOF
<!doctype html><meta charset="utf-8"><title>Fushi Flatpak</title>
<h1>Fushi Flatpak repository</h1>
<p>Install: <code>flatpak install --user $url/$APP_ID.flatpakref</code></p>
<p>Branches: stable (<a href="$APP_ID.stable.flatpakref">ref</a>),
beta (<a href="$APP_ID.beta.flatpakref">ref</a>),
debug (<a href="$APP_ID.debug.flatpakref">ref</a>).
Repo file: <a href="fushi.flatpakrepo">fushi.flatpakrepo</a>.</p>
EOF
  # GitHub Pages runs Jekyll unless told not to, which hides some repo files.
  touch "$site/.nojekyll"
  ostree --repo="$repo" refs
  du -sh "$repo"
}

case "${1:-}" in
  baseapp-key) baseapp_key ;;
  baseapp) [[ $# -eq 2 ]] || die "usage: baseapp <out-dir>"; cmd_baseapp "$2" ;;
  app) [[ $# -eq 5 ]] || die "usage: app <bundle-tarball> <branch> <version> <out-dir>"; cmd_app "$2" "$3" "$4" "$5" ;;
  publish) [[ $# -eq 4 ]] || die "usage: publish <new-repo> <site-dir> <repo-url>"; cmd_publish "$2" "$3" "$4" ;;
  *) die "usage: flatpak_build.sh baseapp-key | baseapp <out> | app <tarball> <branch> <version> <out> | publish <new-repo> <site> <url>" ;;
esac
