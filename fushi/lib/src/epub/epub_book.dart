import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/stats/study_char_count.dart';
import 'package:fushi_core/fushi_core.dart' show mimeTypeForFilePath;
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;
import 'package:path/path.dart' as p;

class EpubBook {
  EpubBook({
    required this.title,
    required this.chapters,
    this.toc = const [],
    this.coverHref,
    this.resources = const {},
    this.rootDirectory,
    this.author,
    this.language,
    this.renditionSpread,
  });

  final String title;
  final String? author;
  final String? language;

  /// Book-level `rendition:spread` value: `landscape`, `both`, `portrait`,
  /// `none`, or `null` when the OPF does not declare one.
  final String? renditionSpread;

  final List<EpubChapter> chapters;
  final List<EpubTocItem> toc;
  final String? coverHref;
  final Map<String, EpubResource> resources;
  final String? rootDirectory;

  /// TODO-723: lazily-built, cached index of every `<img>` in the book, ordered
  /// by spine (reading order) then by DOM order within each chapter. Built once
  /// on first [images] access and cached; the illustration set is immutable for
  /// the lifetime of an opened book. Kept *out* of the constructor so [EpubBook]
  /// stays an immutable value type (all declared fields final) -- derived caches
  /// like this one and [_imageOnlyChapterMemo] are never constructor inputs.
  List<EpubImageRef>? _images;

  /// 按章号记忆化的 [isImageOnlyChapter] 结果。章节文件在一本已打开的书的生命周期
  /// 内不变，答案恒定；spread 配对（[EpubSpreadMap]）、边缘分析
  /// （EpubSpreadAnalyzer）、章节服务与预取会对同一章反复提问，未记忆化时每问一次
  /// 就是一次整章 html_parser 全 DOM 解析（主 isolate）。缓存收在数据拥有者这里，
  /// 所有调用方（含旧页面级缓存覆盖不到的 spread/analyzer 路径）统一受益。
  final Map<int, bool> _imageOnlyChapterMemo = <int, bool>{};

  /// 每章「实义字符数」提示（[kChapterCharCountCaliber] 当前口径，见
  /// [chapterCharacterCount]），用于 [isImageOnlyChapter] 免解析短路。
  ///
  /// 方向安全性：该口径只数假名/汉字/字母数字（标点/空白剔除、振假名剥离），
  /// 恒 ≤ [_chapterPlainTextFromBody] 的纯文本长度；因此
  /// `hint > _imageChapterMaxTextChars` ⇒ 纯文本必超阈值 ⇒ 必非纯图片章，
  /// 无需读盘/解析。hint ≤ 阈值（含 0 占位）不能反推，回落全量解析。
  /// **只接受当前口径的计数**——旧口径可能计入振假名等而高估，破坏上述单向推理。
  List<int>? _charCountHints;

  /// 注入 [kChapterCharCountCaliber] 当前口径的每章字数（来自导入期落库的
  /// chaptersJson 或后台重算），供 [isImageOnlyChapter] 免解析短路。调用方负责
  /// 保证口径正确；长度与 [chapters] 不符时超界章节按无提示处理。
  void setChapterCharCountHints(List<int> counts) {
    _charCountHints = counts;
  }

  Uint8List? readResource(String path) {
    final String normalized = normalizeHref(path);
    final EpubResource? resource = resources[normalized];
    if (resource != null) return resource.readBytes();
    if (rootDirectory == null) return null;
    final File file = File(p.join(rootDirectory!, normalized));
    if (file.existsSync()) return file.readAsBytesSync();
    return null;
  }

  String mediaType(String path) {
    return resources[normalizeHref(path)]?.mediaType ?? fallbackMimeType(path);
  }

  // Uses package:html DOM parser — same parsing semantics as the WebView.
  // Entities, nesting, malformed HTML are all handled by the parser, not regex.
  // Must match JS isFurigana() in reader_pagination_scripts.dart: both sides
  // drop <rt>/<rp>/<rtc> content but keep ruby base text.
  /// Plain text of chapter at [index], with ruby annotations stripped.
  /// Used by EpubSrtMatcher and sasayaki rematch for audiobook alignment.
  String chapterPlainText(int index) {
    if (index < 0 || index >= chapters.length) return '';
    final html_dom.Document doc = parseChapterHtml(chapters[index].html);
    return _chapterPlainTextFromBody(doc.body);
  }

  /// [chapterPlainText] 的同一份纯文本，外加每处 ruby 的基底区间与读音
  /// （有声书匹配的「读音轨」：听写かな对正文漢字零重叠，出版社标好的振假名是
  /// 唯一零推断误差的读音来源）。
  ///
  /// `text` 与 [chapterPlainText] **逐码元相同**（同一 DOM、同一空白折叠、同一
  /// trim；守卫测试 `test/epub/epub_ruby_plain_text_test.dart`）——`fushi-cue://`
  /// 偏移、阅读位置、统计水位全部建立在这份文本上，读音只能作旁路。
  EpubPlainTextWithRuby chapterPlainTextWithRuby(int index) {
    if (index < 0 || index >= chapters.length) {
      return const EpubPlainTextWithRuby(
          text: '', rubies: <EpubRubyAnnotation>[]);
    }
    final html_dom.Document doc = parseChapterHtml(chapters[index].html);
    return _RubyPlainTextWalker.walk(doc.body);
  }

