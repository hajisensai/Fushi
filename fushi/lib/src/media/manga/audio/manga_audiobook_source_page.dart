/// 漫画有声「有声书音源」页（设计 §9）：关联书库里的有声书（本卷或整个系列）、选音源
/// 策略、发起前看命中统计，确认后写进演出稿。
///
/// 页面不存演出稿镜像：每次改书单 / 策略 / 写入都「读最新 → 改 → 原子写」，不会把
/// 别处（标注、复核界面）同时写下的行覆盖掉。命中统计是一次性结果，书单一变就作废。
///
/// [MangaAudiobookSourcePanel] 是可嵌入的主体（生成 / 制作台界面可以直接放进自己的
/// 页里），[MangaAudiobookSourcePage] 只是给它套一层页面外壳。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/manga/audio/manga_audiobook_source.dart';
import 'package:fushi/src/media/manga/audio/manga_drama_track_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audiobook_match.dart';

/// 面板的读写口（生产 = [MangaAudiobookSourceService]；测试注入假实现）。
abstract interface class MangaAudiobookSourceBackend {
  Future<MangaAudioScript> loadScript(String bookKey);
  Future<void> saveScript(String bookKey, MangaAudioScript script);
  Future<List<MangaAudiobookCandidate>> candidates(String bookKey);
  Future<MokuroPayload?> loadPayload(String bookKey);
  Future<MangaAudiobookCorpus> loadCorpus(List<String> bookKeys);
  Future<MangaAudiobookMatchResult> match(
    List<MangaAudiobookQueryLine> lines,
    List<MangaAudiobookCue> corpus,
  );
  Future<List<String>> seriesVolumes(String bookKey);
  Future<int> linkSourcesTo(List<String> volumes, List<String> sources);
}

/// 生产实现：转给 [MangaAudiobookSourceService]，匹配放后台 isolate。
class AppMangaAudiobookSourceBackend implements MangaAudiobookSourceBackend {
  AppMangaAudiobookSourceBackend(AppModel appModel)
    : _service = MangaAudiobookSourceService(
        appModel,
        bookTitle: _displayTitle,
      );

  final MangaAudiobookSourceService _service;

  @override
  Future<MangaAudioScript> loadScript(String bookKey) =>
      _service.loadScript(bookKey);

  @override
  Future<void> saveScript(String bookKey, MangaAudioScript script) =>
      _service.saveScript(bookKey, script);

  @override
  Future<List<MangaAudiobookCandidate>> candidates(String bookKey) =>
      _service.candidates(bookKey);

  @override
  Future<MokuroPayload?> loadPayload(String bookKey) =>
      _service.loadPayload(bookKey);

  @override
  Future<MangaAudiobookCorpus> loadCorpus(List<String> bookKeys) =>
      _service.loadCorpus(bookKeys);

  @override
  Future<MangaAudiobookMatchResult> match(
    List<MangaAudiobookQueryLine> lines,
    List<MangaAudiobookCue> corpus,
  ) => matchMangaAudiobookInBackground(lines, corpus);

  @override
  Future<List<String>> seriesVolumes(String bookKey) =>
      _service.seriesVolumes(bookKey);

  @override
  Future<int> linkSourcesTo(List<String> volumes, List<String> sources) =>
      _service.linkSourcesTo(volumes, sources);
}

class MangaAudiobookSourcePage extends StatelessWidget {
  const MangaAudiobookSourcePage({
    super.key,
    required this.bookKey,
    required this.backend,
    this.onOpenDramaTrack,
  });

  final String bookKey;
  final MangaAudiobookSourceBackend backend;

  /// 「广播剧 / 动画音轨」入口（没有文本时间表的真人音频走 ASR）；null = 不显示。
  final VoidCallback? onOpenDramaTrack;

