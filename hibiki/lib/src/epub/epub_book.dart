import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
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
  /// stays an immutable value type (all declared fields final) -- this is the one
  /// derived cache, never assigned from outside.
  List<EpubImageRef>? _images;

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
    final html_dom.Document doc = html_parser.parse(chapters[index].html);
    return _chapterPlainTextFromBody(doc.body);
  }

  /// TODO-1192: chapter [index] 的「实义字符数」——只数假名 / 汉字 / 叠字符 /
  /// 字母数字，剔除所有标点、括号（「」『』（）等）、全角/半角空白与全角符号，
  /// 与 hoshi/ttu `getCharacterCount`（`isNotJapaneseRegex`）口径一致（见
  /// [japaneseCharCount]）。基于 [chapterPlainText]（振假名 `<rt>/<rp>/<rtc>` 已
  /// 剥离故不计入），再过滤非实义字符。用于导入时落库的每章字数与阅读统计，让
  /// 「书的总字数 / 统计字数 / 阅读速度」贴近 hoshi，而不是含标点/括号/空白高约
  /// 10~20%。**不改** [chapterPlainText]（查词 / 对齐 / 搜索仍需完整文本）。
  int chapterCharacterCount(int index) {
    return japaneseCharCount(chapterPlainText(index));
  }

  /// Whitespace-collapsed plain text of an already-parsed [body], with ruby
  /// annotations (`<rt>`/`<rp>`/`<rtc>`) stripped. Mutates [body] by removing the
  /// ruby nodes, so callers must pass a throwaway parsed document's body.
  static String _chapterPlainTextFromBody(html_dom.Element? body) {
    _removeRubyAnnotations(body);
    final String raw = body?.text ?? '';
    return raw.replaceAll(RegExp(r'\s+'), ' ').trim();
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
    final html_dom.Document doc = html_parser.parse(chapters[index].html);
    if (_chapterImageRefs(doc).isEmpty) return false;
    return _chapterPlainTextFromBody(doc.body).length <=
        _imageChapterMaxTextChars;
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
    final html_dom.Document doc = html_parser.parse(chapters[index].html);
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
      final String? ref = _svgImageHref(image);
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
        in _backgroundImageUrlPattern.allMatches(css.toString())) {
      final String ref = (match.group(1) ?? '').trim();
      if (ref.isNotEmpty) refs.add(ref);
    }
    return refs;
  }

  /// Matches a CSS `background-image: url(...)` (or `background:` shorthand),
  /// capturing the reference with surrounding quotes/whitespace stripped.
  static final RegExp _backgroundImageUrlPattern = RegExp(
    r'''background(?:-image)?\s*:[^;}]*url\(\s*['"]?([^'")]+?)['"]?\s*\)''',
    caseSensitive: false,
  );

  /// Reads an SVG `<image>` reference. package:html stores a namespaced
  /// `xlink:href` under an `AttributeName` key (not the plain String
  /// `'xlink:href'`), so match on the attribute's *local* name `href` — this
  /// covers both `xlink:href` (legacy, still the norm in Japanese fixed-layout
  /// EPUB) and the un-prefixed SVG2 `href`.
  static String? _svgImageHref(html_dom.Element image) {
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
      final html_dom.Document doc = html_parser.parse(chapters[i].html);
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
    if (uri.host != ReaderHibikiSource.kHost) return null;
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
  // to opening `https://hoshi.local/...` in the OS browser (blank page) instead
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
/// [ReaderHibikiSource.epubUrl] / the `/epub/<path>` intercept treat as relative
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
/// [resolveImageHref]) suitable for [ReaderHibikiSource.epubUrl].
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

/// TODO-1192: 存进 [EpubBooks.chaptersJson] 每章 `characters` 字段用的计数口径版本。
/// v1（无 `charCaliber` 标记）= 旧的 `chapterPlainText().length`（含标点/括号/空白，
/// 比 hoshi 高约 10~20%）；v2 = [japaneseCharCount]（只数假名/汉字/叠字符/字母数字，
/// 与 hoshi `getCharacterCount` 对齐）。开书发现缓存不是当前口径 → 后台重算并回写。
const int kChapterCharCountCaliber = 2;

/// TODO-1192: 统计一段文本里的「实义字符数」，与 ttu/hoshi `getCharacterCount`
/// 的 `isNotJapaneseRegex` 口径一致：只计入
///   - 假名：平假名（ぁ-ゖ / ゝゞ）、片假名（ァ-ヺ / ー ヽヾ）、半角片假名（ｦ-ﾟ）；
///   - 汉字（CJK 扩展A/统一/兼容 + BMP 外扩展B+ 经 runes 计入）；
///   - 叠字/重复符号（々〆〇〻）与日文常见圈号（○◯）；
///   - 半角字母数字（0-9 A-Z a-z）。
/// 其余一律不计：所有标点、括号（「」『』（）【】等）、全/半角空白、全角标点
/// （。！？、）、全角字母数字等。用 [String.runes] 遍历，正确处理 BMP 外的
/// 代理对汉字（每个码点算一字，不因 UTF-16 拆成两半重复计）。纯函数，供单测锁定
/// 口径（剔标点 / 振假名不计 / 撤销修复即转红）。
int japaneseCharCount(String text) {
  int count = 0;
  for (final int rune in text.runes) {
    if (_isCountedJapaneseRune(rune)) count++;
  }
  return count;
}

/// 单个码点是否计入 [japaneseCharCount]（whitelist；其余全部剔除）。
bool _isCountedJapaneseRune(int c) {
  // 半角字母数字（ttu 用 `0-9A-Z` + `i` flag → 含小写）。
  if (c >= 0x30 && c <= 0x39) return true; // 0-9
  if (c >= 0x41 && c <= 0x5A) return true; // A-Z
  if (c >= 0x61 && c <= 0x7A) return true; // a-z
  // 日文常见圈号 ○(25CB) ◯(25EF)。
  if (c == 0x25CB || c == 0x25EF) return true;
  // 叠字/重复符号：々(3005) 〆(3006) 〇(3007)、〻(303B)、ゝゞ(309D-309E)。
  if (c >= 0x3005 && c <= 0x3007) return true;
  if (c == 0x303B) return true;
  if (c >= 0x309D && c <= 0x309E) return true;
  // 平假名 ぁ-ゖ。
  if (c >= 0x3041 && c <= 0x3096) return true;
  // 片假名 ァ-ヺ 与音符/叠字 ー-ヿ（含 ー ヽ ヾ）。
  if (c >= 0x30A1 && c <= 0x30FA) return true;
  if (c >= 0x30FC && c <= 0x30FF) return true;
  // 半角片假名 ｦ-ﾟ。
  if (c >= 0xFF66 && c <= 0xFF9F) return true;
  // 汉字：扩展A(3400-4DBF)、统一(4E00-9FFF)、兼容(F900-FAFF)、扩展B+(20000-2FA1F)。
  if (c >= 0x3400 && c <= 0x4DBF) return true;
  if (c >= 0x4E00 && c <= 0x9FFF) return true;
  if (c >= 0xF900 && c <= 0xFAFF) return true;
  if (c >= 0x20000 && c <= 0x2FA1F) return true;
  return false;
}

String normalizeHref(String href) => href
    .trim()
    .replaceAll('\\', '/')
    .replaceFirst(RegExp('^/'), '')
    .split('#')
    .first
    .split('?')
    .first;

String fallbackMimeType(String path) {
  switch (p.extension(path).toLowerCase()) {
    case '.css':
      return 'text/css';
    case '.js':
      return 'application/javascript';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.png':
      return 'image/png';
    case '.gif':
      return 'image/gif';
    case '.svg':
      return 'image/svg+xml';
    case '.xhtml':
    case '.html':
      return 'text/html';
    case '.woff':
      return 'font/woff';
    case '.woff2':
      return 'font/woff2';
    case '.ttf':
      return 'font/ttf';
    case '.otf':
      return 'font/otf';
    default:
      return 'application/octet-stream';
  }
}
