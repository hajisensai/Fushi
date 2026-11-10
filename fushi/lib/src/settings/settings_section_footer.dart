/// 设置分组脚注（样式 + 文字件）。叶子文件：只依赖设计系统 token 与平台判据，
/// 不碰 `SettingsContext` / `AppModel`，单独的设置子页面用它不会被拖进 lib/ 的大
/// import 环（守卫 `test/build/import_cycle_guard_test.dart`）。
/// `settings_schema_widgets.dart` 转出本文件，旧 import 照常可用。
library;

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoColors;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;

/// section footer 文字样式解析器。两个渲染器对 footer 用不同的 TextStyle
/// （Material：bodySmall + surfaces.onVariant；Cupertino：metadata + secondaryLabel），
/// 是这套共享 schema widget 里唯一的平台差异，作参数注入。
typedef SettingsFooterStyle = TextStyle? Function(BuildContext context);

/// 设置分组脚注的默认文字样式，按设计系统 / 平台分派：Apple = iOS footnote
/// （13 号 secondaryLabel）；Cupertino = metadata + secondaryLabel；MD3 =
/// bodySmall + surfaces.onVariant。分组内外的说明文字都走这一处。
TextStyle? settingsFootnoteStyle(BuildContext context) {
  if (isCupertinoPlatform(context)) {
    return FushiDesignTokens.of(context).type.metadata.copyWith(
      color: CupertinoColors.secondaryLabel.resolveFrom(context),
    );
  }
  if (isGlassDesign(context)) {
    return FushiAppleMetrics.of(context).footnoteStyle(context);
  }
  return Theme.of(context).textTheme.bodySmall?.copyWith(
    color: FushiDesignTokens.of(context).surfaces.onVariant,
  );
}

/// section 底部说明文字。padding 两渲染器一致；文字样式默认按设计系统取
/// [settingsFootnoteStyle]，渲染器要别的口径时经 [style] 注入。
class SettingsSectionFooter extends StatelessWidget {
  const SettingsSectionFooter(this.text, {super.key, this.style});

  final String text;
  final SettingsFooterStyle? style;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.gap + tokens.spacing.gap / 2,
        0,
        tokens.spacing.gap + tokens.spacing.gap / 2,
        tokens.spacing.gap + tokens.spacing.gap / 2,
      ),
      child: Text(text, style: (style ?? settingsFootnoteStyle)(context)),
    );
  }
}
