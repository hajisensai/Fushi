/// Kavita EPUB 系列详情：章（文件）列表，每章可「阅读」（流式打开：下载到缓存后
/// 入库阅读）或「下载」（固定为长期保留）。
///
/// 打开 = [KavitaBookService.openOrImport]（已在本地就不重复下载）；下载 = 打开 +
/// [KavitaBookService.pin]。下载入口受 `StoreRestrictedCapability.downloads` 管（iOS
/// 隐藏），阅读不受限。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/media/kavita/kavita_book_binding.dart';
import 'package:fushi/src/media/kavita/kavita_book_service.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';

class KavitaBookSeriesPage extends ConsumerStatefulWidget {
  const KavitaBookSeriesPage({
    required this.server,
    required this.series,
    required this.api,
    super.key,
  });

  final KavitaServerConfig server;
  final KavitaSeries series;
  final KavitaApi api;

  @override
  ConsumerState<KavitaBookSeriesPage> createState() =>
      _KavitaBookSeriesPageState();
}

class _KavitaBookSeriesPageState extends ConsumerState<KavitaBookSeriesPage> {
  List<KavitaChapter> _chapters = const <KavitaChapter>[];
  Map<int, ({String bookKey, KavitaBookBinding binding})> _bound =
      const <int, ({String bookKey, KavitaBookBinding binding})>{};
  bool _loading = true;
  Object? _error;

  /// 正在下载的章 → 进度百分比（null = 大小未知）。
  final Map<int, int?> _busy = <int, int?>{};
  final Map<int, KavitaCancelToken> _tokens = <int, KavitaCancelToken>{};

  KavitaBookService? _service;

  Future<KavitaBookService> _ensureService() async {
    final KavitaBookService? existing = _service;
    if (existing != null) return existing;
    final KavitaBookService created = KavitaBookService(
      db: ref.read(appProvider).database,
      tempRoot: await getTemporaryDirectory(),
    );
    return _service = created;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final KavitaCancelToken token in _tokens.values) {
      token.cancel();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final KavitaSeriesDetail detail = await widget.api.getSeriesDetail(
        widget.series.id,
      );
      final KavitaBookService service = await _ensureService();
      final Map<int, ({String bookKey, KavitaBookBinding binding})> bound =
          await service.boundChapters(widget.server.id);
      if (!mounted) return;
      setState(() {
        _chapters = detail.allChapters;
        _bound = bound;
        _loading = false;
      });
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('KavitaBookSeries.load', error, stack);
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _refreshBound() async {
    final KavitaBookService service = await _ensureService();
    final Map<int, ({String bookKey, KavitaBookBinding binding})> bound =
        await service.boundChapters(widget.server.id);
    if (mounted) setState(() => _bound = bound);
  }

  /// 确保这一章在本地，返回 bookKey；失败 / 取消返回 null（已提示用户）。
  Future<String?> _ensureLocal(KavitaChapter chapter) async {
    final KavitaBookService service = await _ensureService();
    final KavitaCancelToken token = KavitaCancelToken();
    _tokens[chapter.id] = token;
    setState(() => _busy[chapter.id] = null);
    try {
      return await service.openOrImport(
        serverConfigId: widget.server.id,
        api: widget.api,
        series: widget.series,
        chapter: chapter,
        cancelToken: token,
        onProgress: (int received, int? total) {
          if (!mounted || total == null || total <= 0) return;
          setState(() => _busy[chapter.id] = (received * 100) ~/ total);
        },
      );
    } on KavitaDownloadCancelled {
      return null;
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('KavitaBookSeries.download', error, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          FushiSnackBar(
            content: Text(
              t.kavita_book_download_failed(
                reason: error is KavitaApiException
                    ? 'HTTP ${error.statusCode}'
                    : error.runtimeType.toString(),
              ),
            ),
          ),
        );
      }
      return null;
    } finally {
      _tokens.remove(chapter.id);
      if (mounted) setState(() => _busy.remove(chapter.id));
    }
  }

