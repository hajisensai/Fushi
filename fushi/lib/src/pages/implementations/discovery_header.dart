/// 发现页统一头部控件：**来源筛选下拉 + 搜索框**。
///
/// 三个域的发现页（书/有声书与 galgame 走 `MediaDiscoveryPage`，漫画走
/// `MangaDiscoveryPage`）头部形状由本组件给出唯一真相：左侧「全部来源 / 具体
/// 来源」下拉，右侧搜索框。用户在任一模块看到的发现页结构因此一致。
///
/// 各域的「来源」实体互不相同（发现源 adapter / Mihon 在线源），所以
/// 本组件只吃 [DiscoverySourceOption] 这层最小公共结构 `(id, label)`，不绑任何
/// 域模型——想让新的域接进来只需把自己的来源映射成一串 (id, label)。
library;

import 'package:flutter/material.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/utils.dart';

/// 「全部来源」哨兵 id（`DropdownMenu` 泛型不便用 null）。真实来源 id 不得为空串。
const String kDiscoveryAllSourcesId = '';

/// 下拉里的一个来源选项。
class DiscoverySourceOption {
  const DiscoverySourceOption({required this.id, required this.label});

  /// 域内稳定 id；空串是「全部来源」哨兵，不可用作真实来源 id。
  final String id;

  /// 展示名（站名/来源名，不走 i18n）。
  final String label;
}

const OutlineInputBorder _pillBorder = OutlineInputBorder(
  borderRadius: BorderRadius.all(Radius.circular(kFushiSearchFieldHeight / 2)),
  borderSide: BorderSide.none,
);

/// 发现页头部（四个域统一）：
///
/// - 宽屏：来源下拉 + 搜索胶囊（M3E search bar / Apple 玻璃，[FushiSearchBar]）
///   + 行尾动作（✨ AI 下载、刷新…）同一行；
/// - 窄屏（[isCompactWidth]）：搜索框独占整行，来源下拉 + 行尾动作排下一行；
/// - 最后一行：筛选（[leading]，媒体域分段 / 筛选 chip）左对齐**单行**，放不下横滑。
class DiscoveryHeaderControls extends StatelessWidget {
  const DiscoveryHeaderControls({
    required this.sources,
    required this.selectedSourceId,
    required this.onSourceSelected,
    required this.searchController,
    required this.searchFocusNode,
    required this.searchHintText,
    required this.onSearchSubmitted,
    super.key,
    this.leading,
    this.trailing = const <Widget>[],
    this.onSearchChanged,
    this.onSearchCleared,
    this.searchFocusId = const FushiFocusId('discovery-search'),
  });

  /// 可选来源（不含「全部来源」，本组件自己在最前面补）。
  final List<DiscoverySourceOption> sources;

  /// 当前选中的来源 id；[kDiscoveryAllSourcesId] = 全部来源。
  final String selectedSourceId;

  final ValueChanged<String> onSourceSelected;

  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final String searchHintText;
  final ValueChanged<String> onSearchSubmitted;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onSearchCleared;

  /// 搜索框的焦点条目 id。`FushiFocusController` 按 id 覆盖注册，两个发现页
  /// （统一发现页 / 漫画发现页）可能同时挂在树上，各自传独立 id 才不会互顶。
  final FushiFocusId searchFocusId;

  /// 筛选行内容（如媒体域分段按钮 + 筛选 chip）：排在第二行、单行横滑。
  final Widget? leading;

  /// 搜索框之后、同一行的附加按钮（页头不渲染时页头动作挪到这里，如刷新）。
  final List<Widget> trailing;

