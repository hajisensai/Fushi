/// Apple（Cupertino，iOS 27 / macOS 27）导入页：2026-11-24 用户拍板方案 A
/// （「设置」式分组列表，效果图 `build/import_cupertino_design/index.html`）。
///
/// - 页名「导入」由库页外壳的大标题给（`AppleLibraryLayout` 停在导入页时换标题），
///   本页首行是副标题「到 〈库名〉 · 支持 n 种格式 ⓘ」（点 ⓘ 出格式气泡）；
/// - 「添加到〈库〉」组：本地方式（主方式排第一行，图标与其余行同一种中性样式），组脚注是原引导
///   首块的说明（能拖放时提拖放）；
/// - 「网络与服务器」组：网络共享（spec 里的网络方式）+ 连接服务器 + Fushi 互联
///   （+ 漫画的浏览对端漫画库），后几行来自来源区；
/// - 「常驻来源」组：来源区（`MediaSourcesView`）交出数据，由
///   [AppleImportSourcesSection] 画，带 Apple「编辑」模式；
/// - macOS 档宽窗双栏：左「添加 + 网络」、右「常驻来源」；
/// - 拖放：只在文件拖进窗口时出现 [AppleImportDropOverlay]，其余压暗；
/// - 查词空态（没有库名的 spec）：ContentUnavailableView 式图标 + 标题 + 说明，
///   下面一组方式行。
///
/// 动效：组为单位错峰进场（[FushiStaggeredEntrance]），行按压 [FushiPressScale]
/// （行内）。只在 `isGlassDesign` 为真时由 `ImportPageLayout` 选用。
library;

import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/import/apple/apple_import_drop_overlay.dart';
import 'package:fushi/src/media/import/apple/apple_import_rows.dart';
import 'package:fushi/src/media/import/apple/apple_import_sources.dart';
import 'package:fushi/src/media/import/import_collage_blocks.dart'
    show showImportFormatBubble;
import 'package:fushi/src/media/import/import_run_controller.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// spec 所属库的显示名（副标题「到 X」与「添加到 X」）；查词空态等不属于库页的
/// 导入面为 null（走 ContentUnavailableView 式头部）。
String? appleImportLibraryName(String specId) => switch (specId) {
  'book' => t.books,
  'manga' => t.manga_library,
  'video' => t.nav_video,
  'music' => t.nav_music,
  'game' => t.nav_game,
  _ => null,
};

/// macOS 档宽窗双栏的最小内容宽。
const double kAppleImportTwoColumnMinWidth = 860;

/// 双栏每栏的最大宽（macOS 系统设置表单列宽量级）与栏间距。
const double kAppleImportColumnMaxWidth = 520;
const double kAppleImportColumnGap = 28;

class AppleImportLayout extends StatefulWidget {
  const AppleImportLayout({
    required this.spec,
    this.sources,
    this.scrollable = true,
    super.key,
  });

  final ImportSurfaceSpec spec;
  final Widget? sources;
  final bool scrollable;

  @override
  State<AppleImportLayout> createState() => _AppleImportLayoutState();
}

class _AppleImportLayoutState extends State<AppleImportLayout> {
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

  List<ImportMethod> get _localMethods => <ImportMethod>[
    for (final ImportMethod m in widget.spec.methods)
      if (m.kind != ImportMethodKind.network) m,
  ];

  List<ImportMethod> get _networkMethods => <ImportMethod>[
    for (final ImportMethod m in widget.spec.methods)
      if (m.kind == ImportMethodKind.network) m,
  ];

  Widget _methodRow(ImportMethod method, {String? title}) =>
      AppleImportMethodRow(
        method: method,
        title: title,
        busy: _runs.isBusy(method),
        dimmed: _runs.isDimmed(method),
        onTap: () => unawaited(_runs.run(method)),
      );

