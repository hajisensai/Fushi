#!/usr/bin/env python3
"""Merge one platform release assets into the update-manifest JSON file.

TODO-781 (race) + TODO-1173 (version downgrade). Two problems break a naive
merge of the manifest that publish_update_manifest.sh pushes to the
update-manifest branch:

  1. Two platform publish jobs (android / desktop) push the SAME branch
     concurrently for the SAME release tag; the losing job assets get
     clobbered. Fixed by preserving the OTHER platform assets.
  2. Each platform job stamps the manifest with its OWN commit git rev-list
     count sequence. A slow platform build (Windows) from an OLDER push can
     finish AFTER a newer push fast platform job. The prior logic only
     compared existing.tag == tag: a different tag caused a FULL overwrite,
     so the slow-old job wrote its OLDER version back over the manifest and
     clients on the newer build saw an older latest, reporting
     already-up-to-date (the version downgrade of TODO-1173).

The fix is a MONOTONIC, PER-PLATFORM merge keyed on releaseSequence:

  * Monotonic guard: the advertised top-level tag/version/releaseSequence
    never moves backward. If the manifest already carries a HIGHER
    releaseSequence than this run, this run keeps the existing (newer)
    top-level metadata and only contributes assets for its own platform.
  * Cross-platform asset union: assets are grouped by platform (from the
    asset name shape). Each platform keeps the asset set from its OWN
    highest sequence. A late older-sequence job only refreshes its own
    platform slot (and only if its sequence is not lower than what that
    slot already holds); it NEVER wipes another platform newer assets. A
    late older SAME-platform job is rejected. This keeps a lagging platform
    asset present so the client selectUpdateReleaseForCurrentPlatform never
    returns null.
  * Liveness filter (BUG-1516): "keep the lagging platform's asset" is only
    safe while that asset still EXISTS. The rolling release prunes old
    assets per platform, so a platform that stops publishing eventually has
    its retained entry point at a deleted file -- the client then downloads
    a hard 404 with no in-app recovery (real report: an old Hibiki debug
    client stuck on hibiki-1.3.2-debug.10182-windows-setup.exe after that
    asset was pruned, while the manifest advertised 1.3.3-debug.10192 up
    top). Retained entries are therefore intersected with the release's
    CURRENT asset names when the caller can supply them. Dropping the slot
    makes the client report "no build for your platform" instead of a
    broken download -- an honest miss beats a guaranteed 404.

releaseSequence used to be write-only; it is now the primary comparison key
and is persisted PER ASSET so a later merge can compare platforms sitting at
different sequences. Legacy manifests without the field degrade safely: the
sequence is recovered from the tag (...-debug.5633+sha -> 5633), then from
the top-level releaseSequence, and finally treated as unknown/oldest so a
fresh publish supersedes it. The extra per-asset keys are ignored by the
client (buildReleaseFromManifest reads only name + browser_download_url).

Reading/writing a file (not a git tree) keeps this offline-testable:
fushi/test/tools/update_manifest_publish_race_test.dart drives this script
twice over one file, and tool/merge_update_manifest_test.py unit-tests
merge_manifest() directly.

Required env:
  MANIFEST_FILE        path to the manifest JSON to read/merge/write
  TAG                  this release tag (v0.11.1-debug.5633+3cf5905)
  CHANNEL              debug|beta|formal
  VERSION              normalized version string
  PRERELEASE           true|false
  NOTES                release notes
  RELEASE_SEQUENCE     monotonic int (git rev-list count)
  PLATFORM_ASSETS_JSON JSON array of {name, browser_download_url} for THIS run

Optional env:
  LIVE_ASSET_NAMES_JSON  JSON array of asset names that STILL EXIST on the
                         rolling release right now (BUG-1516). Retained
                         entries whose file has been pruned are dropped.
                         Absent / empty / unparseable => no filtering, so a
                         failed `gh release view` can never wipe the manifest.
"""

from __future__ import annotations

import json
import os
import re
from typing import Any, Optional

_SEQ_IN_TAG = re.compile(r"(?:debug|beta)\.(\d+)")


def _valid_assets(raw: Any) -> list[dict[str, Any]]:
    if not isinstance(raw, list):
        return []
    out: list[dict[str, Any]] = []
    for a in raw:
        if (
            isinstance(a, dict)
            and a.get("name")
            and a.get("browser_download_url")
        ):
            out.append(a)
    return out


