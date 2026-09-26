import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/mining/video_mine_queue.dart';
import 'package:fushi_anki/fushi_anki.dart' show BaseAnkiRepository;
import 'package:fushi/src/mining/web_mine_queue_store.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 「看完再制卡」的待制卡列表：看暂存了哪些卡、删掉点错的、一键全部写入 Anki。
///
/// 写入由调用方给的 [commit] 执行（视频页装配 Anki 后端、写完刷新角标）；本弹窗只负责
/// 展示进度、写完重载列表。全部写成功就自己关掉并把汇总交回去（调用方用 OSD 报告），
/// 有失败的留着显示原因，可删可重试。
Future<VideoMineCommitSummary?> showVideoMineQueueDialog({
  required BuildContext context,
  required VideoMineQueue queue,
  required String bookUid,
  required Future<VideoMineCommitSummary> Function(
    void Function(int done, int total) onProgress,
  )
  commit,
  VoidCallback? onChanged,
}) {
  return showAppDialog<VideoMineCommitSummary>(
    context: context,
    builder: (_) => VideoMineQueueDialog(
      queue: queue,
      bookUid: bookUid,
      commit: commit,
      onChanged: onChanged,
    ),
  );
}

/// 离开播放页之后，在后台把 [bookUid] 的待制卡写进 Anki：先等 [inFlight]（还在准备
/// 媒体的暂存任务）收尾，再 [VideoMineQueue.commitAll]。
///
/// 结果用全局 toast 报：此时播放页和它左上角的 OSD 都已不在。视频页自己「提示只走
/// OSD、不用 toast」（BUG-931）约束的是页面在场的时候——toast 会被视频画面挡住；退出
/// 之后用户在书架 / 首页，toast 正是看得见的那一层。列表为空时什么都不报。
void commitStagedVideoMinesAfterExit({
  required Future<VideoMineQueue> queue,
  required String bookUid,
  required BaseAnkiRepository repo,
  required List<Future<void>> inFlight,
}) {
  unawaited(() async {
    try {
      await Future.wait(inFlight);
      final VideoMineQueue resolved = await queue;
      if ((await resolved.pending(bookUid)).isEmpty &&
          (await resolved.failed(bookUid)).isEmpty) {
        return;
      }
      final VideoMineCommitSummary summary = await resolved.commitAll(
        bookUid: bookUid,
        repo: repo,
      );
      FushiToast.show(
        msg: t.video_mine_queue_committed(
          ok: summary.succeeded,
          failed: summary.failed,
        ),
        severity: summary.failed == 0
            ? ToastSeverity.success
            : ToastSeverity.warning,
      );
    } catch (error, stack) {
      try {
        ErrorLogService.instance.log('mineVideoCard.flushStaged', error, stack);
      } catch (_) {}
    }
  }());
}

/// 导出 widget 便于测试直接构造。
class VideoMineQueueDialog extends StatefulWidget {
  const VideoMineQueueDialog({
    required this.queue,
    required this.bookUid,
    required this.commit,
    this.onChanged,
    super.key,
  });

  final VideoMineQueue queue;
  final String bookUid;
  final Future<VideoMineCommitSummary> Function(
    void Function(int done, int total) onProgress,
  )
  commit;
  final VoidCallback? onChanged;

  @override
  State<VideoMineQueueDialog> createState() => _VideoMineQueueDialogState();
}

class _VideoMineQueueDialogState extends State<VideoMineQueueDialog> {
  List<WebMineQueueRow> _rows = const <WebMineQueueRow>[];
  bool _loading = true;
  ({int done, int total})? _progress;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final List<WebMineQueueRow> failed = await widget.queue.failed(
      widget.bookUid,
    );
    final List<WebMineQueueRow> pending = await widget.queue.pending(
      widget.bookUid,
    );
    if (!mounted) return;
    setState(() {
      _rows = <WebMineQueueRow>[...failed, ...pending]
        ..sort((WebMineQueueRow a, WebMineQueueRow b) => a.id.compareTo(b.id));
      _loading = false;
    });
  }

  Future<void> _remove(WebMineQueueRow row) async {
    await widget.queue.discard(row.id);
    widget.onChanged?.call();
    await _reload();
  }

  Future<void> _commitAll() async {
    setState(() => _progress = (done: 0, total: _rows.length));
    final VideoMineCommitSummary summary = await widget.commit((
      int done,
      int total,
    ) {
      if (mounted) setState(() => _progress = (done: done, total: total));
    });
    if (!mounted) return;
    setState(() => _progress = null);
    if (summary.failed == 0) {
      Navigator.of(context).pop(summary);
      return;
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final ({int done, int total})? progress = _progress;
    final bool busy = progress != null;
    return AlertDialog(
      title: Text(t.video_mine_queue_title),
      content: SizedBox(
        width: 520,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (progress != null) ...<Widget>[
                    LinearProgressIndicator(
                      value: progress.total == 0
                          ? null
                          : progress.done / progress.total,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      t.video_mine_queue_committing(
                        done: progress.done,
                        total: progress.total,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_rows.isEmpty)
                    Text(t.video_mine_queue_empty)
                  else
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _rows.length,
                        itemBuilder: (BuildContext context, int index) {
                          final WebMineQueueRow row = _rows[index];
                          final Map<String, String> fields =
                              decodeWebMineFields(row.fieldsJson);
                          final String word = fields['expression'] ?? '';
                          final bool failed =
                              row.status == WebMineQueueStatus.failed;
                          return FushiListItem(
                            key: ValueKey<String>('video-mine-queue-${row.id}'),
                            density: FushiListDensity.compact,
                            title: Text(
                              word.isEmpty ? row.sentence : word,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              failed
                                  ? t.video_mine_queue_failed(
                                      reason: row.error ?? '',
                                    )
                                  : row.sentence,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: failed ? TextStyle(color: cs.error) : null,
                            ),
                            trailing: IconButton(
                              tooltip: t.video_mine_queue_remove,
                              icon: const Icon(Icons.delete_outline),
                              onPressed: busy ? null : () => _remove(row),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: Text(t.dialog_close),
        ),
        FilledButton(
          onPressed: busy || _rows.isEmpty ? null : _commitAll,
          child: Text(t.video_mine_queue_commit_all),
        ),
      ],
    );
  }
}
