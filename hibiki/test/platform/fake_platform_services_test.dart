import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/platform/platform_services.dart';
import 'package:hibiki_platform/hibiki_platform.dart';

import '../helpers/fake_platform_services.dart';

void main() {
  group('FakeLifecycleService', () {
    test('restartApp sets restartCalled', () async {
      final svc = FakeLifecycleService();
      expect(svc.restartCalled, isFalse);
      await svc.restartApp();
      expect(svc.restartCalled, isTrue);
    });

    test('exitApp sets exitCalled', () async {
      final svc = FakeLifecycleService();
      expect(svc.exitCalled, isFalse);
      await svc.exitApp();
      expect(svc.exitCalled, isTrue);
    });

    test('moveTaskToBack sets moveTaskToBackCalled', () async {
      final svc = FakeLifecycleService();
      expect(svc.moveTaskToBackCalled, isFalse);
      await svc.moveTaskToBack();
      expect(svc.moveTaskToBackCalled, isTrue);
    });

    test('supportsRestart reflects supportsRestartValue', () {
      final svc = FakeLifecycleService()..supportsRestartValue = true;
      expect(svc.supportsRestart, isTrue);
    });
  });

  group('FakeClipboardService', () {
    test('copyToClipboard records last copied text', () async {
      final svc = FakeClipboardService();
      expect(svc.lastCopied, isNull);
      await svc.copyToClipboard('hello');
      expect(svc.lastCopied, equals('hello'));
    });

    test('copyToClipboard overwrites previous value', () async {
      final svc = FakeClipboardService();
      await svc.copyToClipboard('first');
      await svc.copyToClipboard('second');
      expect(svc.lastCopied, equals('second'));
    });

    test('shouldShowCopyToast reflects shouldShowCopyToastValue', () {
      final svc = FakeClipboardService()..shouldShowCopyToastValue = true;
      expect(svc.shouldShowCopyToast, isTrue);
    });
  });

  group('FakePermissionService', () {
    test('hasExternalStoragePermission returns hasExternalStorage', () async {
      final svc = FakePermissionService()..hasExternalStorage = false;
      expect(await svc.hasExternalStoragePermission(), isFalse);
    });

    test('requestOverlayPermission sets requestOverlayCalled', () async {
      final svc = FakePermissionService();
      expect(svc.requestOverlayCalled, isFalse);
      await svc.requestOverlayPermission();
      expect(svc.requestOverlayCalled, isTrue);
    });

    test('canDrawOverlays reflects overlaysAllowed', () async {
      final svc = FakePermissionService()..overlaysAllowed = true;
      expect(await svc.canDrawOverlays(), isTrue);
    });
  });

  group('FakeDirectoryService', () {
    test('getHibikiExportDirectory returns exportDir', () async {
      final svc = FakeDirectoryService()..exportDir = '/custom/path';
      expect(await svc.getHibikiExportDirectory(), equals('/custom/path'));
    });

    test('getExternalStorageDirectories returns empty by default', () async {
      expect(
        await FakeDirectoryService().getExternalStorageDirectories(),
        isEmpty,
      );
    });
  });

  group('FakeDeviceInfoService', () {
    test('sdkVersion returns configured sdk', () async {
      final svc = FakeDeviceInfoService()..sdk = 34;
      expect(await svc.sdkVersion, equals(34));
    });

    test('deviceModel returns configured model', () async {
      final svc = FakeDeviceInfoService()..model = 'Pixel 8';
      expect(await svc.deviceModel, equals('Pixel 8'));
    });
  });

  group('fakePlatformServices', () {
    test('returns a valid PlatformServices', () {
      final services = fakePlatformServices();
      expect(services, isA<PlatformServices>());
    });

    test('uses provided FakeLifecycleService instance', () async {
      final lifecycle = FakeLifecycleService();
      final services = fakePlatformServices(lifecycle: lifecycle);
      expect(services.lifecycle, same(lifecycle));
      await services.lifecycle.restartApp();
      expect(lifecycle.restartCalled, isTrue);
    });

    test('uses provided FakeClipboardService instance', () async {
      final clipboard = FakeClipboardService();
      final services = fakePlatformServices(clipboard: clipboard);
      expect(services.clipboard, same(clipboard));
      await services.clipboard.copyToClipboard('test');
      expect(clipboard.lastCopied, equals('test'));
    });

    test('creates fresh fakes when none provided', () {
      final s1 = fakePlatformServices();
      final s2 = fakePlatformServices();
      expect(s1.lifecycle, isNot(same(s2.lifecycle)));
    });

    test('implements PlatformDirectoryService contract', () {
      final services = fakePlatformServices();
      expect(services.directory, isA<PlatformDirectoryService>());
    });

    test('implements PlatformPermissionService contract', () {
      final services = fakePlatformServices();
      expect(services.permission, isA<PlatformPermissionService>());
    });

    test('implements PlatformDeviceInfoService contract', () {
      final services = fakePlatformServices();
      expect(services.deviceInfo, isA<PlatformDeviceInfoService>());
    });
  });
}
