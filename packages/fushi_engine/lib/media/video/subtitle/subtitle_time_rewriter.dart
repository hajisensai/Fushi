/// 只改字幕文件里时间戳的那几个字符，其余字节原样保留（样式、[Fonts]、注释、行尾、编码）。
///
/// **为什么不解码**：时间戳、逗号、换行、`Dialogue:` 这些都是 ASCII，而 Shift-JIS / GBK /
/// Big5 / EUC-JP / UTF-8 的多字节尾字节都 ≥ 0x40（或 ≥ 0x80），不会与数字、`:`、`,`、`.`、
/// 换行撞上。于是把字节按 latin1 一一映射成字符（字节 ↔ 字符双射），做完文本替换再映射
/// 回去，替换以外的每个字节都不会被动过，也不必猜编码。只有 UTF-16 例外，按码元处理。
///
/// 偏移为 0 时输出与输入逐字节相同。
library;

import 'dart:typed_data';

import 'package:fushi_engine/media/video/subtitle/subtitle_reference_alignment.dart';

/// 字幕字节的承载方式。
enum SubtitleByteLayout { byteTransparent, utf16le, utf16be }

/// 字节 ↔ 可做文本替换的字符串，且能无损回写。
class SubtitleTextBuffer {
  const SubtitleTextBuffer._(this.text, this.layout);

  factory SubtitleTextBuffer.decode(Uint8List bytes) {
    final SubtitleByteLayout layout = _detectLayout(bytes);
    if (layout == SubtitleByteLayout.byteTransparent) {
      return SubtitleTextBuffer._(String.fromCharCodes(bytes), layout);
    }
    final bool le = layout == SubtitleByteLayout.utf16le;
    final List<int> units = <int>[
      for (int i = 0; i + 1 < bytes.length; i += 2)
        le ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1],
    ];
    return SubtitleTextBuffer._(String.fromCharCodes(units), layout);
  }

  final String text;
  final SubtitleByteLayout layout;

  Uint8List encode(String value) {
    final List<int> units = value.codeUnits;
    if (layout == SubtitleByteLayout.byteTransparent) {
      return Uint8List.fromList(units);
    }
    final bool le = layout == SubtitleByteLayout.utf16le;
    final Uint8List out = Uint8List(units.length * 2);
    for (int i = 0; i < units.length; i++) {
      out[2 * i + (le ? 0 : 1)] = units[i] & 0xff;
      out[2 * i + (le ? 1 : 0)] = units[i] >> 8;
    }
    return out;
  }
}

SubtitleByteLayout _detectLayout(Uint8List b) {
  if (b.length >= 2 && b[0] == 0xff && b[1] == 0xfe) {
    return SubtitleByteLayout.utf16le;
  }
  if (b.length >= 2 && b[0] == 0xfe && b[1] == 0xff) {
    return SubtitleByteLayout.utf16be;
  }
  // 无 BOM 的 UTF-16：ASCII 字符的高字节恒为 0。
  if (b.length >= 4 && b[1] == 0 && b[3] == 0 && b[0] != 0) {
    return SubtitleByteLayout.utf16le;
  }
  if (b.length >= 4 && b[0] == 0 && b[2] == 0 && b[1] != 0) {
    return SubtitleByteLayout.utf16be;
  }
  return SubtitleByteLayout.byteTransparent;
}

// ---------------------------------------------------------------------------
// 时间戳
// ---------------------------------------------------------------------------

/// 文件里的一个时间戳，连同它的书写形式（回写时照原样的位数与分隔符）。
class SubtitleTimestamp {
  const SubtitleTimestamp({
    required this.start,
    required this.end,
    required this.ms,
    required this.hourDigits,
    required this.minuteDigits,
    required this.secondDigits,
    required this.fractionSeparator,
    required this.fractionDigits,
  });

  /// 在文本里的区间 [start, end)。
  final int start;
  final int end;
  final int ms;

  /// 小时位数；0 表示原文没写小时（VTT 的 `mm:ss.ttt`）。
  final int hourDigits;
  final int minuteDigits;
  final int secondDigits;
  final String fractionSeparator;
  final int fractionDigits;

  static final RegExp _pattern = RegExp(
    r'^(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:([.,])(\d{1,3}))?$',
  );