  /// BUG-2017：章节 XHTML 的**唯一** DOM 解析入口。
  ///
  /// EPUB 章节是 XML（`application/xhtml+xml`），WebView 按该 MIME 走 XML 解析，
  /// 于是 `<script src="…"/>` / `<title/>` 是合法空元素。但这里的 HTML5 解析器
  /// 不认 raw-text 元素的自闭合写法：`<script/>` 被当成**未闭合的开标签**，
  /// tokenizer 进入 script data 状态，一路把文档剩余部分（含整个 `<body>`）
  /// 吞成该元素的文本，`doc.body` 于是为空。kobo 处理过的日文 EPUB 正是这种
  /// 形态（head 里一行自闭合 `<script src="../../js/kobo.js"/>`、全文无
  /// `</script>`），导致每章纯文本为空 —— 有声书对齐匹配率 0、每章字数落库 0、
  /// 每章都被 [isImageOnlyChapter] 判成纯图片章。
  ///
  /// 归一化自闭合 raw-text 标签后再交给 HTML 解析器，两侧解析结果重新一致。
  static html_dom.Document parseChapterHtml(String html) {
    return html_parser.parse(normalizeSelfClosingRawTextTags(html));
  }

  /// TODO-1192: chapter [index] 的「实义字符数」——只数假名 / 汉字 / 叠字符 /
  /// 字母数字，剔除所有标点、括号（「」『』（）等）、全角/半角空白与全角符号，
  /// 与 hoshi/ttu `getCharacterCount`（`isNotJapaneseRegex`）口径一致（见
  /// [countStudyChars]）。基于 [chapterPlainText]（振假名 `<rt>/<rp>/<rtc>` 已
  /// 剥离故不计入），再过滤非实义字符。用于导入时落库的每章字数与阅读统计，让
  /// 「书的总字数 / 统计字数 / 阅读速度」贴近 hoshi，而不是含标点/括号/空白高约
  /// 10~20%。**不改** [chapterPlainText]（查词 / 对齐 / 搜索仍需完整文本）。
  int chapterCharacterCount(int index) {
    return countStudyChars(chapterPlainText(index));
  }

  /// Whitespace-collapsed plain text of an already-parsed [body], with ruby
  /// annotations (`<rt>`/`<rp>`/`<rtc>`) stripped. Mutates [body] by removing the
  /// ruby nodes, so callers must pass a throwaway parsed document's body.
  static final RegExp _whitespaceRun = RegExp(r'\s+');

  static String _chapterPlainTextFromBody(html_dom.Element? body) {
    _removeRubyAnnotations(body);
    final String raw = body?.text ?? '';
    return raw.replaceAll(_whitespaceRun, ' ').trim();
  }

  static void _removeRubyAnnotations(html_dom.Element? root) {
    if (root == null) return;
    root.querySelectorAll('rt, rp, rtc').forEach(
          (el) => el.remove(),
        );
  }

  /// TODO-1174: the largest whitespace-stripped plain-text length a chapter may
  /// still carry and count as a pure illustration page. A full-page illustration
  /// commonly carries a short caption / figcaption / page number / 「挿絵」credit
  /// that the old strict "text must be empty" test rejected, so such a page never
  /// merged into the following prose and kept its own page. Kept deliberately
  /// small: any real prose paragraph blows past it, so a text chapter can never
  /// be misclassified as image-only and have its body silently dropped by the
  /// image-merge pass ([EpubSpreadMap._mergeImageEntries]).
  static const int _imageChapterMaxTextChars = 20;

