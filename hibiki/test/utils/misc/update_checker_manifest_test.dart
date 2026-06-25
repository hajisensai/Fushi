import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

/// TODO-705: beta/debug channels read the CI-published mirror manifest on the
/// update-manifest orphan branch (latest-<channel>.json), rebuilt into an
/// API-isomorphic release map fed back into the existing asset-selection chain.
String _manifestJson({
  int schemaVersion = 1,
  String tag = 'v0.10.1-beta.162',
  String version = '0.10.1-beta.162',
  String channel = 'beta',
  bool prerelease = true,
  String notes = 'Beta build notes',
  List<Map<String, dynamic>>? assets,
}) {
  return jsonEncode(<String, dynamic>{
    'schemaVersion': schemaVersion,
    'version': version,
    'tag': tag,
    'channel': channel,
    'prerelease': prerelease,
    'notes': notes,
    'assets': assets ??
        <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'hibiki-0.10.1-arm64-v8a.apk',
            'browser_download_url':
                'https://github.com/hdjsadgfwtg/hibiki/releases/download/$tag/hibiki-0.10.1-arm64-v8a.apk',
          },
          <String, dynamic>{
            'name': 'hibiki-0.10.1-windows-setup.exe',
            'browser_download_url':
                'https://github.com/hdjsadgfwtg/hibiki/releases/download/$tag/hibiki-0.10.1-windows-setup.exe',
          },
        ],
  });
}

