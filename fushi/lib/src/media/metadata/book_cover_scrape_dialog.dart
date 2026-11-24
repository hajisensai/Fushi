import 'dart:io';

import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/metadata/book_metadata_scrape_facade.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart';
import 'package:fushi_engine/media/metadata/books/book_catalog.dart'
    show findIsbnIn, normalizeIsbn13;
import 'package:fushi_engine/media/metadata/books/rakuten_books.dart';
import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart';
import 'package:fushi_engine/media/metadata/image_download.dart';
import 'package:fushi/src/media/metadata/scrape_cover_preview.dart';
import 'package:fushi/src/media/metadata/scrape_failure_view.dart';
import 'package:fushi/src/media/nsfw/media_nsfw_dialog.dart'
    show writeMediaNsfw;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/src/utils/components/fushi_dropdown.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 书籍 / 漫画 / 有声书「在线匹配封面」弹窗（统一刮削 P1b）。
///
/// 源用下拉切换（[BookScrapeSource]，八个源分段放不下）：Bangumi 书籍条目
/// （`filter.type=[1]`）、DLsite 音声 / 漫画 / 小说作品、MangaBaka 漫画 / 轻小说系列（选中
/// 系列后进卷封面网格，预选本地卷号 [BookCoverScrapeDialog.volume] 那一卷；结果区底部显示
/// MangaBaka 署名）、AniList 轻小说、openBD（只按 ISBN）、NDL Search、楽天ブックス（要设备
/// 本地凭据；没填时下拉里照样列出，**只有选中它时**结果区才提示去哪填，不发请求）、iTunes
/// 歌曲（专辑封面）。默认 Bangumi（填了楽天凭据也不会变成默认源）；预填词里认得出 DLsite
/// 编号时默认切到 DLsite 并只填编号（直取），预填词本身就是 ISBN 时默认 openBD；这本「书」
/// 其实是导入的歌曲（[isSong]，同步文件是 LRC 歌词）时默认 iTunes。切到 openBD 而搜索框里
/// 没有 ISBN 时，用书本身的 ISBN（[isbn]，EPUB 导入时从 OPF 读出）。
///
/// NSFW 候选（各源标的成人向条目）对所有源一视同仁：书自己标了 NSFW（或在 NSFW 合集里，
/// [includeNsfw]）才显示，并标「NSFW」；没标时藏起来，结果区写明藏了几条，给「标为
/// NSFW」按钮（[onMarkNsfw]，写的是书架菜单同一个开关），点了就显示（拍板台 pr3497）。
/// 选中候选后下载其封面到临时文件并经 `Navigator.pop(`[BookCoverScrapeSelection]`)` 连同候选本身返回给调用方（候选解析与下载都经
/// [BookMetadataScrapeFacade]，书架页的写回也经它）（书籍编辑对话框把它当作新的封面
/// override，走既有 `setOverrideThumbnailFromMediaItem` 落地——不新增任何存储路径）。
///
/// 返回 `null` = 用户取消 / 未选。
Future<BookCoverScrapeSelection?> showBookCoverScrapeDialog({
  required BuildContext context,
  required String initialQuery,
  num? volume,
  String? isbn,
  RakutenBooksCredentials? rakuten,
  bool includeNsfw = false,
  bool isSong = false,
  Future<void> Function()? onMarkNsfw,
}) {
  return showAppDialog<BookCoverScrapeSelection>(
    context: context,
    builder: (BuildContext ctx) => BookCoverScrapeDialog(
      initialQuery: initialQuery,
      volume: volume,
      isbn: isbn,
      rakuten: rakuten,
      includeNsfw: includeNsfw,
      isSong: isSong,
      onMarkNsfw: onMarkNsfw,
    ),
  );
}

