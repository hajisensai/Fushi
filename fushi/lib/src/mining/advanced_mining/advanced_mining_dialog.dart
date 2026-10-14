import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 「高级制卡」对话框入口（契约见 [AdvancedMiningCapabilities]）。
///
/// 调用方负责在外面包 `runWithLookupPopupHidden`（查词弹窗是原生平台视图，会盖住
/// Flutter 对话框，BUG-797）。对话框关闭（确认或取消）后会调用
/// [AdvancedMiningSections.onClosed]。
///
/// 桩实现：完整 UI 由 `AdvancedMiningDialog` 提供（宽屏双栏 / 窄屏底部面板）。
Future<void> showAdvancedMiningDialog({
  required BuildContext context,
  required AdvancedMiningCapabilities capabilities,
}) async {
  try {
    await showAppDialog<void>(
      context: context,
      builder: (_) => AdvancedMiningDialog(capabilities: capabilities),
    );
  } finally {
    await capabilities.sections.onClosed?.call();
  }
}

/// 「高级制卡」对话框本体（纯 UI，所有能力经 [capabilities] 注入）。
class AdvancedMiningDialog extends StatefulWidget {
  const AdvancedMiningDialog({super.key, required this.capabilities});

  final AdvancedMiningCapabilities capabilities;

  @override
  State<AdvancedMiningDialog> createState() => _AdvancedMiningDialogState();
}

class _AdvancedMiningDialogState extends State<AdvancedMiningDialog> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
