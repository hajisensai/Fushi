import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_controller.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_mosaic.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_sections.dart';
import 'package:fushi/src/mining/advanced_mining/manga_crop_geometry.dart';
import 'package:fushi/src/mining/advanced_mining/manga_crop_selector.dart';
import 'package:fushi/src/utils/components/fushi_pill_segmented_button.dart'
    show
        FushiPillSegmentedButton,
        fushiPillSegmentSelectedFill,
        fushiPillSegmentSelectedForeground;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show MiningMosaicRegion;

/// 没拿到建议（页尺寸未知）时的占位纵横比：B5 漫画单页。
const Size kMangaFallbackPageSize = Size(1000, 1414);

/// 当前页的像素尺寸（建议框给的为准）。
Size mangaPageSizeOf(AdvancedMiningController c) =>
    c.cropSuggestions?.pageSize ?? kMangaFallbackPageSize;

/// 摘要行里的取景说明：`所在分镜 · 输出 820×934`。
String mangaCropSummary(AdvancedMiningController c) {
  final String label = mangaCropChoiceLabel(c.cropChoice);
  final Rect? rect = c.cropRect;
  if (rect == null) return label;
  final ({int width, int height}) px = cropOutputPixels(
    rect,
    mangaPageSizeOf(c),
  );
  return '$label · ${t.popup_advanced_mining_crop_output(width: px.width, height: px.height)}';
}

/// 下载分镜模型并在失败时如实提示（成功后控制器自己切到「所在分镜」）。
Future<void> downloadMangaPanelModel(AdvancedMiningController c) async {
  final bool ok = await c.downloadPanelModel();
  if (!ok) {
    FushiToast.show(
      msg: t.popup_advanced_mining_crop_download_failed,
      severity: ToastSeverity.warning,
    );
  }
}

/// 「未下载分镜模型」提示 + 下载入口（下载中显示进度）。
class MangaPanelModelNotice extends StatelessWidget {
  const MangaPanelModelNotice({super.key, required this.controller});

  final AdvancedMiningController controller;

  @override
  Widget build(BuildContext context) {
    final AdvancedMiningController c = controller;
    final AdvancedMiningMangaImageSection section = c.mangaSection!;
    final int? received = c.downloadedBytes;
    final int? total = section.panelModelSizeBytes;
    final List<Widget> actions = <Widget>[];
    if (received != null) {
      actions.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox.square(
              dimension: 18,
              child: FushiCircularProgressIndicator(
                strokeWidth: 2.5,
                value: total == null || total <= 0
                    ? null
                    : (received / total).clamp(0.0, 1.0),
              ),
            ),
            const SizedBox(width: 8),
            Text(t.popup_advanced_mining_crop_downloading),
          ],
        ),
      );
    } else if (section.downloadPanelModel != null) {
      actions.add(
        FushiTextButton.icon(
          onPressed: c.locked
              ? null
              : () => unawaited(downloadMangaPanelModel(c)),
          icon: const FushiIcon(FushiIcons.download, size: 18),
          label: Text(
            t.popup_advanced_mining_crop_download_model(
              size: FushiByteFormat.bytes(total),
            ),
          ),
        ),
      );
    }
    return FushiInlineNotice(
      message: t.popup_advanced_mining_crop_no_model,
      actions: actions,
    );
  }
}

/// 裁切工作区：取景选项 + 无模型提示 + 原页图上的框选控件 + 图例 / 操作提示。
///
/// 宽屏左栏与手机全屏框选页共用；[compactChoices] 时选项用分段（手机），否则用
/// 胶囊（桌面，与音频 / 视频分区同一形态）。
class MangaCropWorkspace extends StatelessWidget {
  const MangaCropWorkspace({
    super.key,
    required this.controller,
    this.touch = false,
    this.onSubmit,
    this.autofocusSelector = false,
    this.header,
  });

  final AdvancedMiningController controller;

  /// 工作区顶部的取景选项（桌面胶囊）；放在标题行右侧会在 5 个选项时折行、把
  /// 标题挤歪，所以单独占一行。
  final Widget? header;
  final bool touch;
  final VoidCallback? onSubmit;
  final bool autofocusSelector;

