/// 互联 host 侧的远程自更新（反馈 Pp8XPyve0N）：把已配对 client 的「更新主机」请求
/// 落到本机现有的自更新流程上（[HeadlessUpdateFlow.resolveAvailableUpdate] 查版本、
/// [HeadlessUpdateFlow.downloadAndApply] 下载并交给 [PlatformUpdater.apply]）。
///
/// 下载期间 host 上显示与本机「检查更新」同一个下载浮层（进度 + 「取消」+ 「隐藏」）：
/// host 上正在阅读 / 播放的人能看见是别的设备发起了更新，并能在安装器接班退出本进程
/// 之前取消；取消后本轮以 `failed` / `cancelled` 结束，client 随即看到。
///
/// 平台门只有一处：[PlatformUpdater.supportsInAppInstall]（Android / Windows / macOS
/// 能应用内安装，iOS / Linux 不能）——与本机「检查更新」能不能下载安装是同一个判据。
///
/// 各平台的结局：
///   * 桌面：apply 由安装器接班、本进程退出并在安装后重启（client 看到的是连接断开
///     → 重连后版本号变了）；
///   * Android：apply 拉起系统安装确认 → 阶段 awaitingHostConfirmation，必须有人在
///     host 设备上点「安装」；缺「安装未知应用」权限时系统把 host 带到授权页，同样
///     停在 awaitingHostConfirmation（error = install_permission）。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart' show PlatformException;
import 'package:fushi_engine/sync/host_update/host_update_protocol.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/updates/app_update_check.dart';
import 'package:fushi/src/utils/misc/build_version.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/utils.dart';

/// 查本平台可装新版本的函数（测试缝；生产 = [HeadlessUpdateFlow.resolveAvailableUpdate]）。
typedef HostUpdateResolver =
    Future<({String version, UpdateAsset? asset})?> Function();

/// 下载并安装的函数（测试缝；生产 = [HeadlessUpdateFlow.downloadAndApply]）。
typedef HostUpdateInstaller =
    Future<void> Function({
      required UpdateAsset asset,
      required String version,
      required void Function(double progress) onProgress,
      required void Function() onInstalling,
    });

/// 本机能否被已配对设备远程更新（平台门）。判据就是本机自更新能否应用内安装——
/// 设置页开关的可见性与 host 端点的拒绝走同一个 [PlatformUpdater.supportsInAppInstall]。
bool hostRemoteUpdatePlatformSupported() =>
    updaterForCurrentPlatform().supportsInAppInstall;

/// `error` 字段里「Android 需要先授予安装未知应用权限」的取值。
const String kHostUpdateErrorInstallPermission = 'install_permission';

/// `error` 字段里「host 上的人在下载浮层取消了这次更新」的取值。
const String kHostUpdateErrorCancelled = 'cancelled';

class AppHostSelfUpdater implements HostSelfUpdater {
  AppHostSelfUpdater({
    required PlatformUpdater updater,
    required String Function() currentVersion,
    required String Function() platform,
    required Future<bool> Function() isAllowed,
    required HostUpdateResolver resolve,
    required HostUpdateInstaller install,
    void Function()? onRemoteUpdateStarted,
    DateTime Function()? now,
    Duration refreshThrottle = const Duration(minutes: 1),
  }) : _updater = updater,
       _currentVersion = currentVersion,
       _platform = platform,
       _isAllowed = isAllowed,
       _resolve = resolve,
       _install = install,
       _onRemoteUpdateStarted = onRemoteUpdateStarted,
       _now = now ?? DateTime.now,
       _refreshThrottle = refreshThrottle;

  final PlatformUpdater _updater;
  final String Function() _currentVersion;
  final String Function() _platform;
  final Future<bool> Function() _isAllowed;
  final HostUpdateResolver _resolve;
  final HostUpdateInstaller _install;
  final void Function()? _onRemoteUpdateStarted;
  final DateTime Function() _now;
  final Duration _refreshThrottle;

  ({String version, UpdateAsset? asset})? _latest;
  DateTime? _lastResolvedAt;
  Future<void>? _resolving;
  HostUpdatePhase _phase = HostUpdatePhase.idle;
  double? _progress;
  String? _error;

  @override
  bool get platformSupported => _updater.supportsInAppInstall;

  @override
  Future<bool> isRemoteUpdateAllowed() => _isAllowed();

  @override
  Future<HostUpdateStatus> status({bool refresh = false}) async {
    if (refresh && platformSupported && !_phase.isBusy) {
      await _refreshLatest();
    }
    return _snapshot(await _isAllowed());
  }

  @override
  Future<HostUpdateStatus> startUpdate() async {
    if (_phase.isBusy) throw const HostUpdateRejected(HostUpdateDenial.busy);
    // 触发时一定按此刻的更新源重查（不吃节流缓存）：客户端看到的「有新版」可能已过时。
    await _refreshLatest(force: true);
    final ({String version, UpdateAsset? asset})? latest = _latest;
    final UpdateAsset? asset = latest?.asset;
    if (latest == null || asset == null) {
      throw const HostUpdateRejected(HostUpdateDenial.noUpdate);
    }
    if (HeadlessUpdateFlow.isActive(latest.version)) {
      throw const HostUpdateRejected(HostUpdateDenial.busy);
    }
    _phase = HostUpdatePhase.downloading;
    _progress = 0;
    _error = null;
    _onRemoteUpdateStarted?.call();
    // 先取快照再启动：_run 同步跑到第一个 await 之前就可能已经推进阶段，响应应当
    // 描述「刚接受触发」那一刻，而不是被后台进度抢先改掉的状态。
    final HostUpdateStatus accepted = _snapshot(true);
    unawaited(_run(asset, latest.version));
    return accepted;
  }

