/// TTS 页面共用的宽屏双栏骨架：左侧固定宽卡片侧栏（可选底部常驻区）+ 右侧内容。
///
/// 制作台（步骤侧栏 + 步骤内容）与「朗读声音」（声音列表 + 声音详情）共用这一份，
/// 断点与侧栏宽度也只在这里写一次。窄形态各页自己决定（制作台是步骤选择片 + 底部
/// 固定条，朗读声音是列表 → 推详情页），本组件只管宽形态。
///
/// 纯 widget：不读 AppModel / Riverpod。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/utils.dart';

/// 切成「侧栏 + 内容」双栏的最小宽度（MD3 window size class 的 expanded 起点，
/// 与词典管理 / 快捷键浏览器同一断点）。
const double kTtsWideMinWidth = 840;

/// 双栏形态下侧栏的固定宽度。
const double kTtsSidebarWidth = 300;

/// 当前可用宽度是否走双栏。
bool ttsUsesWideLayout(double width) => width >= kTtsWideMinWidth;

/// 宽屏双栏：左侧 [sidebar]（自带滚动视图，填满侧栏卡片的剩余高度）+ 可选
/// [sidebarFooter]（分隔线下方常驻），右侧 [content]（自带滚动视图）。两栏各是
/// 一个焦点遍历组：Tab 先走完侧栏再进内容。
class TtsTwoPaneLayout extends StatelessWidget {
  const TtsTwoPaneLayout({
    required this.sidebar,
    required this.content,
    this.sidebarFooter,
    this.sidebarKey,
    super.key,
  });

  final Widget sidebar;
  final Widget content;
  final Widget? sidebarFooter;

  /// 侧栏卡片（固定宽度那一层）的 key，测试按它量宽度 / 找后代。
  final Key? sidebarKey;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.page,
            tokens.spacing.gap,
            0,
            tokens.spacing.page + bottomSafeInsetOf(context),
          ),
          child: SizedBox(
            width: kTtsSidebarWidth,
            child: DecoratedBox(
              key: sidebarKey,
              decoration: BoxDecoration(
                color: tokens.surfaces.card,
                borderRadius: FushiM3eShape.containerLargeRadius,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(child: FocusTraversalGroup(child: sidebar)),
                  if (sidebarFooter != null) ...<Widget>[
                    Divider(height: 1, color: tokens.surfaces.outline),
                    Padding(
                      padding: EdgeInsets.all(tokens.spacing.card),
                      child: FocusTraversalGroup(child: sidebarFooter!),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        Expanded(child: FocusTraversalGroup(child: content)),
      ],
    );
  }
}
