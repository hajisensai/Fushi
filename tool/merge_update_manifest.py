#!/usr/bin/env python3
"""Merge one platform's release assets into the update-manifest JSON file.

TODO-781: This is the load-bearing merge step of `publish_update_manifest.sh`,
extracted into a standalone, unit-testable script. The Android debug auto-update
broke because two platform publish jobs (android / desktop) push the SAME
`update-manifest` branch concurrently for the SAME release tag; the loser's
assets were clobbered. The fix lives in two layers:

  1. publish_update_manifest.sh re-fetches the LIVE remote tip on every retry and
     never falls into orphan-branch mode on a transient fetch failure.
  2. This merge keeps the OTHER platform's same-tag assets instead of dropping
     them. The only assets that are superseded are those carrying a DIFFERENT
     tag (a genuinely older release).

Reading from / writing to a file (not a git tree) keeps this offline-testable:
the Dart guard test (hibiki/test/tools/update_manifest_publish_race_test.dart)
drives this script twice over the same file to simulate interleaved publishes.

Required env:
  MANIFEST_FILE        path to the manifest JSON to read/merge/write
  TAG                  this release's tag (e.g. v0.11.1-debug.5633+3cf5905)
  CHANNEL              debug|beta|formal
  VERSION              normalized version string
  PRERELEASE           "true"|"false"
  NOTES                release notes
  RELEASE_SEQUENCE     monotonic int (git rev-list count)
  PLATFORM_ASSETS_JSON JSON array of {name, browser_download_url} for THIS run
"""

from __future__ import annotations

import json
import os
from typing import Any


def _valid_assets(raw: Any) -> list[dict[str, str]]:
    """Filter a raw assets list down to well-formed {name, url} entries."""
    if not isinstance(raw, list):
        return []
    out: list[dict[str, str]] = []
    for a in raw:
        if (
            isinstance(a, dict)
            and a.get("name")
            and a.get("browser_download_url")
        ):
            out.append(a)
    return out


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
) -> dict[str, Any]:
    """Pure merge: combine this platform's assets with any same-tag prior assets.

    Same-tag manifest -> keep the other platform's assets and merge ours
    (dedupe by name; ours win on a name collision so a re-run updates the URL).
    A manifest carrying a DIFFERENT tag is a genuinely older release and is
    fully superseded.
    """
    prior_assets: list[dict[str, str]] = []
    if existing.get("tag") == tag:
        prior_assets = _valid_assets(existing.get("assets"))

    by_name: dict[str, dict[str, str]] = {a["name"]: a for a in prior_assets}
    for a in new_assets:
        by_name[a["name"]] = a
    merged = sorted(by_name.values(), key=lambda a: a["name"])

    return {
        "schemaVersion": 1,
        "version": version,
        "tag": tag,
        "channel": channel,
        "prerelease": prerelease,
        "releaseSequence": int(release_sequence),
        "notes": notes,
        "assets": merged,
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


def main() -> None:
    path = os.environ["MANIFEST_FILE"]
    new_assets = _valid_assets(json.loads(os.environ["PLATFORM_ASSETS_JSON"]))

    manifest = merge_manifest(
        _load_existing(path),
        tag=os.environ["TAG"],
        channel=os.environ["CHANNEL"],
        version=os.environ["VERSION"],
        prerelease=os.environ["PRERELEASE"].strip().lower() == "true",
        notes=os.environ["NOTES"],
        release_sequence=int(os.environ["RELEASE_SEQUENCE"]),
        new_assets=new_assets,
    )

    with open(path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(
        f"Wrote {path} with {len(manifest['assets'])} asset(s) for tag {manifest['tag']}"
    )


if __name__ == "__main__":
    main()
