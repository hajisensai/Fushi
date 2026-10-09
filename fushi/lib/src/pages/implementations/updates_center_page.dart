import 'dart:async' show unawaited;
import 'dart:io' show File;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart' show UpdateFeedEntryRow;

import 'package:fushi/src/pages/fushi_page_placeholders.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/utils.dart';

/// 更新中心（v101）：四个域的更新事件汇成一页。
///
/// 页头（2026-10-09 精简）只有一行悬浮工具栏：`[返回] [域筛选 …]`，没有「全部」
/// ——番剧新集 / 漫画新章会被成串的应用新版、扩展更新淹没。默认打开哪个域见
/// [pickDefaultUpdateFeedFilter]。刷新 / 全部标为已读 / 清空记录是低频页面动作，
/// 恒在「⋯」里；筛选放不下时按 [FushiFloatingTopBar] 的自适应溢出从最低优先级
/// （应用新版）起收进同一个「⋯」。
///
/// 页面**不认识**任何一个域的打开方式——跳转由 [onOpenEntry] 注入。理由与
/// `UpdateFeedService` 不 import slang 同源：这一页要能在 widget 测试里独立构建，
/// 而「打开合集 / 打开漫画作品页 / 打开扩展页 / 打开发布页」四条链路各自拖着一
/// 整棵依赖树。
class UpdatesCenterPage extends StatefulWidget {
  const UpdatesCenterPage({super.key, required this.service, this.onOpenEntry});

  final UpdateFeedService service;

  /// 打开一条更新。null = 只标已读不跳转。
  final Future<void> Function(UpdateFeedEntryRow entry)? onOpenEntry;

  @override
  State<UpdatesCenterPage> createState() => _UpdatesCenterPageState();
}

