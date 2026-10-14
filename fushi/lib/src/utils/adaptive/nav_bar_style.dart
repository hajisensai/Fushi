/// 手机底栏形态（用户偏好 `nav_bar_style`，2026-10-15 原型，见 PR #2190）。
///
/// 除 [flat] 外三种形态都把查词收进胶囊（不再拆成 FAB / 圆钮），所有目的地
/// 同级排列；横滑切模块的序列也随之带上查词（见 `homeSwipeTabs`）。
enum AdaptiveNavBarStyle {
  /// 平铺：放得下全部平铺，放不下的收进最右的「更多」（原有形态）。
  flat('flat'),

  /// 中央展开：左右各两项常驻，中间「+」点开 / 按住划过去弧形弹出其余。
  launcher('launcher'),

  /// 分页滑动：每页 5 个，在底栏上左右滑翻页，小圆点提示页数。
  pager('pager'),

  /// 中央展开 + 翻页：「+」固定在中间，两侧 4 格可横滑翻到下一组；「+」里是
  /// 当前页之外的全部目的地。
  launcherPager('launcher_pager');

  const AdaptiveNavBarStyle(this.prefValue);

  /// 落库的字符串（冻结，改名不改它）。
  final String prefValue;

  /// 查词是否进胶囊（除平铺外都进）。
  bool get lookupInBar => this != flat;

  /// 底栏横滑是翻页（此时不挂「按住横拖」拖选）。
  bool get pages => this == pager || this == launcherPager;

  /// 中央有「+」。
  bool get hasLauncher => this == launcher || this == launcherPager;

  static AdaptiveNavBarStyle fromPref(String value) {
    for (final AdaptiveNavBarStyle style in values) {
      if (style.prefValue == value) return style;
    }
    return flat;
  }
}
