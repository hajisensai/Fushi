import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiRubySpan;

class ReaderSelectionData {
  ReaderSelectionData({
    required this.text,
    required this.sentence,
    this.rect,
    this.glyphRect,
    this.handlesRect,
    this.handlesBoxes,
    this.normalizedOffset,
    this.normalizedLength,
    this.sentenceOffset = 0,
    this.sentenceNormalizedOffset,
    this.sentenceNormalizedLength,
    this.matchableOffset,
    this.matchableLength,
    this.sentenceMatchableOffset,
    this.sentenceMatchableLength,
    this.verticalWriting = false,
    this.mangaPageIndex,
    this.mangaSentenceGroup,
    this.audioCuePayload,
    this.fromHover = false,
    this.carriesLyricsCueContext = false,
    this.lyricsCueContext,
    this.rubySpans = const <FushiRubySpan>[],
  });

  factory ReaderSelectionData.fromJson(Map<String, dynamic> json) {
    return ReaderSelectionData(
      text: json['text'] as String? ?? '',
      sentence: json['sentence'] as String? ?? '',
      rect: _readRect(json['rect']),
      glyphRect: _readRect(json['glyphRect']),
      handlesRect: _readHandlesRect(json['handlesRect']),
      handlesBoxes: _readHandlesBoxes(json['handlesBoxes']),
      normalizedOffset: (json['normalizedOffset'] as num?)?.toInt(),
      normalizedLength: (json['normalizedLength'] as num?)?.toInt(),
      sentenceOffset: (json['sentenceOffset'] as num?)?.toInt() ?? 0,
      sentenceNormalizedOffset: (json['sentenceNormalizedOffset'] as num?)
          ?.toInt(),
      sentenceNormalizedLength: (json['sentenceNormalizedLength'] as num?)
          ?.toInt(),
      matchableOffset: (json['matchableOffset'] as num?)?.toInt(),
      matchableLength: (json['matchableLength'] as num?)?.toInt(),
      sentenceMatchableOffset: (json['sentenceMatchableOffset'] as num?)
          ?.toInt(),
      sentenceMatchableLength: (json['sentenceMatchableLength'] as num?)
          ?.toInt(),
      verticalWriting: json['verticalWriting'] as bool? ?? false,
      mangaPageIndex: (json['mangaPageIndex'] as num?)?.toInt(),
      mangaSentenceGroup: (json['mangaSentenceGroup'] as num?)?.toInt(),
      audioCuePayload: json['audioCuePayload'] as String?,
      fromHover: json['fromHover'] as bool? ?? false,
      carriesLyricsCueContext: json.containsKey('lyricsCueContext'),
      lyricsCueContext: _readStringKeyedMap(json['lyricsCueContext']),
      rubySpans: FushiRubySpan.listFromWire(json['rubyReadings']),
    );
  }

  final String text;

  /// Cue identity from the rendered DOM, independent of study-unit offsets.
  final String? audioCuePayload;
  final String sentence;
  final Map<String, double>? rect;

  /// 被点那个字的视口矩形（WebView 视口 CSS 像素）。
  ///
  /// 只有漫画 OCR 命中时才有：漫画把 [rect] 换成整句分组的并集（让弹窗避开整个气泡），
  /// 这里另带被点字形，供并集大到四周放不下弹窗时退回贴字定位（BUG-3604）。EPUB 与
  /// 旧 payload 为 null（[rect] 本身就是字形）。
  final Map<String, double>? glyphRect;

  /// Union of the two grip touch targets in WebView viewport CSS pixels.
  /// Separate from the glyph anchor used by dictionary lookup.
  final Map<String, double>? handlesRect;

  /// 两个手柄触控盒**各自**的矩形（顺序 start, end），WebView 视口 CSS 像素。
  ///
  /// 宿主避让操作条要按单个盒子算：[handlesRect] 是并集 bbox，两球之间那段正文空白也被
  /// 算进障碍里；竖排长选区的 bbox 会一路延伸到末字球，于是"放在 bbox 上方"根本放不下，
  /// 操作条被翻到 bbox 底端 = 掉到选区尾部下方。任一端不合法时整体为 null（宿主退回并集）。
  final List<Map<String, double>>? handlesBoxes;

