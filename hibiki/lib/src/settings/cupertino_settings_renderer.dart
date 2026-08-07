import 'package:flutter/cupertino.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_renderer.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

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
    // no-op：Cupertino 详情正文本就无横向内边距（靠 CupertinoListSection /
    // 外层容器提供留白），故 [insetHorizontally] 对其无影响，仅为满足接口签名。
    bool insetHorizontally = true,
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
              FushiDesignTokens.of(context).type.metadata.copyWith(
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

    // 自滚动（宽屏 master-detail 详情面板）。刻意非懒（SingleChildScrollView +
    // Column），完整 BUG-037 根因见 MaterialSettingsRenderer.buildDetailContent
    // 同位置注释；也不能换裸 Column——有界 Expanded 里会 RenderFlex 溢出
    // （BUG-009 R1）。
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
          // 行级稳定 key：visibleCopy 按运行时谓词过滤，行增删时以 item.id 锚定
          // State 归属（否则同类型相邻行按位置错配旧 State）。
          (SettingsItem item) => SettingsSchemaItem(
            key: ValueKey<String>(item.id),
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
