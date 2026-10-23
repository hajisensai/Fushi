import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 加载失败页：壳在 `tab.error != null` 时把它盖在网页上（不透明底，盖住平台
/// WebView 自带的错误页）。图标 / 标题 / 说明 / 重试；断网换「检查网络」文案。
///
/// 动效与两套设计系统由 [FushiPlaceholderMessage] 负责（错误色块弹入、文案淡入；
/// Apple 走 ContentUnavailableView 口径）。
class WebBrowserErrorView extends StatelessWidget {
  const WebBrowserErrorView({
    required this.error,
    required this.onRetry,
    super.key,
  });

  final WebBrowserLoadError error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final int? code = error.statusCode;
    final String title = error.offline
        ? t.web_browser_error_offline_title
        : t.web_browser_error_title;
    final String body = error.offline
        ? t.web_browser_error_offline_body
        : code != null
        ? t.web_browser_error_http_body(code: code)
        : error.description;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: FushiPlaceholderMessage(
            key: const ValueKey<String>('web-browser-error'),
            icon: error.offline ? FushiIcons.cloudOff : FushiIcons.error,
            tone: FushiPlaceholderTone.error,
            message: title,
            details: <String>[
              body,
              if (error.url.host.isNotEmpty) error.url.host,
            ],
            action: FushiFilledButton.tonalIcon(
              key: const ValueKey<String>('web-browser-error-retry'),
              onPressed: onRetry,
              icon: const FushiIcon(FushiIcons.refresh),
              label: Text(t.retry),
            ),
          ),
        ),
      ),
    );
  }
}
