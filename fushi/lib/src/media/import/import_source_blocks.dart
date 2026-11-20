/// 导入面「常驻来源」区的块（导入稿 v2「共用组件」）：常驻来源块、互联块、
/// 「添加来源」虚线末块、「连接服务器 ›」块，以及带拖动手柄重排的来源网格。
///
/// 这些块**只负责画**：数据与动作由 `MediaSourcesView`（色块呈现）按每个扫描根
/// 填进 [ImportSourceBlockData]，业务逻辑仍只有 `MediaSourcesViewState` 那一份
/// （重新扫描 / 刮削 / ⋯ 菜单 / 重排持久化），不复制两份。
///
/// 来源块与发现稿的来源块同一套语言（[DiscoverySourceColorsBuilder] 同源同色、
/// [DiscoverySourceGlyph] 名字首字多边形），有意不带封面小条：块上放的是统计
/// 数字（稿判据 ③，只用来源行上现有的数据）。
library;

import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/import/import_glyph.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_source_block.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_block_color_scope.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_fit_text.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 来源「⋯」菜单里的一项（重命名 / 恢复自动分组 / 导出诊断包 / 生成字幕 /
/// 打开文件夹 / 隐私 / 保留为我的来源 / 移除来源）。`MediaSourcesView` 的列表
/// 呈现与色块呈现共用同一份清单。
@immutable
class ImportSourceMenuAction {
  const ImportSourceMenuAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.key,
    this.destructive = false,
  });

  final Key? key;
  final String label;
  final IconData icon;

  /// null = 此刻不可用（菜单项置灰）。
  final VoidCallback? onTap;

  /// 破坏性动作（移除）：菜单里用 error 色；确认框由动作自己弹。
  final bool destructive;
}

/// 来源块底部的圆钮动作（重新扫描之外的：视频的刮削 / 刮削设置）。
@immutable
class ImportSourceIconAction {
  const ImportSourceIconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.busy = false,
    this.key,
  });

  final Key? key;
  final IconData icon;
  final String tooltip;

  /// null = 禁用。
  final VoidCallback? onTap;
  final bool busy;
}

/// 一个扫描根在来源块上要画的全部数据（由 `MediaSourcesView` 按行填）。
///
/// 状态优先级与列表呈现一致：刮削进行中 → 扫描失败 → 计数 · 上次扫描；视频另起
/// 一行可点的上次刮削摘要（BUG-1720）。
@immutable
class ImportSourceBlockData {
  const ImportSourceBlockData({
    required this.id,
    required this.name,
    required this.location,
    required this.countText,
    required this.menu,
    this.lastScanText,
    this.isPrivate = false,
    this.autoOwnerText,
    this.scanError = false,
    this.working = false,
    this.scrapeProgressText,
    this.scrapeSummaryText,
    this.scrapeSummaryFailed = false,
    this.onScrapeSummary,
    this.onRescan,
    this.rescanBusy = false,
    this.actions = const <ImportSourceIconAction>[],
    this.cover,
  });

  /// `media_sources.id`（key 与取色都按它）。
  final int id;
  final String name;

  /// 本地 = 路径；网络 = `TRANSPORT · user@host  rootPath`。
  final String location;

  /// 「128 卷」（整串 key 加大显示，不拆单位）。
  final String countText;

  /// 「上次扫描 …」；null = 从未扫描。
  final String? lastScanText;
  final bool isPrivate;

  /// 「由视频来源「X」自动添加」副行。
  final String? autoOwnerText;

  /// 上次扫描失败（`lastScanError`）：画 error 色「扫描失败 · 重试」。
  final bool scanError;

  /// 扫描 / 刮削 / 导出进行中：块底不定进度条。
  final bool working;

  /// 刮削进度文案（含作品名）；非 null 时取代计数行。
  final String? scrapeProgressText;

  /// 视频上次刮削摘要（可点）。
  final String? scrapeSummaryText;
  final bool scrapeSummaryFailed;
  final VoidCallback? onScrapeSummary;

