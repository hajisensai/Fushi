import 'dart:async' show unawaited;
import 'dart:io' show File;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart' show UpdateFeedEntryRow;

import 'package:fushi/src/pages/fushi_page_placeholders.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/utils.dart';

/// 更新中心（v101）：四个域的更新事件汇成一页。
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

  /// null = 全部域。
  UpdateFeedKind? _filter;

  /// 进页面那一刻的未读条目。进页面即全部标已读（见 [_enter]），之后切到别的
  /// 域从库里读回来的已经全是已读——「这次停留里哪些是新的」只能看这份快照。
  /// 点开一条 / 「全部标为已读」时从这里摘掉。
  Set<String> _fresh = <String>{};

  /// 进页面快照最多看这么多条（按时间倒序）：只用来保存本次高亮，
  /// 远超一屏的旧条目不影响这两个判断。
  static const int _kSnapshotLimit = 1000;

  @override
  void initState() {
    super.initState();
    _enter();
  }

  /// 进页面 = 已读。用户点进来的动作本身就是「我看到了」，不该进来之后还要再
  /// 按一次「全部已读」才能把首页角标和系统通知消掉。先取未读快照（本次停留的高亮）再标；[markAllSeen] 顺带撤系统通知。
  Future<void> _enter() async {
    final List<UpdateFeedEntryRow> all = await widget.service.entries(
      limit: _kSnapshotLimit,
    );
    if (!mounted) return;
    final Set<String> fresh = <String>{};
    for (final UpdateFeedEntryRow row in all) {
      final UpdateFeedKind? kind = UpdateFeedKind.fromDbValue(row.kind);
      if (kind == null) continue;
      if (row.seenAt == null) {
        fresh.add(row.entryId);
      }
    }
    _fresh = fresh;

    await _load();
    await widget.service.markAllSeen();
  }

  Future<void> _load() async {
    final UpdateFeedKind? kind = _filter;
    setState(() => _loading = true);
    final List<UpdateFeedEntryRow> rows = await widget.service.entries(
      kinds: kind == null ? const <UpdateFeedKind>{} : <UpdateFeedKind>{kind},
    );
    // 加载期间又切了域：这份结果已经过时，交给后发的那次加载。
    if (!mounted || kind != _filter) return;
    setState(() {
      _entries = rows;
      _loading = false;
    });
  }

  void _select(UpdateFeedKind? kind) {
    if (kind == _filter) return;
    setState(() => _filter = kind);
    unawaited(_load());
  }

  /// 全部域标已读。进页面时库里已经全标过了，这里收掉的是本次停留的「新」
  /// 高亮，保持「全部标为已读」的全域语义。
  Future<void> _markAllSeen() async {
    await widget.service.markAllSeen();
    if (!mounted) return;
    setState(() => _fresh = <String>{});
    await _load();
  }

  /// 清空当前筛选下的全部记录（「全部」= 四个域一起清）。先确认。
  Future<void> _clear() async {
    final UpdateFeedKind? kind = _filter;
    final FushiDestructiveConfirmResult? confirmed =
        await showAppDialog<FushiDestructiveConfirmResult>(
          context: context,
          builder: (BuildContext dialogContext) =>
              FushiDestructiveConfirmDialog(
                title: t.updates_history_clear_confirm_title,
                message: t.updates_history_clear_confirm_body(
                  scope: kind == null
                      ? t.updates_filter_all
                      : updateFeedKindLabel(kind),
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
      actions: <Widget>[
        FushiIconButton(
          icon: FushiIcons.checklist,
          tooltip: t.updates_mark_all_seen,
          onTap: _entries.isEmpty ? null : _markAllSeen,
        ),
        FushiIconButton(
          icon: FushiIcons.deleteSweep,
          tooltip: t.updates_history_clear,
          onTap: _loading || _entries.isEmpty ? null : _clear,
        ),
        FushiIconButton(
          icon: FushiIcons.refresh,
          tooltip: t.refresh,
          onTap: _loading ? null : _load,
        ),
      ],
      // 域筛选条原本固定在正文顶部：页头浮在正文上之后会被胶囊盖住，所以随
      // 页头一起进 headerBottom（页头 → 筛选纵向堆叠、一起收起）。
      headerBottom: _buildFilters(),
      // Builder：正文要在页头脚手架之内取 MediaQuery 顶部让位（状态栏 + 浮动
      // 页头含筛选条）。
      body: Builder(builder: _buildList),
    );
  }

  Widget _buildFilters() {
    // 横向滚动区必须包 HorizontalDragScrollable：桌面端默认 dragDevices 不含
    // mouse，不包就是「鼠标拖不动」（守卫 horizontal_drag_scroll_guard 盯着）。
    return HorizontalDragScrollable(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // 挂在页头 headerBottom 里：页头已有左右内边距，这里不再叠加。
        child: Row(
          children: <Widget>[
            _filterChip(label: t.updates_filter_all, kind: null),
            for (final UpdateFeedKind kind in UpdateFeedKind.values)
              _filterChip(label: updateFeedKindLabel(kind), kind: kind),
          ],
        ),
      ),
    );
  }

  Widget _filterChip({required String label, required UpdateFeedKind? kind}) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FushiChoiceChip(
        label: Text(label),
        selected: _filter == kind,
        onSelected: (bool selected) {
          if (!selected) return;
          _select(kind);
        },
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
