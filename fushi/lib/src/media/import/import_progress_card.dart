import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';

/// 导入进度卡（M3E）：secondaryContainer 色块 + 等宽大号百分比 + 波浪线性进度
/// + 当前步骤文案；挂载时弹簧上浮进场。读 [ImportFlowMixin] 的两个 notifier。
class ImportProgressCard extends StatelessWidget {
  const ImportProgressCard({
    required this.progress,
    required this.message,
    super.key,
  });

  final ValueListenable<double> progress;
  final ValueListenable<String> message;

  @override
  Widget build(BuildContext context) {
    final FushiTypography type = context.fushiType;
    final FushiMotionScheme motion = context.fushiMotion;
    // 色块上的字跟卡片配对前景（fushiType 自带页面前景，HBK-AUDIT-022）。
    final Color? onCard = fushiCardToneColors(
      context,
      FushiCardTone.secondary,
    )?.onContainer;
    final Widget card = FushiCard(
      tone: FushiCardTone.secondary,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (BuildContext context, double value, Widget? _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '${(value.clamp(0.0, 1.0) * 100).round()}%',
                  style: type.headlineSmallEmphasized.tabular.copyWith(
                    color: onCard,
                  ),
                ),
                const SizedBox(height: 8),
                FushiLinearProgressIndicator(value: value),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<String>(
            valueListenable: message,
            builder: (BuildContext context, String msg, Widget? _) => Text(
              msg,
              style: type.bodyMedium.copyWith(color: onCard),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    if (motion.spatialDefault.duration == Duration.zero) return card;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: motion.spatialDefault.duration,
      curve: motion.spatialDefault.curve,
      child: card,
      builder: (BuildContext context, double v, Widget? child) => Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - v) * 16),
          child: child,
        ),
      ),
    );
  }
}
