import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fushi/utils.dart';

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
class ScrapeFailureView extends StatefulWidget {
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
  ///
  /// 🔴 凭据不得进这里：带 query 凭据的 URL 必须在**异常构造侧**就脱敏
  /// （见 `credential_redaction.dart`），不能指望本视图过滤——同一串文本还会流进
  /// 错误日志与日志上传，只堵界面等于没堵。
  final String detail;

  @override
  State<ScrapeFailureView> createState() => _ScrapeFailureViewState();
}

class _ScrapeFailureViewState extends State<ScrapeFailureView> {
  /// 详情默认**折叠**：用户要的是「能看到完整报错」，不是「每次都先撞一段英文」。
  /// 折叠 + 一键展开两者都满足；普通断网场景仍然只看到两句人话。
  bool _detailShown = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
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
              widget.title,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 4),
            Text(
              widget.reason,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            // 展开开关：默认折叠，一键看全。图标随状态翻转，文案两态各自 i18n。
            TextButton.icon(
              key: const ValueKey<String>('scrape_failure_detail_toggle'),
              icon: Icon(
                _detailShown ? Icons.expand_less : Icons.expand_more,
                size: 18,
              ),
              label: Text(_detailShown
                  ? t.scrape_failure_detail_hide
                  : t.scrape_failure_detail_show),
              onPressed: () => setState(() => _detailShown = !_detailShown),
            ),
            if (_detailShown) ...<Widget>[
              const SizedBox(height: 8),
              // 详情块限高 + 内部滚动：长异常链（含底层 SocketException 全文）不把
              // 「复制」按钮推出可视区，用户永远够得着上报入口。
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 132),
                child: SizedBox(
                  width: double.infinity,
                  child: HibikiCard(
                    padding: EdgeInsets.all(tokens.spacing.gap),
                    color: tokens.surfaces.overlay,
                    borderRadius: tokens.radii.cardRadius,
                    child: SingleChildScrollView(
                      child: SelectableText(
                        widget.detail,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: Text(t.copy_error),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: widget.detail));
                  HibikiToast.show(
                    msg: t.error_copied,
                    severity: ToastSeverity.success,
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