  /// True when chapter [index] is a pure illustration page: it carries at least
  /// one image and no more than [_imageChapterMaxTextChars] characters of
  /// readable text. Drives spread-pairing of adjacent scan/manga/illustration
  /// pages and folding a standalone illustration page into the following prose.
  ///
  /// TODO-1174: broadened from the original "exactly one `<img>` AND zero text"
  /// test, which missed the two commonest real illustration pages — Japanese
  /// fixed-layout books that wrap a single JPEG in an SVG `<image xlink:href>`
  /// (no `<img>` at all), and pages carrying a caption / page number beside the
  /// image — so those illustrations each kept their own page instead of merging.
  /// "Has an image" now counts `<img>`, SVG `<image>`, and CSS
  /// `background-image` (see [_chapterImageRefs]); the count is relaxed from
  /// exactly one to one-or-more. The text threshold is the guardrail that keeps
  /// a real prose chapter from ever being absorbed.
  bool isImageOnlyChapter(int index) {
    if (index < 0 || index >= chapters.length) return false;
    final bool? memo = _imageOnlyChapterMemo[index];
    if (memo != null) return memo;
    // 字数提示短路（方向安全性见 [_charCountHints]）：实义字数已超阈值的正文章
    // 直接判非纯图片章，免去读盘 + 全 DOM 解析——纯文字书的 spread 分析由此
    // 从「逐章解析全书」降为纯内存比较。
    final List<int>? hints = _charCountHints;
    if (hints != null &&
        index < hints.length &&
        hints[index] > _imageChapterMaxTextChars) {
      return _imageOnlyChapterMemo[index] = false;
    }
    final html_dom.Document doc = parseChapterHtml(chapters[index].html);
    final bool value = _chapterImageRefs(doc).isNotEmpty &&
        _chapterPlainTextFromBody(doc.body).length <= _imageChapterMaxTextChars;
    return _imageOnlyChapterMemo[index] = value;
  }

  /// The first chapter-relative image reference of chapter [index] (see
  /// [_chapterImageRefs] for the sources considered), or null when none. Used by
  /// edge-matching and spread pairing, which need a single representative image.
  String? chapterImageSrc(int index) {
    final List<String> refs = chapterImageSrcs(index);
    return refs.isEmpty ? null : refs.first;
  }

  /// TODO-1174: every chapter-relative image reference of chapter [index], in
  /// priority/DOM order (see [_chapterImageRefs]). The inline image-merge
  /// renderer folds all of them into the absorbing prose chapter so a multi-image
  /// or SVG-`<image>` illustration page never loses an illustration when merged.
  List<String> chapterImageSrcs(int index) {
    if (index < 0 || index >= chapters.length) return const <String>[];
    final html_dom.Document doc = parseChapterHtml(chapters[index].html);
    return _chapterImageRefs(doc);
  }

  /// TODO-1174: every chapter-relative image reference in [doc], across the ways
  /// a fixed-layout / illustration EPUB page can carry a full-page image, in
  /// priority order: HTML `<img src>`, then SVG `<image xlink:href>` / `<image
  /// href>` (Japanese fixed layout often wraps one JPEG in an SVG viewport with
  /// no `<img>`), then CSS `background-image: url(...)` (inline `style=`
  /// attributes and `<style>` blocks — best effort, not matched to a specific
  /// element, which is enough for the image-only classifier). Empty/whitespace
  /// references are skipped.
  static List<String> _chapterImageRefs(html_dom.Document doc) {
    final List<String> refs = <String>[];
    for (final html_dom.Element img in doc.querySelectorAll('img')) {
      final String ref = (img.attributes['src'] ?? '').trim();
      if (ref.isNotEmpty) refs.add(ref);
    }
    for (final html_dom.Element image in doc.querySelectorAll('image')) {
      final String? ref = svgImageHref(image);
      if (ref != null && ref.isNotEmpty) refs.add(ref);
    }
    final StringBuffer css = StringBuffer();
    for (final html_dom.Element styled in doc.querySelectorAll('[style]')) {
      css.writeln(styled.attributes['style'] ?? '');
    }
    for (final html_dom.Element styleEl in doc.querySelectorAll('style')) {
      css.writeln(styleEl.text);
    }
    for (final Match match
        in backgroundImageUrlPattern.allMatches(css.toString())) {
      final String ref = (match.group(1) ?? '').trim();
      if (ref.isNotEmpty) refs.add(ref);
    }
    return refs;
  }

  /// Matches a CSS `background-image: url(...)` (or `background:` shorthand),
  /// capturing the reference with surrounding quotes/whitespace stripped.
  /// Public because [IllustrationProgressIndex] classifies the same
  /// references element by element — one pattern, not two drifting copies.
  static final RegExp backgroundImageUrlPattern = RegExp(
    r'''background(?:-image)?\s*:[^;}]*url\(\s*['"]?([^'")]+?)['"]?\s*\)''',
    caseSensitive: false,
  );

  /// Reads an SVG `<image>` reference (shared with
  /// [IllustrationProgressIndex]). package:html stores a namespaced
  /// `xlink:href` under an `AttributeName` key (not the plain String
  /// `'xlink:href'`), so match on the attribute's *local* name `href` — this
  /// covers both `xlink:href` (legacy, still the norm in Japanese fixed-layout
  /// EPUB) and the un-prefixed SVG2 `href`.
  static String? svgImageHref(html_dom.Element image) {
    for (final MapEntry<Object, String> attr in image.attributes.entries) {
      final String name = attr.key.toString();
      if (name == 'href' || name == 'xlink:href' || name.endsWith(':href')) {
        final String value = attr.value.trim();
        if (value.isNotEmpty) return value;
      }
    }
    return null;
  }

