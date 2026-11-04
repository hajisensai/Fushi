// FushiAlertDialog 的内容区默认由 FushiDialogContentScroll 负责「装不下就滚」，
// 调用点不再手包 SingleChildScrollView——包括外面先套一层 SizedBox /
// ConstrainedBox 定宽、里面再手包滚动的写法（那会变成外壳一层 + 手包一层的嵌套
// 滚动）。这里静态扫 lib/：`content:` 之后紧跟（几行内）手包滚动的 FushiAlertDialog
// 调用点只允许白名单里的「定高日志 / 显式限高区域」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 有意保留内层滚动的调用点：路径 → 允许的处数与原因。
const Map<String, (int, String)> _allowed = <String, (int, String)>{
  // 本地 TTS 引擎日志：定高 360 的日志窗、reverse 贴底滚，不是「装不下兜底」。
  'lib/src/media/audiobook/tts/gpt_sovits_local_page.dart': (1, '定高日志窗'),
  'lib/src/media/audiobook/tts/irodori_local_page.dart': (1, '定高日志窗'),
  'lib/src/media/audiobook/tts/voicevox_local_page.dart': (1, '定高日志窗'),
  // 长度无上限的内容（全量字段值 / 错误日志）：可能高过外壳判型用的放大上限
  // （整窗 4 倍），超过后外壳会把它当吃满型给视口高度，所以由内层滚动视口自己滚。
  // 内层 SCSV 在外壳里不会形成两级滚动：装得进上限时外层滚、内层全展开；装不进
  // 时外层不滚、内层滚。
  'lib/src/anki/anki_mined_card_action_sheet.dart': (1, '全量字段值，长度无上限'),
  'lib/src/utils/misc/error_details_dialog.dart': (1, '错误详情日志，长度无上限'),
  'lib/src/pages/implementations/video_download_jobs_panel.dart': (
    1,
    '下载错误原文，长度无上限',
  ),
  // 刮削运行详情：ConstrainedBox(maxHeight) 显式限高的滚动区。
  'lib/src/media/video/metadata/video_source_scrape_run_detail_dialog.dart': (
    2,
    '显式限高区域',
  ),
};

/// 从 [open]（指向 `(`）起找配对的 `)`；跳过字符串与注释。
int _matchParen(String src, int open) {
  int depth = 0;
  int i = open;
  while (i < src.length) {
    final String c = src[i];
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      final int nl = src.indexOf('\n', i);
      i = nl < 0 ? src.length : nl;
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i = src.indexOf('*/', i) + 2;
      continue;
    }
    if (c == "'" || c == '"') {
      final bool triple = src.startsWith(c * 3, i);
      final String quote = triple ? c * 3 : c;
      int j = i + quote.length;
      while (j < src.length && !src.startsWith(quote, j)) {
        j += src[j] == r'\' ? 2 : 1;
      }
      i = j + quote.length;
      continue;
    }
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return src.length;
}

/// 每个 FushiAlertDialog 调用里 content 手包滚动的处数（显式传 scrollable 的不算）。
int _manualScrollSites(String src) {
  int count = 0;
  final RegExp ctor = RegExp(r'\bFushiAlertDialog\(');
  for (final RegExpMatch m in ctor.allMatches(src)) {
    final int open = m.end - 1;
    final int close = _matchParen(src, open);
    final String call = src.substring(open, close);
    if (RegExp(r'\bscrollable\s*:').hasMatch(call)) continue;
    final int content = call.indexOf(RegExp(r'\bcontent:\s'));
    if (content < 0) continue;
    // content 后 8 行内出现 SingleChildScrollView 即视为手包。
    final List<String> lines = call.substring(content).split('\n');
    final String head = lines.take(9).join('\n');
    if (head.contains('SingleChildScrollView(')) count++;
  }
  return count;
}

void main() {
  test('FushiAlertDialog 调用点不手包 SingleChildScrollView（定宽外壳里也不行）', () {
    final Map<String, int> found = <String, int>{};
    for (final FileSystemEntity e in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String src = e.readAsStringSync();
      if (!src.contains('FushiAlertDialog(')) continue;
      final int n = _manualScrollSites(src);
      if (n > 0) found[e.path.replaceAll(r'\', '/')] = n;
    }
    final List<String> offenders = <String>[
      for (final MapEntry<String, int> f in found.entries)
        if (f.value != (_allowed[f.key]?.$1 ?? 0)) '${f.key}: ${f.value} 处',
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          '内容区的「装不下就滚」由 FushiAlertDialog 自带的 FushiDialogContentScroll '
          '负责，调用点只定宽、不再手包 SingleChildScrollView；确需内层定高 / 限高'
          '滚动区的，登记进 _allowed 并写明原因',
    );
    // 白名单不留陈旧项。
    for (final MapEntry<String, (int, String)> a in _allowed.entries) {
      expect(found[a.key], a.value.$1, reason: '${a.key} 白名单已陈旧');
    }
  });

  test('判据自检：定宽外壳里的手包滚动被认出来，显式 scrollable 放行', () {
    const String wrapped = '''
FushiAlertDialog(
  content: SizedBox(
    width: 420,
    child: SingleChildScrollView(child: Text('a (b')),
  ),
)''';
    const String explicit = '''
FushiAlertDialog(
  scrollable: false,
  content: SingleChildScrollView(child: Text('x')),
)''';
    const String clean = '''
FushiAlertDialog(
  content: SizedBox(width: 420, child: Column(children: <Widget>[])),
)''';
    expect(_manualScrollSites(wrapped), 1);
    expect(_manualScrollSites(explicit), 0);
    expect(_manualScrollSites(clean), 0);
  });
}
