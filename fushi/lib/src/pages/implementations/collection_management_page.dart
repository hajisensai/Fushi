import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 「管理合集」页：与「管理标签」对等，一处列出本库页域（书架 / 漫画 / 视频 /
/// 游戏）的全部合集。
///
/// 页面本身不重写任何合集动作：点按 = 打开合集详情（[onOpenCollection]），
/// 长按 / 右键 / ⋯ = 该库页现成的合集菜单（[onShowCollectionMenu]：重命名、
/// 标签、排序、删除，删除时连带成员本体的语义按库页域各自决定），与库页上的
/// 合集卡同一个入口。任何写入经 [FushiDatabase.watchCollectionTablesChanged]
/// 回来重载列表，不靠各动作逐个通知。
class CollectionManagementPage extends StatefulWidget {
  const CollectionManagementPage({
    required this.database,
    required this.domain,
    required this.onOpenCollection,
    required this.onShowCollectionMenu,
    super.key,
  });

  final FushiDatabase database;

  /// 只列这个库页域的合集（与「加入合集」候选同一判据）。
  final CollectionShelfDomain domain;

  /// 打开合集详情页（库页的 `_openCollectionDetail`）。
  final void Function(MediaCollectionRow collection) onOpenCollection;

  /// 合集上下文菜单（库页的 `_showCollectionContextMenu`）。右键时须在第一个
  /// await 之前读 `activeContextMenuAnchor`，本页按 [contextMenuInvoker] 约定派发。
  final Future<void> Function(MediaCollectionRow collection)
  onShowCollectionMenu;

  @override
  State<CollectionManagementPage> createState() =>
      _CollectionManagementPageState();
}

class _CollectionManagementPageState extends State<CollectionManagementPage> {
  List<MediaCollectionRow> _collections = const <MediaCollectionRow>[];
  final Map<int, int> _memberCounts = <int, int>{};
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  StreamSubscription<void>? _changes;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _changes = widget.database.watchCollectionTablesChanged().listen(
      (_) => _reload(),
    );
    _reload();
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final FushiDatabase db = widget.database;
    final List<MediaCollectionRow> collections = await db
        .getMediaCollectionsInDomain(widget.domain);
    final Map<int, int> counts = <int, int>{};
    for (final MediaCollectionItemRow item
        in await db.getAllCollectionItems()) {
      counts.update(item.collectionId, (int n) => n + 1, ifAbsent: () => 1);
    }
    if (!mounted) return;
    setState(() {
      _collections = collections;
      _memberCounts
        ..clear()
        ..addAll(counts);
      _loaded = true;
    });
  }

  void _showMenu(MediaCollectionRow collection) =>
      unawaited(widget.onShowCollectionMenu(collection));

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final double leadingWidth = apple ? metrics.leadingIconSize : 40;
    final List<MediaCollectionRow> visible = filterByMediaSearch(
      _collections,
      _search.text,
      (MediaCollectionRow c) => <String>[c.name],
    );

    Widget row(MediaCollectionRow collection, int index, int count) {
      return FushiGroupedListItem(
        key: ValueKey<String>('collection-manage-row-${collection.id}'),
        index: index,
        count: count,
        separatorIndent:
            metrics.rowHorizontal + leadingWidth + metrics.leadingGap,
        child: ContextMenuTrigger(
          // 与库页合集卡同一约定：右键经 contextMenuInvoker 暴露锚点 → 指针处
          // 右键菜单；长按 / ⋯ 无锚点 → 抽屉 / 对话框。
          onInvoke: contextMenuInvoker(() => _showMenu(collection)),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onLongPress: () => _showMenu(collection),
            child: FushiListItem(
              minHeight: apple ? null : 64,
              leading: SizedBox(
                width: leadingWidth,
                child: Center(
                  child: apple
                      ? FushiIcon(
                          FushiIcons.collection,
                          color: theme.colorScheme.primary,
                        )
                      : Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondaryContainer,
                            borderRadius: FushiM3eShape.smallRadius,
                          ),
                          child: FushiIcon(
                            FushiIcons.collection,
                            size: 20,
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                ),
              ),
              title: Text(
                collection.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                t.collection_detail_member_count(
                  n: _memberCounts[collection.id] ?? 0,
                ),
              ),
              trailing: FushiIconButtonControl(
                tooltip: t.shelf_toolbar_more,
                icon: const FushiIcon(FushiIcons.more),
                onPressed: () => _showMenu(collection),
              ),
              onTap: () => widget.onOpenCollection(collection),
            ),
          ),
        ),
      );
    }

    final Widget header = Padding(
      padding: EdgeInsets.fromLTRB(
        0,
        tokens.spacing.gap,
        0,
        tokens.spacing.gap * 1.5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _CollectionSummaryCard(count: _collections.length),
          SizedBox(height: tokens.spacing.gap * 1.5),
          FushiSearchField(
            fieldKey: const ValueKey<String>('collection_management_search'),
            controller: _search,
            focusNode: _searchFocus,
            hintText: t.collection_manage_search_hint,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {},
            onClear: () => setState(_search.clear),
          ),
        ],
      ),
    );

    // 正文铺到浮动页头底下：context 取 Builder 的（页头脚手架之内），才读得到
    // 顶部让位（状态栏 + 页头）；摘要卡与搜索是列表首项，随内容一起滚走。
    Widget buildBody(BuildContext context) {
      if (!_loaded) {
        return SafeArea(
          bottom: false,
          child: Center(child: adaptiveIndicator(context: context)),
        );
      }
      if (_collections.isEmpty) {
        return SafeArea(
          bottom: false,
          child: Center(
            child: FushiPlaceholderMessage(
              icon: FushiIcons.collection,
              message: t.collection_manage_empty_hint,
            ),
          ),
        );
      }
      return FushiEntranceScope(
        child: ListView.builder(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.page,
            MediaQuery.paddingOf(context).top,
            tokens.spacing.page,
            tokens.spacing.gap + MediaQuery.paddingOf(context).bottom,
          ),
          itemCount: visible.length + 1,
          itemBuilder: (BuildContext context, int i) {
            if (i == 0) return header;
            return FushiStaggeredEntrance(
              index: i - 1,
              child: row(visible[i - 1], i - 1, visible.length),
            );
          },
        ),
      );
    }

    return FushiPageScaffold(
      title: t.collection_manage_title,
      body: Builder(builder: buildBody),
    );
  }
}

/// 页首摘要色块（与标签管理页同一形态）：M3E 饱和 primaryContainer 大色块 +
/// Display 级合集数 + 操作提示；Apple / 墨水屏不铺色块，只留文字层级。
class _CollectionSummaryCard extends StatelessWidget {
  const _CollectionSummaryCard({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final bool plain = apple || eink;
    final Color fill = plain
        ? Colors.transparent
        : theme.colorScheme.primaryContainer;
    final Color fg = plain
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onPrimaryContainer;
    return Container(
      padding: EdgeInsets.all(apple ? tokens.spacing.gap : tokens.spacing.card),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: FushiM3eShape.containerLargeRadius,
        border: eink ? Border.all(color: theme.colorScheme.outline) : null,
      ),
      child: Row(
        children: <Widget>[
          Text(
            '$count',
            style:
                (apple
                        ? theme.textTheme.headlineMedium
                        : theme.textTheme.displayMedium)
                    ?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w800,
                      height: 1,
                    ),
          ),
          SizedBox(width: tokens.spacing.gap * 1.5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t.collection_manage_count(n: count),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  t.collection_manage_menu_hint,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listSubtitle.copyWith(
                    color: fg.withValues(alpha: 0.78),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
