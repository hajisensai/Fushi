/// 导入面页面骨架（导入稿 v2「ImportCollagePage」，现名 [MaterialImportLayout]）：书 / 漫画 / 视频 / 音乐 /
/// 游戏的「导入」视图与查词「一本词典都没有」的空态共用。只接一份
/// [ImportSurfaceSpec] 和一个可选的来源区（`MediaSourcesView` 的色块呈现）。
///
/// - 版式按真实宽度断点取（[ImportCollageLayout]，稿断点表），任何宽度不出空洞；
/// - spec 给了 [ImportSurfaceSpec.onDrop] 时整页包 [FushiFileDropTarget]（IM2：
///   之前导入视图祖先链上没有落点却画着拖放虚线），落下交给该模块库页现有的
///   onDrop，不另写分发；外层仍由库页壳套 `DropSurfaceScope`；
/// - 拖放态：引导首块浮起、虚线变实线、标题换「松手导入」，其余块压暗；
/// - 进场：0 引导首块 → 1..n 方式块 → n+1 区头 → 来源块（[ImportSurfaceSpec
///   .sourceEntranceIndex] 起），错峰序号连续。
library;

import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/import/import_collage_blocks.dart';
import 'package:fushi/src/media/import/import_run_controller.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 某个宽度档 + 方式数下的版式（稿断点表 R14 / R15）。纯数据，便于单测。
@immutable
class ImportCollageLayout {
  const ImportCollageLayout({
    required this.sizeClass,
    required this.guideOwnRow,
    required this.guideSpan,
    required this.guideBanner,
    required this.guideMinHeight,
    required this.methodColumns,
    required this.methodMinHeight,
    required this.lastMethodWide,
    required this.sourceColumns,
    required this.showMethodDetails,
  });

  /// - expanded（≥840）：N ≤ 4 时引导首块与方式块同一行，6 列里首块占 6 − N
  ///   （最少 2 列）、方式块各占 1 列；N ≥ 5 时首块独占一行做横幅（高 128），
  ///   方式块一行 N 等分。来源区 3 列。
  /// - medium（600–839）：首块独占一行（高 132）；N = 3 直接 3 列，其余 2 列、
  ///   N 为奇数时最后一块横排占满一行。来源区 2 列。
  /// - compact（<600）：首块独占一行；方式块同 medium，只留名称 + 箭头。来源区
  ///   1 列。
  factory ImportCollageLayout.resolve(WindowSizeClass sizeClass, int methods) {
    final int n = methods < 1 ? 1 : methods;
    switch (sizeClass) {
      case WindowSizeClass.expanded:
        final bool banner = n >= 5;
        return ImportCollageLayout(
          sizeClass: sizeClass,
          guideOwnRow: banner,
          guideSpan: banner ? 6 : (6 - n < 2 ? 2 : 6 - n),
          guideBanner: banner,
          guideMinHeight: banner ? 128 : 206,
          methodColumns: n,
          methodMinHeight: banner ? 196 : 206,
          lastMethodWide: false,
          sourceColumns: 3,
          showMethodDetails: true,
        );
      case WindowSizeClass.medium:
      case WindowSizeClass.compact:
        final bool compact = sizeClass == WindowSizeClass.compact;
        final int columns = n == 3 ? 3 : 2;
        return ImportCollageLayout(
          sizeClass: sizeClass,
          guideOwnRow: true,
          guideSpan: columns,
          guideBanner: false,
          guideMinHeight: compact ? 140 : 132,
          methodColumns: columns,
          methodMinHeight: compact ? 124 : 150,
          lastMethodWide: columns == 2 && n.isOdd,
          sourceColumns: compact ? 1 : 2,
          showMethodDetails: !compact,
        );
    }
  }

  final WindowSizeClass sizeClass;
  final bool guideOwnRow;