/// 给书架上的 [item] 开刮削弹窗：先读它的 ISBN（openBD 预填）、有效 NSFW 标记
/// （决定显不显示 NSFW 候选）与是不是导入的歌曲（默认 iTunes），「标为 NSFW」写回同一个
/// 宿主。书架卡菜单与编辑弹窗共用。
Future<BookCoverScrapeSelection?> showBookCoverScrapeDialogForItem({
  required BuildContext context,
  required FushiDatabase db,
  required MediaItem item,
  required String initialQuery,
  num? volume,
  RakutenBooksCredentials? rakuten,
}) async {
  final String? isbn = await BookMetadataScrapeFacade.isbnForItem(db, item);
  final BookNsfwHost? host = BookMetadataScrapeFacade.nsfwHostForItem(item);
  final bool nsfw = await BookMetadataScrapeFacade.isNsfwHost(db, host);
  final bool song = await BookMetadataScrapeFacade.isSongForItem(db, item);
  if (!context.mounted) return null;
  return showBookCoverScrapeDialog(
    context: context,
    initialQuery: initialQuery,
    volume: volume,
    isbn: isbn,
    rakuten: rakuten,
    includeNsfw: nsfw,
    isSong: song,
    onMarkNsfw: host == null
        ? null
        : () => writeMediaNsfw(db, host.kind, host.entryKey, true),
  );
}

/// 弹窗的选择结果：下载好的封面临时文件 + 选中的候选（写回时连同简介 / 评分 /
/// 标签等条目资料一起落库，书架系列色块读它）。
typedef BookCoverScrapeSelection = ({
  File cover,
  BookScrapeCandidate candidate,
});

/// 弹窗主体（导出便于 widget 测试直接构造并注入 [scraperOverride]）。
class BookCoverScrapeDialog extends StatefulWidget {
  const BookCoverScrapeDialog({
    super.key,
    required this.initialQuery,
    this.scraperOverride,
    this.downloaderOverride,
    this.volume,
    this.isbn,
    this.rakuten,
    this.includeNsfw = false,
    this.isSong = false,
    this.onMarkNsfw,
  });

  final String initialQuery;

  /// 这本「书」其实是导入的歌曲（LRC 歌词 + 音频）：默认源切到 iTunes。
  final bool isSong;

  /// 显示 NSFW 候选（书自己是 NSFW 时为 true）。
  final bool includeNsfw;

  /// 「标为 NSFW」：把这本书标成 NSFW（抛异常 = 没写成，候选仍藏着）；null = 认不出
  /// 宿主，只提示不给按钮。
  final Future<void> Function()? onMarkNsfw;

  /// 本地书的卷号（MangaBaka 卷封面网格预选这一卷）；null = 不预选。
  final num? volume;

  /// 书本身的 ISBN-13（没有为 null），openBD 预填用。
  final String? isbn;

  /// 楽天ブックス凭据（设备本地设置；注入 [scraperOverride] 时以 scraper 自带的为准）。
  final RakutenBooksCredentials? rakuten;

  /// 测试注入的 scraper（注入时弹窗不负责关闭它）。
  final BookMetadataScraper? scraperOverride;

  /// 测试注入的封面下载器（null = 真实下载到临时文件）。
  final BookCoverDownloader? downloaderOverride;

  @override
  State<BookCoverScrapeDialog> createState() => _BookCoverScrapeDialogState();
}

/// 纯函数：弹窗的初始源与搜索词。预填词里带 DLsite 编号 → (DLsite, 编号)；预填词
/// 本身是一个 ISBN → (openBD, ISBN-13)；[isSong]（导入的歌曲）→ (iTunes, 原词)；否则
/// (Bangumi, 原词)。
(BookScrapeSource, String) bookScrapeInitialState(
  String initialQuery, {
  bool isSong = false,
}) {
  final DlsiteWorkId? id = DlsiteWorkId.findIn(initialQuery);
  if (id != null) return (BookScrapeSource.dlsite, id.value);
  final String? isbn = normalizeIsbn13(initialQuery);
  if (isbn != null) return (BookScrapeSource.openbd, isbn);
  if (isSong) return (BookScrapeSource.itunes, initialQuery);
  return (BookScrapeSource.bangumi, initialQuery);
}

class _BookCoverScrapeDialogState extends State<BookCoverScrapeDialog> {
  late final TextEditingController _queryCtrl;
  late final BookMetadataScraper _scraper;

  /// 候选解析与封面下载都经门面（与 `fushi_cli book` 同一个方法）。
  late final BookMetadataScrapeFacade _facade;
  late BookScrapeSource _source;

