import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

List<Map<String, dynamic>> _assets(List<String> names) => names
    .map((String name) => <String, dynamic>{
          'name': name,
          'browser_download_url': 'https://example.com/$name',
        })
    .toList(growable: false);

Map<String, dynamic> _release({
  required String tag,
  required bool prerelease,
  required List<String> assets,
  bool draft = false,
}) =>
    <String, dynamic>{
      'tag_name': tag,
      'prerelease': prerelease,
      'draft': draft,
      'html_url': 'https://example.com/releases/$tag',
      'body': 'Release notes for $tag',
      'assets': _assets(assets),
    };

void main() {
  group('selectUpdateReleaseForCurrentPlatform', () {
    test('debug Windows skips a newer APK-only release and selects setup',
        () async {
      final UpdateReleaseSelection? selected =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[
          _release(
            tag: 'v0.5.1-debug.20+abc1234',
            prerelease: true,
            assets: <String>[
              'hibiki-0.5.1-debug.20-abc1234-debug.apk',
            ],
          ),
          _release(
            tag: 'v0.5.1-debug.19+abc1234',
            prerelease: true,
            assets: <String>[
              'hibiki-0.5.1-debug.19-windows-setup.exe',
            ],
          ),
        ],
        currentVersion: '0.5.0',
        channel: UpdateChannel.debug,
        updater: WindowsUpdater(),
      );

      expect(selected, isNotNull);
      expect(selected!.version, '0.5.1-debug.19');
      expect(
        selected.downloadUrl,
        'https://example.com/hibiki-0.5.1-debug.19-windows-setup.exe',
      );
    });

    test('debug Android skips a newer Windows-only release and selects APK',
        () async {
      final UpdateReleaseSelection? selected =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[
          _release(
            tag: 'v0.5.1-debug.20+abc1234',
            prerelease: true,
            assets: <String>[
              'hibiki-0.5.1-debug.20-windows-setup.exe',
            ],
          ),
          _release(
            tag: 'v0.5.1-debug.19+abc1234',
            prerelease: true,
            assets: <String>[
              'hibiki-0.5.1-debug.19-abc1234-debug.apk',
            ],
          ),
        ],
        currentVersion: '0.5.0',
        channel: UpdateChannel.debug,
        updater: AndroidUpdater(
          abiProvider: () async => <String>['arm64-v8a'],
        ),
      );

      expect(selected, isNotNull);
      expect(selected!.version, '0.5.1-debug.19');
      expect(
        selected.downloadUrl,
        'https://example.com/hibiki-0.5.1-debug.19-abc1234-debug.apk',
      );
    });

    test('debug Windows returns null when newer releases are APK-only',
        () async {
      final UpdateReleaseSelection? selected =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[
          _release(
            tag: 'v0.5.5-debug.55+abc1234',
            prerelease: true,
            assets: <String>[
              'hibiki-0.5.5-debug.55-abc1234-debug.apk',
            ],
          ),
        ],
        currentVersion: '0.5.5-debug.4',
        channel: UpdateChannel.debug,
        updater: WindowsUpdater(),
      );

      expect(selected, isNull);
    });

    test('debug Android returns null when newer releases are Windows-only',
        () async {
      final UpdateReleaseSelection? selected =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[
          _release(
            tag: 'v0.5.5-debug.55+abc1234',
            prerelease: true,
            assets: <String>[
              'hibiki-0.5.5-debug.55-windows-setup.exe',
            ],
          ),
        ],
        currentVersion: '0.5.5-debug.4',
        channel: UpdateChannel.debug,
        updater: AndroidUpdater(
          abiProvider: () async => <String>['arm64-v8a'],
        ),
      );

      expect(selected, isNull);
    });

    test('debug combined release lets each platform choose its own asset',
        () async {
      final Map<String, dynamic> combinedRelease = _release(
        tag: 'v0.5.5-debug.55+abc1234',
        prerelease: true,
        assets: <String>[
          'hibiki-0.5.5-debug.55-windows-setup.exe',
          'hibiki-0.5.5-debug.55-abc1234-debug.apk',
        ],
      );

      final UpdateReleaseSelection? windowsSelected =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[combinedRelease],
        currentVersion: '0.5.5-debug.4',
        channel: UpdateChannel.debug,
        updater: WindowsUpdater(),
      );
      final UpdateReleaseSelection? androidSelected =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[combinedRelease],
        currentVersion: '0.5.5-debug.4',
        channel: UpdateChannel.debug,
        updater: AndroidUpdater(
          abiProvider: () async => <String>['arm64-v8a'],
        ),
      );

      expect(
        windowsSelected?.downloadUrl,
        'https://example.com/hibiki-0.5.5-debug.55-windows-setup.exe',
      );
      expect(
        androidSelected?.downloadUrl,
        'https://example.com/hibiki-0.5.5-debug.55-abc1234-debug.apk',
      );
    });

    test('unsupported platforms still fall back to opening the release page',
        () async {
      final UpdateReleaseSelection? selected =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[
          _release(
            tag: 'v0.5.5-debug.55+abc1234',
            prerelease: true,
            assets: <String>[
              'hibiki-0.5.5-debug.55-windows-setup.exe',
            ],
          ),
        ],
        currentVersion: '0.5.5-debug.4',
        channel: UpdateChannel.debug,
        updater: UnsupportedUpdater(),
      );

      expect(selected, isNotNull);
      expect(selected!.version, '0.5.5-debug.55');
      expect(selected.downloadUrl, isNull);
    });

    test('beta channel ignores debug releases with matching platform assets',
        () async {
      final UpdateReleaseSelection? selected =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[
          _release(
            tag: 'v0.5.1-debug.20+abc1234',
            prerelease: true,
            assets: <String>[
              'hibiki-0.5.1-debug.20-windows-setup.exe',
            ],
          ),
          _release(
            tag: 'v0.5.1-beta.19',
            prerelease: true,
            assets: <String>[
              'hibiki-0.5.1-windows-setup.exe',
            ],
          ),
        ],
        currentVersion: '0.5.0',
        channel: UpdateChannel.beta,
        updater: WindowsUpdater(),
      );

      expect(selected, isNotNull);
      expect(selected!.version, '0.5.1-beta.19');
      expect(
        selected.downloadUrl,
        'https://example.com/hibiki-0.5.1-windows-setup.exe',
      );
    });

    test('stable channel ignores prereleases with matching platform assets',
        () async {
      final UpdateReleaseSelection? selected =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[
          _release(
            tag: 'v0.5.2-debug.20+abc1234',
            prerelease: true,
            assets: <String>[
              'hibiki-0.5.2-debug.20-windows-setup.exe',
            ],
          ),
          _release(
            tag: 'v0.5.2',
            prerelease: false,
            assets: <String>[
              'hibiki-0.5.2-windows-setup.exe',
            ],
          ),
        ],
        currentVersion: '0.5.1',
        channel: UpdateChannel.stable,
        updater: WindowsUpdater(),
      );

      expect(selected, isNotNull);
      expect(selected!.version, '0.5.2');
      expect(
        selected.downloadUrl,
        'https://example.com/hibiki-0.5.2-windows-setup.exe',
      );
    });
  });
}
