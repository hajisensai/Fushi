import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/utils.dart';

/// 推荐包下载的**常驻**可见入口（设置 → 系统 → 通用）。
///
/// BUG-2097：下载的所有权已上移到 [RecommendedPackDownloadController]，关掉新手
/// 引导不再取消它 —— 但「在后台跑」如果没有任何地方看得到，等于没跑。这一行就是
/// 那个地方：下载中报进度并能取消，下完报「待导入」并能就地导入。
///
/// BUG-2165 补上第三态「已暂停」：取消、失败、上个进程被关掉，盘上都躺着一截可续
/// 的半截包。它以前一律落回 idle（= 整行不渲染），于是那 3 GB 既看不到、也只能靠
/// 重开新手引导才续得上。现在它在这里报「已下 3.2 GB · 继续下载」，失败原因（如果
/// 有）就地显示——失败后没有重试按钮，等于让用户从 0 重下 9.5 GB。
///
/// 空闲（盘上什么都没有）时整行不渲染：设置页不该常驻一条恒为「无任务」的死行。
class RecommendedPackDownloadRow extends StatelessWidget {
  const RecommendedPackDownloadRow({
    required this.controller,
    required this.onImport,
    super.key,
  });

  final RecommendedPackDownloadController controller;

  /// 导入已下好的整包。导入要用户确认覆盖/合并并重启进程，controller 不自己发起，
  /// 由宿主（设置页 / 新手引导）传进来。
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        controller.stage,
        controller.progress,
        controller.receivedBytes,
        controller.error,
      ]),
      builder: (BuildContext context, _) {
        switch (controller.stage.value) {
          case RecommendedPackDownloadStage.idle:
            return const SizedBox.shrink();
          case RecommendedPackDownloadStage.downloading:
            return AdaptiveSettingsRow(
              title: t.onboarding_pack_status_downloading,
              subtitle: recommendedPackProgressLabel(
                progress: controller.progress.value,
                receivedBytes: controller.receivedBytes.value,
              ),
              icon: Icons.downloading_outlined,
              showIcon: true,
              controlBelow: true,
              trailing: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  LinearProgressIndicator(
                    value: controller.progress.value > 0
                        ? controller.progress.value
                        : null,
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      onPressed: controller.requestCancel,
                      child: Text(t.dialog_cancel),
                    ),
                  ),
                ],
              ),
            );
          case RecommendedPackDownloadStage.paused:
            final String? failure = controller.error.value;
            return AdaptiveSettingsRow(
              title: t.onboarding_pack_status_paused,
              // 失败原因优先于通用说明：断在 8 GB 的人最需要知道断在什么上。
              subtitle: failure == null
                  ? '${recommendedPackProgressLabel(
                      progress: controller.progress.value,
                      receivedBytes: controller.receivedBytes.value,
                    )} · ${t.onboarding_pack_paused_desc}'
                  : '${recommendedPackProgressLabel(
                      progress: controller.progress.value,
                      receivedBytes: controller.receivedBytes.value,
                    )} · ${t.onboarding_pack_download_failed(message: failure)}',
              icon: Icons.pause_circle_outline,
              showIcon: true,
              trailing: FilledButton.tonal(
                onPressed: () => unawaited(controller.start()),
                child: Text(t.onboarding_pack_download_resume),
              ),
            );
          case RecommendedPackDownloadStage.downloaded:
            return AdaptiveSettingsRow(
              title: t.onboarding_pack_status_ready,
              subtitle: t.onboarding_pack_action_import_existing_desc,
              icon: Icons.inventory_2_outlined,
              showIcon: true,
              trailing: FilledButton(
                onPressed: onImport,
                child: Text(t.onboarding_pack_import_now),
              ),
            );
        }
      },
    );
  }
}
