#!/usr/bin/env python3
"""Standalone unit tests for merge_update_manifest.merge_manifest (TODO-1173).

Run:  python3 tool/merge_update_manifest_test.py
Exits non-zero on the first failed assertion. No test framework required.

Covers the monotonic guard and cross-platform asset union that fix the update
manifest version downgrade (an installed newer build shown an older latest),
plus backward compatibility with legacy manifests that lack releaseSequence.
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from merge_update_manifest import merge_manifest  # noqa: E402

_REPO = "owner/repo"


def _url(tag: str, name: str) -> str:
    return "https://github.com/" + _REPO + "/releases/download/" + tag + "/" + name


def _android(seq: int):
    tag = "v0.11.1-debug." + str(seq) + "+sha" + str(seq)
    version = "0.11.1-debug." + str(seq)
    name = "hibiki-0.11.1-debug." + str(seq) + "-sha" + str(seq) + "-debug.apk"
    assets = [{"name": name, "browser_download_url": _url(tag, name)}]
    return tag, version, assets, name


def _desktop(seq: int):
    tag = "v0.11.1-debug." + str(seq) + "+sha" + str(seq)
    version = "0.11.1-debug." + str(seq)
    name = "hibiki-0.11.1-debug." + str(seq) + "-windows-setup.exe"
    assets = [{"name": name, "browser_download_url": _url(tag, name)}]
    return tag, version, assets, name


def _publish(existing, platform_fn, seq, live=None):
    tag, version, assets, name = platform_fn(seq)
    out = merge_manifest(
        existing,
        tag=tag,
        channel="debug",
        version=version,
        prerelease=True,
        notes="notes for " + str(seq),
        release_sequence=seq,
        new_assets=assets,
        live_asset_names=live,
    )
    # Round-trip through JSON to mirror what publish_update_manifest.sh persists.
    return json.loads(json.dumps(out)), name


def _names(manifest):
    return sorted(a["name"] for a in manifest["assets"])


_failures = []


def check(cond, msg):
    if not cond:
        _failures.append(msg)
        print("FAIL: " + msg)
    else:
        print("ok:   " + msg)


def test_first_publish():
    m, apk = _publish({}, _android, 100)
    check(m["tag"] == "v0.11.1-debug.100+sha100", "first publish advertises its tag")
    check(m["releaseSequence"] == 100, "first publish releaseSequence == 100")
    check(_names(m) == [apk], "first publish has only its asset")


def test_cross_platform_union_newer_tag():
    # android@100 then desktop@105: DIFFERENT tags, DIFFERENT platforms.
    # New semantics: keep BOTH (do not fully supersede the other platform).
    m, apk = _publish({}, _android, 100)
    m, exe = _publish(m, _desktop, 105)
    check(_names(m) == sorted([apk, exe]), "newer desktop keeps older android asset")
    check(m["tag"] == "v0.11.1-debug.105+sha105", "top tag advances to newest 105")
    check(m["releaseSequence"] == 105, "top releaseSequence advances to 105")


def test_monotonic_guard_old_platform_late():
    # THE bug: desktop@100 (slow, older push) finishes AFTER android@105.
    # Must NOT downgrade the advertised version; must still add desktop asset.
    m, apk = _publish({}, _android, 105)
    m, exe = _publish(m, _desktop, 100)
    check(m["tag"] == "v0.11.1-debug.105+sha105", "monotonic top tag stays 105")
    check(m["releaseSequence"] == 105, "monotonic top releaseSequence stays 105")
    check(m["version"] == "0.11.1-debug.105", "monotonic top version stays 105")
    check(m["notes"] == "notes for 105", "monotonic notes stay newest")
    check(_names(m) == sorted([apk, exe]), "lagging desktop asset still added")


def test_same_platform_downgrade_rejected():
    # android@105 then a stale android@100 re-arrives: keep 105, drop 100.
    m, apk105 = _publish({}, _android, 105)
    m, apk100 = _publish(m, _android, 100)
    check(_names(m) == [apk105], "same-platform older seq rejected")
    check(m["releaseSequence"] == 105, "same-platform downgrade keeps top 105")


def test_same_platform_upgrade_replaces():
    # android multi-ABI at 100, then android multi-ABI at 105: 100 set dropped.
    def android_multi(seq):
        tag = "v0.11.1-beta." + str(seq)
        version = "0.11.1-beta." + str(seq)
        names = [
            "hibiki-0.11.1-beta." + str(seq) + "-arm64-v8a.apk",
            "hibiki-0.11.1-beta." + str(seq) + "-x86_64.apk",
        ]
        assets = [{"name": n, "browser_download_url": _url(tag, n)} for n in names]
        return tag, version, assets, names

    tag100, v100, a100, n100 = android_multi(100)
    m = json.loads(json.dumps(merge_manifest(
        {}, tag=tag100, channel="beta", version=v100, prerelease=True,
        notes="b100", release_sequence=100, new_assets=a100,
    )))
    tag105, v105, a105, n105 = android_multi(105)
    m = json.loads(json.dumps(merge_manifest(
        m, tag=tag105, channel="beta", version=v105, prerelease=True,
        notes="b105", release_sequence=105, new_assets=a105,
    )))
    check(_names(m) == sorted(n105), "same-platform upgrade replaces whole ABI set")
    check(m["releaseSequence"] == 105, "same-platform upgrade advances to 105")


def test_concurrent_same_tag_both_platforms():
    # TODO-781: same tag, two platforms -> both kept.
    m, apk = _publish({}, _android, 100)
    m, exe = _publish(m, _desktop, 100)
    check(_names(m) == sorted([apk, exe]), "same-tag concurrent keeps both platforms")
    check(m["releaseSequence"] == 100, "same-tag concurrent top seq == 100")


def test_backward_compat_legacy_no_seq():
    # Legacy manifest: no releaseSequence field, no per-asset provenance; seq is
    # recovered from the tag. A newer desktop must not drop the legacy android.
    apk = "hibiki-0.11.1-debug.100-sha100-debug.apk"
    tag = "v0.11.1-debug.100+sha100"
    legacy = {
        "schemaVersion": 1,
        "version": "0.11.1-debug.100",
        "tag": tag,
        "channel": "debug",
        "prerelease": True,
        "notes": "legacy",
        "assets": [{"name": apk, "browser_download_url": _url(tag, apk)}],
    }
    m, exe = _publish(legacy, _desktop, 105)
    check(_names(m) == sorted([apk, exe]), "legacy android recovered via tag seq, kept")
    check(m["releaseSequence"] == 105, "legacy plus newer desktop advances top to 105")


def test_backward_compat_no_seq_unparseable():
    # No releaseSequence and a tag with no debug./beta. sequence: must not crash;
    # existing asset treated as oldest so the incoming publish supersedes safely.
    old = "hibiki-old-windows-setup.exe"
    legacy = {
        "schemaVersion": 1,
        "version": "0.0.0",
        "tag": "v0.0.0",
        "channel": "debug",
        "prerelease": True,
        "notes": "legacy",
        "assets": [{"name": old, "browser_download_url": _url("v0.0.0", old)}],
    }
    m, exe = _publish(legacy, _desktop, 105)
    # old and new are both windows platform; incoming (105 > -1) wins the slot.
    check(exe in _names(m), "unparseable legacy incoming desktop asset present")
    check(m["releaseSequence"] == 105, "unparseable legacy adopts incoming seq")


def test_idempotent():
    m1, apk = _publish({}, _android, 100)
    m2, _ = _publish(m1, _android, 100)
    check(m1 == m2, "re-publishing the same run is idempotent")


# ── BUG-1516: retained entries must not outlive the file they point at ──────
#
# Shape of the real outage: desktop published at seq 10182 and then stopped;
# Android kept publishing. The rolling release pruned the 10182 desktop asset,
# but the merge kept advertising it, so the only in-app action an old Windows
# client had was downloading a 404.


def _android_name(seq):
    return _android(seq)[3]


def test_pruned_retained_asset_is_dropped():
    m, exe = _publish({}, _desktop, 10182)
    check(exe in _names(m), "precondition: desktop asset advertised at 10182")

    # Android publishes later; the release no longer carries the desktop asset.
    m2, apk = _publish(m, _android, 10192, live={_android_name(10192)})
    check(exe not in _names(m2), "pruned desktop asset dropped from manifest")
    check(apk in _names(m2), "the just-uploaded APK survives the filter")


def test_live_retained_asset_is_kept():
    # Same publish order, but the desktop asset is still on the release: the
    # cross-platform union must behave exactly as before the filter existed.
    m, exe = _publish({}, _desktop, 10182)
    m2, apk = _publish(m, _android, 10192, live={_android_name(10192), exe})
    check(exe in _names(m2), "live desktop asset still retained")
    check(apk in _names(m2), "APK present alongside it")


def test_incoming_survives_stale_live_snapshot():
    # The live list is queried before this run's upload finishes, so it can miss
    # the asset we are publishing right now. Incoming must never be filtered --
    # otherwise a publish would delete its own asset from the manifest.
    m, exe = _publish({}, _desktop, 10182)
    m2, apk = _publish(m, _android, 10192, live={exe})
    check(apk in _names(m2), "incoming asset kept despite absent from live set")
    check(exe in _names(m2), "live desktop asset kept")


def test_unavailable_live_list_disables_filter():
    # `gh release view` failing must not be read as "nothing is live" — that
    # would strand every platform that did not publish in this run.
    m, exe = _publish({}, _desktop, 10182)
    m2, apk = _publish(m, _android, 10192, live=None)
    check(exe in _names(m2), "None live list keeps retained assets (fail-open)")
    check(apk in _names(m2), "and still adds the incoming asset")


def test_empty_live_list_clears_retained():
    # An empty SET is different from None: the release genuinely has no assets
    # besides what this run uploads, so every retained entry is dead.
    m, exe = _publish({}, _desktop, 10182)
    m2, apk = _publish(m, _android, 10192, live=set())
    check(exe not in _names(m2), "empty live set drops retained assets")
    check(apk in _names(m2), "incoming asset unaffected by empty live set")


# ── BUG-1516 ①b: cross-family desktop mirror ───────────────────────────────
#
# The hibiki-family manifest's TOP LEVEL belongs to the Android bridge, but its
# desktop slots must carry Fushi installers (Windows/macOS migrate by installer
# overwrite; Android cannot cross package names). So the mirror contributes
# assets and must not touch anything else.


def _mirror(existing, platform_fn, seq):
    tag, version, assets, name = platform_fn(seq)
    out = merge_manifest(
        existing,
        tag=tag,
        channel="debug",
        version=version,
        prerelease=True,
        notes="fushi notes " + str(seq),
        release_sequence=seq,
        new_assets=assets,
        advertise_top_level=False,
    )
    return json.loads(json.dumps(out)), name


def test_mirror_adds_asset_without_moving_top_level():
    bridge, apk = _publish({}, _android, 10192)
    mirrored, exe = _mirror(bridge, _desktop, 10405)

    check(exe in _names(mirrored), "mirror contributes the desktop asset")
    check(apk in _names(mirrored), "mirror keeps the bridge APK")
    # The whole point: a bridge client must keep reading the bridge's release.
    check(
        mirrored["version"] == bridge["version"],
        "mirror leaves top-level version alone",
    )
    check(mirrored["tag"] == bridge["tag"], "mirror leaves top-level tag alone")
    check(
        mirrored["releaseSequence"] == bridge["releaseSequence"],
        "mirror leaves top-level releaseSequence alone (BUG-1481 mismatch guard)",
    )
    check(mirrored["notes"] == bridge["notes"], "mirror leaves notes alone")


def test_mirror_supersedes_the_stale_desktop_slot():
    # The pre-split desktop entry is what went 404. A higher-sequence mirror must
    # replace it outright, without any liveness filter being involved.
    stale, old_exe = _publish({}, _desktop, 10182)
    bridge, apk = _publish(stale, _android, 10192)
    check(old_exe in _names(bridge), "precondition: stale desktop entry present")

    mirrored, new_exe = _mirror(bridge, _desktop, 10405)
    check(old_exe not in _names(mirrored), "stale desktop entry superseded")
    check(new_exe in _names(mirrored), "current desktop asset takes the slot")
    check(apk in _names(mirrored), "bridge APK untouched by the desktop mirror")


def test_mirror_never_creates_a_manifest():
    # No existing hibiki-family manifest => nothing to mirror into. Creating one
    # would resurrect a retired channel carrying the other family's metadata.
    out, _ = _mirror({}, _desktop, 10405)
    check(out == {}, "mirror is a no-op when there is no manifest to augment")


def main():
    for fn in [
        test_first_publish,
        test_cross_platform_union_newer_tag,
        test_monotonic_guard_old_platform_late,
        test_same_platform_downgrade_rejected,
        test_same_platform_upgrade_replaces,
        test_concurrent_same_tag_both_platforms,
        test_backward_compat_legacy_no_seq,
        test_backward_compat_no_seq_unparseable,
        test_idempotent,
        test_pruned_retained_asset_is_dropped,
        test_live_retained_asset_is_kept,
        test_incoming_survives_stale_live_snapshot,
        test_unavailable_live_list_disables_filter,
        test_empty_live_list_clears_retained,
        test_mirror_adds_asset_without_moving_top_level,
        test_mirror_supersedes_the_stale_desktop_slot,
        test_mirror_never_creates_a_manifest,
    ]:
        print("== " + fn.__name__ + " ==")
        fn()
    if _failures:
        print("")
        print(str(len(_failures)) + " FAILURE(S)")
        sys.exit(1)
    print("")
    print("ALL PASS")


if __name__ == "__main__":
    main()