class _UpdatesCenterPageState extends State<UpdatesCenterPage>
    with FushiPagePlaceholders<UpdatesCenterPage> {
  bool _loading = true;
  List<UpdateFeedEntryRow> _entries = const <UpdateFeedEntryRow>[];

  /// 当前域筛选。null 只出现在进页面、默认域还没算出来的那一刻（筛选条此时
  /// 不高亮任何一项，免得先亮「番剧新集」再跳到别的域）。
  UpdateFeedKind? _filter;

  /// 进页面那一刻的未读条目。进页面即全部标已读（见 [_enter]），之后切到别的
  /// 域从库里读回来的已经全是已读——「这次停留里哪些是新的」只能看这份快照。
  /// 点开一条 / 「全部标为已读」时从这里摘掉。
  Set<String> _fresh = <String>{};

  /// 进页面快照最多看这么多条（按时间倒序）：只用来定默认域与本次高亮，
  /// 远超一屏的旧条目不影响这两个判断。
  static const int _kSnapshotLimit = 1000;

  @override
  void initState() {
    super.initState();
    _enter();
  }

  /// 进页面 = 已读。用户点进来的动作本身就是「我看到了」，不该进来之后还要再
  /// 按一次「全部已读」才能把首页角标和系统通知消掉。先取未读快照（定默认域 +
  /// 本次停留的高亮）再标；[markAllSeen] 顺带撤系统通知。
  Future<void> _enter() async {
    final List<UpdateFeedEntryRow> all = await widget.service.entries(
      limit: _kSnapshotLimit,
    );
    if (!mounted) return;
    final Set<UpdateFeedKind> unseen = <UpdateFeedKind>{};
    final Set<UpdateFeedKind> present = <UpdateFeedKind>{};
    final Set<String> fresh = <String>{};
    for (final UpdateFeedEntryRow row in all) {
      final UpdateFeedKind? kind = UpdateFeedKind.fromDbValue(row.kind);
      if (kind == null) continue;
      present.add(kind);
      if (row.seenAt == null) {
        unseen.add(kind);
        fresh.add(row.entryId);
      }
    }
    _fresh = fresh;
    _filter = pickDefaultUpdateFeedFilter(unseen: unseen, present: present);
    await _load();
    await widget.service.markAllSeen();
  }

  Future<void> _load() async {
    final UpdateFeedKind? kind = _filter;
    if (kind == null) return;
    setState(() => _loading = true);
    final List<UpdateFeedEntryRow> rows = await widget.service.entries(
      kinds: <UpdateFeedKind>{kind},
    );
    // 加载期间又切了域：这份结果已经过时，交给后发的那次加载。
    if (!mounted || kind != _filter) return;
    setState(() {
      _entries = rows;
      _loading = false;
    });
  }

  void _select(UpdateFeedKind kind) {
    if (kind == _filter) return;
    setState(() => _filter = kind);
    unawaited(_load());
  }

  /// 全部域标已读。进页面时库里已经全标过了，这里收掉的是本次停留的「新」
  /// 高亮。不再按当前域标：「全部」页签没了，按域标就得逐个切过去按一遍。
  Future<void> _markAllSeen() async {
    await widget.service.markAllSeen();
    if (!mounted) return;
    setState(() => _fresh = <String>{});
    await _load();
  }

  /// 清空当前域的全部记录。破坏性操作，先确认。
  Future<void> _clear() async {
    final UpdateFeedKind? kind = _filter;
    if (kind == null) return;
    final FushiDestructiveConfirmResult? confirmed =
        await showAppDialog<FushiDestructiveConfirmResult>(
          context: context,
          builder: (BuildContext dialogContext) =>
              FushiDestructiveConfirmDialog(
                title: t.updates_history_clear_confirm_title,
                message: t.updates_history_clear_confirm_body(
                  scope: updateFeedKindLabel(kind),
                ),
                confirmLabel: t.updates_history_clear_confirm_action,
                leadingIcon: FushiIcons.deleteSweep,
              ),
        );
    if (confirmed == null || !mounted) return;
    final int removed = await widget.service.clear(kind: kind);
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      FushiSnackBar(content: Text(t.updates_history_cleared(count: removed))),
    );
  }

  Future<void> _open(UpdateFeedEntryRow entry) async {
    // 先标已读再跳转：跳转可能把本页顶掉（push 新路由），之后的 setState 就到不
    // 了了；而「点开过」这个事实不该取决于跳转成功与否。
    await widget.service.markSeen(<String>[entry.entryId]);
    if (mounted) {
      setState(() => _fresh.remove(entry.entryId));
      await _load();
    }
    await widget.onOpenEntry?.call(entry);
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: t.updates_center_title,
      header: _buildTopBar(context),
      // Builder：正文要在页头脚手架之内取 MediaQuery 顶部让位（状态栏 + 浮动
      // 页头）。
      body: Builder(builder: _buildList),
    );
  }

  /// 唯一一行页头：返回胶囊 + 紧跟其后的域筛选按钮组（选中 = 选中胶囊底），
  /// 页面动作恒在组尾「⋯」。宽度不够时筛选从最低优先级（枚举末位）起收进同一
  /// 个「⋯」——测宽与展开回差全走 [FushiFloatingTopBar] 那一套。
  Widget _buildTopBar(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    final bool canPop = navigator?.canPop() ?? false;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: FushiFloatingTopBar(
        actionsFollowLeading: true,
        // 纯图标认不出是哪一类通知：宽度够就带字，放不下先只给选中项带字，
        // 再把低优先级收进「⋯」，最后才退成纯图标。
        inlineLabels: true,
        leading: <FushiToolbarItem>[
          if (canPop)
            FushiToolbarItem(
              key: const ValueKey<String>('updates_back'),
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator!.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[
          <FushiToolbarItem>[
            for (final UpdateFeedKind kind in UpdateFeedKind.values)
              FushiToolbarItem(
                key: ValueKey<String>('updates_filter_${kind.dbValue}'),
                icon: updateFeedKindIcon(kind),
                label: updateFeedKindLabel(kind),
                selected: _filter == kind,
                onPressed: () => _select(kind),
              ),
          ],
        ],
        menu: <FushiToolbarItem>[
          FushiToolbarItem(
            key: const ValueKey<String>('updates_refresh'),
            icon: FushiIcons.refresh,
            label: t.refresh,
            onPressed: _loading ? null : () => unawaited(_load()),
          ),
          FushiToolbarItem(
            key: const ValueKey<String>('updates_mark_all_seen'),
            icon: FushiIcons.checklist,
            label: t.updates_mark_all_seen,
            onPressed: _fresh.isEmpty ? null : () => unawaited(_markAllSeen()),
          ),
          FushiToolbarItem(
            key: const ValueKey<String>('updates_clear'),
            icon: FushiIcons.deleteSweep,
            label: t.updates_history_clear,
            onPressed: _loading || _entries.isEmpty
                ? null
                : () => unawaited(_clear()),
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    // 切域时「加载 → 列表 / 空态」交叉淡入，列表本身再按首屏错峰进场；时长走
    // fushiMotionDuration（减弱动态效果 / 墨水屏下归零）。
    final String phase = _loading
        ? 'loading'
        : _entries.isEmpty
        ? 'empty'
        : 'list';
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      child: KeyedSubtree(
        key: ValueKey<String>('${phase}_${_filter?.dbValue}'),
        child: _buildListBody(context),
      ),
    );
  }

  Widget _buildListBody(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (_loading) return SafeArea(bottom: false, child: buildLoading());
    if (_entries.isEmpty) {
      return SafeArea(bottom: false, child: _UpdatesEmptyState(tokens: tokens));
    }
    // M3E 分段卡片列表（首尾大圆角、行间 2px），首屏错峰进场；切筛选重开窗口。
    return FushiEntranceScope(
      replayKey: _filter,
      child: ListView.builder(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            tokens.spacing.page,
            // 正文滚到浮动页头底下：顶部让出「状态栏 + 页头」。
            tokens.spacing.gap + MediaQuery.paddingOf(context).top,
            tokens.spacing.page,
            tokens.spacing.section,
          ),
        ),
        itemCount: _entries.length,
        itemBuilder: fushiStaggeredItemBuilder((
          BuildContext context,
          int index,
        ) {
          final UpdateFeedEntryRow entry = _entries[index];
          return FushiGroupedListItem(
            index: index,
            count: _entries.length,
            onTap: () => _open(entry),
            child: _UpdateEntryTile(
              entry: entry,
              fresh: _fresh.contains(entry.entryId),
            ),
          );
        }),
      ),
    );
  }
}

/// 进更新中心默认落在哪个域。
///
/// 依次取：枚举序（番剧新集 → 漫画新章 → 漫画扩展 → 应用新版：内容在前，
/// 「有新版本」类提示在后）里第一个**有未读**的域；都没有未读时第一个**有记录**
/// 的域；一条记录都没有时番剧新集。番剧 / 漫画有新内容时不会被成串的应用新版
/// 盖住，而只有应用新版是新的时也能一进来就看到它。
UpdateFeedKind pickDefaultUpdateFeedFilter({
  required Set<UpdateFeedKind> unseen,
  required Set<UpdateFeedKind> present,
}) {
  for (final UpdateFeedKind kind in UpdateFeedKind.values) {
    if (unseen.contains(kind)) return kind;
  }
  for (final UpdateFeedKind kind in UpdateFeedKind.values) {
    if (present.contains(kind)) return kind;
  }
  return UpdateFeedKind.values.first;
}

/// 域的本地化名。放在这里而不是枚举里：`UpdateFeedKind` 要能在纯 Dart 单测里跑，
/// slang 的 `t` 需要 Flutter binding。
String updateFeedKindLabel(UpdateFeedKind kind) => switch (kind) {
  UpdateFeedKind.videoEpisode => t.updates_kind_video_episode,
  UpdateFeedKind.mangaChapter => t.updates_kind_manga_chapter,
  UpdateFeedKind.mangaExtension => t.updates_kind_manga_extension,
  UpdateFeedKind.appRelease => t.updates_kind_app_release,
};

IconData updateFeedKindIcon(UpdateFeedKind kind) => switch (kind) {
  UpdateFeedKind.videoEpisode => FushiIcons.video,
  UpdateFeedKind.mangaChapter => FushiIcons.manga,
  UpdateFeedKind.mangaExtension => FushiIcons.browserExtension,
  UpdateFeedKind.appRelease => FushiIcons.downloading,
};

class _UpdateEntryTile extends StatelessWidget {
  const _UpdateEntryTile({required this.entry, required this.fresh});

  final UpdateFeedEntryRow entry;

  /// 本次停留里算「新」（进页面时未读，见 `_fresh` 快照）。
  final bool fresh;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final UpdateFeedKind? kind = UpdateFeedKind.fromDbValue(entry.kind);
    final bool unseen = fresh;
    final Map<String, Object?> detail = decodeUpdateFeedDetail(
      entry.detailJson,
    );
    // 配图 / 发布时刻是域侧写进 detailJson 的可选投影（番剧域有，其余没有）；
    // 图文件可能已被封面 GC 收走，不在就退回域图标。
    final String? imagePath = detail['imagePath'] as String?;
    final bool hasImage = imagePath != null && File(imagePath).existsSync();
    final int? publishedAt = detail['publishedAt'] as int?;
    final String subtitle = <String>[
      if (entry.subtitle case final String s when s.isNotEmpty) s,
      if (publishedAt != null)
        FushiTimeFormat.dateHourMinute(
          DateTime.fromMillisecondsSinceEpoch(publishedAt),
        ),
    ].join(' · ');
    final IconData kindIcon = kind == null
        ? FushiIcons.notifications
        : updateFeedKindIcon(kind);
    // 未读 = primary 色块形状底，已读 = 中性底（M3E 行首图标底；Apple 下
    // FushiListLeadingIcon 自己换成 iOS 设置式图标方块）。
    final Widget kindLeading = FushiListLeadingIcon(
      kindIcon,
      shape: unseen ? FushiLeadingShape.cookie : FushiLeadingShape.circle,
      tone: unseen ? FushiCardTone.primary : FushiCardTone.neutral,
    );
    // 走共享的 FushiListItem 而不是裸 ListTile：普通页面外壳的 MD3 决策收口在
    // 组件层（m3e_design_system_static_test 守着这条），每页自己拼一遍 ListTile
    // 正是那条守卫要拦的东西。
    return FushiListItem(
      leading: hasImage
          ? ClipRRect(
              borderRadius: FushiM3eShape.smallRadius,
              child: Image.file(
                File(imagePath),
                width: 64,
                height: 36,
                fit: BoxFit.cover,
                // BUG-2496：坏图（截断/非图片字节）解码失败不再是致命
                // FlutterError，退回域图标并留一条诊断痕迹。
                errorBuilder: (_, Object error, __) {
                  ErrorLogService.instance.logDiagnostic(
                    'UpdatesCenterPage.coverDecode',
                    '$imagePath: $error',
                  );
                  return kindLeading;
                },
              ),
            )
          : kindLeading,
      title: Text(
        entry.title,
        style: unseen
            ? context.fushiType.bodyLargeEmphasized
            : context.fushiType.bodyLarge,
      ),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      subtitleMaxLines: 1,
      // 未读点：与「加粗 = 未读」同一个事实的第二个可见表征，不靠字重也能分辨。
      trailing: unseen
          ? DecoratedBox(
              decoration: BoxDecoration(
                color: isGlassDesign(context)
                    ? appleColorsOf(context).accent
                    : theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: const SizedBox.square(dimension: 8),
            )
          : null,
    );
  }
}

class _UpdatesEmptyState extends StatelessWidget {
  const _UpdatesEmptyState({required this.tokens});

  final FushiDesignTokens tokens;

  @override
  Widget build(BuildContext context) {
    // 统一空态：MD3 中性分组底块 / Apple 无底块大图标 + 灰字，各自在
    // FushiPlaceholderMessage 里分派；提示语作次级说明。
    return FushiPlaceholderMessage(
      icon: FushiIcons.notifications,
      message: t.updates_center_empty,
      detail: t.updates_center_empty_hint,
    );
  }
}
