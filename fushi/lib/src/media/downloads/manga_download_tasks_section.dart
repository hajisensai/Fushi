import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/downloads/download_source_method.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/media/manga/download/manga_download_progress_label.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_list.dart'
    show mangaChapterDownloadFailedLabel;
import 'package:fushi/src/media/manga/library/online_manga_reshelf.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 「下载」页任务 tab 的漫画分区：读 `manga_download_jobs`（在线章节 +
/// mokuro.moe 整卷同一张表）输出 [DownloadTaskEntry]，与 torrent / 直链 / 远端
/// 任务并列进统一列表（设计稿 2026-09-12 §4，取代原 `MokuroMoeTasksSection`）。
///
/// 只做映射，不持有任务：动作全部委托 [MangaDownloadService]（取消 / 重试 /
/// 清除），行的真相是表——`watchJobs` 一响就整体重取。独立使用时空表不占位；
/// [tasksBuilder] 把条目接进外层统一列表。
class MangaDownloadTasksSection extends ConsumerStatefulWidget {
  const MangaDownloadTasksSection({
    super.key,
    this.sourcesOverride,
    this.tasksBuilder,
  });

  /// 测试注入的全部数据来源（null = 全部取自 [AppModel]）。注入了就**整体**用它，
  /// 不再碰 app 数据库——没注入的那一项就是没有。
  final MangaDownloadTaskSources? sourcesOverride;

  /// Parent owns unified filtering, sorting and grouping, including empty lists.
  final DownloadTasksBuilder? tasksBuilder;

  @override
  ConsumerState<MangaDownloadTasksSection> createState() =>
      _MangaDownloadTasksSectionState();
}

class _MangaDownloadTasksSectionState
    extends ConsumerState<MangaDownloadTasksSection> {
  MangaDownloadService? _downloads;
  OnlineMangaReshelf? _reshelf;
  List<MangaDownloadJobRow> _jobs = const <MangaDownloadJobRow>[];
  List<RecoverableOnlineManga> _recoverable = const <RecoverableOnlineManga>[];
  StreamSubscription<void>? _watch;
  StreamSubscription<void>? _reshelfWatch;

  @override
  void initState() {
    super.initState();
    final MangaDownloadTaskSources sources =
        widget.sourcesOverride ?? _appSources();
    _downloads = sources.downloads;
    _reshelf = sources.reshelf;
    // 删书时保留下来的章节目录（「重新入库」候选）：删书 / 重新入库 / 改下载根
    // 后由 [OnlineMangaReshelf.changes] 通知重扫。
    _reshelfWatch = OnlineMangaReshelf.changes.listen(
      (_) => unawaited(_reloadRecoverable()),
    );
    unawaited(_reloadRecoverable());
    final MangaDownloadService? downloads = _downloads;
    if (downloads == null) return;
    _watch = downloads.watchJobs().listen(
      (_) => unawaited(_reload()),
      onError: (Object error, StackTrace stack) {
        ErrorLogService.instance.log(
          'MangaDownloadTasksSection.watch',
          error,
          stack,
        );
      },
    );
    unawaited(_reload());
  }

  @override
  void dispose() {
    unawaited(_watch?.cancel());
    _watch = null;
    unawaited(_reshelfWatch?.cancel());
    _reshelfWatch = null;
    super.dispose();
  }

  /// 没注入时的唯一来源：app 持有的服务（库没就绪 = 两项都没有）。
  MangaDownloadTaskSources _appSources() {
    final AppModel appModel = ref.read(appProvider);
    if (!appModel.isDatabaseReady) return const MangaDownloadTaskSources();
    return MangaDownloadTaskSources(
      downloads: appModel.mangaDownloadService,
      reshelf: appModel.onlineMangaReshelf,
    );
  }

  Future<void> _reloadRecoverable() async {
    final OnlineMangaReshelf? reshelf = _reshelf;
    if (reshelf == null) return;
    try {
      final OnlineMangaReshelfScan scan = await reshelf.scan();
      if (!mounted) return;
      setState(() => _recoverable = scan.recoverable);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaDownloadTasksSection.scanRecoverable',
        error,
        stack,
      );
    }
  }

  Future<void> _reload() async {
    final MangaDownloadService? downloads = _downloads;
    if (downloads == null) return;
    final List<MangaDownloadJobRow> jobs = await downloads.listJobs();
    if (!mounted) return;
    setState(() => _jobs = jobs);
  }

  @override
  Widget build(BuildContext context) {
    final MangaDownloadService? downloads = _downloads;
    final OnlineMangaReshelf? reshelf = _reshelf;
    final List<DownloadTaskEntry> entries = <DownloadTaskEntry>[
      if (downloads != null)
        for (final MangaDownloadJobRow job in _jobs)
          mangaDownloadTaskEntry(job, downloads),
      if (reshelf != null)
        for (final RecoverableOnlineManga item in _recoverable)
          recoverableMangaTaskEntry(item, reshelf),
    ];
    final DownloadTasksBuilder? builder = widget.tasksBuilder;
    if (builder != null) return builder(context, entries);
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final DownloadTaskEntry entry in entries) entry.builder(context),
      ],
    );
  }
}