  /// Chapter learning-unit coordinates for navigation and persisted favorites.
  final int? normalizedOffset;
  final int? normalizedLength;
  final int sentenceOffset;
  final int? sentenceNormalizedOffset;
  final int? sentenceNormalizedLength;

  /// Audio matching coordinates, measured in normalized UTF-16 code units.
  /// Never substitute learning-unit offsets when these are unavailable.
  final int? matchableOffset;
  final int? matchableLength;
  final int? sentenceMatchableOffset;
  final int? sentenceMatchableLength;

  /// Whether the source glyph belongs to a vertical writing run.
  ///
  /// Most reader surfaces derive this from page settings. Manga OCR can mix
  /// horizontal and vertical blocks on one page, so its overlay reports the
  /// direction per hit and the popup host consumes it for anchor placement.
  final bool verticalWriting;

  /// Exact 0-based manga page containing the selected OCR glyph.
  ///
  /// This is null for EPUB and legacy manga payloads. In a two-page spread the
  /// reader must use this page, rather than the spread's first page, as the
  /// image attached to a mined card.
  final int? mangaPageIndex;

  /// 命中的 OCR 块所在的句子分组（overlay 的 `data-manga-sentence-group`）。
  ///
  /// 宿主据此把这句话映射回该页的 OCR 块，在**原页图坐标系**里求出句子矩形
  /// （制卡裁切用）；[rect] 是 WebView 视口像素，经过缩放 / 旋转 / 拆页后对不上原图。
  /// EPUB 与旧 payload 为 null。
  final int? mangaSentenceGroup;

  /// 这次选词来自指针扫过（Shift 悬停 / 悬停查词），而不是一次明确的点击 / 按键。
  ///
  /// 宿主据此把这次查词记成 `LookupOrigin.hover`。旧 payload 没有该字段 = false。
  final bool fromHover;

  /// payload 是否带了 `lyricsCueContext` 键（歌词文档在选词时同步读的
  /// `window.__lyricsCueContext`，可为 null）。为 false 时宿主没有这份上下文，
  /// 仍需自己去歌词 WebView 读（旧 payload / 正文文档）。
  final bool carriesLyricsCueContext;

  /// 歌词文档选词那一刻的命中 cue：`{textFragmentId, cueIndex}`；没命中 cue 为 null。
  final Map<String, dynamic>? lyricsCueContext;

  /// [text] 里带原文振假名的基字（`{s, e, r}`：UTF-16 区间 + `<rt>` 读音），由
  /// `buildSelectionPayload` 从 DOM 的 `<ruby>` 读出。查词据此让读音吻合的同长度候选
  /// 排前；旧 payload / 无 ruby 为空。
  final List<FushiRubySpan> rubySpans;
}

Map<String, dynamic>? _readStringKeyedMap(Object? raw) {
  if (raw is! Map) return null;
  return <String, dynamic>{
    for (final MapEntry<Object?, Object?> e in raw.entries)
      if (e.key is String) e.key! as String: e.value,
  };
}

/// 选区锚点矩形：缺字段按 0 补（与历史 `rect` 解析逐字节一致）。
Map<String, double>? _readRect(Object? raw) {
  if (raw is! Map) return null;
  double read(String key) => (raw[key] as num?)?.toDouble() ?? 0;
  return <String, double>{
    'x': read('x'),
    'y': read('y'),
    'width': read('width'),
    'height': read('height'),
  };
}

Map<String, double>? _readHandlesRect(Object? raw) {
  if (raw is! Map) return null;
  final Map<String, double> result = <String, double>{};
  for (final String key in <String>['x', 'y', 'width', 'height']) {
    final Object? value = raw[key];
    if (value is! num || !value.toDouble().isFinite) return null;
    result[key] = value.toDouble();
  }
  if (result['width']! <= 0 || result['height']! <= 0) return null;
  return result;
}

List<Map<String, double>>? _readHandlesBoxes(Object? raw) {
  if (raw is! List) return null;
  final List<Map<String, double>> boxes = <Map<String, double>>[];
  for (final Object? item in raw) {
    final Map<String, double>? box = _readHandlesRect(item);
    if (box == null) return null;
    boxes.add(box);
  }
  return boxes.isEmpty ? null : boxes;
}
