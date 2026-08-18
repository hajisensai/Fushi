import 'package:flutter/material.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

/// 库页顶栏分段导航的统一每段最小宽（逻辑像素）。
///
/// TODO-2937：书架 / 漫画 / 视频 / 游戏四个模块的顶栏分段各自按本页最长文案取
/// 宽，段数与字数不同导致四页的分段块宽窄不一、观感割裂。统一下限后，常规中文
/// 文案（≤5 字）在四页渲染成等宽块；更长文案（其他语言）仍按该条最长段等宽放
/// 大，放不下时先退自然宽、再退横向滚动（见 [FushiSegmentedStrip.minSegmentWidth]），
/// 手机窄屏行为不变。
/// 取值 = 5 个 CJK 字的估宽（5 × 14）+ 每段 chrome（28）。定值时最长中文顶栏
/// 文案是 5 字「捕获工作台」；该页签后改短为 3 字「工作台」（TODO-2937 拍板），
/// 保留 5 字下限维持改名前的四页等宽观感，并为 ≤5 字的中文文案留余量。
const double kLibrarySectionTabMinSegmentWidth = 98.0;

/// [LibrarySectionTabs] 的一段：值 + 用户可读标签。
class LibrarySectionTab<T> {
  const LibrarySectionTab({required this.value, required this.label});

  final T value;
  final String label;
}

/// 库页（书架 / 漫画 / 视频 / 游戏）顶栏共用的分段导航。
///
/// 收敛点（TODO-2937）：此前 [MediaLibraryShell]、`VideoLibraryShell`、
/// `GameSectionTabs` 三处各自拼一遍「[FushiAdjustableSegmented] +
/// [FushiSegmentedStrip]」，样式细节（每段宽度、focusId 约定）随调用点漂移。
/// 本组件把这对组合与顶栏统一样式收成唯一实现：
/// - 单个焦点停靠点，focusId 恒为 `<focusIdPrefix>-sections`，左右方向键原地切段；
/// - 每段宽度下限 [kLibrarySectionTabMinSegmentWidth]，四个模块顶栏观感一致。
class LibrarySectionTabs<T extends Object> extends StatelessWidget {
  const LibrarySectionTabs({
    required this.tabs,
    required this.selected,
    required this.onChanged,
    required this.focusIdPrefix,
    super.key,
  });

  final List<LibrarySectionTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onChanged;

  /// focusId 前缀（如 `game-library-tab`），焦点停靠点 id 为 `<prefix>-sections`。
  final String focusIdPrefix;

  @override
  Widget build(BuildContext context) {
    return FushiAdjustableSegmented<T>(
      values: <T>[for (final LibrarySectionTab<T> tab in tabs) tab.value],
      selected: selected,
      onChanged: onChanged,
      focusIdPrefix: focusIdPrefix,
      focusId: FushiFocusId('$focusIdPrefix-sections'),
      child: FushiSegmentedStrip<T>(
        segments: <ButtonSegment<T>>[
          for (final LibrarySectionTab<T> tab in tabs)
            ButtonSegment<T>(value: tab.value, label: Text(tab.label)),
        ],
        selected: selected,
        onChanged: onChanged,
        minSegmentWidth: kLibrarySectionTabMinSegmentWidth,
      ),
    );
  }
}
