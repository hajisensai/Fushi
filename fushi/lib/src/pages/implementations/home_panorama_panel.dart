/// 首页「媒体库全景」小组件（[HomeWidgetKind.panorama]，2×2 · 4×2）：只是入口，不默认
/// 渲染 3D 预览（不建图集、不跑帧循环）。点块 / 「全屏」进可操作的 [PanoramaPage]；
/// 「分享动画」先选最后锁定的作品，再播 16 秒开场动画（只用于分享）。
///
/// 恒可用（不属于任何可关的模块）；旧可选面板「自动」档默认不显示（2026-10-30 用户
/// 「默认关闭媒体库全景」），所以迁移首个布局时只有钉成「显示」的用户才放上它。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

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
    required this.size,
    this.poster = false,
  });

  final PanoramaOpenWork onOpen;

  /// 格子尺寸档。
  final HomeWidgetSize size;

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

    return HomeWidgetFrame(
      key: const ValueKey<String>('home-panorama-panel'),
      tapKey: const ValueKey<String>('home-panorama-banner'),
      title: t.home_panel_panorama_title,
      icon: FushiIcons.blur,
      hueKey: HomeWidgetKind.panorama.id,
      poster: poster,
      dense: false,
      onTap: hasWorks ? () => _openFullscreen(context) : null,
      child: Builder(
        builder: (BuildContext context) {
          final HomeWidgetStyle style = HomeWidgetStyle.of(context);
          final TextStyle base =
              Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
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
            enabled: onPressed != null,
            enabledColor: style.foreground,
            onTap: onPressed,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  status,
                  maxLines: size.cols >= 4 ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: base.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                    color: style.accent,
                  ),
                ),
              ),
              Row(
                children: <Widget>[
                  Expanded(
                    child: ready == null
                        ? const SizedBox.shrink()
                        : Text(
                            panoramaSummary(ready),
                            key: const ValueKey<String>(
                              'home-panorama-summary',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: base.copyWith(
                              fontSize: 12,
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
                    onPressed: hasWorks ? () => _openFullscreen(context) : null,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
