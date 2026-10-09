/// 视频刮削运行时：协调器 + 任务控制器 + 库内补刮调度器三件套的持有者。
///
/// 原先这三样连同「按配置指纹惰性重建」「关停时等在途任务再释放」都是
/// `HomePage` 的私有状态，别的入口（桌面 CLI 控制通道、互联 host）只能经
/// `AppModel.videoScrapeControllerResolver` 借到控制器，拿不到补刮调度器（待确认
/// 作品清单的唯一数据源）。这里把它们原样搬出来，HomePage 仍是唯一的持有者与
/// 生命周期主人（initState 建、dispose 关），并把自己登记到
/// [AppModel.videoScrapeRuntime]；行为与搬家前逐行一致。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/ai/ai_video_identity_assistant.dart';
import 'package:fushi_engine/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_library_scrape_sweep.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataProviderKind;
import 'package:fushi_engine/media/video/metadata/video_scrape_sweep_ledger.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';

import 'package:fushi/src/media/video/acquisition/app_video_acquisition_assembly.dart'
    show videoDiscoveryScrapeConfig;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 按当前配置建一个协调器（生产装配见 [VideoScrapeRuntime.forApp]）。
typedef VideoScrapeCoordinatorFactory =
    VideoSourceScrapeCoordinator Function(
      VideoSourceScrapeGlobalConfig config,
      AiVideoIdentityAdvisor aiIdentityAdvisor,
    );

class VideoScrapeRuntime {
  VideoScrapeRuntime({
    required FushiDatabase Function() database,
    required VideoSourceScrapeGlobalConfig Function() readConfig,
    required AiVideoIdentityAdvisor Function() createAiIdentityAdvisor,
    required bool Function() isAutoBackfillEnabled,
    VideoScrapeCoordinatorFactory? createCoordinator,
    VideoScrapeSweepLedger Function()? createLedger,
    VoidCallback? onTaskChanged,
    VoidCallback? onLibraryChanged,
  }) : _database = database,
       _readConfig = readConfig,
       _createAiIdentityAdvisor = createAiIdentityAdvisor,
       _isAutoBackfillEnabled = isAutoBackfillEnabled,
       _createCoordinator =
           createCoordinator ??
           ((
             VideoSourceScrapeGlobalConfig config,
             AiVideoIdentityAdvisor advisor,
           ) => VideoSourceScrapeCoordinator(
             database: database(),
             config: config,
             aiIdentityAdvisor: advisor,
           )),
       _createLedger = createLedger ?? VideoScrapeSweepLedger.new,
       _onTaskChanged = onTaskChanged,
       _onLibraryChanged = onLibraryChanged;

  /// 生产装配：配置与发现页同一份判据（[videoDiscoveryScrapeConfig]：TMDB key
  /// 解析 + 界面语言），离线标题索引打开，补刮账本落盘。
  factory VideoScrapeRuntime.forApp(
    AppModel appModel, {
    VoidCallback? onTaskChanged,
    VoidCallback? onLibraryChanged,
  }) => VideoScrapeRuntime(
    database: () => appModel.database,
    readConfig: () => videoDiscoveryScrapeConfig(
      appModel.prefsRepo,
      uiLocaleTag: appModel.appLocale.toLanguageTag(),
    ),
    // 顾问每次现取偏好里的指派，所以 AI 指派不进配置指纹：用户改了指派
    // 立即生效，不需要重建协调器；判定缓存与补刮账本按它现算的能力键作废。
    createAiIdentityAdvisor: () =>
        PreferencesAiVideoIdentityAdvisor(appModel.prefsRepo),
    isAutoBackfillEnabled: () => appModel.videoLibraryAutoBackfillScrape,
    createCoordinator:
        (
          VideoSourceScrapeGlobalConfig config,
          AiVideoIdentityAdvisor advisor,
        ) => VideoSourceScrapeCoordinator(
          database: appModel.database,
          config: config,
          // 生产装配点显式打开离线标题索引（AniDB 标题包 + Fribb 映射）；默认关是
          // 为了单测不联网。
          enableOfflineTitleIndex: true,
          aiIdentityAdvisor: advisor,
        ),
    // 「自动试过 / 刷新过」落盘跨进程：否则每次启动都把查无/歧义作品重刮一轮、
    // 把哈希查询失败的文件整份重读（用户感知为「每次打开都在重新加载资料」）。
    createLedger: VideoScrapeSweepLedger.inSupportDirectory,
    onTaskChanged: onTaskChanged,
    onLibraryChanged: onLibraryChanged,
  );

  final FushiDatabase Function() _database;
  final VideoSourceScrapeGlobalConfig Function() _readConfig;
  final AiVideoIdentityAdvisor Function() _createAiIdentityAdvisor;
  final bool Function() _isAutoBackfillEnabled;
  final VideoScrapeCoordinatorFactory _createCoordinator;
  final VideoScrapeSweepLedger Function() _createLedger;
  final VoidCallback? _onTaskChanged;

  /// 一批刮削成功结束（库里的作品资料可能变了）时回调；视频库页据此刷新。
  final VoidCallback? _onLibraryChanged;

