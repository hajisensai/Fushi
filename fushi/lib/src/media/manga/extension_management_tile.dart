import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
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

/// 扩展行动作按钮的强调层级（M3E 按钮族）。
///
/// 同一行里的动作按语义分级而不是一律文字按钮：安装 = filled（主操作）、
/// 有更新 = tonal（强调但不抢主色）、卸载 = outlined（破坏性的次要动作）、
/// 预览 = text（辅助）。
enum ExtensionTileActionStyle { filled, tonal, outlined, text }

/// Shared visual contract for Mihon APK and Aidoku AIX extension rows.
/// Runtime-specific pages supply metadata and actions; spacing, icon fallback,
/// warning badge, progress, enable switch and buttons stay identical.
///
/// M3E 形态（2026-10-06）：行首 12 圆角方块图标；标题后跟 18+（error tonal
/// 小胶囊）与「可更新」（accent tonal 小胶囊）；副标题是一排元信息小标签
/// （[metaChips]：语言 / 版本 / lib）+ 下载量 + 可展开详情（[details]）；
/// 动作按 [ExtensionTileActionStyle] 分级；安装中在卡片底部展开一条波浪进度。
/// 旧的整块 [subtitle] 仍可用（Aidoku 路径），与结构化参数可以并存。
class MangaExtensionManagementTile extends StatelessWidget {
  const MangaExtensionManagementTile({
    required this.title,
    this.subtitle,
    super.key,
    this.iconUrl,
    this.contentWarning = false,
    this.busy = false,
    this.enabled,
    this.onEnabledChanged,
    this.secondaryLabel,
    this.onSecondary,
    this.secondaryStyle = ExtensionTileActionStyle.text,
    this.primaryLabel,
    this.onPrimary,
    this.primaryStyle = ExtensionTileActionStyle.text,
    this.subtitleMaxLines = 1,
    this.groupIndex,
    this.groupCount,
    this.metaChips = const <String>[],
    this.downloadsLabel,
    this.updateAvailable = false,
    this.details,
  });

  final String title;

  /// 旧式整块副标题（一行元信息文本）。结构化调用点用 [metaChips] /
  /// [downloadsLabel] / [details]，两者可以并存（先标签、后它、再详情）。
  final Widget? subtitle;
  final String? iconUrl;
  final bool contentWarning;
  final bool busy;
  final bool? enabled;
  final ValueChanged<bool>? onEnabledChanged;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final ExtensionTileActionStyle secondaryStyle;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final ExtensionTileActionStyle primaryStyle;

  /// 副标题行数上限。默认 1（一行元信息）；Mihon 的「可用扩展」行在副标题里
  /// 展开自带源清单，由调用点显式放宽。
  final int subtitleMaxLines;

  /// 本行在所属分组（同一仓库 / 同一列表段）里的位置与总行数。两者都给时
  /// 整段读作一个分组（MD3 分段 / Apple inset grouped，见
  /// [FushiGroupedListItem]）；缺省时仍是一张张独立卡片。
  final int? groupIndex;
  final int? groupCount;

  /// 元信息小标签（语言 / 版本 / lib / 站点），每个画成一枚中性小胶囊。
  final List<String> metaChips;

  /// 下载量文案（`1.2k 次下载` / `无下载数据`），排在元信息标签之后。
  final String? downloadsLabel;

  /// 仓库里有比已装版本更新的版本：标题后挂一枚「可更新」强调小胶囊。
  final bool updateAvailable;

  /// 副标题下方的可展开详情（Mihon 的「包含的源」）。
  final Widget? details;

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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget row = _buildBody(context, tokens, narrow: narrow);
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
        // Apple 分隔线从标题起点开始：行内边距 + 图标 + 图标与文字间距。
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

