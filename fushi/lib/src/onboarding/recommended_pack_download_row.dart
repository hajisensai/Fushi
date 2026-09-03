import 'package:flutter/material.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/utils.dart';

/// 推荐包下载的**常驻**可见入口（设置 → 系统 → 通用）。
///
/// BUG-2097：下载的所有权已上移到 [RecommendedPackDownloadController]，关掉新手
/// 引导不再取消它 —— 但「在后台跑」如果没有任何地方看得到，等于没跑。这一行就是
/// 那个地方：下载中报进度并能取消，下完报「待导入」并能就地导入。
///
/// 空闲（没在下、也没有下好待导入的包）时整行不渲染：设置页不该常驻一条恒为
/// 「无任务」的死行。
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
