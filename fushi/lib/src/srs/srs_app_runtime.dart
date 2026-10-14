/// 复习模块（SRS）在 app 进程里的常驻装配：只在模块开着时存在。
///
/// 模块开着时 [srsAppRuntimeProvider] 建一个 [SrsAppRuntime]，它装上：
/// - [SrsAppHost.current]：app 外查词窗 deferred 桥与 Fushi API `/api/srs/*` 的入口；
/// - AnkiConnect v6 兼容端点（Fushi API 根路径）+ `fushiAnkiConnectCompatInstanceId`；
/// - 常规同步的通道后置步骤（`syncChannelPostRunHook`）+ 进入复习 tab 的节流同步；
/// - 自动优化的空闲调度（前台、不在复习页、最多每 6 小时检查一次）。
///
/// 模块关掉（或 provider 被销毁）时 [SrsAppRuntime.dispose] 把上面全部卸下、置回 null：
/// 关着时 app 里没有任何 SRS 定时器、监听、端点或同步步骤（用户硬要求：零行为变化、
/// 零额外开销）。main.dart 在 `appModel.initialise()` 之后 listen 本 provider 保活。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart'
    show fushiAnkiConnectCompatInstanceId;
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_endpoint.dart';
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show homeShellTabNotifier;
import 'package:fushi/src/srs/srs_app_host.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_optimization_scheduler.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/utils.dart';

/// 模块开着时的常驻装配（见文件头）；关着时为 null。
final Provider<SrsAppRuntime?> srsAppRuntimeProvider = Provider<SrsAppRuntime?>(
  (Ref ref) {
    if (!ref.watch(srsModuleEnabledProvider)) return null;
    final AppModel app = ref.read(appProvider);
    final SrsAppRuntime runtime = SrsAppRuntime(
      app: app,
      readStore: () async {
        try {
          return await ref.read(srsStoreProvider.future);
        } catch (e, stack) {
          ErrorLogService.instance.log('SrsAppRuntime.readStore', e, stack);
          return null;
        }
      },
      readMedia: () async {
        try {
          return await ref.read(srsMediaStoreProvider.future);
        } catch (e, stack) {
          ErrorLogService.instance.log('SrsAppRuntime.readMedia', e, stack);
          return null;
        }
      },
      engine: () => ref.read(srsEngineProvider),
      bumpRevision: () => ref.read(srsRevisionProvider.notifier).state++,
    );
    runtime.install();
    ref.onDispose(runtime.dispose);
    return runtime;
  },
);

/// 把 [srsAppRuntimeProvider] 挂到根容器上保活（main.dart 在 initialise 之后调一次）。
void installSrsAppRuntime(ProviderContainer container) {
  container.listen<SrsAppRuntime?>(
    srsAppRuntimeProvider,
    (SrsAppRuntime? previous, SrsAppRuntime? next) {},
    fireImmediately: true,
  );
}

class SrsAppRuntime {
  SrsAppRuntime({
    required this.app,
    required Future<SrsDbStore?> Function() readStore,
    required Future<SrsMediaStore?> Function() readMedia,
    required FsrsEngine? Function() engine,
    required void Function() bumpRevision,
  }) : _readStore = readStore,
       _readMedia = readMedia,
       _engine = engine,
       _bumpRevision = bumpRevision;

  final AppModel app;
  final Future<SrsDbStore?> Function() _readStore;
  final Future<SrsMediaStore?> Function() _readMedia;
  final FsrsEngine? Function() _engine;
  final void Function() _bumpRevision;

  late final SrsSyncScheduler sync = SrsSyncScheduler(
    readStore: _readStore,
    channels: (Future<void> Function(SyncAssetStore backend) body) =>
        runOnAuthenticatedSyncChannels(
          db: app.database,
          body: (SyncBackend backend) => body(backend),
        ),
    onDataChanged: _bumpRevision,
    onNotice: _showSyncNotice,
    readMediaRoot: () async => (await _readMedia())?.root,
  );

  late final SrsOptimizationScheduler optimizer = SrsOptimizationScheduler(
    readStore: _readStore,
    engine: _engine,
    jobFactory: () {
      final FsrsEngine? e = _engine();
      return SrsIsolateOptimizationJob(
        libraryPath: e is FfiFsrsEngine ? e.library.libraryPath : null,
      );
    },
    canRunNow: _idleForOptimization,
    onApplied: _bumpRevision,
  );

  AppLifecycleListener? _lifecycle;
  bool _installed = false;
  SrsAnkiConnectEndpoint? _endpoint;

