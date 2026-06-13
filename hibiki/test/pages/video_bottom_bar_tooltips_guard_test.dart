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

  /// 截某套主题的 bottomButtonBar 段（从 `bottomButtonBar:` 到方法体内下一个 `];`）。
  String bottomBar(String themeSig) {
    final int themeIdx = src.indexOf(themeSig);
    expect(themeIdx, greaterThanOrEqualTo(0), reason: '需有 $themeSig');
    final int bottom = src.indexOf('bottomButtonBar: <Widget>[', themeIdx);
    expect(bottom, greaterThanOrEqualTo(0),
        reason: '$themeSig 缺 bottomButtonBar');
    // bottomButtonBar 以 `_buildFullscreenButton(desktop:` 收尾的那行后第一个 `],`。
    final int fsIdx = src.indexOf('_buildFullscreenButton(', bottom);
    expect(fsIdx, greaterThan(bottom),
        reason: '$themeSig bottomButtonBar 应以全屏按钮收尾');
    final int end = src.indexOf('],', fsIdx);
    expect(end, greaterThan(fsIdx), reason: '$themeSig bottomButtonBar 应正常闭合');
    return src.substring(bottom, end);
  }

  const List<String> tooltipKeys = <String>[
    'video_bottom_seek_back',
    'video_bottom_prev_cue',
    'video_bottom_play_pause',
    'video_bottom_next_cue',
    'video_bottom_seek_forward',
  ];

  void expectBottomTooltips(String themeSig) {
    final String bar = bottomBar(themeSig);
    for (final String key in tooltipKeys) {
      expect(
        bar.contains('Tooltip(') && bar.contains('message: t.$key'),
        isTrue,
        reason: '$themeSig 底栏应有 Tooltip(message: t.$key)',
      );
    }
    // 5 键都包 Tooltip：bottomButtonBar 内至少 5 个 Tooltip(。
    expect('Tooltip('.allMatches(bar).length, greaterThanOrEqualTo(5),
        reason: '$themeSig 底栏 5 键应各包一个 Tooltip');
  }

  test('桌面底栏 5 键有 Tooltip', () {
    expectBottomTooltips('MaterialDesktopVideoControlsThemeData');
  });

  test('移动底栏 5 键有 Tooltip', () {
    expectBottomTooltips(
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
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
