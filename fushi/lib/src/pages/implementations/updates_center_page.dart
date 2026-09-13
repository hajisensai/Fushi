import 'dart:io' show File;

import 'package:flutter/material.dart';
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
  const UpdatesCenterPage({
    super.key,
    required this.service,
    this.onOpenEntry,
  });

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final List<UpdateFeedEntryRow> rows = await widget.service.entries(
      kinds: _filter == null
          ? const <UpdateFeedKind>{}
          : <UpdateFeedKind>{_filter!},
    );
    if (!mounted) return;
    setState(() {
      _entries = rows;
      _loading = false;
    });
  }

  Future<void> _markAllSeen() async {
    await widget.service.markAllSeen(kind: _filter);
    if (!mounted) return;
    await _load();
  }

  Future<void> _open(UpdateFeedEntryRow entry) async {
    // 先标已读再跳转：跳转可能把本页顶掉（push 新路由），之后的 setState 就到不
    // 了了；而「点开过」这个事实不该取决于跳转成功与否。
    await widget.service.markSeen(<String>[entry.entryId]);
    if (mounted) await _load();
    await widget.onOpenEntry?.call(entry);
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: t.updates_center_title,
      actions: <Widget>[
        FushiIconButton(
          icon: Icons.done_all_outlined,
          tooltip: t.updates_mark_all_seen,
          onTap: _entries.isEmpty ? null : _markAllSeen,
        ),
        FushiIconButton(
          icon: Icons.refresh,
          tooltip: t.refresh,
          onTap: _loading ? null : _load,
        ),
      ],
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildFilters(tokens),
        Expanded(child: _buildList(tokens)),
      ],
    );
  }

  Widget _buildFilters(FushiDesignTokens tokens) {
    // 横向滚动区必须包 HorizontalDragScrollable：桌面端默认 dragDevices 不含
    // mouse，不包就是「鼠标拖不动」（守卫 horizontal_drag_scroll_guard 盯着）。
    return HorizontalDragScrollable(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: tokens.spacing.gap),
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
      child: ChoiceChip(
        label: Text(label),
        selected: _filter == kind,
        onSelected: (bool selected) {
          if (!selected) return;
          setState(() => _filter = kind);
          _load();
        },
      ),
    );
  }

  Widget _buildList(FushiDesignTokens tokens) {
    if (_loading) return buildLoading();
    if (_entries.isEmpty) {
      return _UpdatesEmptyState(tokens: tokens);
    }
    return ListView.builder(
      padding: EdgeInsets.all(tokens.spacing.gap),
      itemCount: _entries.length,
      itemBuilder: (BuildContext context, int index) {
        final UpdateFeedEntryRow entry = _entries[index];
        return _UpdateEntryTile(
          entry: entry,
          onTap: () => _open(entry),
        );
      },
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
      UpdateFeedKind.videoEpisode => Icons.movie_outlined,
      UpdateFeedKind.mangaChapter => Icons.photo_library_outlined,
      UpdateFeedKind.mangaExtension => Icons.extension_outlined,
      UpdateFeedKind.appRelease => Icons.system_update_outlined,
    };

class _UpdateEntryTile extends StatelessWidget {
  const _UpdateEntryTile({required this.entry, required this.onTap});

  final UpdateFeedEntryRow entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final UpdateFeedKind? kind = UpdateFeedKind.fromDbValue(entry.kind);
    final bool unseen = entry.seenAt == null;
    final Map<String, Object?> detail = decodeUpdateFeedDetail(entry.detailJson);
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
    // 走共享的 FushiListItem 而不是裸 ListTile：普通页面外壳的 MD3 决策收口在
    // 组件层（md3_design_system_static_test 守着这条），每页自己拼一遍 ListTile
    // 正是那条守卫要拦的东西。
    return FushiListItem(
      leading: hasImage
          ? ClipRRect(
              borderRadius: BorderRadius.circular(6),
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
                  return Icon(
                    kind == null
                        ? Icons.notifications_outlined
                        : updateFeedKindIcon(kind),
                    color: unseen
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  );
                },
              ),
            )
          : Icon(
              kind == null
                  ? Icons.notifications_outlined
                  : updateFeedKindIcon(kind),
              color:
                  unseen ? theme.colorScheme.primary : theme.colorScheme.outline,
            ),
      title: Text(
        entry.title,
        style: unseen
            ? theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)
            : theme.textTheme.bodyLarge,
      ),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      subtitleMaxLines: 1,
      // 未读点：与「加粗 = 未读」同一个事实的第二个可见表征，不靠字重也能分辨。
      trailing: unseen
          ? Icon(Icons.circle, size: 8, color: theme.colorScheme.primary)
          : null,
      onTap: onTap,
    );
  }
}

class _UpdatesEmptyState extends StatelessWidget {
  const _UpdatesEmptyState({required this.tokens});

  final FushiDesignTokens tokens;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.card),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.notifications_none_outlined,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            SizedBox(height: tokens.spacing.gap),
            Text(t.updates_center_empty, style: theme.textTheme.titleMedium),
            SizedBox(height: tokens.spacing.gap),
            Text(
              t.updates_center_empty_hint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}