  @override
  Widget build(BuildContext context) {
    final AdvancedMiningController c = controller;
    final MangaCropSuggestions? s = c.cropSuggestions;
    final Widget canvas = c.mangaLoading
        ? const Center(child: FushiLoadingView(compact: true))
        : MangaCropSelector(
            pageBytes: c.pageBytes,
            pageSize: mangaPageSizeOf(c),
            selection: c.cropRect,
            panels: s?.panels ?? const <Rect>[],
            textRect: s?.textRect,
            mosaic: c.mosaicApplicable
                ? c.mosaicRegions
                : const <MiningMosaicRegion>[],
            enabled: !c.locked && c.cropChoice != MangaCropChoice.none,
            autofocus: autofocusSelector,
            touch: touch,
            onSubmit: onSubmit,
            onChanged: (Rect rect, MangaCropEdit edit) => c.setCropRect(
              rect,
              fromPanelCycle: edit == MangaCropEdit.panel,
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (header != null) ...<Widget>[header!, const SizedBox(height: 10)],
        if (!c.panelModelAvailable && !c.mangaLoading) ...<Widget>[
          MangaPanelModelNotice(controller: c),
          const SizedBox(height: 10),
        ],
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              // 页图垫底用搜索面（比分区卡高一阶），页面四周留白才看得出边界。
              color: FushiDesignTokens.of(context).surfaces.search,
              borderRadius: const BorderRadius.all(Radius.circular(14)),
            ),
            child: Padding(padding: const EdgeInsets.all(12), child: canvas),
          ),
        ),
        const SizedBox(height: 10),
        // 打码对着**整页原图**框（与取景框同一坐标系，先打码再裁）；编辑页里把取景框
        // 外压暗，框外的码会被裁掉。选了「不要」时没有图可打。
        if (!c.mangaLoading &&
            c.pageBytes != null &&
            c.mosaicApplicable) ...<Widget>[
          AdvancedMiningMosaicBar(
            controller: c,
            loadBytes: () async => c.pageBytes,
            focusRect: c.cropRect,
          ),
          const SizedBox(height: 8),
        ],
        _MangaCropLegend(touch: touch),
      ],
    );
  }
}

/// 桌面取景选项胶囊（整页 / 所在分镜 / 文字周围 / 自定义 / 不要）。没有对应框的
/// 方式不显示，而不是给一个点了没反应的选项。
class MangaCropChoiceChips extends StatelessWidget {
  const MangaCropChoiceChips({super.key, required this.controller});

  final AdvancedMiningController controller;

  @override
  Widget build(BuildContext context) {
    final AdvancedMiningController c = controller;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final MangaCropChoice choice in MangaCropChoice.values)
          if (c.isCropChoiceAvailable(choice))
            AdvancedMiningChoiceChip(
              label: mangaCropChoiceLabel(choice),
              selected: c.cropChoice == choice,
              onSelected: c.locked || c.mangaLoading
                  ? null
                  : () => c.selectCropChoice(choice),
            ),
      ],
    );
  }
}

class _MangaCropLegend extends StatelessWidget {
  const _MangaCropLegend({required this.touch});

  final bool touch;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle style = context.fushiType.labelMedium.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 14,
              height: 0,
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: scheme.primary, width: 1.5),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(t.popup_advanced_mining_crop_legend_panels, style: style),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.all(Radius.circular(3)),
                border: Border.all(color: kMangaCropTextRectColor, width: 2),
              ),
            ),
            const SizedBox(width: 6),
            Text(t.popup_advanced_mining_crop_legend_text, style: style),
          ],
        ),
        Text(t.popup_advanced_mining_crop_hint, style: style),
      ],
    );
  }
}

/// 「卡片上的样子」：按当前框把原页图裁出来的缩略 + 输出尺寸。框变化时补间过去，
/// 与左边框选同步移动。
class MangaCropPreviewPanel extends StatelessWidget {
  const MangaCropPreviewPanel({super.key, required this.controller});

  final AdvancedMiningController controller;