  Widget _footnote(BuildContext context, String text) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.symmetric(
        horizontal: metrics.rowHorizontal,
      ),
      child: Text(text, style: metrics.footnoteStyle(context)),
    );
  }

  /// 「添加到〈库〉」组（查词空态：无组名，脚注是格式链接）。
  Widget _addSection(BuildContext context, String? library) {
    final ImportSurfaceSpec spec = widget.spec;
    final String description = _dropEnabled
        ? spec.guideDescription
        : spec.guideDescriptionWithoutDrop ?? spec.guideDescription;
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('import-apple-add-section'),
      title: library == null ? null : t.import_section_add_to(library: library),
      footer: library == null
          ? (spec.formatCount > 0
                ? Padding(
                    padding: EdgeInsetsDirectional.symmetric(
                      horizontal: FushiAppleMetrics.of(context).rowHorizontal,
                    ),
                    child: _FormatsLink(spec: spec),
                  )
                : null)
          : _footnote(context, description),
      children: <Widget>[
        for (final ImportMethod m in _localMethods) _methodRow(m),
      ],
    );
  }

  /// 「网络与服务器」组；没有任何行时为 null。
  Widget? _networkSection(BuildContext context, AppleImportSourcesData? data) {
    final List<Widget> rows = <Widget>[
      for (final ImportMethod m in _networkMethods)
        _methodRow(m, title: t.import_method_network_share),
      if (data != null) ...appleImportNetworkRows(context, data),
    ];
    if (rows.isEmpty) return null;
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('import-apple-network-section'),
      title: t.import_section_network,
      children: rows,
    );
  }

  /// 方式组 + 来源组的版式（[data] 为 null = 没有来源区交数据）。
  Widget _compose(BuildContext context, AppleImportSourcesData? data) {
    final String? library = appleImportLibraryName(widget.spec.id);
    final Widget add = FushiStaggeredEntrance(
      index: 1,
      child: _addSection(context, library),
    );
    final Widget? networkSection = _networkSection(context, data);
    final Widget? network = networkSection == null
        ? null
        : FushiStaggeredEntrance(index: 2, child: networkSection);
    final Widget? sources = data == null
        ? null
        : FushiStaggeredEntrance(
            index: 3,
            child: AppleImportSourcesSection(data: data),
          );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Widget? right = sources;
        final bool twoColumns =
            right != null &&
            fushiAppleUsesMacMetrics(context) &&
            constraints.maxWidth >= kAppleImportTwoColumnMinWidth;
        if (!twoColumns) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[add, ?network, ?sources],
          );
        }
        // macOS「系统设置」式两栏：两栏等宽、各不超过 [kAppleImportColumnMaxWidth]，
        // 靠起始边排（宽窗不把右栏拉满到窗口边）；两栏顶部都是组外标题，
        // 走同一套 AdaptiveSettingsSection 标题度量，标题基线与卡片顶边齐平。
        final double column = math.min(
          kAppleImportColumnMaxWidth,
          (constraints.maxWidth - kAppleImportColumnGap) / 2,
        );
        return Row(
          key: const ValueKey<String>('import-apple-two-columns'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: column,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[add, ?network],
              ),
            ),
            const SizedBox(width: kAppleImportColumnGap),
            SizedBox(width: column, child: right),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ImportSurfaceSpec spec = widget.spec;
    final String? library = appleImportLibraryName(spec.id);
    final Widget? sources = widget.sources;
    final Widget header = FushiStaggeredEntrance(
      index: 0,
      child: library == null
          ? _AppleImportUnavailableHeader(spec: spec)
          : _AppleImportHeader(spec: spec, library: library),
    );
    final Widget groups;
    final Object? composer = sources;
    if (sources != null &&
        composer is AppleImportSourcesComposer &&
        composer.composesAppleImport) {
      groups = AppleImportScope(compose: _compose, child: sources);
    } else {
      groups = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[_compose(context, null), ?sources],
      );
    }
    final bool dropEnabled = _dropEnabled;
    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[header, const SizedBox(height: 16), groups],
    );
    if (widget.scrollable) {
      final FushiDesignTokens tokens = FushiDesignTokens.of(context);
      content = SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          FushiFloatingChromeInset.of(context) + tokens.spacing.gap,
          tokens.spacing.page,
          tokens.spacing.page,
        ),
        child: content,
      );
    }
    Widget body = FushiEntranceScope(child: content);
    final FileDropCallback? onDrop = spec.onDrop;
    if (onDrop != null) {
      if (dropEnabled) {
        body = _AppleImportDropStage(child: body);
      }
      body = FushiFileDropTarget(
        debugLabel: 'import-${spec.id}',
        onDrop: onDrop,
        child: body,
      );
    }
    return body;
  }
}

