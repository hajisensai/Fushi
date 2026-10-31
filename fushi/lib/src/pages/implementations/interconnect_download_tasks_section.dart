/// 下载中心「任务」tab 里的**互联下载**段：从已配对设备拉到本机的视频 / 书 /
/// 有声书（[InterconnectDownloadManager]）。
///
/// 与 `RemoteDownloadTasksSection`（让 host 代为下载的任务）方向相反：那里的
/// 任务跑在对端，这里的跑在本机。此前这类任务只在库页封面角上有一个进度环，
/// 离开库页就看不到、也没有字节数（BUG-2714）。与其它段同一链式注入形状，
/// 没有任务时是空段。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/discovery/discovery_labels.dart';
import 'package:fushi/src/media/video/video_library_delete.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/startup/media_handle_registry.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        FushiDatabase,
        LocalFileDeleteFailure,
        LocalFileDeleteReport,
        deleteLocalFiles;
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show VideoDownloadPipelineService;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart'
    show DeleteDecision, DeleteScope;
import 'package:fushi/src/media/downloads/download_source_method.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';

class InterconnectDownloadTasksSection extends ConsumerWidget {
  const InterconnectDownloadTasksSection({
    required this.tasksBuilder,
    super.key,
  });

  final DownloadTasksBuilder tasksBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final InterconnectDownloadManager manager = ref.watch(
      interconnectDownloadManagerProvider,
    );
    final List<DownloadTaskEntry> entries = <DownloadTaskEntry>[
      for (final InterconnectDownloadTask task in manager.tasks.values)
        interconnectDownloadTaskEntry(
          manager,
          task,
          deleteCompletedFiles: _completedFilesDeleter(ref, manager, task),
        ),
    ];
    return tasksBuilder(context, entries);
  }
}

/// 已完成的**扩展源视频**任务的「删除（可连文件）」。其它来源 / 状态，或不知道
/// 成品落点（[InterconnectDownloadTask.destPath] 为 null）时返回 null——它们没有
/// 可删的文件，下载中心只给「清记录」。删除本体见
/// [deleteCompletedInterconnectDownloadFiles]（桌面控制通道共用）。
Future<void> Function({required bool deleteFiles})? _completedFilesDeleter(
  WidgetRef ref,
  InterconnectDownloadManager manager,
  InterconnectDownloadTask task,
) {
  if (!canDeleteCompletedDownloadFiles(task)) return null;
  return ({required bool deleteFiles}) async {
    if (!deleteFiles) {
      manager.clearTask(task.id);
      return;
    }
    final AppModel app = ref.read(appProvider);
    await deleteCompletedInterconnectDownloadFiles(
      database: app.database,
      pipeline: app.videoDownloadPipelineService,
      manager: manager,
      task: task,
      report: (VideoLibraryDeleteResult result) =>
          reportVideoLibraryDeleteFailures(
            result,
            source: 'InterconnectDownloadTasks.deleteCompleted',
          ),
    );
  };
}

/// 这条任务有没有可删的成品文件：已完成的**扩展源视频**且知道落点。
bool canDeleteCompletedDownloadFiles(InterconnectDownloadTask task) =>
    task.status == InterconnectDownloadStatus.completed &&
    task.origin == InterconnectDownloadOrigin.extension &&
    task.kind == InterconnectDownloadKind.video &&
    task.destPath != null;

