import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/library_filter_dropdown.dart'
    show LibrarySearchField;
import 'package:fushi/src/utils/components/fushi_control_metrics.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';

/// 一行元信息：跳过空片段后用 ` · ` 串成**单行**。
///
/// 扩展行以前是「语言 · 版本」`\n`「完整 URL」两行硬换行，副标题独占两行、
/// 行高冲到 ~89px，手机一屏只剩六条；URL 还带 `https://` 前缀把有效信息
/// 挤出可视区。收成一行后行高回到 ~62px，且与本仓其它列表（下载任务卡
/// `download_task_card.dart`、章节行 `manga_chapter_list.dart`）同一写法。
String mangaSourceMetaLine(Iterable<String?> parts) => parts
    .map((String? part) => part?.trim() ?? '')
    .where((String part) => part.isNotEmpty)
    .join(' · ');

/// 源地址的可读短形：去掉 scheme / `www.` / 末尾斜杠，保留主机（+ 非根路径）。
/// 解析不动的（Aidoku 只有包 id、没有 baseUrl）原样返回。
String mangaSourceHostLabel(String value) {
  final String raw = value.trim();
  if (raw.isEmpty) return '';
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) return raw;
  final String host =
      uri.host.startsWith('www.') ? uri.host.substring(4) : uri.host;
  final String path = uri.path == '/' ? '' : uri.path;
  return '$host$path';
}

/// Shared visual contract for Mihon APK and Aidoku AIX extension rows.
/// Runtime-specific pages supply metadata and actions; spacing, icon fallback,
/// warning badge, progress, enable switch and buttons stay identical.
class MangaExtensionManagementTile extends StatelessWidget {
  const MangaExtensionManagementTile({
    required this.title,
    required this.subtitle,
    super.key,
    this.iconUrl,
    this.contentWarning = false,
    this.busy = false,
    this.enabled,
    this.onEnabledChanged,
    this.secondaryLabel,
    this.onSecondary,
    this.primaryLabel,
    this.onPrimary,
    this.subtitleMaxLines = 1,
    this.groupIndex,
    this.groupCount,
  });

  final String title;
  final Widget subtitle;
  final String? iconUrl;
  final bool contentWarning;
  final bool busy;
  final bool? enabled;
  final ValueChanged<bool>? onEnabledChanged;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final String? primaryLabel;
  final VoidCallback? onPrimary;

  /// 副标题行数上限。默认 1（一行元信息）；Mihon 的「可用扩展」行在副标题里
  /// 展开自带源清单，由调用点显式放宽。
  final int subtitleMaxLines;

  /// 本行在所属分组（同一仓库 / 同一列表段）里的位置与总行数。两者都给时
  /// 整段读作一个分组（MD3 分段 / Apple inset grouped，见
  /// [FushiGroupedListItem]）；缺省时仍是一张张独立卡片。
  final int? groupIndex;
  final int? groupCount;

