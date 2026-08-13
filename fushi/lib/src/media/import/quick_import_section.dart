import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import 'package:fushi/utils.dart';

/// 「快速导入」区的一个入口按钮声明。
class QuickImportAction {
  const QuickImportAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onTap;
  final bool enabled;
}

/// 库页「导入」视图顶部的快速导入区：区标题 + 一排入口按钮。
///
/// 四个媒体域（书 / 漫画 / 视频 / 游戏）同构复用——版式完全一致，只是按钮多少
/// 不同（各域只声明自己真正有的入口，与 `MediaLibraryShell`「不放空壳 tab」同一
/// 哲学）。单件导入入口从各库页页头 / FAB 收敛到这里后，「要进内容 → 去导入」
/// 是全 app 唯一心智模型；批量常驻入口（扫描根）由同一页下方的来源列表承接，
/// 两种入库方式在同一屏幕上下文里自然互相解释。
class QuickImportSection extends StatelessWidget {
  const QuickImportSection({required this.actions, super.key});

  final List<QuickImportAction> actions;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(t.quick_import_title, style: theme.textTheme.titleLarge),
        SizedBox(height: tokens.spacing.gap),
        Wrap(
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            for (final QuickImportAction action in actions)
              FilledButton.tonalIcon(
                onPressed:
                    action.enabled ? () => unawaited(action.onTap()) : null,
                icon: Icon(action.icon, size: 18),
                label: Text(action.label),
              ),
          ],
        ),
      ],
    );
  }
}
