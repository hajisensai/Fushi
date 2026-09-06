import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/src/onboarding/recommended_pack_import.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

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
    return RecommendedPackDownloadMiniBarView(
      controller: appModel.recommendedPackDownloadController,
      onImport: () => unawaited(importDownloadedRecommendedPack(appModel)),
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
    super.key,
  });

  final RecommendedPackDownloadController controller;

  /// 导入已下好的整包。导入要用户确认覆盖/合并并重启进程，controller 不自己发起。
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        controller.stage,
        controller.progress,
        controller.receivedBytes,
        controller.error,
        controller.miniBarDismissed,
      ]),
      builder: (BuildContext context, _) {
        if (!controller.isActive || controller.miniBarDismissed.value) {
          return const SizedBox.shrink();
        }
        // 面色走设计令牌的语义角色，不在这里自己挑 MD3 surface：`surfaces.overlay`
        // 正是「正在听书」那条迷你条用的同一层，两条并排堆在同一个槽里才读成一条
        // 底部状态带。
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        final ColorScheme scheme = Theme.of(context).colorScheme;
        final TextTheme textTheme = Theme.of(context).textTheme;
        return Material(
          color: tokens.surfaces.overlay,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 下载中才画进度条：0 = 总大小未知（服务器不报 length），退化成不定态。
              if (controller.isDownloading)
                LinearProgressIndicator(
                  minHeight: 2,
                  value: controller.progress.value > 0
                      ? controller.progress.value
                      : null,
                ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: <Widget>[
                    Icon(_icon, color: tokens.surfaces.onVariant),
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
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: t.onboarding_pack_mini_bar_hide,
                      onPressed: controller.dismissMiniBar,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String? get _failure => controller.isPaused ? controller.error.value : null;

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
      return t.onboarding_pack_download_failed(message: failure);
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
        return t.onboarding_pack_action_import_existing_desc;
    }
  }

  List<Widget> get _actions {
    switch (controller.stage.value) {
      case RecommendedPackDownloadStage.downloading:
        return <Widget>[
          TextButton(
            onPressed: controller.requestCancel,
            child: Text(t.dialog_cancel),
          ),
        ];
      case RecommendedPackDownloadStage.paused:
        return <Widget>[
          FilledButton.tonal(
            onPressed: () => unawaited(controller.start()),
            child: Text(t.onboarding_pack_download_resume),
          ),
        ];
      case RecommendedPackDownloadStage.downloaded:
        return <Widget>[
          FilledButton(
            onPressed: onImport,
            child: Text(t.onboarding_pack_import_now),
          ),
        ];
      case RecommendedPackDownloadStage.idle:
        return const <Widget>[];
    }
  }
}
