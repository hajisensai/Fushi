/// 「AI 下载」（浏览 › 发现的小说 / 漫画 / 游戏域）的本地确定性半边：按域去哪些
/// 来源搜、每条候选怎么下载。AI 只决定「搜什么词」与「推荐哪几条」
/// （`ai_media_acquisition_assistant.dart`），这里一行都不经 LLM。
///
/// 三种后端各自复用该域已有的下载路径，不另起一套：
///  * [DiscoveryAcquisitionBackend]：发现源（Nyaa / OPDS / AList / 资源站…），
///    下载走发现页同一个 [startDiscoveryItemDownload]（torrent / 直链 → 自动入库）；
///  * [MihonMangaAcquisitionBackend]：已启用的 Mihon 漫画源，下载 = 加入书架 +
///    全部未锁章节进漫画下载队列（与作品页「下载全部」同一服务）；
///  * [LnReaderNovelAcquisitionBackend]：已启用的 LNReader 插件，下载 = 作品页
///    同一个整本下载对话框（EPUB 入书架）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart'
    show EpubBookRow, MangaOnlineSourceRow;
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/media/discovery/discovery_models.dart';

import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart';
import 'package:fushi/src/media/discovery/discovery_labels.dart';
import 'package:fushi/src/media/discovery/media_discovery_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_global_search_runner.dart';
import 'package:fushi/src/media/manga/mihon/mihon_enabled_sources.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_book_download.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_novel_detail_page.dart'
    show
        LnReaderDownloadAborted,
        LnReaderDownloadDialog,
        LnReaderDownloadFailed,
        LnReaderDownloadOutcome,
        LnReaderDownloadSucceeded;
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show fushiBooksProvider, srtBooksProvider;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/download_actions.dart'
    show startDiscoveryItemDownload;
import 'package:fushi/src/utils/misc/bounded_concurrency.dart';
import 'package:fushi/utils.dart';

/// 每个来源最多取几条结果进候选（热门源一次返回几十条，全收会把挑选池挤满）。
const int kMediaAcquisitionPerSourceLimit = 8;

/// 一条可下载的候选。[payload] 是后端自己的类型，只由产出它的 [backend] 解读。
class MediaAcquisitionCandidate {
  MediaAcquisitionCandidate({
    required this.id,
    required this.title,
    required this.sourceLabel,
    required this.backend,
    required this.payload,
    this.details = const <String>[],
    this.score = 0,
  });

  /// 本次运行内唯一（后端前缀 + 来源 + 条目身份）。
  final String id;
  final String title;
  final String sourceLabel;
  final List<String> details;
  final MediaAcquisitionBackend backend;
  final Object payload;

  /// 本地排序分（做种数等）；AI 未指派 / 失败时就按它排。
  final int score;

  AiMediaAcquisitionCandidateFact toFact() => AiMediaAcquisitionCandidateFact(
    id: id,
    title: title,
    source: sourceLabel,
    details: details,
  );
}

/// 一个域里的一类来源。
abstract class MediaAcquisitionBackend {
  /// 搜一个词。单源失败自己吞掉（记日志），不拖垮其它来源。
  Future<List<MediaAcquisitionCandidate>> search(String query);

  /// 下载 [candidate]；结果自己 toast。返回是否已交给下载 / 入库。
  Future<bool> acquire(
    BuildContext context,
    MediaAcquisitionCandidate candidate,
  );
}

/// 发现源（与发现页同一个 [MediaDiscoveryService]、同一份「停用来源」偏好）。
class DiscoveryAcquisitionBackend implements MediaAcquisitionBackend {
  DiscoveryAcquisitionBackend({required this.appModel, required this.kinds});

  final AppModel appModel;
  final List<DiscoveryMediaKind> kinds;

