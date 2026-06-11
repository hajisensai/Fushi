import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-127 视频控制条清理（4 子项）源码守卫。
///
/// media_kit 跑不了 headless，桌面/移动 controls 主题与 bottom sheet 都难在 widget
/// 测试里真实驱动，故把不变量锁在 `video_hibiki_page.dart` 的源码结构上：
/// ① 控制条不再放着色器对比按钮（C 快捷键 + 右键菜单 + `_toggleShaderCompare` 保留）。
/// ② 倍速 / 音轨字幕轨 bottom sheet 可滚动（isScrollControlled + maxHeight 约束）。
/// ③ 控制条不再放倍速按钮（`_showSpeedMenu` 方法保留——右键菜单仍引用）。
/// ④ 字幕列表按钮移到 topButtonBar 倒数第二（设置 tune 按钮左边），桌面 + 移动一致。
void main() {
  final String src =
      File('lib/src/pages/implementations/video_hibiki_page.dart')
          .readAsStringSync();

  /// 桌面 + 移动两套 controls 主题方法体（含两条 topButtonBar）。
  String controlsThemes() {
    final int start = src.indexOf('MaterialDesktopVideoControlsThemeData');
    final int end = src.indexOf('void _showTrackMenu(');
    expect(start, greaterThanOrEqualTo(0), reason: '需有桌面 controls 主题起点');
    expect(end, greaterThan(start),
        reason: '需有 _showTrackMenu 作为 controls 段终点');
    return src.substring(start, end);
  }

  group('① 控制条无着色器对比按钮（保留 C / 右键 / _toggleShaderCompare）', () {
    test('控制条不含 Icons.compare 按钮', () {
      expect(controlsThemes().contains('Icons.compare'), isFalse,
          reason: '着色器对比按钮应移出桌面 / 移动控制条');
    });
    test('_toggleShaderCompare 方法与 C 快捷键接线保留', () {
      expect(
          src.contains('Future<void> _toggleShaderCompare() async {'), isTrue,
          reason: '_toggleShaderCompare 方法必须保留（右键菜单 + 快捷键引用）');
      expect(
          src.contains(
            'toggleShaderCompare: () => unawaited(_toggleShaderCompare())',
          ),
          isTrue,
          reason: 'C 快捷键 action 接线保留');
    });
  });

  group('② 倍速 / 音轨字幕轨菜单可滚动', () {
    String sheetBody(String startSig) {
      final int start = src.indexOf(startSig);
      expect(start, greaterThanOrEqualTo(0), reason: '需有 $startSig');
      final int end = src.indexOf('.whenComplete(', start);
      expect(end, greaterThan(start), reason: '$startSig 缺 whenComplete 终点');
      return src.substring(start, end);
    }

    test('_showSpeedMenu 用 isScrollControlled + maxHeight + 可滚动 ListView', () {
      final String body = sheetBody('void _showSpeedMenu() {');
      expect(body.contains('isScrollControlled: true'), isTrue,
          reason: '倍速 sheet 须 isScrollControlled（否则半屏裁掉底部档位）');
      expect(body.contains('maxHeight:'), isTrue,
          reason: '倍速 sheet 须 maxHeight 约束');
      expect(body.contains('ListView.builder('), isTrue,
          reason: '倍速 sheet 须用可滚动 ListView（不再裸 Column 堆 ListTile）');
      expect(body.contains('Column('), isFalse,
          reason: '倍速 sheet 不应再用不可滚动的 Column 堆档位');
    });

    test('_showTrackMenu 同病同治：isScrollControlled + maxHeight + 可滚动 ListView',
        () {
      final String body = sheetBody('void _showTrackMenu(');
      expect(body.contains('isScrollControlled: true'), isTrue,
          reason: '音轨 / 字幕轨 sheet 须 isScrollControlled');
      expect(body.contains('maxHeight:'), isTrue,
          reason: '音轨 / 字幕轨 sheet 须 maxHeight 约束');
      expect(body.contains('ListView.builder('), isTrue,
          reason: '音轨 / 字幕轨 sheet 须用可滚动 ListView.builder');
    });
  });

  group('③ 控制条无倍速按钮（_showSpeedMenu 方法保留）', () {
    test('控制条不含 Icons.speed 按钮', () {
      expect(controlsThemes().contains('Icons.speed'), isFalse,
          reason: '倍速按钮应移出控制条（改从右键菜单 / [ ] 快捷键 / 设置调）');
    });
    test('_showSpeedMenu 方法保留（右键菜单引用）', () {
      expect(src.contains('void _showSpeedMenu() {'), isTrue,
          reason: '_showSpeedMenu 方法必须保留（右键菜单仍引用）');
      expect(
          src.contains('item(Icons.speed, t.video_setting_speed, '
              '_showSpeedMenu)'),
          isTrue,
          reason: '右键菜单倍速项仍走 _showSpeedMenu');
    });
  });

  group('④ 字幕列表按钮在 topButtonBar 倒数第二（设置左边）', () {
    /// 截某套主题的 topButtonBar 段（从 `topButtonBar:` 到 `bottomButtonBar:`）。
    String topBar(String themeSig) {
      final int themeIdx = src.indexOf(themeSig);
      expect(themeIdx, greaterThanOrEqualTo(0), reason: '需有 $themeSig');
      final int top = src.indexOf('topButtonBar:', themeIdx);
      final int bottom = src.indexOf('bottomButtonBar:', top);
      expect(top, greaterThanOrEqualTo(0), reason: '$themeSig 缺 topButtonBar');
      expect(bottom, greaterThan(top), reason: '$themeSig 缺 bottomButtonBar');
      return src.substring(top, bottom);
    }

    void expectJumpListSecondToLast(String themeSig) {
      final String bar = topBar(themeSig);
      // 字幕列表按钮以其 onPressed 锚定（图标 + onPressed 同属一枚按钮）。
      const String jumpSig = 'onPressed: _toggleSubtitleJumpList,';
      final int jumpIdx = bar.indexOf(jumpSig);
      final int settingsIdx = bar.indexOf('onPressed: _showPlayerSettings');
      expect(jumpIdx, greaterThanOrEqualTo(0), reason: '$themeSig 顶栏缺字幕列表按钮');
      expect(settingsIdx, greaterThanOrEqualTo(0), reason: '$themeSig 顶栏缺设置按钮');
      // 字幕列表必须排在设置之前（左边）。
      expect(jumpIdx, lessThan(settingsIdx),
          reason: '$themeSig 字幕列表按钮应在设置按钮左边');
      // 倒数第二 = 字幕列表自身 onPressed 之后、设置按钮之前不再夹别的按钮的
      // onPressed（紧挨设置左侧，二者之间只剩设置按钮构造器）。
      final String between =
          bar.substring(jumpIdx + jumpSig.length, settingsIdx);
      expect(between.contains('onPressed:'), isFalse,
          reason: '$themeSig 字幕列表与设置之间不应再夹其它按钮（须为倒数第二）');
      expect(between.contains('_buildCrossSubtitleRecordButton'), isFalse,
          reason: '$themeSig 字幕列表与设置之间不应再夹跨字幕制卡按钮');
    }

    test('桌面顶栏字幕列表是倒数第二（紧挨设置左侧）', () {
      expectJumpListSecondToLast('MaterialDesktopVideoControlsThemeData');
    });
    test('移动顶栏字幕列表是倒数第二（紧挨设置左侧）', () {
      expectJumpListSecondToLast(
          'MaterialVideoControlsThemeData _mobileControlsTheme(');
    });
  });
}