  /// 解析 `text[start, end)`；不是时间戳返回 null。
  static SubtitleTimestamp? parse(String text, int start, int end) {
    final RegExpMatch? m = _pattern.firstMatch(text.substring(start, end));
    if (m == null) return null;
    final String h = m.group(1) ?? '';
    final String frac = m.group(5) ?? '';
    final int fracMs = frac.isEmpty ? 0 : int.parse(frac.padRight(3, '0'));
    final int ms =
        ((int.tryParse(h) ?? 0) * 3600 +
                int.parse(m.group(2)!) * 60 +
                int.parse(m.group(3)!)) *
            1000 +
        fracMs;
    return SubtitleTimestamp(
      start: start,
      end: end,
      ms: ms,
      hourDigits: h.length,
      minuteDigits: m.group(2)!.length,
      secondDigits: m.group(3)!.length,
      fractionSeparator: m.group(4) ?? '',
      fractionDigits: frac.length,
    );
  }

  /// 按原书写形式写出 [newMs]（负数截到 0，按原小数位四舍五入）。
  String format(int newMs) {
    final int unit = switch (fractionDigits) {
      1 => 100,
      2 => 10,
      3 => 1,
      _ => 1000,
    };
    final int v = ((newMs < 0 ? 0 : newMs) / unit).round() * unit;
    final int hours = v ~/ 3600000;
    final int minutes = (v ~/ 60000) % 60;
    final int seconds = (v ~/ 1000) % 60;
    final String frac = fractionDigits == 0
        ? ''
        : '$fractionSeparator${((v % 1000) ~/ unit).toString().padLeft(fractionDigits, '0')}';
    final String hourPart = hourDigits > 0
        ? '${hours.toString().padLeft(hourDigits, '0')}:'
        : (hours > 0 ? '${hours.toString().padLeft(2, '0')}:' : '');
    return '$hourPart${minutes.toString().padLeft(minuteDigits, '0')}:'
        '${seconds.toString().padLeft(secondDigits, '0')}$frac';
  }
}

// ---------------------------------------------------------------------------
// 扫描
// ---------------------------------------------------------------------------

/// 一条带时间的字幕行（ASS 的 Dialogue/Comment 行，或 SRT/VTT 的一个 cue 块）。
class SubtitleTimedLine {
  const SubtitleTimedLine({
    required this.startStamp,
    required this.endStamp,
    required this.blockStart,
    required this.blockEnd,
    required this.alignable,
  });

  final SubtitleTimestamp startStamp;
  final SubtitleTimestamp endStamp;

  /// 删除这条时要去掉的文本区间 [blockStart, blockEnd)。
  final int blockStart;
  final int blockEnd;

  /// 能否当对齐证据：注释行、定位特效字、绘图、空白行不算（写回时照样平移）。
  final bool alignable;

  int get startMs => startStamp.ms;
  int get endMs => endStamp.ms;
}

class _Line {
  const _Line(this.start, this.end, this.next);

  /// 行内容 [start, end)，[next] 是下一行开头（跨过换行符）。
  final int start;
  final int end;
  final int next;
}

List<_Line> _splitLines(String text) {
  final List<_Line> lines = <_Line>[];
  int start = 0;
  while (start < text.length) {
    int nl = text.indexOf('\n', start);
    final int next = nl < 0 ? text.length : nl + 1;
    if (nl < 0) nl = text.length;
    final int end = nl > start && text.codeUnitAt(nl - 1) == 0x0d ? nl - 1 : nl;
    lines.add(_Line(start, end, next));
    start = next;
  }
  return lines;
}

/// 扫描所有带时间的行；ASS 按 `[Events]` + `Format:` 定位列，其余按 `-->`。
List<SubtitleTimedLine> scanSubtitleTimedLines(String text) {
  final List<_Line> lines = _splitLines(text);
  final bool isAss = RegExp(
    r'^\s*\[events\]\s*$',
    caseSensitive: false,
    multiLine: true,
  ).hasMatch(text);
  return isAss ? _scanAss(text, lines) : _scanArrowCues(text, lines);
}

// ---- ASS ------------------------------------------------------------------

final RegExp _assOverride = RegExp(r'\{[^}]*\}');
final RegExp _assDrawing = RegExp(r'\\p[1-9]');

bool _assTextAlignable(String body) {
  if (body.contains(r'\pos(') || body.contains(r'\move(')) return false;
  if (_assDrawing.hasMatch(body)) return false;
  final String plain = body
      .replaceAll(_assOverride, '')
      .replaceAll(RegExp(r'\\[Nnh]'), '')
      .trim();
  return plain.isNotEmpty;
}

