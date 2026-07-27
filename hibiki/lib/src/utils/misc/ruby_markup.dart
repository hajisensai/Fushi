// 注音（振假名）标记解析：把 galgame Hook 台词 / 剪贴板文本里的注音标记拆成
// 「纯基准文本 + 旁路下标区间」，正文一个字符不加不减。
//
// 为什么是这个形状：仓库里字幕侧已有同款范式（`parseSubtitleMarkup` 产出
// `plainText` + `SubtitleSpan` 区间，见 packages/hibiki_audio/.../subtitle_markup.dart），
// 下游查词 / 制卡 sentence / 字数统计全靠「正文即唯一坐标系」才不漂移。注音走同一
// 形状，就不会重演「显示串 ≠ 查询串」那类偏移 bug。
//
// 唯一的差别是坐标单位用 **UTF-16 code unit** 而不是字素簇：本模块的消费端是
// Windows 原生浮窗，DirectWrite `HitTestPoint` 回传的 `textPosition` 就是 UTF-16
// 下标（windows/runner/floating_lyric_window.cpp:1465），而 Dart `String` 下标同单位，
// 两侧天然对齐，`JapaneseLanguage.wordFromIndex` 也是按 UTF-16 切。字素簇在这里
// 反而要多一层换算，是白送的错位风险。
//
// 设计底线（Never break userspace）：
// - 认不出的标记**原样保留**，绝不猜着删——宁可显示一个多余的尖括号，也不能吃掉
//   用户真正想看的正文。
// - 歧义形式（裸 `《》`、`[かな]`）必须同时满足「注音全是假名」+「前面紧挨着汉字
//   串」才成立，否则按普通文本处理。显式形式（`<ruby>`、`<r…>`、`｜…《》`）结构
//   无歧义，不需要这层保险。

import 'package:flutter/foundation.dart';

/// 一段注音：`ruby` 注在纯文本 [RubyMarkupText.text] 的 `[start, start+length)` 上方。
/// 下标单位是 UTF-16 code unit（与 Dart `String` 下标、DirectWrite `textPosition` 同单位）。
@immutable
class RubySpan {
  const RubySpan({
    required this.start,
    required this.length,
    required this.ruby,
  });

  final int start;
  final int length;
  final String ruby;

  int get end => start + length;

  RubySpan shifted(int delta) =>
      RubySpan(start: start + delta, length: length, ruby: ruby);

  /// MethodChannel 载荷（native 侧按同名字段解包，见 windows/runner/flutter_window.cpp）。
  Map<String, Object?> toChannelMap() => <String, Object?>{
        'start': start,
        'length': length,
        'ruby': ruby,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RubySpan &&
          start == other.start &&
          length == other.length &&
          ruby == other.ruby;

  @override
  int get hashCode => Object.hash(start, length, ruby);

  @override
  String toString() => 'RubySpan($start,$length,$ruby)';
}

/// 解析结果：[text] 是剥掉注音标记后的纯基准文本，[spans] 是挂在它上面的注音区间。
@immutable
class RubyMarkupText {
  const RubyMarkupText({required this.text, required this.spans});

  /// 无注音的直通结果（绝大多数行走这条路）。
  factory RubyMarkupText.plain(String text) =>
      RubyMarkupText(text: text, spans: const <RubySpan>[]);

  final String text;
  final List<RubySpan> spans;

  bool get hasRuby => spans.isNotEmpty;

  /// 把区间重新基准化到 [candidate] 上。
  ///
  /// 管线里文本还会被继续加工（`trim()`、`_capLookupInput` 的尾部截断、去重返回
  /// trim 过的串），每处都可能让下标漂移。与其在每个加工点各写一遍偏移修正，不如
  /// 统一走这一个函数：[candidate] 必须是 [text] 的**连续子串**（trim 和截断都满足），
  /// 命中就整体平移并丢掉越界区间；一旦不是子串（说明发生了预期外的改写）就**退回
  /// 无注音**——宁可不显示振假名，也绝不显示错位的振假名。
  RubyMarkupText rebase(String candidate) {
    if (candidate == text) return this;
    if (spans.isEmpty) return RubyMarkupText.plain(candidate);
    final int offset = candidate.isEmpty ? -1 : text.indexOf(candidate);
    if (offset < 0) return RubyMarkupText.plain(candidate);
    final List<RubySpan> moved = <RubySpan>[];
    for (final RubySpan span in spans) {
      final int start = span.start - offset;
      if (start < 0 || start + span.length > candidate.length) continue;
      moved.add(RubySpan(start: start, length: span.length, ruby: span.ruby));
    }
    return RubyMarkupText(text: candidate, spans: moved);
  }

  /// `trim()` 并同步平移区间。
  RubyMarkupText trimmed() => rebase(text.trim());

  /// MethodChannel 载荷；无注音时返回 `null`，native 侧因此完全走老路径
  /// （缺省参数 = 今天逐像素一致）。
  List<Map<String, Object?>>? toChannelSpans() => rubySpansToChannel(spans);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RubyMarkupText &&
          text == other.text &&
          listEquals(spans, other.spans);

