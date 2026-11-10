/// 漫画 OCR 任务管理页（反馈 iuv4-jWC8S）：集中看所有整卷 OCR 任务的进度，逐项
/// 或批量（本作品 / 全部）暂停、继续。
///
/// 页面不存任何任务状态：每次 [MangaOcrJobRegistry.changes] 都从注册表重新取
/// [MangaOcrJobRegistry.entries]，运行中任务的进度经各自的
/// [MangaOcrRunningJob.events] 触发重绘（读的仍是注册表里的 `lastEvent`）。暂停 /
/// 继续的语义全在注册表（[MangaOcrJobRegistry.pause] / [MangaOcrJobRegistry.resume]）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_ocr_progress.dart'
    show graphicSubtitleOcrEngineLabel;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 书名解析口（测试注入；生产读数据库）。返回 null = 查不到，标题回落到 bookKey。
typedef MangaOcrBookTitleLoader = Future<String?> Function(String bookKey);

/// 引擎显示名口（测试注入；生产与漫画 OCR 设置同一套文案）。
typedef MangaOcrEngineLabeler = String Function(MangaOcrEngineId engine);

class MangaOcrManagerPage extends ConsumerStatefulWidget {
  const MangaOcrManagerPage({super.key, this.bookTitle, this.engineLabel});

  final MangaOcrBookTitleLoader? bookTitle;
  final MangaOcrEngineLabeler? engineLabel;

  /// push 本页。
  static Future<void> push(BuildContext context) {
    return Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => const MangaOcrManagerPage(),
      ),
    );
  }

  @override
  ConsumerState<MangaOcrManagerPage> createState() =>
      _MangaOcrManagerPageState();
}

class _MangaOcrManagerPageState extends ConsumerState<MangaOcrManagerPage> {
  late final MangaOcrJobRegistry _registry;
  StreamSubscription<void>? _changes;

  /// 运行中任务的进度观察（按任务对象身份，不按 bookKey：同一本书前一章结束 /
  /// 被暂停、下一章接着开跑，两次变更可能在同一轮通知里合并，按 bookKey 会让
  /// 观察者停在已结束的旧任务上）；只为触发重绘，不缓存进度。
  final Map<MangaOcrRunningJob, StreamSubscription<MangaOcrBackgroundEvent>>
  _progress =
      Map<
        MangaOcrRunningJob,
        StreamSubscription<MangaOcrBackgroundEvent>
      >.identity();
  final Map<String, String> _bookTitles = <String, String>{};
  final Set<String> _titleRequested = <String>{};

