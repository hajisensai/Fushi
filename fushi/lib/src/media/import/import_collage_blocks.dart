/// 导入界面拼贴的块组件（导入稿 v2「共用组件」）：多边形 glyph、引导首块、导入
/// 方式色块、「支持 n 种格式 ›」气泡、拖放虚线框。数据全部来自
/// [ImportSurfaceSpec]，组件不按模块分支。
///
/// 动效只取 [FushiMotion]：悬停 [FushiHoverLift]、按压 [FushiCard] 内置的
/// [FushiPressScale]；减弱动效下 glyph 不转、不转圈（[fushiMotionEnabled]）。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/import/import_glyph.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_fit_text.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 去向的界面文字（[ImportDestination] 本身不带文案）。
extension ImportDestinationLabel on ImportDestination {
  String get label => switch (this) {
    ImportDestination.dialog => t.import_destination_dialog,
    ImportDestination.choice => t.import_destination_choice,
    ImportDestination.source => t.import_destination_source,
    ImportDestination.read => t.import_destination_read,
    ImportDestination.pickFile => t.import_destination_pick_file,
    ImportDestination.pickFolder => t.import_destination_pick_folder,
    ImportDestination.pickDrive => t.import_destination_pick_drive,
    ImportDestination.list => t.import_destination_list,
  };
}

/// 「支持 n 种格式 ›」胶囊（稿 `.imp-guide .fmt`）：点开分组气泡
/// [showImportFormatBubble]。命中区 ≥48dp。
class ImportFormatChip extends StatelessWidget {
  const ImportFormatChip({required this.spec, required this.colors, super.key});

  final ImportSurfaceSpec spec;
  final FushiCoverBlockColors colors;

  @override
  Widget build(BuildContext context) {
    final int count = spec.formatCount;
    return FushiTextButton(
      key: ValueKey<String>('import-formats-${spec.id}'),
      onPressed: () => showImportFormatBubble(
        context: context,
        groups: spec.formatGroups,
        pickOnlyGroups: spec.pickOnlyFormatGroups,
      ),
      style: TextButton.styleFrom(
        foregroundColor: colors.onContainer,
        backgroundColor: colors.onContainer.withValues(alpha: 0.16),
        minimumSize: const Size(48, 48),
        tapTargetSize: MaterialTapTargetSize.padded,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            t.import_formats_supported_count(n: count),
            style: context.fushiType.labelMedium.copyWith(
              fontWeight: FontWeight.w700,
              color: colors.onContainer,
            ),
          ),
          const SizedBox(width: 4),
          FushiIcon(
            FushiIcons.chevronRight,
            size: 16,
            color: colors.onContainer,
          ),
        ],
      ),
    );
  }
}

/// 「支持 n 种格式」的分组气泡：手机（compact）用底部弹层，其余用小对话框。
/// 组名与标签都来自 spec（扩展名集合派生，不手写）。
Future<void> showImportFormatBubble({
  required BuildContext context,
  required List<ImportFormatGroup> groups,
  List<ImportFormatGroup> pickOnlyGroups = const <ImportFormatGroup>[],
}) {
  final bool compact =
      windowSizeClassReal(
        MediaQuery.sizeOf(context).width,
        FushiAppUiScale.of(context),
      ) ==
      WindowSizeClass.compact;
  Widget body(BuildContext context) =>
      _ImportFormatBubbleBody(groups: groups, pickOnlyGroups: pickOnlyGroups);
  if (compact) {
    return adaptiveModalSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) => FushiModalSheetFrame(
        key: const ValueKey<String>('import-format-bubble'),
        title: t.import_supported_formats,
        scrollable: true,
        // 正文与标题同一左右边距：不传时默认 0，分组名和格式 chip 贴着弹层边
        // （用户 2026-11-16「排版有问题」）。
        bodyPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        body: body(sheetContext),
      ),
    );
  }
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => FushiDialogFrame(
      key: const ValueKey<String>('import-format-bubble'),
      maxWidth: 420,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.import_supported_formats,
        scrollable: true,
        // 正文与标题同一左右边距：不传时默认 0，分组名和格式 chip 贴着弹层边
        // （用户 2026-11-16「排版有问题」）。
        bodyPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        body: body(dialogContext),
      ),
    ),
  );
}

class _ImportFormatBubbleBody extends StatelessWidget {
  const _ImportFormatBubbleBody({
    required this.groups,
    required this.pickOnlyGroups,
  });

  final List<ImportFormatGroup> groups;
  final List<ImportFormatGroup> pickOnlyGroups;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    Widget group(ImportFormatGroup g) => Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap * 2),
      child: Semantics(
        container: true,
        label: '${g.title} · ${g.labels.length}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ExcludeSemantics(
              child: Text(
                '${g.title} · ${g.labels.length}',
                style: context.fushiType.labelLarge.copyWith(
                  fontWeight: FontWeight.w700,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            SizedBox(height: tokens.spacing.gap),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final String label in g.labels)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(FushiRadii.chipValue),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Text(
                        label,
                        style: context.fushiType.labelMedium.copyWith(
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final ImportFormatGroup g in groups) group(g),
        for (final ImportFormatGroup g in pickOnlyGroups) group(g),
      ],
    );
  }
}

