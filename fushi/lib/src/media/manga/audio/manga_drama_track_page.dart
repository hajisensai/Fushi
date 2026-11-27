/// 漫画有声「广播剧 / 动画音轨」页（设计 §9 末段）：选几段真人音频（广播剧 CD 音轨、
/// 动画视频），本机 ASR 转录后按页对到这一卷上，登记成这卷的有声成品；对不上的段照常
/// 播放、只是不高亮。
///
/// 流水线在引擎（`manga_drama_track.dart`），宿主装配在 [MangaDramaTrackService]，运行中的
/// 任务归进程级任务表 [MangaDramaTrackTasks]（离开页面不停，只有点「取消」才停）；页面只
/// 管选文件、发起 / 取消、显示进度与匹配统计，不存成品镜像。
///
/// [MangaDramaTrackPanel] 是可嵌入的主体，[MangaDramaTrackPage] 只是页面外壳；入口在
/// 作品页「⋯」里「有声书音源」旁边，以及有声书音源页底部。
library;

import 'dart:async';

import 'package:fushi_engine/tts/manga_audio/manga_drama_track.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart'
    show TtsRenderCancelToken;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/state_resource_scope.dart';
import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart'
    show pickRealFilePaths;
import 'package:fushi/src/media/manga/audio/manga_drama_track_service.dart';
import 'package:fushi/src/media/manga/audio/manga_drama_track_tasks.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 可选的音频 / 视频扩展名（视频只取音轨）。
const Set<String> kMangaDramaFileExtensions = <String>{
  'mp3',
  'm4a',
  'm4b',
  'aac',
  'flac',
  'wav',
  'ogg',
  'opus',
  'mka',
  'mp4',
  'mkv',
  'webm',
  'mov',
  'avi',
};

/// 面板的读写口（生产 = [MangaDramaTrackService] + 系统文件选择器；测试注入假实现）。
abstract interface class MangaDramaTrackBackend {
  Future<MangaDramaVolume?> loadVolume(String bookKey);

  /// 选文件（按选择顺序）；取消返回空列表。
  Future<List<String>> pickAudioFiles(BuildContext context);

  Future<MangaDramaOutcome> run({
    required MangaDramaVolume volume,
    required List<String> audioPaths,
    required TtsRenderCancelToken cancel,
    MangaDramaProgress? onProgress,
  });
}

class AppMangaDramaTrackBackend implements MangaDramaTrackBackend {
  AppMangaDramaTrackBackend(this.appModel)
    : _service = MangaDramaTrackService(appModel, bookTitle: _displayTitle);

  final AppModel appModel;
  final MangaDramaTrackService _service;

  @override
  Future<MangaDramaVolume?> loadVolume(String bookKey) =>
      _service.loadVolume(bookKey);

  @override
  Future<List<String>> pickAudioFiles(BuildContext context) =>
      pickRealFilePaths(
        context: context,
        appModel: appModel,
        allowedExtensions: kMangaDramaFileExtensions,
      );

  @override
  Future<MangaDramaOutcome> run({
    required MangaDramaVolume volume,
    required List<String> audioPaths,
    required TtsRenderCancelToken cancel,
    MangaDramaProgress? onProgress,
  }) => _service.run(
    volume: volume,
    audioPaths: audioPaths,
    cancel: cancel,
    onProgress: onProgress,
  );
}

/// 进度文案（纯函数）：转录按「第 n 个文件」（1 起），剪段按「done/total」。
String mangaDramaPhaseLabel(MangaDramaPhase phase, int done, int total) =>
    switch (phase) {
      MangaDramaPhase.transcribing => t.manga_audio_drama_phase_transcribing(
        done: done < total ? done + 1 : total,
        total: total,
      ),
      MangaDramaPhase.matching => t.manga_audio_drama_phase_matching,
      MangaDramaPhase.cutting => t.manga_audio_drama_phase_cutting(
        done: done,
        total: total,
      ),
    };

