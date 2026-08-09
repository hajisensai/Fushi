import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';

// TODO-1205 / BUG-1205: the update checker must judge presence of an update and
// display the version from the SELECTED PLATFORM ASSET own stamped version, not
// from the manifest top-level tag (the merge script keeps that at the MAX
// release sequence across all platforms). When desktop advertises seq 6636 but
// the Android apk still lags at seq 6621, an installed 6621 client used to be
// told there is a new 6636 forever, install 6621 again, and loop.
//
// These pure-function tests drive the real consumption chain
// (buildReleaseFromManifest -> selectUpdateReleaseForCurrentPlatform) that the
// _check flow uses, at the strongest landable layer (no network / widgets).

Map<String, dynamic> _stampedAsset({
  required String name,
  required String downloadTag,
  String? version,
  String? tag,
  int? releaseSequence,
}) {
  final Map<String, dynamic> asset = <String, dynamic>{
    'name': name,
    'browser_download_url':
        'https://github.com/hajisensai/fushi/releases/download/$downloadTag/$name',
  };
  if (version != null) asset['version'] = version;
  if (tag != null) asset['tag'] = tag;
  if (releaseSequence != null) asset['releaseSequence'] = releaseSequence;
  return asset;
}

String _debugManifest({
  required String topVersion,
  required String topTag,
  required List<Map<String, dynamic>> assets,
}) {
  return jsonEncode(<String, dynamic>{
    'schemaVersion': kUpdateManifestSchemaVersion,
    'version': topVersion,
    'tag': topTag,
    'channel': 'debug',
    'prerelease': true,
    'releaseSequence': 6636,
    'notes': 'debug build $topVersion',
    'assets': assets,
  });
}

