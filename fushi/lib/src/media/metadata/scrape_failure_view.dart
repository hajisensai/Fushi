import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 书籍、游戏等交互式元数据刮削的统一失败态展示件。
///
/// 为什么把技术详情摆到界面上（BUG-1219）：底层异常的 `toString()` 本身就是完整因果
/// 链（如 `BookScrapeException: Bangumi search request failed: ClientException with
/// SocketException: Failed host lookup: 'api.bgm.tv'`，或 `Bangumi search HTTP 502`），
/// 此前只落错误日志、界面只留一句「没能从封面源取到有效响应」——用户无从区分 DNS 不
/// 通、代理没生效、被限流还是对面 5xx，只能换页翻日志。一句可行动的话回答「我该做
/// 什么」，完整详情回答「到底怎么了」，两者都留在出错的地方。
///
/// 外观（M3E，2026-10-06）：与全应用错误态同一个 [FushiPlaceholderMessage]
/// （tone: error——errorContainer 色块图标弹入 + 标题 / 原因淡入上浮），下面是
/// 「重试」（调用方给了 [onRetry] 才出现）与「显示详情」按钮组，详情展开成一块
/// tonal 卡并带「复制错误」。Apple 设计系统 / 墨水屏由共享组件自行降级。
///
/// 差异只在标题文案与原因折叠规则，均由调用方传入。
class ScrapeFailureView extends StatefulWidget {
  const ScrapeFailureView({
    super.key,
    required this.title,
    required this.reason,
    required this.detail,
    this.onRetry,
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

  /// 重新执行失败的那次请求。null = 不出「重试」按钮（调用方另有重试入口，
  /// 例如搜索框旁的「搜索」键）。
  final VoidCallback? onRetry;

  @override
  State<ScrapeFailureView> createState() => _ScrapeFailureViewState();
}

class _ScrapeFailureViewState extends State<ScrapeFailureView> {
  /// 详情默认**折叠**：用户要的是「能看到完整报错」，不是「每次都先撞一段英文」。
  /// 折叠 + 一键展开两者都满足；普通断网场景仍然只看到两句人话。
  bool _detailShown = false;

  @override
  Widget build(BuildContext context) {
    // 结果区高度由弹窗决定，可能比本列矮（窄窗/小屏）：外层滚动兜底，避免
    // RenderFlex overflow 把失败态本身变成一条黄黑警告。
    return Center(
      child: SingleChildScrollView(
        child: FushiPlaceholderMessage(
          tone: FushiPlaceholderTone.error,
          icon: FushiIcons.error,
          message: widget.title,
          detail: widget.reason,
          detailMaxLines: null,
          action: _buildActions(context),
        ),
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiMotionScheme motion = context.fushiMotion;
    final double gap = tokens.spacing.gap;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Wrap(
          alignment: WrapAlignment.center,
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            if (widget.onRetry case final VoidCallback retry)
              FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('scrape_failure_retry'),
                onPressed: retry,
                icon: const FushiIcon(FushiIcons.refresh, size: 18),
                label: Text(t.retry),
              ),
            // 展开开关：默认折叠，一键看全。图标随状态翻转，文案两态各自 i18n。
            FushiTextButton.icon(
              key: const ValueKey<String>('scrape_failure_detail_toggle'),
              icon: FushiIcon(
                _detailShown ? FushiIcons.expandLess : FushiIcons.expandMore,
                size: 18,
              ),
              label: Text(_detailShown
                  ? t.scrape_failure_detail_hide
                  : t.scrape_failure_detail_show),
              onPressed: () => setState(() => _detailShown = !_detailShown),
            ),
          ],
        ),
        AnimatedSize(
          duration: motion.spatialDefault.duration,
          curve: motion.spatialDefault.curve,
          alignment: Alignment.topCenter,
          child: !_detailShown
              ? const SizedBox(width: double.infinity)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox(height: tokens.spacing.rowVertical),
                    // 详情块限高 + 内部滚动：长异常链（含底层 SocketException 全文）
                    // 不把「复制」按钮推出可视区，用户永远够得着上报入口。
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 132),
                      child: SizedBox(
                        width: double.infinity,
                        child: FushiCard(
                          tone: FushiCardTone.error,
                          padding: EdgeInsets.symmetric(
                            horizontal: tokens.spacing.rowVertical,
                            vertical: gap,
                          ),
                          borderRadius: FushiM3eShape.smallRadius,
                          child: SingleChildScrollView(
                            child: SelectableText(
                              widget.detail,
                              // error 饱和卡：textTheme 自带页面前景，显式跟
                              // 卡片配对前景（HBK-AUDIT-022）。
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: fushiCardToneColors(
                                  context,
                                  FushiCardTone.error,
                                )?.onContainer,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: gap),
                    FushiTextButton.icon(
                      icon: const FushiIcon(FushiIcons.copy, size: 18),
                      label: Text(t.copy_error),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: widget.detail));
                        FushiToast.show(
                          msg: t.error_copied,
                          severity: ToastSeverity.success,
                        );
                      },
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
