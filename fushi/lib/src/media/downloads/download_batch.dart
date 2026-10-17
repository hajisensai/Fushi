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
    DownloadBatchAction.delete =>
      actions.delete == null
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

/// 「清除已完成」里一条已完成任务会被怎样处理。
///
/// 来源能力天然不齐，所以「清除已完成」不能简单地对每条调 clear 或 delete：
/// - 只有 [DownloadTaskActions.clear] 的（直链 / mokuro / 漫画 / 转录）只能移出列表；
/// - 只有能删文件的 [DownloadTaskActions.delete] 的（video job、扩展源成品）没有
///   「只清记录」——它们的 delete 会联动删库行、摘种子，不勾「同时删除文件」时
///   绝不能拿它冒充清除；
/// - delete 兑现不了删文件（[DownloadTaskActions.deletesFiles] 为 false）的，
///   deleteFiles 参数的语义由来源决定（对端 host 的老版本缺省会连数据一起删），
///   一律不碰。
enum DownloadClearCompletedDisposition {
  /// 只移出列表，文件留着（用户没勾「同时删除文件」）。
  clearRecord,

  /// 删除任务并连带删除已下载文件。
  deleteFiles,

  /// 用户勾了「同时删除文件」，但这条来源删不了文件：只移出列表。
  clearRecordKeepFiles,

  /// 按用户的选择这条做不了任何事，原样留在列表里。
  untouched,
}

/// 这条任务真能连文件一起删吗（[DownloadTaskActions.delete] 在且兑现得了删文件）。
bool downloadTaskCanDeleteFiles(DownloadTaskEntry task) =>
    task.actions.delete != null && task.actions.deletesFiles;

/// 按用户是否勾了「同时删除文件」，判定一条已完成任务的处理方式。
DownloadClearCompletedDisposition downloadClearCompletedDisposition(
  DownloadTaskEntry task, {
  required bool deleteFiles,
}) {
  final bool hasClear = task.actions.clear != null;
  if (deleteFiles) {
    if (downloadTaskCanDeleteFiles(task)) {
      return DownloadClearCompletedDisposition.deleteFiles;
    }
    return hasClear
        ? DownloadClearCompletedDisposition.clearRecordKeepFiles
        : DownloadClearCompletedDisposition.untouched;
  }
  return hasClear
      ? DownloadClearCompletedDisposition.clearRecord
      : DownloadClearCompletedDisposition.untouched;
}

/// 「清除已完成」的处理对象：可见行里状态为 [DownloadTaskStatus.completed] 的条目。
List<DownloadTaskEntry> selectCompletedDownloadTasks(
  Iterable<DownloadTaskEntry> rendered,
) => rendered
    .where(
      (DownloadTaskEntry task) => task.status == DownloadTaskStatus.completed,
    )
    .toList();

/// 「清除已完成」入口要不要摆出来：至少有一条已完成任务在某种选择下能被处理。
bool canClearCompletedDownloadTasks(Iterable<DownloadTaskEntry> completed) =>
    completed.any(
      (DownloadTaskEntry task) =>
          task.actions.clear != null || downloadTaskCanDeleteFiles(task),
    );

/// 一次「清除已完成」的结果；各段互斥，[total] 等于处理对象的条数。
class DownloadClearCompletedOutcome {
  const DownloadClearCompletedOutcome({
    this.cleared = 0,
    this.filesDeleted = 0,
    this.clearedKeptFiles = 0,
    this.untouched = 0,
    this.failed = 0,
  });

  /// 只移出列表（未勾删除文件）。
  final int cleared;

  /// 连同已下载文件一起删除。
  final int filesDeleted;

  /// 勾了删除文件但来源删不了，只移出了列表。
  final int clearedKeptFiles;

  /// 按用户的选择做不了，原样保留在列表里。
  final int untouched;

  /// 执行时抛错。
  final int failed;

  int get total =>
      cleared + filesDeleted + clearedKeptFiles + untouched + failed;
}

/// 对已定死的一批已完成任务执行「清除已完成」，串行、单条失败不中断整批
/// （理由同 [runDownloadTaskBatch]）。
Future<DownloadClearCompletedOutcome> runDownloadClearCompleted({
  required Iterable<DownloadTaskEntry> tasks,
  required bool deleteFiles,
  void Function(Object error, StackTrace stackTrace)? onError,
}) async {
  int cleared = 0;
  int filesDeleted = 0;
  int clearedKeptFiles = 0;
  int untouched = 0;
  int failed = 0;
  for (final DownloadTaskEntry task in tasks) {
    final DownloadClearCompletedDisposition disposition =
        downloadClearCompletedDisposition(task, deleteFiles: deleteFiles);
    try {
      switch (disposition) {
        case DownloadClearCompletedDisposition.clearRecord:
          await task.actions.clear!();
          cleared++;
        case DownloadClearCompletedDisposition.deleteFiles:
          await task.actions.delete!(deleteFiles: true);
          filesDeleted++;
        case DownloadClearCompletedDisposition.clearRecordKeepFiles:
          await task.actions.clear!();
          clearedKeptFiles++;
        case DownloadClearCompletedDisposition.untouched:
          untouched++;
      }
    } on Object catch (error, stackTrace) {
      failed++;
      onError?.call(error, stackTrace);
    }
  }
  return DownloadClearCompletedOutcome(
    cleared: cleared,
    filesDeleted: filesDeleted,
    clearedKeptFiles: clearedKeptFiles,
    untouched: untouched,
    failed: failed,
  );
}

/// 「清除已完成」结果的用户可见描述：只拼非零段，用 ' · ' 连接。
String describeDownloadClearCompletedOutcome(
  DownloadClearCompletedOutcome outcome,
) {
  final List<String> parts = <String>[
    if (outcome.cleared > 0)
      t.download_clear_completed_result_cleared(n: outcome.cleared),
    if (outcome.filesDeleted > 0)
      t.download_clear_completed_result_files_deleted(n: outcome.filesDeleted),
    if (outcome.clearedKeptFiles > 0)
      t.download_clear_completed_result_kept_files(n: outcome.clearedKeptFiles),
    if (outcome.untouched > 0)
      t.download_clear_completed_result_untouched(n: outcome.untouched),
    if (outcome.failed > 0) t.download_batch_failed(n: outcome.failed),
  ];
  return parts.join(' · ');
}