  @override
  int get hashCode => Object.hash(text, Object.hashAll(spans));

  @override
  String toString() => 'RubyMarkupText($text, $spans)';
}

/// 注音区间 → MethodChannel 载荷；空列表返回 `null`，让调用方直接省掉该字段，
/// native 因此完全走老渲染路径。
List<Map<String, Object?>>? rubySpansToChannel(List<RubySpan> spans) => spans
        .isEmpty
    ? null
    : spans.map((RubySpan span) => span.toChannelMap()).toList(growable: false);

/// 一个基准段及其注音（注音为空表示这段只是普通文本）。
typedef _RubyUnit = ({String base, String ruby});

/// 某个标记被吃掉后的结果：下一个扫描位置 + 产出的基准/注音段。
typedef _Consumed = ({int next, List<_RubyUnit> units});

/// 快速否定：一行里连注音标记的起始符都没有就直接直通，省掉整趟扫描。
/// galgame 台词绝大多数不带注音，这条捷径决定了本模块在 80ms 轮询里可以白跑。
final RegExp _rubyMarkerHint = RegExp(r'[<《｜|\[]');

/// `<ruby>漢字<rt>かんじ</rt></ruby>`（HTML / Web texthooker / 浏览器扩展常见）。
final RegExp _htmlRubyPattern = RegExp(
  r'<ruby\b[^>]*>(.*?)</ruby\s*>',
  caseSensitive: false,
  dotAll: true,
);

/// `<rp>（）</rp>` 是给不支持 ruby 的渲染器看的回退括号，整段丢弃（与 EPUB 侧
/// `EpubBook._removeRubyAnnotations` 同口径）。
final RegExp _rpElementPattern = RegExp(
  r'<rp\b[^>]*>.*?</rp\s*>',
  caseSensitive: false,
  dotAll: true,
);

/// `<rb>` / `<rtc>` 只是分组壳，去掉标签保留内容。
final RegExp _rubyShellTagPattern = RegExp(
  r'</?(?:rb|rtc)\b[^>]*>',
  caseSensitive: false,
);

final RegExp _rtElementPattern = RegExp(
  r'<rt\b[^>]*>(.*?)</rt\s*>',
  caseSensitive: false,
  dotAll: true,
);

/// `<rふる>震</r>`：注音写在标签里、基准是标签内容。截图里 WITCH ON THE HOLY NIGHT
/// 用的就是这一种，BGI/Ethornell 系的 `<R…>…</R>` 同形。
final RegExp _taggedRubyPattern =
    RegExp(r'<[rR]\s*([^<>]*?)\s*>([^<>]*)</[rR]\s*>');

/// 青空文庫式显式形：`｜震《ふる》`（全角竖线，也兼容 ASCII `|`）。有竖线定界，
/// 基准范围无歧义。
final RegExp _pipeAozoraPattern = RegExp(r'[｜|]([^｜|《》]+)《([^》]*)》');

/// 裸 `《ふる》` / `[ふる]`：基准靠「前面紧挨着的汉字串」倒推，是歧义形式，
/// 必须过假名判据。
final RegExp _bareAozoraPattern = RegExp(r'《([^》]*)》');
final RegExp _bracketReadingPattern = RegExp(r'\[([^\[\]]*)\]');

const int _kMaxRubyReadingLength = 16;

bool _isKanaRune(int rune) =>
    // 平假名（含濁点/半濁点/繰り返し記号）
    (rune >= 0x3041 && rune <= 0x309F) ||
    // 片假名（含長音符 ー / 中黒 ・）
    (rune >= 0x30A0 && rune <= 0x30FF) ||
    // 半角片假名
    (rune >= 0xFF66 && rune <= 0xFF9D);

/// 歧义形式的保险丝：注音必须是一串不太长的假名。真实注音永远满足；而普通文本里
/// 恰好出现的 `《…》`（书名号）、`[…]`（编号/时间）几乎必然不满足，于是被原样留下。
bool _isRubyReading(String reading) {
  if (reading.isEmpty || reading.length > _kMaxRubyReadingLength) return false;
  for (final int rune in reading.runes) {
    if (!_isKanaRune(rune)) return false;
  }
  return true;
}

/// 可以被裸注音倒推为基准的字符：汉字 + 々〆〇 + 兼容汉字。
/// 只认 BMP——扩展 B 区汉字要代理对，倒推会切碎；那种字上基本也不会出现裸注音，
/// 认不出就当普通文本，属于安全失败方向。
bool _isBaseUnit(int unit) =>
    (unit >= 0x4E00 && unit <= 0x9FFF) ||
    (unit >= 0x3005 && unit <= 0x3007) ||
    (unit >= 0xF900 && unit <= 0xFAFF);

/// 把 `<ruby>` 元素内部拆成交替的「基准段 + `<rt>` 注音」。
/// 支持 mono-ruby（`<ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>` → 两段各自注音）。
List<_RubyUnit> _splitRubyElement(String inner) {
  final String cleaned = inner
      .replaceAll(_rpElementPattern, '')
      .replaceAll(_rubyShellTagPattern, '');
  final List<_RubyUnit> units = <_RubyUnit>[];
  int cursor = 0;
  for (final Match match in _rtElementPattern.allMatches(cleaned)) {
    units.add((
      base: cleaned.substring(cursor, match.start),
      ruby: match.group(1) ?? '',
    ));
    cursor = match.end;
  }
  if (cursor < cleaned.length) {
    units.add((base: cleaned.substring(cursor), ruby: ''));
  }
  return units;
}

_Consumed? _tryHtmlRuby(String raw, int at) {
  final Match? match = _htmlRubyPattern.matchAsPrefix(raw, at);
  if (match == null) return null;
  final List<_RubyUnit> units = _splitRubyElement(match.group(1) ?? '');
  // `<ruby>` 的结构无歧义（rt 就是注音），所以不过假名判据：英文/罗马字注音一样
  // 该被抬到上方，而不是拼进正文。
  return (next: match.end, units: units);
}

_Consumed? _tryTaggedRuby(String raw, int at) {
  final Match? match = _taggedRubyPattern.matchAsPrefix(raw, at);
  if (match == null) return null;
  final String reading = match.group(1) ?? '';
  final String base = match.group(2) ?? '';
  // `<r…>` 的标签名太短，普通文本里也可能撞上（`<red>` 之类），过一道假名判据。
  if (base.isEmpty || !_isRubyReading(reading)) return null;
  return (next: match.end, units: <_RubyUnit>[(base: base, ruby: reading)]);
}

_Consumed? _tryPipeAozora(String raw, int at) {
  final Match? match = _pipeAozoraPattern.matchAsPrefix(raw, at);
  if (match == null) return null;
  final String base = match.group(1) ?? '';
  final String reading = match.group(2) ?? '';
  if (base.isEmpty || reading.isEmpty) return null;
  // 有 `｜` 显式定界，基准范围无歧义，不需要假名判据。
  return (next: match.end, units: <_RubyUnit>[(base: base, ruby: reading)]);
}

/// 裸注音（`《…》` / `[…]`）：基准要从**已经产出的正文**里倒推。
/// [floor] 是上一段注音的结束位置，倒推不许跨过它，否则会把已注音的字再吃一次。
int _lookbackBaseStart(List<int> out, int floor) {
  int start = out.length;
  while (start > floor && _isBaseUnit(out[start - 1])) {
    start--;
  }
  return start;
}

/// 解析注音标记。[raw] 原样返回时表示这行不含（可识别的）注音。
RubyMarkupText parseRubyMarkup(String raw) {
  if (raw.isEmpty || !_rubyMarkerHint.hasMatch(raw)) {
    return RubyMarkupText.plain(raw);
  }

  final List<int> out = <int>[];
  final List<RubySpan> spans = <RubySpan>[];

  void emit(List<_RubyUnit> units) {
    for (final _RubyUnit unit in units) {
      if (unit.base.isEmpty) continue;
      final int start = out.length;
      out.addAll(unit.base.codeUnits);
      if (unit.ruby.isNotEmpty) {
        spans.add(
          RubySpan(start: start, length: out.length - start, ruby: unit.ruby),
        );
      }
    }
  }

  int i = 0;
  while (i < raw.length) {
    final int unit = raw.codeUnitAt(i);

    if (unit == 0x3C /* < */) {
      final _Consumed? consumed =
          _tryHtmlRuby(raw, i) ?? _tryTaggedRuby(raw, i);
      if (consumed != null) {
        emit(consumed.units);
        i = consumed.next;
        continue;
      }
    } else if (unit == 0xFF5C /* ｜ */ || unit == 0x7C /* | */) {
      final _Consumed? consumed = _tryPipeAozora(raw, i);
      if (consumed != null) {
        emit(consumed.units);
        i = consumed.next;
        continue;
      }
    } else if (unit == 0x300A /* 《 */ || unit == 0x5B /* [ */) {
      final RegExp pattern =
          unit == 0x300A ? _bareAozoraPattern : _bracketReadingPattern;
      final Match? match = pattern.matchAsPrefix(raw, i);
      final String reading = match?.group(1) ?? '';
      if (match != null && _isRubyReading(reading)) {
        final int floor = spans.isEmpty ? 0 : spans.last.end;
        final int start = _lookbackBaseStart(out, floor);
        if (start < out.length) {
          spans.add(
            RubySpan(start: start, length: out.length - start, ruby: reading),
          );
          i = match.end;
          continue;
        }
      }
    }

    out.add(unit);
    i++;
  }

  // 注意不能在 spans 为空时直接返回 raw：`<ruby>` 里 `<rt>` 为空这类输入会剥掉标记
  // 却不产生注音，此时 out 已经与 raw 不同，返回 raw 等于把标记又塞回正文。
  return RubyMarkupText(text: String.fromCharCodes(out), spans: spans);
}