/// 删掉一条已完成剧集下载的成品并移出任务记录（下载页「删除并删文件」与
/// `fushi_cli source anime-dl rm --delete-files` 共用）。
///
/// 按文件找库行（见 [deleteCompletedDownloadFile]）：有行走媒体库删除链（放句柄 →
/// 删行 → 删原件 + 字幕），没有只删文件本身（先放掉握着它的播放器句柄）。只有文件
/// 真的删掉了才移出任务记录：删失败（Windows 句柄占用等）时任务留着让用户重试，
/// 删除结果交给 [report]（页面弹提示，CLI 回原因）。返回是否删掉并移出。
///
/// [task] 不满足 [canDeleteCompletedDownloadFiles] 抛 [ArgumentError]。
/// [releaseHandles] 只给测试替换（缺省是 [MediaHandleRegistry.releaseHolding]）。
Future<bool> deleteCompletedInterconnectDownloadFiles({
  required FushiDatabase database,
  required VideoDownloadPipelineService? pipeline,
  required InterconnectDownloadManager manager,
  required InterconnectDownloadTask task,
  required void Function(VideoLibraryDeleteResult result) report,
  Future<void> Function(List<String> paths)? releaseHandles,
}) async {
  if (!canDeleteCompletedDownloadFiles(task)) {
    throw ArgumentError.value(
      task.id,
      'task',
      'not a completed extension video download with a known file',
    );
  }
  final VideoBookRepository repo = VideoBookRepository(database);
  final bool done = await deleteCompletedDownloadFile(
    destPath: task.destPath!,
    libraryRowFor: (String path) async =>
        (await repo.findByVideoPath(path))?.bookUid,
    deleteLibraryRow: (String bookUid) => deleteVideoBooksWithDecision(
      repo: repo,
      database: database,
      pipeline: pipeline,
      bookUids: <String>[bookUid],
      decision: const DeleteDecision(
        scope: DeleteScope.keepLocalOnly,
        deleteLocalFiles: true,
      ),
    ),
    deleteOrphanFile: (String path) async {
      // 与媒体库删除链同一顺序：正握着它的播放器先放句柄，再删。
      await (releaseHandles ?? MediaHandleRegistry.instance.releaseHolding)(
        <String>[path],
      );
      return deleteLocalFiles(<String>[path]);
    },
    fileExists: (String path) => File(path).exists(),
    report: report,
  );
  if (done) manager.clearTask(task.id);
  return done;
}

/// 删掉一条已完成下载的成品文件 [destPath]（纯编排，依赖全注入，供测试直接断言）。
/// 返回 true = 文件已不在盘上、任务记录可以移出。
///
/// 按**文件**找库行，而不是按任务键：完成后库里那一行可能已被用户删掉、或被重新
/// 「加入媒体库」成同 bookUid 的 `anime-source://` 流媒体行——按任务键删会删掉
/// 用户的流媒体行，真实落点文件却原封不动。
/// - 库里有行指向这个文件 → 走媒体库删除链（放句柄 → 删行 → 删原件 + 字幕）；
/// - 没有 → 不碰任何库行，只删文件本身。
///
/// 删除链报告无失败、文件却还在（仍被别的库行引用，护栏没删）也算没删掉：补一条
/// 失败进报告，让用户看到提示而不是被静默清掉任务。
Future<bool> deleteCompletedDownloadFile({
  required String destPath,
  required Future<String?> Function(String path) libraryRowFor,
  required Future<VideoLibraryDeleteResult> Function(String bookUid)
  deleteLibraryRow,
  required Future<LocalFileDeleteReport> Function(String path) deleteOrphanFile,
  required Future<bool> Function(String path) fileExists,
  required void Function(VideoLibraryDeleteResult result) report,
}) async {
  final String? bookUid = await libraryRowFor(destPath);
  VideoLibraryDeleteResult result = bookUid != null
      ? await deleteLibraryRow(bookUid)
      : (
          deleted: 0,
          failed: const <VideoBookDeleteFailure>[],
          localFiles: await deleteOrphanFile(destPath),
        );
  final bool stillOnDisk = await fileExists(destPath);
  if (stillOnDisk && result.localFiles.failures.isEmpty) {
    result = (
      deleted: result.deleted,
      failed: result.failed,
      localFiles: result.localFiles.merge(
        LocalFileDeleteReport(
          failures: <LocalFileDeleteFailure>[
            LocalFileDeleteFailure(
              destPath,
              'still on disk (referenced by another library entry)',
            ),
          ],
        ),
      ),
    );
  }
  report(result);
  return result.failed.isEmpty && !stillOnDisk;
}