  /// TODO-723: every `<img>` in the book in reading order. Walks [chapters] in
  /// spine order; for each chapter parses its XHTML with `package:html` and
  /// collects every `<img>` with a non-empty `src` in DOM order. `orderInBook`
  /// is a 0-based running index across the whole book; `chapterIndex` is the
  /// owning spine index. Chapters with no images contribute nothing. SVG
  /// `<image xlink:href>` is intentionally NOT included yet (deferred).
  ///
  /// Built lazily and cached in [_images] (the illustration set does not change
  /// once a book is open).
  List<EpubImageRef> get images {
    final List<EpubImageRef>? cached = _images;
    if (cached != null) return cached;
    final List<EpubImageRef> built = <EpubImageRef>[];
    int order = 0;
    for (int i = 0; i < chapters.length; i++) {
      final String chapterHref = chapters[i].href;
      final html_dom.Document doc = parseChapterHtml(chapters[i].html);
      for (final html_dom.Element img in doc.querySelectorAll('img')) {
        final String? src = img.attributes['src'];
        if (src == null || src.trim().isEmpty) continue;
        built.add(EpubImageRef(
          chapterIndex: i,
          orderInBook: order++,
          src: resolveImageHref(chapterHref, src),
        ));
      }
    }
    final List<EpubImageRef> result = List<EpubImageRef>.unmodifiable(built);
    _images = result;
    return result;
  }

  ({int chapterIndex, String? fragment})? resolveInternalLink(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.host != ReaderFushiSource.kHost) return null;
    if (!uri.path.startsWith('/epub/')) return null;

    final String epubPath = _canonicalEpubPath(
        _decodeHrefPath(uri.path.substring('/epub/'.length)));
    final String? fragment = uri.fragment.isNotEmpty ? uri.fragment : null;

    for (int i = 0; i < chapters.length; i++) {
      if (_canonicalEpubPath(chapters[i].href) == epubPath) {
        return (chapterIndex: i, fragment: fragment);
      }
    }

    return null;
  }

  /// TODO-796: maps a stored TOC `href` (a spine-relative path that may carry a
  /// `#fragment`, percent escapes, `./`/`../` segments, or case differences from
  /// the spine chapter href) to its spine chapter index, or -1 when no spine
  /// chapter owns it.
  ///
  /// The TOC sheet previously matched with a raw `==` against the stored chapter
  /// href ([_tocHrefToChapterIndex]), a *different* standard than
  /// [resolveInternalLink]'s [_canonicalEpubPath] comparison. A cover/front-
  /// matter TOC entry whose href differed only by `./` / `%xx` / letter case
  /// then resolved to -1 and was silently dropped from the flattened TOC, so the
  /// real first chapter slid into row 0 — clicking "Cover" jumped to chapter 1.
  ///
  /// This reuses the one canonicalization standard (so link resolution and TOC
  /// matching can never disagree) and, only when the exact-canonical pass finds
  /// nothing, falls back to a case-insensitive canonical pass. Case folding is
  /// kept out of [_canonicalEpubPath] itself so [resolveInternalLink] still
  /// honours case-sensitive filesystems; the fallback is TOC-local and only ever
  /// recovers an otherwise-dropped entry — it never reroutes a path that already
  /// matched exactly.
  int chapterIndexForHref(String? href) {
    if (href == null) return -1;
    final String base = normalizeHref(href);
    if (base.isEmpty) return -1;
    final String target = _canonicalEpubPath(_decodeHrefPath(base));
    if (target.isEmpty) return -1;

    for (int i = 0; i < chapters.length; i++) {
      if (_canonicalEpubPath(chapters[i].href) == target) {
        return i;
      }
    }
    final String targetLower = target.toLowerCase();
    for (int i = 0; i < chapters.length; i++) {
      if (_canonicalEpubPath(chapters[i].href).toLowerCase() == targetLower) {
        return i;
      }
    }
    return -1;
  }

  /// TODO-807：章节 [index] 是否为 EPUB 导航/目录文档（见 [EpubChapter.isNav]）。
  /// 越界返回 false。有声书被动跨章跟随据此跳过目录页。
  bool isChapterNav(int index) {
    if (index < 0 || index >= chapters.length) return false;
    return chapters[index].isNav;
  }

  /// Percent-decodes a href path, degrading to the raw value on malformed
  /// escapes (a TOC `src` is untrusted input — a stray `%` must not abort the
  /// whole jump). Mirrors the percent-decoding [EpubParser] applies at parse
  /// time so both sides of the comparison are decoded.
  static String _decodeHrefPath(String path) {
    try {
      return Uri.decodeComponent(path);
    } on ArgumentError {
      return path;
    }
  }

  // BUG-097: the WebView resolves a relative `<a href>` against the current
  // document URL, so the clicked link's path can carry `./` / `../` / duplicate
  // slashes that the stored chapter href (canonicalized at parse time) does not.
  // A strict `==` then missed legitimate internal links → the caller fell back
  // to opening `https://fushi.local/...` in the OS browser (blank page) instead
  // of jumping. Canonicalize both sides (POSIX, slash-style agnostic) so the
  // comparison is symmetric regardless of redundant path segments.
  static String _canonicalEpubPath(String path) {
    final String normalized = normalizeHref(path);
    if (normalized.isEmpty) return normalized;
    return p.posix.normalize(normalized);
  }
}

