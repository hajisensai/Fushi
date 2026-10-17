import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/updates/host_self_update_service.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/src/utils/misc/update_checker.dart'
    show UpdateDownloadCancelledException;
import 'package:fushi_engine/sync/host_update/host_update_protocol.dart';

/// 反馈 Pp8XPyve0N：host 侧远程自更新状态机（平台门 / 节流 / 各平台结局）。
class _FakePlatformUpdater extends PlatformUpdater {
  _FakePlatformUpdater({required this.inApp});

  final bool inApp;

  @override
  bool get supportsUpdateCheck => true;

  @override
  bool get supportsInAppInstall => inApp;

  @override
  Future<UpdateAsset?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async => null;

  @override
  Future<void> apply(File file, String version) async {}
}

const UpdateAsset _asset = UpdateAsset(
  name: 'fushi-2.11.0-windows-setup.exe',
  url: 'https://example.invalid/fushi-2.11.0-windows-setup.exe',
);

void main() {
  late int resolveCalls;
  late ({String version, UpdateAsset? asset})? latest;
  late Future<void> Function({
    required void Function(double progress) onProgress,
    required void Function() onInstalling,
  })
  installBody;
  late bool allowed;
  late int startedToasts;
  late DateTime now;

  setUp(() {
    resolveCalls = 0;
    latest = (version: '2.11.0', asset: _asset);
    installBody = ({required onProgress, required onInstalling}) async {
      onProgress(0.5);
      onInstalling();
    };
    allowed = true;
    startedToasts = 0;
    now = DateTime(2026, 10, 13, 12);
  });

  AppHostSelfUpdater build({bool inApp = true}) => AppHostSelfUpdater(
    updater: _FakePlatformUpdater(inApp: inApp),
    currentVersion: () => '2.10.0',
    platform: () => 'android',
    isAllowed: () async => allowed,
    resolve: () async {
      resolveCalls++;
      return latest;
    },
    install:
        ({
          required UpdateAsset asset,
          required String version,
          required void Function(double progress) onProgress,
          required void Function() onInstalling,
        }) => installBody(onProgress: onProgress, onInstalling: onInstalling),
    onRemoteUpdateStarted: () => startedToasts++,
    now: () => now,
  );

  /// 让 unawaited 的后台更新跑完。
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('platform gate follows PlatformUpdater.supportsInAppInstall', () async {
    final AppHostSelfUpdater unsupported = build(inApp: false);
    expect(unsupported.platformSupported, isFalse);
    final HostUpdateStatus status = await unsupported.status(refresh: true);
    expect(status.supported, isFalse);
    expect(resolveCalls, 0, reason: '不支持的平台不该去更新源查版本');
  });

  test('refresh reports the latest version and is throttled', () async {
    final AppHostSelfUpdater updater = build();
    final HostUpdateStatus status = await updater.status(refresh: true);
    expect(status.currentVersion, '2.10.0');
    expect(status.latestVersion, '2.11.0');
    expect(status.remoteUpdateAllowed, isTrue);
    await updater.status(refresh: true);
    expect(resolveCalls, 1);
    now = now.add(const Duration(minutes: 2));
    await updater.status(refresh: true);
    expect(resolveCalls, 2);
  });

  test('a release without an installable asset is not offered', () async {
    latest = (version: '2.11.0', asset: null);
    final AppHostSelfUpdater updater = build();
    expect((await updater.status(refresh: true)).latestVersion, isNull);
    await expectLater(
      updater.startUpdate(),
      throwsA(
        isA<HostUpdateRejected>().having(
          (HostUpdateRejected e) => e.denial,
          'denial',
          HostUpdateDenial.noUpdate,
        ),
      ),
    );
  });

  test('no update available rejects with noUpdate', () async {
    latest = null;
    await expectLater(
      build().startUpdate(),
      throwsA(
        isA<HostUpdateRejected>().having(
          (HostUpdateRejected e) => e.denial,
          'denial',
          HostUpdateDenial.noUpdate,
        ),
      ),
    );
  });

  test(
    'start re-resolves, runs install and ends awaiting host confirmation',
    () async {
      final AppHostSelfUpdater updater = build();
      await updater.status(refresh: true);
      final HostUpdateStatus started = await updater.startUpdate();
      expect(resolveCalls, 2, reason: '触发时必须按此刻的更新源重查，不吃节流缓存');
      expect(started.phase, HostUpdatePhase.downloading);
      expect(startedToasts, 1);
      await settle();
      final HostUpdateStatus after = await updater.status();
      expect(after.phase, HostUpdatePhase.awaitingHostConfirmation);
      expect(after.error, isNull);
    },
  );

  test('second trigger while downloading is rejected as busy', () async {
    final Completer<void> gate = Completer<void>();
    installBody = ({required onProgress, required onInstalling}) async {
      onProgress(0.25);
      await gate.future;
    };
    final AppHostSelfUpdater updater = build();
    await updater.startUpdate();
    await settle();
    final HostUpdateStatus mid = await updater.status();
    expect(mid.phase, HostUpdatePhase.downloading);
    expect(mid.progress, 0.25);
    await expectLater(
      updater.startUpdate(),
      throwsA(
        isA<HostUpdateRejected>().having(
          (HostUpdateRejected e) => e.denial,
          'denial',
          HostUpdateDenial.busy,
        ),
      ),
    );
    gate.complete();
    await settle();
  });

  test('missing Android install permission waits for the host user', () async {
    installBody = ({required onProgress, required onInstalling}) async {
      onInstalling();
      throw PlatformException(code: 'INSTALL_PERMISSION_REQUIRED');
    };
    final AppHostSelfUpdater updater = build();
    await updater.startUpdate();
    await settle();
    final HostUpdateStatus status = await updater.status();
    expect(status.phase, HostUpdatePhase.awaitingHostConfirmation);
    expect(status.error, kHostUpdateErrorInstallPermission);
  });

  test('install failure is reported as failed with a reason', () async {
    installBody = ({required onProgress, required onInstalling}) async {
      throw StateError('disk full');
    };
    final AppHostSelfUpdater updater = build();
    await updater.startUpdate();
    await settle();
    final HostUpdateStatus status = await updater.status();
    expect(status.phase, HostUpdatePhase.failed);
    expect(status.error, contains('disk full'));
  });

  test(
    'PR #2100 review: cancelling on the host ends the round as cancelled',
    () async {
      // host 上的人在下载浮层点「取消」→ 下载引擎抛取消异常。
      installBody = ({required onProgress, required onInstalling}) async {
        onProgress(0.3);
        throw const UpdateDownloadCancelledException();
      };
      final AppHostSelfUpdater updater = build();
      await updater.startUpdate();
      await settle();
      final HostUpdateStatus status = await updater.status();
      expect(status.phase, HostUpdatePhase.failed);
      expect(status.error, kHostUpdateErrorCancelled);
      expect(status.progress, isNull);
      // 本轮结束：可以再触发一次。
      expect(status.canTrigger, isTrue);
    },
  );

  test('host switch is read live', () async {
    final AppHostSelfUpdater updater = build();
    allowed = false;
    expect(await updater.isRemoteUpdateAllowed(), isFalse);
    expect((await updater.status()).remoteUpdateAllowed, isFalse);
  });
}
