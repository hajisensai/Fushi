/// 漫画全源搜索的**聚合执行层**：源归一化描述 + 逐源运行态 + 有界并发扇出 +
/// Cloudflare 分型。原是 `manga_global_search_page.dart` 的 private sealed
/// class（不可复用、不可单测），抽出为公开 API；页面只留 UI 与导航。
///
/// **为什么不并进 `MediaDiscoverySource`**：漫画源产的是「可打开的作品条目」
/// （点开进详情页/加书架，需要 MihonSourceContext 等强类型上下文），发现源产
/// 的是「可下载的资源」（magnet/直链 payload）——payload、动作、去重语义都
/// 不同，硬塞同一模型只会造出一堆可空字段和特例分支。两者统一的是**聚合语义**
/// （有界并发 `runBoundedTasks` + 渐进逐源交付 + 单源失败不拖垮整页），不是
/// 数据模型。
library;

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_action.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/utils/misc/bounded_concurrency.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 单个来源的搜索进度。
enum MangaSearchRunStatus { loading, done, empty, cloudflare, error }

/// 归一化的来源描述（当前只有 Mihon 一种；保留 sealed 形态以便接新运行时）。
sealed class MangaGlobalSource {
  const MangaGlobalSource();

  String get id;
  String get name;
  String get language;
}

final class MihonGlobalSource extends MangaGlobalSource {
  const MihonGlobalSource(this.row);

  final MangaOnlineSourceRow row;

  @override
  String get id => 'mihon:${row.extensionPackage}:${row.sourceId}';
  @override
  String get name => row.name;
  @override
  String get language => row.language;
}

/// 一个来源在本次搜索里的运行态。
class MangaSourceSearchRun {
  MangaSourceSearchRun(this.source);

  final MangaGlobalSource source;
  MangaSearchRunStatus status = MangaSearchRunStatus.loading;
  Object? error;

  // Mihon
  MihonSourceContext? mihonContext;
  List<MihonManga> mihonItems = const <MihonManga>[];
}

/// 逐源扇出执行器（宿主/运行时注入，可纯 fake 测试）。
///
/// 不是无 UI 依赖：Cloudflare 判型用的 `mihonCloudflareChallenge` 目前定义在
/// widget 文件 `mihon_cloudflare_action.dart` 里，它要认的 `OnlineMangaUnavailable`
/// 所在的 `online_manga_runtime_adapter.dart` 也 import 了登录页。要在无头环境复用
/// 本类，得先把这两个类型 / 函数挪到无 UI 文件。
class MangaGlobalSearchRunner {
  MangaGlobalSearchRunner({required MihonManager? mihonManager})
    : _mihonManager = mihonManager;

  final MihonManager? _mihonManager;

  /// 并发跑一轮搜索：每个来源独立更新 [runs] 里自己那行并回调 [onRunUpdated]；
  /// 一个源慢或失败不拖累其余。[isCancelled] 为真后不再改写任何运行态
  /// （调用方用 generation/mounted 实现，同原页面语义）。
  /// 每个来源一个不同站点，跨站并发安全；[maxConcurrent] 限流只为不让
  /// 几十个源同时打出去。
  Future<void> search({
    required List<MangaSourceSearchRun> runs,
    required String query,
    required bool Function() isCancelled,
    required void Function() onRunUpdated,
    int maxConcurrent = 6,
  }) {
    // 被 Cloudflare 拦下的源按 [MangaSearchRunStatus.cloudflare] 标成徽标，用户
    // 点进源页再交互解题（Mihon 的解题总是用户点按钮触发，扇出里不会弹页）。
    return runBoundedTasks(
      runs,
      maxConcurrent: maxConcurrent,
      task: (MangaSourceSearchRun run) =>
          _runOne(run, query, isCancelled, onRunUpdated),
    );
  }

  Future<void> _runOne(
    MangaSourceSearchRun run,
    String query,
    bool Function() isCancelled,
    void Function() onRunUpdated,
  ) async {
    // 排队期间这一轮已被取消（换了关键词 / 离开页面）：还没发出的源不再发。
    // 已发出的搜索没有请求号，取消不了，只在回来后丢弃结果。
    if (isCancelled()) return;
    try {
      switch (run.source) {
        case MihonGlobalSource(:final MangaOnlineSourceRow row):
          final MihonManager manager = _mihonManager!;
          final MihonSourceContext context = await manager.contextForSource(
            row,
          );
          final MihonMangaPage page = await manager.runtime.search(
            context.extension,
            context.source,
            page: 1,
            query: query,
            preferences: context.preferences,
          );
          if (isCancelled()) return;
          run.mihonContext = context;
          run.mihonItems = page.items;
          run.status = page.items.isEmpty
              ? MangaSearchRunStatus.empty
              : MangaSearchRunStatus.done;
      }
    } on Object catch (error, stack) {
      if (isCancelled()) return;
      // 2026-10 体验优化：页面只给归一后的短句，原始异常在这里落日志。
      ErrorLogService.instance.log(
        'MangaGlobalSearch[${run.source.name}]',
        error,
        stack,
      );
      run.error = error;
      run.status = isCloudflareError(error)
          ? MangaSearchRunStatus.cloudflare
          : MangaSearchRunStatus.error;
    }
    if (!isCancelled()) onRunUpdated();
  }

  /// Cloudflare 保护判型：先按类型（[MihonCloudflareChallengeException] 可能
  /// 包在阶段 / 运行时异常的 cause 链里，它的文案是 `CLOUDFLARE_CHALLENGE_REQUIRED`，
  /// 按文案匹配不到），再按文案兜底（扩展自己抛的纯文本错误）。
  static bool isCloudflareError(Object error) =>
      mihonCloudflareChallenge(error) != null ||
      '$error'.contains('Cloudflare');
}