  /// 重新扫描；null = 此刻不可用（忙）。
  final VoidCallback? onRescan;
  final bool rescanBusy;
  final List<ImportSourceIconAction> actions;
  final List<ImportSourceMenuAction> menu;

  /// 该来源一张已入库条目的封面（取色用，没有就按来源名哈希）。
  final ImageProvider? cover;
}

/// 块内圆钮：视觉 36、命中区 48（稿 `.ib`）。
class _BlockIconButton extends StatelessWidget {
  const _BlockIconButton({
    required this.icon,
    required this.tooltip,
    required this.colors,
    required this.onTap,
    this.busy = false,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final FushiCoverBlockColors colors;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) => FushiIconButton(
    icon: icon,
    size: 18,
    tooltip: tooltip,
    busy: busy,
    enabled: onTap != null,
    onTap: onTap,
    enabledColor: colors.onContainer,
    disabledColor: colors.onContainer.withValues(alpha: 0.4),
    backgroundColor: colors.onContainer.withValues(alpha: 0.16),
    padding: const EdgeInsets.all(9),
    padTouchTarget: true,
  );
}

/// 来源「⋯」菜单按钮（色块与列表同一份清单 [ImportSourceMenuAction]）。
class ImportSourceMenuButton extends StatelessWidget {
  const ImportSourceMenuButton({required this.actions, this.color, super.key});

  final List<ImportSourceMenuAction> actions;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return FushiPopupMenuButton<ImportSourceMenuAction>(
      tooltip: t.common_more_actions,
      icon: FushiIcon(FushiIcons.more, size: 20, color: color),
      onSelected: (ImportSourceMenuAction action) => action.onTap?.call(),
      itemBuilder: (BuildContext context) =>
          <PopupMenuEntry<ImportSourceMenuAction>>[
            for (final ImportSourceMenuAction action in actions)
              PopupMenuItem<ImportSourceMenuAction>(
                key: action.key,
                value: action,
                enabled: action.onTap != null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    FushiIcon(
                      action.icon,
                      size: 20,
                      color: action.destructive ? cs.error : null,
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        action.label,
                        style: action.destructive
                            ? TextStyle(color: cs.error)
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
          ],
    );
  }
}

/// 块的外壳：色块底 + 拼贴外形 + 悬停上浮（来源块整块不可点，只有块内按钮）。
class _BlockShell extends StatelessWidget {
  const _BlockShell({
    required this.colors,
    required this.minHeight,
    required this.child,
    super.key,
  });

  final FushiCoverBlockColors colors;
  final double minHeight;
  final Widget child;
  static const EdgeInsetsGeometry padding = EdgeInsets.fromLTRB(16, 14, 12, 14);

  @override
  Widget build(BuildContext context) => FushiBlockColorScope(
    // 块里的开关 / 按钮 / 弹层取块自己的配色（不退回全局 primary）。
    colors: colors,
    child: FushiHoverLift(
      builder: (BuildContext context, bool _) => DecoratedBox(
        decoration: ShapeDecoration(
          color: colors.container,
          shape: fushiCoverBlockShape(context, FushiCoverBlockSize.regular),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: Padding(padding: padding, child: child),
        ),
      ),
    ),
  );
}

/// 常驻来源块（稿 `.sb2`）：glyph + 名称 + 位置，统计行加大，块底是重新扫描 /
/// 视频刮削圆钮 + 隐私徽标 +「⋯」，右上角拖动手柄（[dragHandle]，由
/// [ImportSourceGrid] 给）。
class ImportSourceBlock extends StatelessWidget {
  const ImportSourceBlock({
    required this.data,
    this.dragHandle,
    this.minHeight = 164,
    super.key,
  });