  Future<void> _run(UpdateAsset asset, String version) async {
    try {
      await _install(
        asset: asset,
        version: version,
        onProgress: (double value) => _progress = value,
        onInstalling: () {
          _phase = HostUpdatePhase.installing;
          _progress = null;
        },
      );
      // 桌面 apply 成功即由安装器接班、本进程退出，走不到这里；能正常返回的只有
      // Android——系统安装确认已在 host 上弹出，要有人点「安装」。
      _phase = HostUpdatePhase.awaitingHostConfirmation;
    } on PlatformException catch (e, stack) {
      if (e.code == 'INSTALL_PERMISSION_REQUIRED') {
        // 原生侧已把 host 带去「安装未知应用」授权页：有人在 host 上授权后，本机下次
        // 「检查更新」会复用已下载的安装包。
        _phase = HostUpdatePhase.awaitingHostConfirmation;
        _error = kHostUpdateErrorInstallPermission;
        return;
      }
      _fail(e, stack);
    } catch (e, stack) {
      _fail(e, stack);
    }
  }

  void _fail(Object e, StackTrace stack) {
    // host 上的人在下载浮层点了「取消」：是人的决定，不是故障，不进报错日志。
    final bool cancelled = e is UpdateDownloadCancelledException;
    if (!cancelled) {
      ErrorLogService.instance.log('HostSelfUpdate.run', e, stack);
    }
    _phase = HostUpdatePhase.failed;
    _progress = null;
    _error = cancelled ? kHostUpdateErrorCancelled : '$e';
  }

  /// 节流地重查最新版本；并发调用合并成一次。查失败只留痕，保留上一次结果。
  Future<void> _refreshLatest({bool force = false}) {
    final DateTime? last = _lastResolvedAt;
    if (!force && last != null && _now().difference(last) < _refreshThrottle) {
      return Future<void>.value();
    }
    return _resolving ??= () async {
      try {
        _latest = await _resolve();
        _lastResolvedAt = _now();
      } catch (e, stack) {
        ErrorLogService.instance.log('HostSelfUpdate.resolve', e, stack);
      } finally {
        _resolving = null;
      }
    }();
  }

  HostUpdateStatus _snapshot(bool allowed) {
    final ({String version, UpdateAsset? asset})? latest = _latest;
    return HostUpdateStatus(
      currentVersion: _currentVersion(),
      platform: _platform(),
      supported: platformSupported,
      remoteUpdateAllowed: allowed,
      // 本平台没有可应用内安装的包时，对远程更新而言等于「没有可装的新版」。
      latestVersion: latest?.asset == null ? null : latest!.version,
      phase: _phase,
      progress: _progress,
      error: _error,
    );
  }
}

/// 生产装配：版本 / 通道 / 代理都按**每次调用时**的 app 设置现读（用户改了更新通道
/// 不必重启互联服务）。
AppHostSelfUpdater createAppHostSelfUpdater(AppModel appModel) {
  final PlatformUpdater updater = updaterForCurrentPlatform();
  String currentVersion() =>
      resolveCurrentAppVersion(appModel.packageInfo.version);
  return AppHostSelfUpdater(
    updater: updater,
    currentVersion: currentVersion,
    platform: () => Platform.operatingSystem,
    isAllowed: () =>
        SyncRepository(appModel.database).isInterconnectRemoteUpdateEnabled(),
    resolve: () => HeadlessUpdateFlow.resolveAvailableUpdate(
      currentVersion: currentVersion(),
      currentBuildNumber: appModel.packageInfo.buildNumber,
      channel: appUpdateChannelOf(appModel),
      customProxy: appModel.updateCustomProxy,
      updater: updater,
    ),
    install:
        ({
          required UpdateAsset asset,
          required String version,
          required void Function(double progress) onProgress,
          required void Function() onInstalling,
        }) => HeadlessUpdateFlow.downloadAndApply(
          asset: asset,
          version: version,
          updater: updater,
          customProxy: appModel.updateCustomProxy,
          // 与本机「检查更新」同一个下载浮层（进度 / 取消 / 隐藏），挂在根 Navigator 的
          // Overlay 上：任意界面都看得见。app 还没有界面（无根 Navigator）时为 null，
          // 照常下载。
          overlay: appModel.navigatorKey.currentState?.overlay,
          onProgress: onProgress,
          onInstalling: onInstalling,
        ),
    // host 上的人要知道「是别的设备让本机更新的」，否则突然退出 / 弹安装框像是故障。
    onRemoteUpdateStarted: () => FushiToast.show(
      msg: t.interconnect_host_update_remote_started,
      severity: ToastSeverity.info,
    ),
  );
}
