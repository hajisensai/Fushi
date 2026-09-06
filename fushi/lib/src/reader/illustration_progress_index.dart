import 'package:html/dom.dart' as html_dom;

import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/epub/epub_parser.dart';
import 'package:fushi/src/reader/image_reveal_key.dart';
import 'package:fushi/src/stats/study_char_count.dart' show countStudyChars;

/// 一张插图在书里的阅读位置：spine 章号 + 章内归一偏移。
///
/// 坐标系与 `ReaderPosition`（`sectionIndex` / `normCharOffset`，0~10000 分数基准）
/// **完全一致**，两者可直接比较——图片库据此判「这张图读到了没有」。
class IllustrationPosition {
  const IllustrationPosition({
    required this.chapterIndex,
    required this.normCharOffset,
  });

  /// spine 章号（0-based）。`-1` = 封面（OPF `cover-image`），恒排在正文之前，
  /// 因此永远算「已读到」——封面不是剧透。
  final int chapterIndex;

  /// 章内归一偏移（0~10000）：图片之前的实义字符数 ÷ 全章实义字符数。
  final int normCharOffset;

  /// 本图是否落在阅读位置（[chapterIndex] / [normCharOffset]）**之后** = 还没读到。
  bool isAfter({required int chapterIndex, required int normCharOffset}) {
    if (this.chapterIndex != chapterIndex) {
      return this.chapterIndex > chapterIndex;
    }
    return this.normCharOffset > normCharOffset;
  }
}

/// 插图 → 阅读位置的索引：图片库「未读到的插图先遮罩」的判据来源。
///
/// 键是 [ImageRevealKey] 的稳定 key（extractDir 相对、decode、正斜杠），与阅读器
/// WebView / Drift `revealed_images` / 图片库磁盘 `File` 三端同一套标识，所以
/// 「已揭开」与「读到没读到」两个判据能落在同一张图上。
///
/// 定位范围：`<img src>`、SVG `<image xlink:href|href>`（日文固定版式插图页常见）
/// 与**行内** `style="background-image:url(...)"`。`<style>` 块 / 外部 CSS 里的
/// 背景图不进索引（它们没有 DOM 位置、又常来自共享样式表），这类图定位不到 →
/// [isUnread] 返回 false → 不遮罩：宁可漏遮，也不凭猜测把已读的图糊住。
class IllustrationProgressIndex {
  const IllustrationProgressIndex(this.positions);

  /// 空索引（解析失败 / 无 EPUB 结构时的退化值：一律不按进度遮罩）。
  static const IllustrationProgressIndex empty = IllustrationProgressIndex(
    <String, IllustrationPosition>{},
  );

  /// reveal key → 该图在书中**首次出现**的位置（同一张图被多章引用时取最早那次，
  /// 早于阅读位置就算读到了）。
  final Map<String, IllustrationPosition> positions;

  /// [revealKey] 这张图是否还没读到（= 落在阅读位置之后）。
  ///
  /// key 为空、或索引里定位不到（正文没引用 / 只在外部 CSS 里出现）一律 false。
  bool isUnread({
    required String? revealKey,
    required int chapterIndex,
    required int normCharOffset,
  }) {
    if (revealKey == null) return false;
    final IllustrationPosition? position = positions[revealKey];
    if (position == null) return false;
    return position.isAfter(
      chapterIndex: chapterIndex,
      normCharOffset: normCharOffset,
    );
  }

  /// 按 spine 顺序扫全书建索引。纯函数（只读 [book]），可直接在 isolate 内跑。
  static IllustrationProgressIndex build(EpubBook book) {
    final Map<String, IllustrationPosition> positions =
        <String, IllustrationPosition>{};

    void record(String? key, IllustrationPosition position) {
      if (key == null) return;
      positions.putIfAbsent(key, () => position);
    }

    // 封面先登记（章号 -1）：它总在正文之前，任何阅读位置都已「读到」。
    final String? coverHref = book.coverHref;
    if (coverHref != null) {
      record(
        _revealKeyOf(coverHref),
        const IllustrationPosition(chapterIndex: -1, normCharOffset: 0),
      );
    }

    for (int i = 0; i < book.chapters.length; i++) {
      final String chapterHref = book.chapters[i].href;
      final html_dom.Document doc;
      try {
        doc = EpubBook.parseChapterHtml(book.chapters[i].html);
      } catch (_) {
        // 单章读盘/解析失败（文件缺失、编码坏）不该毁掉整本索引：跳过该章，
        // 它的图定位不到 → 不遮罩，其余章照常。
        continue;
      }
      final _ChapterScan scan = _scanChapter(doc.body);
      for (final _ChapterImageHit hit in scan.hits) {
        record(
          _revealKeyOf(resolveImageHref(chapterHref, hit.src)),
          IllustrationPosition(
            chapterIndex: i,
            normCharOffset: _normOffset(hit.charsBefore, scan.totalChars),
          ),
        );
      }
    }

    return IllustrationProgressIndex(
      Map<String, IllustrationPosition>.unmodifiable(positions),
    );
  }