  List<BookScrapeCandidate> _results = const <BookScrapeCandidate>[];
  bool _searching = false;
  bool _searched = false;

  /// 上一次搜索失败的异常（null = 没失败）。失败态在结果区显示错误行 + 可行动原因
  /// （区别于「无匹配」空态），用户可再点「搜索」重试——不允许静默塌缩成空列表。
  Object? _searchFailure;

  /// 正在下载封面的候选（在其「使用」按钮上转圈；null = 无进行中）。
  BookScrapeCandidate? _applyingCandidate;

  /// 当前源只按 ISBN 查、而搜索框里没有 ISBN（结果区给提示，不发请求）。
  bool _needsIsbn = false;

  /// 当前源要凭据而没填（楽天；结果区提示去哪填，不发请求）。
  bool _needsCredentials = false;

  /// 是否显示 NSFW 候选（初值跟随书的 NSFW 标记，「标为 NSFW」后变 true）。
  late bool _includeNsfw;

  /// 上次搜索因书没标 NSFW 藏起来的候选条数。
  int _hiddenNsfw = 0;

  /// 「标为 NSFW」正在写库。
  bool _markingNsfw = false;

  /// MangaBaka 卷封面网格：选中的系列（null = 在候选列表页）。
  BookScrapeCandidate? _volumeSeries;
  List<BookVolumeCover> _volumes = const <BookVolumeCover>[];
  bool _loadingVolumes = false;
  Object? _volumeFailure;

  /// 正在下载的那一卷（转圈）。
  BookVolumeCover? _applyingVolume;

  @override
  void initState() {
    super.initState();
    final (BookScrapeSource source, String query) = bookScrapeInitialState(
      widget.initialQuery,
      isSong: widget.isSong,
    );
    _source = source;
    _includeNsfw = widget.includeNsfw;
    _queryCtrl = TextEditingController(text: query);
    _scraper =
        widget.scraperOverride ?? BookMetadataScraper(rakuten: widget.rakuten);
    _facade = BookMetadataScrapeFacade(
      scraper: _scraper,
      downloadImage: widget.downloaderOverride,
    );
    // 首帧后按预填标题自动搜一次。
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    if (widget.scraperOverride == null) _scraper.close();
    super.dispose();
  }

  Future<void> _search() async {
    final String keyword = _queryCtrl.text.trim();
    if (keyword.isEmpty) return;
    final bool needsCredentials =
        _source.needsCredentials && !_scraper.rakutenAvailable;
    final bool needsIsbn = _source.isbnOnly && findIsbnIn(keyword) == null;
    if (needsCredentials || needsIsbn) {
      setState(() {
        _needsCredentials = needsCredentials;
        _needsIsbn = !needsCredentials && needsIsbn;
        _searched = false;
        _results = const <BookScrapeCandidate>[];
        _hiddenNsfw = 0;
        _searchFailure = null;
      });
      return;
    }
    setState(() {
      _searching = true;
      _searched = true;
      _needsIsbn = false;
      _needsCredentials = false;
      _searchFailure = null;
    });
    List<BookScrapeCandidate> results = const <BookScrapeCandidate>[];
    int hidden = 0;
    Object? failure;
    try {
      final BookScrapeSearchResult found = await _facade.searchDetailed(
        source: _source,
        query: keyword,
        includeNsfw: _includeNsfw,
      );
      results = found.candidates;
      hidden = found.hiddenNsfw;
    } catch (e, stack) {
      // BUG-1176：失败要有出口。界面出可见失败行，原始原因落错误日志（用户可在
      // 「错误日志」页查看/上传），不静默塌缩成空列表。
      ErrorLogService.instance.log('BookCoverScrapeDialog.search', e, stack);
      failure = e;
    }
    if (!mounted) return;
    setState(() {
      _results = results;
      _hiddenNsfw = hidden;
      _searching = false;
      _searchFailure = failure;
    });
  }

