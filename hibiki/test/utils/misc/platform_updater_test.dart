import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';

List<Map<String, dynamic>> _assets(List<String> names) => names
    .map((String n) => <String, dynamic>{
          'name': n,
          'browser_download_url': 'https://example.com/$n',
        })
    .toList();

void main() {
  group('WindowsUpdater.selectAsset', () {
    test('picks the -windows-setup.exe asset', () async {
      final WindowsUpdater u = WindowsUpdater();
      final String? url = await u.selectAsset(_assets(<String>[
        'hibiki-0.4.2-arm64-v8a.apk',
        'hibiki-0.4.2-windows-setup.exe',
        'hibiki-0.4.2-linux-x86_64.AppImage',
      ]));
      expect(url, 'https://example.com/hibiki-0.4.2-windows-setup.exe');
    });

    test('returns null when no windows asset present', () async {
      final WindowsUpdater u = WindowsUpdater();
      final String? url =
          await u.selectAsset(_assets(<String>['hibiki-0.4.2-arm64-v8a.apk']));
      expect(url, isNull);
    });

    test('supports update check and in-app install', () {
      final WindowsUpdater u = WindowsUpdater();
      expect(u.supportsUpdateCheck, isTrue);
      expect(u.supportsInAppInstall, isTrue);
    });
  });

  group('AndroidUpdater.selectAsset', () {
    test('matches device ABI', () async {
      final AndroidUpdater u = AndroidUpdater(
        abiProvider: () async => <String>['arm64-v8a'],
      );
      final String? url = await u.selectAsset(_assets(<String>[
        'hibiki-0.4.2-armeabi-v7a.apk',
        'hibiki-0.4.2-arm64-v8a.apk',
        'hibiki-0.4.2-windows-setup.exe',
      ]));
      expect(url, 'https://example.com/hibiki-0.4.2-arm64-v8a.apk');
    });

    test('falls back to first apk when no ABI match', () async {
      final AndroidUpdater u = AndroidUpdater(
        abiProvider: () async => <String>['x86_64'],
      );
      final String? url = await u.selectAsset(_assets(<String>[
        'hibiki-0.4.2-armeabi-v7a.apk',
        'hibiki-0.4.2-arm64-v8a.apk',
      ]));
      expect(url, 'https://example.com/hibiki-0.4.2-armeabi-v7a.apk');
    });

    test('returns null when no apk asset', () async {
      final AndroidUpdater u =
          AndroidUpdater(abiProvider: () async => <String>[]);
      final String? url = await u
          .selectAsset(_assets(<String>['hibiki-0.4.2-windows-setup.exe']));
      expect(url, isNull);
    });
  });

  group('UnsupportedUpdater', () {
    test('checks but cannot install; selectAsset always null', () async {
      final UnsupportedUpdater u = UnsupportedUpdater();
      expect(u.supportsUpdateCheck, isTrue);
      expect(u.supportsInAppInstall, isFalse);
      expect(await u.selectAsset(_assets(<String>['x.zip'])), isNull);
    });
  });

  group('factory + capability helpers', () {
    test('updaterForCurrentPlatform returns a supported-check updater', () {
      final PlatformUpdater u = updaterForCurrentPlatform();
      expect(u.supportsUpdateCheck, isTrue);
    });

    test('capability helpers agree with the current updater', () {
      final PlatformUpdater u = updaterForCurrentPlatform();
      expect(platformSupportsUpdateCheck(), u.supportsUpdateCheck);
      expect(platformSupportsInAppInstall(), u.supportsInAppInstall);
    });

    test('in-app install capability is android or windows in phase 1', () {
      final bool expected = Platform.isAndroid || Platform.isWindows;
      expect(platformSupportsInAppInstall(), expected);
    });
  });
}
