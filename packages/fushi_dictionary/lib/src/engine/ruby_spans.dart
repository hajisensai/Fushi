// ── 原文自带振假名（ruby）随查词带进引擎 ──────────────────────────────
//
// 原文 `<ruby>忙<rt>せわ</rt></ruby>しい` 已经告诉读者这里读「せわしい」，但取词串只剩
// 「忙しい」，同匹配长度候选按频率排，「いそがしい」永远压在前面。取词方（阅读器 / 歌词 /
// 卡片 / 弹窗 / 浏览器 / 扩展）把取词串里每个 ruby 基字的区间与 <rt> 读音一起交给查词，
// 引擎（native/fushidicts 的 `LookupOptions::ruby_readings`，比较器在匹配长度之后、
// 截断之前按读音一致度排）是唯一的排序实现；本文件只负责区间类型、坐标换算与缓存键。
//
// 只用来源自带的读音，不做任何读音推断（全仓禁自动注音）。

/// 查询串里一段带来源振假名的基字：`[start, end)` 是 UTF-16 码元区间（以交给查词的
/// 查询串为坐标系），[reading] 是该基字的 `<rt>` 文本。可跨 isolate 发送。
class FushiRubySpan {
  const FushiRubySpan({
    required this.start,
    required this.end,
    required this.reading,
  });

  /// 从 wire 形态 `{s, e, r}`（取词脚本 / 远端查词请求）读一组区间，丢掉畸形项；
  /// 读音去首尾空白，空读音 / 空区间 / 负偏移丢弃。
  static List<FushiRubySpan> listFromWire(Object? raw) {
    if (raw is! List) return const <FushiRubySpan>[];
    final List<FushiRubySpan> spans = <FushiRubySpan>[];
    for (final Object? item in raw) {
      if (item is! Map) continue;
      final Object? start = item['s'];
      final Object? end = item['e'];
      final Object? reading = item['r'];
      if (start is! num || end is! num || reading is! String) continue;
      final String trimmed = reading.trim();
      if (trimmed.isEmpty || start < 0 || end.toInt() <= start.toInt()) {
        continue;
      }
      spans.add(
        FushiRubySpan(start: start.toInt(), end: end.toInt(), reading: trimmed),
      );
    }
    return spans;
  }

  /// [listFromWire] 的逆：`[{s, e, r}, ...]`。
  static List<Map<String, Object>> listToWire(List<FushiRubySpan> spans) =>
      <Map<String, Object>>[
        for (final FushiRubySpan span in spans)
          <String, Object>{'s': span.start, 'e': span.end, 'r': span.reading},
      ];

  final int start;
  final int end;
  final String reading;

  @override
  bool operator ==(Object other) =>
      other is FushiRubySpan &&
      other.start == start &&
      other.end == end &&
      other.reading == reading;

  @override
  int get hashCode => Object.hash(start, end, reading);

  @override
  String toString() => 'FushiRubySpan($start, $end, $reading)';
}

/// 把 [spans] 平移到去掉句首 [leadingStrip] 个码元、截到 [length] 长度的查询串坐标系；
/// 越界或被截断的段丢弃，其余保持原顺序。
List<FushiRubySpan> shiftRubySpans(
  List<FushiRubySpan> spans, {
  required int leadingStrip,
  required int length,
}) {
  if (spans.isEmpty) return spans;
  return <FushiRubySpan>[
    for (final FushiRubySpan span in spans)
      if (span.start - leadingStrip >= 0 &&
          span.end - leadingStrip <= length &&
          span.end > span.start &&
          span.reading.isNotEmpty)
        FushiRubySpan(
          start: span.start - leadingStrip,
          end: span.end - leadingStrip,
          reading: span.reading,
        ),
  ];
}

/// [spans] 的缓存键后缀（空 = 无 ruby，返回空串，旧键逐字不变）。ruby 改变引擎的排序与
/// 截断结果，带 ruby 的查询必须单独成键。
String rubySpansCacheSuffix(List<FushiRubySpan> spans) {
  if (spans.isEmpty) return '';
  final StringBuffer out = StringBuffer('/ruby');
  for (final FushiRubySpan span in spans) {
    out
      ..write(':')
      ..write(span.start)
      ..write('-')
      ..write(span.end)
      ..write('=')
      ..write(span.reading.length)
      ..write('.')
      ..write(span.reading);
  }
  return out.toString();
}

/// FFI 封送：把 [text] 上的 UTF-16 区间换成引擎用的**码点**偏移（`start, end` 交替），
/// 读音以 U+001F 连接。越界、切开代理对、读音含 U+001F 的段丢弃。
({List<int> bounds, String readings}) rubySpansToCodePointBounds(
  String text,
  List<FushiRubySpan> spans,
) {
  if (spans.isEmpty) return (bounds: const <int>[], readings: '');
  // codePointAt[i] = UTF-16 偏移 i 之前的码点数；-1 = i 落在代理对中间。
  final List<int> codePointAt = List<int>.filled(text.length + 1, -1);
  int codePoints = 0;
  for (int i = 0; i < text.length; i++) {
    final int unit = text.codeUnitAt(i);
    final bool lowSurrogate =
        unit >= 0xDC00 &&
        unit <= 0xDFFF &&
        i > 0 &&
        text.codeUnitAt(i - 1) >= 0xD800 &&
        text.codeUnitAt(i - 1) <= 0xDBFF;
    if (!lowSurrogate) {
      codePointAt[i] = codePoints;
      codePoints++;
    }
  }
  codePointAt[text.length] = codePoints;

  final List<int> bounds = <int>[];
  final List<String> readings = <String>[];
  for (final FushiRubySpan span in spans) {
    if (span.start < 0 ||
        span.end > text.length ||
        span.end <= span.start ||
        span.reading.isEmpty ||
        span.reading.contains('\u001f')) {
      continue;
    }
    final int start = codePointAt[span.start];
    final int end = codePointAt[span.end];
    if (start < 0 || end < 0) continue;
    bounds
      ..add(start)
      ..add(end);
    readings.add(span.reading);
  }
  return (bounds: bounds, readings: readings.join('\u001f'));
}
