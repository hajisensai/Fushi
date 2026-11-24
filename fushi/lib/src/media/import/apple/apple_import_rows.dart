/// Apple（Cupertino，iOS 27 / macOS 27）导入页的行件（方案 A「设置」式分组列表）：
/// 行首中性灰圆角方块图标（主方式换强调色）、方式行、分组头（带右侧动作）、
/// 行尾小转圈。行本身一律是公共件 [AdaptiveSettingsRow]，这里只给 Apple 档的
/// 行首 / 行尾件；颜色只表达「可点 / 选中 / 状态」，不读 `ImportTone`。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/import/import_collage_blocks.dart'
    show ImportDestinationLabel;
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiCircularProgressIndicator;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

/// 行首图标方块：iOS 29 / macOS 22（[FushiAppleMetrics.iconTileSize]），中性
/// systemFill 底 + label 色字形，所有方式同一种（用户 11-24：主方式不高亮）；
/// [plain] 不画底、字形用强调色（「添加来源…」这类强调行）。
class AppleImportIconTile extends StatelessWidget {
  const AppleImportIconTile({
    required this.icon,
    this.plain = false,
    super.key,
  });

  final IconData icon;
  final bool plain;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors colors = appleColorsOf(context);
    final double size = metrics.iconTileSize;
    final Color glyph = plain ? colors.accent : colors.label;
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: plain ? Colors.transparent : colors.fill,
          borderRadius: FushiBorderRadius.chip,
        ),
        child: Center(
          child: FushiIcon(
            icon,
            size: size * (plain ? 0.8 : 0.62),
            color: glyph,
          ),
        ),
      ),
    );
  }
}

/// 页内次级文字（副标题、组头动作）：iOS 档 15 号 / macOS 档 13 号 secondaryLabel。
TextStyle appleImportSecondaryStyle(BuildContext context) {
  final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
  return metrics.desktop
      ? metrics.footnoteStyle(context)
      : metrics.subtitleStyle(context);
}

/// 行尾小转圈（方式在跑 / 来源在扫）。
class AppleImportRowSpinner extends StatelessWidget {
  const AppleImportRowSpinner({super.key});

  @override
  Widget build(BuildContext context) {
    final double size = FushiAppleMetrics.of(context).desktop ? 14 : 18;
    return SizedBox.square(
      dimension: size,
      child: const FushiCircularProgressIndicator.adaptive(strokeWidth: 2),
    );
  }
}

/// 分组头：13 号 secondaryLabel 标题（与 [AdaptiveSettingsSection] 外标题同一
/// 口径）+ 右侧可选的强调色文字动作（「编辑」/「完成」）。
class AppleImportSectionHeader extends StatelessWidget {
  const AppleImportSectionHeader({
    required this.title,
    this.actionLabel,
    this.onAction,
    this.actionKey,
    super.key,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final String? label = actionLabel;
    final VoidCallback? action = onAction;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        metrics.rowHorizontal,
        0,
        metrics.rowHorizontal,
        metrics.desktop ? 6 * metrics.scale : 7,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Text(title, style: settingsAppleSectionTitleStyle(context)),
          ),
          if (label != null)
            Semantics(
              button: true,
              enabled: action != null,
              child: FushiPressScale(
                enabled: action != null,
                child: GestureDetector(
                  key: actionKey,
                  behavior: HitTestBehavior.opaque,
                  onTap: action,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 32),
                    child: Align(
                      widthFactor: 1,
                      alignment: AlignmentDirectional.bottomEnd,
                      child: Text(
                        label,
                        style: appleImportSecondaryStyle(context).copyWith(
                          color: action == null
                              ? appleColorsOf(context).tertiaryLabel
                              : appleColorsOf(context).accent,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 一种导入方式的列表行（方案 A「添加到〈库〉」组 / 「网络与服务器」组）。
///
/// 去向按 Apple 惯例：弹对话框 / 二选一 / 列表 / 登记来源 = 行尾 chevron；直接选
/// 文件 / 选目录 / 选光驱 / 直接读 = 无 chevron，macOS 档另在行尾写灰色去向字。
/// 在跑（[busy]）时说明换「导入中」、行尾转圈；别的方式在跑时压暗（[dimmed]）
/// 且不可点。焦点 id 与 M3E 方式块同名（`import-method-<id>`）。
class AppleImportMethodRow extends StatelessWidget {
  const AppleImportMethodRow({
    required this.method,
    required this.onTap,
    this.title,
    this.busy = false,
    this.dimmed = false,
    super.key,
  });

  final ImportMethod method;
  final VoidCallback onTap;

  /// 覆盖行名（「网络与服务器」组里的网络共享行）；null = [ImportMethod.label]。
  final String? title;
  final bool busy;
  final bool dimmed;

  static bool showsChevron(ImportDestination? destination) =>
      switch (destination) {
        ImportDestination.dialog ||
        ImportDestination.choice ||
        ImportDestination.list ||
        ImportDestination.source => true,
        _ => false,
      };

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final bool interactive = method.enabled && !busy && !dimmed;
    final ImportDestination? destination = method.destination;
    final bool chevron = showsChevron(destination);
    final String? note = method.note;
    final String? description = busy
        ? t.import_in_progress
        : (metrics.desktop && note != null
              ? <String>[
                  if (method.description != null) method.description!,
                  note,
                ].join('\n')
              : method.description);
    Widget? trailing;
    if (busy) {
      trailing = const AppleImportRowSpinner();
    } else if (chevron) {
      trailing = const FushiAppleChevron();
    } else if (metrics.desktop && destination != null) {
      trailing = Text(
        destination.label,
        style: metrics
            .subtitleStyle(context)
            .copyWith(color: appleColorsOf(context).secondaryLabel),
      );
    }
    return AnimatedOpacity(
      opacity: dimmed || !method.enabled ? 0.4 : 1,
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      child: FushiPressScale(
        enabled: interactive,
        child: AdaptiveSettingsRow(
          key: ValueKey<String>('import-method-${method.id}'),
          focusId: FushiFocusId('import-method-${method.id}'),
          title: title ?? method.label,
          subtitle: description,
          leading: AppleImportIconTile(icon: method.icon),
          trailing: trailing,
          onTap: interactive ? onTap : null,
        ),
      ),
    );
  }
}