  @override
  Future<List<MediaAcquisitionCandidate>> search(String query) async {
    final MediaDiscoveryService service = appModel.mediaDiscoveryService;
    final List<MediaAcquisitionCandidate> out = <MediaAcquisitionCandidate>[];
    for (final DiscoveryMediaKind kind in kinds) {
      final DiscoveryAggregateResult result;
      try {
        result = await service.load(
          DiscoveryRequest(kind: kind, query: query),
          disabledSourceIds: appModel.discoveryDisabledSourceIds,
        );
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'MediaAcquisition.discovery',
          error,
          stack,
        );
        continue;
      }
      for (final DiscoverySourceSlice slice in result.slices) {
        final String sourceLabel =
            service.sourceById(slice.sourceId)?.displayName ?? slice.sourceId;
        int taken = 0;
        for (final DiscoveryEntry entry in slice.page.entries) {
          if (entry is! DiscoveryResourceItem || !entry.isDownloadable) {
            continue;
          }
          if (++taken > kMediaAcquisitionPerSourceLimit) break;
          out.add(
            MediaAcquisitionCandidate(
              id: 'd:${entry.sourceId}:${entry.id}',
              title: entry.title,
              sourceLabel: sourceLabel,
              backend: this,
              payload: entry,
              score: entry.seeders ?? 0,
              details: <String>[
                discoveryMediaKindLabel(entry.kind),
                if (entry.sizeBytes != null)
                  formatDiscoveryBytes(entry.sizeBytes!),
                if (entry.seeders != null) '↑${entry.seeders}',
                if (entry.dateText != null)
                  formatDiscoveryDate(entry.dateText!),
                if (entry.note != null) entry.note!,
              ],
            ),
          );
        }
      }
    }
    return out;
  }

  @override
  Future<bool> acquire(
    BuildContext context,
    MediaAcquisitionCandidate candidate,
  ) => startDiscoveryItemDownload(
    context: context,
    appModel: appModel,
    item: candidate.payload as DiscoveryResourceItem,
  );
}

class _MihonHit {
  const _MihonHit(this.context, this.manga);

  final MihonSourceContext context;
  final MihonManga manga;
}

/// 已启用的 Mihon 漫画源（与漫画全源搜索同一个 [MangaGlobalSearchRunner]）。
class MihonMangaAcquisitionBackend implements MediaAcquisitionBackend {
  MihonMangaAcquisitionBackend({required this.appModel});

  final AppModel appModel;

  MihonManager get _manager => appModel.mihonManager;

  @override
  Future<List<MediaAcquisitionCandidate>> search(String query) async {
    final List<MangaSourceSearchRun> runs = <MangaSourceSearchRun>[
      for (final MangaOnlineSourceRow row in enabledMangaOnlineSources(
        _manager,
      ))
        MangaSourceSearchRun(MihonGlobalSource(row)),
    ];
    if (runs.isEmpty) return const <MediaAcquisitionCandidate>[];
    await MangaGlobalSearchRunner(mihonManager: _manager).search(
      runs: runs,
      query: query,
      isCancelled: () => false,
      onRunUpdated: () {},
    );
    return <MediaAcquisitionCandidate>[
      for (final MangaSourceSearchRun run in runs)
        if (run.mihonContext != null)
          for (final MihonManga manga in run.mihonItems.take(
            kMediaAcquisitionPerSourceLimit,
          ))
            MediaAcquisitionCandidate(
              id: 'm:${run.source.id}:${manga.url}',
              title: manga.title,
              sourceLabel: run.source.name,
              backend: this,
              payload: _MihonHit(run.mihonContext!, manga),
              details: <String>[
                if (run.source.language.isNotEmpty) run.source.language,
                if ((manga.author ?? '').trim().isNotEmpty)
                  manga.author!.trim(),
              ],
            ),
    ];
  }

  /// 加入书架 → 拉章节 → 全部未锁章节入队（与作品页「加入书架」+「下载全部」
  /// 同一服务与同一跳过规则）。
  @override
  Future<bool> acquire(
    BuildContext context,
    MediaAcquisitionCandidate candidate,
  ) async {
    final _MihonHit hit = candidate.payload as _MihonHit;
    try {
      final OnlineMangaLibraryEntry seed = OnlineMangaLibraryEntry(
        runtime: OnlineMangaRuntimeKind.mihon,
        extensionPackage: hit.context.extension.packageName,
        sourceId: hit.context.source.id,
        series: MihonLibraryAdapter.seriesOf(hit.manga),
        chapters: const <OnlineMangaChapter>[],
      );
      final OnlineMangaRefreshResult refreshed = await MihonLibraryAdapter(
        _manager,
        presetContext: hit.context,
      ).refresh(seed);
      final OnlineMangaLibraryEntry fetched = seed.copyWith(
        series: refreshed.series,
        chapters: refreshed.chapters,
      );
      final OnlineMangaLibraryService service = appModel
          .onlineMangaLibraryService(OnlineMangaRuntimeKind.mihon);
      final EpubBookRow row = await service.add(fetched);
      final OnlineMangaLibraryEntry entry =
          OnlineMangaLibraryEntry.tryParse(row.sourceMetadata) ?? fetched;
      final List<OnlineMangaChapter> pending = <OnlineMangaChapter>[
        for (final OnlineMangaChapter chapter in entry.chapters.reversed)
          if (!chapter.locked) chapter,
      ];
      final int locked = entry.chapters.length - pending.length;
      if (locked > 0) {
        FushiToast.show(
          msg: t.manga_series_download_all_locked_skipped(count: locked),
        );
      }
      if (pending.isEmpty) {
        if (locked == 0) FushiToast.show(msg: t.manga_series_download_all_none);
        return false;
      }
      await appModel.mangaDownloadService.enqueueChapters(
        entry: entry,
        chapters: pending,
        autoOcr: appModel.mangaDownloadAutoOcr,
      );
      FushiToast.show(
        msg: t.manga_series_download_all_queued(count: pending.length),
        severity: ToastSeverity.success,
      );
      return true;
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MediaAcquisition.mihon', error, stack);
      FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      return false;
    }
  }
}