  /// 正在执行的批量 / 单项操作，防止连点把同一项暂停两次。
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _registry = ref.read(mangaOcrJobRegistryProvider);
    _changes = _registry.changes.listen((_) => _onRegistryChanged());
    _observeRunning();
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    for (final StreamSubscription<MangaOcrBackgroundEvent> sub
        in _progress.values) {
      unawaited(sub.cancel());
    }
    _progress.clear();
    super.dispose();
  }

  void _onRegistryChanged() {
    if (!mounted) return;
    _observeRunning();
    setState(() {});
  }

  /// 让每个运行中的任务都有一个进度观察者；已不在运行集里的观察者释放。
  void _observeRunning() {
    final Set<MangaOcrRunningJob> running = Set<MangaOcrRunningJob>.identity()
      ..addAll(_registry.all);
    for (final MangaOcrRunningJob job in _progress.keys.toList()) {
      if (!running.contains(job)) {
        unawaited(_progress.remove(job)!.cancel());
      }
    }
    for (final MangaOcrRunningJob job in running) {
      _progress.putIfAbsent(
        job,
        () => job.events.listen(
          (_) {
            if (mounted) setState(() {});
          },
          // 失败由注册表记日志并移出运行集，这里等 changes 重绘即可。
          onError: (Object _) {},
        ),
      );
    }
  }

  MangaOcrBookTitleLoader get _bookTitleLoader =>
      widget.bookTitle ??
      (String bookKey) async {
        final AppModel appModel = ref.read(appProvider);
        return (await appModel.database.getEpubBook(bookKey))?.title;
      };

  String _engineLabel(MangaOcrEngineId engine) {
    final MangaOcrEngineLabeler? override = widget.engineLabel;
    if (override != null) return override(engine);
    return graphicSubtitleOcrEngineLabel(
      engine,
      localModelKey: ref.read(appProvider).mangaOcrLocalModel,
    );
  }

  String _bookTitle(String bookKey) {
    if (_titleRequested.add(bookKey)) {
      unawaited(
        _bookTitleLoader(bookKey).then((String? title) {
          if (!mounted || title == null || title.isEmpty) return;
          setState(() => _bookTitles[bookKey] = title);
        }),
      );
    }
    return _bookTitles[bookKey] ?? bookKey;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pause(Iterable<MangaOcrJobEntry> entries) => _run(() async {
    await _registry.pauseAll(<MangaOcrJobRef>[
      for (final MangaOcrJobEntry entry in entries)
        if (entry.canPause) entry.ref,
    ]);
  });

  Future<void> _resume(Iterable<MangaOcrJobEntry> entries) => _run(() async {
    _registry.resumeAll(<MangaOcrJobRef>[
      for (final MangaOcrJobEntry entry in entries)
        if (entry.status == MangaOcrJobStatus.paused) entry.ref,
    ]);
  });

  Future<void> _cancelBook(String bookKey) =>
      _run(() => _registry.cancel(bookKey));

  @override
  Widget build(BuildContext context) {
    final List<MangaOcrJobEntry> entries = _registry.entries();
    final bool anyPausable = entries.any((MangaOcrJobEntry e) => e.canPause);
    final bool anyPaused = entries.any(
      (MangaOcrJobEntry e) => e.status == MangaOcrJobStatus.paused,
    );
    // 按书分组，保留注册表给出的先后（运行中 → 排队 → 暂停）。
    final Map<String, List<MangaOcrJobEntry>> byBook =
        <String, List<MangaOcrJobEntry>>{};
    for (final MangaOcrJobEntry entry in entries) {
      byBook.putIfAbsent(entry.bookKey, () => <MangaOcrJobEntry>[]).add(entry);
    }
    final List<String> books = byBook.keys.toList(growable: false);
    return FushiPageScaffold(
      title: t.manga_ocr_manager_title,
      actions: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('manga_ocr_manager_pause_all'),
          tooltip: t.manga_ocr_manager_pause_all,
          label: t.manga_ocr_manager_pause_all,
          icon: FushiIcons.pause,
          enabled: anyPausable && !_busy,
          onTap: () => unawaited(_pause(entries)),
        ),
        FushiIconButton(
          key: const ValueKey<String>('manga_ocr_manager_resume_all'),
          tooltip: t.manga_ocr_manager_resume_all,
          label: t.manga_ocr_manager_resume_all,
          icon: FushiIcons.play,
          enabled: anyPaused && !_busy,
          onTap: () => unawaited(_resume(entries)),
        ),
      ],
      body: FushiEntranceScope(
        child: Builder(
          builder: (BuildContext context) => ListView.builder(
            key: const ValueKey<String>('manga_ocr_manager_list'),
            padding: EdgeInsets.only(
              top: 8 + MediaQuery.paddingOf(context).top,
              bottom: 24 + bottomSafeInsetOf(context),
              left: 16,
              right: 16,
            ),
            itemCount: books.isEmpty ? 1 : books.length,
            itemBuilder: books.isEmpty
                ? (BuildContext context, int _) => Padding(
                    key: const ValueKey<String>('manga_ocr_manager_empty'),
                    padding: const EdgeInsets.all(32),
                    child: Center(child: Text(t.manga_ocr_manager_empty)),
                  )
                : fushiStaggeredItemBuilder(
                    (BuildContext context, int index) =>
                        _bookGroup(books[index], byBook[books[index]]!),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _bookGroup(String bookKey, List<MangaOcrJobEntry> entries) {
    final bool pausable = entries.any((MangaOcrJobEntry e) => e.canPause);
    final bool paused = entries.any(
      (MangaOcrJobEntry e) => e.status == MangaOcrJobStatus.paused,
    );
    return Column(
      key: ValueKey<String>('manga_ocr_manager_book_$bookKey'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiSectionTitle.group(
          _bookTitle(bookKey),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (pausable)
                _action(
                  key: 'manga_ocr_manager_pause_book_$bookKey',
                  tooltip: t.manga_ocr_manager_pause_book,
                  icon: FushiIcons.pause,
                  onTap: () => _pause(entries),
                ),
              if (paused)
                _action(
                  key: 'manga_ocr_manager_resume_book_$bookKey',
                  tooltip: t.manga_ocr_manager_resume_book,
                  icon: FushiIcons.play,
                  onTap: () => _resume(entries),
                ),
              _action(
                key: 'manga_ocr_manager_cancel_book_$bookKey',
                tooltip: t.manga_ocr_manager_cancel_book,
                icon: FushiIcons.cancel,
                onTap: () => _cancelBook(bookKey),
              ),
            ],
          ),
        ),
        FushiGroupedList(
          children: <Widget>[
            for (final MangaOcrJobEntry entry in entries) _tile(entry),
          ],
        ),
      ],
    );
  }

  Widget _action({
    required String key,
    required String tooltip,
    required IconData icon,
    required Future<void> Function() onTap,
  }) {
    return FushiPressScale(
      enabled: !_busy,
      child: FushiIconButton(
        key: ValueKey<String>(key),
        tooltip: tooltip,
        icon: icon,
        enabled: !_busy,
        onTap: () => unawaited(onTap()),
      ),
    );
  }

  String _status(MangaOcrJobEntry entry) {
    final MangaOcrBackgroundEvent? last = entry.lastEvent;
    switch (entry.status) {
      case MangaOcrJobStatus.running:
        if (last == null || last.pagesTotal <= 0) {
          return t.manga_ocr_manager_status_starting;
        }
        // 远程引擎第一阶段数的是上传页数，文案必须换（BUG-3605）。
        if (last.uploading) {
          return t.manga_remote_ocr_uploading(
            done: last.pagesDone,
            total: last.pagesTotal,
          );
        }
        return t.manga_ocr_manager_status_running(
          done: last.pagesDone,
          total: last.pagesTotal,
        );
      case MangaOcrJobStatus.queued:
        return t.manga_ocr_manager_status_queued;
      case MangaOcrJobStatus.paused:
        if (last == null || last.pagesTotal <= 0 || last.uploading) {
          return t.manga_ocr_manager_status_paused;
        }
        return t.manga_ocr_manager_status_paused_at(
          done: last.pagesDone,
          total: last.pagesTotal,
        );
    }
  }

  Widget _tile(MangaOcrJobEntry entry) {
    final String id = '${entry.bookKey}|${entry.directory}';
    final MangaOcrBackgroundEvent? last = entry.lastEvent;
    final double? progress =
        entry.status == MangaOcrJobStatus.running &&
            last != null &&
            last.pagesTotal > 0
        ? (last.pagesDone / last.pagesTotal).clamp(0.0, 1.0)
        : null;
    final String status = '${_status(entry)} · ${_engineLabel(entry.engine)}';
    final String? title = entry.title;
    return FushiListItem(
      key: ValueKey<String>('manga_ocr_manager_item_$id'),
      leading: AnimatedSwitcher(
        duration: fushiMotionDuration(context, FushiMotion.short),
        child: FushiListLeadingIcon(
          key: ValueKey<MangaOcrJobStatus>(entry.status),
          switch (entry.status) {
            MangaOcrJobStatus.running => FushiIcons.ocr,
            MangaOcrJobStatus.queued => FushiIcons.schedule,
            MangaOcrJobStatus.paused => FushiIcons.pauseCircle,
          },
        ),
      ),
      title: Text(
        title == null || title.isEmpty ? p.basename(entry.directory) : title,
      ),
      subtitle: entry.status == MangaOcrJobStatus.running
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: FushiLinearProgressIndicator(value: progress),
                ),
                Text(status),
              ],
            )
          : Text(status),
      subtitleMaxLines: 1,
      trailing: switch (entry.status) {
        MangaOcrJobStatus.paused => _action(
          key: 'manga_ocr_manager_resume_$id',
          tooltip: t.manga_ocr_manager_resume,
          icon: FushiIcons.play,
          onTap: () => _resume(<MangaOcrJobEntry>[entry]),
        ),
        _ when entry.canPause => _action(
          key: 'manga_ocr_manager_pause_$id',
          tooltip: t.manga_ocr_manager_pause,
          icon: FushiIcons.pause,
          onTap: () => _pause(<MangaOcrJobEntry>[entry]),
        ),
        _ => null,
      },
    );
  }
}
