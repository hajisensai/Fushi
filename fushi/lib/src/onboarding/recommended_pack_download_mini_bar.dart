import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/onboarding/recommended_pack_discard.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/src/onboarding/recommended_pack_import.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 推荐包下载的**全局**常驻迷你条，挂在首页 shell 的内容区底部
/// （`home_page.dart` 的 `_bodyWithMiniBar`，移动底栏 / 桌面 rail / macOS 三套布局
/// 共用），与「正在听书」迷你条并列。
///
/// BUG-2165：BUG-2097 把下载的所有权从向导页上移到了 [AppModel]，走完引导确实不再
/// 掐断它 —— 但可见入口只剩设置 → 系统里那一行。**新用户走完引导恰好落在首页**，
/// 而那一行要「设置 tab → 系统分类 → 滚到通用第 5 项」三步才够得着，且不在任何
/// 必经路径上。于是屏幕上一个像素都没有说明那 9.5 GB 还在下：用户的原话就是
/// 「会不会好像不会在后台下载，如果后台下载的话需要给个地方看进度」。
///
/// 这条就是那个地方。它是设置那一行的**并列**入口，不是替代（BUG-2097 的守卫
/// 测试仍然要求设置里那一行存在）：两处读同一个 controller，不自建任何状态。
///
/// 空闲时不渲染（[SizedBox.shrink]，不占布局）；用户点了取消或收起（×）之后本次
/// 会话内也不再渲染 —— 见 [RecommendedPackDownloadController.miniBarDismissed]。
/// 收起只影响这条，设置那一行照旧。
class RecommendedPackDownloadMiniBar extends ConsumerWidget {
  const RecommendedPackDownloadMiniBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel appModel = ref.watch(appProvider);
    final RecommendedPackDownloadController controller =
        appModel.recommendedPackDownloadController;
    return RecommendedPackDownloadMiniBarView(
      controller: controller,
      onImport: () => unawaited(importDownloadedRecommendedPack(appModel)),
      onDiscard: () =>
          unawaited(confirmAndDiscardRecommendedPack(context, controller)),
    );
  }
}

/// [RecommendedPackDownloadMiniBar] 的无 provider 依赖版本（与
/// `RecommendedPackDownloadRow` 同形状）：controller 与导入回调从外面传进来，
/// widget 测试因此不必先立起一个真 [AppModel]。
class RecommendedPackDownloadMiniBarView extends StatelessWidget {
  const RecommendedPackDownloadMiniBarView({
    required this.controller,
    required this.onImport,
    required this.onDiscard,
    super.key,
  });

  final RecommendedPackDownloadController controller;

  /// 导入已下好的整包。导入要用户确认覆盖/合并并重启进程，controller 不自己发起。
  final VoidCallback onImport;

