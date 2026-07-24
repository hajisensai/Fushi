import 'package:flutter/material.dart';

import 'package:hibiki/utils.dart';

/// 补扫结果卡片可选动作（Navigator.pop 返回值）。
enum MangaRescanAction {
  /// 以识别文本为 searchTerm 打开词典弹窗。
  lookup,

  /// 把识别块回写进本书 manga.json 对应页并刷新覆盖层。
  writeBack,

  /// 用云端 VLM（Gemini）重试本框（仅开关开 + key 非空时显示）。
  cloudRetry,
}

/// 单框补扫结果底部卡片：识别文本 + 来源标注（本地/云端）+ 动作按钮。
///
/// 纯展示 widget（动作经 `Navigator.pop(context, action)` 回给调用方），
/// 「云端重试」显隐由 [showCloudRetry]（开关开 + key 非空）单点决定，可独立
/// widget 测试。空文本时查词/回写禁用（没有可用文本），云端重试仍可用——
/// 手写体本地认不出正是云端兜底的主场景。
class MangaRescanResultSheet extends StatelessWidget {
  const MangaRescanResultSheet({
    required this.text,
    required this.fromCloud,
    required this.showCloudRetry,
    super.key,
  });

  /// 识别文本（trim 后；可能为空）。
  final String text;

  /// 本结果是否来自云端（标注来源）。
  final bool fromCloud;

  /// 是否显示「云端重试」（开关开 + key 非空）。
  final bool showCloudRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasText = text.isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  fromCloud
                      ? Icons.cloud_outlined
                      : Icons.document_scanner_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    fromCloud
                        ? t.manga_rescan_cloud_source
                        : t.manga_rescan_local_source,
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: theme.colorScheme.primary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SelectableText(
              hasText ? text : t.manga_rescan_empty,
              style: hasText
                  ? theme.textTheme.titleMedium
                  : theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
                  icon: const Icon(Icons.search, size: 18),
                  label: Text(t.manga_rescan_lookup),
                ),
                OutlinedButton.icon(
                  key: const ValueKey<String>('manga_rescan_writeback'),
                  onPressed: hasText
                      ? () =>
                          Navigator.pop(context, MangaRescanAction.writeBack)
                      : null,
                  icon: const Icon(Icons.save_alt_outlined, size: 18),
                  label: Text(t.manga_rescan_writeback),
                ),
                if (showCloudRetry)
                  OutlinedButton.icon(
                    key: const ValueKey<String>('manga_rescan_cloud_retry'),
                    onPressed: () =>
                        Navigator.pop(context, MangaRescanAction.cloudRetry),
                    icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                    label: Text(t.manga_rescan_cloud_retry),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
