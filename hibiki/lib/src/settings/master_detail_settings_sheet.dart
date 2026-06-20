import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:hibiki/utils.dart';

/// 设置子页（push 进去的二级页）顶部的返回页头：左侧返回按钮 + 标题。
///
/// 平台自适应：Cupertino 用 [CupertinoButton] + `chevron_back`，其余平台用共享的
/// [HibikiIconButton] + `arrow_back`，标题用主题排版（不写死字号）。
///
/// 由阅读器（[ReaderQuickSettingsSheet]）与视频（[VideoQuickSettingsSheet]）的窄窗
/// push 子页共用——两边原本各有一份逐字符相同的私有 `_InBookSettingsHeader` /
/// `_VideoSettingsHeader`，抽到此处消除重复（TODO-583，零行为变化）。
class HibikiSettingsSubPageHeader extends StatelessWidget {
  const HibikiSettingsSubPageHeader({
    required this.title,
    required this.onBack,
    super.key,
  });

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final TextStyle? titleStyle = cupertino
        ? CupertinoTheme.of(context).textTheme.navTitleTextStyle
        : Theme.of(context).textTheme.titleMedium;
    final IconData icon =
        cupertino ? CupertinoIcons.chevron_back : Icons.arrow_back;

    return Row(
      children: <Widget>[
        if (cupertino)
          Semantics(
            button: true,
            label: t.back,
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              minSize: 36,
              onPressed: onBack,
              child: Icon(icon, size: 22),
            ),
          )
        else
          HibikiIconButton(
            icon: icon,
            tooltip: t.back,
            padding: EdgeInsets.all(tokens.spacing.gap / 2),
            onTap: onBack,
          ),
        SizedBox(width: tokens.spacing.gap / 2),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        ),
      ],
    );
  }
}

/// 「快速设置」类弹窗的 master-detail 外壳骨架：阅读器与视频两张设置 sheet 的
/// `build` 方法原本是逐字构造相同的外壳（[PopScope] + [HibikiModalSheetFrame] +
/// [LayoutBuilder] 按宽高判定宽/窄 + 窄窗 [SingleChildScrollView] + [AnimatedSize]），
/// 抽到此处共享（TODO-583，零行为变化）。
///
/// **范围收窄**：只抽外壳骨架，宽窗内部布局两边发散（阅读器是左右 master-detail
/// [MaterialSupportingPaneLayout]，视频是顶部横向分类条 + 下方详情），故宽窗内容由调
/// 用方经 [wideBuilder] 提供；窄窗主/子页内容由 [narrowChild] 提供，padding 也由调用方
/// 经 [narrowPadding] 算（阅读器 `page + gap/2`、视频 `page + gap`，**不可统一**），
/// 复用主/子页切换 Element 的 [narrowKey] 也由调用方决定（阅读器带 key、视频不带）。
///
/// 宽窗判定使用确定性几何判据（窗口宽且高都 >= 共享阈值常量
/// `kHibikiSettingsWideThreshold` 560 × `kHibikiSettingsWideMinHeight` 440），不测内容
/// 高度——同设备同尺寸下书籍/视频表现一致，高度不足时直接 push 而非出滚动条。判定结果
/// 经 [onWideChanged] 回写给调用方的 `_isWide` State 字段，供 [PopScope.canPop] 在下一
/// 帧读取（宽窗下返回键直接关弹窗，不卡在「返回上一级」）。
class HibikiMasterDetailSettingsSheet extends StatelessWidget {
  const HibikiMasterDetailSettingsSheet({
    required this.subPageActive,
    required this.onPopToParent,
    required this.isWide,
    required this.onWideChanged,
    required this.wideBuilder,
    required this.narrowKey,
    required this.narrowPadding,
    required this.narrowChild,
    this.maxHeightFactor = 0.80,
    super.key,
  });

  /// 当前是否处在二级子页（= 调用方的 `_subPage != null`）。窄窗 push 语义下决定
  /// 返回键是先回主页（[onPopToParent]）还是直接关弹窗。
  final bool subPageActive;

  /// 窄窗子页态按返回键时回退到主页（调用方 `setState(() => _subPage = null)`）。
  final VoidCallback onPopToParent;

  /// 调用方持有的最近一次宽窗判定（`_isWide` State 字段）。[PopScope.canPop] 读它。
  final bool isWide;

  /// [LayoutBuilder] 每次按几何判定出的宽窗结果回写给调用方（更新 `_isWide`）。
  final ValueChanged<bool> onWideChanged;

  /// sheet 高度上限因子（两张 sheet 均为 0.80）。
  final double maxHeightFactor;

  /// 宽窗内容（两边发散）：在有界高度下构造各自的 master-detail / 顶栏+详情。
  final Widget Function(BuildContext context, BoxConstraints constraints)
      wideBuilder;

  /// 窄窗外层 [SingleChildScrollView] 的 key（阅读器 `ValueKey(_subPage ?? 'main')`、
  /// 视频 `null`），保留各自的主/子页切换 Element 复用语义。
  final Key? Function() narrowKey;

  /// 窄窗 padding（阅读器 `page + gap/2`、视频 `page + gap`，含底部键盘 inset）。
  final EdgeInsets Function(BuildContext context, BoxConstraints constraints)
      narrowPadding;

  /// 窄窗 [AnimatedSize] 的内容（调用方按 [subPageActive] 选 main / sub 页）。
  final Widget Function(BuildContext context, BoxConstraints constraints)
      narrowChild;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 宽窗 master-detail：选中态始终有值，返回键应直接关弹窗而非退回「未选中」；
      // 窄窗 push 时保留原「先回主页」语义。
      canPop: !subPageActive || isWide,
      onPopInvokedWithResult: (bool didPop, _) {
        if (!didPop) {
          onPopToParent();
        }
      },
      child: HibikiModalSheetFrame(
        maxHeightFactor: maxHeightFactor,
        // master-detail 绝不能套外层滚动：外层 SingleChildScrollView 会给 supporting
        // pane 布局「无界高度」→ Row(stretch) 拿 h=Infinity（debug 崩 / release 两 pane
        // 一块滚、左不固定）。frame 不滚，滚动策略下放到 body 按宽/窄各自决定。
        scrollable: false,
        body: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 确定性几何判据：宽且高都够才进宽窗 master-detail，否则窄窗 push。
            final bool wide =
                constraints.maxWidth >= kHibikiSettingsWideThreshold &&
                    constraints.maxHeight >= kHibikiSettingsWideMinHeight;
            onWideChanged(wide);
            if (wide) {
              return wideBuilder(context, constraints);
            }
            // 窄窗（含全部手机 bottom sheet）：维持现有 push 行为。body 自带滚动视口
            // （padding 含键盘 inset 也随内容一起滚动）。
            return SingleChildScrollView(
              key: narrowKey(),
              padding: narrowPadding(context, constraints),
              child: AnimatedSize(
                duration: const Duration(milliseconds: 200),
                alignment: Alignment.topCenter,
                child: narrowChild(context, constraints),
              ),
            );
          },
        ),
      ),
    );
  }
}
