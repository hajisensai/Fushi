/// 首页「媒体库全景」面板（[HomeDashboardPanel.panorama]）：只是入口，不默认渲染 3D 预览
/// （不建图集、不跑帧循环）。点面板 / 「全屏」进可操作的 [PanoramaPage]；「分享动画」先选
/// 最后锁定的作品，再播 16 秒开场动画（只用于分享）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/panorama/panorama_library.dart';
import 'package:fushi/src/media/panorama/panorama_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_dashboard_panel.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 全景面板该不该出现（纯函数）：钉了显示 / 隐藏照办；自动 = 显示（空库时面板里给引导语）。
bool resolveHomePanoramaPanelVisible({required HomeDashboardPanelMode mode}) =>
    mode != HomeDashboardPanelMode.hidden;

final Provider<bool> homePanoramaPanelVisibleProvider = Provider<bool>((
  Ref ref,
) {
  final AppModel app = ref.watch(appProvider);
  if (!app.isPreferencesReady) return false;
  return resolveHomePanoramaPanelVisible(
    mode: app.homeDashboardPanelMode(HomeDashboardPanel.panorama),
  );
});

class HomePanoramaPanel extends ConsumerWidget {
  const HomePanoramaPanel({super.key, required this.onOpen});

  final PanoramaOpenWork onOpen;

  /// 入口横幅高度（原先是 280 的实时预览）。
  static const double bannerHeight = 112;

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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final BorderRadius radius = apple
        ? FushiAppleMetrics.of(context).groupBorderRadius
        : FushiBorderRadius.card;
    final Color fill = apple
        ? appleColorsOf(context).secondaryGroupedBackground
        : tokens.surfaces.group;
    final AsyncValue<PanoramaLibrary> library = ref.watch(
      panoramaLibraryProvider,
    );
    final PanoramaLibrary? ready = library.valueOrNull;
    final bool hasWorks = ready != null && !ready.isEmpty;

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
      enabledColor: tokens.type.sectionLabel.color,
      onTap: onPressed,
    );

    final Widget banner = FushiPressScale(
      enabled: hasWorks,
      child: GestureDetector(
        key: const ValueKey<String>('home-panorama-banner'),
        behavior: HitTestBehavior.opaque,
        onTap: hasWorks ? () => _openFullscreen(context) : null,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              radius: 1.4,
              colors: <Color>[Color(0xFF2A1E3A), Color(0xFF05070F)],
            ),
          ),
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(tokens.spacing.card),
              child: Text(
                library.hasError
                    ? t.panorama_load_failed
                    : library.isLoading
                    ? t.panorama_loading
                    : hasWorks
                    ? t.home_panel_panorama_hint
                    : t.panorama_empty,
                textAlign: TextAlign.center,
                style: tokens.type.metadata.copyWith(color: Colors.white70),
              ),
            ),
          ),
        ),
      ),
    );

    return FushiHoverLift(
      scale: 1.005,
      builder: (BuildContext context, bool hovering) => Material(
        key: const ValueKey<String>('home-panorama-panel'),
        color: fill,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: eink
              ? BorderSide(color: tokens.surfaces.outline)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                tokens.spacing.gap + 4,
                tokens.spacing.gap / 2,
                tokens.spacing.gap / 2,
                tokens.spacing.gap / 2,
              ),
              child: Row(
                children: <Widget>[
                  FushiIcon(
                    FushiIcons.blur,
                    size: 18,
                    color: tokens.type.sectionLabel.color,
                  ),
                  SizedBox(width: tokens.spacing.gap / 2),
                  // 标题与说明上下两行、各自省略：窄列（首页 240 宽）时按钮不被挤出。
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          t.home_panel_panorama_title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tokens.type.sectionLabel,
                        ),
                        if (ready != null)
                          Text(
                            panoramaSummary(ready),
                            key: const ValueKey<String>(
                              'home-panorama-summary',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tokens.type.metadata,
                          ),
                      ],
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
            ),
            SizedBox(height: bannerHeight, child: banner),
          ],
        ),
      ),
    );
  }
}
