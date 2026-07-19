import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/utils.dart';

/// 下载任务列表（计划状态 + 边下边播/删除 + 刷新）。下载页与下载对话框共用
/// （单一真相源）。自持状态：init 载入、动作后重载、刷新按钮催一轮 tick。
class DownloadTasksList extends ConsumerStatefulWidget {
  const DownloadTasksList({super.key, this.maxHeight, this.refreshSignal});

  /// 列表最大高度（对话框里限高 200；整页可传 null 让外层滚动）。
  final double? maxHeight;

  /// 外部重载信号：每次 tick（如 ValueNotifier 值变化）本列表重新载入计划。
  /// 调用方在推送新下载 / 关闭搜索对话框后 bump 它即可刷新，不必持有 State。
  final Listenable? refreshSignal;

  @override
  ConsumerState<DownloadTasksList> createState() => _DownloadTasksListState();
}

class _DownloadTasksListState extends ConsumerState<DownloadTasksList> {
  List<AnimeDownloadPlan> _plans = const <AnimeDownloadPlan>[];

  @override
  void initState() {
    super.initState();
    widget.refreshSignal?.addListener(_onSignal);
    unawaited(reload());
  }

  void _onSignal() => unawaited(reload());

  @override
  void didUpdateWidget(DownloadTasksList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) {
      oldWidget.refreshSignal?.removeListener(_onSignal);
      widget.refreshSignal?.addListener(_onSignal);
    }
  }

  @override
  void dispose() {
    widget.refreshSignal?.removeListener(_onSignal);
    super.dispose();
  }

  /// 重新从计划存储载入（新的在上）。
  Future<void> reload() async {
    final AnimeDownloadPlanStore? store =
        ref.read(appProvider).animeDownloadPlanStore;
    if (store == null) return;
    final List<AnimeDownloadPlan> plans = await store.loadAll();
    if (!mounted) return;
    setState(() => _plans = plans.reversed.toList(growable: false));
  }

  Future<void> _refresh() async {
    await reload();
    unawaited(ref.read(appProvider).animeDownloadService?.tick());
  }

  Future<void> _delete(AnimeDownloadPlan plan) async {
    final AnimeDownloadPlanStore? store =
        ref.read(appProvider).animeDownloadPlanStore;
    if (store == null) return;
    await store.delete(plan.id);
    await reload();
  }

  Future<void> _playNow(AnimeDownloadPlan plan) async {
    final bool ok =
        await ref.read(appProvider).animeDownloadService?.importNow(plan.id) ??
            false;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          ok ? t.anime_download_play_now_ok : t.anime_download_play_now_fail),
    ));
    if (ok) await reload();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget list = _plans.isEmpty
        ? Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              t.anime_download_no_tasks,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          )
        : ListView.builder(
            shrinkWrap: true,
            itemCount: _plans.length,
            itemBuilder: (BuildContext context, int i) =>
                _buildRow(theme, _plans[i]),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '${t.anime_download_tasks} (${_plans.length})',
                style: theme.textTheme.titleSmall,
              ),
            ),
            TextButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(t.anime_download_refresh),
            ),
          ],
        ),
        if (widget.maxHeight != null)
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxHeight!),
            child: list,
          )
        else
          list,
      ],
    );
  }

  Widget _buildRow(ThemeData theme, AnimeDownloadPlan plan) {
    final ColorScheme scheme = theme.colorScheme;
    final Widget statusIcon = switch (plan.status) {
      AnimeDownloadPlan.statusImported =>
        Icon(Icons.check_circle_outline, size: 20, color: scheme.primary),
      AnimeDownloadPlan.statusFailed => Tooltip(
          message: plan.failReason ?? '',
          child: Icon(Icons.error_outline, size: 20, color: scheme.error),
        ),
      _ => const SizedBox(
          width: 20,
          height: 20,
          child: Padding(
            padding: EdgeInsets.all(2),
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
    };
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: statusIcon,
      title:
          Text(plan.seriesTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        plan.torrentTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (plan.status == AnimeDownloadPlan.statusDownloading)
            IconButton(
              tooltip: t.anime_download_play_now,
              icon: const Icon(Icons.play_circle_outline, size: 20),
              onPressed: () => _playNow(plan),
            ),
          IconButton(
            tooltip: t.anime_download_delete,
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: () => _delete(plan),
          ),
        ],
      ),
    );
  }
}