  /// 窄于此宽度时文字动作按钮下移到副标题下方一行。
  ///
  /// 2026-10 体验优化：trailing 的 `Wrap` 在 `FushiListItem` 的 `Row` 里拿到
  /// 的是无界宽度，永远不会换行——窄屏上「预览 + 安装」两个按钮加开关直接
  /// 把标题列挤到只剩几个字甚至溢出。
  static const double compactActionsBreakpoint = 480;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          _buildTile(
            context,
            narrow: constraints.maxWidth < compactActionsBreakpoint,
          ),
    );
  }

  Widget _buildTile(BuildContext context, {required bool narrow}) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget row = _buildRow(context, theme, tokens, narrow: narrow);
    final int? index = groupIndex;
    final int? count = groupCount;
    if (index != null && count != null) {
      return FushiGroupedListItem(
        index: index,
        count: count,
        // 组尾与下一组之间留一段组间距（组内是 MD3 2px 缝 / Apple 无缝）。
        margin: EdgeInsets.only(
          bottom: index >= count - 1 ? tokens.spacing.gap : 0,
        ),
        // Apple 分隔线从标题起点开始：行内边距 + 36 图标 + 图标与文字间距。
        separatorIndent: tokens.spacing.rowHorizontal -
            4 +
            _ExtensionIcon._size +
            FushiAppleMetrics.of(context).leadingGap,
        child: row,
      );
    }
    return FushiCard(
      // 行与行之间必须有实边距：卡片圆角 10 而外边距为 0 时，相邻卡片之间只
      // 从圆角缺口漏出几处页面底色，看着像锯齿而不是分隔。
      margin: EdgeInsets.only(bottom: tokens.spacing.gap),
      padding: EdgeInsets.zero,
      child: row,
    );
  }

  Widget _buildRow(
    BuildContext context,
    ThemeData theme,
    FushiDesignTokens tokens, {
    required bool narrow,
  }) {
    final List<Widget> actions = <Widget>[
      if (secondaryLabel != null)
        FushiTextButton(
          style: _actionStyle,
          onPressed: onSecondary,
          child: Text(secondaryLabel!),
        ),
      if (primaryLabel != null)
        FushiTextButton(
          style: _actionStyle,
          onPressed: onPrimary,
          child: Text(primaryLabel!),
        ),
    ];
    final List<Widget> trailingChildren = <Widget>[
      if (busy)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox.square(
            dimension: 18,
            child: FushiCircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      if (enabled != null)
        FushiSwitch.adaptive(value: enabled!, onChanged: onEnabledChanged),
      if (!narrow) ...actions,
    ];
    return FushiListItem(
      // 一行副标题 + 36px 图标已经自带高度；rowVertical(12) 是给两行副标题
      // 留的，这里收到 gap(8)，行高从 ~89 降到 ~62。
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.rowHorizontal - 4,
        vertical: tokens.spacing.gap,
      ),
      titleMaxLines: 2,
      subtitleMaxLines: subtitleMaxLines,
      leading: _ExtensionIcon(url: iconUrl ?? ''),
      title: Row(
        children: <Widget>[
          Flexible(child: Text(title)),
          if (contentWarning) ...<Widget>[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              // 中性徽标底 + 错误色文字（不再整块 errorContainer）。
              decoration: BoxDecoration(
                color: fushiNeutralTagColors(context).background,
                borderRadius: tokens.radii.chipRadius,
              ),
              child: Text(
                '18+',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: fushiStatusColor(context, FushiStatusTone.error),
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: narrow && actions.isNotEmpty
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                subtitle,
                const SizedBox(height: 4),
                Wrap(
                  key: const ValueKey<String>(
                    'manga_extension_tile_compact_actions',
                  ),
                  spacing: 4,
                  runSpacing: 4,
                  children: actions,
                ),
              ],
            )
          : subtitle,
      trailing: trailingChildren.isEmpty
          ? null
          : Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: trailingChildren,
            ),
    );
  }

  /// 文字动作按钮默认左右各 16 的内边距，两个按钮并排就把标题挤到只剩半屏。
  /// 收到 10 并保留 44 高的点按目标（触摸端最小命中区）。
  static final ButtonStyle _actionStyle = TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    minimumSize: const Size(0, 44),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
}

/// 把「表头 + 若干扩展行」拍平的目录行表切成分组：返回每一行在所属分组里的
/// （组内位置, 组内总行数）。[isHeader] 逐行标明是不是仓库表头；表头是本组第
/// 0 行，后面跟到下一个表头之前的扩展行依次 1、2…。表头之前没有表头的行自成
/// 一组。漫画 / 视频（Mihon）与小说（LNReader）的扩展目录共用。
List<(int, int)> extensionGroupSlots(Iterable<bool> isHeader) {
  final List<bool> headers = isHeader.toList(growable: false);
  final List<(int, int)> slots = List<(int, int)>.filled(headers.length, (0, 1));
  int start = 0;
  while (start < headers.length) {
    int end = start + 1;
    while (end < headers.length && !headers[end]) {
      end++;
    }
    final int count = end - start;
    for (int i = start; i < end; i++) {
      slots[i] = (i - start, count);
    }
    start = end;
  }
  return slots;
}

/// 扩展目录里超过这个条数的仓库分组默认收起。
///
/// 不是拍脑袋的魔数，编码的是一条产品规则：**一眼扫得完的分组就没必要收起**。
/// 装了三五个扩展的自建仓库全收起来只会让用户多点一下；而 keiyoushi 一家就
/// 1900+ 个扩展，铺开时这一页除了滚动什么也做不了（用户「这里支持下根据仓库
/// 折叠」）。收起态下表头仍显示扩展条数，不会让人以为列表空了。漫画 / 视频
/// （Mihon）与小说（LNReader）的扩展目录共用这一条。
const int kExtensionStoreAutoCollapseThreshold = 20;

