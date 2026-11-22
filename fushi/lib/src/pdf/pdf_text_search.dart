import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:fushi/src/pdf/pdf_text_sections.dart';

/// PDF 阅读器全文搜索（拍板台 KN4kdP4JB8：只搜文本层，结果列表跳页 + 页上高亮，
/// 无文本层明确提示，OCR 搜索不做）。
///
/// 匹配口径与有声书字幕匹配同一套归一化（[AudioTextNormalizer.normalizeWithOffsets]，
/// Rust 折叠内核）：去掉标点 / 空白 / 换行，全角→半角、大小写与片假名→平假名折叠。
/// PDF 文本层按行出字（`fullText` 行间有换行），日文竖排 / 横排的一句话常被折行
/// 切开；直接拿原文 `indexOf` 会漏掉所有跨行命中，归一化后再找就没有这个问题。
/// 命中区间经 [pdfRawRangeForNormRange] 换回 `fullText` 码元下标（含中间被剥掉的
/// 换行 / 标点），再按 pdfrx 文本片段拆成逐行矩形画高亮。

/// 一页的搜索素材：文本层全文（`loadStructuredText().fullText`，与 `charRects`
/// 逐码元对齐）+ 把 `fullText` 码元区间 `[start, end)` 换成该页 PDF 坐标逐行矩形
/// 的函数。
typedef PdfSearchPageSource = ({
  String fullText,
  List<PdfRect> Function(int start, int end) rectsFor,
});

/// 读第 [pageIndex] 页（0 起）的搜索素材；文本层读失败返回 null（只记日志，跳过该页）。
typedef PdfSearchPageLoader =
    Future<PdfSearchPageSource?> Function(int pageIndex);

/// 归一化函数（默认 [AudioTextNormalizer.normalizeWithOffsets]，单测注入手写映射）。
typedef PdfSearchNormalizer = NormalizedTextWithOffsets Function(String text);

/// 在一页文本里找 [normalizedQuery]（已归一化）的全部不重叠命中，返回 `fullText`
/// 码元区间（按出现顺序）。
///
/// [normalizedQuery] 为空（查询全是标点 / 空白，归一化后什么都不剩）时退回原文
/// 字面匹配 [rawQuery]，让「搜个书名号」这种查询也有结果。
List<({int start, int end})> pdfFindQueryInPage({
  required String fullText,
  required NormalizedTextWithOffsets normalized,
  required String normalizedQuery,
  required String rawQuery,
}) {
  final List<({int start, int end})> out = <({int start, int end})>[];
  if (normalizedQuery.isEmpty) {
    if (rawQuery.isEmpty) return out;
    int from = 0;
    while (true) {
      final int at = fullText.indexOf(rawQuery, from);
      if (at < 0) break;
      out.add((start: at, end: at + rawQuery.length));
      from = at + rawQuery.length;
    }
    return out;
  }
  final String text = normalized.text;
  int from = 0;
  while (true) {
    final int at = text.indexOf(normalizedQuery, from);
    if (at < 0) break;
    final int normEnd = at + normalizedQuery.length;
    final ({int start, int end})? raw = pdfRawRangeForNormRange(
      normalized,
      normStart: at,
      normEnd: normEnd,
    );
    if (raw != null && raw.end <= fullText.length) out.add(raw);
    from = normEnd;
  }
  return out;
}

/// 结果列表里显示的上下文片段：命中前后各取 [radius] 个码元，换行 / 回车剥掉
/// （PDF 文本层按行断，日文正文里塞空格反而难读），截断处补省略号。返回片段与
/// 命中在片段里的区间。截取边界不落在代理对中间（`𠮟` 这类扩展 B 汉字、emoji
/// 是两个码元），否则片段两端会出现孤立代理、渲染成乱码。
({String text, int matchStart, int matchEnd}) pdfSearchSnippet(
  String fullText, {
  required int start,
  required int end,
  int radius = 24,
}) {
  int from = (start - radius).clamp(0, fullText.length);
  int to = (end + radius).clamp(end, fullText.length);
  if (from > 0 && _isLowSurrogate(fullText.codeUnitAt(from))) from--;
  if (to < fullText.length && _isLowSurrogate(fullText.codeUnitAt(to))) to++;
  final StringBuffer buf = StringBuffer();
  int matchStart = 0;
  int matchEnd = 0;
  if (from > 0) buf.write('…');
  for (int i = from; i < to; i++) {
    if (i == start) matchStart = buf.length;
    if (i == end) matchEnd = buf.length;
    final int unit = fullText.codeUnitAt(i);
    if (unit == 0x0A || unit == 0x0D) continue;
    buf.writeCharCode(unit);
  }
  if (end >= to) matchEnd = buf.length;
  if (to < fullText.length) buf.write('…');
  return (text: buf.toString(), matchStart: matchStart, matchEnd: matchEnd);
}

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// 一条搜索命中。
@immutable
class PdfTextSearchHit {
  const PdfTextSearchHit({
    required this.pageIndex,
    required this.start,
    required this.end,
    required this.rects,
    required this.snippet,
    required this.snippetMatchStart,
    required this.snippetMatchEnd,
  });

