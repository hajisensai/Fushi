import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiIconButtonControl;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 返回条本身那一行的高度（不含顶部让位）。
const double kWebVideoReturnBarRowHeight = 52;

/// 返回条在页面顶端占的总高度：先让出页面顶部 padding（桌面自绘标题行 / 状态栏），
/// 再放 [kWebVideoReturnBarRowHeight] 那一行。站点 WebView 从这个高度往下画。
///
/// 播放器页是沉浸页（`FushiTitleBarColorScope`）：标题行浮在页面顶端、不占版面，
/// 页面靠 `MediaQuery.padding.top` 自己让开（`FushiDesktopTitleBar` 交下来的就是
/// 标题行高度）。不让的话「在浏览器中打开」正好压在窗口最小化 / 最大化 / 关闭
/// 三键底下（反馈 -TwLAKqRZx）。
double webVideoReturnBarExtent(BuildContext context) =>
    MediaQuery.paddingOf(context).top + kWebVideoReturnBarRowHeight;

/// 播放器层露出站点页面时（观看页还没有视频 / 站点弹层打断）顶部的细返回条：返回、标题、
/// 「在浏览器中打开」。底色铺到窗口顶端（标题行浮出时盖在同色底上），按钮行排在顶部
/// padding 下面。没有地址栏 / 前进 / 刷新 / 档位切换——浏览只在 app 内浏览器里
/// （`docs/specs/2026-11-01-one-browser.md`）。
class WebVideoReturnBar extends StatelessWidget {
  const WebVideoReturnBar({
    required this.title,
    required this.onBack,
    required this.onOpenInBrowser,
    super.key,
  });

  final ValueListenable<String?> title;
  final VoidCallback onBack;

  /// 为 null 时按钮禁用（会话还没建好）。
  final VoidCallback? onOpenInBrowser;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double top = MediaQuery.paddingOf(context).top;
    return ColoredBox(
      key: const ValueKey<String>('video-web-return-bar'),
      color: theme.colorScheme.surface,
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, top + 6, 8, 6),
        child: Row(
          children: <Widget>[
            FushiIconButtonControl(
              key: const ValueKey<String>('video-web-return-back'),
              tooltip: t.back,
              icon: const FushiIcon(FushiIcons.back),
              onPressed: onBack,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ValueListenableBuilder<String?>(
                valueListenable: title,
                builder: (BuildContext _, String? value, Widget? __) => Text(
                  value ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
            const SizedBox(width: 4),
            FushiIconButtonControl(
              key: const ValueKey<String>('video-web-open-in-browser'),
              tooltip: t.web_video_open_in_browser,
              icon: const FushiIcon(FushiIcons.globe),
              onPressed: onOpenInBrowser,
            ),
          ],
        ),
      ),
    );
  }
}