  /// 行本体 + 底部的安装进度槽（busy 时弹簧展开一条波浪进度，结束后收起）。
  Widget _buildBody(
    BuildContext context,
    FushiDesignTokens tokens, {
    required bool narrow,
  }) {
    final FushiMotionScheme motion = context.fushiMotion;
    final double horizontal = tokens.spacing.rowHorizontal - 4;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildRow(context, tokens, narrow: narrow),
        AnimatedSize(
          duration: motion.spatialDefault.duration,
          curve: motion.spatialDefault.curve,
          alignment: Alignment.topCenter,
          child: busy
              ? Padding(
                  key: const ValueKey<String>('extension_tile_busy_progress'),
                  padding: EdgeInsets.fromLTRB(
                    horizontal,
                    0,
                    horizontal,
                    tokens.spacing.gap,
                  ),
                  child: const FushiLinearProgressIndicator(),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _buildRow(
    BuildContext context,
    FushiDesignTokens tokens, {
    required bool narrow,
  }) {
    final List<Widget> actions = <Widget>[
      if (secondaryLabel != null)
        _actionButton(secondaryLabel!, onSecondary, secondaryStyle),
      if (primaryLabel != null)
        _actionButton(primaryLabel!, onPrimary, primaryStyle),
    ];
    final List<Widget> trailingChildren = <Widget>[
      if (enabled != null)
        FushiSwitch.adaptive(value: enabled!, onChanged: onEnabledChanged),
      if (!narrow) ...actions,
    ];
    final bool structured = metaChips.isNotEmpty ||
        downloadsLabel != null ||
        details != null;
    final bool compactActions = narrow && actions.isNotEmpty;
    final Widget? subtitleBlock = structured || compactActions
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (metaChips.isNotEmpty || downloadsLabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: _ExtensionMetaWrap(
                    chips: metaChips,
                    downloadsLabel: downloadsLabel,
                  ),
                ),
              if (subtitle != null) subtitle!,
              if (details != null) details!,
              if (compactActions) ...<Widget>[
                const SizedBox(height: 6),
                Wrap(
                  key: const ValueKey<String>(
                    'manga_extension_tile_compact_actions',
                  ),
                  spacing: 8,
                  runSpacing: 6,
                  children: actions,
                ),
              ],
            ],
          )
        : subtitle;
    return FushiListItem(
      // 一行副标题 + 图标已经自带高度；rowVertical(12) 是给两行副标题
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
            // M3E：error tonal 小胶囊（errorContainer 底 + onErrorContainer
            // 字）；Apple 是空心胶囊 + 系统红字。
            const FushiTag(text: '18+', tone: FushiTagTone.error, dense: true),
          ],
          if (updateAvailable) ...<Widget>[
            const SizedBox(width: 8),
            FushiTag(
              key: const ValueKey<String>('extension_tile_update_badge'),
              text: t.extension_update_available,
              tone: FushiTagTone.accent,
              dense: true,
            ),
          ],
        ],
      ),
      subtitle: subtitleBlock,
      trailing: trailingChildren.isEmpty
          ? null
          : Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: trailingChildren,
            ),
    );
  }

  /// 动作按钮：M3E xs 档（32 高；触摸端命中区由主题的 tapTargetSize 补到 48）。
  static Widget _actionButton(
    String label,
    VoidCallback? onPressed,
    ExtensionTileActionStyle style,
  ) {
    final Widget child = Text(label);
    const FushiButtonSize size = FushiButtonSize.xs;
    return switch (style) {
      ExtensionTileActionStyle.filled => FushiFilledButton(
        size: size,
        onPressed: onPressed,
        child: child,
      ),
      ExtensionTileActionStyle.tonal => FushiFilledButton.tonal(
        size: size,
        onPressed: onPressed,
        child: child,
      ),
      ExtensionTileActionStyle.outlined => FushiOutlinedButton(
        size: size,
        onPressed: onPressed,
        child: child,
      ),
      ExtensionTileActionStyle.text => FushiTextButton(
        size: size,
        onPressed: onPressed,
        child: child,
      ),
    };
  }
}

/// 扩展行副标题里的一排元信息：中性小胶囊（语言 / 版本 / lib）+ 下载量。
class _ExtensionMetaWrap extends StatelessWidget {
  const _ExtensionMetaWrap({required this.chips, required this.downloadsLabel});

  final List<String> chips;
  final String? downloadsLabel;