  VideoSourceScrapeCoordinator? _coordinator;
  VideoSourceScrapeTaskController? _controller;
  String? _configFingerprint;
  VideoLibraryScrapeSweep? _sweep;

  /// 当前已建好的控制器；还没人要过（或已关停）时为 null，**不触发构建**。
  /// 外壳浮钮 / 生命周期中断这类「有就用、没有就算」的读点用它。
  VideoSourceScrapeTaskController? get currentController => _controller;

  /// 当前配置下的控制器：配置指纹变了且没有任务在跑时重建（连同协调器与补刮
  /// 调度器），否则复用。
  VideoSourceScrapeTaskController get controller {
    final VideoSourceScrapeTaskController? existing = _controller;
    final VideoSourceScrapeGlobalConfig config = _readConfig();
    // BUG-2581：指纹统一取 [VideoSourceScrapeGlobalConfig.runtimeFingerprint]，
    // 别再手抄字段——这里曾漏掉哈希开关与 AniDB 账号，填好账号后仍复用旧协调器。
    final String fingerprint = config.runtimeFingerprint;
    if (existing != null &&
        (existing.isBusy || _configFingerprint == fingerprint)) {
      return existing;
    }
    final VoidCallback? listener = _onTaskChanged;
    if (listener != null) existing?.removeListener(listener);
    // 旧一代调度器先断开监听，否则它还会对旧 controller 的通知发起补刮。
    _sweep?.dispose();
    existing?.dispose();
    _coordinator?.close();
    final AiVideoIdentityAdvisor aiIdentityAdvisor = _createAiIdentityAdvisor();
    final VideoSourceScrapeCoordinator coordinator = _createCoordinator(
      config,
      aiIdentityAdvisor,
    );
    _coordinator = coordinator;
    _configFingerprint = fingerprint;
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(coordinator);
    if (listener != null) controller.addListener(listener);
    _controller = controller;
    // 补刮调度器跟随 controller 重建，绝不持有已 dispose 的旧 controller。
    _sweep = VideoLibraryScrapeSweep(
      database: _database(),
      controller: controller,
      isEnabled: _isAutoBackfillEnabled,
      // 与协调器同一份快照：哈希就绪时纯集号文件与已识别作品的新文件也进补刮。
      isHashReady: () => config.anidbHashReady,
      ledger: _createLedger(),
      configFingerprint: fingerprint,
      // 配上 / 换掉 AI 后，之前「试过没认出」的作品立即重新进补刮。
      aiCapabilityKey: () => aiIdentityAdvisor.capabilityKey,
      // Shoko 式增量刷新：TMDB /tv/changes 与库内 TMDB id 求交集，只重刷变过的剧。
      tmdbChangedTvIds: ({required DateTime since}) {
        final VideoMetadataProvider? tmdb = coordinator.registry.provider(
          VideoMetadataProviderKind.tmdb,
        );
        return tmdb is TmdbVideoMetadataProvider && tmdb.isAvailable
            ? tmdb.changedTvShowIds(since: since)
            : Future<Set<int>>.value(const <int>{});
      },
    );
    return controller;
  }

  /// 与 [controller] 同一代的补刮调度器（待确认作品清单的数据源）。
  VideoLibraryScrapeSweep get sweep {
    // 确保 controller/sweep 已按当前配置构建。
    final VideoSourceScrapeTaskController _ = controller;
    return _sweep!;
  }

  /// 观察一个刮削任务：成功结束通知库变更，失败记诊断日志；原样返回 [task]。
  /// 所有入口（库页按钮、扫描后自动刮、桌面控制通道）都经它发起，库页才会刷新。
  Future<SourceScrapeReport> observe(Future<SourceScrapeReport> task) {
    unawaited(
      task.then<void>(
        (SourceScrapeReport _) {
          _onLibraryChanged?.call();
        },
        onError: (Object error, StackTrace stackTrace) {
          ErrorLogService.instance.log(
            'HomePage.videoSourceScrape',
            error,
            stackTrace,
          );
        },
      ),
    );
    return task;
  }

  /// Widget dispose 不能 await；先标记中断并让在途 Future 到下一取消边界，再关闭
  /// HTTP client/ChangeNotifier，避免已释放 notifier 或已关闭 client 被异步任务继续用。
  void shutdown() {
    final VideoSourceScrapeTaskController? controller = _controller;
    final VideoSourceScrapeCoordinator? coordinator = _coordinator;
    _controller = null;
    _coordinator = null;
    _configFingerprint = null;
    // 在途批次之后才结束：调度器先断开，结束通知不能再发起补刮。
    _sweep?.dispose();
    _sweep = null;
    if (controller == null) {
      coordinator?.close();
      return;
    }
    final VoidCallback? listener = _onTaskChanged;
    if (listener != null) controller.removeListener(listener);
    controller.markInterrupted();
    final Future<SourceScrapeReport>? active = controller.activeTask;
    if (active == null) {
      controller.dispose();
      coordinator?.close();
      return;
    }
    unawaited(
      active
          .then<void>((_) {}, onError: (Object _, StackTrace __) {})
          .whenComplete(() {
            controller.dispose();
            coordinator?.close();
          }),
    );
  }
}