/// 扩展目录的仓库分组表头：名字 + 扩展条数 + 展开箭头。漫画 / 视频 / 小说三域
/// 的扩展页签共用，外观一致。
///
/// 条数不是装饰：收起态下这是「这个仓库到底有没有东西」的唯一线索，没有它
/// 折叠就等于让列表看起来空了。
class ExtensionStoreGroupHeader extends StatelessWidget {
  const ExtensionStoreGroupHeader({
    required this.keyPrefix,
    required this.indexUrl,
    required this.label,
    required this.count,
    required this.expanded,
    required this.onTap,
    super.key,
    this.groupCount,
  });

  /// 表头所在分组的总行数（表头自己算第一行 + 展开的扩展行）。给了就把表头
  /// 画成分组的首行（MD3 分段 / Apple inset grouped，与下面的扩展行
  /// [MangaExtensionManagementTile.groupIndex] 连成一组），缺省时是独立卡片。
  final int? groupCount;

  /// 行 key 前缀（`<keyPrefix>-store-group-<indexUrl>`）。
  final String keyPrefix;

  /// key 用 indexUrl 而不是显示名：页面顶部的仓库**管理**卡也画着同一个 name，
  /// 按名字定位会撞上那张卡（它没有 onTap，点了什么都不会发生）。
  final String indexUrl;
  final String label;
  final int count;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget row = FushiListItem(
      key: ValueKey<String>('$keyPrefix-store-group-$indexUrl'),
      onTap: onTap,
      leading: AnimatedRotation(
        turns: expanded ? 0.25 : 0,
        duration: const Duration(milliseconds: 150),
        child: const FushiIcon(Icons.chevron_right),
      ),
      title: Text(label, style: theme.textTheme.titleSmall),
      subtitle: Text(t.mihon_store_extension_count(count: count)),
    );
    final int? rows = groupCount;
    if (rows != null) {
      return FushiGroupedListItem(
        index: 0,
        count: rows,
        // 收起的分组只剩表头一行：它同时是组尾，给出组间距。
        margin: EdgeInsets.only(
          bottom: rows <= 1 ? FushiDesignTokens.of(context).spacing.gap : 0,
        ),
        child: row,
      );
    }
    return FushiCard(
      padding: EdgeInsets.zero,
      child: row,
    );
  }
}

/// Shared responsive language/search row for extension repositories.
class MangaExtensionFilters extends StatelessWidget {
  const MangaExtensionFilters({
    required this.languages,
    required this.selectedLanguage,
    required this.languageLabel,
    required this.allLanguagesLabel,
    required this.searchHint,
    required this.searchController,
    required this.searchQuery,
    required this.onLanguageChanged,
    required this.onSearchChanged,
    required this.onSearchCleared,
    super.key,
    this.keyPrefix = 'manga_extension',
  });

