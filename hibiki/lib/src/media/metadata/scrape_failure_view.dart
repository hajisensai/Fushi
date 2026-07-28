import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:hibiki/utils.dart';

/// 刮削失败态的统一展示件（视频「在线匹配海报」弹窗 / 书籍「在线匹配封面」弹窗共用）。
///
/// 为什么把技术详情摆到界面上（BUG-1219）：底层异常的 `toString()` 本身就是完整因果
/// 链（如 `ScrapeNetworkException: Bangumi search request failed: ClientException with
/// SocketException: Failed host lookup: 'api.bgm.tv'`，或 `Bangumi search HTTP 502`），
/// 此前只落错误日志、界面只留一句「没能从封面源取到有效响应」——用户无从区分 DNS 不
/// 通、代理没生效、被限流还是对面 5xx，只能换页翻日志。一句可行动的话回答「我该做
/// 什么」，完整详情回答「到底怎么了」，两者都留在出错的地方。
///
/// 两个弹窗共用一份而不是各写各的：它们此前是逐字重复的两段 Column，各改各的必然
/// 漂开。差异只在标题文案与原因折叠规则，都由调用方传入。
class ScrapeFailureView extends StatelessWidget {
  const ScrapeFailureView({
    super.key,
    required this.title,
    required this.reason,
    required this.detail,
  });

  /// 失败标题（各弹窗自己的 i18n 文案，如「搜索失败，点「搜索」可重试。」）。
  final String title;

  /// 一句用户可行动的原因（调用方按自身异常域折成网络/服务端两类）。
  final String reason;

  /// 完整技术详情：异常 `toString()`。英文、给排查与上报用，不做翻译。
  final String detail;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      // 结果区高度由弹窗决定，可能比本列矮（窄窗/小屏）：外层滚动兜底，避免
      // RenderFlex overflow 把失败态本身变成一条黄黑警告。
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, color: theme.colorScheme.error),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 4),
            Text(
              reason,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            // 详情块限高 + 内部滚动：长异常链（含底层 SocketException 全文）不把
            // 「复制」按钮推出可视区，用户永远够得着上报入口。
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 132),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    detail,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: Text(t.copy_error),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: detail));
                HibikiToast.show(msg: t.error_copied);
              },
            ),
          ],
        ),
      ),
    );
  }
}
