import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/epub/book_file_location.dart';
import 'package:fushi/src/lookup/sentence_extraction.dart';
import 'package:fushi/src/pages/base_source_page.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pdf/pdf_engine.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi/src/stats/read_unit_ledger.dart';
import 'package:fushi/utils.dart';

/// PDF 阅读器页面（Phase 1 渲染 / Phase 2 点选查词 / Phase 3 页码进度 / Phase 4 制卡）。
///
/// 与 EPUB 的 [ReaderFushiPage] 平行：那边是 WebView + JS 选区 + 章内字符偏移，这边是
/// pdfrx（PDFium）+ 字符级 `charRects` + **页码**。两者最终汇到同一批共享设施：
/// [BaseSourcePageState.searchDictionaryResult]（查词弹窗/朗读）、[ReaderPositionRepository]
/// （阅读位置）、[StudyClock]（时长统计）、[AnkiMiningContext]（制卡）。
///
/// PDF 绝对路径由 `EpubBooks` 行经 `bookMainFilePath` 还原（唯一真相源，不自拼）。
class ReaderPdfPage extends BaseSourcePage {
  const ReaderPdfPage({
    super.key,
    required super.item,
    required this.bookKey,
  });

  final String bookKey;

  @override
  BaseSourcePageState<ReaderPdfPage> createState() => _ReaderPdfPageState();
}

