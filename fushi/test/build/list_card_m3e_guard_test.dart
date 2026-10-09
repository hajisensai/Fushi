import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

// 列表与卡片统一为 M3E（2026-10-05）的守卫：lib/ 下禁止新增裸 Material
// `ListTile(` / `Card(` / `Card.filled(` / `Card.outlined(`。
//
// 裸控件绕过了共享层的全部规格——M3E 形状分级（卡 20）、分段列表的交互形变、
// secondaryContainer 选中底、Apple 设计系统的 inset grouped 实色行、焦点契约
// （FushiFocusTarget / Enter 激活）、墨水屏描边。一律改用：
// - 列表行：FushiListItem（共享行）或 FushiListTileControl（与 ListTile 同参）；
//   分组：FushiGroupedList / FushiGroupedListItem / SliverFushiGroupedList；
// - 卡片：FushiCard（variant / tone）或 FushiCardControl（与 Card 同参）。
//
// 白名单只放「包装本身」：设计系统分派层必须在 MD3 分支里构造原控件。

/// 允许出现裸构造的文件（相对 fushi/，正斜杠）→ 原因。
const Map<String, String> _allowlist = <String, String>{
  'lib/src/utils/components/glass/fushi_glass_lists.dart':
      'FushiListTileControl / FushiCardControl 的 MD3 分支构造原 ListTile / Card',
};

final RegExp _raw = RegExp(
  r'(?<![A-Za-z0-9_.$])(ListTile|Card)(\.filled|\.outlined)?\(',
);

void main() {
  test('lib/ 下没有新增的裸 ListTile / Card', () {
    final Directory lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: '须在 fushi/ 下运行');
    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String rel = entity.path.replaceAll(r'\', '/');
      if (rel.endsWith('.g.dart') || _allowlist.containsKey(rel)) continue;
      final String source = entity.readAsStringSync();
      final List<String> lines = source.split('\n');
      final List<String> codeLines = maskCommentsAndStrings(source).split('\n');
      for (int i = 0; i < lines.length; i++) {
        if (_raw.hasMatch(codeLines[i])) {
          offenders.add('$rel:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '改用 FushiListItem / FushiListTileControl / FushiGroupedList* / '
          'FushiCard / FushiCardControl（见 fushi_m3e_list_card.dart 顶部说明）；'
          '确需裸控件的包装层才可进白名单',
    );
  });

  test('扫描只认真实构造，保留 URL 后面的代码与原行号', () {
    const String source = """// Card(
/* ListTile(
Card.filled( */
final hint = 'Card.outlined(';
final url = 'https://example.test'; Card();
ListTile(); // Card(
""";
    final List<String> lines = maskCommentsAndStrings(source).split('\n');
    expect(
      <int>[
        for (int i = 0; i < lines.length; i++)
          if (_raw.hasMatch(lines[i])) i + 1,
      ],
      <int>[5, 6],
    );
  });

  test('白名单里的文件都还存在且确实用到裸控件（防过期）', () {
    for (final String path in _allowlist.keys) {
      final File f = File(path);
      expect(f.existsSync(), isTrue, reason: '$path 已不存在，删掉白名单条目');
      expect(
        _raw.hasMatch(maskCommentsAndStrings(f.readAsStringSync())),
        isTrue,
        reason: '$path 已不再构造裸 ListTile / Card，删掉白名单条目',
      );
    }
  });
}
