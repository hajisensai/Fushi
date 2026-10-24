import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 失败页的标题 / 正文 / 图标（按 [WebBrowserLoadError.kind] 取本地化文案）。
typedef WebBrowserErrorCopy = ({String title, String body, IconData icon});

/// [error] → 失败页文案。HTTP 错误按状态码；网络层错误按类别。引擎原文
/// （[WebBrowserLoadError.description]）**不**当正文，只进折叠的详细信息。
WebBrowserErrorCopy webBrowserErrorCopyOf(WebBrowserLoadError error) {
  final int? code = error.statusCode;
  if (code != null) {
    return (
      title: t.web_browser_error_title,
      body: t.web_browser_error_http_body(code: code),
      icon: FushiIcons.error,
    );
  }
  return switch (error.kind) {
    WebBrowserLoadErrorKind.offline => (
      title: t.web_browser_error_offline_title,
      body: t.web_browser_error_offline_body,
      icon: FushiIcons.cloudOff,
    ),
    WebBrowserLoadErrorKind.dnsFailed => (
      title: t.web_browser_error_dns_title,
      body: t.web_browser_error_dns_body,
      icon: FushiIcons.searchOff,
    ),
    WebBrowserLoadErrorKind.connectionFailed => (
      title: t.web_browser_error_connection_title,
      body: t.web_browser_error_connection_body,
      icon: FushiIcons.linkOff,
    ),
    WebBrowserLoadErrorKind.timedOut => (
      title: t.web_browser_error_timeout_title,
      body: t.web_browser_error_timeout_body,
      icon: FushiIcons.timerOff,
    ),
    WebBrowserLoadErrorKind.certificate => (
      title: t.web_browser_error_certificate_title,
      body: t.web_browser_error_certificate_body,
      icon: FushiIcons.lock,
    ),
    WebBrowserLoadErrorKind.badResponse => (
      title: t.web_browser_error_response_title,
      body: t.web_browser_error_response_body,
      icon: FushiIcons.error,
    ),
    WebBrowserLoadErrorKind.tooManyRedirects => (
      title: t.web_browser_error_redirect_title,
      body: t.web_browser_error_redirect_body,
      icon: FushiIcons.error,
    ),
    WebBrowserLoadErrorKind.generic => (
      title: t.web_browser_error_title,
      body: t.web_browser_error_generic_body,
      icon: FushiIcons.error,
    ),
  };
}

/// 加载失败页：壳在 `tab.error != null` 时把它盖在网页上（不透明底，盖住平台
/// WebView 自带的错误页）。图标 / 标题 / 本地化说明 / 重试；引擎原文收在「详细
/// 信息」里，默认折叠。
///
/// 动效与两套设计系统由 [FushiPlaceholderMessage] 负责（错误色块弹入、文案淡入；
/// Apple 走 ContentUnavailableView 口径）；详细信息的展开收起走 [AnimatedSize]，
/// 时长取 [fushiMotionDuration]（减弱动态效果 / 墨水屏归零）。
class WebBrowserErrorView extends StatefulWidget {
  const WebBrowserErrorView({
    required this.error,
    required this.onRetry,
    super.key,
  });

  final WebBrowserLoadError error;
  final VoidCallback onRetry;

  @override
  State<WebBrowserErrorView> createState() => _WebBrowserErrorViewState();
}

class _WebBrowserErrorViewState extends State<WebBrowserErrorView> {
  bool _detailsShown = false;

  @override
  void didUpdateWidget(WebBrowserErrorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.error, widget.error)) _detailsShown = false;
  }

  @override
  Widget build(BuildContext context) {
    final WebBrowserLoadError error = widget.error;
    final WebBrowserErrorCopy copy = webBrowserErrorCopyOf(error);
    final ThemeData theme = Theme.of(context);
    final String raw = error.description.trim();
    final bool hasDetails = raw.isNotEmpty && error.statusCode == null;
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: FushiPlaceholderMessage(
            key: const ValueKey<String>('web-browser-error'),
            icon: copy.icon,
            tone: FushiPlaceholderTone.error,
            message: copy.title,
            details: <String>[
              copy.body,
              if (error.url.host.isNotEmpty) error.url.host,
            ],
            action: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FushiFilledButton.tonalIcon(
                  key: const ValueKey<String>('web-browser-error-retry'),
                  onPressed: widget.onRetry,
                  icon: const FushiIcon(FushiIcons.refresh),
                  label: Text(t.retry),
                ),
                if (hasDetails) ...<Widget>[
                  const SizedBox(height: 8),
                  FushiTextButton(
                    key: const ValueKey<String>('web-browser-error-details'),
                    onPressed: () =>
                        setState(() => _detailsShown = !_detailsShown),
                    child: Text(
                      _detailsShown
                          ? t.web_browser_error_details_hide
                          : t.web_browser_error_details_show,
                    ),
                  ),
                  FushiAnimatedSize(
                    duration: fushiMotionDuration(context, FushiMotion.short),
                    curve: FushiMotion.standard,
                    alignment: Alignment.topCenter,
                    child: _detailsShown
                        ? ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 420),
                            child: SelectableText(
                              raw,
                              key: const ValueKey<String>(
                                'web-browser-error-raw',
                              ),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