  /// 所在页（0 起）。
  final int pageIndex;

  /// 页 `fullText` 的码元区间 `[start, end)`。
  final int start;
  final int end;

  /// 该页 PDF 坐标下的逐行矩形（画高亮 / 跳转时露出用）。
  final List<PdfRect> rects;

  /// 结果列表片段与命中在片段里的区间。
  final String snippet;
  final int snippetMatchStart;
  final int snippetMatchEnd;
}

/// 搜索状态。
enum PdfTextSearchStatus {
  /// 还没搜 / 已清空。
  idle,

  /// 正在逐页搜。
  searching,

  /// 搜完了（可能 0 命中）。
  done,

  /// 搜完了，但整本没有一页有文本层（扫描图 PDF）——要明确告诉用户搜不了。
  noTextLayer,

  /// 每一页的文本层都读失败。
  failed,
}

/// PDF 全文搜索会话：逐页读文本层找命中、持有结果与「当前命中」，阅读页据此画高亮、
/// 跳页，搜索面板据此列结果。由阅读页持有（关掉面板再打开，上次的结果还在）。
class PdfTextSearchController extends ChangeNotifier {
  PdfTextSearchController({
    required PdfSearchPageLoader loadPage,
    PdfSearchNormalizer? normalize,
    this.maxHits = kPdfSearchMaxHits,
  }) : _loadPage = loadPage,
       _normalize = normalize ?? AudioTextNormalizer.normalizeWithOffsets;

  /// 结果上限：搜「の」这种字能在一本书里命中上万次，列表与高亮都没意义，到上限即停。
  static const int kPdfSearchMaxHits = 1000;

  final PdfSearchPageLoader _loadPage;
  final PdfSearchNormalizer _normalize;
  final int maxHits;

  /// 代次：新搜索 / 清空 / 销毁时递增，旧搜索的循环见代次变了就退出。
  int _generation = 0;
  bool _disposed = false;

  PdfTextSearchStatus _status = PdfTextSearchStatus.idle;
  PdfTextSearchStatus get status => _status;

  String _query = '';

  /// 当前（或最近一次）搜索的查询词（已 trim）。
  String get query => _query;

  final List<PdfTextSearchHit> _hits = <PdfTextSearchHit>[];

  /// 只读视图（不拷贝）：页绘制回调每画一页都要读，上千条命中时拷贝一遍太浪费。
  late final List<PdfTextSearchHit> hits =
      UnmodifiableListView<PdfTextSearchHit>(_hits);

  /// 页（0 起）→ 该页命中在 [hits] 里的下标（画高亮用，免得每画一页扫全表）。
  final Map<int, List<int>> _hitsByPage = <int, List<int>>{};

  int? _currentIndex;

  /// 当前选中的命中（跳过去、画成强调色的那条）；null = 还没选。
  int? get currentIndex => _currentIndex;

  PdfTextSearchHit? get currentHit {
    final int? i = _currentIndex;
    return i == null ? null : _hits[i];
  }

  int _searchedPages = 0;
  int _pageCount = 0;

  /// 已搜页数 / 总页数（进度条用）。
  int get searchedPages => _searchedPages;
  int get pageCount => _pageCount;

  bool _truncated = false;

  /// 命中达到 [maxHits] 后停搜，只列前 [maxHits] 条。
  bool get truncated => _truncated;

  /// 有结果可导航（上一个 / 下一个 / 页上高亮）。
  bool get hasHits => _hits.isNotEmpty;

  /// 第 [pageIndex] 页（0 起）的命中下标（升序）；没有返回空表。
  List<int> hitIndicesOnPage(int pageIndex) =>
      _hitsByPage[pageIndex] ?? const <int>[];