/// TODO-723: resolves an `<img src>` (which the WebView resolves relative to the
/// *current chapter document*) into an **epub-root-relative href** that
/// [ReaderFushiSource.epubUrl] / the `/epub/<path>` intercept treat as relative
/// to the EPUB root. Mirrors [EpubSpreadAnalyzer._resolveImagePath] /
/// [_resolveSpreadImageUrl]: join against the chapter's directory then POSIX-
/// normalize. Pure (no book/IO state) so the root-cause path is directly
/// unit-testable.
///
/// Examples (chapterHref -> src => result):
/// - `OEBPS/text/ch1.xhtml` + `../images/p1.png` => `OEBPS/images/p1.png`
/// - `OEBPS/text/ch1.xhtml` + `./img.png`        => `OEBPS/text/img.png`
/// - `OEBPS/text/ch1.xhtml` + `img.png`          => `OEBPS/text/img.png`
/// - `ch.xhtml`             + `images/x.png`      => `images/x.png`
String resolveImageHref(String chapterHref, String src) {
  final String chapterDir = p.posix.dirname(normalizeHref(chapterHref));
  return p.posix.normalize(p.posix.join(chapterDir, src));
}

/// TODO-723: one illustration occurrence in a book, in reading order.
///
/// [chapterIndex] is the owning spine chapter; [orderInBook] is a 0-based index
/// across the whole book (stable reading order); [src] is the **epub-root-
/// relative href** (already resolved against the owning chapter's directory via
/// [resolveImageHref]) suitable for [ReaderFushiSource.epubUrl].
class EpubImageRef {
  const EpubImageRef({
    required this.chapterIndex,
    required this.orderInBook,
    required this.src,
  });

  final int chapterIndex;
  final int orderInBook;
  final String src;
}

/// [EpubBook.chapterPlainTextWithRuby] 的产物。
class EpubPlainTextWithRuby {
  const EpubPlainTextWithRuby({required this.text, required this.rubies});

  /// 与 [EpubBook.chapterPlainText] 逐码元相同的纯文本。
  final String text;

  /// 按出现顺序、互不重叠的 ruby 基底区间（[text] 的 UTF-16 码元）与读音。
  final List<EpubRubyAnnotation> rubies;
}

/// 一处 ruby：基底在纯文本里的区间 `[start, end)` 与 `<rt>` 读音（多段 `<rt>`
/// 拼接；mono-ruby `<ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>` 记成一处
/// `漢字`/`かんじ`——匹配只需整词读音）。
class EpubRubyAnnotation {
  const EpubRubyAnnotation({
    required this.start,
    required this.end,
    required this.reading,
  });

  final int start;
  final int end;
  final String reading;
}

/// 与 [EpubBook._chapterPlainTextFromBody] 等价的一次 DOM 遍历，顺手记下 ruby。
///
/// 等价性怎么保证：`Element.text` 就是按文档序拼接全部后代文本节点；这里同样按
/// 文档序拼接、跳过 `rt`/`rp`/`rtc` 子树（对应 `_removeRubyAnnotations`），再做
/// `\s+` → 一个空格的折叠——折叠用同一个 `RegExp(r'\s')` 逐码元判定——最后
/// [String.trim]（与原实现同一调用），trim 掉的前导码元数从各区间里减掉。
class _RubyPlainTextWalker {
  _RubyPlainTextWalker._();

  static final RegExp _whitespace = RegExp(r'\s');

  final StringBuffer _out = StringBuffer();
  final List<EpubRubyAnnotation> _rubies = <EpubRubyAnnotation>[];
  bool _pendingSpace = false;

  /// 当前所在 ruby 的基底起点（还没输出任何基底字符时为 -1）；不嵌套。
  int _rubyStart = -2;
  StringBuffer? _reading;

  static EpubPlainTextWithRuby walk(html_dom.Element? body) {
    final _RubyPlainTextWalker w = _RubyPlainTextWalker._();
    if (body != null) w._visit(body);
    final String raw = w._out.toString();
    final String text = raw.trim();
    final int shift = raw.length - raw.trimLeft().length;
    final List<EpubRubyAnnotation> rubies = <EpubRubyAnnotation>[
      for (final EpubRubyAnnotation r in w._rubies)
        if (r.end - shift <= text.length && r.start - shift >= 0)
          EpubRubyAnnotation(
            start: r.start - shift,
            end: r.end - shift,
            reading: r.reading,
          ),
    ];
    return EpubPlainTextWithRuby(text: text, rubies: rubies);
  }