  Future<void> _read(KavitaChapter chapter) async {
    final String? bookKey = await _ensureLocal(chapter);
    if (bookKey == null || !mounted) return;
    unawaited(_refreshBound());
    final AppModel appModel = ref.read(appProvider);
    final MediaItem? item = await ReaderFushiSource.instance
        .mediaItemForBookKey(bookKey);
    if (item == null || !mounted) return;
    await appModel.openMedia(
      ref: ref,
      mediaSource: item.getMediaSource(appModel: appModel),
      item: item,
    );
    if (mounted) unawaited(_refreshBound());
  }

  Future<void> _download(KavitaChapter chapter) async {
    final String? bookKey = await _ensureLocal(chapter);
    if (bookKey == null) return;
    final KavitaBookService service = await _ensureService();
    await service.pin(bookKey);
    if (mounted) await _refreshBound();
  }

  Future<void> _removeDownload(String bookKey) async {
    final KavitaBookService service = await _ensureService();
    await service.unpin(bookKey);
    if (mounted) await _refreshBound();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.series.displayName)),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return Center(child: adaptiveIndicator(context: context));
    if (_error != null) {
      return FushiPlaceholderMessage(
        icon: FushiIcons.error,
        message: t.kavita_connect_failed(reason: ''),
        action: FushiFilledButton.icon(
          onPressed: () => unawaited(_load()),
          icon: const FushiIcon(FushiIcons.refresh),
          label: Text(t.retry),
        ),
      );
    }
    if (_chapters.isEmpty) {
      return FushiPlaceholderMessage(
        icon: FushiIcons.books,
        message: t.kavita_book_no_chapters,
      );
    }
    final bool canDownload = StoreRestrictedCapability.downloads.isAvailable;
    return FushiEntranceScope(
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _chapters.length,
        itemBuilder: fushiStaggeredItemBuilder((
          BuildContext context,
          int index,
        ) {
          final KavitaChapter chapter = _chapters[index];
          return _chapterTile(chapter, canDownload: canDownload);
        }),
      ),
    );
  }

  Widget _chapterTile(KavitaChapter chapter, {required bool canDownload}) {
    final ({String bookKey, KavitaBookBinding binding})? local =
        _bound[chapter.id];
    final bool busy = _busy.containsKey(chapter.id);
    final int? percent = _busy[chapter.id];
    final bool pinned = local != null && !local.binding.cachedOnly;
    final String status = busy
        ? (percent == null
              ? t.kavita_book_downloading(percent: '…')
              : t.kavita_book_downloading(percent: '$percent'))
        : pinned
        ? t.kavita_book_downloaded
        : local != null
        ? t.kavita_book_cached
        : '';
    return FushiListItem(
      key: ValueKey<String>('kavita_chapter_${chapter.id}'),
      title: Text(chapter.displayName),
      titleMaxLines: 2,
      subtitle: status.isEmpty ? null : Text(status),
      onTap: busy ? null : () => unawaited(_read(chapter)),
      trailing: busy
          ? FushiTextButton(
              onPressed: () => _tokens[chapter.id]?.cancel(),
              child: Text(t.kavita_book_cancel),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (canDownload && pinned)
                  FushiIconButtonControl(
                    tooltip: t.kavita_book_remove_download,
                    icon: const FushiIcon(FushiIcons.downloadDone),
                    onPressed: () => unawaited(_removeDownload(local.bookKey)),
                  )
                else if (canDownload)
                  FushiIconButtonControl(
                    tooltip: t.kavita_book_download,
                    icon: const FushiIcon(FushiIcons.download),
                    onPressed: () => unawaited(_download(chapter)),
                  ),
                FushiIconButtonControl(
                  tooltip: t.kavita_book_open,
                  icon: const FushiIcon(FushiIcons.books),
                  onPressed: () => unawaited(_read(chapter)),
                ),
              ],
            ),
    );
  }
}
