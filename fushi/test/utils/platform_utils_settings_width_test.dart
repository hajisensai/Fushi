import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 设置页内容宽守卫：宽屏不再有强制内容宽上限（用户实报「设置页有莫名奇妙的宽度
/// 限制」）。此前 medium / expanded 返回 960，把走 [DesktopContentLayout] 的设置
/// 正文（各库页内嵌的设置标签页 `ModuleSettingsView`）居中锁在窄栏。
void main() {
  test('settings content has no width cap on wide desktop', () {
    for (final WindowSizeClass sizeClass in <WindowSizeClass>[
      WindowSizeClass.medium,
      WindowSizeClass.expanded,
    ]) {
      expect(
        desktopContentMaxWidth(sizeClass, DesktopContentKind.settings),
        isNull,
        reason: '$sizeClass 下设置正文应占满（仅留侧向留白），不得再被 960 锁窄',
      );
    }
  });

  test('compact returns null (no cap) for settings', () {
    expect(
      desktopContentMaxWidth(
        WindowSizeClass.compact,
        DesktopContentKind.settings,
      ),
      isNull,
    );
  });

  test('settings keeps its side padding so text does not touch the edge', () {
    expect(
      desktopContentPadding(
        WindowSizeClass.expanded,
        DesktopContentKind.settings,
      ),
      const EdgeInsets.symmetric(horizontal: 24),
    );
  });
}
