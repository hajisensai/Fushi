import 'package:flutter/cupertino.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_detail_page.dart';
import 'package:hibiki/src/settings/settings_renderer.dart';
import 'package:hibiki/src/settings/settings_schema_widgets.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

class CupertinoSettingsRenderer implements SettingsRenderer {
  const CupertinoSettingsRenderer();

  @override
  Widget buildHomePage({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required SettingsDestinationId selectedDestinationId,
    required ValueChanged<SettingsDestinationId> onDestinationSelected,
    bool embedded = false,
  }) {
    final Widget list = buildDestinationList(
      settingsContext: settingsContext,
      destinations: destinations,
      selectedDestinationId: selectedDestinationId,
      onDestinationSelected: onDestinationSelected,
    );
    if (embedded) return list;
    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: <Widget>[
          CupertinoSliverNavigationBar(
            largeTitle: Text(settingsContext.context.t.settings),
          ),
          SliverFillRemaining(child: list),
        ],
      ),
    );
  }

  @override
  Widget buildDestinationList({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required SettingsDestinationId selectedDestinationId,
    required ValueChanged<SettingsDestinationId> onDestinationSelected,
    bool pushRoutes = true,
  }) {
    final Color primaryColor =
        CupertinoTheme.of(settingsContext.context).primaryColor;
    return CupertinoListSection.insetGrouped(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        settingsContext.context,
      ),
      children: destinations.map((SettingsDestination destination) {
        return CupertinoListTile(
          leading: Icon(destination.icon, color: primaryColor),
          title: Text(destination.title),
          subtitle:
              destination.summary != null ? Text(destination.summary!) : null,
          trailing: const CupertinoListTileChevron(),
          onTap: () {
            onDestinationSelected(destination.id);
            if (!pushRoutes) return;
            Navigator.of(settingsContext.context).push(
              CupertinoPageRoute<void>(
                builder: (_) => SettingsDetailPage(destination: destination),
              ),
            );
          },
        );
      }).toList(growable: false),
    );
  }

  @override
  Widget buildDetailPage({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
  }) {
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        settingsContext.context,
      ),
      child: CustomScrollView(
        slivers: <Widget>[
          CupertinoSliverNavigationBar(
            largeTitle: Text(destination.title),
          ),
          SliverToBoxAdapter(
            child: buildDetailContent(
              settingsContext: settingsContext,
              destination: destination,
              // sliver 沿滚动轴无界，详情须收缩到内容高、由外层 CustomScrollView
              // 滚动（large-title 折叠依赖同一 scrollview）。
              shrinkWrap: true,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget buildDetailContent({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
    ScrollController? scrollController,
    bool shrinkWrap = false,
  }) {
    final List<SettingsSection> sections =
        destination.visibleSections(settingsContext);
    final EdgeInsets mediaPadding =
        MediaQuery.of(settingsContext.context).padding;
    // 底部留安全区，自滚到底时最后一项不贴边（对齐 Material 渲染器）。
    final EdgeInsets padding = EdgeInsets.only(bottom: mediaPadding.bottom);

    Widget section(int index) => SettingsSchemaSection(
          section: sections[index],
          settingsContext: settingsContext,
          showIcons: false,
          routeBuilder: (BuildContext context, WidgetBuilder builder) {
            return CupertinoPageRoute<void>(builder: builder);
          },
          footerStyle: (BuildContext context) =>
              HibikiDesignTokens.of(context).type.metadata.copyWith(
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
        );

    // 整页正文逃生口（见 SettingsDestination.body）：接在所有 schema section 之后，
    // 与它们共享同一个滚动容器与内边距。
    final Widget? bodyWidget = destination.body?.call(settingsContext);

    // shrinkWrap：嵌在外层 sliver / SingleChildScrollView 里（buildDetailPage 的
    // CustomScrollView 复用此路径），由父滚动；shrinkWrap ListView 必须布局全部子项
    // 来量自身高度，extent 已精确，禁用自身滚动即可。
    if (shrinkWrap) {
      return ListView.builder(
        controller: scrollController,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: padding,
        itemCount: sections.length + (bodyWidget != null ? 1 : 0),
        itemBuilder: (BuildContext context, int index) =>
            index < sections.length ? section(index) : bodyWidget!,
      );
    }

    // 自滚动（宽屏 master-detail 详情面板）。镜像 MaterialSettingsRenderer：懒加载
    // ListView.builder 按已布局子项平均高估算视口外 section 的 extent，section 高度
    // 悬殊时 maxScrollExtent 随滚动漂移、弹道落点被重新 clamp → 视口跳跃（BUG-037）。
    // 全 section 布局（SingleChildScrollView + Column）让 extent 精确恒定；它本身可
    // 滚动，也不会像裸 Column 那样在有界 Expanded 里 RenderFlex 溢出（BUG-009 R1）。
    return SingleChildScrollView(
      controller: scrollController,
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int index = 0; index < sections.length; index++) section(index),
          if (bodyWidget != null) bodyWidget,
        ],
      ),
    );
  }

  @override
  List<Widget> buildSectionRows({
    required SettingsContext settingsContext,
    required SettingsSection section,
    bool showIcons = true,
  }) {
    final SettingsSection visible = section.visibleCopy(settingsContext);
    return visible.items
        .map(
          (SettingsItem item) => SettingsSchemaItem(
            item: item,
            settingsContext: settingsContext,
            showIcons: showIcons,
            routeBuilder: (BuildContext context, WidgetBuilder builder) {
              return CupertinoPageRoute<void>(builder: builder);
            },
          ),
        )
        .toList(growable: false);
  }
}