  void _visit(html_dom.Node node) {
    if (node is html_dom.Text) {
      _append(node.data);
      return;
    }
    if (node is! html_dom.Element) {
      for (final html_dom.Node child in node.nodes) {
        _visit(child);
      }
      return;
    }
    final String tag = node.localName ?? '';
    if (tag == 'rt' || tag == 'rp' || tag == 'rtc') {
      // `<rtc>` 是读音容器（里面还是 `<rt>`），三者内容都不进正文。
      if (_reading != null && tag != 'rp') {
        for (final html_dom.Element rt in tag == 'rt'
            ? <html_dom.Element>[node]
            : node.querySelectorAll('rt')) {
          _reading!.write(rt.text);
        }
      }
      return;
    }
    final bool isRuby = tag == 'ruby' && _rubyStart == -2;
    if (isRuby) {
      _rubyStart = -1;
      _reading = StringBuffer();
    }
    for (final html_dom.Node child in node.nodes) {
      _visit(child);
    }
    if (isRuby) {
      final String reading =
          _reading!.toString().replaceAll(_whitespaceRun, '').trim();
      if (_rubyStart >= 0 && reading.isNotEmpty) {
        _rubies.add(
          EpubRubyAnnotation(
            start: _rubyStart,
            end: _out.length,
            reading: reading,
          ),
        );
      }
      _rubyStart = -2;
      _reading = null;
    }
  }

  static final RegExp _whitespaceRun = RegExp(r'\s+');

  void _append(String data) {
    for (int i = 0; i < data.length; i++) {
      final String ch = data[i];
      if (_whitespace.hasMatch(ch)) {
        _pendingSpace = true;
        continue;
      }
      if (_pendingSpace) {
        if (_out.isNotEmpty) _out.write(' ');
        _pendingSpace = false;
      }
      if (_rubyStart == -1) _rubyStart = _out.length;
      _out.write(ch);
    }
  }
}

class EpubChapter {
  /// Eager constructor — [html] is already in memory. Used by DB-metadata /
  /// legacy fallbacks, audiobook import dialogs, and tests.
  EpubChapter({
    required this.id,
    required this.href,
    required this.mediaType,
    required String html,
    this.spineIndex,
    this.linear = true,
    this.spreadProperty,
    this.isNav = false,
  })  : _eagerHtml = html,
        _filePath = null;

  /// TODO-296: lazy constructor — chapter XHTML is read + decoded from
  /// [filePath] on first [html] access and cached, instead of slurping every
  /// spine chapter into memory at parse/open time. The WebView already serves
  /// chapter bodies straight from disk (reader intercept), so the only in-memory
  /// consumers are [chapterPlainText]/search/spread analysis — all of which now
  /// pull the same on-disk bytes on demand, keeping the rendered/aligned text
  /// byte-identical while bounding open-book heap and latency.
  EpubChapter.lazy({
    required this.id,
    required this.href,
    required this.mediaType,
    required String filePath,
    this.spineIndex,
    this.linear = true,
    this.spreadProperty,
    this.isNav = false,
  })  : _eagerHtml = null,
        _filePath = filePath;

  final String id;
  final String href;
  final String mediaType;
  final int? spineIndex;
  final bool linear;

  /// `page-spread-left`, `page-spread-right`, or `null`.
  final String? spreadProperty;

  /// TODO-807：该 spine 项是 EPUB 导航/目录文档（`properties="nav"` /
  /// `epub:type="toc"`）或封面页——日文 EPUB 常把目录页作为 spine 首个 linear
  /// 项，于是 `chapters[0]` 就是目录页。有声书被动跨章跟随时不能把这种页当作
  /// 导航目标（会跳到目录），但它已被序列化进 DB chaptersJson（按 index 寻
  /// 址），物理删除会移位既有书的存储 index，故保留该项、只打标记，导航逻辑
  /// 跳过它。默认 false（DB 回退路径 / 旧测试构造的章节天然为正文，保持原
  /// 行为）。
  final bool isNav;

  final String? _eagerHtml;
  final String? _filePath;
  String? _lazyHtml;

  /// Chapter XHTML source. For lazy chapters this reads + decodes [_filePath]
  /// on first access and caches the result; a missing file degrades to `''`
  /// (matches the DB-fallback builder contract) rather than throwing.
  String get html {
    final String? eager = _eagerHtml;
    if (eager != null) return eager;
    return _lazyHtml ??= _readChapterFile(_filePath);
  }

  static String _readChapterFile(String? filePath) {
    if (filePath == null) return '';
    final File file = File(filePath);
    if (!file.existsSync()) return '';
    return decodeEpubText(file.readAsBytesSync());
  }
}

class EpubTocItem {
  EpubTocItem({required this.label, this.href, this.children = const []});

  final String label;
  final String? href;
  final List<EpubTocItem> children;
}