  /// 与方式块同行时首块占的列数（6 列制）。
  final int guideSpan;
  final bool guideBanner;
  final double guideMinHeight;
  final int methodColumns;
  final double methodMinHeight;
  final bool lastMethodWide;
  final int sourceColumns;
  final bool showMethodDetails;

  bool get compact => sizeClass == WindowSizeClass.compact;
}

/// 导入面页面骨架（见文件头）：M3E 拼贴版，经 `ImportPageLayout` 在非 Cupertino
/// 主题下选用（2026-11-24 起 Cupertino 主题走 `AppleImportLayout`）。
///
/// [sources] 是来源区（通常是 `MediaSourcesView(presentation: blocks)`）；为空时
/// 没有来源区（查词空态）。[onAddSource] 非空时区头右侧有「＋ 添加来源」。
/// [scrollable] = false 时不自带滚动与顶部浮动栏让位（嵌进别的滚动页，如查词
/// 主页的空态）。
class MaterialImportLayout extends StatefulWidget {
  const MaterialImportLayout({
    required this.spec,
    this.sources,
    this.onAddSource,
    this.addSourceEnabled = true,
    this.scrollable = true,
    super.key,
  });

  final ImportSurfaceSpec spec;
  final Widget? sources;
  final VoidCallback? onAddSource;
  final bool addSourceEnabled;
  final bool scrollable;

  @override
  State<MaterialImportLayout> createState() => _MaterialImportLayoutState();
}

class _MaterialImportLayoutState extends State<MaterialImportLayout> {
  /// 正在跑的方式（任何方式在跑都挡住重复点击；与 Apple 布局共用的状态）。
  final ImportRunController _runs = ImportRunController();

  @override
  void initState() {
    super.initState();
    _runs.addListener(_onRunsChanged);
  }

  void _onRunsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _runs
      ..removeListener(_onRunsChanged)
      ..dispose();
    super.dispose();
  }

  bool get _dropEnabled => widget.spec.onDrop != null && isDesktopPlatform;

  @override
  Widget build(BuildContext context) {
    final ImportSurfaceSpec spec = widget.spec;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    Widget body = ImportToneScope(
      tone: spec.tone,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final ImportCollageLayout layout = ImportCollageLayout.resolve(
            windowSizeClassReal(
              constraints.maxWidth,
              FushiAppUiScale.of(context),
            ),
            spec.methods.length,
          );
          return _ImportCollageBody(
            spec: spec,
            layout: layout,
            dropEnabled: _dropEnabled,
            runningId: _runs.runningId,
            runningShowsProgress: _runs.runningShowsProgress,
            onRun: (ImportMethod m) => unawaited(_runs.run(m)),
            sources: widget.sources,
            onAddSource: widget.onAddSource,
            addSourceEnabled: widget.addSourceEnabled,
          );
        },
      ),
    );
    if (widget.scrollable) {
      body = SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          FushiFloatingChromeInset.of(context) + tokens.spacing.gap,
          tokens.spacing.page,
          tokens.spacing.page,
        ),
        child: body,
      );
    }
    body = FushiEntranceScope(child: body);
    final FileDropCallback? onDrop = spec.onDrop;
    if (onDrop != null) {
      body = FushiFileDropTarget(
        debugLabel: 'import-${spec.id}',
        onDrop: onDrop,
        child: body,
      );
    }
    return body;
  }
}

class _ImportCollageBody extends StatelessWidget {
  const _ImportCollageBody({
    required this.spec,
    required this.layout,
    required this.dropEnabled,
    required this.runningId,
    required this.runningShowsProgress,
    required this.onRun,
    required this.sources,
    required this.onAddSource,
    required this.addSourceEnabled,
  });

  final ImportSurfaceSpec spec;
  final ImportCollageLayout layout;
  final bool dropEnabled;
  final String? runningId;
  final bool runningShowsProgress;
  final ValueChanged<ImportMethod> onRun;
  final Widget? sources;
  final VoidCallback? onAddSource;
  final bool addSourceEnabled;