/// 拖放态舞台：内容压暗 + 覆盖层（读最近一层落点的悬停态）。
class _AppleImportDropStage extends StatelessWidget {
  const _AppleImportDropStage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool dragging = FushiFileDropTarget.dragHoveringOf(context);
    return Stack(
      children: <Widget>[
        AnimatedOpacity(
          opacity: dragging ? 0.45 : 1,
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          child: child,
        ),
        Positioned.fill(child: AppleImportDropOverlay(visible: dragging)),
      ],
    );
  }
}

/// 库页导入页的副标题行：「到 〈库名〉 · 支持 n 种格式 ⓘ」。
class _AppleImportHeader extends StatelessWidget {
  const _AppleImportHeader({required this.spec, required this.library});

  final ImportSurfaceSpec spec;
  final String library;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final TextStyle style = appleImportSecondaryStyle(context);
    return Padding(
      padding: EdgeInsetsDirectional.symmetric(
        horizontal: metrics.rowHorizontal,
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 2,
        children: <Widget>[
          Text(
            t.import_header_destination(library: library),
            key: const ValueKey<String>('import-apple-destination'),
            style: style,
          ),
          if (spec.formatCount > 0) ...<Widget>[
            Text('·', style: style),
            _FormatsLink(spec: spec, style: style),
          ],
        ],
      ),
    );
  }
}

/// 「支持 n 种格式 ⓘ」：次要文字色 + 强调色小 ⓘ（整段可点），点开格式气泡（与 M3E 同一个
/// [showImportFormatBubble]）。
class _FormatsLink extends StatelessWidget {
  const _FormatsLink({required this.spec, this.style});

  final ImportSurfaceSpec spec;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    final TextStyle base =
        style ?? FushiAppleMetrics.of(context).footnoteStyle(context);
    return Semantics(
      button: true,
      child: GestureDetector(
        key: ValueKey<String>('import-formats-${spec.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(
          showImportFormatBubble(
            context: context,
            groups: spec.formatGroups,
            pickOnlyGroups: spec.pickOnlyFormatGroups,
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 3,
            children: <Widget>[
              Text(
                t.import_formats_supported_count(n: spec.formatCount),
                style: base.copyWith(color: colors.secondaryLabel),
              ),
              FushiIcon(
                FushiIcons.info,
                size: (base.fontSize ?? 13) - 1,
                color: colors.accent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 查词空态的头部（ContentUnavailableView 式）：大图标 + 标题 + 说明。
class _AppleImportUnavailableHeader extends StatelessWidget {
  const _AppleImportUnavailableHeader({required this.spec});

  final ImportSurfaceSpec spec;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors colors = appleColorsOf(context);
    final bool drop = spec.onDrop != null && isDesktopPlatform;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(spec.guideIcon, size: 54, color: colors.tertiaryLabel),
          const SizedBox(height: 12),
          Text(
            spec.guideTitle,
            textAlign: TextAlign.center,
            style: context.fushiType.titleLargeEmphasized.copyWith(
              color: colors.label,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            drop
                ? spec.guideDescription
                : spec.guideDescriptionWithoutDrop ?? spec.guideDescription,
            textAlign: TextAlign.center,
            style: metrics.subtitleStyle(context),
          ),
        ],
      ),
    );
  }
}