class EpubResource {
  EpubResource({required this.mediaType, this.bytes, this.filePath});

  final String mediaType;
  final Uint8List? bytes;
  final String? filePath;

  Uint8List? readBytes() {
    if (bytes != null) return bytes;
    if (filePath == null) return null;
    final File file = File(filePath!);
    return file.existsSync() ? file.readAsBytesSync() : null;
  }
}

/// Decodes EPUB text-file bytes as UTF-8, degrading gracefully instead of
/// throwing on non-UTF-8 input. EPUB mandates UTF-8 for its XML, but legacy
/// Japanese books/raw XHTML sometimes carry Shift_JIS/EUC-JP; strict utf8
/// decoding would throw FormatException and abort the whole load
/// (HBK-AUDIT-033). A UTF-8 BOM is stripped; malformed bytes become U+FFFD.
///
/// Single source of truth shared by [EpubParser] (structure parse) and
/// [EpubChapter.html] (TODO-296 lazy read) so eager and lazy chapter text are
/// byte-identical.
String decodeEpubText(List<int> rawBytes) {
  List<int> bytes = rawBytes;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    bytes = bytes.sublist(3);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// BUG-2017：HTML5 里内容会一路读到**显式结束标签**才终止的元素。
///
/// 对这些元素，tokenizer 见到开标签就切进 raw-text / escapable-raw-text /
/// plaintext 状态，此后的 `<` 不再当标签看。因此 XML 风格的自闭合写法
/// （`<script/>`）在 HTML 解析器眼里是个**永不闭合的开标签**：文档剩余部分
/// 整体成为该元素的文本，`<body>` 连同全部正文一起消失。
///
/// 空元素（`<br/>` `<img/>` `<meta/>`）不在此列——它们本就无内容，自闭合写法
/// 在两种解析器下等价，不能碰。
const Set<String> kRawTextTags = <String>{
  'script',
  'style',
  'textarea',
  'title',
  'iframe',
  'noembed',
  'noframes',
  'noscript',
  'xmp',
  'plaintext',
};

/// BUG-2017：把 XHTML 里自闭合的 raw-text 标签（`<script src="…"/>`）改写成
/// 显式闭合（`<script src="…"></script>`），使 HTML 解析器得到与 XML 解析器
/// （WebView 按 `application/xhtml+xml` 走的那条）一致的文档树。
///
/// 只改 [kRawTextTags] 里的标签，且只在其**自身**以 `/>` 结束时改写，所以对
/// 合法 HTML 是恒等变换：普通 HTML 不会把 `<script/>` 当空元素写，真写了也
/// 本就是当前这种「吞掉后文」的坏形态。注释 / CDATA / DOCTYPE / XML 声明整段
/// 原样透传，属性值里的 `>` 由引号状态机跳过，都不会被误判成标签边界。
String normalizeSelfClosingRawTextTags(String html) {
  if (!html.contains('/>')) return html;
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < html.length) {
    final int lt = html.indexOf('<', i);
    if (lt < 0) {
      out.write(html.substring(i));
      break;
    }
    out.write(html.substring(i, lt));
    final int passthrough = _markupPassthroughEnd(html, lt);
    if (passthrough >= 0) {
      out.write(html.substring(lt, passthrough));
      i = passthrough;
      continue;
    }
    final int gt = _tagCloseIndex(html, lt);
    if (gt < 0) {
      out.write(html.substring(lt));
      break;
    }
    out.write(_expandSelfClosingRawTextTag(html.substring(lt, gt + 1)));
    i = gt + 1;
  }
  return out.toString();
}

/// 注释 / CDATA / DOCTYPE / 处理指令的结束下标（exclusive）；[lt] 处不是这类
/// 标记时返回 -1。未闭合时吃到串尾，与 HTML 解析器的 bogus-comment 收尾一致。
int _markupPassthroughEnd(String s, int lt) {
  if (s.startsWith('<!--', lt)) {
    final int end = s.indexOf('-->', lt + 4);
    return end < 0 ? s.length : end + 3;
  }
  if (s.startsWith('<![CDATA[', lt)) {
    final int end = s.indexOf(']]>', lt + 9);
    return end < 0 ? s.length : end + 3;
  }
  if (s.startsWith('<!', lt) || s.startsWith('<?', lt)) {
    final int end = s.indexOf('>', lt);
    return end < 0 ? s.length : end + 1;
  }
  return -1;
}

/// 从 [lt]（指向 `<`）扫到该标签的 `>` 下标；引号内的 `>` 不算边界。未闭合
/// 返回 -1。
int _tagCloseIndex(String s, int lt) {
  String? quote;
  for (int i = lt + 1; i < s.length; i++) {
    final String c = s[i];
    if (quote != null) {
      if (c == quote) quote = null;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '>') {
      return i;
    }
  }
  return -1;
}