  /// 放弃已暂停的下载（确认后删半截包）。与 [onImport] 同一条纪律：删几 GB 要用户
  /// 在确认框里按，controller 只提供原语。
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        controller.stage,
        controller.progress,
        controller.receivedBytes,
        controller.error,
        controller.isDeleting,
        controller.miniBarDismissed,
      ]),
      builder: (BuildContext context, _) {
        if (!controller.isActive || controller.miniBarDismissed.value) {
          return const SizedBox.shrink();
        }
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        final ColorScheme scheme = Theme.of(context).colorScheme;
        final TextTheme textTheme = Theme.of(context).textTheme;
        // eink：overlay 面层塌成页面底色，这条状态带与上方 tab 正文连成一片；
        // 顶上描一条线把它切出来。
        final bool eink = isEinkTheme(context);
        final Widget body = Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 下载中才画进度条：0 = 总大小未知（服务器不报 length），退化成不定态
            // （eink 下钉成 0：不定态动画在墨水屏上是整条带子持续刷新；默认轨道色
            // surfaceContainerHighest 也塌成底色，给实色轨道才看得见）。
            if (controller.isDownloading)
              FushiLinearProgressIndicator(
                minHeight: 2,
                value: einkSafeProgressValue(
                  context,
                  controller.progress.value > 0
                      ? controller.progress.value
                      : null,
                ),
                backgroundColor: eink ? scheme.surface : null,
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: <Widget>[
                  FushiIcon(_icon, color: tokens.surfaces.onVariant),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleSmall,
                        ),
                        Text(
                          _subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: _failure == null
                                ? tokens.surfaces.onVariant
                                : scheme.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ..._actions,
                  // 收起**从不**动下载本身：这是「不想看」，不是「不想下」。
                  FushiIconButtonControl(
                    icon: const FushiIcon(Icons.close),
                    tooltip: t.onboarding_pack_mini_bar_hide,
                    onPressed: controller.dismissMiniBar,
                  ),
                ],
              ),
            ),
          ],
        );
        // 外形与「正在听书」迷你条三态同口径（两条叠在同一个底部槽里）：
        // 墨水屏贴边整条 + 顶线；Apple 离边 14 的浮动玻璃胶囊（导航与控件层）；
        // MD3 离边 12 的浮动卡（surfaceContainerHigh、圆角 16、elevation 2）。
        if (eink) {
          return Material(
            color: tokens.surfaces.overlay,
            shape: Border(top: BorderSide(color: tokens.surfaces.outline)),
            child: body,
          );
        }
        if (isGlassDesign(context)) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
            child: GlassContainer(
              useOwnLayer: true,
              quality: fushiGlassQuality(context, prominent: true),
              // 与正在听书迷你条同一档：浮在内容上的大块条用无色 bar 玻璃，
              // 不是带灰填充的常规玻璃。
              settings: fushiClearGlassSettings(context, bar: true),
              shape: const LiquidRoundedSuperellipse(borderRadius: 28),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: body,
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Material(
            color: scheme.surfaceContainerHigh,
            surfaceTintColor: Colors.transparent,
            shadowColor: scheme.shadow,
            elevation: 2,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
            clipBehavior: Clip.antiAlias,
            child: body,
          ),
        );
      },
    );
  }

  String? get _failure =>
      controller.isPaused ? controller.failureMessage : null;

  IconData get _icon {
    switch (controller.stage.value) {
      case RecommendedPackDownloadStage.downloading:
        return Icons.downloading_outlined;
      case RecommendedPackDownloadStage.paused:
        return Icons.pause_circle_outline;
      case RecommendedPackDownloadStage.downloaded:
      case RecommendedPackDownloadStage.idle:
        return Icons.inventory_2_outlined;
    }
  }

  String get _title {
    if (controller.isDeleting.value) return t.onboarding_pack_discard_running;
    switch (controller.stage.value) {
      case RecommendedPackDownloadStage.downloading:
        return t.onboarding_pack_status_downloading;
      case RecommendedPackDownloadStage.paused:
        return t.onboarding_pack_status_paused;
      case RecommendedPackDownloadStage.downloaded:
      case RecommendedPackDownloadStage.idle:
        return t.onboarding_pack_status_ready;
    }
  }

  String get _subtitle {
    final String? failure = _failure;
    if (failure != null) {
      return failure;
    }
    switch (controller.stage.value) {
      case RecommendedPackDownloadStage.downloading:
      case RecommendedPackDownloadStage.paused:
        return recommendedPackProgressLabel(
          progress: controller.progress.value,
          receivedBytes: controller.receivedBytes.value,
        );
      case RecommendedPackDownloadStage.downloaded:
      case RecommendedPackDownloadStage.idle:
        return t.onboarding_pack_download_ready_hint;
    }
  }

  List<Widget> get _actions {
    switch (controller.stage.value) {
      case RecommendedPackDownloadStage.downloading:
        return <Widget>[
          FushiTextButton(
            onPressed: controller.requestCancel,
            child: Text(t.dialog_cancel),
          ),
        ];
      case RecommendedPackDownloadStage.paused:
        // 「放弃」排在「继续」前面：右手边那颗是主动作，误触代价（重下几 GB）落在
        // 放弃这颗上，所以它不能是主按钮、也不能挨着 ×。
        return <Widget>[
          FushiTextButton(
            onPressed: controller.isDeleting.value ? null : onDiscard,
            child: Text(t.onboarding_pack_download_discard),
          ),
          FushiFilledButton.tonal(
            onPressed: controller.isDeleting.value
                ? null
                : () => unawaited(controller.start()),
            child: Text(t.onboarding_pack_download_resume),
          ),
        ];
      case RecommendedPackDownloadStage.downloaded:
        return <Widget>[
          FushiFilledButton(
            onPressed: controller.isDeleting.value ? null : onImport,
            child: Text(t.onboarding_pack_import_now),
          ),
        ];
      case RecommendedPackDownloadStage.idle:
        return const <Widget>[];
    }
  }
}