/// [MangaDownloadTasksSection] 的数据来源：任务表服务 + 「重新入库」扫描器。
///
/// 两项一起注入或一起取自 app，不按项各自回退（注入了一项、另一项回头去读 app
/// 数据库，单测没覆盖 appProvider 时就会在 initState 里炸）。
class MangaDownloadTaskSources {
  const MangaDownloadTaskSources({this.downloads, this.reshelf});

  /// null = 不显示任务表里的漫画任务。
  final MangaDownloadService? downloads;

  /// null = 不显示「可重新入库」条目。
  final OnlineMangaReshelf? reshelf;
}

/// 漫画任务条目的作品身份 provider：`externalId` 是任务表的 `book_key`（在线条目
/// bookKey / `mokuro:<系列>`）。只供 [mangaDownloadTaskFocus] 精确定位，不落库。
const String kMangaDownloadWorkProvider = 'manga-book';

/// 作品页「下载任务」入口带去下载中心的筛选：只看这本书的漫画任务（含可重新
/// 入库条目），按 bookKey 精确匹配，不靠标题兜底误吸同名作品的任务。
DownloadTaskWorkFocus mangaDownloadTaskFocus({
  required String bookKey,
  required String title,
}) => DownloadTaskWorkFocus(
  title: title,
  matchesIdentity: (DownloadTaskWorkIdentity identity) =>
      identity.provider == kMangaDownloadWorkProvider &&
      identity.externalId == bookKey,
);

DownloadTaskWorkIdentity _mangaWorkIdentity(String bookKey) =>
    DownloadTaskWorkIdentity(
      provider: kMangaDownloadWorkProvider,
      externalId: bookKey,
    );

/// 下载根里一部「有章节、没书架行」的在线漫画 → 统一下载中心条目。
///
/// 与有声书任务的「补对齐文件」同一类入口：卡片主操作就是「重新入库」（bookKey / uid
/// 原样还原，旧卡片的来源随之重新连上），菜单里另有「删除已下载文件」（确认后删目录）。
DownloadTaskEntry recoverableMangaTaskEntry(
  RecoverableOnlineManga item,
  OnlineMangaReshelf reshelf,
) {
  final String id = 'manga-shelf:${item.bookKey}';
  final String status = t.download_task_manga_removed_status(
    n: item.downloadedChapterCount,
  );
  Future<void> reshelve() async {
    try {
      await reshelf.reshelve(item);
      FushiToast.show(
        msg: t.download_task_manga_reshelved(title: item.title),
        severity: ToastSeverity.success,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaDownloadTasks.reshelve', error, stack);
      FushiToast.show(msg: error.toString(), severity: ToastSeverity.error);
    }
  }

  Future<void> discard(BuildContext context) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.download_task_manga_discard,
      message: t.download_task_manga_discard_confirm(title: item.title),
      icon: FushiIcons.delete,
      confirmLabel: t.dialog_delete,
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await reshelf.discard(item);
      FushiToast.show(msg: t.storage_entry_delete_done);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaDownloadTasks.discard', error, stack);
      FushiToast.show(msg: error.toString(), severity: ToastSeverity.error);
    }
  }

  return DownloadTaskEntry(
    id: id,
    title: item.title,
    createdAt: item.sidecar.importedAt,
    kind: DownloadTaskKind.manga,
    status: DownloadTaskStatus.attention,
    progress: 1,
    collectionKey: item.bookKey,
    collectionTitle: item.title,
    workIdentity: _mangaWorkIdentity(item.bookKey),
    searchTerms: <String>[item.title],
    builder: (BuildContext context) => DownloadTaskCard(
      key: ValueKey<String>(id),
      taskId: id,
      title: item.title,
      status: status,
      progress: 1,
      tone: DownloadTaskTone.paused,
      leading: const FushiIcon(FushiIcons.manga),
      quickAction: DownloadTaskQuickAction(
        key: ValueKey<String>('manga-reshelve-${item.bookKey}'),
        icon: FushiIcons.libraryAdd,
        tooltip: t.download_task_manga_reshelve,
        onPressed: () => unawaited(reshelve()),
      ),
      menuActions: <DownloadTaskMenuAction>[
        DownloadTaskMenuAction(
          id: 'reshelve',
          icon: FushiIcons.libraryAdd,
          label: t.download_task_manga_reshelve,
          onSelected: () => unawaited(reshelve()),
        ),
        DownloadTaskMenuAction(
          id: 'discard',
          icon: FushiIcons.delete,
          label: t.download_task_manga_discard,
          destructive: true,
          onSelected: () => unawaited(discard(context)),
        ),
      ],
      details: Text(item.directory),
    ),
  );
}