class MangaDramaTrackPage extends StatelessWidget {
  const MangaDramaTrackPage({
    super.key,
    required this.bookKey,
    required this.backend,
    required this.tasks,
  });

  final String bookKey;
  final MangaDramaTrackBackend backend;
  final MangaDramaTrackTasks tasks;

  static Future<void> push(
    BuildContext context, {
    required AppModel appModel,
    required String bookKey,
  }) {
    return Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MangaDramaTrackPage(
          bookKey: bookKey,
          backend: AppMangaDramaTrackBackend(appModel),
          tasks: mangaDramaTrackTasksFor(appModel),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      masthead: true,
      title: t.manga_audio_drama_title,
      body: Builder(
        builder: (BuildContext context) => MangaDramaTrackPanel(
          bookKey: bookKey,
          backend: backend,
          tasks: tasks,
          padding: EdgeInsets.only(
            top: 8 + MediaQuery.paddingOf(context).top,
            bottom: 24 + bottomSafeInsetOf(context),
            left: 16,
            right: 16,
          ),
        ),
      ),
    );
  }
}

class MangaDramaTrackPanel extends StatefulWidget {
  const MangaDramaTrackPanel({
    super.key,
    required this.bookKey,
    required this.backend,
    required this.tasks,
    this.padding = const EdgeInsets.all(16),
  });

  final String bookKey;
  final MangaDramaTrackBackend backend;

  /// 进程级任务表：页面只观察，任务不随页面销毁。
  final MangaDramaTrackTasks tasks;
  final EdgeInsetsGeometry padding;

  @override
  State<MangaDramaTrackPanel> createState() => _MangaDramaTrackPanelState();
}

