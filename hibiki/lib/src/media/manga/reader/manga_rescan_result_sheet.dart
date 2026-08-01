/// 框选识别的结果卡片：识别文本 + 来源标注 + 采纳入口。
///
/// 没有这张卡片，框选识别就是一次「看不见结果」的空转——用户既不知道认出了什么，
/// 也没有把结果用起来的入口。两个采纳动作：
/// - **查词**：把识别文本喂进既有词典管线（气泡即句子）。
/// - **回写本页**：落进 mokuro 格式的 `manga.json`，下次打开不重跑 OCR。
///
/// 本 widget 只做展示，动作经 `Navigator.pop(context, action)` 回传，不持任何回调
/// ——调用方用 `showModalBottomSheet<MangaRescanAction>` 包起来 await 结果即可。
library;

import 'package:flutter/material.dart';

import 'package:hibiki/i18n/strings.g.dart';

/// 结果卡片的采纳动作。
enum MangaRescanAction {
  /// 以识别文本查词。
  lookup,

  /// 把识别块回写进本书 manga.json 的对应页。
  writeBack,
}

/// 框选识别结果卡片（由调用方包进 `showModalBottomSheet`）。
class MangaRescanResultSheet extends StatelessWidget {
  const MangaRescanResultSheet({required this.text, super.key});

  /// 识别文本；为空表示本地模型没认出（手写体/装饰字体常见）。
  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasText = text.isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.document_scanner_outlined,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  t.manga_rescan_local_source,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (hasText)
              SelectableText(text, style: theme.textTheme.titleMedium)
            else
              Text(
                t.manga_rescan_empty,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  key: const ValueKey<String>('manga_rescan_lookup'),
                  onPressed: hasText
                      ? () => Navigator.pop(context, MangaRescanAction.lookup)
                      : null,
                  icon: const Icon(Icons.search),
                  label: Text(t.manga_rescan_lookup),
                ),
                OutlinedButton.icon(
                  key: const ValueKey<String>('manga_rescan_writeback'),
                  onPressed: hasText
                      ? () =>
                          Navigator.pop(context, MangaRescanAction.writeBack)
                      : null,
                  icon: const Icon(Icons.save_alt_outlined),
                  label: Text(t.manga_rescan_writeback),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