class _ReaderPdfPageState extends BaseSourcePageState<ReaderPdfPage>
    with WidgetsBindingObserver {
  final PdfViewerController _pdfController = PdfViewerController();

  /// 每页结构化文本缓存（`loadStructuredText` 有解析成本，点一次查一次会卡）。
  /// key = 0-based 页索引。
  final Map<int, PdfPageText> _pageTextCache = <int, PdfPageText>{};

  late final Future<_PdfBookLoad?> _loadFuture = _load();

  /// 打开时读回的书行（标题/总页数）与已保存页码，供恢复与进度落库使用。
  EpubBookRow? _bookRow;

  /// P4 写侧收敛：查词 / 制卡计数归属本书（此前 PDF 漏覆写，全落 '' 汇总桶）。
  /// 口径照抄 EPUB 阅读器（reader_fushi_page 的同名覆写）：[bookKey] 存书身份，
  /// title 恒 raw（`_bookRow?.title`，统计聚合键不过 display-title 门面）。
  @override
  ({String? bookKey, String? title})? get lookupBookIdentity =>
      (bookKey: widget.bookKey, title: _bookRow?.title);

  /// v82：位置/书签子表键（= [_bookRow] 的 `uid`，_load 时一次解析）。null =
  /// 书行缺失或旧行无 uid——相关读写跳过，不拿 bookKey 兜底写孤儿行。
  String? _bookUid;
  int _restorePageIndex = 0;

  /// 当前页（0-based）。pdfrx 的 `pageNumber` 是 1-based，落库统一 0-based
  /// （与 `ReaderPositions.sectionIndex` 的 EPUB 章 index 口径一致）。
  int _currentPageIndex = 0;
  int _lastSavedPageIndex = -1;

  /// 「读过」判据的唯一账本（2026-09-06 裁定，三域共用，见
  /// `docs/plans/2026-09-06-read-unit-ledger.md`）：**翻走即计 + 会话覆盖并集**。
  /// 单元 = 页号半开区间 `[page, page+1)`；离开一页那一刻把它（若本会话未覆盖）
  /// 记进时钟当前段的页数。跳 N 页只计跳走前那页、跳过的从未成为当前单元；往回翻 /
  /// 回到已读页并集已覆盖 → 0；无存档预置（续读时存档页是当前单元，翻走计一次）。
  /// 此前是标量水位 `_sessionMaxPageIndex`（BUG-2222：跳 N 页计 N 页），已废。
  late final ReadUnitLedger _readLedger = ReadUnitLedger(
    onCredit: (List<(int, int)> fresh) =>
        _studyClock?.addPages(readUnitsLength(fresh)),
    onRetract: (List<(int, int)> retracted) =>
        _studyClock?.retractPages(readUnitsLength(retracted)),
  );
  Timer? _saveDebounce;
  bool _restoreDone = false;

  /// v92：本页唯一的阅读时钟兼累计器（同 EPUB 侧 `_studyClock`）。页面不再持有
  /// 任何会话时长字段——旧的 `_sessionReadingMs` / `_sessionStartTime` 形态整个消失。
  StudyClock? _studyClock;

  /// 无文本层（扫描图 PDF）只提示一次。
  bool _noTextLayerNotified = false;

  /// PDF 自带目录（outline），懒加载一次；空列表 = 已加载但该 PDF 无目录。
  List<PdfOutlineNode>? _outline;

  /// 最近一次查词命中的句子与词在句中的偏移，喂制卡（[AnkiMiningContext]）。
  String _lastSentence = '';
  int _lastSentenceOffset = 0;

  /// 命中判定容差（PDF point）。点在字符矩形外但足够近仍算命中；超出即视为点在
  /// 空白/图片上不查词（对齐 pdfrx 自身 `_findTextAndIndexForPoint` 的 8pt）。
  static const double _kHitTestMarginPt = 8;

  /// 交给词典引擎的最长子串长度。引擎做最长匹配 + 去屈折并回吐命中长度，故这里
  /// **不做分词**——与视频字幕查词（取到句尾逐字查）同构。
  static const int _kLookupWindow = 30;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 进程退出兜底：把未落盘的页码 flush 掉（与 EPUB 阅读器同纪律）。
    ExitFlushRegistry.instance.register(_flushPosition);
  }

  @override
  void dispose() {
    ExitFlushRegistry.instance.unregister(_flushPosition);
    WidgetsBinding.instance.removeObserver(this);
    _saveDebounce?.cancel();
    // 离开当前页：账本结算最后一个单元（翻走即计），必须早于 flush / 时钟 dispose。
    _readLedger.leave();
    // dispose 里只能 fire-and-forget（不能 await）；正常退出走 onSourcePagePop
    // 的 await 路径，这里是崩溃/异常拆栈时的兜底。
    unawaited(_flushPosition());
    _studyClock?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // 切屏 / 进后台自动暂停阅读计时（BUG-892）：stop 先结算失焦瞬间的部分窗口再
      // 封段落库；顺序同 EPUB 侧。
      unawaited(_studyClock?.stop());
      unawaited(_flushPosition());
    } else if (state == AppLifecycleState.resumed) {
      // BUG-892 / BUG-1052: 后台那段靠「时钟停着」丢弃，不再重锚墙钟基准。
      _studyClock?.start();
    }
  }

  @override
  Future<void> onSourcePagePop() async {
    // 离开当前页：账本结算最后一个单元（翻走即计），再落盘。
    _readLedger.leave();
    // 返回书架的正常路径：await 落盘，保证书架 recency/进度立刻正确。
    await _flushPosition();
    await _studyClock?.stop();
  }

  // ── 加载 / 恢复 ───────────────────────────────────────────────────────

  Future<_PdfBookLoad?> _load() async {
    await PdfEngine.ensureInitialized();
    final FushiDatabase db = appModel.database;
    final EpubBookRow? row = await db.getEpubBook(widget.bookKey);
    if (row == null) return null;
    final String path = bookMainFilePath(row);
    if (!File(path).existsSync()) return null;

    _bookRow = row;
    // v82：位置/书签键 = EpubBooks.uid（行在手直接取；空 uid 视同缺失，读写跳过）。
    _bookUid = row.uid.isEmpty ? null : row.uid;

    // 读回已保存页码（sectionIndex = 0-based 页）。越界守卫按总页数。
    final ReaderPosition? saved = _bookUid == null
        ? null
        : await ReaderPositionRepository(db).findByBookUid(_bookUid!);
    if (saved != null &&
        saved.sectionIndex >= 0 &&
        saved.sectionIndex < row.chapterCount) {
      _restorePageIndex = saved.sectionIndex;
      _currentPageIndex = saved.sectionIndex;
      _lastSavedPageIndex = saved.sectionIndex;
    }

    // v92：唯一时钟（同 EPUB 侧）；空闲门 + 生命周期前台门只对阅读面生效。
    _studyClock ??= StudyClock(
      database: db,
      mediaKind: kActivityMediaBook,
      mediaKey: widget.bookKey,
      title: row.title,
      format: BookFormat.pdf.dbValue,
      idleTimeout: appModel.readingIdleTimeout,
      onWriteError: (Object e, StackTrace st) =>
          ErrorLogService.instance.log('StudyClock.write(pdf)', e, st),
    );
    _studyClock!.start();
    return _PdfBookLoad(path: path, row: row);
  }

  void _onViewerReady() {
    if (_restoreDone) return;
    _restoreDone = true;
    if (_restorePageIndex <= 0) return;
    // pdfrx 页码是 1-based。
    unawaited(_pdfController.goToPage(pageNumber: _restorePageIndex + 1));
  }

  // ── 页码进度 ──────────────────────────────────────────────────────────

  void _onPageChanged(int? pageNumber) {
    if (pageNumber == null) return;
    final int pageIndex = pageNumber - 1;
    if (pageIndex < 0) return;
    // v92 阅读空闲门：翻页 = 用户输入。
    _studyClock?.touch();
    // 翻走即计：到达新页 = 离开上一页，账本结算上一页（首次覆盖才 addPages，与时长
    // 同段同 uid）；本页要等下次翻走才计。
    _readLedger.arrive(pageIndex, pageIndex + 1);
    _currentPageIndex = pageIndex;
    // 500ms debounce（与 EPUB 阅读器同口径）：连续翻页只落最后一次。
    if (pageIndex == _lastSavedPageIndex) return;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_persistPosition(pageIndex));
    });
  }

  Future<void> _persistPosition(int pageIndex) async {
    _lastSavedPageIndex = pageIndex;
    final FushiDatabase db = appModel.database;
    // v82：uid 缺失时只跳过位置写入（不拿 bookKey 兜底造孤儿行）；下方「已读完」
    // 标记走 bookKey 键的 epub_books 表，照常执行。
    final String? bookUid = _bookUid;
    if (bookUid != null) {
      try {
        await ReaderPositionRepository(db).save(
          bookUid: bookUid,
          sectionIndex: pageIndex,
          normCharOffset: 0,
          // PDF 无章内字符偏移。**必须显式传值**（传 null 会掉进 EPUB 专用的
          // 「跨 section 精确锚失效」启发式）。
          charOffset: 0,
        );
      } catch (e, stack) {
        ErrorLogService.instance
            .log('ReaderPdfPage._persistPosition', e, stack);
      }
    }
    // 翻到最后一页 → 幂等写「已读完」（判据用总页数，PDF 无 chapters）。
    final int pageCount = _bookRow?.chapterCount ?? 0;
    if (pageCount > 0 && pageIndex >= pageCount - 1) {
      try {
        await db.markEpubBookCompletedIfUnset(widget.bookKey, DateTime.now());
      } catch (e, stack) {
        ErrorLogService.instance.log('ReaderPdfPage.markCompleted', e, stack);
      }
    }
  }

  Future<void> _flushPosition() async {
    _saveDebounce?.cancel();
    if (_bookRow == null) return;
    if (_currentPageIndex != _lastSavedPageIndex) {
      await _persistPosition(_currentPageIndex);
    }
    await _flushReadingStats();
  }

  /// 把「上一次 tick 到现在」的部分窗口结算并落库（不停表）。PDF 无字数，时钟只记
  /// 时长；「页数」绝不塞进字数口径。
  Future<void> _flushReadingStats() async {
    await _studyClock?.flushNow();
  }

  // ── Phase 2：点选查词 ─────────────────────────────────────────────────

  /// 取（并缓存）某页的结构化文本。[pageIndex] 为 0-based。
  Future<PdfPageText?> _pageText(int pageIndex, PdfPage page) async {
    final PdfPageText? cached = _pageTextCache[pageIndex];
    if (cached != null) return cached;
    try {
      final PdfPageText text = await page.loadStructuredText();
      _pageTextCache[pageIndex] = text;
      return text;
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderPdfPage.loadStructuredText', e, stack);
      return null;
    }
  }

  /// 单击正文即查词（对齐视频字幕「点字查词」，日语最顺手）。
  ///
  /// [documentPosition] 是 pdfrx 的**文档坐标**（整册布局空间，未缩放）。流程：
  /// 文档点 → 命中页 → 页内 PDF 坐标 → 最近字符索引 → 从该字符起取子串当查询词 →
  /// 字符矩形换算成屏幕矩形当弹窗锚点。
  Future<void> _lookupAtDocumentPosition(Offset documentPosition) async {
    if (!_pdfController.isReady) return;
    final PdfPageLayout layout = _pdfController.layout;
    final List<PdfPage> pages = _pdfController.pages;

    for (int i = 0; i < pages.length && i < layout.pageLayouts.length; i++) {
      final Rect pageRect = layout.pageLayouts[i];
      if (!pageRect.contains(documentPosition)) continue;

      final PdfPage page = pages[i];
      final PdfPageText? text = await _pageText(i, page);
      if (!mounted) return;
      if (text == null || text.charRects.isEmpty) {
        _notifyNoTextLayer();
        return;
      }

      // 文档坐标 → 页内 PDF 坐标（原点左下、Y 轴向上、单位 point）。
      final PdfPoint pt = documentPosition
          .translate(-pageRect.left, -pageRect.top)
          .toPdfPoint(page: page, scaledPageSize: pageRect.size);

      final int? charIndex = _closestCharIndex(text.charRects, pt);
      if (charIndex == null) return; // 点在空白/图片上：不查词，也不关栈。

      await _lookupFromChar(
        page: page,
        pageRect: pageRect,
        text: text,
        charIndex: charIndex,
      );
      return;
    }
  }

  /// 在 [charRects] 里找命中（或容差内最近）的字符索引；超出容差返回 null。
  static int? _closestCharIndex(List<PdfRect> charRects, PdfPoint pt) {
    double bestDistanceSquared = double.infinity;
    int? bestIndex;
    for (int c = 0; c < charRects.length; c++) {
      final PdfRect rect = charRects[c];
      if (rect.containsPoint(pt)) return c;
      final double d2 = rect.distanceSquaredTo(pt);
      if (d2 < bestDistanceSquared) {
        bestDistanceSquared = d2;
        bestIndex = c;
      }
    }
    if (bestIndex == null) return null;
    if (bestDistanceSquared > _kHitTestMarginPt * _kHitTestMarginPt) {
      return null;
    }
    return bestIndex;
  }

  /// 由命中字符发起查词：组装查询串 + 句子（喂制卡/收藏）+ 屏幕锚点矩形。
  Future<void> _lookupFromChar({
    required PdfPage page,
    required Rect pageRect,
    required PdfPageText text,
    required int charIndex,
  }) async {
    final String fullText = text.fullText;
    if (charIndex < 0 || charIndex >= fullText.length) return;

    // 不分词：从命中字符起取一段交给引擎做最长匹配（引擎回吐真实命中长度）。
    final String searchTerm = fullText.substring(
      charIndex,
      math.min(charIndex + _kLookupWindow, fullText.length),
    );
    if (searchTerm.trim().isEmpty) return;

    // 整句喂给制卡/收藏通道（复用阅读器同款 [extractSentenceAt]，同一套句读口径）。
    //
    // PDF 的 fullText 在**视觉换行**处普遍带 \n/\r，而换行是分句符——直接分句会把每个
    // 视觉行切成一句，制卡拿到半截话。这里用**等长替换**把 \n/\r 换成空格（1 字符换
    // 1 字符，charIndex 与 charRects 的索引对齐**完全不变**），只让句读标点决定句子边界。
    final String flattened =
        fullText.replaceAll('\n', ' ').replaceAll('\r', ' ');
    final SentenceExtractionResult extracted =
        extractSentenceAt(flattened, charIndex, 1);
    _lastSentence = extracted.sentence.trim();
    _lastSentenceOffset = extracted.selStart;
    if (_lastSentence.isNotEmpty) {
      appModel.currentMediaSource?.setCurrentSentence(
        selection: FushiTextSelection(text: _lastSentence),
      );
    }

    final Rect? selectionRect = _screenRectForChar(
      page: page,
      pageRect: pageRect,
      charRect: text.charRects[charIndex],
    );
    if (selectionRect == null || !mounted) return;

    prunePopupStack(0);
    final int highlightCount = await searchDictionaryResult(
      searchTerm: searchTerm,
      selectionRect: selectionRect,
    );
    if (!mounted || highlightCount <= 0) return;

    // 把引擎实际命中的词在 PDF 上做原生蓝选高亮（复用 pdfrx 选区，零手绘），
    // 与 EPUB 查词后高亮原文同语义。两端 inclusive。
    _highlightMatchedTerm(text, charIndex, highlightCount);
  }

  /// 字符矩形（PDF 页坐标）→ 屏幕全局矩形（弹窗锚点坐标系）。
  Rect? _screenRectForChar({
    required PdfPage page,
    required Rect pageRect,
    required PdfRect charRect,
  }) {
    final Rect documentRect =
        charRect.toRectInDocument(page: page, pageRect: pageRect);
    final Rect? localRect =
        _pdfController.doc2local.rectToLocal(context, documentRect);
    if (localRect == null) return null;
    final RenderBox? box = _pdfController.renderBox;
    if (box == null) return null;
    final Offset globalTopLeft = box.localToGlobal(localRect.topLeft);
    return globalTopLeft & localRect.size;
  }

  void _highlightMatchedTerm(PdfPageText text, int charIndex, int length) {
    try {
      final int endIndex =
          math.min(charIndex + length - 1, text.charRects.length - 1);
      if (endIndex < charIndex) return;
      unawaited(
        _pdfController.textSelectionDelegate.setTextSelectionPointRange(
          PdfTextSelectionRange.fromPoints(
            PdfTextSelectionPoint(text, charIndex),
            PdfTextSelectionPoint(text, endIndex),
          ),
        ),
      );
    } catch (e, stack) {
      // 高亮是锦上添花，失败绝不影响已弹出的查词结果。
      ErrorLogService.instance.log('ReaderPdfPage.highlight', e, stack);
    }
  }

  void _notifyNoTextLayer() {
    if (_noTextLayerNotified) return;
    _noTextLayerNotified = true;
    FushiToast.show(msg: t.pdf_no_text_layer, severity: ToastSeverity.error);
  }

  // ── Phase 5：书签（复用 EPUB 的 Bookmarks 表）───────────────────────

  /// 在当前页加书签。PDF 复用同一张 `Bookmarks` 表：`sectionIndex` 存 0-based 页码
  /// （与 [ReaderPositions] 同口径），`normCharOffset` 恒 0。键 = 书 uid（v82），
  /// PDF 行已在 `EpubBooks`，删书时由 `deleteEpubBook` 显式级联清掉，零额外接线。
  Future<void> _addBookmarkAtCurrentPage() async {
    final EpubBookRow? row = _bookRow;
    final String? bookUid = _bookUid;
    if (row == null || bookUid == null) return;
    try {
      await BookmarkRepository(appModel.database).addBookmark(
        bookUid,
        Bookmark(
          sectionIndex: _currentPageIndex,
          normCharOffset: 0,
          // 标签用页序（1-based，与页码指示器一致）；纯数字免 i18n。
          label: 'P.${_currentPageIndex + 1}',
          createdAt: DateTime.now(),
          bookUid: bookUid,
          bookTitle: row.title,
        ),
      );
      if (!mounted) return;
      FushiToast.show(
          msg: t.pdf_bookmark_added, severity: ToastSeverity.success);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderPdfPage.addBookmark', e, stack);
    }
  }

  Future<void> _showBookmarks() async {
    final String? bookUid = _bookUid;
    if (bookUid == null) return;
    List<Bookmark> bookmarks;
    try {
      // legacyBookKey：`bookmarks_<bookKey>` 遗留偏好一次性迁进 DB（键换 uid）。
      bookmarks = await BookmarkRepository(appModel.database)
          .getBookmarks(bookUid, legacyBookKey: widget.bookKey);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderPdfPage.getBookmarks', e, stack);
      return;
    }
    if (!mounted) return;
    if (bookmarks.isEmpty) {
      FushiToast.show(msg: t.pdf_bookmarks_empty, severity: ToastSeverity.info);
      return;
    }
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => _PdfBookmarkSheet(
        bookmarks: bookmarks,
        onSelect: (Bookmark bookmark) {
          Navigator.of(context).pop();
          unawaited(
            _pdfController.goToPage(pageNumber: bookmark.sectionIndex + 1),
          );
        },
        onDelete: (Bookmark bookmark) async {
          final int? id = bookmark.id;
          if (id == null) return;
          try {
            await BookmarkRepository(appModel.database).removeBookmarkById(id);
          } catch (e, stack) {
            ErrorLogService.instance
                .log('ReaderPdfPage.removeBookmark', e, stack);
          }
        },
      ),
    );
  }

  // ── Phase 5：目录（PDF outline）导航 ──────────────────────────────────

  /// 打开 PDF 自带目录（outline / bookmarks）。懒加载：只在用户点开时解析一次。
  Future<void> _showOutline() async {
    if (!_pdfController.isReady) return;
    List<PdfOutlineNode> outline = _outline ?? const <PdfOutlineNode>[];
    if (_outline == null) {
      try {
        outline = await _pdfController.document.loadOutline();
        _outline = outline;
      } catch (e, stack) {
        ErrorLogService.instance.log('ReaderPdfPage.loadOutline', e, stack);
        _outline = const <PdfOutlineNode>[];
        outline = _outline!;
      }
    }
    if (!mounted) return;
    if (outline.isEmpty) {
      FushiToast.show(msg: t.pdf_outline_empty, severity: ToastSeverity.info);
      return;
    }
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => _PdfOutlineSheet(
        nodes: outline,
        onSelect: (PdfOutlineNode node) {
          Navigator.of(context).pop();
          if (node.dest != null) {
            unawaited(_pdfController.goToDest(node.dest));
          }
        },
      ),
    );
  }

  // ── Phase 4：制卡 ─────────────────────────────────────────────────────

  /// 查词弹窗里点「+」制卡。句子来自最近一次查词（[_lastSentence]），卡图是**当前页
  /// 栅格化 PNG**（PDF 没有视频帧/封面图可用，页面本身就是最有信息量的图）。
  @override
  Future<MinePopupResult> onMineFromPopup(Map<String, String> fields) async {
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    Directory? tempDir;
    try {
      final String sentence =
          _lastSentence.isNotEmpty ? _lastSentence : (fields['sentence'] ?? '');

      // 当前页栅格化成临时 PNG 当卡图；失败则无图落卡（不阻断制卡）。
      String? coverPath;
      final Uint8List? pagePng = await _renderCurrentPagePng();
      if (pagePng != null) {
        tempDir = await Directory.systemTemp.createTemp('fushi_pdf_mine_');
        final File file = File(p.join(tempDir.path, 'page.png'));
        await file.writeAsBytes(pagePng, flush: true);
        coverPath = file.path;
      }

      final AnkiMiningContext miningContext = AnkiMiningContext(
        sentence: sentence,
        documentTitle: _bookRow?.title,
        coverPath: coverPath,
        sentenceOffset: _lastSentenceOffset,
        source: AnkiMiningSource.book,
        bookTitleTag: appModel.autoAddBookNameToTags
            ? BaseAnkiRepository.sanitizeTitleTag(_bookRow?.title)
            : null,
      );

      FushiToast.showMine(
        msg: t.card_mining_pending,
        status: MineToastStatus.pending,
      );
      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: jsonEncode(fields),
        context: miningContext,
      );
      final described = describeMineOutcome(outcome);
      if (described.record) {
        unawaited(_recordMinedCount());
      }
      FushiToast.showMine(msg: described.message, status: described.status);
      if (described.success) {
        return MinePopupResult(ankiConnect: true, noteId: outcome.noteId);
      }
      return MinePopupResult.failed(outcome);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderPdfPage.onMineFromPopup', e, stack);
      return const MinePopupResult();
    } finally {
      // 卡图已由 repo 拷进 Anki 媒体库，临时目录用完即删。
      if (tempDir != null) {
        try {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        } catch (_) {
          // 临时文件清理失败无害（系统临时目录会被回收）。
        }
      }
    }
  }

  Future<void> _recordMinedCount() async {
    // P4 写侧收敛：走 DB 复合入口（同事务全局汇总 + per-book 计数），并补上此前
    // 漏写的书身份（旧代码只写全局 addMiningCount，per-book 恒漏 → 恒等式单边偏差）。
    final ({String? bookKey, String? title})? identity = lookupBookIdentity;
    try {
      await appModel.database.recordMiningEvent(
        bookKey: identity?.bookKey,
        title: identity?.title ?? '',
        sourceType: kStatSourceBook,
        at: DateTime.now(),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderPdfPage.recordMined', e, stack);
    }
  }

  /// 当前页栅格化成 PNG 字节（2x 提清晰度）。纯 CPU/FFI 路径，不依赖 GPU 帧回读。
  Future<Uint8List?> _renderCurrentPagePng() async {
    try {
      if (!_pdfController.isReady) return null;
      final List<PdfPage> pages = _pdfController.pages;
      if (_currentPageIndex < 0 || _currentPageIndex >= pages.length) {
        return null;
      }
      final PdfPage page = pages[_currentPageIndex];
      final PdfImage? rendered = await page.render(
        fullWidth: page.width * 2,
        fullHeight: page.height * 2,
        backgroundColor: 0xFFFFFFFF,
      );
      if (rendered == null) return null;
      try {
        return await _bgraToPng(
          rendered.pixels,
          rendered.width,
          rendered.height,
        );
      } finally {
        rendered.dispose();
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderPdfPage.renderPage', e, stack);
      return null;
    }
  }

  static Future<Uint8List?> _bgraToPng(
    Uint8List bgra,
    int width,
    int height,
  ) async {
    final ui.ImmutableBuffer buffer =
        await ui.ImmutableBuffer.fromUint8List(bgra);
    final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.bgra8888,
    );
    final ui.Codec codec = await descriptor.instantiateCodec();
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ui.Image image = frame.image;
    try {
      final ByteData? png =
          await image.toByteData(format: ui.ImageByteFormat.png);
      return png?.buffer.asUint8List();
    } finally {
      image.dispose();
      codec.dispose();
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final String title = widget.item?.title ?? _bookRow?.title ?? '';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        // 在 await 之前拿住 navigator：onWillPop 是异步长操作（落位置 + closeMedia），
        // 之后再用 context 会跨 async gap。
        final NavigatorState navigator = Navigator.of(context);
        final bool shouldPop = await onWillPop();
        if (!mounted || !shouldPop) return;
        navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: <Widget>[
            _buildPageIndicator(),
            IconButton(
              tooltip: t.pdf_bookmarks,
              icon: const Icon(Icons.bookmark_add_outlined),
              onPressed: () => unawaited(_addBookmarkAtCurrentPage()),
            ),
            IconButton(
              tooltip: t.pdf_bookmarks,
              icon: const Icon(Icons.bookmarks_outlined),
              onPressed: () => unawaited(_showBookmarks()),
            ),
            IconButton(
              tooltip: t.pdf_outline,
              icon: const Icon(Icons.list_alt_outlined),
              onPressed: () => unawaited(_showOutline()),
            ),
          ],
        ),
        body: Stack(
          children: <Widget>[
            Positioned.fill(child: _buildViewer()),
            // 查词弹窗层：必须在树里，否则 searchDictionaryResult 查到也不显示。
            buildDictionary(),
          ],
        ),
      ),
    );
  }

  /// 页码指示器「12 / 345」。纯数字，无需 i18n。
  Widget _buildPageIndicator() {
    return AnimatedBuilder(
      animation: _pdfController,
      builder: (BuildContext context, Widget? child) {
        if (!_pdfController.isReady) return const SizedBox.shrink();
        final int? page = _pdfController.pageNumber;
        if (page == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Center(
            child: Text(
              '$page / ${_pdfController.pageCount}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        );
      },
    );
  }

  Widget _buildViewer() {
    return FutureBuilder<_PdfBookLoad?>(
      future: _loadFuture,
      builder: (BuildContext context, AsyncSnapshot<_PdfBookLoad?> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return buildLoading();
        }
        final _PdfBookLoad? load = snapshot.data;
        if (load == null) {
          return Center(child: Text(t.book_file_not_found));
        }
        return PdfViewer.file(
          load.path,
          controller: _pdfController,
          params: PdfViewerParams(
            backgroundColor: const Color(0xFF3A3A3A),
            onViewerReady: (_, __) => _onViewerReady(),
            onPageChanged: _onPageChanged,
            // 单击正文即查词；返回 true 吃掉 tap，阻止 pdfrx 默认清选区行为。
            onGeneralTap: (
              BuildContext context,
              PdfViewerController controller,
              PdfViewerGeneralTapHandlerDetails details,
            ) {
              if (details.type != PdfViewerGeneralTapType.tap) return false;
              if (details.tapOn == PdfViewerPart.background) return false;
              unawaited(_lookupAtDocumentPosition(details.documentPosition));
              return true;
            },
          ),
        );
      },
    );
  }
}

/// [_ReaderPdfPageState._load] 的结果：PDF 磁盘路径 + 其 `EpubBooks` 行。
class _PdfBookLoad {
  const _PdfBookLoad({required this.path, required this.row});

  final String path;
  final EpubBookRow row;
}

/// PDF 书签弹层：列出本书书签（按创建时间倒序），点击跳页、删除即时从列表移除。
class _PdfBookmarkSheet extends StatefulWidget {
  const _PdfBookmarkSheet({
    required this.bookmarks,
    required this.onSelect,
    required this.onDelete,
  });

  final List<Bookmark> bookmarks;
  final void Function(Bookmark bookmark) onSelect;
  final Future<void> Function(Bookmark bookmark) onDelete;

  @override
  State<_PdfBookmarkSheet> createState() => _PdfBookmarkSheetState();
}

class _PdfBookmarkSheetState extends State<_PdfBookmarkSheet> {
  late final List<Bookmark> _items = List<Bookmark>.of(widget.bookmarks);

  @override
  Widget build(BuildContext context) {
    return FushiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.82,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.pdf_bookmarks,
        leadingIcon: Icons.bookmarks_outlined,
        body: _items.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Center(child: Text(t.pdf_bookmarks_empty)),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: _items.length,
                itemBuilder: (BuildContext context, int index) {
                  final Bookmark bookmark = _items[index];
                  return FushiListItem(
                    leading: const Icon(Icons.bookmark_outline),
                    title: Text(bookmark.label),
                    trailing: IconButton(
                      tooltip: t.dialog_delete,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await widget.onDelete(bookmark);
                        if (!mounted) return;
                        setState(() => _items.removeAt(index));
                      },
                    ),
                    onTap: () => widget.onSelect(bookmark),
                  );
                },
              ),
      ),
    );
  }
}

