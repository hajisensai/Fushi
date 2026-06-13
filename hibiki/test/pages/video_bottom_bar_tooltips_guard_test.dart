import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：视频底栏 5 键都有 Tooltip + i18n key 存在（BUG-247 / TODO-282）。
///
/// 根因：底栏 5 键用 media_kit 的 [MaterialDesktopCustomButton] /
/// [MaterialCustomButton] / [MaterialDesktopPlayOrPauseButton] /
/// [MaterialPlayOrPauseButton]，均无 tooltip 参数，悬停无提示。修复用 Flutter
/// [Tooltip] 包裹这 5 键，文案诚实反映双重语义（上一句/下一句在无字幕段退化成相对 seek）。
///
/// media_kit controls 跑不了 headless，故锁源码结构 + i18n 不变量。
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );
  final File baseI18n = File('lib/i18n/strings.i18n.json');
  final File generated = File('lib/i18n/strings.g.dart');

  late String src;
  late String i18nSrc;
  late String genSrc;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    expect(baseI18n.existsSync(), isTrue, reason: 'i18n 基准文件应存在');
    expect(generated.existsSync(), isTrue, reason: 'strings.g.dart 应存在');
    src = page.readAsStringSync();
    i18nSrc = baseI18n.readAsStringSync();
    genSrc = generated.readAsStringSync();
  });

  /// 截共享底栏构造器 [_centeredBottomControlBar] 段（BUG-257 起底栏 5 键的 Tooltip
  /// 与 seek 标注都收口到此 helper，桌面/移动主题各用一个 [Expanded] 调它）。
  String bottomBarHelper() {
    final int start = src.indexOf('Widget _centeredBottomControlBar(');
    expect(start, greaterThanOrEqualTo(0),
        reason: '需有共享底栏构造器 _centeredBottomControlBar');
    // helper 以 `_seekLabelButton` 方法定义起头处收尾。
    final int end = src.indexOf('Widget _seekLabelButton(', start);
    expect(end, greaterThan(start), reason: '_centeredBottomControlBar 应正常闭合');
    return src.substring(start, end);
  }

  const List<String> tooltipKeys = <String>[
    'video_bottom_seek_back',
    'video_bottom_prev_cue',
    'video_bottom_play_pause',
    'video_bottom_next_cue',
    'video_bottom_seek_forward',
  ];

  test('共享底栏 5 键有 Tooltip（桌面/移动同源 _centeredBottomControlBar）', () {
    final String bar = bottomBarHelper();
    // 上一句/play/下一句直接包 Tooltip(message:)，±10s 经 _seekLabelButton 的 tooltip 参数。
    for (final String key in <String>[
      'video_bottom_prev_cue',
      'video_bottom_play_pause',
      'video_bottom_next_cue',
    ]) {
      expect(
        bar.contains('Tooltip(') && bar.contains('message: t.$key'),
        isTrue,
        reason: '共享底栏应有 Tooltip(message: t.$key)',
      );
    }
    expect('Tooltip('.allMatches(bar).length, greaterThanOrEqualTo(3),
        reason: '上一句/play/下一句各包一个 Tooltip');
    expect('tooltip: t.video_bottom_seek_back'.allMatches(bar).length, 1,
        reason: '−10s seek 按钮经 _seekLabelButton tooltip 透传');
    expect('tooltip: t.video_bottom_seek_forward'.allMatches(bar).length, 1,
        reason: '+10s seek 按钮经 _seekLabelButton tooltip 透传');
  });

  test('桌面 + 移动底栏都走共享 _centeredBottomControlBar（无分叉 5 键）', () {
    expect(
      'Expanded(\n          child: _centeredBottomControlBar(controller, desktop: true)'
          .allMatches(src)
          .length,
      1,
      reason: '桌面底栏应走共享 helper',
    );
    expect(
      'Expanded(\n          child: _centeredBottomControlBar(controller, desktop: false)'
          .allMatches(src)
          .length,
      1,
      reason: '移动底栏应走共享 helper',
    );
  });

  test('5 个底栏 tooltip i18n key 在基准 + 生成文件都存在', () {
    for (final String key in tooltipKeys) {
      expect(i18nSrc.contains('"$key"'), isTrue,
          reason: 'strings.i18n.json 缺 key $key');
      expect(genSrc.contains('String get $key'), isTrue,
          reason: 'strings.g.dart 缺 getter $key');
    }
  });
}