  /// 「标为 NSFW」：写书的 NSFW 标记（成功 / 失败的提示由调用方给，书架接线是
  /// `writeMediaNsfw`），成功后连同 NSFW 候选重搜一次。
  Future<void> _markNsfw() async {
    final Future<void> Function()? mark = widget.onMarkNsfw;
    if (mark == null || _markingNsfw) return;
    setState(() => _markingNsfw = true);
    bool ok = false;
    try {
      await mark();
      ok = true;
    } catch (e, stack) {
      ErrorLogService.instance.log('BookCoverScrapeDialog.markNsfw', e, stack);
    }
    if (!mounted) return;
    setState(() {
      _markingNsfw = false;
      if (ok) _includeNsfw = true;
    });
    if (ok) await _search();
  }

  /// 把失败折成一句用户可行动的话。底层已把传输失败 / 非 2xx / 非图片响应统一折成带
  /// `statusCode` 的领域异常，「有没有 statusCode」就是「没拿到可用响应」与「拿到了
  /// 但对面报错」的唯一可靠分界——不做更细的假分类，技术细节留在错误日志里。
  String _failureReason(Object failure) {
    final int? status = switch (failure) {
      BookScrapeException(:final int? statusCode) => statusCode,
      ImageDownloadException(:final int? statusCode) => statusCode,
      _ => null,
    };
    return status == null ? t.scrape_reason_network : t.scrape_reason_server;
  }

  void _selectSource(BookScrapeSource source) {
    if (source == _source) return;
    final String? isbn = widget.isbn;
    if (source.isbnOnly &&
        isbn != null &&
        findIsbnIn(_queryCtrl.text) == null) {
      _queryCtrl.text = isbn;
    }
    setState(() {
      _source = source;
      _volumeSeries = null;
      _results = const <BookScrapeCandidate>[];
      _hiddenNsfw = 0;
      _searched = false;
      _needsIsbn = false;
      _needsCredentials = false;
      _searchFailure = null;
    });
    _search();
  }

  /// MangaBaka 候选「使用」= 进该系列的卷封面网格。
  Future<void> _openVolumes(BookScrapeCandidate candidate) async {
    setState(() {
      _volumeSeries = candidate;
      _volumes = const <BookVolumeCover>[];
      _loadingVolumes = true;
      _volumeFailure = null;
    });
    List<BookVolumeCover> volumes = const <BookVolumeCover>[];
    Object? failure;
    try {
      volumes = await _facade.volumeCovers(candidate.subjectId);
    } catch (e, stack) {
      ErrorLogService.instance.log('BookCoverScrapeDialog.volumes', e, stack);
      failure = e;
    }
    if (!mounted) return;
    setState(() {
      _volumes = volumes;
      _loadingVolumes = false;
      _volumeFailure = failure;
    });
  }

  Future<void> _useVolume(BookVolumeCover cover) async {
    if (_applyingVolume != null) return;
    setState(() => _applyingVolume = cover);
    File? file;
    Object? failure;
    try {
      file = await _facade.downloadVolumeCover(cover);
    } catch (e, stack) {
      ErrorLogService.instance.log('BookCoverScrapeDialog.volume', e, stack);
      failure = e;
    }
    if (!mounted) return;
    if (file == null) {
      setState(() => _applyingVolume = null);
      FushiToast.show(
        msg: failure == null
            ? t.book_scrape_failed
            : '${t.book_scrape_failed}\n${_failureReason(failure)}',
        severity: ToastSeverity.error,
      );
      return;
    }
    _finish((cover: file, candidate: _volumeSeries!.forVolume(cover)));
  }

  /// 弹窗唯一的「选中」出口。BUG-5379：`Navigator.pop(file)` 按实参推断类型，传错
  /// 类型编译期不报、运行时在 pop 里抛类型错误（弹窗卡在转圈、导航栈半弹出）；所有
  /// 出口都经这里，结果类型由签名钉死。
  void _finish(BookCoverScrapeSelection selection) =>
      Navigator.of(context).pop<BookCoverScrapeSelection>(selection);

