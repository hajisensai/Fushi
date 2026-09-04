import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';

/// BUG-2117：快捷键设置页的卡片顺序就是 [ShortcutScope.values] 的声明顺序
/// （页面直接遍历 `values`，没有第二份显示顺序表）。此前枚举按加入时间累加，
/// 页面就排成「阅读器 → 首页 → 全局 → 返回·退出 → 有声书 → …」。这里钉住
/// 「跨页面通用 → 各页面 → 输入设备 → 查词弹窗」的分组顺序：新增 scope 必须
/// 落进对应分组，而不是随手追加到末尾。
void main() {
  test('BUG-2117: ShortcutScope 声明顺序 = 通用 → 页面 → 设备 → 弹窗', () {
    expect(
      ShortcutScope.values,
      orderedEquals(const <ShortcutScope>[
        // 跨页面通用
        ShortcutScope.global,
        ShortcutScope.universal,
        ShortcutScope.globalExternal,
        // 各页面（首页 → 阅读器及其有声书 → 漫画 → 视频）
        ShortcutScope.home,
        ShortcutScope.reader,
        ShortcutScope.audiobook,
        ShortcutScope.manga,
        ShortcutScope.video,
        // 输入设备
        ShortcutScope.gamepad,
        // 查词弹窗
        ShortcutScope.dictionaryPopup,
      ]),
    );
  });
}
