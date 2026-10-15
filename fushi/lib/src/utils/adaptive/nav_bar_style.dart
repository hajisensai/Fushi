/// 手机底栏形态（用户偏好 `nav_bar_style`，2026-10-15 原型，见 PR #2190）。
enum AdaptiveNavBarStyle {
  /// 平铺：放得下全部平铺，放不下的收进最右的「更多」（原有形态）。
  flat('flat'),

  /// 分页滑动：查词并进胶囊、所有目的地同级，每页 5 个，在底栏上左右滑翻页；
  /// 按住约 0.3 秒拖选（可拖到边缘翻页）。
  pager('pager');

  const AdaptiveNavBarStyle(this.prefValue);

  /// 落库的字符串（冻结，改名不改它）。
  final String prefValue;

  /// 查词是否进胶囊（不再拆成 FAB）；横滑切模块的序列也随之带上查词
  /// （见 `homeSwipeTabs`）。
  bool get lookupInBar => this == pager;

  /// 未知值（含原型期一度存在、已删掉的 launcher / launcher_pager）一律回落平铺。
  static AdaptiveNavBarStyle fromPref(String value) {
    for (final AdaptiveNavBarStyle style in values) {
      if (style.prefValue == value) return style;
    }
    return flat;
  }
}
