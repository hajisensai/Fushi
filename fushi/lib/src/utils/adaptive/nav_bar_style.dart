/// 手机底栏形态（用户偏好 `nav_bar_style`，2026-10-15 原型，见 PR #2190）。
enum AdaptiveNavBarStyle {
  /// 平铺：放得下全部平铺，放不下的收进最右的「更多」（原有形态）。
  flat('flat'),

  // 以下两种是「放不下的入口怎么露出来」的交互原型（2026-10-23，设计稿见
  // fushi/build/bottom_nav_design/divergent.html），只接 MD3 悬浮胶囊；
  // Apple 胶囊遇到它们按分页滑动画。实现见 `nav_overflow/`。
  //
  // 「分页滑动」（pager）与「圆柱滚筒」（drum）两种 MD3 样式已于 2026-10-25
  // 删除（用户：相机模式条吸收滚筒的宽视野与底标后，两者都砍掉）；落过库的
  // 'pager' / 'drum' 经 [fromPref] 回落出厂默认。

  /// 拇指转盘：末格是刻度旋钮，按住升起半圆转盘，转到顶端指针松手跳转。
  dial('dial'),

  /// 相机模式条：全部目的地铺满胶囊宽度（首尾贴边不留白），当前项是专属
  /// 多边形 + 底标，放不下时跟手横拨、两端渐隐提示还有更多。
  modeStrip('mode_strip');

  /// 是否是 `nav_overflow/` 里的交互原型之一（只 MD3 悬浮胶囊画）。
  bool get isOverflowVariant => switch (this) {
    flat => false,
    dial || modeStrip => true,
  };

  const AdaptiveNavBarStyle(this.prefValue);

  /// 出厂默认：相机模式条（2026-10-23 用户拍板「相机模式条作为默认样式」；
  /// 此前 2026-10-16 起是分页滑动）。Apple 胶囊没接原型，按分页滑动画。
  ///
  /// 偏好是「缺省即默认」：从没写过 `nav_bar_style` 的安装（含升级上来的
  /// 老用户）随之变成相机模式条；显式选过的已落库，保持原选择。
  /// 读取端（[fromPref]）与设置行的 `defaultValue` 一律取这里，不各写一份。
  static const AdaptiveNavBarStyle defaultStyle = modeStrip;

  /// 落库的字符串（冻结，改名不改它）。
  final String prefValue;

  /// 没写过（空串）与未知值（含已删掉的 pager / drum，以及原型期一度存在的
  /// launcher / launcher_pager / shelf / fan）一律回落出厂默认 [defaultStyle]。
  static AdaptiveNavBarStyle fromPref(String value) {
    for (final AdaptiveNavBarStyle style in values) {
      if (style.prefValue == value) return style;
    }
    return defaultStyle;
  }
}