  /// 从第一页搜到 [pageCount] 页。空查询等于 [clear]。同一查询已搜完 / 正在搜时
  /// 不重搜（回车连按、面板重开时重提交）。
  Future<void> search(String rawQuery, {required int pageCount}) async {
    final String query = rawQuery.trim();
    if (query.isEmpty) {
      clear();
      return;
    }
    if (query == _query &&
        _pageCount == pageCount &&
        (_status == PdfTextSearchStatus.searching ||
            _status == PdfTextSearchStatus.done ||
            _status == PdfTextSearchStatus.noTextLayer)) {
      return;
    }
    final int generation = ++_generation;
    _query = query;
    _hits.clear();
    _hitsByPage.clear();
    _currentIndex = null;
    _searchedPages = 0;
    _pageCount = pageCount;
    _truncated = false;
    _status = PdfTextSearchStatus.searching;
    notifyListeners();

    final String normalizedQuery = _normalize(query).text;
    bool anyText = false;
    bool anyLoaded = false;
    for (int page = 0; page < pageCount; page++) {
      final PdfSearchPageSource? source = await _loadPage(page);
      if (_disposed || generation != _generation) return;
      _searchedPages = page + 1;
      bool changed = false;
      if (source != null) {
        anyLoaded = true;
        final String fullText = source.fullText;
        final NormalizedTextWithOffsets normalized = _normalize(fullText);
        if (normalized.text.isNotEmpty || fullText.trim().isNotEmpty) {
          anyText = true;
        }
        for (final ({int start, int end}) range in pdfFindQueryInPage(
          fullText: fullText,
          normalized: normalized,
          normalizedQuery: normalizedQuery,
          rawQuery: query,
        )) {
          if (_hits.length >= maxHits) {
            _truncated = true;
            break;
          }
          final ({String text, int matchStart, int matchEnd}) snippet =
              pdfSearchSnippet(fullText, start: range.start, end: range.end);
          (_hitsByPage[page] ??= <int>[]).add(_hits.length);
          _hits.add(
            PdfTextSearchHit(
              pageIndex: page,
              start: range.start,
              end: range.end,
              rects: source.rectsFor(range.start, range.end),
              snippet: snippet.text,
              snippetMatchStart: snippet.matchStart,
              snippetMatchEnd: snippet.matchEnd,
            ),
          );
          changed = true;
        }
      }
      if (_truncated) break;
      // 有新命中立刻刷新（结果流式出现）；没命中的页每 8 页刷一次进度，免得
      // 上千页的书每页重建一次结果列表。
      if (changed || page % 8 == 7) notifyListeners();
    }
    if (_disposed || generation != _generation) return;
    _status = !anyLoaded && pageCount > 0
        ? PdfTextSearchStatus.failed
        : (!anyText && pageCount > 0)
        ? PdfTextSearchStatus.noTextLayer
        : PdfTextSearchStatus.done;
    notifyListeners();
  }

  /// 选中第 [index] 条命中（列表点选 / 上一个 / 下一个），返回它；越界返回 null。
  PdfTextSearchHit? select(int index) {
    if (index < 0 || index >= _hits.length) return null;
    _currentIndex = index;
    notifyListeners();
    return _hits[index];
  }

  /// 下一条命中（末条之后回到第一条）。
  PdfTextSearchHit? next() {
    if (_hits.isEmpty) return null;
    final int? i = _currentIndex;
    return select(i == null ? 0 : (i + 1) % _hits.length);
  }

  /// 上一条命中（第一条之前回到末条）。
  PdfTextSearchHit? previous() {
    if (_hits.isEmpty) return null;
    final int? i = _currentIndex;
    return select(
      i == null ? _hits.length - 1 : (i - 1 + _hits.length) % _hits.length,
    );
  }

  /// 清空查询与结果（关闭搜索）；正在跑的搜索随代次作废。
  void clear() {
    _generation++;
    final bool wasEmpty =
        _status == PdfTextSearchStatus.idle && _hits.isEmpty && _query.isEmpty;
    _query = '';
    _hits.clear();
    _hitsByPage.clear();
    _currentIndex = null;
    _searchedPages = 0;
    _pageCount = 0;
    _truncated = false;
    _status = PdfTextSearchStatus.idle;
    if (!wasEmpty) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