/// 导入引导首块（导入面唯一加大的块，稿 `.imp-guide`）：模块色底 + 多边形图标 +
/// 标题 + 一句说明 +「支持 n 种格式 ›」。不放按钮。
///
/// [dropEnabled]（本面真的装了落点且在桌面端）时画虚线内框、说明可以提拖放；
/// 否则不画虚线（IM2：没有落点就不画拖放的视觉）。[dragging] 是拖放态：块浮起、
/// 虚线变实线、标题换成中性的「松手导入」，减弱动效下只换描边和标题。
///
/// [banner] = 横幅版式（桌面 5 种方式时独占一行，图标在左）。
class ImportGuideBlock extends StatelessWidget {
  const ImportGuideBlock({
    required this.spec,
    required this.dropEnabled,
    this.dragging = false,
    this.banner = false,
    this.minHeight = 206,
    this.compact = false,
    super.key,
  });

  final ImportSurfaceSpec spec;
  final bool dropEnabled;
  final bool dragging;
  final bool banner;
  final double minHeight;

  /// 手机版式：图标与标题缩一档。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final FushiCoverBlockColors colors = importToneColors(context, spec.tone);
    final bool eink = isEinkTheme(context);
    final bool motion = fushiMotionEnabled(context);
    final bool lifted = dragging && motion;
    final double radius = fushiCoverBlockRadius(
      FushiCoverBlockSize.regular,
      minHeight,
    );
    final String title = dragging
        ? t.import_drop_release_title
        : spec.guideTitle;
    final String description = dragging
        ? t.import_drop_release_hint
        : dropEnabled
        ? spec.guideDescription
        : (spec.guideDescriptionWithoutDrop ?? spec.guideDescription);
    final bool showFormats =
        spec.formatGroups.isNotEmpty || spec.pickOnlyFormatGroups.isNotEmpty;
    return FushiHoverLift(
      forceLifted: lifted,
      builder: (BuildContext context, bool hovering) {
        final double glyphSize = compact ? 46 : 60;
        final Widget glyph = ImportGlyph(
          icon: spec.guideIcon,
          colors: colors,
          seed: 'import-guide-${spec.id}',
          size: glyphSize,
          turns: (hovering || dragging) && motion ? 14 / 360 : 0,
        );
        final Widget text = Semantics(
          container: true,
          header: true,
          label: '$title. $description',
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style:
                      (compact
                              ? context.fushiType.titleMedium
                              : context.fushiType.titleLarge)
                          .copyWith(
                            height: 1.2,
                            fontWeight: FontWeight.w800,
                            color: colors.onContainer,
                          ),
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Text(
                    description,
                    style: context.fushiType.bodySmall.copyWith(
                      height: 1.5,
                      color: colors.onContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        final Widget formats = showFormats
            ? ImportFormatChip(spec: spec, colors: colors)
            : const SizedBox.shrink();
        final Widget content = banner
            ? Row(
                children: <Widget>[
                  glyph,
                  const SizedBox(width: 18),
                  Expanded(child: text),
                  const SizedBox(width: 12),
                  formats,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  glyph,
                  const SizedBox(height: 10),
                  text,
                  if (showFormats) ...<Widget>[
                    const SizedBox(height: 12),
                    formats,
                  ],
                ],
              );
        final Duration fade = fushiMotionDuration(context, FushiMotion.short);
        return AnimatedContainer(
          duration: fade,
          curve: FushiMotion.standard,
          constraints: BoxConstraints(minHeight: minHeight),
          decoration: ShapeDecoration(
            color: colors.container,
            shape: fushiCoverBlockShape(context, FushiCoverBlockSize.regular),
            shadows: lifted
                ? fushiCoverBlockShadows(FushiCoverBlockSize.regular)
                : const <BoxShadow>[],
          ),
          child: CustomPaint(
            foregroundPainter: dropEnabled
                ? ImportDashedBorderPainter(
                    color: dragging
                        ? colors.onContainer
                        : colors.onContainer.withValues(alpha: 0.3),
                    radius: radius,
                    dashed: !dragging && !eink,
                    strokeWidth: dragging ? 3 : 2,
                    inset: dragging ? 4 : 8,
                  )
                : null,
            child: Padding(
              padding: EdgeInsets.all(compact ? 18 : 22),
              child: content,
            ),
          ),
        );
      },
    );
  }
}

/// 导入方式色块（稿 `.mb`）：等尺寸，glyph + 名称 + 一句说明 + 去向。主方式取
/// 模块色反色，其余按 [ImportMethodKind] 钉色。
///
/// [showDetails] = 中宽以上（显示说明与去向文字）；手机只留 glyph + 名称 + 箭头。
/// [wide] = 横排占满一行（中宽 / 手机方式数为奇数时的最后一块）。
/// [busy]：不弹对话框的方式进行中，glyph 转圈、说明换「导入中…」；[dimmed]：
/// 另一个方式正在跑，本块 45% 不可点。
class ImportMethodBlock extends StatelessWidget {
  const ImportMethodBlock({
    required this.method,
    required this.moduleTone,
    required this.onTap,
    this.showDetails = true,
    this.wide = false,
    this.busy = false,
    this.dimmed = false,
    this.minHeight = 206,
    super.key,
  });

  final ImportMethod method;
  final ImportTone moduleTone;
  final VoidCallback onTap;
  final bool showDetails;
  final bool wide;
  final bool busy;
  final bool dimmed;
  final double minHeight;

  static const double _goSize = 34;

  @override
  Widget build(BuildContext context) {
    final bool primary = method.kind == ImportMethodKind.primary;
    final FushiCoverBlockColors colors = importToneColors(
      context,
      importMethodTone(method.kind, moduleTone),
      inverse: primary,
    );
    final bool motion = fushiMotionEnabled(context);
    final bool interactive = method.enabled && !dimmed && !busy;
    final double radius = fushiCoverBlockRadius(
      FushiCoverBlockSize.regular,
      minHeight,
    );
    final String? description = busy
        ? t.import_in_progress
        : method.description;
    final String? destination = method.destination?.label;
    return FushiHoverLift(
      enabled: interactive,
      builder: (BuildContext context, bool hovering) {
        final Widget glyph = ImportGlyph(
          icon: method.icon,
          colors: colors,
          seed: 'import-method-${method.id}',
          size: wide || !showDetails ? 38 : 46,
          turns: hovering && motion ? -10 / 360 : 0,
          spinning: busy,
        );
        final Widget name = FushiFitText(
          text: method.label,
          minSize: showDetails ? 13 : 12,
          maxSize: showDetails ? 17 : 15,
          style: TextStyle(
            height: 1.2,
            fontWeight: FontWeight.w800,
            color: colors.onContainer,
          ),
        );
        final TextStyle detailStyle = context.fushiType.bodySmall.copyWith(
          height: 1.45,
          fontWeight: FontWeight.w600,
          color: colors.onContainer,
        );
        final List<Widget> details = <Widget>[
          if ((showDetails || busy) && description != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(description, style: detailStyle),
          ],
          if (showDetails && !busy && method.note != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              method.note!,
              style: detailStyle.copyWith(fontWeight: FontWeight.w500),
            ),
          ],
        ];
        final Widget arrow = AnimatedSlide(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          curve: FushiMotion.release,
          offset: Offset(hovering && motion ? 4 / _goSize : 0, 0),
          child: SizedBox.square(
            dimension: _goSize,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.onContainer.withValues(alpha: 0.16),
              ),
              child: Center(
                child: FushiIcon(
                  FushiIcons.forward,
                  size: 18,
                  color: colors.onContainer,
                ),
              ),
            ),
          ),
        );
        final Widget go = ExcludeSemantics(
          child: Row(
            children: <Widget>[
              if (showDetails && destination != null)
                Expanded(
                  child: Text(
                    destination,
                    style: context.fushiType.labelMedium.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colors.onContainer,
                    ),
                  ),
                )
              else
                const Spacer(),
              arrow,
            ],
          ),
        );
        final Widget body = wide
            ? Row(
                children: <Widget>[
                  glyph,
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[name, ...details],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (showDetails && destination != null) ...<Widget>[
                    ExcludeSemantics(
                      child: Text(
                        destination,
                        style: context.fushiType.labelMedium.copyWith(
                          fontWeight: FontWeight.w700,
                          color: colors.onContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  ExcludeSemantics(child: arrow),
                ],
              )
            // 去向行贴底：非定位的内容列预留去向行高度，去向行定位在块底——
            // 块按 [minHeight] 撑开时它在底部，内容长了块随之增高（不出溢出）。
            : Stack(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(bottom: _goSize + 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        glyph,
                        const SizedBox(height: 10),
                        name,
                        ...details,
                      ],
                    ),
                  ),
                  PositionedDirectional(start: 0, end: 0, bottom: 0, child: go),
                ],
              );
        return AnimatedOpacity(
          opacity: dimmed ? 0.45 : 1,
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          child: Semantics(
            enabled: interactive,
            label: <String>[
              method.label,
              if (description != null) description,
              if (showDetails && !busy && method.note != null) method.note!,
            ].join('. '),
            excludeSemantics: true,
            button: true,
            onTap: interactive ? onTap : null,
            child: FushiCard(
              key: ValueKey<String>('import-method-${method.id}'),
              focusId: FushiFocusId('import-method-${method.id}'),
              onTap: interactive ? onTap : null,
              color: colors.container,
              shape: fushiCoverBlockShape(context, FushiCoverBlockSize.regular),
              borderRadius: BorderRadius.circular(radius),
              padding: EdgeInsets.zero,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: wide ? 96 : minHeight),
                child: Padding(
                  padding: EdgeInsets.all(showDetails ? 16 : 12),
                  child: body,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
