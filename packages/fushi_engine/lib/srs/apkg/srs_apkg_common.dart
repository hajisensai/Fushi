/// 导入 / 导出共用：媒体引用扫描与改写、fushi-ext 格式常量、导入牌组的确定性 ID。
library;

import 'package:fushi_srs/fushi_srs.dart';

/// fushi-ext 的 format 字段值与版本号（导入只认 [srsFushiExtVersion] 及以下）。
const String srsFushiExtFormat = 'fushi-ext';
const int srsFushiExtVersion = 1;

/// fushi-ext 里每个牌组随附的设置键（按 Fushi 原值写出 / 恢复）。
const List<String> srsFushiExtDeckKeys = <String>[
  SrsFieldKeys.deckParamsMode,
  SrsFieldKeys.deckAlgorithm,
  SrsFieldKeys.deckFsrs6Params,
  SrsFieldKeys.deckFsrs7Params,
  SrsFieldKeys.deckRetention,
  SrsFieldKeys.deckSteps,
  SrsFieldKeys.deckLimits,
  SrsFieldKeys.deckMaxInterval,
  SrsFieldKeys.deckAutoplay,
  SrsFieldKeys.deckReplayQuestion,
  SrsFieldKeys.deckRwkvQueue,
  SrsFieldKeys.deckNewPlan,
];

/// 从 Anki 导入时按全名新建的牌组 ID：与 Fushi 里新建牌组同一条规则（[SrsIds.deck]），
/// 多台设备各自导入同一个包、或一端导入一端手建同名牌组，合并后都是同一个牌组。
String srsImportedDeckId(String profileUid, String fullName) =>
    SrsIds.deck(profileUid, fullName);

// Anki rslib text.rs 的 HTML 媒体引用：img/audio/video/object/source/iframe 的 src / data。
final RegExp _htmlMediaRef = RegExp(
  r'''<\b(?:img|audio|video|object|source|iframe)\b[^>]+\b(?:src|data)\b=(?:"([^"]+?)"|'([^']+?)'|([^ >]+?))(?=\s|>)''',
  caseSensitive: false,
  dotAll: true,
);

final RegExp _soundRef = RegExp(r'\[sound:([^\]]+)\]');

/// 模板 / CSS 里引用下划线开头静态文件的写法（url("_x.woff")、src="_x.js" 等）。
final RegExp _staticRef = RegExp(r'''["'(]\s*(_[^"')\s]+)''');

bool _isRemote(String name) => name.contains('://') || name.startsWith('data:');

String _unescape(String s) {
  String out = s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
  try {
    out = Uri.decodeFull(out);
  } on ArgumentError {
    // 不是合法百分号编码：按原样。
  }
  return out;
}

/// 一段 HTML（字段值 / 模板）引用的本地媒体文件名（已反转义）。
Set<String> srsMediaRefsIn(String html, {bool includeStatic = false}) {
  // 快速判断：标签引用必含「<」、音频引用必含「[sound:」（纯文本字段占多数，迁移时要
  // 扫几十万个字段）。
  if (!includeStatic && !html.contains('<') && !html.contains('[sound:')) {
    return <String>{};
  }
  final Set<String> out = <String>{};
  for (final RegExpMatch m in _htmlMediaRef.allMatches(html)) {
    final String raw = m.group(1) ?? m.group(2) ?? m.group(3) ?? '';
    if (raw.isEmpty || _isRemote(raw)) continue;
    out.add(_unescape(raw));
  }
  for (final RegExpMatch m in _soundRef.allMatches(html)) {
    final String raw = m.group(1)!;
    if (!_isRemote(raw)) out.add(_unescape(raw));
  }
  if (includeStatic) {
    for (final RegExpMatch m in _staticRef.allMatches(html)) {
      out.add(_unescape(m.group(1)!));
    }
  }
  return out;
}

/// 把 [html] 里的媒体引用按 [renames]（原名 → 新名）改写；没改名的原样保留。
String srsRewriteMediaRefs(String html, Map<String, String> renames) {
  if (renames.isEmpty) return html;
  String rewriteGroup(RegExpMatch m, int group) {
    final String whole = m.group(0)!;
    final String? raw = m.group(group);
    if (raw == null) return whole;
    final String? to = renames[_unescape(raw)];
    if (to == null || to == raw) return whole;
    final int at = whole.lastIndexOf(raw);
    return whole.substring(0, at) + to + whole.substring(at + raw.length);
  }

  String out = html.replaceAllMapped(_htmlMediaRef, (Match mm) {
    final RegExpMatch m = mm as RegExpMatch;
    final int g = m.group(1) != null ? 1 : (m.group(2) != null ? 2 : 3);
    return rewriteGroup(m, g);
  });
  out = out.replaceAllMapped(
    _soundRef,
    (Match m) => rewriteGroup(m as RegExpMatch, 1),
  );
  out = out.replaceAllMapped(
    _staticRef,
    (Match m) => rewriteGroup(m as RegExpMatch, 1),
  );
  return out;
}