/// PDF 目录弹层：把 pdfrx 的树形 [PdfOutlineNode] 拍平成带缩进的可点列表。
///
/// 用缩进而非可展开树：PDF 目录通常只有 2-3 层且条目不多，拍平一次可见全貌、点一下
/// 就跳，比逐层展开少两次交互。
class _PdfOutlineSheet extends StatelessWidget {
  const _PdfOutlineSheet({required this.nodes, required this.onSelect});

  final List<PdfOutlineNode> nodes;
  final void Function(PdfOutlineNode node) onSelect;

  /// 深度优先拍平，记录每个节点的层级用于缩进。
  static List<({PdfOutlineNode node, int depth})> _flatten(
    List<PdfOutlineNode> nodes, [
    int depth = 0,
  ]) {
    final List<({PdfOutlineNode node, int depth})> out =
        <({PdfOutlineNode node, int depth})>[];
    for (final PdfOutlineNode node in nodes) {
      out.add((node: node, depth: depth));
      if (node.children.isNotEmpty) {
        out.addAll(_flatten(node.children, depth + 1));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final List<({PdfOutlineNode node, int depth})> flat = _flatten(nodes);
    return FushiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.82,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.pdf_outline,
        leadingIcon: Icons.list_alt_outlined,
        body: ListView.builder(
          shrinkWrap: true,
          itemCount: flat.length,
          itemBuilder: (BuildContext context, int index) {
            final ({PdfOutlineNode node, int depth}) entry = flat[index];
            final int? pageNumber = entry.node.dest?.pageNumber;
            return FushiListItem(
              // 层级用左内边距表达（FushiListItem 的 padding 是整体内边距）。
              padding:
                  EdgeInsets.only(left: 8.0 + entry.depth * 16.0, right: 8),
              title: Text(
                entry.node.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              titleMaxLines: 2,
              trailing: pageNumber != null ? Text('$pageNumber') : null,
              onTap: () => onSelect(entry.node),
            );
          },
        ),
      ),
    );
  }
}