  @override
  Widget build(BuildContext context) {
    final TextStyle base = DefaultTextStyle.of(context).style;
    final String? downloads = downloadsLabel;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        for (final String chip in chips)
          if (chip.trim().isNotEmpty)
            FushiTag(text: chip, tone: FushiTagTone.neutral, dense: true),
        if (downloads != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FushiIcon(FushiIcons.download, size: 14, color: base.color),
                const SizedBox(width: 2),
                Text(
                  downloads,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: base.color,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
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
    final FushiSpringSpec spring = context.fushiMotion.spatialFast;
    final Widget row = FushiListItem(
      key: ValueKey<String>('$keyPrefix-store-group-$indexUrl'),
      onTap: onTap,
      leading: AnimatedRotation(
        turns: expanded ? 0.25 : 0,
        duration: spring.duration,
        curve: spring.curve,
        child: const FushiIcon(FushiIcons.chevronRight),
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

/// 筛选 chip 行的一个选项：值 + 显示文案。
typedef ExtensionFilterOption<T> = ({T value, String label});

/// 扩展目录的一行筛选 chip（M3E choice chip，单选）：行首维度名 + 一排 chip，
/// 放不下时横向滚动（鼠标 / 触控板也能横拖）。仓库 / 语言 / 下载量门槛三行
/// 共用；每个 chip 的 key 是 `<chipKeyPrefix><值>`。
///
/// chip 是普通可聚焦控件：Tab / 方向键逐个走到，Enter / 手柄 A 选中；横滚区
/// 会随焦点自动滚到可见。Apple 设计系统下 [FushiChoiceChip] 自动出玻璃胶囊。
class ExtensionFilterChipRow<T> extends StatelessWidget {
  const ExtensionFilterChipRow({
    required this.label,
    required this.options,
    required this.selected,
    required this.chipKeyPrefix,
    required this.onSelected,
    super.key,
    this.icon,
  });

  final String label;
  final IconData? icon;
  final List<ExtensionFilterOption<T>> options;
  final T selected;
  final String chipKeyPrefix;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextStyle? labelStyle = Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(color: colors.onSurfaceVariant);
    final IconData? icon = this.icon;
    return Semantics(
      label: label,
      container: true,
      explicitChildNodes: true,
      child: HorizontalDragScrollable(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // 上下各留 2：chip 的焦点环 / 玻璃投影不被横滚区裁掉。
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: <Widget>[
              if (icon != null) ...<Widget>[
                FushiIcon(icon, size: 18, color: colors.onSurfaceVariant),
                const SizedBox(width: 6),
              ],
              ExcludeSemantics(child: Text(label, style: labelStyle)),
              const SizedBox(width: 12),
              for (int i = 0; i < options.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 8),
                FushiChoiceChip(
                  key: ValueKey<String>('$chipKeyPrefix${options[i].value}'),
                  label: Text(options[i].label),
                  selected: options[i].value == selected,
                  onSelected: (bool _) {
                    if (options[i].value != selected) {
                      onSelected(options[i].value);
                    }
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared responsive search + store + language filters for extension catalogs.
///
/// M3E 形态（2026-10-06）：上面一条 [FushiSearchBar]，下面是横滚 chip 行——
/// 「仓库」（给了 [stores] 且多于一个仓库时才出现，首项「全部仓库」）与
/// 「语言」（首项 [allLanguagesLabel]）。语言 chip 的 key 沿用旧下拉项的
/// `<keyPrefix>_language_<code>`，仓库 chip 是 `<keyPrefix>_store_<indexUrl>`。
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
    this.stores = const <ExtensionFilterOption<String>>[],
    this.selectedStore = '*',
    this.onStoreChanged,
    this.storeLabel,
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

  /// 可选的仓库筛选（值 = 仓库 indexUrl）。`'*'` 是「全部仓库」。
  final List<ExtensionFilterOption<String>> stores;
  final String selectedStore;
  final ValueChanged<String>? onStoreChanged;

  /// 仓库行的维度名；缺省「仓库」。
  final String? storeLabel;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<String>? onStoreChanged = this.onStoreChanged;
    final bool showStores = onStoreChanged != null && stores.length > 1;
    final String effectiveStore = stores.any(
      (ExtensionFilterOption<String> store) => store.value == selectedStore,
    )
        ? selectedStore
        : '*';
    final String effectiveLanguage =
        languages.contains(selectedLanguage) ? selectedLanguage : '*';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiSearchBar(
          fieldKey: ValueKey<String>('${keyPrefix}_search_field'),
          controller: searchController,
          hintText: searchHint,
          onQueryChanged: onSearchChanged,
          onClear: onSearchCleared,
        ),
        if (showStores) ...<Widget>[
          const SizedBox(height: 8),
          ExtensionFilterChipRow<String>(
            key: ValueKey<String>('${keyPrefix}_store_filter'),
            icon: FushiIcons.hub,
            label: storeLabel ?? t.media_import_segment_stores,
            chipKeyPrefix: '${keyPrefix}_store_',
            selected: effectiveStore,
            options: <ExtensionFilterOption<String>>[
              (value: '*', label: t.extension_filter_all_stores),
              ...stores,
            ],
            onSelected: onStoreChanged,
          ),
        ],
        if (languages.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          ExtensionFilterChipRow<String>(
            key: ValueKey<String>('${keyPrefix}_language_filter'),
            icon: FushiIcons.language,
            label: languageLabel,
            chipKeyPrefix: '${keyPrefix}_language_',
            selected: effectiveLanguage,
            options: <ExtensionFilterOption<String>>[
              (value: '*', label: allLanguagesLabel),
              for (final String language in languages)
                (value: language, label: language.toUpperCase()),
            ],
            onSelected: onLanguageChanged,
          ),
        ],
      ],
    );
  }
}

class _ExtensionIcon extends StatelessWidget {
  const _ExtensionIcon({required this.url});

  final String url;

  /// 有图标和没图标的行必须等宽起排：占位图标是 24、网络图标是 32 时，
  /// 同一列表里两种行的标题左缘差 8px，扫下来像没对齐。统一成一个固定
  /// 40×40 的 12 圆角方块（M3E 列表行首尺寸），图标缺失时方块里居中放占位符。
  static const double _size = 40;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    const Widget fallback = Center(
      child: FushiIcon(FushiIcons.browserExtension, size: 20),
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