/// 一条任务行 → 统一下载中心条目。
///
/// `id = manga:<jobId>`；`collectionKey` 在线章节取 bookKey、mokuro 卷取
/// `mokuro:<系列>`（表里的 bookKey 本来就是这个形状）；动作：排队 / 下载中可
/// 暂停、暂停可恢复（半成品留着续跑）、未结束可取消、failed / cancelled 可重试
/// （同一行复位，BUG-1433）、已结束可清除。
DownloadTaskEntry mangaDownloadTaskEntry(
  MangaDownloadJobRow job,
  MangaDownloadService downloads,
) {
  final String id = 'manga:${job.jobId}';
  final bool finished = _isFinished(job);
  final bool retryable =
      job.status == MangaDownloadJobStatus.failed ||
      job.status == MangaDownloadJobStatus.cancelled;
  final bool pausable = isMangaDownloadJobInFlight(job.status);
  final bool paused = job.status == MangaDownloadJobStatus.paused;
  final MangaDownloadProgress live = downloads.progressOf(job);
  final double? progress = job.status == MangaDownloadJobStatus.done
      ? 1
      : live.fraction;
  final String? seriesName = mokuroMoeSeriesNameOf(job.bookKey);
  final String collectionTitle = seriesName ?? job.title;
  final String status = _statusLabel(job, live);
  final ({DownloadTransferMethod method, bool external}) source =
      mangaDownloadSourceOf(job.runtime);
  // 源要过 Cloudflare 验证而失败的行：行上直接给「验证」（判据同作品页的验证
  // 按钮），通过后这一行与同站其它 Cloudflare 失败行一起重新排队。
  final bool verifiable = downloads.cloudflareChallengeOf(job) != null;
  final bool verifying = verifiable && downloads.isVerifyingCloudflare(job);
  return DownloadTaskEntry(
    id: id,
    title: job.kind == MangaDownloadJobKind.mokuroVolume
        ? job.title
        : '${job.title} · ${job.chapterTitle}',
    createdAt: job.createdAt,
    kind: DownloadTaskKind.manga,
    status: switch (job.status) {
      MangaDownloadJobStatus.queued => DownloadTaskStatus.queued,
      MangaDownloadJobStatus.running => DownloadTaskStatus.active,
      MangaDownloadJobStatus.done => DownloadTaskStatus.completed,
      MangaDownloadJobStatus.failed => DownloadTaskStatus.attention,
      MangaDownloadJobStatus.paused => DownloadTaskStatus.paused,
      _ => DownloadTaskStatus.cancelled,
    },
    progress: progress,
    collectionKey: job.bookKey,
    collectionTitle: collectionTitle,
    workIdentity: _mangaWorkIdentity(job.bookKey),
    searchTerms: <String>[job.title, job.chapterTitle, collectionTitle],
    // 单跑道持久队列：没有调度优先级，任务上也没有可 reveal 的落盘路径。暂停 /
    // 恢复是真的原地续跑（paused 行保留已落地的页 / `.part`），与取消（删半成品）
    // 分开。
    actions: DownloadTaskActions(
      pause: pausable ? () => downloads.pause(job.jobId) : null,
      resume: paused ? () => downloads.resume(job.jobId) : null,
      retry: retryable ? () => downloads.retry(job.jobId) : null,
      clear: finished ? () => downloads.remove(job.jobId) : null,
      cancel: finished ? null : () => downloads.cancel(job.jobId),
    ),
    builder: (BuildContext context) => DownloadTaskCard(
      key: ValueKey<String>(id),
      taskId: id,
      method: source.method,
      externalSource: source.external,
      title: job.kind == MangaDownloadJobKind.mokuroVolume
          ? job.title
          : job.chapterTitle,
      status: status,
      subtitle: collectionTitle,
      progress: progress,
      tone: _toneOf(job),
      leading: const FushiIcon(FushiIcons.manga),
      quickAction: verifiable
          ? DownloadTaskQuickAction(
              key: ValueKey<String>('manga-download-quick-verify-${job.jobId}'),
              icon: FushiIcons.verifiedUser,
              tooltip: t.manga_source_cloudflare_verify_title,
              onPressed: verifying
                  ? null
                  : () => unawaited(
                      verifyMangaDownloadCloudflare(downloads, job.jobId),
                    ),
            )
          : _mangaQuickAction(job, downloads),
      menuActions: <DownloadTaskMenuAction>[
        // 折叠态的主操作位让给了「验证」，「重试」挪进菜单，仍是一步可达。
        if (verifiable)
          DownloadTaskMenuAction(
            id: 'retry',
            icon: FushiIcons.refresh,
            label: t.retry,
            onSelected: () => unawaited(downloads.retry(job.jobId)),
          ),
        if (pausable)
          DownloadTaskMenuAction(
            id: 'pause',
            icon: FushiIcons.pause,
            label: t.download_task_pause,
            onSelected: () => unawaited(downloads.pause(job.jobId)),
          ),
        if (paused)
          DownloadTaskMenuAction(
            id: 'resume',
            icon: FushiIcons.play,
            label: t.download_task_resume,
            onSelected: () => unawaited(downloads.resume(job.jobId)),
          ),
        if (!finished)
          DownloadTaskMenuAction(
            id: 'cancel',
            icon: FushiIcons.close,
            label: t.dialog_cancel,
            onSelected: () => unawaited(downloads.cancel(job.jobId)),
          ),
        if (finished)
          DownloadTaskMenuAction(
            id: 'clear',
            icon: FushiIcons.remove,
            label: t.download_batch_clear,
            onSelected: () => unawaited(downloads.remove(job.jobId)),
          ),
      ],
      details: _MangaDownloadTaskRow(
        job: job,
        status: status,
        progress: live.fraction,
        downloads: downloads,
        verifiable: verifiable,
        verifying: verifying,
      ),
    ),
  );
}

