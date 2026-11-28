#!/usr/bin/env python3
"""Native library registry (native/crates.json): the one reader and the one source-key implementation.

Every script that needs "which native libraries exist / which ones a platform needs / which source tree
an artifact was built from" calls this file instead of keeping its own list:

  tool/native_libs.ps1                 list --host-test / --android-local, key --require-clean
  tool/bootstrap.sh                    list --host-test
  fushi/tool/dist_test/worker_*.sh     list ..., key
  .github/actions/native-store-names   paths, tree-key (artifact store names)
  fushi/macos/bundle_native_libs.sh    bundle macos
  fushi/ios/check_native_libs.sh       ios-checks

Commands (cwd anywhere inside the repo):

  list [--host-test] [--android-local] [--ios-umbrella] [--platform P [--bundled-by B] [--required R]]
      crate names, one per line, registry order.
  get <crate> <field[.field...]>
      one registry value (strings raw, lists one item per line, everything else JSON).
  paths <crate>
      the committed inputs the crate's artifact is built from: its directory, its external_sources,
      key_extra_inputs, and for an aggregate (the iOS umbrella) every member's paths.
  key <crate> [--require-clean] [--features]
      source key of the crate = tree-key over `paths <crate>`. --features appends `+<test_features>`
      (the host test library is built with them). --require-clean: exit 3 without output when any of
      the paths has uncommitted changes (the artifact's source cannot be named).
  tree-key <path>...
      sha256 over `git ls-tree -r --full-tree HEAD -- <path>...` minus Markdown blobs. Fails when a
      path matches nothing (a renamed directory must not turn a key into a constant).
  bundle <platform>
      `<name>\\t<artifact>\\t<required>\\t<build script>` for every crate the app wiring bundles on <platform>.
  ios-checks
      `<name>\\t<abi_symbol>` for every umbrella member iOS requires (`required: always` with a symbol).
  check
      validate the registry against the tree (exit 1 with one line per problem).

Source key: the same function for the local stamps (native_libs.ps1), the dist workers and the CI
artifact store (names.sh folds runner identity on top of it). Markdown is left out: no build reads a
.md, and a README edit used to cold-rebuild every platform. tool/native_crates_test.py pins it.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence

REQUIRED_MODES = ("always", "release", "optional")
PLATFORMS = ("windows", "linux", "macos", "android", "ios")
LANGUAGES = ("rust", "cpp", "c")
# The ABIs a platform entry without its own `abis` builds (same as split-per-abi release APKs).
DEFAULT_ANDROID_ABIS = ("arm64-v8a", "armeabi-v7a", "x86_64")


class RegistryError(Exception):
    """The registry or a key input is unusable; the message is shown as is."""


@dataclass(frozen=True)
class PlatformEntry:
    artifact: Optional[str]
    required: str
    bundled_by: Optional[str]
    fallback: Optional[str]
    via: Optional[str]
    abis: Sequence[str]


@dataclass(frozen=True)
class Crate:
    name: str
    language: str
    dart_package: Optional[str]
    abi_symbol: Optional[str]
    host_test_lib: bool
    test_features: str
    id_audit: bool
    aggregate: Optional[str]
    external_sources: Sequence[str]
    key_extra_inputs: Sequence[str]
    toolchain_file: Optional[str]
    build: Dict[str, str]
    platforms: Dict[str, PlatformEntry] = field(default_factory=dict)

    @property
    def dir(self) -> str:
        return f"native/{self.name}"


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def _platform_entry(crate: str, platform: str, raw: dict) -> PlatformEntry:
    required = raw.get("required")
    if required not in REQUIRED_MODES:
        raise RegistryError(f"{crate}.platforms.{platform}.required must be one of {REQUIRED_MODES}, got {required!r}")
    fallback = raw.get("fallback")
    if required == "optional" and not fallback:
        raise RegistryError(f"{crate}.platforms.{platform}: required=optional needs a `fallback` (what degrades)")
    if required != "optional" and fallback:
        raise RegistryError(f"{crate}.platforms.{platform}: `fallback` only makes sense for required=optional")
    abis = raw.get("abis", list(DEFAULT_ANDROID_ABIS) if platform == "android" else [])
    return PlatformEntry(
        artifact=raw.get("artifact"),
        required=required,
        bundled_by=raw.get("bundled_by"),
        fallback=fallback,
        via=raw.get("via"),
        abis=tuple(abis),
    )


def load(root: Optional[Path] = None) -> List[Crate]:
    path = (root or repo_root()) / "native" / "crates.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema") != 1:
        raise RegistryError(f"{path}: unsupported schema {data.get('schema')!r}")
    crates: List[Crate] = []
    seen = set()
    for raw in data["crates"]:
        name = raw["name"]
        if name in seen:
            raise RegistryError(f"duplicate crate {name}")
        seen.add(name)
        if raw.get("language") not in LANGUAGES:
            raise RegistryError(f"{name}.language must be one of {LANGUAGES}")
        platforms = {}
        for platform, entry in raw.get("platforms", {}).items():
            if platform not in PLATFORMS:
                raise RegistryError(f"{name}.platforms: unknown platform {platform!r}")
            platforms[platform] = _platform_entry(name, platform, entry)
        crates.append(
            Crate(
                name=name,
                language=raw["language"],
                dart_package=raw.get("dart_package"),
                abi_symbol=raw.get("abi_symbol"),
                host_test_lib=bool(raw.get("host_test_lib", False)),
                test_features=raw.get("test_features", ""),
                id_audit=bool(raw.get("id_audit", False)),
                aggregate=raw.get("aggregate"),
                external_sources=tuple(raw.get("external_sources", [])),
                key_extra_inputs=tuple(raw.get("key_extra_inputs", [])),
                toolchain_file=raw.get("toolchain_file"),
                build=dict(raw.get("build", {})),
                platforms=platforms,
            )
        )
    return crates


def by_name(crates: Sequence[Crate], name: str) -> Crate:
    for crate in crates:
        if crate.name == name:
            return crate
    raise RegistryError(f"unknown crate {name!r} (native/crates.json)")


def aggregate_members(crates: Sequence[Crate], aggregate: Crate) -> List[Crate]:
    """Crates linked into an aggregate library (the iOS umbrella: platforms.ios.via == its name)."""
    return [
        c
        for c in crates
        if aggregate.aggregate in c.platforms and c.platforms[aggregate.aggregate].via == aggregate.name
    ]


def source_paths(crates: Sequence[Crate], crate: Crate) -> List[str]:
    paths: List[str] = [crate.dir, *crate.external_sources, *crate.key_extra_inputs]
    if crate.aggregate:
        for member in aggregate_members(crates, crate):
            paths.extend(source_paths(crates, member))
    unique: List[str] = []
    for p in paths:
        if p not in unique:
            unique.append(p)
    return unique


def _git(root: Path, *args: str) -> bytes:
    proc = subprocess.run(["git", "-C", str(root), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise RegistryError(f"git {' '.join(args)} failed: {proc.stderr.decode('utf-8', 'replace').strip()}")
    return proc.stdout


def tree_key(root: Path, paths: Sequence[str], strict: bool) -> str:
    """sha256 over the committed, non-Markdown blobs under `paths`.

    strict: every path must contribute (crate inputs: a renamed / typo'd path fails). Otherwise only the
    whole set must (names.sh non-crate inputs such as third_party/mihon_build, whose binaries are vendored
    and enter the name through vendored_identity, so only its README is committed).
    """
    if not paths:
        raise RegistryError("tree-key needs at least one path")
    listing = _git(root, "ls-tree", "-r", "--full-tree", "HEAD", "--", *paths)
    lines = [line for line in listing.split(b"\n") if line and not line.lower().endswith(b".md")]
    if not lines:
        raise RegistryError(f"git ls-tree HEAD matched nothing for: {' '.join(paths)}")
    if strict:
        names = [line.split(b"\t", 1)[1].decode("utf-8", "replace") for line in lines]
        for p in paths:
            prefix = p.rstrip("/")
            if not any(n == prefix or n.startswith(prefix + "/") for n in names):
                raise RegistryError(f"git ls-tree HEAD matched nothing for {p}")
    return hashlib.sha256(b"\n".join(lines) + b"\n").hexdigest()


def is_dirty(root: Path, paths: Sequence[str]) -> bool:
    status = _git(root, "status", "--porcelain", "--untracked-files=all", "--", *paths)
    return bool(status.strip())


def crate_key(root: Path, crates: Sequence[Crate], crate: Crate, with_features: bool) -> str:
    key = tree_key(root, source_paths(crates, crate), strict=True)
    if with_features and crate.test_features:
        key = f"{key}+{crate.test_features}"
    return key


def select(
    crates: Sequence[Crate],
    host_test: bool = False,
    android_local: bool = False,
    ios_umbrella: bool = False,
    platform: Optional[str] = None,
    bundled_by: Optional[str] = None,
    required: Optional[str] = None,
) -> List[Crate]:
    out: List[Crate] = []
    for c in crates:
        if host_test and not c.host_test_lib:
            continue
        # Android .so the app build requires and the local tooling prepares (native_libs.ps1 -Android,
        # dist worker): Rust crates that are `required: always` on Android.
        if android_local and not (
            c.language == "rust" and "android" in c.platforms and c.platforms["android"].required == "always"
        ):
            continue
        if ios_umbrella and not ("ios" in c.platforms and c.platforms["ios"].via == "fushi_ios_umbrella"):
            continue
        if platform is not None:
            entry = c.platforms.get(platform)
            if entry is None:
                continue
            if bundled_by is not None and entry.bundled_by != bundled_by:
                continue
            if required is not None and entry.required != required:
                continue
        out.append(c)
    return out


def check(root: Path, crates: Sequence[Crate]) -> List[str]:
    problems: List[str] = []
    names = {c.name for c in crates}
    on_disk = sorted(
        p.name
        for p in (root / "native").iterdir()
        if p.is_dir() and p.name != "third_party_licenses" and not p.name.startswith(".")
    )
    for missing in sorted(set(on_disk) - names):
        problems.append(f"native/{missing} is not registered in native/crates.json")
    for c in crates:
        if not (root / c.dir).is_dir():
            problems.append(f"{c.name}: {c.dir} does not exist")
            continue
        if c.language == "rust" and not (root / c.dir / "Cargo.toml").is_file():
            problems.append(f"{c.name}: rust crate without {c.dir}/Cargo.toml")
        for platform, script in c.build.items():
            if platform not in PLATFORMS:
                problems.append(f"{c.name}.build: unknown platform {platform!r}")
            if not (root / c.dir / script).is_file():
                problems.append(f"{c.name}.build.{platform}: {c.dir}/{script} does not exist")
        for rel in (*c.external_sources, *c.key_extra_inputs):
            if not (root / rel).exists():
                problems.append(f"{c.name}: listed input {rel} does not exist")
        if c.dart_package and not (root / c.dart_package / "pubspec.yaml").is_file():
            problems.append(f"{c.name}.dart_package: {c.dart_package}/pubspec.yaml does not exist")
        if c.host_test_lib:
            for platform in ("windows", "linux", "macos"):
                if platform not in c.build:
                    problems.append(f"{c.name}: host_test_lib needs build.{platform}")
        for platform, entry in c.platforms.items():
            if entry.bundled_by == "app":
                if not entry.artifact:
                    problems.append(f"{c.name}.platforms.{platform}: bundled_by=app needs an artifact")
                if platform not in c.build:
                    problems.append(f"{c.name}.platforms.{platform}: bundled_by=app needs build.{platform}")
            if entry.via and entry.via not in names:
                problems.append(f"{c.name}.platforms.{platform}.via: unknown aggregate {entry.via}")
        ios = c.platforms.get("ios")
        if ios and ios.via and ios.required == "always" and not c.abi_symbol:
            problems.append(f"{c.name}: iOS required=always needs an abi_symbol to check the umbrella for")
        if c.abi_symbol and c.dart_package:
            pkg = root / c.dart_package / "lib"
            needle = f"'{c.abi_symbol}'"
            if pkg.is_dir() and not any(needle in f.read_text(encoding="utf-8", errors="replace") for f in pkg.rglob("*.dart")):
                problems.append(f"{c.name}: abi_symbol {c.abi_symbol} is not looked up anywhere under {c.dart_package}/lib")
    return problems


def _print_value(value: object) -> None:
    if isinstance(value, str):
        print(value)
    elif isinstance(value, (list, tuple)):
        for item in value:
            print(item if isinstance(item, str) else json.dumps(item))
    elif value is None:
        pass
    else:
        print(json.dumps(value))


def _raw_crate(root: Path, name: str) -> dict:
    data = json.loads((root / "native" / "crates.json").read_text(encoding="utf-8"))
    for raw in data["crates"]:
        if raw["name"] == name:
            return raw
    raise RegistryError(f"unknown crate {name!r} (native/crates.json)")


def main(argv: Sequence[str]) -> int:
    # Plain \n on every OS: the shell callers split / compare the output (Git Bash would keep the \r).
    sys.stdout.reconfigure(newline="\n")  # type: ignore[attr-defined]
    root = repo_root()
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, args = argv[0], list(argv[1:])
    crates = load(root)
    if cmd == "list":
        opts = {"host_test": False, "android_local": False, "ios_umbrella": False}
        platform = bundled = required = None
        while args:
            a = args.pop(0)
            if a == "--host-test":
                opts["host_test"] = True
            elif a == "--android-local":
                opts["android_local"] = True
            elif a == "--ios-umbrella":
                opts["ios_umbrella"] = True
            elif a == "--platform":
                platform = args.pop(0)
            elif a == "--bundled-by":
                bundled = args.pop(0)
            elif a == "--required":
                required = args.pop(0)
            else:
                raise RegistryError(f"list: unknown option {a}")
        for c in select(crates, platform=platform, bundled_by=bundled, required=required, **opts):
            print(c.name)
        return 0
    if cmd == "get":
        if len(args) != 2:
            raise RegistryError("usage: get <crate> <field[.field...]>")
        value: object = _raw_crate(root, args[0])
        for part in args[1].split("."):
            value = value.get(part) if isinstance(value, dict) else None
        _print_value(value)
        return 0
    if cmd == "paths":
        for p in source_paths(crates, by_name(crates, args[0])):
            print(p)
        return 0
    if cmd == "key":
        if not args:
            raise RegistryError("usage: key <crate> [--require-clean] [--features]")
        crate = by_name(crates, args[0])
        flags = set(args[1:])
        unknown = flags - {"--require-clean", "--features"}
        if unknown:
            raise RegistryError(f"key: unknown option(s) {sorted(unknown)}")
        if "--require-clean" in flags and is_dirty(root, source_paths(crates, crate)):
            return 3
        print(crate_key(root, crates, crate, "--features" in flags))
        return 0
    if cmd == "tree-key":
        # The crate inputs names.sh passes are the registry's own (`paths`), checked by `check`.
        print(tree_key(root, args, strict=False))
        return 0
    if cmd == "bundle":
        if len(args) != 1:
            raise RegistryError("usage: bundle <platform>")
        for c in select(crates, platform=args[0], bundled_by="app"):
            entry = c.platforms[args[0]]
            print(f"{c.name}\t{entry.artifact}\t{entry.required}\t{c.build[args[0]]}")
        return 0
    if cmd == "ios-checks":
        for c in select(crates, ios_umbrella=True, platform="ios", required="always"):
            if c.abi_symbol:
                print(f"{c.name}\t{c.abi_symbol}")
        return 0
    if cmd == "check":
        problems = check(root, crates)
        for p in problems:
            print(f"error: {p}", file=sys.stderr)
        return 1 if problems else 0
    raise RegistryError(f"unknown command {cmd!r}")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except RegistryError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
