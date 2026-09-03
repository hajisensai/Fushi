import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart' show FushiFocusId;
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/utils/components/current_app_icon.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/misc/official_links.dart';

/// 宽屏主导航 rail 顶部的品牌位（`adaptiveNavRail` 的 leading）。应用图标直接占
/// rail 顶部固定区域，不叠加卡片底色、描边或额外内边距；下面的目的地仍在剩余空间
/// 内独立居中。
///
/// 品牌位同时是官网入口：点击在系统浏览器里打开 [kOfficialWebsiteUrl]，与
/// 「设置 · 通用 · 官网」调同一个 [openOfficialWebsite]。
///
/// rail 的每个目的地都是独立焦点目标，品牌位也必须是——否则键盘 Tab / 手柄永远走
/// 不到它，只有鼠标能点。手柄 A / 回车走 [ActivateIntent]：在主焦点的 context 派发
/// 后向上走 Actions 链，[InkWell] 自己就把它映射到 `onTap`（`canRequestFocus:
/// false` 不影响这条映射，焦点节点属于 [FushiFocusTarget]），所以这里不再叠一层
/// 重复的 Actions；换成 `GestureDetector` 之类没有该映射的控件时，
/// `test/widgets/nav_rail_brand_button_test.dart` 的键盘激活用例会红。
/// `autoHome: false` 让被动 auto-home 仍落到第一个目的地而不是品牌位，只有显式
/// 方向导航才停在这里。
class NavRailBrandButton extends StatelessWidget {
  const NavRailBrandButton({super.key});

  /// 品牌位的焦点 id。rail 目的地用 `nav-rail-<序号>`，这里是固定后缀，两者不撞。
  static const FushiFocusId focusId = FushiFocusId('nav-rail-logo');

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 8 + 64 + 8 正好等于 kAdaptiveNavRailWidth（80），零余量。rail 外面是
    // SafeArea(right: false)，left inset 一旦大于 0（带刘海的平板/折叠屏横屏）
    // 可用宽度就不足 80，写死的 64 会溢出。用 FittedBox 兜住：有地方时仍是 64，
    // 挤了就等比缩小，而不是画到框外。
    return Padding(
      padding: EdgeInsets.all(tokens.spacing.gap),
      child: Tooltip(
        message: t.options_website,
        child: InkWell(
          onTap: () => unawaited(openOfficialWebsite()),
          canRequestFocus: false,
          borderRadius: tokens.radii.controlRadius,
          child: Semantics(
            button: true,
            label: 'Fushi',
            child: FushiFocusTarget(
              id: focusId,
              autoHome: false,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox.square(
                  dimension: 64,
                  child: ClipRRect(
                    borderRadius: tokens.radii.controlRadius,
                    child: const CurrentAppIcon(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
