/// Apple（Cupertino，iOS 27 / macOS 27）内容区的段头：Apple Music「主页」/ App
/// Store / Apple TV 货架上方的 title2 粗体段名，可点时标题后带一枚 tertiaryLabel 的
/// ›（系统「查看全部」写法）。音乐推荐、游戏首页等 Apple 布局共用。
///
/// Apple 专用件：只在 `isGlassDesign` 为真时由各模块的 Apple 布局调用；M3E 的对应
/// 物是 `FushiSectionTitle`（MD3 titleLarge），两套由页面层按设计系统分派，本件
/// 不再自带 M3E 分支。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/apple/apple_text_style.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_focusable.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 段标题：可选副标题；[onOpen] 非 null 时标题后带 ›，整个标题是去「查看全部」的
/// 按钮（键盘 / 手柄可聚焦、Enter 激活）。[trailing] 是段头右侧的动作（如「播放」
/// 胶囊、「换一个」）。
///
/// [horizontalPadding] 是左右页边：null = 页面令牌的 `spacing.page`；外层列表已留
/// 页边时传 0。
class AppleSectionHeader extends StatelessWidget {
  const AppleSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onOpen,
    this.openKey,
    this.trailing,
    this.horizontalPadding,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onOpen;

  /// 标题按钮的 key（测试与焦点驱动用）。
  final Key? openKey;
  final Widget? trailing;
  final double? horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final FushiAppleColors c = appleColorsOf(context);
    final double k = m.scale;
    final double pad =
        horizontalPadding ?? FushiDesignTokens.of(context).spacing.page;
    final TextStyle titleStyle = appleTextStyle(
      context,
      size: (m.desktop ? 18 : 21) * k,
      weight: FontWeight.w700,
    );
    Widget titleRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        ),
        if (onOpen != null)
          FushiIcon(
            FushiIcons.chevronRight,
            size: (m.desktop ? 15 : 18) * k,
            color: c.tertiaryLabel,
          ),
      ],
    );
    if (onOpen case final VoidCallback open) {
      titleRow = FushiPressScale(
        child: FushiFocusable(
          key: openKey,
          onTap: open,
          borderRadius: BorderRadius.circular(8),
          child: titleRow,
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 24 * k, pad, 8 * k),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                titleRow,
                if (subtitle case final String s when s.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: 2 * k),
                    child: Text(
                      s,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: appleTextStyle(
                        context,
                        size: (m.desktop ? 12 : 13.5) * k,
                        color: c.secondaryLabel,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing case final Widget t) ...<Widget>[
            SizedBox(width: 8 * k),
            t,
          ],
        ],
      ),
    );
  }
}