/// 一条互联下载任务 → 下载中心条目（纯映射，供测试直接断言）。
///
/// [deleteCompletedFiles] 非 null 时已完成任务获得「删除（可连文件）」动作；此时
/// 不再提供只清记录的 `clear`——扩展下载的成品清了记录就再没有地方删文件。
DownloadTaskEntry interconnectDownloadTaskEntry(
  InterconnectDownloadManager manager,
  InterconnectDownloadTask task, {
  Future<void> Function({required bool deleteFiles})? deleteCompletedFiles,
}) {
  final bool fromExtension =
      task.origin == InterconnectDownloadOrigin.extension;
  final String sectionTitle = fromExtension
      ? t.download_method_extension
      : t.download_interconnect_section_title;
  final String entryId = 'interconnect:${task.id}';
  final bool restartable = manager.canRestart(task.id);
  final bool unfinished =
      task.status == InterconnectDownloadStatus.paused ||
      task.status == InterconnectDownloadStatus.failed;
  return DownloadTaskEntry(
    id: entryId,
    title: task.title,
    kind: switch (task.kind) {
      InterconnectDownloadKind.video => DownloadTaskKind.video,
      InterconnectDownloadKind.book => DownloadTaskKind.novel,
      InterconnectDownloadKind.audiobook => DownloadTaskKind.audiobook,
    },
    status: switch (task.status) {
      InterconnectDownloadStatus.running => DownloadTaskStatus.active,
      InterconnectDownloadStatus.paused => DownloadTaskStatus.paused,
      InterconnectDownloadStatus.completed => DownloadTaskStatus.completed,
      InterconnectDownloadStatus.failed => DownloadTaskStatus.attention,
    },
    createdAt: task.startedAt,
    progress: task.progress,
    collectionKey: fromExtension ? 'interconnect-extension' : 'interconnect',
    collectionTitle: sectionTitle,
    searchTerms: <String>[task.title],
    actions: DownloadTaskActions(
      pause: manager.canPause(task.id)
          ? () async => manager.pause(task.id)
          : null,
      resume: restartable && task.status == InterconnectDownloadStatus.paused
          ? () => manager.resume(task.id)
          : null,
      retry: restartable && task.status == InterconnectDownloadStatus.failed
          ? () => manager.resume(task.id)
          : null,
      clear:
          task.status == InterconnectDownloadStatus.completed &&
              deleteCompletedFiles == null
          ? () async => manager.clearTask(task.id)
          : null,
      // 未完成任务的「删除」= 放弃续传：勾了删文件就连 `.part` 一起删，不勾只移出
      // 列表（`.part` 留着，下次点下载照样从断点接上）。
      delete: unfinished
          ? ({required bool deleteFiles}) async {
              if (deleteFiles) {
                await manager.discard(task.id);
              } else {
                manager.clearTask(task.id);
              }
            }
          : deleteCompletedFiles,
      deletesFiles: (unfinished && restartable) || deleteCompletedFiles != null,
    ),
    builder: (BuildContext context) => DownloadTaskCard(
      key: ValueKey<String>(entryId),
      taskId: entryId,
      title: task.title,
      status: interconnectDownloadStatusLabel(task),
      subtitle: sectionTitle,
      method: fromExtension
          ? DownloadTransferMethod.extension
          : DownloadTransferMethod.direct,
      externalSource: fromExtension,
      progress: task.status == InterconnectDownloadStatus.completed
          ? 1
          : task.progress,
      leading: FushiIcon(switch (task.kind) {
        InterconnectDownloadKind.video when fromExtension =>
          DownloadTransferMethod.extension.icon,
        InterconnectDownloadKind.video => Icons.devices_outlined,
        InterconnectDownloadKind.book => Icons.menu_book_outlined,
        InterconnectDownloadKind.audiobook => Icons.headphones_outlined,
      }),
      details: _InterconnectTaskDetails(task: task),
    ),
  );
}

/// 任务行的状态一句话（纯函数）：下载中 / 暂停给「已收 / 总 (百分比)」，只知道
/// 已收就只给已收，连字节都没有（书的传输原语只报比例）就给百分比。
String interconnectDownloadStatusLabel(InterconnectDownloadTask task) {
  final String head = switch (task.status) {
    InterconnectDownloadStatus.running => t.download_task_status_downloading,
    InterconnectDownloadStatus.paused => t.download_task_status_paused,
    InterconnectDownloadStatus.completed => t.download_task_status_completed,
    InterconnectDownloadStatus.failed => t.download_task_status_error,
  };
  if (task.status == InterconnectDownloadStatus.completed) return head;
  final int? received = task.receivedBytes;
  final int? total = task.totalBytes;
  final String? amount;
  if (received != null && total != null && total > 0) {
    final int percent = ((received / total).clamp(0.0, 1.0) * 100).floor();
    amount =
        '${formatDiscoveryBytes(received)} / '
        '${formatDiscoveryBytes(total)} ($percent%)';
  } else if (received != null) {
    amount = formatDiscoveryBytes(received);
  } else if (task.progress != null) {
    amount = '${(task.progress! * 100).floor()}%';
  } else {
    amount = null;
  }
  return amount == null ? head : '$head · $amount';
}

class _InterconnectTaskDetails extends StatelessWidget {
  const _InterconnectTaskDetails({required this.task});

  final InterconnectDownloadTask task;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? error = task.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(interconnectDownloadStatusLabel(task), style: text.bodySmall),
        if (task.status == InterconnectDownloadStatus.failed && error != null)
          Text(
            error,
            style: text.bodySmall?.copyWith(color: scheme.error),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }
}
