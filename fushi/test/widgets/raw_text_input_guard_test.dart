import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

// 输入框 / 搜索框统一成 M3E（用户 2026-10-05）之后的回退守卫：lib/ 下新代码
// 不得再直接构造框架 / 第三方的原始输入控件，一律走共享层——
//   * 搜索：FushiSearchBar / FushiSearchAnchor / showFushiSearchView
//     （lib/src/utils/components/fushi_search.dart）；
//   * 输入：FushiTextField（fushi_material_components.dart）或设计系统分派的
//     FushiTextFieldControl / FushiTextFormFieldControl（glass/fushi_glass_inputs.dart）。
// 原始控件绕过了两套设计系统的形态（MD3 填充胶囊 / Apple 实色输入框）、
// BUG-2973 的竖直居中、IME 组字门与 Esc / 焦点归还，迁过去的地方会一处处
// 长回「各自一套」。
//
// 白名单是渐进的：共享组件实现文件本身允许；其余条目是已知存量，按
// (文件, 控件) 精确计数——迁走一处就把计数降下来，计数只许降不许升。

/// 被禁止的原始构造（前面不能紧跟标识符字符，所以 FushiTextField( /
/// FushiSearchBar( 不算）。
final RegExp _raw = RegExp(
  r'(?<![A-Za-z0-9_$])'
  r'(TextField|TextFormField|CupertinoTextField|CupertinoSearchTextField|'
  r'GlassTextField|MacosTextField|MacosSearchField|SearchBar|SearchAnchor)'
  r'\s*(?:\.\w+)?\s*\(',
);

/// 共享输入 / 搜索组件的实现文件：在这里包装原始控件是它们的职责。
const Set<String> _componentFiles = <String>{
  'lib/src/utils/components/fushi_material_components.dart',
  'lib/src/utils/components/glass/fushi_glass_inputs.dart',
  'lib/src/utils/components/fushi_search.dart',
};

/// 存量：(文件 → 控件 → 允许的次数)。迁移后降计数 / 删条目。
const Map<String, Map<String, int>> _legacy = <String, Map<String, int>>{
  // AI 下视频对话页底部输入条：Apple 下是浮在对话上的透明液态玻璃胶囊
  // （Messages 输入条），共享 Apple 输入框是内容层实色框，形态不同。
  'lib/src/pages/implementations/ai_video_acquisition_page.dart': <String, int>{
    'GlassTextField': 1,
  },
  // 设置页搜索框：设置重设计分支（sh-settings-redesign）在改这个文件，
  // 合并后改用 FushiSearchBar。
  'lib/src/settings/settings_home_page.dart': <String, int>{
    'CupertinoSearchTextField': 1,
  },
  // AdaptiveSettingsTextField 的 Apple 分支：iOS 表单的玻璃输入框（标签在框
  // 上方、说明在框下方），MD3 分支已走 FushiTextFormFieldControl。
  'lib/src/utils/components/settings_shared.dart': <String, int>{
    'GlassTextField': 1,
  },
};

Map<String, Map<String, int>> _scan() {
  final Map<String, Map<String, int>> hits = <String, Map<String, int>>{};
  final List<FileSystemEntity> entries = Directory(
    'lib',
  ).listSync(recursive: true);
  for (final FileSystemEntity entity in entries) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final String path = entity.path.replaceAll(r'\', '/');
    if (path.endsWith('.g.dart')) continue;
    if (_componentFiles.contains(path)) continue;
    final String source = maskCommentsAndStrings(entity.readAsStringSync());
    for (final String code in source.split('\n')) {
      for (final RegExpMatch m in _raw.allMatches(code)) {
        final String name = m.group(1)!;
        (hits[path] ??= <String, int>{}).update(
          name,
          (int n) => n + 1,
          ifAbsent: () => 1,
        );
      }
    }
  }
  return hits;
}

void main() {
  test('lib/ 不直接构造原始输入 / 搜索控件（走 FushiSearchBar / FushiTextField）', () {
    final Map<String, Map<String, int>> hits = _scan();
    final List<String> violations = <String>[];
    hits.forEach((String path, Map<String, int> byName) {
      byName.forEach((String name, int count) {
        final int allowed = _legacy[path]?[name] ?? 0;
        if (count > allowed) {
          violations.add('$path: $name × $count（允许 $allowed）');
        }
      });
    });
    expect(
      violations,
      isEmpty,
      reason:
          '改用共享组件：搜索用 FushiSearchBar（fushi_search.dart），输入用 '
          'FushiTextField / FushiTextFieldControl / FushiTextFormFieldControl。',
    );
  });

  test('存量白名单不过期：迁走后要把计数降下来', () {
    final Map<String, Map<String, int>> hits = _scan();
    final List<String> stale = <String>[];
    _legacy.forEach((String path, Map<String, int> byName) {
      byName.forEach((String name, int allowed) {
        final int actual = hits[path]?[name] ?? 0;
        if (actual < allowed) {
          stale.add('$path: $name 实际 $actual < 白名单 $allowed');
        }
      });
    });
    expect(stale, isEmpty, reason: '白名单只许降：把计数改成实际值或删掉条目');
  });

  test('守卫的匹配本身：认原始控件、不认共享组件', () {
    bool matches(String code) => _raw.hasMatch(maskCommentsAndStrings(code));
    expect(matches('child: TextField('), isTrue);
    expect(matches('return TextFormField('), isTrue);
    expect(matches('CupertinoTextField.borderless('), isTrue);
    expect(matches('const SearchBar('), isTrue);
    expect(matches('FushiTextField('), isFalse);
    expect(matches('FushiSearchBar('), isFalse);
    expect(matches('FushiTextFieldControl('), isFalse);
    expect(matches('PopupDictionarySearchBar('), isFalse);
    expect(matches('find.byType(TextField)'), isFalse);
    expect(matches('// TextField('), isFalse);
    expect(matches('/* ignored\nTextField( */'), isFalse);
    expect(matches("final hint = 'TextField(';"), isFalse);
    expect(matches("final url = 'https://example.test'; TextField();"), isTrue);
  });
}