  Future<void> _use(BookScrapeCandidate candidate) async {
    if (candidate.source == BookScrapeSource.mangabaka &&
        _volumeSeries == null) {
      await _openVolumes(candidate);
      return;
    }
    if (_applyingCandidate != null) return;
    setState(() => _applyingCandidate = candidate);
    File? file;
    Object? failure;
    try {
      file = await _facade.downloadCover(candidate);
    } catch (e, stack) {
      // 下载失败必须可见 + 可查：toast 给「失败了 + 大概因为什么」，原始原因进日志。
      ErrorLogService.instance.log('BookCoverScrapeDialog.download', e, stack);
      failure = e;
    }
    if (!mounted) return;
    if (file == null) {
      setState(() => _applyingCandidate = null);
      FushiToast.show(
        msg: failure == null
            ? t.book_scrape_failed
            : '${t.book_scrape_failed}\n${_failureReason(failure)}',
        severity: ToastSeverity.error,
      );
      return;
    }
    _finish((cover: file, candidate: candidate));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiAlertDialog(
      title: Text(t.book_scrape_title),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(t.book_scrape_source_label),
                const SizedBox(width: 12),
                Expanded(
                  child: FushiDropdown<BookScrapeSource>(
                    key: const ValueKey<String>('book_scrape_source_picker'),
                    options: BookScrapeSource.values,
                    initialOption: _source,
                    enabled: !_searching,
                    generateLabel: (BookScrapeSource s) => s.label,
                    onChanged: (BookScrapeSource? v) {
                      if (v != null && !_searching) _selectSource(v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: FushiTextFieldControl(
                    controller: _queryCtrl,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: t.book_scrape_hint,
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                FushiFilledButton(
                  onPressed: _searching ? null : _search,
                  child: Text(t.book_scrape_search),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 120),
                child: _volumeSeries != null
                    ? _buildVolumes(theme)
                    : _buildResults(theme, tokens),
              ),
            ),
            if (_source == BookScrapeSource.mangabaka)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  t.book_scrape_mangabaka_attribution,
                  key: const ValueKey<String>(
                    'book_scrape_mangabaka_attribution',
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_cancel),
        ),
      ],
    );
  }

  /// MangaBaka 卷封面网格：预选本地卷号那一卷（高亮 + 排在最前），另给「使用系列
  /// 封面」。
  Widget _buildVolumes(ThemeData theme) {
    final BookScrapeCandidate series = _volumeSeries!;
    final Widget header = Row(
      children: <Widget>[
        FushiIconButtonControl(
          tooltip: t.back,
          icon: const FushiIcon(FushiIcons.back),
          onPressed: () => setState(() => _volumeSeries = null),
        ),
        Expanded(
          child: Text(
            '${t.book_scrape_volume_title} · ${series.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        FushiTextButton(
          onPressed: _applyingVolume != null || _applyingCandidate != null
              ? null
              // 系列主封面走普通下载路径（卷网格打开时 [_use] 不再进网格）。
              : () => _use(series),
          key: const ValueKey<String>('book_scrape_series_cover'),
          child: Text(t.book_scrape_series_cover),
        ),
      ],
    );
    Widget body;
    if (_loadingVolumes) {
      body = const FushiLoadingView();
    } else if (_volumeFailure != null) {
      body = ScrapeFailureView(
        title: t.book_scrape_search_failed,
        reason: _failureReason(_volumeFailure!),
        detail: _volumeFailure.toString(),
      );
    } else if (_volumes.isEmpty) {
      body = Center(child: Text(t.book_scrape_volume_empty));
    } else {
      final num? wanted = widget.volume;
      bool isWanted(BookVolumeCover v) =>
          wanted != null && (v.volume - wanted).abs() < 0.01;
      final List<BookVolumeCover> ordered = <BookVolumeCover>[
        ..._volumes.where(isWanted),
        ..._volumes.where((BookVolumeCover v) => !isWanted(v)),
      ];
      body = FushiEntranceScope(
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 112,
            childAspectRatio: 0.62,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: ordered.length,
          itemBuilder: fushiStaggeredItemBuilder(
            (BuildContext context, int index) => _buildVolumeTile(
              theme,
              ordered[index],
              selected: isWanted(ordered[index]),
            ),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        header,
        Flexible(child: body),
      ],
    );
  }

  Widget _buildVolumeTile(
    ThemeData theme,
    BookVolumeCover cover, {
    required bool selected,
  }) {
    final ColorScheme scheme = theme.colorScheme;
    return FushiPressScale(
      child: InkWell(
        key: ValueKey<String>('book_scrape_volume_${cover.label}'),
        borderRadius: FushiBorderRadius.chip,
        onTap: _applyingVolume != null ? null : () => _useVolume(cover),
        child: Column(
          children: <Widget>[
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: FushiBorderRadius.chip,
                  border: Border.all(
                    color: selected ? scheme.primary : Colors.transparent,
                    width: 3,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: FushiBorderRadius.chip,
                  child: identical(_applyingVolume, cover)
                      ? const Center(
                          child: FushiCircularProgressIndicator(strokeWidth: 2),
                        )
                      : Image(
                          image: AppHttpImage(cover.thumbnailUrl ?? cover.url),
                          fit: BoxFit.cover,
                          width: double.infinity,
                          errorBuilder: (_, __, ___) => const SizedBox.expand(),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              t.book_scrape_volume_label(volume: cover.label),
              style: theme.textTheme.bodySmall,
              maxLines: 1,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(ThemeData theme, FushiDesignTokens tokens) {
    if (_searching) {
      return const FushiLoadingView();
    }
    final Object? failure = _searchFailure;
    if (failure != null) {
      // 搜索失败错误行：可见反馈 + 可行动原因 + 完整技术详情 + 重试指引（搜索按钮
      // 此时已恢复可点）。详情直接进界面而不是只落错误日志，见 [ScrapeFailureView]。
      return ScrapeFailureView(
        title: t.book_scrape_search_failed,
        reason: _failureReason(failure),
        detail: failure.toString(),
      );
    }
    if (_needsCredentials) {
      return Center(
        key: const ValueKey<String>('book_scrape_rakuten_unavailable'),
        child: Text(
          t.book_scrape_rakuten_unavailable,
          textAlign: TextAlign.center,
        ),
      );
    }
    if (_needsIsbn) {
      return Center(
        child: Text(t.book_scrape_isbn_required, textAlign: TextAlign.center),
      );
    }
    final Widget list = _searched && _results.isEmpty
        ? Center(child: Text(t.book_scrape_empty))
        : ListView.separated(
            itemCount: _results.length,
            separatorBuilder: (_, __) => const FushiDividerControl(height: 1),
            itemBuilder: (BuildContext context, int index) =>
                _buildTile(theme, tokens, _results[index]),
          );
    if (_hiddenNsfw == 0) return list;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildNsfwNotice(theme),
        Flexible(child: list),
      ],
    );
  }

  /// 「藏了 N 条 NSFW 结果」提示行 + 「标为 NSFW」按钮（认不出宿主时只有提示）。
  Widget _buildNsfwNotice(ThemeData theme) {
    return Padding(
      key: const ValueKey<String>('book_scrape_nsfw_hidden'),
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              t.book_scrape_nsfw_hidden(count: _hiddenNsfw),
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (widget.onMarkNsfw != null) ...<Widget>[
            const SizedBox(width: 8),
            FushiTextButton(
              key: const ValueKey<String>('book_scrape_nsfw_mark'),
              onPressed: _markingNsfw || _searching ? null : _markNsfw,
              child: Text(t.media_nsfw_switch),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTile(
    ThemeData theme,
    FushiDesignTokens tokens,
    BookScrapeCandidate candidate,
  ) {
    final List<String> metaParts = <String>[
      if (candidate.isAdult) 'NSFW',
      if (candidate.year != null) '${candidate.year}',
      if (candidate.author != null) candidate.author!,
      if (candidate.publisher != null) candidate.publisher!,
      if (candidate.series != null) candidate.series!,
      if (candidate.originalTitle != null) candidate.originalTitle!,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          ScrapeCoverPreview(
            url: candidate.coverUrl,
            headers: candidate.coverHeaders,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  candidate.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (metaParts.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      metaParts.join(' · '),
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FushiFilledButton.tonal(
            onPressed: _applyingCandidate != null
                ? null
                : () => _use(candidate),
            child: identical(_applyingCandidate, candidate)
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: FushiCircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(t.book_scrape_use),
          ),
        ],
      ),
    );
  }
}