  /// epub-root 相对 href → 稳定 reveal key。href 可能带 percent 转义
  /// （`foo%20bar.jpg`），磁盘文件名是真空格，故先 decode 再归一（与阅读器 JS
  /// 侧 `decodeURIComponent` 对称）。
  static String? _revealKeyOf(String href) {
    String decoded = href;
    try {
      decoded = Uri.decodeComponent(href);
    } on ArgumentError {
      // 非法转义序列：按原样归一，至少不丢这张图。
    }
    return ImageRevealKey.normalize(decoded);
  }

  static int _normOffset(int charsBefore, int totalChars) {
    if (totalChars <= 0) return 0;
    return ((charsBefore * 10000) / totalChars).round().clamp(0, 10000);
  }

  /// 按文档顺序走一章的 DOM：累加实义字符数，遇图记下「它前面有多少字」。
  ///
  /// 字符口径与 [EpubBook.chapterCharacterCount] 一致（[countStudyChars]，振假名
  /// `<rt>/<rp>/<rtc>` 跳过），所以算出的分数与阅读器落库的 `normCharOffset`
  /// 落在同一把尺上。（逐文本节点计数在被标签切断的西文单词处可能与整段计数差
  /// 一两个字，对「读到没读到」这个判据无影响。）
  static _ChapterScan _scanChapter(html_dom.Element? body) {
    final List<_ChapterImageHit> hits = <_ChapterImageHit>[];
    int chars = 0;

    void visit(html_dom.Node node) {
      if (node is html_dom.Text) {
        chars += countStudyChars(node.text);
        return;
      }
      if (node is! html_dom.Element) return;
      final String tag = (node.localName ?? '').toLowerCase();
      if (tag == 'rt' || tag == 'rp' || tag == 'rtc') return;
      for (final String src in _imageRefsOf(node, tag)) {
        hits.add(_ChapterImageHit(src: src, charsBefore: chars));
      }
      for (final html_dom.Node child in node.nodes) {
        visit(child);
      }
    }

    if (body != null) visit(body);
    return _ChapterScan(hits: hits, totalChars: chars);
  }

  /// 单个元素自带的图片引用（章节相对 href），复用 [EpubBook] 的既有判据。
  static List<String> _imageRefsOf(html_dom.Element element, String tag) {
    final List<String> refs = <String>[];
    if (tag == 'img') {
      final String src = (element.attributes['src'] ?? '').trim();
      if (src.isNotEmpty) refs.add(src);
    } else if (tag == 'image') {
      final String? href = EpubBook.svgImageHref(element);
      if (href != null && href.isNotEmpty) refs.add(href);
    }
    final String style = (element.attributes['style'] ?? '').trim();
    if (style.isNotEmpty) {
      for (final Match match in EpubBook.backgroundImageUrlPattern.allMatches(
        style,
      )) {
        final String ref = (match.group(1) ?? '').trim();
        if (ref.isNotEmpty) refs.add(ref);
      }
    }
    return refs;
  }
}

class _ChapterImageHit {
  const _ChapterImageHit({required this.src, required this.charsBefore});

  /// 章节相对的原始引用（未 resolve）。
  final String src;

  /// 该图之前本章已出现的实义字符数。
  final int charsBefore;
}

class _ChapterScan {
  const _ChapterScan({required this.hits, required this.totalChars});

  final List<_ChapterImageHit> hits;
  final int totalChars;
}

/// `compute()` 入口：后台 isolate 里解析已解压目录并建索引。
///
/// 图片库开页时整本 html 解析（几十~几百章）不能压在 UI 线程上——与开书路径的
/// [parseBookOnly] 同款处理。目录不是合法 EPUB（`parseFromExtracted` 抛
/// [FormatException]）由调用方按「无索引」降级。
IllustrationProgressIndex buildIllustrationProgressIndex(String extractDir) {
  return IllustrationProgressIndex.build(
    EpubParser.parseFromExtracted(extractDir),
  );
}