  @override
  Widget build(BuildContext context) {
    final double gap = FushiDesignTokens.of(context).spacing.gap + 4;
    final bool dragging =
        dropEnabled && FushiFileDropTarget.dragHoveringOf(context);
    final Duration fade = fushiMotionDuration(context, FushiMotion.short);
    Widget dim(Widget child) => AnimatedOpacity(
      opacity: dragging ? 0.45 : 1,
      duration: fade,
      curve: FushiMotion.standard,
      child: child,
    );

    final Widget guide = FushiStaggeredEntrance(
      index: 0,
      child: ImportGuideBlock(
        spec: spec,
        dropEnabled: dropEnabled,
        dragging: dragging,
        banner: layout.guideBanner,
        minHeight: layout.guideMinHeight,
        compact: layout.compact,
      ),
    );
    Widget method(int i, {bool wide = false}) {
      final ImportMethod m = spec.methods[i];
      final bool busy = runningShowsProgress && runningId == m.id;
      return FushiStaggeredEntrance(
        index: 1 + i,
        child: dim(
          ImportMethodBlock(
            method: m,
            moduleTone: spec.tone,
            onTap: () => onRun(m),
            showDetails: layout.showMethodDetails,
            wide: wide,
            busy: busy,
            dimmed: runningShowsProgress && runningId != m.id,
            minHeight: layout.methodMinHeight,
          ),
        ),
      );
    }

    final List<Widget> children = <Widget>[];
    final int n = spec.methods.length;
    if (!layout.guideOwnRow) {
      children.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(flex: layout.guideSpan, child: guide),
            for (int i = 0; i < n; i++) ...<Widget>[
              SizedBox(width: gap),
              Expanded(child: method(i)),
            ],
          ],
        ),
      );
    } else {
      children
        ..add(guide)
        ..add(SizedBox(height: gap));
      final int cols = layout.methodColumns;
      for (int start = 0; start < n; start += cols) {
        final int end = start + cols > n ? n : start + cols;
        final bool wideLast =
            layout.lastMethodWide && end == n && end - start == 1;
        if (start > 0) children.add(SizedBox(height: gap));
        if (wideLast) {
          children.add(method(start, wide: true));
          continue;
        }
        children.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (int i = start; i < end; i++) ...<Widget>[
                if (i > start) SizedBox(width: gap),
                Expanded(child: method(i)),
              ],
              // 不满一行时补位（只有 lastMethodWide 关掉的档才会走到）。
              for (int i = end; i < start + cols; i++) ...<Widget>[
                SizedBox(width: gap),
                const Expanded(child: SizedBox.shrink()),
              ],
            ],
          ),
        );
      }
    }

    final Widget? sourceArea = sources;
    if (sourceArea != null) {
      children
        ..add(const SizedBox(height: 28))
        ..add(
          FushiStaggeredEntrance(
            index: n + 1,
            child: dim(
              _ImportSourcesHeader(
                onAddSource: onAddSource,
                enabled: addSourceEnabled,
                compact: layout.compact,
              ),
            ),
          ),
        )
        ..add(const SizedBox(height: 8))
        ..add(dim(sourceArea));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

/// 来源区区头：「常驻来源」+ 右侧「＋ 添加来源」（高 40，命中区 ≥48）。
class _ImportSourcesHeader extends StatelessWidget {
  const _ImportSourcesHeader({
    required this.onAddSource,
    required this.enabled,
    required this.compact,
  });

  final VoidCallback? onAddSource;
  final bool enabled;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? add = onAddSource;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            t.media_source_section_title,
            style: context.fushiType.titleMediumEmphasized,
          ),
        ),
        if (add != null)
          FushiIconButton(
            key: const ValueKey<String>('import-sources-add'),
            tooltip: t.media_source_add,
            label: t.media_source_add,
            icon: FushiIcons.add,
            enabled: enabled,
            onTap: add,
          ),
      ],
    );
  }
}
