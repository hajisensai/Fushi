import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/settings/settings_cli_tasks.dart';
import 'package:fushi/src/updates/app_update_cli.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/utils.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

class _AppModel extends AppModel {
  _AppModel() : super(testPlatformServices());

  @override
  PackageInfo get packageInfo => PackageInfo(
    appName: 'Fushi',
    packageName: 'jp.fushi.test',
    version: '1.0.0',
    buildNumber: '1',
  );

  @override
  bool get updateBetaChannel => false;

  @override
  bool get updateDebugChannel => false;

  @override
  String get updateCustomProxy => '';
}

class _FakeUpdater extends PlatformUpdater {
  _FakeUpdater({this.installable = true});

  final bool installable;
  final List<String> applied = <String>[];

  @override
  bool get supportsUpdateCheck => true;

  @override
  bool get supportsInAppInstall => installable;

  @override
  Future<UpdateAsset?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async => null;

  @override
  Future<void> apply(File file, String version) async {
    applied.add('${file.path}@$version');
  }
}

const HeadlessUpdateCheck _update = HeadlessUpdateCheck(
  version: '1.1.0',
  asset: UpdateAsset(name: 'fushi-setup.exe', url: 'https://x/setup.exe'),
  releaseNotes: '- 新功能',
  htmlUrl: 'https://github.com/x/releases/tag/1.1.0',
);

/// 控制通道的应用自更新三步：检查（不弹对话框）→ 后台下载（进度 / 取消与下载
/// 浮层共用一个令牌）→ 确认安装（交给同一个 PlatformUpdater.apply）。
void main() {
  late Directory tmp;
  late SettingsCliTaskRegistry registry;
  late _AppModel app;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_update_cli_');
    registry = SettingsCliTaskRegistry();
    app = _AppModel();
  });

  tearDown(() {
    debugSetAppUpdateCliBackend(null);
    tmp.deleteSync(recursive: true);
  });

  AppUpdateCliBackend backend({
    required _FakeUpdater updater,
    HeadlessUpdateCheck? update = _update,
    Future<File> Function(
      UpdateDownloadCancellation cancellation,
      void Function(double) onProgress,
    )?
    download,
  }) => AppUpdateCliBackend(
    updater: updater,
    check: (AppModel _) async => update,
    download:
        (
          AppModel _,
          HeadlessUpdateCheck u,
          UpdateDownloadCancellation cancellation,
          void Function(double) onProgress,
        ) async {
          if (download != null) return download(cancellation, onProgress);
          onProgress(0.5);
          final File file = File('${tmp.path}/${u.asset!.name}')
            ..writeAsStringSync('pkg');
          onProgress(1);
          return file;
        },
  );

  test('check：已是最新 / 有新版带说明与可安装标记', () async {
    debugSetAppUpdateCliBackend(backend(updater: _FakeUpdater(), update: null));
    final Map<String, Object?> latest = await checkAppUpdateForCli(app);
    expect(latest['updateAvailable'], isFalse);
    expect(latest['currentVersion'], '1.0.0');
    expect(latest['channel'], 'stable');

    debugSetAppUpdateCliBackend(backend(updater: _FakeUpdater()));
    final Map<String, Object?> found = await checkAppUpdateForCli(app);
    expect(found['updateAvailable'], isTrue);
    expect(found['version'], '1.1.0');
    expect(found['releaseNotes'], '- 新功能');
    expect(found['installable'], isTrue);
  });

  test('check：不能应用内安装的平台给出下载页', () async {
    debugSetAppUpdateCliBackend(
      backend(updater: _FakeUpdater(installable: false)),
    );
    final Map<String, Object?> found = await checkAppUpdateForCli(app);
    expect(found['installable'], isFalse);
    expect(found['downloadPage'], 'https://github.com/x/releases/tag/1.1.0');
    expect(
      () => startAppUpdateDownloadForCli(app, registry: registry),
      throwsStateError,
    );
  });

  test('download → install：装的是下载好的那个包，安装任务进入提交阶段', () async {
    final _FakeUpdater updater = _FakeUpdater();
    debugSetAppUpdateCliBackend(backend(updater: updater));
    expect(
      () => installAppUpdateForCli(app, registry: registry),
      throwsStateError,
      reason: '没下载就安装要拒绝',
    );
    final SettingsCliTask download = startAppUpdateDownloadForCli(
      app,
      registry: registry,
    );
    expect(
      () => startAppUpdateDownloadForCli(app, registry: registry),
      throwsStateError,
      reason: '同时只能有一个下载',
    );
    await download.whenDone;
    expect(download.status, SettingsCliTaskStatus.done);
    expect(download.result!['version'], '1.1.0');
    expect(appUpdateDownloadedForCli?.version, '1.1.0');

    final SettingsCliTask install = installAppUpdateForCli(
      app,
      registry: registry,
    );
    expect(install.toJson()['cancellable'], isFalse);
    expect(install.detail['version'], '1.1.0');
    expect(updater.applied, isEmpty, reason: '应答送出之前不交给安装器');
    await install.whenDone;
    expect(install.status, SettingsCliTaskStatus.done);
    expect(updater.applied.single, endsWith('fushi-setup.exe@1.1.0'));
  });

  test('cancel：触发下载令牌，任务以 cancelled 结束、不留可安装的包', () async {
    final Completer<File> pending = Completer<File>();
    debugSetAppUpdateCliBackend(
      backend(
        updater: _FakeUpdater(),
        download: (UpdateDownloadCancellation cancellation, _) {
          cancellation.registerAbort(
            () =>
                pending.completeError(const UpdateDownloadCancelledException()),
          );
          return pending.future;
        },
      ),
    );
    final SettingsCliTask download = startAppUpdateDownloadForCli(
      app,
      registry: registry,
    );
    await pumpEventQueue();
    final Map<String, Object?> cancelled = cancelAppUpdateDownloadForCli(
      registry: registry,
    );
    expect(cancelled['outcome'], 'requested');
    await download.whenDone;
    expect(download.status, SettingsCliTaskStatus.cancelled);
    expect(appUpdateDownloadedForCli, isNull);
    expect(
      () => cancelAppUpdateDownloadForCli(registry: registry),
      throwsStateError,
    );
  });
}
