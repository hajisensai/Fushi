import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';

/// 可以对一批选中任务执行的动作。
///
/// 与 [DownloadTaskActions] 的槽位一一对应；不含 setPriority（它还要带一个档位
/// 参数，走单独入口）与 reveal（批量打开 N 个文件管理器窗口是骚扰不是便利）。
enum DownloadBatchAction { pause, resume, retry, cancel, clear, delete }

/// 一次批量操作的结果。
///
/// [unsupported] 与 [failed] 是**两回事**：前者是这条任务的来源根本没有这个动作
/// （单跑道队列没有暂停、mokuro 删不了磁盘文件），后者是支持但执行时出错。混成
/// 一个数字会让用户以为「失败了、再试一次就好」，而实际上再试一百次也一样。
class DownloadBatchOutcome {
  const DownloadBatchOutcome({
    this.done = 0,
    this.unsupported = 0,
    this.failed = 0,
  });

  /// 真正执行成功的条数。
  final int done;

  /// 因来源不支持该动作被跳过的条数。
  final int unsupported;

  /// 支持该动作但执行时抛错的条数。
  final int failed;

  int get total => done + unsupported + failed;

  bool get isEmpty => total == 0;
}

/// 取一条任务在某个批量动作下的执行体；来源不支持该动作时返回 null。
///
/// [deleteFiles] 只对 [DownloadBatchAction.delete] 有意义，由调用方在弹过**一次**
/// 确认框之后定死，逐条复用。
Future<void> Function()? downloadTaskBatchCallable(
  DownloadTaskEntry task,
  DownloadBatchAction action, {
  bool deleteFiles = false,
}) {
  final DownloadTaskActions actions = task.actions;
  return switch (action) {
    DownloadBatchAction.pause => actions.pause,
    DownloadBatchAction.resume => actions.resume,
    DownloadBatchAction.retry => actions.retry,
    DownloadBatchAction.cancel => actions.cancel,
    DownloadBatchAction.clear => actions.clear,
    DownloadBatchAction.delete => actions.delete == null
        ? null
        : () => actions.delete!(deleteFiles: deleteFiles),
  };
}

/// 选中集里有几条真的支持这个动作——按钮的可用态判据。
///
/// 一条都不支持时按钮直接禁用：摆一个点下去只会弹「0 条已处理」的按钮，比没有
/// 这个按钮更糟。
int countDownloadTasksSupporting(
  Iterable<DownloadTaskEntry> tasks,
  DownloadBatchAction action,
) {
  int count = 0;
  for (final DownloadTaskEntry task in tasks) {
    if (downloadTaskBatchCallable(task, action) != null) count++;
  }
  return count;
}

/// 对一批任务串行执行同一个动作。
///
/// **串行而非并发**：这些动作最终落到 torrent 后端与 SQLite 上，并发只会把「一批
/// 操作」变成「一批竞态」（同一后端的暂停/恢复、同一张表的生命周期 CAS）；顺序
/// 执行也让结果计数与用户看到的列表顺序对得上。
///
/// **单条抛错不中断整批**：一条失败就整批停下，用户既不知道做成了几条，也不知道
/// 从哪条开始没做——那比部分成功更难收拾。错误计入 [DownloadBatchOutcome.failed]。
Future<DownloadBatchOutcome> runDownloadTaskBatch({
  required Iterable<DownloadTaskEntry> tasks,
  required DownloadBatchAction action,
  bool deleteFiles = false,
  void Function(Object error, StackTrace stackTrace)? onError,
}) async {
  int done = 0;
  int unsupported = 0;
  int failed = 0;
  for (final DownloadTaskEntry task in tasks) {
    final Future<void> Function()? callable = downloadTaskBatchCallable(
      task,
      action,
      deleteFiles: deleteFiles,
    );
    if (callable == null) {
      unsupported++;
      continue;
    }
    try {
      await callable();
      done++;
    } on Object catch (error, stackTrace) {
      failed++;
      onError?.call(error, stackTrace);
    }
  }
  return DownloadBatchOutcome(
    done: done,
    unsupported: unsupported,
    failed: failed,
  );
}

/// 批量结果的用户可见描述：只拼非零的段，用 ' · ' 连接。
///
/// 「不支持」与「失败」分开说，因为用户的下一步动作不同：前者再点一百次也一样，
/// 后者值得重试。三段全为零时返回空串，调用方据此不弹提示。
String describeDownloadBatchOutcome(DownloadBatchOutcome outcome) {
  final List<String> parts = <String>[
    if (outcome.done > 0) t.download_batch_done(n: outcome.done),
    if (outcome.unsupported > 0)
      t.download_batch_unsupported(n: outcome.unsupported),
    if (outcome.failed > 0) t.download_batch_failed(n: outcome.failed),
  ];
  return parts.join(' · ');
}
