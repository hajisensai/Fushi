/// 首页 dashboard 顶部的更新横幅（v101）。
///
/// 只在**有未读**时挂载：没有更新的日子里首页不该多一块常驻空卡。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/pages/implementations/updates_center_open.dart';
import 'package:fushi/src/pages/implementations/updates_center_page.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/utils.dart';

class UpdatesDashboardBanner extends StatefulWidget {
  const UpdatesDashboardBanner({super.key, required this.service});

  final UpdateFeedService service;

  @override
  State<UpdatesDashboardBanner> createState() => _UpdatesDashboardBannerState();
}

class _UpdatesDashboardBannerState extends State<UpdatesDashboardBanner> {
  Map<UpdateFeedKind, int> _counts = const <UpdateFeedKind, int>{};
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    // 走 service 的 tableUpdates 信号流，**不是**裸 `select(...).watch()`：drift 的
    // QueryStream 在 dispose 取消时会排一个 Timer.run，widget 测试里「构建再卸载」
    // 的用例会因此全红（BUG-834）。
    _changes = widget.service.watchChanged().listen((_) => _reload());
    _reload();
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  Future<void> _reload() async {
    final Map<UpdateFeedKind, int> counts = await widget.service.unseenCounts();
    if (!mounted) return;
    setState(() => _counts = counts);
  }

  int get _total => _counts.values.fold<int>(0, (int a, int b) => a + b);

  Future<void> _openCenter() async {
    await openUpdatesCenter(context, widget.service);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final int total = _total;
    if (total == 0) return const SizedBox.shrink();
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    // 下间距挂在**有内容的那一支**上，不在调用方：调用方在构建时还不知道计数
    // （异步），在外面写死一个 SizedBox 会让没有更新时首页顶部空出一条。
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.card),
      child: FushiCard(
        padding: EdgeInsets.zero,
        margin: EdgeInsets.zero,
        child: FushiListItem(
          leading: Badge(
            label: Text('$total'),
            child: Icon(
              Icons.notifications_active_outlined,
              color: theme.colorScheme.primary,
            ),
          ),
          title: Text(t.updates_center_title),
          subtitle: Text(_summary()),
          subtitleMaxLines: 1,
          trailing: const Icon(Icons.chevron_right),
          onTap: _openCenter,
          padding: EdgeInsets.all(tokens.spacing.gap),
        ),
      ),
    );
  }

  /// 「番剧新集 3 · 漫画新章 12」——按域列未读数，用户一眼看出是哪类更新。
  String _summary() => <String>[
        for (final UpdateFeedKind kind in UpdateFeedKind.values)
          if ((_counts[kind] ?? 0) > 0)
            '${updateFeedKindLabel(kind)} ${_counts[kind]}',
      ].join(' · ');
}