class _AssColumns {
  const _AssColumns(this.start, this.end, this.count);

  static const _AssColumns standard = _AssColumns(1, 2, 10);

  final int start;
  final int end;
  final int count;

  static _AssColumns parse(String spec) {
    final List<String> names = spec
        .split(',')
        .map((String s) => s.trim().toLowerCase())
        .toList();
    final int start = names.indexOf('start');
    final int end = names.indexOf('end');
    if (start < 0 || end < 0) return standard;
    return _AssColumns(start, end, names.length);
  }
}

List<SubtitleTimedLine> _scanAss(String text, List<_Line> lines) {
  final List<SubtitleTimedLine> out = <SubtitleTimedLine>[];
  bool inEvents = false;
  _AssColumns columns = _AssColumns.standard;
  for (final _Line line in lines) {
    final String content = text.substring(line.start, line.end);
    final String trimmed = content.trimLeft();
    if (trimmed.startsWith('[')) {
      inEvents = trimmed.trimRight().toLowerCase() == '[events]';
      continue;
    }
    if (!inEvents) continue;
    if (trimmed.startsWith('Format:')) {
      columns = _AssColumns.parse(trimmed.substring('Format:'.length));
      continue;
    }
    final SubtitleTimedLine? event = _scanAssEvent(text, line, columns);
    if (event != null) out.add(event);
  }
  return out;
}

SubtitleTimedLine? _scanAssEvent(String text, _Line line, _AssColumns columns) {
  final String content = text.substring(line.start, line.end);
  final int lead = content.length - content.trimLeft().length;
  final String trimmed = content.substring(lead);
  final bool dialogue = trimmed.startsWith('Dialogue:');
  if (!dialogue && !trimmed.startsWith('Comment:')) return null;
  // 字段起点：冒号后；前 count-1 个逗号分隔字段，最后一个字段（Text）可含逗号。
  final List<int> fieldStarts = <int>[
    line.start + lead + trimmed.indexOf(':') + 1,
  ];
  for (
    int i = fieldStarts.first;
    i < line.end && fieldStarts.length < columns.count;
    i++
  ) {
    if (text.codeUnitAt(i) == 0x2c) fieldStarts.add(i + 1);
  }
  if (fieldStarts.length < columns.count) return null;
  SubtitleTimestamp? field(int col) {
    int s = fieldStarts[col];
    int e = col + 1 < fieldStarts.length ? fieldStarts[col + 1] - 1 : line.end;
    while (s < e && text.codeUnitAt(s) == 0x20) {
      s++;
    }
    while (e > s && text.codeUnitAt(e - 1) == 0x20) {
      e--;
    }
    return SubtitleTimestamp.parse(text, s, e);
  }

  final SubtitleTimestamp? start = field(columns.start);
  final SubtitleTimestamp? end = field(columns.end);
  if (start == null || end == null || start.start > end.start) return null;
  final String body = text.substring(fieldStarts.last, line.end);
  return SubtitleTimedLine(
    startStamp: start,
    endStamp: end,
    blockStart: line.start,
    blockEnd: line.next,
    alignable: dialogue && _assTextAlignable(body),
  );
}

// ---- SRT / VTT --------------------------------------------------------------

final RegExp _markupTag = RegExp(r'<[^>]*>|\{[^}]*\}');

bool _isBlank(String text, _Line l) =>
    text.substring(l.start, l.end).trim().isEmpty;

List<SubtitleTimedLine> _scanArrowCues(String text, List<_Line> lines) {
  final List<SubtitleTimedLine> out = <SubtitleTimedLine>[];
  for (int i = 0; i < lines.length; i++) {
    final SubtitleTimedLine? cue = _scanArrowCue(text, lines, i);
    if (cue != null) out.add(cue);
  }
  return out;
}