  final List<String> languages;
  final String selectedLanguage;
  final String languageLabel;
  final String allLanguagesLabel;
  final String searchHint;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onLanguageChanged;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchCleared;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final Widget languageFilter = FushiDropdownButtonFormField<String>(
      value: languages.contains(selectedLanguage) ? selectedLanguage : '*',
      // 行内筛选不挂浮动标签：标签会把下拉撑得比并排的搜索框高一截（MD3 浮动
      // 标签 56、Apple 标题在框上方），用户 2026-10-04 报「搜索框和语言框不一样
      // 高」。维度名由无障碍标签表达，选中值（「全部语言」/「JA」）自明。
      // MD3 下装饰收成无边无底的紧凑形态，填充胶囊由外层容器画并把下拉在
      // 定高里居中——InputDecorator 在多余高度里贴顶放内容，靠内边距凑高度
      // 会随视觉密度 / 字号缩放漂移。Apple 分支不读这些装饰（自带玻璃壳）。
      decoration: const InputDecoration(
        isCollapsed: true,
        border: InputBorder.none,
      ),
      // 收起态的选中值直接给文字：默认用菜单项本身（带 48 高的菜单项容器，
      // 桌面视觉密度下会让文字比按钮中线高 4px），在 40 高的行内里不居中。
      selectedItemBuilder: (BuildContext context) => <Widget>[
        for (final String label in <String>[
          allLanguagesLabel,
          for (final String language in languages) language.toUpperCase(),
        ])
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      items: <DropdownMenuItem<String>>[
        DropdownMenuItem<String>(
          key: ValueKey<String>('${keyPrefix}_language_*'),
          value: '*',
          child: Text(allLanguagesLabel),
        ),
        for (final String language in languages)
          DropdownMenuItem<String>(
            key: ValueKey<String>('${keyPrefix}_language_$language'),
            value: language,
            child: Text(language.toUpperCase()),
          ),
      ],
      onChanged: (String? value) => onLanguageChanged(value ?? '*'),
    );
    // 与语言下拉同一个行内控件高度（MD3 40 / Apple 36），两者并排时等高、
    // 中线一致；搜索框与库页工具行同一个组件。
    final double controlHeight = fushiInlineControlHeight(context);
    final bool glass = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget searchField = LibrarySearchField(
      fieldKey: ValueKey<String>('${keyPrefix}_search_field'),
      controller: searchController,
      hintText: searchHint,
      onChanged: onSearchChanged,
      onClear: onSearchCleared,
    );
    final Widget sizedLanguageFilter = Semantics(
      label: languageLabel,
      container: true,
      child: Container(
        height: controlHeight,
        alignment: Alignment.center,
        padding: glass
            ? EdgeInsets.zero
            : const EdgeInsetsDirectional.only(start: 16, end: 8),
        // 与并排的 MD3 填充式搜索框同一枚胶囊（surfaceContainerHigh、无描边；
        // 墨水屏描边）；Apple 由下拉自己的玻璃壳负责，这里不画。
        decoration: glass
            ? null
            : ShapeDecoration(
                color: eink
                    ? null
                    : FushiDesignTokens.of(context).surfaces.search,
                shape: StadiumBorder(
                  side: eink ? BorderSide(color: colors.outline) : BorderSide.none,
                ),
              ),
        // 桌面的紧凑视觉密度会让 InputDecorator 把收起态内容整体上移 4px
        // （densityOffset），在定高胶囊里不居中；行内下拉固定用标准密度。
        child: Theme(
          data: Theme.of(context).copyWith(
            visualDensity: VisualDensity.standard,
          ),
          child: languageFilter,
        ),
      ),
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < 700) {
          return Column(
            children: <Widget>[
              sizedLanguageFilter,
              const SizedBox(height: 12),
              searchField,
            ],
          );
        }
        return Row(
          children: <Widget>[
            Expanded(child: sizedLanguageFilter),
            const SizedBox(width: 12),
            Expanded(child: searchField),
          ],
        );
      },
    );
  }
}

class _ExtensionIcon extends StatelessWidget {
  const _ExtensionIcon({required this.url});

  final String url;

  /// 有图标和没图标的行必须等宽起排：占位 `Icon` 是 24、网络图标是 32 时，
  /// 同一列表里两种行的标题左缘差 8px，扫下来像没对齐。统一成一个固定
  /// 36×36 的圆角容器，图标缺失时容器里居中放占位符。
  static const double _size = 36;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    const Widget fallback = Center(
      child: FushiIcon(Icons.extension_outlined, size: 20),
    );
    return SizedBox.square(
      dimension: _size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaces.group,
          borderRadius: FushiM3eShape.smallRadius,
        ),
        child: url.isEmpty
            ? fallback
            : ClipRRect(
                borderRadius: FushiM3eShape.smallRadius,
                // 🔴 不要换回 Image.network（BUG-1715）：NetworkImage 走 Flutter
                // 内部 HttpClient，接不进应用代理出口；桌面上索引经代理能拉到、
                // 图标直连 raw.githubusercontent.com 却失败，列表就全是占位图标。
                child: Image(
                  image: AppHttpImage(url),
                  width: _size,
                  height: _size,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => fallback,
                  loadingBuilder:
                      (_, Widget child, ImageChunkEvent? progress) =>
                          progress == null ? child : fallback,
                ),
              ),
      ),
    );
  }
}
