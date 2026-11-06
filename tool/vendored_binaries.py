#!/usr/bin/env python3
"""Prebuilt third-party binaries that live in a GitHub release, not in git.

The binaries (libmpv / ANGLE / libplacebo / FFmpegKit / LunaHook / jogamp ...)
used to be committed, and every rebuild added tens of MB to history. They are
now gitignored at their original paths; tool/vendored_binaries.json records
path + sha256 + size + download URL for each one, and this tool puts the exact
bytes back where the consumers (CMake MD5 checks, Gradle, podspecs, Makefiles,
galgame / Mihon scripts, unit tests) already look for them.

Standard library only: it runs on every GitHub runner (Windows / Linux /
macOS), the dist_test workers and a dev box before Flutter is installed.

  python3 tool/vendored_binaries.py fetch [--group G ...]
      Make every selected file match the manifest. Files that already match
      cost one sha256 pass; anything missing or different is taken from the
      local cache or downloaded (HTTPS_PROXY / HTTP_PROXY are honoured),
      verified, and written atomically. Any size / sha256 mismatch fails the
      run. Default: all groups.

  python3 tool/vendored_binaries.py check [--group G ...]
      Like fetch, but never writes: exit 1 when a file is missing / different.

  python3 tool/vendored_binaries.py register --group G PATH ...
      Bumping a binary: record (or update) PATH's sha256 / size / URL from
      the file on disk. Then `publish` uploads it.

  python3 tool/vendored_binaries.py publish
      Upload every manifest file that the release does not have yet (gh CLI),
      then download each new asset back and compare its sha256.

  python3 tool/vendored_binaries.py identity PREFIX ...
      Print "path sha256" for the entries under PREFIX (used by
      .github/actions/native-store-names/names.sh, whose git tree hash can no
      longer see these bytes).

Cache: downloads are kept content-addressed in $FUSHI_VENDORED_CACHE (default
~/.cache/fushi/vendored-binaries, %LOCALAPPDATA%\\fushi\\vendored-binaries on
Windows), so every worktree / CI cache restore reuses them.

The cache is shared by every process on the machine (parallel worktree
bootstraps, the dist_test worker slots), so each cached file <sha256> is
guarded by an OS file lock on <sha256>.lock (fcntl.flock / msvcrt.locking,
released by the OS if the holder dies, so a crash never leaves a stale lock).
Under that lock a writer downloads to a unique temp file and os.replace()s it
into place, and a reader copies it out; nobody reads a file another process is
replacing (on Windows that os.replace / copy pair fails with a sharing
violation). A waiter gives up loudly after LOCK_TIMEOUT_SECONDS.

Network: only transport failures (connection errors, timeouts, truncated
bodies, HTTP 5xx) of the external CDN are retried, DOWNLOAD_ATTEMPTS times in
all, and each retry is logged. Bytes that arrive but do not match the manifest
(size / sha256) and HTTP 4xx are never retried: a wrong asset fails at once.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import hashlib
import http.client
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import BinaryIO, Iterable, Iterator, Optional

ROOT: Path = Path(__file__).resolve().parent.parent
MANIFEST: Path = ROOT / "tool" / "vendored_binaries.json"
CHUNK: int = 1 << 20
# Transport-level failures only (connection reset, 5xx, timeout). A response
# whose bytes do not match the manifest is never retried: that is a wrong or
# corrupted asset and must fail loudly.
DOWNLOAD_ATTEMPTS: int = 3
# Backoff before retry N is RETRY_BACKOFF_SECONDS * N.
RETRY_BACKOFF_SECONDS: float = 2.0
# How long a process waits for another one holding a cache entry's lock (that
# one is downloading or copying the same file). Long enough for a slow proxy to
# finish a 40 MB asset with all its retries; past it the run fails, naming the
# lock file, instead of waiting forever.
LOCK_TIMEOUT_SECONDS: float = 1800.0
LOCK_POLL_SECONDS: float = 0.2


class VendoredError(Exception):
    pass


class _TransportError(Exception):
    """A retryable network failure (never a content mismatch)."""


def log(message: str) -> None:
    print(message, flush=True)


def load_manifest() -> dict:
    with MANIFEST.open("r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    seen_paths: set[str] = set()
    seen_assets: dict[str, str] = {}
    for entry in manifest["files"]:
        for key in ("path", "group", "sha256", "size", "url"):
            if key not in entry:
                raise VendoredError(f"manifest entry {entry!r} lacks '{key}'")
        if entry["path"] in seen_paths:
            raise VendoredError(f"manifest lists {entry['path']} twice")
        asset = entry["url"].rsplit("/", 1)[-1]
        if seen_assets.setdefault(asset, entry["sha256"]) != entry["sha256"]:
            raise VendoredError(f"manifest asset name {asset} names two different files")
        seen_paths.add(entry["path"])
    return manifest


def save_manifest(manifest: dict) -> None:
    manifest["files"].sort(key=lambda entry: entry["path"])
    lines = ["{"]
    for key in ("_comment", "repo", "tag"):
        lines.append(f"  {json.dumps(key)}: {json.dumps(manifest[key], ensure_ascii=False)},")
    lines.append('  "files": [')
    rows = []
    for entry in manifest["files"]:
        ordered = {k: entry[k] for k in ("path", "group", "size", "sha256", "url")}
        rows.append("    " + json.dumps(ordered, ensure_ascii=False))
    lines.append(",\n".join(rows))
    lines.append("  ]")
    lines.append("}")
    data = ("\n".join(lines) + "\n").encode("utf-8")
    tmp = MANIFEST.with_suffix(".json.tmp")
    tmp.write_bytes(data)
    os.replace(tmp, MANIFEST)


def asset_name(path: str, sha256: str) -> str:
    # Content-addressed: paths that share a basename (full-*.jar, the
    # xcframework slices) get different names because their bytes differ, and
    # every version of one path keeps its own asset, so an old commit's
    # manifest still resolves to the bytes it was built with.
    return f"{sha256[:16]}-{path.rsplit('/', 1)[-1]}"


def asset_url(manifest: dict, path: str, sha256: str) -> str:
    return (
        f"https://github.com/{manifest['repo']}/releases/download/"
        f"{manifest['tag']}/{asset_name(path, sha256)}"
    )


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(CHUNK)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def matches(path: Path, entry: dict) -> bool:
    try:
        if not path.is_file() or path.stat().st_size != entry["size"]:
            return False
    except OSError:
        return False
    return sha256_of(path) == entry["sha256"]


def cache_dir() -> Path:
    configured = os.environ.get("FUSHI_VENDORED_CACHE")
    if configured:
        return Path(configured)
    if os.name == "nt" and os.environ.get("LOCALAPPDATA"):
        return Path(os.environ["LOCALAPPDATA"]) / "fushi" / "vendored-binaries"
    return Path.home() / ".cache" / "fushi" / "vendored-binaries"


def select(manifest: dict, groups: Optional[list[str]]) -> list[dict]:
    known = sorted({entry["group"] for entry in manifest["files"]})
    if not groups or groups == ["all"]:
        return list(manifest["files"])
    unknown = [group for group in groups if group not in known]
    if unknown:
        raise VendoredError(f"unknown group(s) {unknown}; known: {known}")
    return [entry for entry in manifest["files"] if entry["group"] in groups]


def _transfer(url: str, handle: BinaryIO) -> tuple[int, str]:
    """One GET of url into handle; returns (bytes, sha256).

    Raises _TransportError for what a retry can fix (connection / timeout /
    truncated body / HTTP 5xx) and VendoredError for HTTP 4xx. A failure to
    write the local file is an OSError from handle.write and propagates as is:
    retrying cannot fix a full disk.
    """
    digest = hashlib.sha256()
    written = 0
    request = urllib.request.Request(url, headers={"User-Agent": "fushi-vendored-binaries"})
    try:
        # urllib's default opener honours HTTPS_PROXY / HTTP_PROXY / NO_PROXY.
        response = urllib.request.urlopen(request, timeout=120)
    except urllib.error.HTTPError as error:
        if error.code < 500:
            raise VendoredError(f"{url}: HTTP {error.code} {error.reason}") from error
        raise _TransportError(f"HTTP {error.code} {error.reason}") from error
    except (urllib.error.URLError, http.client.HTTPException, OSError) as error:
        raise _TransportError(str(error)) from error
    declared = response.headers.get("Content-Length")
    with response:
        while True:
            try:
                chunk = response.read(CHUNK)
            except (http.client.HTTPException, OSError) as error:
                # IncompleteRead (HTTPException), reset / timeout (OSError).
                raise _TransportError(f"after {written} bytes: {error!r}") from error
            if not chunk:
                break
            handle.write(chunk)
            digest.update(chunk)
            written += len(chunk)
    # read(amt) does not raise IncompleteRead when the peer closes early: it
    # just returns b"". A body shorter than its own Content-Length is a dropped
    # connection (retry), not a wrong asset.
    if declared is not None and declared.isdigit() and written < int(declared):
        raise _TransportError(f"connection closed after {written} of {declared} bytes")
    return written, digest.hexdigest()


def download(url: str, destination: Path, entry: dict) -> None:
    """Download url to destination, verifying size and sha256 on the fly.

    Retries transport failures only (see _transfer), logging each one; a body
    that arrives complete but differs from the manifest fails immediately.
    """
    last_error: Optional[_TransportError] = None
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        with destination.open("wb") as handle:
            try:
                written, sha256 = _transfer(url, handle)
            except _TransportError as error:
                last_error = error
            else:
                if written != entry["size"] or sha256 != entry["sha256"]:
                    raise VendoredError(
                        f"{url} does not match the manifest for {entry['path']}: "
                        f"got {written} bytes sha256={sha256}, "
                        f"expected {entry['size']} bytes sha256={entry['sha256']} "
                        "(not retried: a wrong or corrupted asset)"
                    )
                return
        if attempt < DOWNLOAD_ATTEMPTS:
            delay = RETRY_BACKOFF_SECONDS * attempt
            log(
                f"    {entry['path']}: download attempt {attempt}/{DOWNLOAD_ATTEMPTS} "
                f"failed ({last_error}); retrying in {delay:.0f}s"
            )
            time.sleep(delay)
        else:
            log(
                f"    {entry['path']}: download attempt {attempt}/{DOWNLOAD_ATTEMPTS} "
                f"failed ({last_error}); giving up"
            )
    raise VendoredError(f"{url}: download failed after {DOWNLOAD_ATTEMPTS} attempts: {last_error}")


def _try_lock(fd: int) -> bool:
    """Non-blocking exclusive lock on byte 0 of fd; False when another holder has it."""
    if os.name == "nt":
        import msvcrt

        os.lseek(fd, 0, os.SEEK_SET)
        try:
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
        except OSError:
            return False
        return True
    import fcntl

    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    return True


def _unlock(fd: int) -> None:
    if os.name == "nt":
        import msvcrt

        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
    else:
        import fcntl

        fcntl.flock(fd, fcntl.LOCK_UN)


@contextlib.contextmanager
def cache_lock(cache: Path, sha256: str, timeout: Optional[float] = None) -> Iterator[None]:
    """Hold the cross-process lock of cache entry <sha256> (see the module doc).

    The lock file itself is never deleted: removing it while another process
    waits on it would let two holders lock two different files.
    """
    limit = LOCK_TIMEOUT_SECONDS if timeout is None else timeout
    cache.mkdir(parents=True, exist_ok=True)
    lock_path = cache / f"{sha256}.lock"
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o666)
    try:
        deadline = time.monotonic() + limit
        waited = False
        while not _try_lock(fd):
            if not waited:
                log(f"  waiting for {lock_path} (another process is fetching the same file)")
                waited = True
            if time.monotonic() >= deadline:
                raise VendoredError(
                    f"timed out after {limit:.0f}s waiting for the cache lock {lock_path}; "
                    "another fetch holds it (stuck download?). Stop that process and re-run; "
                    "the OS releases the lock when its holder exits."
                )
            time.sleep(LOCK_POLL_SECONDS)
        try:
            yield
        finally:
            _unlock(fd)
    finally:
        os.close(fd)


def _unique_sibling(path: Path, suffix: str) -> Path:
    with tempfile.NamedTemporaryFile(
        dir=path.parent, prefix=path.name + ".", suffix=suffix, delete=False
    ) as handle:
        return Path(handle.name)


def materialize(entry: dict, cache: Path) -> str:
    target = ROOT / entry["path"]
    # Two fetches into the same checkout (bootstrap + melos post hook, two dist
    # slots on one worktree) must not hash `target` while the other replaces it
    # (PermissionError on Windows): serialize per target path. Lock order is
    # always target -> cache entry, so the two locks cannot deadlock.
    target_key = "target-" + hashlib.sha256(str(target.resolve()).lower().encode("utf-8")).hexdigest()
    with cache_lock(cache, target_key):
        return _materialize_locked(entry, cache, target)


def _materialize_locked(entry: dict, cache: Path, target: Path) -> str:
    if matches(target, entry):
        return "ok"
    action = "replaced" if target.exists() else "fetched"
    if target.exists():
        log(f"  {entry['path']}: local file differs from the manifest; replacing it")
    cached = cache / entry["sha256"]
    target.parent.mkdir(parents=True, exist_ok=True)
    # Unique per process / thread: two fetches into the same checkout (bootstrap
    # + melos post hook) must not share a staging file either.
    staging = _unique_sibling(target, ".vendored-part")
    try:
        with cache_lock(cache, entry["sha256"]):
            if matches(cached, entry):
                action += " from cache"
            else:
                part_path = _unique_sibling(cached, ".part")
                try:
                    log(f"  downloading {entry['path']} ({entry['size'] / 1048576:.1f} MiB)")
                    download(entry["url"], part_path, entry)
                    os.replace(part_path, cached)
                finally:
                    if part_path.exists():
                        part_path.unlink()
            # Still under the lock: no other process can os.replace `cached`
            # while it is being read.
            shutil.copyfile(cached, staging)
        if not matches(staging, entry):
            raise VendoredError(f"{entry['path']}: copy from {cached} does not match the manifest")
        os.replace(staging, target)
    finally:
        if staging.exists():
            staging.unlink()
    return action


def command_fetch(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    entries = select(manifest, args.group)
    cache = Path(args.cache_dir) if args.cache_dir else cache_dir()
    started = time.monotonic()
    failures: list[str] = []
    counts: dict[str, int] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = {pool.submit(materialize, entry, cache): entry for entry in entries}
        for future in concurrent.futures.as_completed(futures):
            entry = futures[future]
            try:
                result = future.result()
            except Exception as error:  # reported below, then the run fails
                failures.append(f"{entry['path']}: {error}")
                continue
            counts[result] = counts.get(result, 0) + 1
            if result != "ok":
                log(f"  {result}: {entry['path']}")
    summary = ", ".join(f"{count} {name}" for name, count in sorted(counts.items()))
    log(
        f"vendored binaries: {len(entries)} file(s) [{summary or 'none'}] "
        f"in {time.monotonic() - started:.1f}s (cache {cache})"
    )
    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 1
    return 0


def command_check(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    bad = [entry["path"] for entry in select(manifest, args.group) if not matches(ROOT / entry["path"], entry)]
    for path in bad:
        print(f"missing or different: {path}", file=sys.stderr)
    if bad:
        print("run: python3 tool/vendored_binaries.py fetch", file=sys.stderr)
        return 1
    log("vendored binaries: all present and matching")
    return 0


def normalized(path: str) -> str:
    absolute = (Path.cwd() / path).resolve()
    try:
        return absolute.relative_to(ROOT).as_posix()
    except ValueError as error:
        raise VendoredError(f"{path} is outside the repository") from error


def command_register(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    by_path = {entry["path"]: entry for entry in manifest["files"]}
    for raw in args.paths:
        path = normalized(raw)
        file = ROOT / path
        if not file.is_file():
            raise VendoredError(f"{path} does not exist")
        digest = sha256_of(file)
        entry = {
            "path": path,
            "group": args.group,
            "size": file.stat().st_size,
            "sha256": digest,
            "url": asset_url(manifest, path, digest),
        }
        previous = by_path.get(path)
        if previous is None:
            manifest["files"].append(entry)
        else:
            previous.update(entry)
        log(f"registered {path} ({entry['size']} bytes, {digest})")
    save_manifest(manifest)
    log("next: python3 tool/vendored_binaries.py publish; add each new path to .gitignore")
    return 0


def gh(*arguments: str) -> str:
    completed = subprocess.run(
        ["gh", *arguments], capture_output=True, text=True, encoding="utf-8"
    )
    if completed.returncode != 0:
        raise VendoredError(
            f"gh {' '.join(arguments[:3])} failed ({completed.returncode}): "
            f"{completed.stderr.strip()}"
        )
    return completed.stdout


def command_publish(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    repo, tag = manifest["repo"], manifest["tag"]
    release = json.loads(gh("release", "view", tag, "--repo", repo, "--json", "assets"))
    existing = {asset["name"] for asset in release["assets"]}
    pending_by_asset: dict[str, dict] = {}
    for entry in manifest["files"]:
        name = entry["url"].rsplit("/", 1)[-1]
        if name not in existing:
            pending_by_asset.setdefault(name, entry)
    pending = list(pending_by_asset.values())
    for entry in manifest["files"]:
        if entry["url"] != asset_url(manifest, entry["path"], entry["sha256"]):
            raise VendoredError(f"{entry['path']}: url does not follow the asset naming rule")
    if not pending:
        log(f"release {tag} already has all {len(manifest['files'])} asset(s)")
        return 0
    with tempfile.TemporaryDirectory(prefix="fushi-vendored-publish-") as staging_root:
        staging = Path(staging_root)
        staged: list[str] = []
        for entry in pending:
            source = ROOT / entry["path"]
            if not matches(source, entry):
                raise VendoredError(f"{entry['path']}: local file does not match the manifest; register it first")
            name = entry["url"].rsplit("/", 1)[-1]
            shutil.copyfile(source, staging / name)
            staged.append(str(staging / name))
        for batch in range(0, len(staged), 10):
            chunk = staged[batch : batch + 10]
            log(f"uploading {len(chunk)} asset(s) to {repo}@{tag}")
            gh("release", "upload", tag, *chunk, "--repo", repo)
    with tempfile.TemporaryDirectory(prefix="fushi-vendored-verify-") as verify_root:
        for entry in pending:
            probe = Path(verify_root) / entry["sha256"]
            download(entry["url"], probe, entry)
            log(f"verified download of {entry['path']}")
            probe.unlink()
    return 0


def command_identity(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    prefixes = [prefix.rstrip("/") + "/" for prefix in args.prefixes]
    lines = [
        f"{entry['path']} {entry['sha256']}\n"
        for entry in manifest["files"]
        if any(entry["path"].startswith(prefix) for prefix in prefixes)
    ]
    # Bytes, not print(): text-mode stdout on Windows writes CRLF, and names.sh
    # hashes this listing into native artifact store names, which must be the
    # same on every runner OS.
    sys.stdout.flush()
    sys.stdout.buffer.write("".join(lines).encode("utf-8"))
    sys.stdout.buffer.flush()
    return 0


def parse(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")
    for name in ("fetch", "check"):
        command = sub.add_parser(name)
        command.add_argument("--group", action="append", help="limit to a group (repeatable; default all)")
        if name == "fetch":
            command.add_argument("--cache-dir", help="override $FUSHI_VENDORED_CACHE")
    register = sub.add_parser("register")
    register.add_argument("--group", required=True)
    register.add_argument("paths", nargs="+")
    sub.add_parser("publish")
    identity = sub.add_parser("identity")
    identity.add_argument("prefixes", nargs="+")
    arguments = list(argv)
    args = parser.parse_args(arguments)
    if args.command is None:
        args = parser.parse_args(["fetch", *arguments])
    return args


def main(argv: Iterable[str]) -> int:
    args = parse(argv)
    handlers = {
        "fetch": command_fetch,
        "check": command_check,
        "register": command_register,
        "publish": command_publish,
        "identity": command_identity,
    }
    try:
        return handlers[args.command](args)
    except VendoredError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