SubtitleTimedLine? _scanArrowCue(String text, List<_Line> lines, int i) {
  final _Line line = lines[i];
  final int arrow = text.indexOf('-->', line.start);
  if (arrow < 0 || arrow >= line.end) return null;
  final SubtitleTimestamp? start = _trimmedStamp(text, line.start, arrow);
  int e = arrow + 3;
  while (e < line.end && text.codeUnitAt(e) == 0x20) {
    e++;
  }
  int f = e;
  while (f < line.end &&
      text.codeUnitAt(f) != 0x20 &&
      text.codeUnitAt(f) != 0x09) {
    f++;
  }
  final SubtitleTimestamp? end = SubtitleTimestamp.parse(text, e, f);
  if (start == null || end == null) return null;
  int first = i;
  while (first > 0 && !_isBlank(text, lines[first - 1])) {
    first--;
  }
  int last = i;
  final StringBuffer body = StringBuffer();
  while (last + 1 < lines.length && !_isBlank(text, lines[last + 1])) {
    last++;
    body.writeln(text.substring(lines[last].start, lines[last].end));
  }
  int after = last + 1;
  while (after < lines.length && _isBlank(text, lines[after])) {
    after++;
  }
  return SubtitleTimedLine(
    startStamp: start,
    endStamp: end,
    blockStart: lines[first].start,
    blockEnd: after < lines.length ? lines[after].start : text.length,
    alignable: body.toString().replaceAll(_markupTag, '').trim().isNotEmpty,
  );
}

SubtitleTimestamp? _trimmedStamp(String text, int s, int e) {
  while (s < e &&
      (text.codeUnitAt(s) == 0x20 || text.codeUnitAt(s) == 0xfeff)) {
    s++;
  }
  while (e > s && text.codeUnitAt(e - 1) == 0x20) {
    e--;
  }
  return SubtitleTimestamp.parse(text, s, e);
}

// ---------------------------------------------------------------------------
// 对外
// ---------------------------------------------------------------------------

/// 字幕里可当对齐证据的 cue 开始时刻（秒，文件顺序）。
List<double> alignableCueStartSeconds(Uint8List bytes) {
  return <double>[
    for (final SubtitleTimedLine l in scanSubtitleTimedLines(
      SubtitleTextBuffer.decode(bytes).text,
    ))
      if (l.alignable) l.startMs / 1000.0,
  ];
}

class SubtitleRetimeOutcome {
  const SubtitleRetimeOutcome({
    required this.bytes,
    required this.shiftedCount,
    required this.droppedCount,
  });

  final Uint8List bytes;

  /// 被改写时间的 cue 数。
  final int shiftedCount;

  /// 落在被剪掉的 CM 区间、或平移后整句落到 0 之前而删掉的 cue 数。
  final int droppedCount;
}

bool _isIdentity(List<AlignmentSegment> segments) =>
    segments.every((AlignmentSegment s) => s.offsetSeconds.abs() < 0.0005);

/// 按 [segments] 平移整份字幕：每条 cue 按它开始时刻所在的段整体平移（时长不变），
/// 落进被剪掉区间的 cue 删除。
SubtitleRetimeOutcome retimeSubtitleBytes(
  Uint8List bytes,
  List<AlignmentSegment> segments,
) {
  if (segments.isEmpty || _isIdentity(segments)) {
    return SubtitleRetimeOutcome(
      bytes: bytes,
      shiftedCount: 0,
      droppedCount: 0,
    );
  }
  final SubtitleTextBuffer buffer = SubtitleTextBuffer.decode(bytes);
  final String text = buffer.text;
  final List<({double lo, double hi})> removed = alignmentRemovedSpans(
    segments,
  );
  final StringBuffer out = StringBuffer();
  int cursor = 0;
  int shifted = 0;
  int dropped = 0;
  for (final SubtitleTimedLine l in scanSubtitleTimedLines(text)) {
    // 不规范的 SRT（cue 之间缺空行）会让相邻块重叠：前一块若已整块删掉，
    // 这条就在被删的范围里，不能再往回写。
    if (l.startStamp.start < cursor) {
      dropped++;
      continue;
    }
    final double startSec = l.startMs / 1000.0;
    final int delta = (alignmentOffsetAt(segments, startSec) * 1000).round();
    final bool gone =
        l.endMs + delta <= 0 ||
        removed.any(
          (({double lo, double hi}) r) => r.lo <= startSec && startSec < r.hi,
        );
    if (gone) {
      out.write(
        text.substring(cursor, l.blockStart < cursor ? cursor : l.blockStart),
      );
      cursor = l.blockEnd;
      dropped++;
      continue;
    }
    out
      ..write(text.substring(cursor, l.startStamp.start))
      ..write(l.startStamp.format(l.startMs + delta))
      ..write(text.substring(l.startStamp.end, l.endStamp.start))
      ..write(l.endStamp.format(l.endMs + delta));
    cursor = l.endStamp.end;
    shifted++;
  }
  out.write(text.substring(cursor));
  return SubtitleRetimeOutcome(
    bytes: buffer.encode(out.toString()),
    shiftedCount: shifted,
    droppedCount: dropped,
  );
}