  static Future<void> push(
    BuildContext context, {
    required AppModel appModel,
    required String bookKey,
  }) {
    return Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MangaAudiobookSourcePage(
          bookKey: bookKey,
          backend: AppMangaAudiobookSourceBackend(appModel),
          onOpenDramaTrack: () => unawaited(
            MangaDramaTrackPage.push(
              context,
              appModel: appModel,
              bookKey: bookKey,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      masthead: true,
      title: t.manga_audio_source_title,
      body: Builder(
        builder: (BuildContext context) => MangaAudiobookSourcePanel(
          bookKey: bookKey,
          backend: backend,
          onOpenDramaTrack: onOpenDramaTrack,
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

/// 发起匹配前的阻断原因（有就不跑）。
enum _Blocker { noScript, noOcr }

class MangaAudiobookSourcePanel extends StatefulWidget {
  const MangaAudiobookSourcePanel({
    super.key,
    required this.bookKey,
    required this.backend,
    this.padding = const EdgeInsets.all(16),
    this.onOpenDramaTrack,
  });

  final String bookKey;
  final MangaAudiobookSourceBackend backend;
  final EdgeInsetsGeometry padding;

  /// 见 [MangaAudiobookSourcePage.onOpenDramaTrack]。
  final VoidCallback? onOpenDramaTrack;

  @override
  State<MangaAudiobookSourcePanel> createState() =>
      _MangaAudiobookSourcePanelState();
}

class _MangaAudiobookSourcePanelState extends State<MangaAudiobookSourcePanel> {
  /// 最近一次读到的书单与策略（只用于显示；改动一律读最新再写）。
  List<String> _sources = const <String>[];
  MangaAudioSourcePolicy _policy = MangaAudioSourcePolicy.audiobookFirst;
  Map<String, String> _titles = const <String, String>{};
  List<MangaAudiobookCandidate> _candidates = const <MangaAudiobookCandidate>[];
  bool _loaded = false;
  bool _busy = false;
  bool _running = false;
  MangaAudiobookMatchResult? _result;
  _Blocker? _blocker;

  /// 统计时语料里没读到 cue 的关联书。
  List<String> _emptySources = const <String>[];

  MangaAudiobookSourceBackend get _backend => widget.backend;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final MangaAudioScript script = await _backend.loadScript(widget.bookKey);
    final List<MangaAudiobookCandidate> candidates = await _backend.candidates(
      widget.bookKey,
    );
    if (!mounted) return;
    setState(() {
      _sources = List<String>.unmodifiable(script.audiobookSources);
      _policy = script.sourcePolicy;
      _candidates = candidates;
      _titles = <String, String>{
        for (final MangaAudiobookCandidate c in candidates) c.bookKey: c.title,
      };
      _loaded = true;
    });
  }

  String _titleOf(String bookKey) => _titles[bookKey] ?? bookKey;

  /// 读最新演出稿 → [mutate] → 原子写，再把书单 / 策略同步回界面。
  Future<MangaAudioScript> _mutate(
    void Function(MangaAudioScript) mutate,
  ) async {
    final MangaAudioScript script = await _backend.loadScript(widget.bookKey);
    mutate(script);
    await _backend.saveScript(widget.bookKey, script);
    if (mounted) {
      setState(() {
        _sources = List<String>.unmodifiable(script.audiobookSources);
        _policy = script.sourcePolicy;
      });
    }
    return script;
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setSources(List<String> next) => _guard(() async {
    await _mutate((MangaAudioScript s) {
      s.audiobookSources
        ..clear()
        ..addAll(next);
    });
    // 书单变了，之前的统计不再对应。
    if (mounted) setState(() => _result = null);
  });

  Future<void> _add() async {
    final List<MangaAudiobookCandidate> pickable = <MangaAudiobookCandidate>[
      for (final MangaAudiobookCandidate c in _candidates)
        if (!_sources.contains(c.bookKey)) c,
    ];
    if (pickable.isEmpty) {
      FushiToast.show(msg: t.manga_audio_source_pick_empty);
      return;
    }
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: t.manga_audio_source_pick_title,
      icon: FushiIcons.audiobook,
      options: <FushiChoiceOption<String>>[
        for (final MangaAudiobookCandidate c in pickable)
          FushiChoiceOption<String>(value: c.bookKey, label: c.title),
      ],
    );
    if (picked == null || !mounted) return;
    await _setSources(<String>[..._sources, picked]);
  }

  Future<void> _remove(String bookKey) => _setSources(<String>[
    for (final String s in _sources)
      if (s != bookKey) s,
  ]);

  Future<void> _moveUp(int index) {
    if (index <= 0 || index >= _sources.length) return Future<void>.value();
    final List<String> next = List<String>.of(_sources);
    final String moved = next.removeAt(index);
    next.insert(index - 1, moved);
    return _setSources(next);
  }

  Future<void> _applyToSeries() => _guard(() async {
    final List<String> volumes = await _backend.seriesVolumes(widget.bookKey);
    if (volumes.isEmpty) {
      FushiToast.show(msg: t.manga_audio_source_apply_series_none);
      return;
    }
    final int written = await _backend.linkSourcesTo(volumes, _sources);
    FushiToast.show(
      msg: t.manga_audio_source_apply_series_done(count: written),
    );
  });

  Future<void> _setPolicy(MangaAudioSourcePolicy policy) => _guard(() async {
    await _mutate((MangaAudioScript s) => s.sourcePolicy = policy);
  });

  Future<void> _analyze() async {
    if (_running || _sources.isEmpty) return;
    setState(() {
      _running = true;
      _blocker = null;
      _result = null;
      _emptySources = const <String>[];
    });
    try {
      final MangaAudioScript script = await _backend.loadScript(widget.bookKey);
      if (script.audibleLines.isEmpty) {
        if (mounted) setState(() => _blocker = _Blocker.noScript);
        return;
      }
      final MokuroPayload? payload = await _backend.loadPayload(widget.bookKey);
      if (payload == null) {
        if (mounted) setState(() => _blocker = _Blocker.noOcr);
        return;
      }
      final List<MangaAudiobookQueryLine> lines = mangaAudiobookQueryLines(
        script,
        payload,
      );
      final MangaAudiobookCorpus corpus = await _backend.loadCorpus(
        script.audiobookSources,
      );
      final MangaAudiobookMatchResult result = await _backend.match(
        lines,
        corpus.cues,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _emptySources = <String>[
          for (final String key in script.audiobookSources)
            if ((corpus.cueCounts[key] ?? 0) == 0) key,
        ];
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _apply() async {
    final MangaAudiobookMatchResult? result = _result;
    if (result == null) return;
    await _guard(() async {
      late MangaAudiobookApplyReport report;
      await _mutate((MangaAudioScript s) {
        report = applyMangaAudiobookMatches(s, result);
      });
      FushiToast.show(
        msg: t.manga_audio_source_applied(
          written: report.clipsWritten,
          cleared: report.clipsCleared,
          kept: report.userKept,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: FushiCircularProgressIndicator());
    }
    final List<WidgetBuilder> sections = <WidgetBuilder>[
      _linkedSection,
      _policySection,
      _statsSection,
      if (widget.onOpenDramaTrack != null) _dramaSection,
    ];
    return FushiEntranceScope(
      child: ListView.builder(
        key: const ValueKey<String>('manga_audio_source_list'),
        padding: widget.padding,
        itemCount: sections.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => sections[index](context),
        ),
      ),
    );
  }

  Widget _action({
    required String key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    final bool enabled = onTap != null && !_busy;
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

  Widget _linkedSection(BuildContext context) {
    return Column(
      key: const ValueKey<String>('manga_audio_source_linked'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiSectionTitle.group(
          t.manga_audio_source_linked_section,
          trailing: _action(
            key: 'manga_audio_source_add',
            tooltip: t.manga_audio_source_add,
            icon: FushiIcons.add,
            onTap: () => unawaited(_add()),
          ),
        ),
        FushiAnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          alignment: Alignment.topCenter,
          child: _sources.isEmpty
              ? Padding(
                  key: const ValueKey<String>('manga_audio_source_empty'),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(t.manga_audio_source_linked_empty),
                )
              : FushiGroupedList(
                  children: <Widget>[
                    for (int i = 0; i < _sources.length; i++)
                      FushiListItem(
                        key: ValueKey<String>(
                          'manga_audio_source_item_${_sources[i]}',
                        ),
                        leading: const FushiListLeadingIcon(
                          FushiIcons.audiobook,
                        ),
                        title: Text(_titleOf(_sources[i])),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (i > 0)
                              _action(
                                key: 'manga_audio_source_up_${_sources[i]}',
                                tooltip: t.manga_audio_source_move_up,
                                icon: FushiIcons.arrowUp,
                                onTap: () => unawaited(_moveUp(i)),
                              ),
                            _action(
                              key: 'manga_audio_source_remove_${_sources[i]}',
                              tooltip: t.manga_audio_source_remove,
                              icon: FushiIcons.delete,
                              onTap: () => unawaited(_remove(_sources[i])),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FushiPressScale(
              enabled: _sources.isNotEmpty && !_busy,
              child: FushiOutlinedButton.icon(
                key: const ValueKey<String>('manga_audio_source_apply_series'),
                onPressed: _sources.isEmpty || _busy
                    ? null
                    : () => unawaited(_applyToSeries()),
                icon: const FushiIcon(FushiIcons.collections),
                label: Text(t.manga_audio_source_apply_series),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _policySection(BuildContext context) {
    return Padding(
      key: const ValueKey<String>('manga_audio_source_policy'),
      padding: const EdgeInsets.only(top: 16),
      child: AdaptiveSettingsSegmentedRow<MangaAudioSourcePolicy>(
        title: t.manga_audio_source_policy,
        subtitle: switch (_policy) {
          // 有声书 + 合成混排时生成端会克隆旁白音色（manga_audio_narrator.dart）。
          MangaAudioSourcePolicy.audiobookFirst =>
            '${t.manga_audio_source_policy_hint_first} '
                '${t.manga_audio_source_policy_narrator_note}',
          MangaAudioSourcePolicy.audiobookOnly =>
            t.manga_audio_source_policy_hint_only,
          MangaAudioSourcePolicy.synthOnly =>
            t.manga_audio_source_policy_hint_synth,
        },
        segments: <ButtonSegment<MangaAudioSourcePolicy>>[
          ButtonSegment<MangaAudioSourcePolicy>(
            value: MangaAudioSourcePolicy.audiobookFirst,
            label: Text(t.manga_audio_source_policy_audiobook_first),
          ),
          ButtonSegment<MangaAudioSourcePolicy>(
            value: MangaAudioSourcePolicy.audiobookOnly,
            label: Text(t.manga_audio_source_policy_audiobook_only),
          ),
          ButtonSegment<MangaAudioSourcePolicy>(
            value: MangaAudioSourcePolicy.synthOnly,
            label: Text(t.manga_audio_source_policy_synth_only),
          ),
        ],
        selected: _policy,
        onChanged: (MangaAudioSourcePolicy p) => unawaited(_setPolicy(p)),
      ),
    );
  }

  Widget _statsSection(BuildContext context) {
    final MangaAudiobookMatchResult? result = _result;
    final _Blocker? blocker = _blocker;
    return Column(
      key: const ValueKey<String>('manga_audio_source_stats'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiSectionTitle.group(t.manga_audio_source_stats_title),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FushiPressScale(
              enabled: _sources.isNotEmpty && !_running,
              child: FushiFilledButton.icon(
                key: const ValueKey<String>('manga_audio_source_analyze'),
                onPressed: _sources.isEmpty || _running
                    ? null
                    : () => unawaited(_analyze()),
                icon: const FushiIcon(FushiIcons.search),
                label: Text(
                  _running
                      ? t.manga_audio_source_running
                      : t.manga_audio_source_analyze,
                ),
              ),
            ),
            if (result != null)
              FushiPressScale(
                enabled: !_busy,
                child: FushiOutlinedButton.icon(
                  key: const ValueKey<String>('manga_audio_source_apply'),
                  onPressed: _busy ? null : () => unawaited(_apply()),
                  icon: const FushiIcon(FushiIcons.save),
                  label: Text(t.manga_audio_source_apply),
                ),
              ),
          ],
        ),
        AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          child: _running
              ? const Padding(
                  key: ValueKey<String>('manga_audio_source_progress'),
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: FushiLinearProgressIndicator(),
                )
              : blocker != null
              ? Padding(
                  key: ValueKey<_Blocker>(blocker),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(switch (blocker) {
                    _Blocker.noScript => t.manga_audio_source_no_script,
                    _Blocker.noOcr => t.manga_audio_source_no_ocr,
                  }),
                )
              : result == null
              ? const SizedBox.shrink(key: ValueKey<String>('none'))
              : _statsBody(result),
        ),
      ],
    );
  }

  Widget _statsBody(MangaAudiobookMatchResult result) {
    final MangaAudiobookMatchStats s = result.stats;
    Widget row(String key, String label, String value) => FushiListItem(
      key: ValueKey<String>('manga_audio_source_stat_$key'),
      density: FushiListDensity.compact,
      title: Text(label),
      trailing: Text(value),
    );
    return Column(
      key: const ValueKey<String>('manga_audio_source_result'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SizedBox(height: 12),
        FushiGroupedList(
          children: <Widget>[
            row('lines', t.manga_audio_source_stat_lines, '${s.lines}'),
            row('hits', t.manga_audio_source_stat_hits, '${s.hits}'),
            row(
              'partial',
              t.manga_audio_source_stat_partial,
              '${s.partialHits}',
            ),
            if (s.partialNoTiming > 0)
              row(
                'partial_no_timing',
                t.manga_audio_source_stat_partial_no_timing,
                '${s.partialNoTiming}',
              ),
            row('misses', t.manga_audio_source_stat_misses, '${s.misses}'),
            row('short', t.manga_audio_source_stat_short, '${s.tooShort}'),
            row(
              'duration',
              t.manga_audio_source_stat_duration,
              formatMangaClipDuration(s.hitDurationMs),
            ),
          ],
        ),
        if (!s.tokenTimingAvailable)
          _note(
            'manga_audio_source_no_token_timing',
            FushiIcons.info,
            t.manga_audio_source_no_token_timing,
          ),
        for (final String key in _emptySources)
          _note(
            'manga_audio_source_no_cues_$key',
            FushiIcons.warning,
            t.manga_audio_source_no_cues(title: _titleOf(key)),
          ),
      ],
    );
  }

  /// 有声书之外的另一种真人音源：广播剧 / 动画音轨（先 ASR 再按页匹配）。
  Widget _dramaSection(BuildContext context) {
    final VoidCallback? open = widget.onOpenDramaTrack;
    return Padding(
      key: const ValueKey<String>('manga_audio_source_drama'),
      padding: const EdgeInsets.only(top: 16),
      child: FushiGroupedList(
        children: <Widget>[
          FushiPressScale(
            enabled: open != null,
            child: FushiListItem(
              key: const ValueKey<String>('manga_audio_source_open_drama'),
              leading: const FushiListLeadingIcon(FushiIcons.mic),
              title: Text(t.manga_audio_drama_title),
              trailing: const FushiIcon(FushiIcons.chevronRight),
              onTap: open,
            ),
          ),
        ],
      ),
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

/// 命中片段总时长：`m:ss`（满一小时 `h:mm:ss`）。
String formatMangaClipDuration(int ms) {
  final int totalSeconds = (ms / 1000).round();
  final int h = totalSeconds ~/ 3600;
  final int m = (totalSeconds % 3600) ~/ 60;
  final String ss = (totalSeconds % 60).toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// 生产用的书展示名（带用户改名覆盖、去哈希）。
String _displayTitle(String bookKey, String rawTitle) =>
    displayTitleForBook(bookKey: bookKey, rawTitle: rawTitle);