class _MangaDramaTrackPanelState extends State<MangaDramaTrackPanel>
    with StateResourceScope<MangaDramaTrackPanel> {
  bool _loaded = false;
  MangaDramaVolume? _volume;
  List<String> _files = const <String>[];

  /// 挂着的任务（本卷运行中的，或最近一次、结果还要显示的）。
  MangaDramaTask? _task;

  bool get _running => _task?.isRunning ?? false;

  @override
  void initState() {
    super.initState();
    listenTo(widget.tasks, _onTasks);
    // 只摘监听：任务属于进程级任务表，离开页面照跑，结束时全局提示。挂的是哪个任务
    // 随 [_attach] 变，撤销时读当下那个（BUG-5604：挂载失败与 dispose 共用）。
    onTeardown(() => _task?.removeListener(_onTask));
    final MangaDramaTask? existing = widget.tasks.taskFor(widget.bookKey);
    if (existing != null) {
      _files = existing.audioPaths;
      _attach(existing);
    }
    unawaited(_load());
  }

  void _attach(MangaDramaTask? task) {
    if (identical(task, _task)) return;
    _task?.removeListener(_onTask);
    _task = task;
    task?.addListener(_onTask);
  }

  /// 别处（AI 操作、另一扇窗）发起了本卷的任务：挂上去。
  void _onTasks() {
    final MangaDramaTask? running = widget.tasks.runningFor(widget.bookKey);
    if (running == null || identical(running, _task) || !mounted) return;
    setState(() {
      _files = running.audioPaths;
      _attach(running);
    });
  }

  void _onTask() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final MangaDramaVolume? volume = await widget.backend.loadVolume(
      widget.bookKey,
    );
    if (!mounted) return;
    setState(() {
      _volume = volume;
      _loaded = true;
    });
  }

  void _setFiles(List<String> next) {
    setState(() {
      _files = List<String>.unmodifiable(next);
      // 文件变了，上次的结果（统计 / 错误）不再对应。
      _attach(null);
    });
  }

  Future<void> _add() async {
    if (_running) return;
    final List<String> picked = await widget.backend.pickAudioFiles(context);
    if (!mounted || picked.isEmpty) return;
    _setFiles(<String>[
      ..._files,
      for (final String f in picked)
        if (!_files.contains(f)) f,
    ]);
  }

  void _remove(int index) {
    if (_running || index < 0 || index >= _files.length) return;
    _setFiles(<String>[..._files]..removeAt(index));
  }

  void _moveUp(int index) {
    if (_running || index <= 0 || index >= _files.length) return;
    final List<String> next = List<String>.of(_files);
    next.insert(index - 1, next.removeAt(index));
    _setFiles(next);
  }

  void _start() {
    final MangaDramaVolume? volume = _volume;
    if (_running || volume == null || _files.isEmpty) return;
    MangaDramaTask task;
    try {
      task = widget.tasks.start(
        volume: volume,
        audioPaths: _files,
        run: widget.backend.run,
      );
    } on MangaDramaTaskBusy catch (busy) {
      task = busy.running;
    }
    setState(() => _attach(task));
  }

  /// 运行中的进度文案。
  String? get _progress {
    final MangaDramaTask? task = _task;
    if (task == null || !task.isRunning) return null;
    return mangaDramaPhaseLabel(
      task.phase,
      task.progressDone,
      task.progressTotal,
    );
  }

  /// 失败原因（取消不算）。
  String? get _error {
    final MangaDramaTask? task = _task;
    final Object? error = task?.error;
    if (task?.status != MangaDramaTaskStatus.failed || error == null) {
      return null;
    }
    return mangaDramaErrorMessage(error);
  }

  MangaDramaStats? get _stats {
    final MangaDramaTask? task = _task;
    return task?.status == MangaDramaTaskStatus.completed ? task!.stats : null;
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: FushiCircularProgressIndicator());
    }
    final MangaDramaVolume? volume = _volume;
    final List<WidgetBuilder> sections = volume == null
        ? <WidgetBuilder>[_noVolumeSection]
        : <WidgetBuilder>[
            (BuildContext context) => _introSection(context, volume),
            _filesSection,
            _runSection,
          ];
    return FushiEntranceScope(
      child: ListView.builder(
        key: const ValueKey<String>('manga_drama_list'),
        padding: widget.padding,
        itemCount: sections.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => sections[index](context),
        ),
      ),
    );
  }

  Widget _noVolumeSection(BuildContext context) => _note(
    'manga_drama_no_ocr',
    FushiIcons.warning,
    t.manga_audio_error_no_ocr,
  );

  Widget _introSection(BuildContext context, MangaDramaVolume volume) {
    return Column(
      key: const ValueKey<String>('manga_drama_intro'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(t.manga_audio_drama_intro),
        _note('manga_drama_units', FushiIcons.info, switch (volume.unitSource) {
          MangaDramaUnitSource.script => t.manga_audio_drama_units_script(
            count: volume.units.length,
          ),
          MangaDramaUnitSource.ocr => t.manga_audio_drama_units_ocr(
            count: volume.units.length,
          ),
        }),
      ],
    );
  }

  Widget _action({
    required String key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    final bool enabled = onTap != null && !_running;
    return FushiPressScale(
      enabled: enabled,
      child: FushiIconButton(
        key: ValueKey<String>(key),
        tooltip: tooltip,
        icon: icon,
        enabled: enabled,
        onTap: onTap,
      ),
    );
  }

  Widget _filesSection(BuildContext context) {
    return Column(
      key: const ValueKey<String>('manga_drama_files'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SizedBox(height: 8),
        FushiSectionTitle.group(
          t.manga_audio_drama_files_section,
          trailing: _action(
            key: 'manga_drama_add',
            tooltip: t.manga_audio_drama_add,
            icon: FushiIcons.add,
            onTap: () => unawaited(_add()),
          ),
        ),
        FushiAnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          alignment: Alignment.topCenter,
          child: _files.isEmpty
              ? Padding(
                  key: const ValueKey<String>('manga_drama_files_empty'),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(t.manga_audio_drama_files_empty),
                )
              : FushiGroupedList(
                  children: <Widget>[
                    for (int i = 0; i < _files.length; i++)
                      FushiListItem(
                        key: ValueKey<String>('manga_drama_file_$i'),
                        leading: const FushiListLeadingIcon(FushiIcons.music),
                        title: Text(p.basename(_files[i])),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (i > 0)
                              _action(
                                key: 'manga_drama_up_$i',
                                tooltip: t.manga_audio_drama_move_up,
                                icon: FushiIcons.arrowUp,
                                onTap: () => _moveUp(i),
                              ),
                            _action(
                              key: 'manga_drama_remove_$i',
                              tooltip: t.manga_audio_drama_remove,
                              icon: FushiIcons.delete,
                              onTap: () => _remove(i),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _runSection(BuildContext context) {
    final MangaDramaStats? stats = _stats;
    final String? error = _error;
    final String? progress = _progress;
    final bool canStart = _files.isNotEmpty && !_running;
    return Column(
      key: const ValueKey<String>('manga_drama_run'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FushiPressScale(
              enabled: canStart,
              child: FushiFilledButton.icon(
                key: const ValueKey<String>('manga_drama_start'),
                onPressed: canStart ? _start : null,
                icon: const FushiIcon(FushiIcons.mic),
                label: Text(t.manga_audio_drama_start),
              ),
            ),
            if (_running)
              FushiPressScale(
                child: FushiOutlinedButton.icon(
                  key: const ValueKey<String>('manga_drama_cancel'),
                  onPressed: () => widget.tasks.cancel(widget.bookKey),
                  icon: const FushiIcon(FushiIcons.stop),
                  label: Text(t.manga_audio_drama_cancel),
                ),
              ),
          ],
        ),
        _note(
          'manga_drama_replace_hint',
          FushiIcons.info,
          t.manga_audio_drama_replace_hint,
        ),
        AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          child: progress != null
              ? Padding(
                  key: const ValueKey<String>('manga_drama_progress'),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const FushiLinearProgressIndicator(),
                      const SizedBox(height: 8),
                      Text(progress),
                    ],
                  ),
                )
              : error != null
              ? _note('manga_drama_error', FushiIcons.warning, error)
              : stats != null
              ? _statsBody(stats)
              : const SizedBox.shrink(key: ValueKey<String>('none')),
        ),
      ],
    );
  }

  Widget _statsBody(MangaDramaStats s) {
    Widget row(String key, String label, String value) => FushiListItem(
      key: ValueKey<String>('manga_drama_stat_$key'),
      density: FushiListDensity.compact,
      title: Text(label),
      trailing: Text(value),
    );
    return Column(
      key: const ValueKey<String>('manga_drama_result'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiSectionTitle.group(t.manga_audio_drama_stats_title),
        FushiGroupedList(
          children: <Widget>[
            row('cues', t.manga_audio_drama_stat_cues, '${s.cues}'),
            row(
              'matched',
              t.manga_audio_drama_stat_matched,
              '${s.matchedCues}',
            ),
            row('short', t.manga_audio_drama_stat_short, '${s.shortCues}'),
            if (s.backwardCues > 0)
              row(
                'backward',
                t.manga_audio_drama_stat_backward,
                '${s.backwardCues}',
              ),
            row('segments', t.manga_audio_drama_stat_segments, '${s.segments}'),
            row(
              'coverage',
              t.manga_audio_drama_stat_coverage,
              '${(s.unitCoverage * 100).round()}%',
            ),
          ],
        ),
      ],
    );
  }

  Widget _note(String key, IconData icon, String text) => Padding(
    key: ValueKey<String>(key),
    padding: const EdgeInsets.only(top: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        FushiIcon(icon, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

/// 生产用的书展示名（带用户改名覆盖、去哈希）。
String _displayTitle(String bookKey, String rawTitle) =>
    displayTitleForBook(bookKey: bookKey, rawTitle: rawTitle);