  final ImportSourceBlockData data;
  final Widget? dragHandle;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final String sourceKey = 'media-source-${data.id}';
    return DiscoverySourceColorsBuilder(
      sourceId: sourceKey,
      name: data.name,
      cover: data.cover,
      builder: (BuildContext context, FushiCoverBlockColors colors) {
        final ColorScheme cs = Theme.of(context).colorScheme;
        final TextStyle small = context.fushiType.labelMedium.copyWith(
          height: 1.35,
          fontWeight: FontWeight.w600,
          color: colors.onContainer,
        );
        final Widget? handle = dragHandle;
        final Widget top = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            DiscoverySourceGlyph(
              sourceId: sourceKey,
              name: data.name,
              colors: colors,
              size: 46,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  FushiFitText(
                    text: data.name,
                    minSize: 13,
                    maxSize: 18,
                    style: TextStyle(
                      height: 1.15,
                      fontWeight: FontWeight.w900,
                      color: colors.onContainer,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(data.location, style: small),
                ],
              ),
            ),
            if (handle != null) handle,
          ],
        );
        final List<Widget> status = <Widget>[
          if (data.autoOwnerText case final String owner)
            Text(
              '↳ $owner',
              key: ValueKey<String>('media_source_auto_owner_${data.id}'),
              style: small.copyWith(fontWeight: FontWeight.w700),
            ),
          if (data.scrapeProgressText case final String progress)
            Text(progress, style: small.copyWith(fontWeight: FontWeight.w700))
          else if (data.scanError)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FushiTextButton.icon(
                key: ValueKey<String>('media_source_scan_error_${data.id}'),
                onPressed: data.onRescan,
                style: TextButton.styleFrom(
                  foregroundColor: cs.onErrorContainer,
                  backgroundColor: cs.errorContainer,
                  disabledForegroundColor: cs.onErrorContainer,
                  disabledBackgroundColor: cs.errorContainer,
                  minimumSize: const Size(48, 40),
                  tapTargetSize: MaterialTapTargetSize.padded,
                  shape: const StadiumBorder(),
                ),
                icon: const FushiIcon(FushiIcons.warning, size: 16),
                label: Text(
                  '${t.media_source_scan_error} · ${t.retry}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            )
          else
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: 10,
              children: <Widget>[
                Text(
                  data.countText,
                  style: context.fushiType.titleLarge.copyWith(
                    height: 1.05,
                    fontWeight: FontWeight.w900,
                    color: colors.onContainer,
                  ),
                ),
                if (data.lastScanText case final String scanned)
                  Text(
                    scanned,
                    style: small.copyWith(fontWeight: FontWeight.w700),
                  ),
              ],
            ),
          if (data.scrapeSummaryText case final String summary)
            InkWell(
              key: ValueKey<String>('media-source-scrape-summary-${data.id}'),
              onTap: data.onScrapeSummary,
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 32),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: 1,
                  child: Text(
                    summary,
                    style: small.copyWith(
                      fontWeight: FontWeight.w700,
                      color: data.scrapeSummaryFailed ? cs.error : null,
                      decoration: TextDecoration.underline,
                      decorationColor: data.scrapeSummaryFailed
                          ? cs.error
                          : colors.onContainer,
                    ),
                  ),
                ),
              ),
            ),
        ];
        final Widget bottom = Row(
          children: <Widget>[
            _BlockIconButton(
              key: ValueKey<String>('media_source_rescan_${data.id}'),
              icon: FushiIcons.refresh,
              tooltip: t.media_source_rescan,
              colors: colors,
              busy: data.rescanBusy,
              onTap: data.onRescan,
            ),
            for (final ImportSourceIconAction action
                in data.actions) ...<Widget>[
              const SizedBox(width: 6),
              _BlockIconButton(
                key: action.key,
                icon: action.icon,
                tooltip: action.tooltip,
                colors: colors,
                busy: action.busy,
                onTap: action.onTap,
              ),
            ],
            const Spacer(),
            if (data.isPrivate)
              Flexible(
                child: FushiTooltip(
                  key: ValueKey<String>(
                    'media_source_private_badge_${data.id}',
                  ),
                  message: t.media_source_privacy_badge,
                  child: Semantics(
                    label: t.media_source_privacy_badge,
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        shape: StadiumBorder(
                          side: BorderSide(
                            color: colors.onContainer,
                            width: 1.5,
                          ),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            FushiIcon(
                              FushiIcons.lock,
                              size: 13,
                              color: colors.onContainer,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: ExcludeSemantics(
                                child: Text(
                                  t.media_source_privacy_badge,
                                  maxLines: 1,
                                  overflow: TextOverflow.fade,
                                  softWrap: false,
                                  style: small.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ImportSourceMenuButton(
              key: ValueKey<String>('media_source_menu_${data.id}'),
              actions: data.menu,
              color: colors.onContainer,
            ),
          ],
        );
        final FushiMotionScheme motion = context.fushiMotion;
        return _BlockShell(
          colors: colors,
          minHeight: minHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              top,
              const SizedBox(height: 8),
              for (final Widget line in status) ...<Widget>[
                line,
                const SizedBox(height: 4),
              ],
              const SizedBox(height: 4),
              bottom,
              FushiAnimatedSize(
                duration: motion.spatialDefault.duration,
                curve: motion.spatialDefault.curve,
                alignment: Alignment.topCenter,
                child: data.working
                    ? Padding(
                        padding: const EdgeInsetsDirectional.only(
                          top: 8,
                          end: 4,
                        ),
                        child: FushiLinearProgressIndicator(
                          color: colors.onContainer,
                          backgroundColor: colors.onContainer.withValues(
                            alpha: 0.18,
                          ),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 互联块（稿 `.sb2.t7`，IM4）：开关仍写 `SyncRepository.setInterconnectEnabled`
/// （由调用方 [onChanged] 落），说明沿用 `interconnect_enable_hint`。漫画给
/// [onBrowse] 时块内多一颗「浏览对端… ›」，关闭态按钮禁用并换 [browseDisabledHint]。
class ImportInterconnectBlock extends StatelessWidget {
  const ImportInterconnectBlock({
    required this.enabled,
    required this.onChanged,
    this.onBrowse,
    this.browseLabel,
    this.browseDisabledHint,
    this.minHeight = 164,
    super.key,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onBrowse;
  final String? browseLabel;
  final String? browseDisabledHint;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final FushiCoverBlockColors colors = importToneColors(
      context,
      ImportTone.indigo,
    );
    final String? label = browseLabel;
    final VoidCallback? browse = onBrowse;
    final bool hasBrowse = label != null && browse != null;
    final TextStyle small = context.fushiType.labelMedium.copyWith(
      height: 1.35,
      fontWeight: FontWeight.w600,
      color: colors.onContainer,
    );
    return _BlockShell(
      key: const ValueKey<String>('import-interconnect-block'),
      colors: colors,
      // 块高收到内容高：没有浏览按钮时不撑到来源块的最小高度。
      minHeight: hasBrowse ? minHeight : 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ImportGlyph(
                icon: FushiIcons.devices,
                colors: colors,
                seed: 'import-interconnect',
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      t.audio_source_fushi_interconnect,
                      style: context.fushiType.titleMedium.copyWith(
                        height: 1.15,
                        fontWeight: FontWeight.w900,
                        color: colors.onContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(t.interconnect_enable_hint, style: small),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              adaptiveSwitch(
                context: context,
                value: enabled,
                onChanged: onChanged,
              ),
            ],
          ),
          if (hasBrowse) ...<Widget>[
            if (!enabled && browseDisabledHint != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(browseDisabledHint!, style: small),
            ],
            const SizedBox(height: 10),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('import-interconnect-browse'),
                onPressed: enabled ? browse : null,
                style: FilledButton.styleFrom(
                  foregroundColor: colors.onContainer,
                  backgroundColor: colors.onContainer.withValues(alpha: 0.16),
                  disabledForegroundColor: colors.onContainer.withValues(
                    alpha: 0.45,
                  ),
                  disabledBackgroundColor: colors.onContainer.withValues(
                    alpha: 0.08,
                  ),
                  minimumSize: const Size(48, 44),
                ),
                iconAlignment: IconAlignment.end,
                icon: const FushiIcon(FushiIcons.chevronRight, size: 18),
                label: Text(label),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 「添加来源」虚线末块（稿 `.addb`）：同时承担空状态（没有扫描根时说明用
/// `media_source_list_empty`）。悬停时虚线变成模块色、「＋」由圆变圆角方。
class ImportAddSourceBlock extends StatelessWidget {
  const ImportAddSourceBlock({
    required this.onTap,
    required this.hint,
    this.wide = false,
    this.minHeight = 164,
    this.enabled = true,
    super.key,
  });

  final VoidCallback onTap;

  /// 副文案：空状态 `media_source_list_empty`；有来源时「本地文件夹或网络共享」
  /// （游戏用 `game_source_scan_hint`）。
  final String hint;

  /// 横排占满一行（桌面空状态 / 落在新一行行首时）。
  final bool wide;
  final double minHeight;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final FushiCoverBlockColors module = importToneColors(
      context,
      ImportToneScope.of(context),
    );
    const double radius = 24;
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    return FushiHoverLift(
      enabled: enabled,
      builder: (BuildContext context, bool hovering) {
        final Widget plus = AnimatedContainer(
          duration: duration,
          curve: FushiMotion.release,
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(hovering ? 14 : 22),
          ),
          child: Center(
            child: FushiIcon(FushiIcons.add, size: 22, color: cs.onSurface),
          ),
        );
        final Widget text = Column(
          crossAxisAlignment: wide
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              t.media_source_add,
              textAlign: wide ? TextAlign.start : TextAlign.center,
              style: context.fushiType.titleSmall.copyWith(
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                hint,
                textAlign: wide ? TextAlign.start : TextAlign.center,
                style: context.fushiType.bodySmall.copyWith(
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        );
        return FushiCard(
          key: const ValueKey<String>('import-add-source-block'),
          focusId: const FushiFocusId('import-add-source-block'),
          onTap: enabled ? onTap : null,
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(radius),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          padding: EdgeInsets.zero,
          child: CustomPaint(
            foregroundPainter: ImportDashedBorderPainter(
              color: hovering && !eink ? module.accent : cs.outline,
              radius: radius,
              dashed: !eink,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: wide ? 96 : minHeight),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Center(
                  child: wide
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            plus,
                            const SizedBox(width: 14),
                            Flexible(child: text),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            plus,
                            const SizedBox(height: 8),
                            text,
                          ],
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 「连接服务器 ›」块（IM17）：跳设置里对应的媒体服务器区段（[onTap] 由调用方
/// 给，判据仍走各自的入口与合规门）。中性色块。
class ImportConnectServerBlock extends StatelessWidget {
  const ImportConnectServerBlock({
    required this.onTap,
    required this.hint,
    this.wide = false,
    this.minHeight = 164,
    super.key,
  });

  final VoidCallback onTap;

  /// 副文案（服务器类型说明，由调用方给）。
  final String hint;
  final bool wide;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final FushiCoverBlockColors colors = FushiCoverBlockColors.resolve(
      Theme.of(context),
      null,
    );
    final double radius = fushiCoverBlockRadius(
      FushiCoverBlockSize.regular,
      wide ? 96 : minHeight,
    );
    final Widget glyph = ImportGlyph(
      icon: FushiIcons.server,
      colors: colors,
      seed: 'import-connect-server',
      size: 40,
    );
    final Widget text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: Text(
                t.discovery_guide_connect_server,
                style: context.fushiType.titleSmall.copyWith(
                  fontWeight: FontWeight.w800,
                  color: colors.onContainer,
                ),
              ),
            ),
            FushiIcon(
              FushiIcons.chevronRight,
              size: 18,
              color: colors.onContainer,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          hint,
          style: context.fushiType.bodySmall.copyWith(
            fontWeight: FontWeight.w600,
            color: colors.onContainer,
          ),
        ),
      ],
    );
    return FushiHoverLift(
      builder: (BuildContext context, bool _) => FushiCard(
        key: const ValueKey<String>('import-connect-server-block'),
        focusId: const FushiFocusId('import-connect-server-block'),
        onTap: onTap,
        color: colors.container,
        shape: fushiCoverBlockShape(context, FushiCoverBlockSize.regular),
        borderRadius: BorderRadius.circular(radius),
        padding: EdgeInsets.zero,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: wide ? 96 : minHeight),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: wide
                ? Row(
                    children: <Widget>[
                      glyph,
                      const SizedBox(width: 14),
                      Expanded(child: text),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[glyph, const SizedBox(height: 12), text],
                  ),
          ),
        ),
      ),
    );
  }
}

/// 来源网格里一个可重排的来源。
@immutable
class ImportSourceGridEntry {
  const ImportSourceGridEntry({required this.key, required this.builder});

  final Key key;

  /// [handle] 是拖动手柄（拖动浮层里为 null）。
  final Widget Function(BuildContext context, Widget? handle) builder;
}

/// 来源区网格：[leading]（互联块，始终第一个）→ 可重排的 [sources] →
/// [trailing]（「添加来源」「连接服务器」）。列数由调用方按断点给（3 / 2 / 1）。
///
/// 末尾块填满所在行的剩余列——任何宽度都不出网格空洞（稿断点表 R14 / R15）；
/// 落在新一行行首时占满整行，并以横排（`wide`）版式构建。
///
/// 重排只走拖动手柄（R10，长按不再触发拖拽）：手柄按下即拖，落到另一个来源块上
/// 就移到它的位置；键盘 Alt+↑/↓、读屏「上移 / 下移」动作同效。
class ImportSourceGrid extends StatelessWidget {
  const ImportSourceGrid({
    required this.columns,
    required this.sources,
    required this.onReorder,
    this.leading = const <Widget>[],
    this.trailing = const <Widget Function(bool wide)>[],
    this.indexOffset = 0,
    super.key,
  });

  final int columns;
  final List<Widget> leading;
  final List<ImportSourceGridEntry> sources;
  final List<Widget Function(bool wide)> trailing;

  /// [from] / [to] 是 [sources] 里的下标。
  final void Function(int from, int to) onReorder;

  /// 第一个块的错峰序号（[ImportSurfaceSpec.sourceEntranceIndex]）。
  final int indexOffset;

  @override
  Widget build(BuildContext context) {
    final double gap = FushiDesignTokens.of(context).spacing.gap + 4;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int cols = columns < 1 ? 1 : columns;
        final double tileWidth =
            (constraints.maxWidth - gap * (cols - 1)) / cols;
        final List<(Widget, int)> cells = <(Widget, int)>[
          for (final Widget w in leading) (w, 1),
          for (int i = 0; i < sources.length; i++)
            (
              _ReorderableSourceTile(
                key: sources[i].key,
                index: i,
                count: sources.length,
                entry: sources[i],
                tileWidth: tileWidth,
                onReorder: onReorder,
              ),
              1,
            ),
        ];
        int used = cells.length % cols;
        for (int i = 0; i < trailing.length; i++) {
          final bool last = i == trailing.length - 1;
          final bool rowStart = used == 0;
          final int span = last ? cols - used : 1;
          final bool wide = cols > 1 && rowStart && span == cols;
          cells.add((trailing[i](wide), span));
          used = (used + span) % cols;
        }
        final List<Widget> rows = <Widget>[];
        int index = indexOffset;
        List<Widget> row = <Widget>[];
        int filled = 0;
        void flush() {
          if (row.isEmpty) return;
          if (filled < cols) {
            row.add(SizedBox(width: gap));
            row.add(Spacer(flex: cols - filled));
          }
          rows.add(
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: row),
          );
          row = <Widget>[];
          filled = 0;
        }

        for (final (Widget widget, int span) in cells) {
          if (filled + span > cols) flush();
          if (row.isNotEmpty) row.add(SizedBox(width: gap));
          row.add(
            Expanded(
              flex: span,
              child: FushiStaggeredEntrance(index: index++, child: widget),
            ),
          );
          filled += span;
        }
        flush();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < rows.length; i++) ...<Widget>[
              if (i > 0) SizedBox(height: gap),
              rows[i],
            ],
          ],
        );
      },
    );
  }
}

class _ReorderableSourceTile extends StatelessWidget {
  const _ReorderableSourceTile({
    required this.index,
    required this.count,
    required this.entry,
    required this.tileWidth,
    required this.onReorder,
    super.key,
  });

  final int index;
  final int count;
  final ImportSourceGridEntry entry;
  final double tileWidth;
  final void Function(int from, int to) onReorder;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return DragTarget<_ImportSourceDrag>(
      onWillAcceptWithDetails: (DragTargetDetails<_ImportSourceDrag> d) =>
          d.data.index != index,
      onAcceptWithDetails: (DragTargetDetails<_ImportSourceDrag> d) =>
          onReorder(d.data.index, index),
      builder:
          (
            BuildContext context,
            List<_ImportSourceDrag?> candidates,
            List<dynamic> _,
          ) {
            final Widget handle = _ImportSourceDragHandle(
              index: index,
              count: count,
              onReorder: onReorder,
              feedback: Material(
                type: MaterialType.transparency,
                child: SizedBox(
                  width: tileWidth,
                  child: Opacity(
                    opacity: 0.92,
                    child: entry.builder(context, null),
                  ),
                ),
              ),
            );
            final Widget tile = entry.builder(context, handle);
            if (candidates.isEmpty) return tile;
            return DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: cs.primary, width: 3),
              ),
              child: tile,
            );
          },
    );
  }
}

@immutable
class _ImportSourceDrag {
  const _ImportSourceDrag(this.index);

  final int index;
}

/// 拖动手柄（MD3 ⠿ / Apple ≡）：视觉 28、命中区 48；按下即拖（[Draggable]，不等
/// 长按），可聚焦，Alt+↑/↓ 与读屏「上移 / 下移」动作移动一格。
class _ImportSourceDragHandle extends StatelessWidget {
  const _ImportSourceDragHandle({
    required this.index,
    required this.count,
    required this.onReorder,
    required this.feedback,
  });

  final int index;
  final int count;
  final void Function(int from, int to) onReorder;
  final Widget feedback;

  void _move(int delta) {
    final int to = index + delta;
    if (to < 0 || to >= count) return;
    onReorder(index, to);
  }

  @override
  Widget build(BuildContext context) {
    final Color color =
        DefaultTextStyle.of(context).style.color ??
        Theme.of(context).colorScheme.onSurface;
    final Widget glyph = SizedBox.square(
      dimension: 48,
      child: Center(
        child: FushiIcon(
          isGlassDesign(context)
              ? FushiIcons.dragHandle
              : FushiIcons.dragIndicator,
          size: 20,
          color: color.withValues(alpha: 0.75),
        ),
      ),
    );
    return Semantics(
      label: t.tag_manage_reorder_hint,
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        if (index > 0) CustomSemanticsAction(label: t.move_up): () => _move(-1),
        if (index < count - 1)
          CustomSemanticsAction(label: t.move_down): () => _move(1),
      },
      child: FocusableActionDetector(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowUp, alt: true):
              _MoveSourceIntent(-1),
          SingleActivator(LogicalKeyboardKey.arrowDown, alt: true):
              _MoveSourceIntent(1),
        },
        actions: <Type, Action<Intent>>{
          _MoveSourceIntent: CallbackAction<_MoveSourceIntent>(
            onInvoke: (_MoveSourceIntent intent) {
              _move(intent.delta);
              return null;
            },
          ),
        },
        mouseCursor: SystemMouseCursors.grab,
        child: Draggable<_ImportSourceDrag>(
          data: _ImportSourceDrag(index),
          feedback: feedback,
          child: glyph,
        ),
      ),
    );
  }
}

class _MoveSourceIntent extends Intent {
  const _MoveSourceIntent(this.delta);

  final int delta;
}