  @override
  Widget build(BuildContext context) {
    final AdvancedMiningController c = controller;
    final Rect? rect = c.cropRect;
    final Size page = mangaPageSizeOf(c);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget body;
    if (rect == null) {
      body = Text(
        t.popup_advanced_mining_image_none,
        style: context.fushiType.bodyMedium.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    } else {
      final ({int width, int height}) px = cropOutputPixels(rect, page);
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          MangaCropThumbnail(
            bytes: c.pageBytes,
            pageSize: page,
            rect: rect,
            mosaic: c.mosaicRegions,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              t.popup_advanced_mining_crop_output(
                width: px.width,
                height: px.height,
              ),
              style: context.fushiType.labelMedium.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    }
    return AdvancedMiningSectionShell(
      title: t.popup_advanced_mining_crop_preview,
      child: body,
    );
  }
}

/// 把原页图的 [rect] 那一块按比例画进一个最大 [maxSize] 的小框。
class MangaCropThumbnail extends StatelessWidget {
  const MangaCropThumbnail({
    super.key,
    required this.bytes,
    required this.pageSize,
    required this.rect,
    this.maxSize = const Size(112, 140),
    this.mosaic = const <MiningMosaicRegion>[],
  });

  final Uint8List? bytes;
  final Size pageSize;
  final Rect rect;
  final Size maxSize;

  /// 打码区域（相对整页）：缩略图画成卡上的样子。
  final List<MiningMosaicRegion> mosaic;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<Rect?>(
    tween: RectTween(end: rect),
    duration: context.fushiMotion.spatialDefault.duration,
    curve: context.fushiMotion.spatialDefault.curve,
    builder: (BuildContext context, Rect? r, Widget? _) {
      final Rect crop = clampCropRect(r ?? rect, minExtent: 0.01);
      final Size cropPx = Size(
        crop.width * pageSize.width,
        crop.height * pageSize.height,
      );
      final Rect box = containRect(cropPx, maxSize);
      final double scale = box.width / cropPx.width;
      return ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: SizedBox(
          width: box.width,
          height: box.height,
          child: ColoredBox(
            color: FushiDesignTokens.of(context).surfaces.overlay,
            child: bytes == null
                ? null
                : OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: 0,
                    minHeight: 0,
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    child: Transform.translate(
                      offset: Offset(
                        -crop.left * pageSize.width * scale,
                        -crop.top * pageSize.height * scale,
                      ),
                      child: SizedBox(
                        width: pageSize.width * scale,
                        height: pageSize.height * scale,
                        child: mosaic.isNotEmpty
                            ? MiningMosaicImage(
                                bytes: bytes,
                                regions: mosaic,
                                fit: BoxFit.fill,
                              )
                            : Image.memory(
                                bytes!,
                                fit: BoxFit.fill,
                                gaplessPlayback: true,
                                errorBuilder:
                                    (BuildContext _, Object _, StackTrace? _) =>
                                        const SizedBox.shrink(),
                              ),
                      ),
                    ),
                  ),
          ),
        ),
      );
    },
  );
}

/// 手机全屏框选页（交互稿 ④）：顶栏 ×（放弃本页改动）/ 「完成」，中间原页图框选，
/// 底部分段「整页 / 所在分镜（没有时文字周围）/ 自定义 / 不要」。
///
/// 直接操作同一个控制器：「完成」即保留，「×」按进页时的快照还原——窄屏摘要行的
/// 取景说明与确认产出都只认控制器这一份状态。
class MangaCropFullscreenPage extends StatefulWidget {
  const MangaCropFullscreenPage({super.key, required this.controller});

  final AdvancedMiningController controller;

  /// 以从下往上的滑入转场推出全屏页（共享轴语义：它是对话框的下一层）。
  static Future<void> open(
    BuildContext context,
    AdvancedMiningController controller,
  ) {
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    return Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder<void>(
        fullscreenDialog: true,
        transitionDuration: duration,
        reverseTransitionDuration: fushiMotionDuration(
          context,
          FushiMotion.longReverse,
        ),
        pageBuilder:
            (BuildContext context, Animation<double> a, Animation<double> b) =>
                MangaCropFullscreenPage(controller: controller),
        transitionsBuilder:
            (
              BuildContext context,
              Animation<double> animation,
              Animation<double> secondary,
              Widget child,
            ) {
              final Animation<double> curved = CurvedAnimation(
                parent: animation,
                curve: FushiMotion.enter,
                reverseCurve: FushiMotion.exit,
              );
              return FadeTransition(
                opacity: curved,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.06),
                    end: Offset.zero,
                  ).animate(curved),
                  child: child,
                ),
              );
            },
      ),
    );
  }

  @override
  State<MangaCropFullscreenPage> createState() =>
      _MangaCropFullscreenPageState();
}

class _MangaCropFullscreenPageState extends State<MangaCropFullscreenPage> {
  late final ({MangaCropChoice choice, Rect custom}) _snapshot = widget
      .controller
      .snapshotCrop();
  bool _done = false;

  void _close({required bool keep}) {
    _done = true;
    if (!keep) widget.controller.restoreCrop(_snapshot);
    Navigator.of(context).pop();
  }

