/// 首页「媒体库全景」小组件（[HomeWidgetKind.panorama]，2×2…6×4）：只是入口，不默认
/// 渲染 3D 预览（不建图集、不跑帧循环）。点块 / 「全屏」进可操作的 [PanoramaPage]；
/// 「分享动画」先选最后锁定的作品，再播 16 秒开场动画（只用于分享）。
///
/// 恒可用（不属于任何可关的模块）；旧可选面板「自动」档默认不显示（2026-10-30 用户
/// 「默认关闭媒体库全景」），所以迁移首个布局时只有钉成「显示」的用户才放上它。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';

import 'package:fushi/src/media/panorama/panorama_library.dart';
import 'package:fushi/src/media/panorama/panorama_page.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_widget_frame.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

class HomePanoramaPanel extends ConsumerWidget {
  const HomePanoramaPanel({
    super.key,
    required this.onOpen,
    this.poster = false,
  });

  final PanoramaOpenWork onOpen;

  /// true = 海报色块外观。
  final bool poster;

  void _openFullscreen(BuildContext context) {
    unawaited(
      Navigator.of(context).push<void>(
        PageRouteBuilder<void>(
          transitionDuration: fushiMotionDuration(context, FushiMotion.medium),
          reverseTransitionDuration: fushiMotionDuration(
            context,
            FushiMotion.longReverse,
          ),
          pageBuilder: (_, _, _) => PanoramaPage(onOpen: onOpen),
          transitionsBuilder: (_, Animation<double> a, _, Widget child) =>
              FadeTransition(
                opacity: CurvedAnimation(parent: a, curve: FushiMotion.enter),
                child: child,
              ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<PanoramaLibrary> library = ref.watch(
      panoramaLibraryProvider,
    );
    final PanoramaLibrary? ready = library.valueOrNull;
    final bool hasWorks = ready != null && !ready.isEmpty;
    final String status = library.hasError
        ? t.panorama_load_failed
        : library.isLoading
        ? t.panorama_loading
        : hasWorks
        ? t.home_panel_panorama_hint
        : t.panorama_empty;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints cell) => HomeWidgetFrame(
        key: const ValueKey<String>('home-panorama-panel'),
        tapKey: const ValueKey<String>('home-panorama-banner'),
        title: t.home_panel_panorama_title,
        icon: FushiIcons.blur,
        hueKey: HomeWidgetKind.panorama.id,
        poster: poster,
        dense: homeWidgetIsDense(cell.maxHeight),
        onTap: hasWorks ? () => _openFullscreen(context) : null,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final HomeWidgetStyle style = HomeWidgetStyle.of(context);
            final FushiTypography type = context.fushiType;
            final TextStyle statusStyle = type.bodyLarge.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.25,
              color: style.accent,
            );
            final double statusLine = homeWidgetLineHeight(
              context,
              statusStyle,
            );
            // 按钮行按剩余高度收内边距（最多默认 8）：半栏 1×1 的窄网格一行高格子
            // 只剩按钮行那么高，也不溢出。
            final double buttonPad = ((box.maxHeight - 20) / 2).clamp(2, 8);
            final double buttonRow = 20 + buttonPad * 2;
            final bool showStatus = box.maxHeight >= buttonRow + statusLine;
            // 半栏（1 列宽）只放两枚按钮，摘要那一行留给更宽的格子。
            final bool showSummary = homeWidgetIsWide(box.maxWidth);
            Widget action({
              required String id,
              required IconData icon,
              required String label,
              required VoidCallback? onPressed,
            }) => FushiIconButton(
              key: ValueKey<String>(id),
              icon: icon,
              tooltip: label,
              size: 20,
              padding: EdgeInsets.all(buttonPad),
              enabled: onPressed != null,
              enabledColor: style.foreground,
              onTap: onPressed,
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                if (showStatus)
                  Expanded(
                    child: Text(
                      status,
                      // 格子越高放越多行（按行高算，不溢出）。
                      maxLines: homeWidgetLinesFor(
                        box.maxHeight - buttonRow,
                        statusLine,
                        max: 6,
                      ),
                      overflow: TextOverflow.ellipsis,
                      style: statusStyle,
                    ),
                  ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: ready == null || !showSummary
                          ? const SizedBox.shrink()
                          : Text(
                              panoramaSummary(ready),
                              key: const ValueKey<String>(
                                'home-panorama-summary',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: type.bodySmall.copyWith(
                                color: style.muted,
                              ),
                            ),
                    ),
                    action(
                      id: 'home-panorama-share',
                      icon: FushiIcons.play,
                      label: t.panorama_share_animation,
                      onPressed: hasWorks
                          ? () => unawaited(
                              playPanoramaCinematic(context, ready, onOpen),
                            )
                          : null,
                    ),
                    action(
                      id: 'home-panorama-fullscreen',
                      icon: FushiIcons.fullscreen,
                      label: t.panorama_open_fullscreen,
                      onPressed: hasWorks
                          ? () => _openFullscreen(context)
                          : null,
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