  /// 装进常规同步的通道后置步骤（卸下时按身份核对，不误卸别人装的）。
  late final SyncChannelPostRunHook _postRunHook = _postRun;

  Future<void> _postRun(SyncBackend backend) async {
    await sync.syncWithBackend(backend);
  }

  /// AnkiConnect 兼容端点的本实例 id（防自环）。
  final String instanceId = srsAnkiConnectNewInstanceId();

  void install() {
    if (_installed) return;
    _installed = true;
    NavigatorState? navigator() => app.navigatorKey.currentState;
    SrsAppHost.current = SrsAppHost(
      readStore: _readStore,
      openNote: (String noteId) => srsPushNoteEditor(navigator(), noteId),
      openBrowse: () => srsPushBrowse(navigator()),
    );
    fushiAnkiConnectCompatInstanceId = instanceId;
    final SrsAnkiConnectEndpoint endpoint = buildAnkiConnectEndpoint();
    _endpoint = endpoint;
    app.srsAnkiConnectEndpoint = endpoint;
    syncChannelPostRunHook = _postRunHook;
    homeShellTabNotifier.addListener(_onHomeTabChanged);
    srsActiveReviewSessions.addListener(_onReviewSessionsChanged);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    optimizer.start();
  }

  void dispose() {
    if (!_installed) return;
    _installed = false;
    homeShellTabNotifier.removeListener(_onHomeTabChanged);
    srsActiveReviewSessions.removeListener(_onReviewSessionsChanged);
    _lifecycle?.dispose();
    _lifecycle = null;
    optimizer.dispose();
    sync.dispose();
    if (identical(syncChannelPostRunHook, _postRunHook)) {
      syncChannelPostRunHook = null;
    }
    if (identical(app.srsAnkiConnectEndpoint, _endpoint)) {
      app.srsAnkiConnectEndpoint = null;
    }
    _endpoint = null;
    if (fushiAnkiConnectCompatInstanceId == instanceId) {
      fushiAnkiConnectCompatInstanceId = null;
    }
    SrsAppHost.current = null;
  }

  /// AnkiConnect v6 兼容端点（Fushi API 根路径）。API key 与 Fushi API 同一个偏好。
  SrsAnkiConnectEndpoint buildAnkiConnectEndpoint() {
    NavigatorState? navigator() => app.navigatorKey.currentState;
    return SrsAnkiConnectEndpoint(
      handler: SrsAnkiConnectHandler(
        store: () async {
          final SrsDbStore? store = await _readStore();
          if (store == null) throw StateError('Fushi review is not available');
          return store;
        },
        instanceId: instanceId,
        apiKey: () {
          final String key = app.yomitanApiKey;
          return key.isEmpty ? null : key;
        },
        onSync: () => unawaited(
          sync.syncNow().catchError((Object e, StackTrace stack) {
            ErrorLogService.instance.log('SrsAnkiConnect.sync', e, stack);
            return 0;
          }),
        ),
        onGuiBrowse: (String? query, List<String> cardIds) async {
          await srsPushBrowse(navigator());
        },
        onGuiEditNote: (String noteId) async {
          await srsPushNoteEditor(navigator(), noteId);
        },
        mediaSink: (String filename, Uint8List bytes) async {
          final SrsMediaStore? media = await _readMedia();
          if (media == null) throw StateError('Fushi review is not available');
          return media.store(filename, bytes);
        },
      ),
    );
  }

  /// 牌组列表「立即同步」：对所有已认证通道跑一轮。返回跑过的通道数（0 = 没配置）。
  Future<int> syncNow() => sync.syncNow();

  void _onHomeTabChanged() {
    if (homeShellTabNotifier.value != HomeTab.srs) return;
    unawaited(
      sync.syncThrottled().catchError((Object e, StackTrace stack) {
        ErrorLogService.instance.log('SrsAppRuntime.tabSync', e, stack);
        return false;
      }),
    );
  }

  void _onReviewSessionsChanged() {
    if (srsActiveReviewSessions.value > 0) optimizer.cancel();
  }

  void _onLifecycle(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) optimizer.cancel();
  }

  /// 自动优化的空闲判据：app 在前台、不在复习页。
  bool _idleForOptimization() {
    if (srsActiveReviewSessions.value > 0) return false;
    final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _showSyncNotice(SrsSyncNotice notice) {
    FushiToast.show(
      msg: switch (notice) {
        SrsSyncNotice.backendUnsupported => t.srs_sync_backend_unsupported,
        SrsSyncNotice.clockSkew => t.srs_sync_clock_skew,
      },
      severity: ToastSeverity.warning,
    );
  }
}