class _LnReaderHit {
  const _LnReaderHit(this.plugin, this.item);

  final LnReaderInstalledPlugin plugin;
  final LnReaderNovelItem item;
}

/// 已启用的 LNReader 插件（逐插件搜第 1 页，限流并发）。
class LnReaderNovelAcquisitionBackend implements MediaAcquisitionBackend {
  LnReaderNovelAcquisitionBackend({required this.appModel});

  final AppModel appModel;

  LnReaderManager get _manager => appModel.lnReaderManager;

  @override
  Future<List<MediaAcquisitionCandidate>> search(String query) async {
    await _manager.initialise();
    final List<LnReaderInstalledPlugin> plugins = <LnReaderInstalledPlugin>[
      for (final LnReaderInstalledPlugin plugin in _manager.installed)
        if (plugin.enabled) plugin,
    ];
    final List<List<MediaAcquisitionCandidate>> perPlugin =
        List<List<MediaAcquisitionCandidate>>.filled(
          plugins.length,
          const <MediaAcquisitionCandidate>[],
        );
    await runBoundedTasks(
      List<int>.generate(plugins.length, (int i) => i),
      maxConcurrent: 4,
      task: (int i) async {
        final LnReaderInstalledPlugin plugin = plugins[i];
        try {
          await _manager.load(plugin);
          final List<LnReaderNovelItem> items = await _manager.runtime.search(
            plugin.id,
            query: query,
            page: 1,
          );
          perPlugin[i] = <MediaAcquisitionCandidate>[
            for (final LnReaderNovelItem item in items.take(
              kMediaAcquisitionPerSourceLimit,
            ))
              MediaAcquisitionCandidate(
                id: 'n:${plugin.id}:${item.path}',
                title: item.name,
                sourceLabel: plugin.name,
                backend: this,
                payload: _LnReaderHit(plugin, item),
                details: <String>[if (plugin.lang.isNotEmpty) plugin.lang],
              ),
          ];
        } on Object catch (error, stack) {
          ErrorLogService.instance.log(
            'MediaAcquisition.lnreader.${plugin.id}',
            error,
            stack,
          );
        }
      },
    );
    return <MediaAcquisitionCandidate>[
      for (final List<MediaAcquisitionCandidate> list in perPlugin) ...list,
    ];
  }

  /// 拉作品全章 → 作品页同一个整本下载对话框（带进度、可取消），下完入书架。
  @override
  Future<bool> acquire(
    BuildContext context,
    MediaAcquisitionCandidate candidate,
  ) async {
    final _LnReaderHit hit = candidate.payload as _LnReaderHit;
    final LnReaderNovel novel;
    try {
      await _manager.load(hit.plugin);
      novel = await _manager.runtime.novel(hit.plugin.id, hit.item.path);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MediaAcquisition.lnreader', error, stack);
      FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      return false;
    }
    if (novel.chapters.isEmpty) {
      FushiToast.show(msg: t.manga_series_download_all_none);
      return false;
    }
    if (!context.mounted) return false;
    final LnReaderDownloadOutcome? outcome =
        await showAppDialog<LnReaderDownloadOutcome>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext _) => LnReaderDownloadDialog(
            download: LnReaderBookDownload(
              manager: _manager,
              database: appModel.database,
              httpClientFactory: createAppHttpClient,
            ),
            plugin: hit.plugin,
            novel: novel,
            chapters: novel.chapters,
          ),
        );
    switch (outcome) {
      case LnReaderDownloadSucceeded():
        if (context.mounted) {
          final ProviderContainer container = ProviderScope.containerOf(
            context,
            listen: false,
          );
          container.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
          container.invalidate(srtBooksProvider);
        }
        FushiToast.show(
          msg: t.novel_download_done(title: novel.name),
          severity: ToastSeverity.success,
        );
        return true;
      case LnReaderDownloadFailed(:final Object error):
        FushiToast.show(
          msg: error is LnReaderChapterDownloadException
              ? t.novel_download_failed(
                  chapter: error.chapter.name,
                  error: '${error.cause}',
                )
              : '$error',
          severity: ToastSeverity.error,
        );
        return false;
      case LnReaderDownloadAborted():
        FushiToast.show(msg: t.novel_download_cancelled);
        return false;
      case null:
        return false;
    }
  }
}