/// 下载中心任务行的「验证」：弹验证页，通过后这一行与同站其它 Cloudflare 失败
/// 行重新排队；验证失败给 toast（关掉验证页不算失败），行保持 failed。
Future<void> verifyMangaDownloadCloudflare(
  MangaDownloadService downloads,
  String jobId,
) async {
  try {
    await downloads.verifyCloudflare(jobId);
  } on Object catch (error, stack) {
    ErrorLogService.instance.log(
      'MangaDownloadTasks.verifyCloudflare $jobId',
      error,
      stack,
    );
    FushiToast.show(msg: error.toString(), severity: ToastSeverity.error);
  }
}

/// 卡片行尾主操作（issue #2720）：排队 / 下载中 → 取消，暂停 → 恢复，失败 /
/// 已取消 → 重试，完成 → 无（暂停在溢出菜单与详情行）。与视频任务卡同一个折叠态主操作位——之前取消只藏在展开详情里，
/// 折叠的卡片上看不到，用户以为漫画下载没法取消。
DownloadTaskQuickAction? _mangaQuickAction(
  MangaDownloadJobRow job,
  MangaDownloadService downloads,
) => switch (job.status) {
  MangaDownloadJobStatus.queued ||
  MangaDownloadJobStatus.running => DownloadTaskQuickAction(
    key: ValueKey<String>('manga-download-quick-cancel-${job.jobId}'),
    icon: FushiIcons.close,
    tooltip: t.dialog_cancel,
    onPressed: () => unawaited(downloads.cancel(job.jobId)),
  ),
  MangaDownloadJobStatus.paused => DownloadTaskQuickAction(
    key: ValueKey<String>('manga-download-quick-resume-${job.jobId}'),
    icon: FushiIcons.play,
    tooltip: t.download_task_resume,
    onPressed: () => unawaited(downloads.resume(job.jobId)),
  ),
  MangaDownloadJobStatus.failed ||
  MangaDownloadJobStatus.cancelled => DownloadTaskQuickAction(
    key: ValueKey<String>('manga-download-quick-retry-${job.jobId}'),
    icon: FushiIcons.refresh,
    tooltip: t.retry,
    onPressed: () => unawaited(downloads.retry(job.jobId)),
  ),
  _ => null,
};