void main() {
  group('buildReleaseFromManifest passes through per-asset version stamp', () {
    test('per-asset version / tag / releaseSequence survive rebuild', () {
      final Map<String, dynamic>? release = buildReleaseFromManifest(
        _debugManifest(
          topVersion: '1.0.1-debug.6636',
          topTag: 'v1.0.1-debug.6636+aaaaaaa',
          assets: <Map<String, dynamic>>[
            _stampedAsset(
              name: 'hibiki-1.0.1-debug.6621-bbbbbbb-debug.apk',
              downloadTag: 'debug-rolling',
              version: '1.0.1-debug.6621',
              tag: 'v1.0.1-debug.6621+bbbbbbb',
              releaseSequence: 6621,
            ),
          ],
        ),
      );
      expect(release, isNotNull);
      // Top-level tag still advertises the max seq (6636).
      expect(release!['tag_name'], 'v1.0.1-debug.6636+aaaaaaa');
      final Map<String, dynamic> asset = (release['assets'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .single;
      expect(asset['version'], '1.0.1-debug.6621');
      expect(asset['tag'], 'v1.0.1-debug.6621+bbbbbbb');
      expect(asset['releaseSequence'], 6621);
      expect(UpdateAsset.fromReleaseAsset(asset).version, '1.0.1-debug.6621');
    });
  });

  group('selection judges by SELECTED asset version, not top-level tag', () {
    Future<UpdateReleaseSelection?> selectAndroid(
      String manifestBody,
      String currentVersion,
    ) async {
      final Map<String, dynamic> release =
          buildReleaseFromManifest(manifestBody)!;
      return selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[release],
        currentVersion: currentVersion,
        channel: UpdateChannel.debug,
        updater: AndroidUpdater(abiProvider: () async => <String>['arm64-v8a']),
      );
    }

    test(
        'top 6636 but android asset 6621 == installed -> NO prompt (loop fixed)',
        () async {
      final String body = _debugManifest(
        topVersion: '1.0.1-debug.6636',
        topTag: 'v1.0.1-debug.6636+aaaaaaa',
        assets: <Map<String, dynamic>>[
          _stampedAsset(
            name: 'hibiki-1.0.1-debug.6621-bbbbbbb-debug.apk',
            downloadTag: 'debug-rolling',
            version: '1.0.1-debug.6621',
            tag: 'v1.0.1-debug.6621+bbbbbbb',
            releaseSequence: 6621,
          ),
        ],
      );
      final UpdateReleaseSelection? selected =
          await selectAndroid(body, '1.0.1-debug.6621');
      expect(
        selected,
        isNull,
        reason:
            'installed asset version == advertised platform asset -> not update',
      );
    });

    test('android asset 6640 > installed 6621 -> prompt shows ASSET version',
        () async {
      final String body = _debugManifest(
        topVersion: '1.0.1-debug.6640',
        topTag: 'v1.0.1-debug.6640+aaaaaaa',
        assets: <Map<String, dynamic>>[
          _stampedAsset(
            name: 'hibiki-1.0.1-debug.6640-bbbbbbb-debug.apk',
            downloadTag: 'debug-rolling',
            version: '1.0.1-debug.6640',
            tag: 'v1.0.1-debug.6640+bbbbbbb',
            releaseSequence: 6640,
          ),
        ],
      );
      final UpdateReleaseSelection? selected =
          await selectAndroid(body, '1.0.1-debug.6621');
      expect(selected, isNotNull);
      // Display / download use the asset OWN version, not the top-level tag.
      expect(selected!.version, '1.0.1-debug.6640');
      expect(
        selected.downloadUrl,
        'https://github.com/hajisensai/fushi/releases/download/debug-rolling/hibiki-1.0.1-debug.6640-bbbbbbb-debug.apk',
      );
    });

    test(
        'divergent: top 6636 but android asset itself newer 6640 -> asset wins',
        () async {
      final String body = _debugManifest(
        topVersion: '1.0.1-debug.6636',
        topTag: 'v1.0.1-debug.6636+aaaaaaa',
        assets: <Map<String, dynamic>>[
          _stampedAsset(
            name: 'hibiki-1.0.1-debug.6640-bbbbbbb-debug.apk',
            downloadTag: 'debug-rolling',
            version: '1.0.1-debug.6640',
            releaseSequence: 6640,
          ),
        ],
      );
      final UpdateReleaseSelection? selected =
          await selectAndroid(body, '1.0.1-debug.6621');
      expect(selected, isNotNull);
      expect(selected!.version, '1.0.1-debug.6640');
    });

    test('no per-asset version stamp -> fail-open to top-level tag (legacy)',
        () async {
      final String body = _debugManifest(
        topVersion: '1.0.1-debug.6636',
        topTag: 'v1.0.1-debug.6636+aaaaaaa',
        assets: <Map<String, dynamic>>[
          // No version key: mimic a legacy manifest / GitHub API asset.
          _stampedAsset(
            name: 'hibiki-1.0.1-debug.6636-bbbbbbb-debug.apk',
            downloadTag: 'debug-rolling',
          ),
        ],
      );
      final UpdateReleaseSelection? selected =
          await selectAndroid(body, '1.0.1-debug.6621');
      expect(selected, isNotNull,
          reason: 'must not stall updates on legacy manifests');
      expect(selected!.version, '1.0.1-debug.6636',
          reason: 'fail-open uses the advertised top-level version');
    });

    test('windows setup asset 6621 == installed -> NO prompt', () async {
      final String body = _debugManifest(
        topVersion: '1.0.1-debug.6636',
        topTag: 'v1.0.1-debug.6636+aaaaaaa',
        assets: <Map<String, dynamic>>[
          _stampedAsset(
            name: 'hibiki-1.0.1-debug.6621-windows-setup.exe',
            downloadTag: 'debug-rolling',
            version: '1.0.1-debug.6621',
            releaseSequence: 6621,
          ),
        ],
      );
      final Map<String, dynamic> release = buildReleaseFromManifest(body)!;
      final UpdateReleaseSelection? selected =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[release],
        currentVersion: '1.0.1-debug.6621',
        channel: UpdateChannel.debug,
        updater: WindowsUpdater(),
      );
      expect(selected, isNull,
          reason: 'platform-general: windows keys off own asset version too');
    });
  });
}