  /// 底部分段的第二段：有所在分镜就是它，否则退到文字周围（交互稿 ④ 无模型回退态）。
  MangaCropChoice get _suggestedChoice =>
      widget.controller.isCropChoiceAvailable(MangaCropChoice.panel)
      ? MangaCropChoice.panel
      : MangaCropChoice.textArea;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    // 系统返回 = 「×」放弃（不是「完成」）：与顶栏关闭键同一语义。
    onPopInvokedWithResult: (bool didPop, Object? _) {
      if (!didPop && !_done) _close(keep: false);
    },
    child: ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? _) {
        final AdvancedMiningController c = widget.controller;
        final List<MangaCropChoice> segments = <MangaCropChoice>[
          MangaCropChoice.wholePage,
          if (c.isCropChoiceAvailable(_suggestedChoice)) _suggestedChoice,
          MangaCropChoice.custom,
          MangaCropChoice.none,
        ];
        return Scaffold(
          appBar: FushiAppBar(
            leading: FushiIconButtonControl(
              tooltip: t.popup_ctx_cancel,
              onPressed: () => _close(keep: false),
              icon: const FushiIcon(FushiIcons.close),
            ),
            // 窄屏英文「Select image area」放不下时缩小而不是省略号。
            title: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(t.popup_advanced_mining_crop_page_title),
            ),
            // 不自带尾部留白：M3E 悬浮顶栏把 actions 收进一枚胶囊、自己在胶囊外留
            // 边距，这里再包 Padding 会落进胶囊里，按钮偏左（BUG-3410）。
            actions: <Widget>[
              FushiFilledButton(
                onPressed: () => _close(keep: true),
                child: Text(t.popup_advanced_mining_crop_done),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: MangaCropWorkspace(
                      controller: c,
                      touch: true,
                      autofocusSelector: true,
                      onSubmit: () => _close(keep: true),
                    ),
                  ),
                  const SizedBox(height: 12),
                  MangaCropChoiceSegments(
                    choices: segments,
                    selected: c.cropChoice,
                    onSelected: c.locked ? null : c.selectCropChoice,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// 手机全屏框选页底部的取景分段（交互稿 ④）。
///
/// 不直接用 [FushiPillSegmentedButton]：它的段按最宽一段等宽、左右各留 16 内边距，
/// 文字放不下就省略号——四段中文在 390 宽已截成「文字周…」，英文在 360 宽更紧。
/// 这里轨道撑满整行、段内边距收到 6，标签放不下时整体等比缩小（FittedBox
/// scaleDown），任何一段都不出现省略号。外观（轨道色、选中 primary 胶囊、按压
/// 状态层与切换动画）与共享分段同源。
class MangaCropChoiceSegments extends StatelessWidget {
  const MangaCropChoiceSegments({
    super.key,
    required this.choices,
    required this.selected,
    required this.onSelected,
  });

  /// 段高与轨道内边距：与共享胶囊分段同一几何。
  static const double segmentHeight = FushiPillSegmentedButton.segmentHeight;
  static const double trackPadding = FushiPillSegmentedButton.trackPadding;

  /// 段内左右留白（共享分段是 16）。
  static const double labelPadding = 6;

  final List<MangaCropChoice> choices;
  final MangaCropChoice selected;

  /// null = 锁住（与宿主往返中）。
  final ValueChanged<MangaCropChoice>? onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    final TextStyle base = (theme.textTheme.labelLarge ?? const TextStyle())
        .copyWith(height: 1.2);
    Widget segment(MangaCropChoice choice) {
      final bool on = choice == selected;
      final bool enabled = onSelected != null;
      final Color fg = !enabled
          ? cs.onSurface.withValues(alpha: 0.38)
          : on
          ? fushiPillSegmentSelectedForeground(cs, eink: eink)
          : cs.onSurfaceVariant;
      const ShapeBorder pill = StadiumBorder();
      return Semantics(
        button: true,
        selected: on,
        enabled: enabled,
        inMutuallyExclusiveGroup: true,
        child: Material(
          type: MaterialType.transparency,
          shape: pill,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: pill,
            onTap: enabled ? () => onSelected!(choice) : null,
            child: AnimatedContainer(
              duration: duration,
              curve: FushiMotion.standard,
              height: segmentHeight,
              padding: const EdgeInsets.symmetric(horizontal: labelPadding),
              alignment: Alignment.center,
              decoration: ShapeDecoration(
                color: fushiPillSegmentSelectedFill(
                  cs,
                  eink: eink,
                ).withValues(alpha: on ? 1 : 0),
                shape: pill,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  mangaCropChoiceLabel(choice),
                  maxLines: 1,
                  softWrap: false,
                  style: base.copyWith(
                    color: fg,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return DecoratedBox(
      decoration: ShapeDecoration(
        color: FushiDesignTokens.of(context).surfaces.search,
        shape: StadiumBorder(
          side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(trackPadding),
        child: Row(
          children: <Widget>[
            for (final MangaCropChoice choice in choices)
              Expanded(child: segment(choice)),
          ],
        ),
      ),
    );
  }
}
