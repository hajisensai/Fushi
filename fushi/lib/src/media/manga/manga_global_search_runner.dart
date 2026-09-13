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

import 'package:fushi/src/media/manga/aidoku/aidoku_network_session.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_client.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/utils/misc/bounded_concurrency.dart';
import 'package:fushi_engine/sync/manga_sources/host_manga_source_host.dart';

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

/// 「Fushi 互联」合集里对端借出的扩展源（经对端代理搜索）。
final class InterconnectGlobalSource extends MangaGlobalSource {
  const InterconnectGlobalSource(this.source);

  final InterconnectRemoteSource source;

  @override
  String get id => 'interconnect:${source.id}';
  @override
  String get name => source.name;
  @override
  String get language => source.language;
}

/// 一个来源在本次搜索里的运行态。Mihon / Aidoku / 互联字段互斥，由 [source] 类型决定。
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

  // 互联对端源
  List<OnlineMangaSeries> interconnectItems = const <OnlineMangaSeries>[];
}

/// 逐源扇出执行器（无 UI 依赖，宿主/运行时注入，可纯 fake 测试）。
class MangaGlobalSearchRunner {
  MangaGlobalSearchRunner({
    required MihonManager? mihonManager,
    required AidokuRuntime? Function() resolveAidokuRuntime,
    InterconnectMangaSourceTransport? interconnectTransport,
  })  : _mihonManager = mihonManager,
        _resolveAidokuRuntime = resolveAidokuRuntime,
        _interconnectTransport = interconnectTransport;

  final MihonManager? _mihonManager;
  final AidokuRuntime? Function() _resolveAidokuRuntime;

  /// 对端源的传输层；没有互联源参与时可为 null。
  final InterconnectMangaSourceTransport? _interconnectTransport;

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
    // 抑制解题页：6 路扇出里被 Cloudflare 拦下的源不该无操作弹全屏 WebView，
    // 按 [MangaSearchRunStatus.cloudflare] 标成徽标，用户点进源页再交互解题。
    return AidokuCloudflareGate.runSuppressed(
      () => runBoundedTasks(
        runs,
        maxConcurrent: maxConcurrent,
        task: (MangaSourceSearchRun run) =>
            _runOne(run, query, isCancelled, onRunUpdated),
      ),
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
                  .map(
                    (Map<Object?, Object?> value) =>
                        value.cast<String, Object?>(),
                  )
                  .where(
                    (Map<String, Object?> value) =>
                        value['key']?.toString().isNotEmpty ?? false,
                  )
                  .toList(growable: false);
          if (isCancelled()) return;
          run.aidokuItems = entries;
          run.status = entries.isEmpty
              ? MangaSearchRunStatus.empty
              : MangaSearchRunStatus.done;
        case InterconnectGlobalSource(:final InterconnectRemoteSource source):
          final InterconnectMangaSourceTransport? transport =
              _interconnectTransport;
          if (transport == null) {
            throw const InterconnectMangaSourceException(
              InterconnectMangaSourceException.codeUnavailable,
              'Interconnect transport is not wired',
            );
          }
          final RemoteMangaBrowsePage page = await transport.browse(
            source.peer,
            source.id,
            mode: RemoteMangaBrowseMode.search,
            page: 1,
            query: query,
          );
          final List<OnlineMangaSeries> items = <OnlineMangaSeries>[
            for (final Map<String, Object?> json in page.items)
              if (OnlineMangaSeries.fromJson(json)
                  case final OnlineMangaSeries s)
                s,
          ];
          if (isCancelled()) return;
          run.interconnectItems = items;
          run.status = items.isEmpty
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

  /// Cloudflare 保护判型（Aidoku 结构化错误码 + 文案兜底，兜非 Aidoku 来源）。
  static bool isCloudflareError(Object error) {
    if (error is AidokuRuntimeException) {
      return error.code == kAidokuCloudflareChallengeCode;
    }
    // 对端把自己那边的 Cloudflare 分型结构化传回来（host 路由的 error.code）。
    if (error is InterconnectMangaSourceException) return error.isCloudflare;
    return '$error'.contains('Cloudflare');
  }
}