/// 状态 → 卡片色调（与视频任务卡同口径：下载中 primary、完成 tertiary、
/// 失败 error、暂停 / 已取消 paused、排队中性）。
DownloadTaskTone _toneOf(MangaDownloadJobRow job) => switch (job.status) {
  MangaDownloadJobStatus.running => DownloadTaskTone.active,
  MangaDownloadJobStatus.done => DownloadTaskTone.completed,
  MangaDownloadJobStatus.failed => DownloadTaskTone.error,
  MangaDownloadJobStatus.cancelled ||
  MangaDownloadJobStatus.paused => DownloadTaskTone.paused,
  _ => DownloadTaskTone.neutral,
};

/// 漫画下载任务的传输方式与是否外部来源（按 `runtime` 列）：Mihon / 旧
/// Aidoku 是扩展从第三方站点抓、mokuro.moe 是该站的 HTTP 直链、互联是从自己
/// 已配对的设备 HTTP 拉取（不算外部来源）、Kavita 是用户自配的服务器 HTTP 取页
/// （同用户自配 OPDS / Audiobookshelf，不标外部）。未知值按扩展源处理并标外部。
({DownloadTransferMethod method, bool external}) mangaDownloadSourceOf(
  String runtime,
) => switch (runtime) {
  kMokuroMoeDownloadRuntime => (
    method: DownloadTransferMethod.direct,
    external: true,
  ),
  'interconnect' => (method: DownloadTransferMethod.direct, external: false),
  // 网页漫画：宿主自己按扫到的地址 HTTP 直取，来源是第三方站点。
  'web' => (method: DownloadTransferMethod.direct, external: true),
  'kavita' => (method: DownloadTransferMethod.direct, external: false),
  _ => (method: DownloadTransferMethod.extension, external: true),
};

bool _isFinished(MangaDownloadJobRow job) =>
    !isMangaDownloadJobUnfinished(job.status);

/// [progress] 带单位（字节 / 页），由 [MangaDownloadService.progressOf] 给出。
String _statusLabel(MangaDownloadJobRow job, MangaDownloadProgress progress) =>
    switch (job.status) {
      MangaDownloadJobStatus.queued => t.download_status_queued,
      MangaDownloadJobStatus.running =>
        mangaDownloadProgressLabel(progress) ?? t.download_task_status_active,
      MangaDownloadJobStatus.done => t.manga_online_downloaded,
      MangaDownloadJobStatus.cancelled => t.download_status_cancelled,
      MangaDownloadJobStatus.paused => t.download_task_status_paused,
      // 2026-10 体验优化：lastError 为空时原写法留下「失败: 」尾冒号；与章节列表
      // 共用同一个失败文案拼法。
      _ => mangaChapterDownloadFailedLabel(job.lastError),
    };

/// 卡片展开后的详情行：状态图标 + 标题 + 状态文案 + 行内动作。
class _MangaDownloadTaskRow extends StatelessWidget {
  const _MangaDownloadTaskRow({
    required this.job,
    required this.status,
    required this.progress,
    required this.downloads,
    this.verifiable = false,
    this.verifying = false,
  });

  final MangaDownloadJobRow job;
  final String status;

  /// 失败原因是 Cloudflare 挑战且能解：「重试」旁多一个「验证」。
  final bool verifiable;