void main() {
  group('manifestUrlForChannel (pure)', () {
    test('beta/debug return their raw.githubusercontent manifest URLs', () {
      expect(manifestUrlForChannel(UpdateChannel.beta), kBetaManifestUrl);
      expect(manifestUrlForChannel(UpdateChannel.debug), kDebugManifestUrl);
      expect(
        kBetaManifestUrl,
        'https://raw.githubusercontent.com/hdjsadgfwtg/hibiki/update-manifest/latest-beta.json',
      );
      expect(
        kDebugManifestUrl,
        'https://raw.githubusercontent.com/hdjsadgfwtg/hibiki/update-manifest/latest-debug.json',
      );
    });

    test('stable does not use a manifest (302 path), returns null', () {
      expect(manifestUrlForChannel(UpdateChannel.stable), isNull);
    });
  });

  group('buildReleaseFromManifest (manifest to API-isomorphic release map)',
      () {
    test('valid beta manifest rebuilds tag/prerelease/body/assets', () {
      final Map<String, dynamic>? release =
          buildReleaseFromManifest(_manifestJson());
      expect(release, isNotNull);
      expect(release!['tag_name'], 'v0.10.1-beta.162');
      expect(release['prerelease'], isTrue);
      expect(release['draft'], isFalse);
      expect(release['body'], 'Beta build notes');
      expect(release['html_url'], contains('/releases/tag/v0.10.1-beta.162'));

      final List<dynamic> assets = release['assets'] as List<dynamic>;
      expect(assets.length, 2);
      final Map<String, dynamic> apk = assets
          .cast<Map<String, dynamic>>()
          .firstWhere((Map<String, dynamic> a) =>
              (a['name'] as String).endsWith('.apk'));
      // downstream UpdateAsset.fromReleaseAsset only reads browser_download_url.
      expect(
        apk['browser_download_url'],
        'https://github.com/hdjsadgfwtg/hibiki/releases/download/v0.10.1-beta.162/hibiki-0.10.1-arm64-v8a.apk',
      );
    });

    test('rebuilt release matches the beta channel', () {
      final Map<String, dynamic> release =
          buildReleaseFromManifest(_manifestJson())!;
      expect(releaseMatchesUpdateChannel(release, UpdateChannel.beta), isTrue);
    });

    test('Android updater picks apk by ABI from rebuilt release', () async {
      final Map<String, dynamic> release =
          buildReleaseFromManifest(_manifestJson())!;
      final List<Map<String, dynamic>> assets =
          (release['assets'] as List<dynamic>).cast<Map<String, dynamic>>();
      final UpdateAsset? asset = await AndroidUpdater(
        abiProvider: () async => <String>['arm64-v8a'],
      ).selectAsset(assets, channel: UpdateChannel.beta);
      expect(
        asset?.url,
        'https://github.com/hdjsadgfwtg/hibiki/releases/download/v0.10.1-beta.162/hibiki-0.10.1-arm64-v8a.apk',
      );
    });

    test('debug manifest (prerelease true, debug tag) rebuilds and matches',
        () {
      final Map<String, dynamic> release = buildReleaseFromManifest(
        _manifestJson(
          tag: 'v0.10.1-debug.162+abc1234',
          version: '0.10.1-debug.162',
          channel: 'debug',
          assets: <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'hibiki-0.10.1-abc1234-debug.apk',
              'browser_download_url':
                  'https://github.com/hdjsadgfwtg/hibiki/releases/download/v0.10.1-debug.162+abc1234/hibiki-0.10.1-abc1234-debug.apk',
            },
          ],
        ),
      )!;
      expect(release['tag_name'], 'v0.10.1-debug.162+abc1234');
      expect(releaseMatchesUpdateChannel(release, UpdateChannel.debug), isTrue);
    });

    test('unrecognized schemaVersion (future) safely returns null', () {
      expect(buildReleaseFromManifest(_manifestJson(schemaVersion: 2)), isNull);
    });

    test('missing tag field safely returns null', () {
      final String body = jsonEncode(<String, dynamic>{
        'schemaVersion': 1,
        'prerelease': true,
        'assets': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'x.apk',
            'browser_download_url': 'https://example.com/x.apk',
          },
        ],
      });
      expect(buildReleaseFromManifest(body), isNull);
    });

    test('empty assets or no valid browser_download_url returns null', () {
      expect(
        buildReleaseFromManifest(
            _manifestJson(assets: const <Map<String, dynamic>>[])),
        isNull,
      );
      final String missingUrl = jsonEncode(<String, dynamic>{
        'schemaVersion': 1,
        'tag': 'v0.10.1-beta.162',
        'prerelease': true,
        'assets': <Map<String, dynamic>>[
          <String, dynamic>{'name': 'x.apk'},
        ],
      });
      expect(buildReleaseFromManifest(missingUrl), isNull);
    });

    test('malformed JSON or non-object top-level safely returns null', () {
      expect(buildReleaseFromManifest('not json {{{'), isNull);
      expect(buildReleaseFromManifest('[1,2,3]'), isNull);
      expect(buildReleaseFromManifest('NOTOBJ'), isNull);
    });

    test('missing notes degrades body to empty string (no throw)', () {
      final String body = jsonEncode(<String, dynamic>{
        'schemaVersion': 1,
        'tag': 'v0.10.1-beta.162',
        'prerelease': true,
        'assets': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'x.apk',
            'browser_download_url': 'https://example.com/x.apk',
          },
        ],
      });
      expect(buildReleaseFromManifest(body)!['body'], '');
    });
  });

  group('manifest candidate fallback (direct-first + mirror prefixes)', () {
    test('beta manifest URL candidates: direct first, then gh proxy prefixes',
        () {
      final List<String> urls =
          updateCheckUrls(manifestUrlForChannel(UpdateChannel.beta)!);
      expect(urls.first, kBetaManifestUrl, reason: 'direct raw must be first');
      for (final String u in urls.skip(1)) {
        expect(u.endsWith(kBetaManifestUrl), isTrue,
            reason: 'mirror candidate must wrap the direct URL: $u');
        expect(u, isNot(kBetaManifestUrl));
      }
      expect(urls.length, greaterThan(1));
    });

    test(
        'direct-first failure: concurrent race still obtains manifest body '
        'from a mirror (TODO-821)', () async {
      final List<String> attempted = <String>[];
      final List<String> urls =
          updateCheckUrls(manifestUrlForChannel(UpdateChannel.beta)!);
      final String json = _manifestJson();
      final String? body = await fetchFirstSuccessfulBody(
        urls,
        fetch: (String u) async {
          attempted.add(u);
          if (u == urls.first) return null;
          return json;
        },
      );
      expect(body, json);
      // TODO-821：串行逐个尝试改并发竞速 → 全部候选并发发起（不再只试到第 2 个）。
      expect(attempted, containsAll(urls), reason: '并发竞速对所有候选并发发起 fetch');
      expect(attempted.contains(urls.first), isTrue, reason: '直连候选也被发起（虽失败）');
      // 直连失败 → 镜像合法成功胜出，仍能拿到并重建 manifest。
      expect(buildReleaseFromManifest(body!), isNotNull);
    });

    test('all candidates fail returns null (upper layer falls back to API)',
        () async {
      final List<String> urls =
          updateCheckUrls(manifestUrlForChannel(UpdateChannel.debug)!);
      final String? body = await fetchFirstSuccessfulBody(
        urls,
        fetch: (String _) async => null,
      );
      expect(body, isNull);
    });
  });
}