def _coerce_int(value: Any) -> Optional[int]:
    """Best-effort int coercion; bool is rejected, non-numeric -> None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        s = value.strip()
        if s and s.lstrip("-").isdigit():
            try:
                return int(s)
            except ValueError:
                return None
    return None


def _seq_from_tag(tag: Any) -> Optional[int]:
    """Recover the release sequence from a channel-qualified tag string."""
    if not isinstance(tag, str):
        return None
    m = _SEQ_IN_TAG.search(tag)
    return int(m.group(1)) if m else None


def _platform_key(name: str) -> str:
    """Group assets by platform from their version-embedding file name.

    Shapes mirror each Publish step ASSET_GLOB and are mutually exclusive:
    hibiki-*.apk android, hibiki-*-windows-setup.exe windows,
    hibiki-*-macos.zip / hibiki-*.ipa apple. Unknown shape becomes its own
    singleton slot other:<name> unioned by exact name.
    """
    n = name.lower()
    if n.endswith("-windows-setup.exe"):
        return "windows"
    if n.endswith(".apk"):
        return "android"
    if n.endswith("-macos.zip"):
        return "macos"
    if n.endswith(".ipa"):
        return "ios"
    return "other:" + name


def _stamp(
    asset: dict[str, Any],
    *,
    seq: Optional[int],
    tag: str,
    version: str,
) -> dict[str, Any]:
    """Normalize an asset to the persisted shape with provenance stamped on."""
    return {
        "name": asset["name"],
        "browser_download_url": asset["browser_download_url"],
        "releaseSequence": seq,
        "tag": tag,
        "version": version,
    }


def merge_manifest(
    existing: dict[str, Any],
    *,
    tag: str,
    channel: str,
    version: str,
    prerelease: bool,
    notes: str,
    release_sequence: int,
    new_assets: list[dict[str, str]],
    live_asset_names: Optional[set[str]] = None,
) -> dict[str, Any]:
    """Pure, monotonic, per-platform merge (see module docstring).

    Never downgrades the advertised top-level release; keeps every platform
    highest-sequence asset set; idempotent and safe on legacy manifests that
    lack releaseSequence.

    [live_asset_names] is the set of asset names that still exist on the
    release. When given, retained entries not in it are dropped (BUG-1516).
    `None` means "caller could not tell" and disables the filter entirely --
    never confuse it with an empty set, which legitimately means "the release
    has no assets at all" and clears every retained entry.
    """
    release_sequence = int(release_sequence)

    incoming: list[dict[str, Any]] = [
        _stamp(a, seq=release_sequence, tag=tag, version=version)
        for a in new_assets
    ]
    # This run just uploaded its own assets, so they are live by construction
    # even if the caller's snapshot was taken before the upload. Only RETAINED
    # entries are ever filtered.
    incoming_names: set[str] = {a["name"] for a in incoming}

    existing_seq = _coerce_int(existing.get("releaseSequence"))
    if existing_seq is None:
        existing_seq = _seq_from_tag(existing.get("tag"))
    existing_tag = existing.get("tag") if isinstance(existing.get("tag"), str) else ""
    existing_version = (
        existing.get("version") if isinstance(existing.get("version"), str) else ""
    )

    normalized_existing: list[dict[str, Any]] = []
    for a in _valid_assets(existing.get("assets")):
        if (
            live_asset_names is not None
            and a["name"] not in live_asset_names
            and a["name"] not in incoming_names
        ):
            # Pruned off the release -> its URL is a 404. Drop it rather than
            # hand the client a download that cannot succeed (BUG-1516).
            continue
        atag = (
            a.get("tag")
            if (isinstance(a.get("tag"), str) and a.get("tag"))
            else existing_tag
        )
        seq = _coerce_int(a.get("releaseSequence"))
        if seq is None:
            seq = _seq_from_tag(atag)
        if seq is None:
            seq = existing_seq
        aver = (
            a.get("version")
            if (isinstance(a.get("version"), str) and a.get("version"))
            else existing_version
        )
        normalized_existing.append(
            {
                "name": a["name"],
                "browser_download_url": a["browser_download_url"],
                "releaseSequence": seq,
                "tag": atag,
                "version": aver,
            }
        )

    # Group per platform, keeping the highest-sequence asset SET per platform.
    # A missing sequence sorts as oldest (-1) so any real publish supersedes it.
    platforms: dict[str, dict[str, Any]] = {}

    def _consider(asset: dict[str, Any]) -> None:
        key = _platform_key(asset["name"])
        seq = asset["releaseSequence"]
        seq_cmp = seq if seq is not None else -1
        slot = platforms.get(key)
        if slot is None:
            platforms[key] = {"seq": seq_cmp, "assets": [asset]}
            return
        if seq_cmp > slot["seq"]:
            platforms[key] = {"seq": seq_cmp, "assets": [asset]}
        elif seq_cmp == slot["seq"]:
            # Same sequence within a platform: union by name (a re-run refreshing
            # URLs, or multiple ABI apks in one publish). Later wins on a name
            # collision so a re-publish updates the download URL.
            by_name = {x["name"]: x for x in slot["assets"]}
            by_name[asset["name"]] = asset
            slot["assets"] = list(by_name.values())
        # else: strictly older for this platform -> ignore.

    for a in normalized_existing:
        _consider(a)
    for a in incoming:
        _consider(a)

    merged_assets: list[dict[str, Any]] = []
    for slot in platforms.values():
        merged_assets.extend(slot["assets"])
    merged_assets.sort(key=lambda a: a["name"])

    # Monotonic guard on the advertised top-level release. If the manifest
    # already advertises a NEWER sequence than this run, keep it; this older run
    # still contributed assets for its own platform above.
    if existing_seq is not None and existing_seq > release_sequence:
        top_seq: int = existing_seq
        top_tag = existing_tag or tag
        top_version = existing_version or version
        top_notes = (
            existing.get("notes") if isinstance(existing.get("notes"), str) else notes
        )
        top_prerelease = (
            existing.get("prerelease")
            if isinstance(existing.get("prerelease"), bool)
            else prerelease
        )
        top_channel = (
            existing.get("channel")
            if (isinstance(existing.get("channel"), str) and existing.get("channel"))
            else channel
        )
    else:
        top_seq = release_sequence
        top_tag = tag
        top_version = version
        top_notes = notes
        top_prerelease = prerelease
        top_channel = channel

    return {
        "schemaVersion": 1,
        "version": top_version,
        "tag": top_tag,
        "channel": top_channel,
        "prerelease": top_prerelease,
        "releaseSequence": int(top_seq),
        "notes": top_notes,
        "assets": merged_assets,
    }


def _load_existing(path: str) -> dict[str, Any]:
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _live_asset_names_from_env() -> Optional[set[str]]:
    """Parse LIVE_ASSET_NAMES_JSON; anything unusable disables the filter.

    Fail-open on purpose: the caller gets this list from `gh release view`,
    which can fail for reasons that have nothing to do with the manifest
    (rate limit, transient 5xx, tag not created yet). Treating that as
    "nothing is live" would delete every retained asset and strand every
    platform that did not publish in this run -- a far worse outage than the
    stale entry the filter exists to remove.
    """
    raw = os.environ.get("LIVE_ASSET_NAMES_JSON", "").strip()
    if not raw:
        return None
    try:
        parsed = json.loads(raw)
    except (ValueError, TypeError):
        return None
    if not isinstance(parsed, list):
        return None
    return {x for x in parsed if isinstance(x, str) and x}


def main() -> None:
    path = os.environ["MANIFEST_FILE"]
    new_assets = _valid_assets(json.loads(os.environ["PLATFORM_ASSETS_JSON"]))
    live_asset_names = _live_asset_names_from_env()

    manifest = merge_manifest(
        _load_existing(path),
        tag=os.environ["TAG"],
        channel=os.environ["CHANNEL"],
        version=os.environ["VERSION"],
        prerelease=os.environ["PRERELEASE"].strip().lower() == "true",
        notes=os.environ["NOTES"],
        release_sequence=int(os.environ["RELEASE_SEQUENCE"]),
        new_assets=new_assets,
        live_asset_names=live_asset_names,
    )

    with open(path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(
        "Wrote "
        + path
        + " with "
        + str(len(manifest["assets"]))
        + " asset(s); advertised tag "
        + str(manifest["tag"])
        + " (seq "
        + str(manifest["releaseSequence"])
        + ")"
    )


if __name__ == "__main__":
    main()
