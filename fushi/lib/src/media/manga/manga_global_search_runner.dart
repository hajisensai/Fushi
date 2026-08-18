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

import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/utils/misc/bounded_concurrency.dart';

/// 单个来源的搜索进度。
enum MangaSearchRunStatus { loading, done, empty, cloudflare, error }

/// 归一化的来源描述，抹平 Mihon / Aidoku 两套模型。
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

final class AidokuGlobalSource extends MangaGlobalSource {
  const AidokuGlobalSource(this.package);

  final AidokuInstalledPackage package;

  @override
  String get id => 'aidoku:${package.id}';
  @override
  String get name => package.name;
  @override
  String get language =>
      package.languages.isEmpty ? '' : package.languages.first;
}

/// 一个来源在本次搜索里的运行态。Mihon / Aidoku 字段互斥，由 [source] 类型决定。
class MangaSourceSearchRun {
  MangaSourceSearchRun(this.source);

  final MangaGlobalSource source;
  MangaSearchRunStatus status = MangaSearchRunStatus.loading;
  Object? error;

  // Mihon
  MihonSourceContext? mihonContext;
  List<MihonManga> mihonItems = const <MihonManga>[];

  // Aidoku
  List<Map<String, Object?>> aidokuItems = const <Map<String, Object?>>[];
}

/// 逐源扇出执行器（无 UI 依赖，宿主/运行时注入，可纯 fake 测试）。
class MangaGlobalSearchRunner {
  MangaGlobalSearchRunner({
    required MihonManager? mihonManager,
    required AidokuRuntime? Function() resolveAidokuRuntime,
  })  : _mihonManager = mihonManager,
        _resolveAidokuRuntime = resolveAidokuRuntime;

  final MihonManager? _mihonManager;
  final AidokuRuntime? Function() _resolveAidokuRuntime;

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
    try {
      switch (run.source) {
        case MihonGlobalSource(:final MangaOnlineSourceRow row):
          final MihonManager manager = _mihonManager!;
          final MihonSourceContext context =
              await manager.contextForSource(row);
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
        case AidokuGlobalSource(:final AidokuInstalledPackage package):
          final AidokuRuntime? runtime = _resolveAidokuRuntime();
          if (runtime == null) {
            throw const AidokuRuntimeException(
              'RUNTIME_UNAVAILABLE',
              'The Aidoku runtime is unavailable on this platform',
            );
          }
          final Map<String, Object?> result = await runtime.search(
            package.packagePath,
            query: query,
            page: 1,
          );
          final List<Map<String, Object?>> entries =
              (result['entries'] as List<Object?>? ?? const <Object?>[])
                  .whereType<Map<Object?, Object?>>()
                  .map((Map<Object?, Object?> value) =>
                      value.cast<String, Object?>())
                  .where((Map<String, Object?> value) =>
                      value['key']?.toString().isNotEmpty ?? false)
                  .toList(growable: false);
          if (isCancelled()) return;
          run.aidokuItems = entries;
          run.status = entries.isEmpty
              ? MangaSearchRunStatus.empty
              : MangaSearchRunStatus.done;
      }
    } on Object catch (error) {
      if (isCancelled()) return;
      run.error = error;
      run.status = isCloudflareError(error)
          ? MangaSearchRunStatus.cloudflare
          : MangaSearchRunStatus.error;
    }
    if (!isCancelled()) onRunUpdated();
  }

  /// Cloudflare 保护判型（Aidoku 结构化错误码 + 文案兜底）。
  static bool isCloudflareError(Object error) {
    if (error is AidokuRuntimeException) {
      return error.code == 'CLOUDFLARE_CHALLENGE';
    }
    final String text = '$error';
    return text.contains('Cloudflare') || text.contains('CF challenge');
  }
}