  /// 同站的验证正在进行（按钮置灰，不重复弹页）。
  final bool verifying;

  /// 0..1，null = 不定进度（单位无关，见 [MangaDownloadProgress.fraction]）。
  final double? progress;
  final MangaDownloadService downloads;

  /// 2026-10 体验优化：20 号图标 + 默认 8 内边距只有 36dp 命中区，低于触摸
  /// 最小 48dp；手机上重试 / 取消常点空。
  static const BoxConstraints _actionTarget = BoxConstraints(
    minWidth: 48,
    minHeight: 48,
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final Widget statusIcon = switch (job.status) {
      MangaDownloadJobStatus.queued => FushiIcon(
        Icons.schedule_outlined,
        size: 20,
        color: scheme.outline,
      ),
      MangaDownloadJobStatus.done => FushiIcon(
        Icons.check_circle_outline,
        size: 20,
        color: scheme.primary,
      ),
      MangaDownloadJobStatus.failed => FushiIcon(
        Icons.error_outline,
        size: 20,
        color: scheme.error,
      ),
      MangaDownloadJobStatus.cancelled => FushiIcon(
        Icons.block_outlined,
        size: 20,
        color: scheme.outline,
      ),
      MangaDownloadJobStatus.paused => FushiIcon(
        FushiIcons.pause,
        size: 20,
        color: scheme.outline,
      ),
      _ =>
        eink
            ? const FushiIcon(Icons.downloading_outlined, size: 20)
            : SizedBox(
                width: 20,
                height: 20,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: FushiCircularProgressIndicator(
                    strokeWidth: 2,
                    value: progress,
                  ),
                ),
              ),
    };
    final bool errorTone = job.status == MangaDownloadJobStatus.failed;
    final bool retryable =
        job.status == MangaDownloadJobStatus.failed ||
        job.status == MangaDownloadJobStatus.cancelled;
    return FushiListItem(
      density: FushiListDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      subtitleMaxLines: 2,
      titleMaxLines: 2,
      leading: statusIcon,
      title: Text(
        job.kind == MangaDownloadJobKind.mokuroVolume
            ? job.title
            : '${job.title} · ${job.chapterTitle}',
      ),
      subtitle: Text(
        status,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: errorTone ? scheme.error : null,
        ),
      ),
      trailing: retryable
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (verifiable)
                  FushiIconButton(
                    key: ValueKey<String>(
                      'manga-download-row-verify-${job.jobId}',
                    ),
                    tooltip: t.manga_source_cloudflare_verify_title,
                    icon: FushiIcons.verifiedUser,
                    size: 20,
                    constraints: _actionTarget,
                    onTap: verifying
                        ? null
                        : () => unawaited(
                            verifyMangaDownloadCloudflare(downloads, job.jobId),
                          ),
                  ),
                FushiIconButton(
                  key: ValueKey<String>(
                    'manga-download-row-retry-${job.jobId}',
                  ),
                  tooltip: t.retry,
                  icon: Icons.refresh,
                  size: 20,
                  constraints: _actionTarget,
                  onTap: () => unawaited(downloads.retry(job.jobId)),
                ),
              ],
            )
          : job.status == MangaDownloadJobStatus.done
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (job.status == MangaDownloadJobStatus.paused)
                  FushiIconButton(
                    key: ValueKey<String>(
                      'manga-download-row-resume-${job.jobId}',
                    ),
                    tooltip: t.download_task_resume,
                    icon: FushiIcons.play,
                    size: 20,
                    constraints: _actionTarget,
                    onTap: () => unawaited(downloads.resume(job.jobId)),
                  )
                else
                  FushiIconButton(
                    key: ValueKey<String>(
                      'manga-download-row-pause-${job.jobId}',
                    ),
                    tooltip: t.download_task_pause,
                    icon: FushiIcons.pause,
                    size: 20,
                    constraints: _actionTarget,
                    onTap: () => unawaited(downloads.pause(job.jobId)),
                  ),
                FushiIconButton(
                  tooltip: t.dialog_cancel,
                  icon: Icons.close,
                  size: 20,
                  constraints: _actionTarget,
                  onTap: () => unawaited(downloads.cancel(job.jobId)),
                ),
              ],
            ),
    );
  }
}
