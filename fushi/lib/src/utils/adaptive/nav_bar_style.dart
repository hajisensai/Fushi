/// 手机底栏形态（用户偏好 `nav_bar_style`，2026-10-15 原型，见 PR #2190）。
enum AdaptiveNavBarStyle {
  /// 平铺：放得下全部平铺，放不下的收进最右的「更多」（原有形态）。
  flat('flat'),

  /// 分页滑动：胶囊里每页 5 个，在底栏上左右滑翻页；按住约 0.3 秒拖选（可拖到
  /// 边缘翻页）。查词仍是右下角固定的 FAB / 圆钮，不进分页（2026-10-17 用户
  /// 「底部左边要分页右下角是查词」）。MD3 悬浮胶囊与 Apple 胶囊都支持。
  pager('pager');

  const AdaptiveNavBarStyle(this.prefValue);

  /// 出厂默认：分页滑动（2026-10-16 用户拍板「你改成默认分页滑动」）。
  ///
  /// 偏好是「缺省即默认」：从没写过 `nav_bar_style` 的安装（含升级上来的
  /// 老用户）随之变成分页；显式选过「平铺」的已落库 `flat`，保持平铺。
  /// 读取端（[fromPref]）与设置行的 `defaultValue` 一律取这里，不各写一份。
  static const AdaptiveNavBarStyle defaultStyle = pager;

  /// 落库的字符串（冻结，改名不改它）。
  final String prefValue;

  /// 没写过（空串）与未知值（含原型期一度存在、已删掉的 launcher /
  /// launcher_pager）一律回落出厂默认 [defaultStyle]。
  static AdaptiveNavBarStyle fromPref(String value) {
    for (final AdaptiveNavBarStyle style in values) {
      if (style.prefValue == value) return style;
    }
    return defaultStyle;
  }
}