/// 自闭合的 raw-text 标签 → 显式闭合；其余标签原样返回。
String _expandSelfClosingRawTextTag(String tag) {
  if (!tag.endsWith('/>')) return tag;
  final Match? m = RegExp(r'^<([A-Za-z][A-Za-z0-9]*)').firstMatch(tag);
  if (m == null) return tag;
  final String name = m.group(1)!.toLowerCase();
  if (!kRawTextTags.contains(name)) return tag;
  return '${tag.substring(0, tag.length - 2)}></$name>';
}

/// TODO-1192: 存进 [EpubBooks.chaptersJson] 每章 `characters` 字段用的计数口径版本。
///
/// - v1（无 `charCaliber` 标记）= 旧的 `chapterPlainText().length`（含标点/括号/空白，
///   比 hoshi 高约 10~20%）；
/// - v2 = 第一版 `japaneseCharCount`，whitelist 与 ttu `isNotJapaneseRegex` 有残差；
/// - v3 = whitelist 逐区间对齐 ttu 的正则；
/// - v4 = 收敛到全仓唯一口径 [countStudyChars]（`package:fushi/src/stats/study_char_count.dart`）。
///
/// v3→v4 换掉的是**口径本身**，不只是残差：ttu 白名单只收 ASCII 字母数字 + 假名 +
/// 汉字 + 全角字母数字 + 半角片假名，于是英语按字母计（虚高约 5 倍）、`café` 的 é
/// 漏计、俄 / 韩 / 希腊 / 阿拉伯 / 希伯来 / 泰 / 天城文**整个脚本记 0**——后者连带
/// 让 `computeBookProgress` 的分母为 0、章内进度退化成「章号 / 章数」。v4 按文字
/// 自身的分词方式计「学习单位」：无空格文字按码点、空格分词文字按连续串。日文正文
/// 的数字实测变化 <0.1%（只在夹杂西文串处），中文同理。
///
/// **改动计数口径必须同步 +1 本版本号**，否则已按旧口径算好的缓存永不再重算。开书
/// 发现缓存不是当前口径 → 后台按当前口径重算并回写。
///
/// 阅读器 WebView 侧有一份等价的 JS 实现（`reader_pagination_scripts.dart` 的
/// `countChars`），两份必须同口径——JS 算出的 `charOffset` 会写进 DB 的 `char_offset`
/// 列，并在 `absoluteCharOffsetOf` / `computeBookProgress` 里与本文件算出的每章
/// `characters` **直接相加**。对拍守卫见 `fushi/test/stats/study_char_count_parity_test.dart`。
const int kChapterCharCountCaliber = 4;

String normalizeHref(String href) => href
    .trim()
    .replaceAll('\\', '/')
    .replaceFirst(RegExp('^/'), '')
    .split('#')
    .first
    .split('?')
    .first;

/// manifest 未声明 mediaType 时按扩展名兜底的 MIME（阅读器 WebView 拦截器 / 分享用）。
///
/// 命名统一轮 G8：收敛到 hibiki_core 单一映射表 [mimeTypeForFilePath]（旧本地副本
/// 缺 `.webp` 等，EPUB 内 webp 插图曾被按 octet-stream 提供）。保留旧名薄 shim。
String fallbackMimeType(String path) => mimeTypeForFilePath(path);

/// BUG-1203：一个 media-type 是不是「EPUB 内容文档」（该走 HTML 处理链的网页）。
///
/// EPUB 只规定内容文档的 **media-type**（EPUB 3 为 `application/xhtml+xml`，
/// EPUB 2 另允许 `text/html`），**没有**规定文件扩展名——`.htm` / `.xht` / 甚至无
/// 扩展名都合法，所以「按扩展名猜」天然是漏的：漏一个就整本正文空白且无错误日志。
///
/// 唯一实现，两处消费：[EpubParser] 筛 spine 用它；阅读器资源拦截器
/// (`reader_fushi/webview.part.dart` 的 `_readerResourcePayload`) 判「要不要净化 +
/// 注样式 + 当文档渲染」也用它。**不要抄第二份平行谓词**——抄本会漂移，一边改了另一
/// 边没跟就是静默空白页。
///
/// ⚠️ 本谓词只用于**分类**。分类命中后下发给 WebView 的 Content-Type 仍必须是
/// `text/html`，绝不能回 `application/xhtml+xml`：后者让渲染器切到严格 XML 解析，
/// 出版社 EPUB 普遍存在的 well-formedness 瑕疵会直接变成整页 parse error，而
/// BUG-079 / BUG-737 的 `sanitizeXhtml`（为 HTML5 解析器补偿自闭合标签）是针对
/// HTML5 解析语义设计的，切走后既失去意义也不再防护那两类空白/查不了词。
bool isHtmlMediaType(String mediaType) {
  final String lower = mediaType.trim().toLowerCase();
  return lower == 'application/xhtml+xml' ||
      lower == 'text/html' ||
      lower.endsWith('+html');
}
