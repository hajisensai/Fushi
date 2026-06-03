import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/settings/cupertino_settings_renderer.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_renderer.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/utils.dart';

class SettingsHomePage extends BasePage {
  const SettingsHomePage({
    super.key,
    this.embedded = false,
    this.onBack,
  });

  final bool embedded;

  /// 非空时在内嵌页头左侧显示返回箭头（宽屏全屏设置切回来源 tab）。
  final VoidCallback? onBack;

  @override
  BasePageState<SettingsHomePage> createState() => _SettingsHomePageState();
}

class _SettingsHomePageState extends BasePageState<SettingsHomePage> {
  SettingsDestinationId _selectedDestinationId = SettingsDestinationId.reading;

  @override
  void initState() {
    super.initState();
    ErrorLogService.instance.addListener(_onLogChanged);
    DebugLogService.instance.addListener(_onLogChanged);
  }

  @override
  void dispose() {
    ErrorLogService.instance.removeListener(_onLogChanged);
    DebugLogService.instance.removeListener(_onLogChanged);
    super.dispose();
  }

  void _onLogChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final SettingsContext settingsContext = SettingsContext(
      context: context,
      appModel: appModel,
      ref: ref,
      readerSource: ReaderHibikiSource.instance,
      refresh: () {
        if (mounted) setState(() {});
      },
    );
    final List<SettingsDestination> destinations = buildSettingsSchema(
      settingsContext,
    )
        .where((SettingsDestination destination) =>
            destination.isVisible(settingsContext))
        .toList(growable: false);
    if (!destinations.any(
      (SettingsDestination destination) =>
          destination.id == _selectedDestinationId,
    )) {
      _selectedDestinationId = destinations.first.id;
    }
    final SettingsRenderer renderer = isCupertinoPlatform(context)
        ? const CupertinoSettingsRenderer()
        : const MaterialSettingsRenderer();

    final Widget content = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= 720) {
          return _buildWideLayout(
            settingsContext: settingsContext,
            renderer: renderer,
            destinations: destinations,
          );
        }
        return renderer.buildHomePage(
          settingsContext: settingsContext,
          destinations: destinations,
          selectedDestinationId: _selectedDestinationId,
          onDestinationSelected: _selectDestination,
          embedded: widget.embedded,
        );
      },
    );
    return DesktopContentLayout(
      kind: DesktopContentKind.settings,
      child: _buildEmbeddedMaterialShell(content),
    );
  }

  Widget _buildEmbeddedMaterialShell(Widget content) {
    if (!widget.embedded || isCupertinoPlatform(context)) {
      return content;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        HibikiPageHeader(
          title: t.settings,
          leading: widget.onBack != null
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: t.back,
                  onPressed: widget.onBack,
                )
              : null,
        ),
        Expanded(child: content),
      ],
    );
  }

  Widget _buildWideLayout({
    required SettingsContext settingsContext,
    required SettingsRenderer renderer,
    required List<SettingsDestination> destinations,
  }) {
    final SettingsDestination selected = destinations.firstWhere(
      (SettingsDestination destination) =>
          destination.id == _selectedDestinationId,
    );
    final bool cupertino = isCupertinoPlatform(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color dividerColor = cupertino
        ? CupertinoColors.separator.resolveFrom(context)
        : tokens.surfaces.outline;
    // MD3 list-detail: the nav pane sits on the tonal container token
    // (`surfaces.group`) while the detail pane stays on the base page surface.
    // Material only — Cupertino keeps its system background untouched.
    final Color? navPaneColor = cupertino ? null : tokens.surfaces.group;
    return MaterialSupportingPaneLayout(
      minSplitWidth: 720,
      supportingSide: SupportingPaneSide.start,
      dividerColor: dividerColor,
      supporting: Container(
        color: navPaneColor,
        child: renderer.buildDestinationList(
          settingsContext: settingsContext,
          destinations: destinations,
          selectedDestinationId: _selectedDestinationId,
          onDestinationSelected: _selectDestination,
          pushRoutes: false, // master-detail keeps selection in-pane.
        ),
      ),
      // 详情面板的身份就是当前 destination：用 KeyedSubtree 按 id 编码，
      // 切换目标时整棵子树作废重建，避免 Flutter 复用上一目标同位置的 Switch
      // Element 触发 didUpdateWidget(value 变化)→ 圆点滑动（以及分段滑动、滚动
      // 位置串页等同类复用副作用）。
      primary: KeyedSubtree(
        key: ValueKey<SettingsDestinationId>(selected.id),
        child: renderer.buildDetailContent(
          settingsContext: settingsContext,
          destination: selected,
        ),
      ),
    );
  }

  void _selectDestination(SettingsDestinationId id) {
    setState(() => _selectedDestinationId = id);
  }
}
