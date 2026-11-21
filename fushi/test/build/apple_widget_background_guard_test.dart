import 'dart:io';

import 'package:test/test.dart';

/// BUG-4932：iOS / macOS 主屏小组件的底色必须是系统背景 `.background`，与原生小组件同一块面。
///
/// `.containerBackground(.fill.tertiary, for: .widget)`（Xcode 模板默认值）是给控件用的半透明
/// 填充，深色模式下叠出约 `#2D2D2D` 的灰底，比原生小组件（约 `#1C1C1E`）明显发白。Swift 在
/// Windows / Linux CI 上编不了，靠读源码守住：所有小组件都走 `fushiWidgetBackground()`，
/// 且整个扩展里没有任何 `containerBackground` 用 `.fill.*` 当底色。
void main() {
  const String dir = 'apple/HomeWidgets';

  List<File> swiftSources() =>
      Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.swift'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));

  test('widget container background is the system background', () {
    final String timeline = File(
      '$dir/Extension/FushiWidgetTimeline.swift',
    ).readAsStringSync();
    expect(
      timeline,
      contains(
        'buttonStyle(.plain).containerBackground(.background, for: .widget)',
      ),
    );
  });

  test('no containerBackground uses a translucent .fill style', () {
    final RegExp fillBackground = RegExp(r'containerBackground\(\s*\.fill\b');
    final List<String> offenders = <String>[
      for (final File f in swiftSources())
        if (fillBackground.hasMatch(f.readAsStringSync())) f.path,
    ];
    expect(offenders, isEmpty);
  });

  test('every home screen widget goes through fushiWidgetBackground()', () {
    final String views = File(
      '$dir/Extension/FushiHomeWidgetViews.swift',
    ).readAsStringSync();
    final int configs = RegExp(
      r'StaticConfiguration\(kind:',
    ).allMatches(views).length;
    final int backgrounds = RegExp(
      r'\.fushiWidgetBackground\(\)',
    ).allMatches(views).length;
    expect(configs, greaterThan(0));
    expect(backgrounds, configs);
  });
}
