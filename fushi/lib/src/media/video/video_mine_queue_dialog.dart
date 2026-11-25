import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/mining/video_mine_queue.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_anki/fushi_anki.dart' show BaseAnkiRepository;
import 'package:fushi/src/mining/web_mine_queue_store.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
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

/// 一批写入结束后的汇总提示：张数，加上写入的卡带回的提示（如「保存到」被主机退回默认，
/// BUG-4287）——批量写入没有逐张的结果提示，汇总这一条不带它，用户就永远不知道落点变了。
/// 有没送到的（后端不可达，留作待办、下次自动再试）另起一行说清楚，不混进「失败」。
String videoMineCommitMessage(VideoMineCommitSummary summary) => <String>[
  t.video_mine_queue_committed(ok: summary.succeeded, failed: summary.failed),
  if (summary.undelivered > 0)
    t.video_mine_queue_committed_undelivered(count: summary.undelivered),
  ?summary.notice,
].join('\n');

/// 失败行副标题里的原因：已知的固定标记（重复卡、视频到不了）换成本地化说明，其余原样
/// （引擎 / Anki 带回的原因本身就是给人看的）。本地「待制卡」与网页视频「制卡队列」共用。
String mineQueueFailureText(String? error) => switch (error) {
  WebMineQueueStore.duplicateError => t.video_mine_queue_reason_duplicate,
  'navigate_timeout' => t.web_video_mine_queue_reason_unreachable,
  _ => error ?? '',
};

/// 汇总提示的级别：有失败、没送到或带回提示都是 warning（关掉「制卡成功提示」也照样
/// 要让用户看到）。
ToastSeverity videoMineCommitSeverity(VideoMineCommitSummary summary) =>
    summary.failed == 0 && summary.undelivered == 0 && summary.notice == null
    ? ToastSeverity.success
    : ToastSeverity.warning;

/// 离开播放页之后，在后台把 [bookUid] 的待制卡写进 Anki：先等 [inFlight]（还在准备
/// 媒体的暂存任务）收尾，再 [VideoMineQueue.commitAll]。只写待写入的行（含上次因后端
/// 不可达没送到的），不重排之前写入失败的——那是待制卡列表里「全部写入」的事。
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
      final VideoMineCommitSummary? summary = await commitPendingVideoMines(
        queue: queue,
        bookUid: bookUid,
        repo: repo,
        inFlight: inFlight,
      );
      if (summary == null) return;
      FushiToast.show(
        msg: videoMineCommitMessage(summary),
        severity: videoMineCommitSeverity(summary),
      );
    } catch (error, stack) {
      try {
        ErrorLogService.instance.log('mineVideoCard.flushStaged', error, stack);
      } catch (_) {}
    }
  }());
}

/// [commitStagedVideoMinesAfterExit] 的写入本体（不报 toast、不吞错，便于测试）：等
/// [inFlight] 收尾后，把 [bookUid] **待写入**的暂存卡写进 Anki。这一趟一行都没写
/// （没有待写入的行）返回 `null`——只剩写入失败的行时什么都不做，它们留在列表里等
/// 用户手动重试（BUG-4813）。
///
/// 「有没有待写入的行」只在 [VideoMineQueue.commitAll] 的串行链里面判（看它实际处理
/// 了几行），不在排队之前先查一遍：排队期间另一次写入（列表里的「全部写入」、
/// `video mine-send`）可能正好把这些行写完，先查的那一眼就过期了，会报出一条
/// 「成功 0、失败 0」。
Future<VideoMineCommitSummary?> commitPendingVideoMines({
  required Future<VideoMineQueue> queue,
  required String bookUid,
  required BaseAnkiRepository repo,
  required List<Future<void>> inFlight,
}) async {
  await Future.wait(inFlight);
  final VideoMineQueue resolved = await queue;
  final VideoMineCommitSummary summary = await resolved.commitAll(
    bookUid: bookUid,
    repo: repo,
    retryFailed: false,
  );
  return summary.attempted == 0 ? null : summary;
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

  /// 有失败、弹窗留着时，上一轮写入带回的提示（[VideoMineCommitSummary.notice]）显示在列表上方；
  /// 全部成功时汇总交回调用方报，这里不留。
  String? _notice;

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

  Future<void> _retry(WebMineQueueRow row) async {
    await widget.queue.retry(row.id);
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
    setState(() {
      _progress = null;
      _notice = summary.notice ?? _notice;
    });
    if (summary.failed == 0 && summary.undelivered == 0) {
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
    return FushiAlertDialog(
      title: Text(t.video_mine_queue_title),
      content: SizedBox(
        width: 520,
        child: _loading
            ? const FushiLoadingView()
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (progress != null) ...<Widget>[
                    FushiLinearProgressIndicator(
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
                  if (_notice case final String notice) ...<Widget>[
                    Text(notice, style: TextStyle(color: cs.tertiary)),
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
                          // 待办却带着原因 = 上次后端不可达没送到，下次自动再试。
                          final String? undelivered = failed ? null : row.error;
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
                                      reason: mineQueueFailureText(row.error),
                                    )
                                  : undelivered != null
                                  ? t.video_mine_queue_undelivered(
                                      reason: undelivered,
                                    )
                                  : row.sentence,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: failed
                                  ? TextStyle(color: cs.error)
                                  : undelivered != null
                                  ? TextStyle(color: cs.tertiary)
                                  : null,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                // 单行重试：重复卡也能点（用户多半已在 Anki 删了那张）；
                                // 「全部写入」的批量重排会跳过重复卡。
                                if (failed)
                                  FushiIconButtonControl(
                                    tooltip: t.video_mine_queue_retry,
                                    icon: const FushiIcon(FushiIcons.refresh),
                                    onPressed: busy ? null : () => _retry(row),
                                  ),
                                FushiIconButtonControl(
                                  tooltip: t.video_mine_queue_remove,
                                  icon: const FushiIcon(Icons.delete_outline),
                                  onPressed: busy ? null : () => _remove(row),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: Text(t.dialog_close),
        ),
        FushiFilledButton(
          // 只剩重复卡时「全部写入」无事可做（批量重排跳过重复卡），按钮灰掉。
          onPressed:
              busy ||
                  !_rows.any(
                    (WebMineQueueRow r) =>
                        r.error != WebMineQueueStore.duplicateError,
                  )
              ? null
              : _commitAll,
          child: Text(t.video_mine_queue_commit_all),
        ),
      ],
    );
  }
}