  /// 窄屏判据：与视频发现页（`video_discovery_page.dart` 的 `compact`）同一条
  /// ——按界面缩放折算后的逻辑宽度不足 600。三个域的发现页头因此在同一个宽度
  /// 切到同一种两行形态。
  static bool isCompactWidth(BuildContext context, double width) =>
      width * FushiAppUiScale.of(context) < 600;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget? filterRow = leading;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        0,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) =>
                isCompactWidth(context, constraints.maxWidth)
                ? _buildCompact(context, tokens)
                : _buildWide(context, tokens),
          ),
          // 筛选行：左对齐单行，放不下就横滑（不再折行把搜索框以下的内容一层层
          // 往下推）。
          if (filterRow != null) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            HorizontalDragScrollable(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: filterRow,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 宽屏：来源下拉 + 搜索框 + 附加按钮同一行。
  Widget _buildWide(BuildContext context, FushiDesignTokens tokens) {
    return Row(
      children: <Widget>[
        _buildSourceMenu(context, tokens),
        SizedBox(width: tokens.spacing.gap),
        Expanded(child: _buildSearchField()),
        for (final Widget action in trailing) ...<Widget>[
          SizedBox(width: tokens.spacing.gap),
          action,
        ],
      ],
    );
  }

  /// 窄屏（手机竖屏）：搜索框**独占一整行**，来源下拉与附加按钮排第二行。
  ///
  /// 此前窄屏也挤在一行里：`DropdownMenu` 按最长条目取固有宽度，书域在手机上
  /// 把搜索框压成「搜…」，漫画域（来源名更长、还多一颗刷新）干脆把搜索框挤到
  /// 只剩一道竖线；视频发现页却是整条长搜索框——同一个「浏览 › 发现」三个页签
  /// 三种形态（2026-10-04 用户截图）。搜索是发现页的主操作，窄屏一律给整行，
  /// 下拉在第二行填满按钮之外的宽度。
  Widget _buildCompact(BuildContext context, FushiDesignTokens tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildSearchField(),
        SizedBox(height: tokens.spacing.gap),
        Row(
          children: <Widget>[
            Expanded(child: _buildSourceMenu(context, tokens, expand: true)),
            for (final Widget action in trailing) ...<Widget>[
              SizedBox(width: tokens.spacing.gap),
              action,
            ],
          ],
        ),
      ],
    );
  }

  /// M3E 搜索栏（[FushiSearchBar]）：与库页工具行同一枚搜索胶囊。查询的
  /// 防抖由各域发现页自己做（[onSearchChanged]），这里零防抖原样交出。
  Widget _buildSearchField() {
    return FushiSearchBar(
      fieldKey: const ValueKey<String>('discovery_search_field'),
      clearButtonKey: const ValueKey<String>('discovery_search_clear'),
      focusId: searchFocusId,
      controller: searchController,
      focusNode: searchFocusNode,
      hintText: searchHintText,
      onQueryChanged: onSearchChanged,
      onSubmitted: onSearchSubmitted,
      onClear: onSearchCleared,
    );
  }

  /// 来源下拉。[expand] 为真时填满父级给的宽度（窄屏第二行）。
  Widget _buildSourceMenu(
    BuildContext context,
    FushiDesignTokens tokens, {
    bool expand = false,
  }) {
    // 隐式切源（点进某来源的目录）后下拉必须跟着变：DropdownMenu 的
    // initialSelection 只在初次构建生效，外面套一层随选中值变化的 key
    // 强制重建，否则下拉会一直停在旧值上骗用户。
    return KeyedSubtree(
      key: ValueKey<String>('discovery_source_$selectedSourceId'),
      child: FushiDropdownMenu<String>(
        key: const ValueKey<String>('discovery_source_menu'),
        initialSelection: selectedSourceId,
        requestFocusOnTap: false,
        expandedInsets: expand ? EdgeInsets.zero : null,
        // 与搜索框同一几何：DropdownMenu 默认是 56 高的 MD3 文本框，比
        // [kFushiSearchFieldHeight] 的搜索框高出一截、字号也大一号，同一行两个
        // 输入控件高低不齐。压到同高 + 同一排版令牌。
        textStyle: tokens.type.listTitle,
        inputDecorationTheme: Theme.of(context).inputDecorationTheme.copyWith(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.rowHorizontal,
          ),
          constraints: const BoxConstraints.tightFor(
            height: kFushiSearchFieldHeight,
          ),
          // 与旁边的搜索胶囊同形（M3E：全圆角、surfaceContainerHigh 填充、
          // 静止无描边），不再是一颗小圆角描边方块挨着一枚胶囊。
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: _pillBorder,
          enabledBorder: _pillBorder,
          focusedBorder: _pillBorder.copyWith(
            borderSide: BorderSide(
              color: Theme.of(context).colorScheme.primary,
              width: 2,
            ),
          ),
        ),
        onSelected: (String? value) =>
            onSourceSelected(value ?? kDiscoveryAllSourcesId),
        dropdownMenuEntries: <DropdownMenuEntry<String>>[
          DropdownMenuEntry<String>(
            value: kDiscoveryAllSourcesId,
            label: t.discovery_all_sources,
          ),
          for (final DiscoverySourceOption source in sources)
            DropdownMenuEntry<String>(value: source.id, label: source.label),
        ],
      ),
    );
  }
}
