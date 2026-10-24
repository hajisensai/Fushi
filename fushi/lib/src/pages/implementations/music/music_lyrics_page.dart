/// 音乐播放页 / 歌词页（设计 §6.1–6.2、§11.2）：封面 ↔ 逐字歌词共享轴切换，Apple / MD3 两套
/// 背景，宽屏双栏 / 窄屏单栏几何取自 `media/shared/lyrics_shell/`（与有声书歌词模式同一份）。
///
/// - 歌词：`MusicLyricsService.resolve`（sidecar → 内嵌 → LRCLIB），`KaraokeLyricsView`
///   原生渲染，时钟是本地插值的 [MusicLyricsClock]，逐帧不跨 FFI；
/// - 偏移：±100 ms 实时生效并持久化到该来源的 `music_lyrics.offset_ms`；
/// - 查词：长按 / 点词 → 既有查词弹窗（本页是 [BaseSourcePage]，弹窗层就在树里），
///   查词时按设置自动暂停；
/// - 来源：选来源（本地候选 + 在线模糊搜索）写成用户行，可恢复自动来源，可显式导出 TTML。
library;

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_lyrics_view.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_clock.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/shared/lyrics_shell/lyrics_shell_backgrounds.dart';
import 'package:fushi/src/media/shared/lyrics_shell/lyrics_shell_layout.dart';
import 'package:fushi/src/pages/base_source_page.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_transitions.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 一次 ± 按钮调整的偏移步长。
const int kMusicLyricsOffsetStepMs = 100;

/// 播放项 → 歌词解析所需的曲目信息。
MusicLyricsTrackRef musicLyricsTrackRefOf(MusicPlayItem item) =>
    MusicLyricsTrackRef(
      trackUid: item.trackUid,
      path: item.path,
      title: item.title,
      artist: item.artist,
      album: item.album,
      durationMs: item.durationMs,
      cueStartMs: item.startMs,
    );

/// 纯函数：查词命中 → 查词起点文本（从命中字符到行尾，查词引擎自己取最长匹配）。
String musicLyricsLookupTerm(KaraokeLookupHit hit) {
  final int at = hit.charIndexInLine.clamp(0, hit.lineText.length);
  return hit.lineText.substring(at);
}

class MusicLyricsPage extends BaseSourcePage {
  const MusicLyricsPage({super.key, this.startWithLyrics = true})
    : super(item: null);

  /// true = 打开就在歌词面（窄屏）；false = 封面面。
  final bool startWithLyrics;

  @override
  BaseSourcePageState<MusicLyricsPage> createState() => _MusicLyricsPageState();
}

class _MusicLyricsPageState extends BaseSourcePageState<MusicLyricsPage> {
  MusicPlayerEngine get _engine => appModel.musicSession.engine;
  MusicLyricsService get _service => appModel.musicLyrics;

  late final MusicLyricsClock _clock = MusicLyricsClock(_engine);
  late bool _showLyrics = widget.startWithLyrics;

  String? _loadedUid;
  MusicLyricsResolution? _lyrics;
  bool _loading = false;
  Object? _error;
  int _offsetMs = 0;
  bool _pausedForLookup = false;

  @override
  void initState() {
    super.initState();
    _engine.addListener(_onEngine);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onEngine());
  }

  @override
  void dispose() {
    _engine.removeListener(_onEngine);
    _clock.dispose();
    super.dispose();
  }

  void _onEngine() {
    if (!mounted) return;
    final MusicPlayItem? item = _engine.current;
    if (item != null && item.trackUid != _loadedUid) {
      unawaited(_load(item));
    }
    setState(() {});
  }

  Future<void> _load(MusicPlayItem item) async {
    _loadedUid = item.trackUid;
    setState(() {
      _loading = true;
      _error = null;
      _lyrics = null;
    });
    MusicLyricsResolution? r;
    Object? error;
    try {
      r = await _service.resolve(musicLyricsTrackRefOf(item));
    } on Object catch (e) {
      // 在线查询失败（无网 / LRCLIB 5xx）：显示「在线歌词查询失败」，不当成「没有歌词」。
      error = e;
    }
    if (!mounted || _loadedUid != item.trackUid) return;
    setState(() {
      _loading = false;
      _lyrics = r;
      _error = error;
      _offsetMs = r?.timeline.offsetMs ?? 0;
    });
  }

  void _nudgeOffset(int deltaMs) {
    final MusicLyricsResolution? r = _lyrics;
    if (r == null) return;
    setState(() => _offsetMs += deltaMs);
    // 每次点按直接落库（单行 UPDATE，远比一帧便宜），不做防抖。
    unawaited(_service.setOffset(_loadedUid!, r.source, _offsetMs));
  }

  Future<void> _onLookup(KaraokeLookupHit hit) async {
    if (appModel.musicLyricsLookupPause && _engine.isPlaying) {
      _pausedForLookup = true;
      unawaited(_engine.pause());
    }
    await searchDictionaryResult(
      searchTerm: musicLyricsLookupTerm(hit),
      selectionRect: hit.globalRect,
    );
  }

  @override
  void clearDictionaryResult() {
    super.clearDictionaryResult();
    if (_pausedForLookup) {
      _pausedForLookup = false;
      unawaited(_engine.play());
    }
  }

  Future<void> _chooseSource() async {
    final MusicPlayItem? item = _engine.current;
    if (item == null) return;
    final MusicLyricsTrackRef ref = musicLyricsTrackRefOf(item);
    List<MusicLyricsCandidate> candidates = await _service.localCandidates(ref);
    if (!mounted) return;
    if (candidates.isEmpty) {
      try {
        candidates = await _service.searchOnline(ref);
      } on Object catch (e) {
        if (mounted) setState(() => _error = e);
        return;
      }
    }
    if (!mounted) return;
    final MusicLyricsCandidate? picked = await showFushiChoiceDialog(
      context: context,
      title: t.music_lyrics_choose_source,
      icon: FushiIcons.lyrics,
      message: candidates.isEmpty ? t.music_lyrics_no_candidates : null,
      options: <FushiChoiceOption<MusicLyricsCandidate>>[
        for (final MusicLyricsCandidate c in candidates)
          FushiChoiceOption<MusicLyricsCandidate>(
            value: c,
            label: c.label,
            subtitle: '${c.format} · ${c.timeline.timingQuality.dbName}',
          ),
      ],
    );
    if (picked == null) return;
    await _service.choose(item.trackUid, picked);
    if (mounted) await _load(item);
  }

  Future<void> _searchOnline() async {
    final MusicPlayItem? item = _engine.current;
    if (item == null) return;
    final List<MusicLyricsCandidate> found;
    try {
      found = await _service.searchOnline(musicLyricsTrackRefOf(item));
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
      return;
    }
    if (!mounted) return;
    final MusicLyricsCandidate? picked = await showFushiChoiceDialog(
      context: context,
      title: t.music_lyrics_search_online,
      icon: FushiIcons.search,
      message: found.isEmpty ? t.music_lyrics_no_candidates : null,
      options: <FushiChoiceOption<MusicLyricsCandidate>>[
        for (final MusicLyricsCandidate c in found)
          FushiChoiceOption<MusicLyricsCandidate>(
            value: c,
            label: c.label,
            subtitle: c.format,
          ),
      ],
    );
    if (picked == null) return;
    await _service.choose(item.trackUid, picked);
    if (mounted) await _load(item);
  }

  Future<void> _resetSource() async {
    final MusicPlayItem? item = _engine.current;
    if (item == null) return;
    await _service.clearUserEdit(item.trackUid);
    if (mounted) await _load(item);
  }

  Future<void> _exportTtml() async {
    final MusicPlayItem? item = _engine.current;
    final MusicLyricsResolution? r = _lyrics;
    if (item == null || r == null) return;
    try {
      await _service.exportBesideAudio(
        musicLyricsTrackRefOf(item),
        r.timeline,
        'ttml',
      );
    } on FileSystemException catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final MusicPlayItem? item = _engine.current;
    final bool apple = isGlassDesign(context);
    final ImageProvider? cover = item?.coverPath == null
        ? null
        : FileImage(File(item!.coverPath!));
    final Widget background = apple
        ? LyricsShellAppleBackground(
            cover: cover,
            accent: appleColorsOf(context).accent,
          )
        : FushiMeshBackdrop(plateRect: lyricsShellMd3PlateResolver(0));
    Widget page = Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: <Widget>[
          Positioned.fill(child: background),
          Positioned.fill(
            child: SafeArea(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints box) {
                  final Size size = box.biggest;
                  return lyricsPlayerIsWide(size)
                      ? _buildWide(context, item)
                      : _buildNarrow(context, item);
                },
              ),
            ),
          ),
          buildDictionary(),
        ],
      ),
    );
    if (apple) page = FushiAppleDarkTier(child: page);
    return page;
  }

  Widget _buildWide(BuildContext context, MusicPlayItem? item) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 380,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _buildPanel(context, item, showCover: true),
          ),
        ),
        Expanded(child: _buildLyricsArea(context)),
      ],
    );
  }

  Widget _buildNarrow(BuildContext context, MusicPlayItem? item) {
    final Widget face = _showLyrics
        ? KeyedSubtree(
            key: const ValueKey<String>('lyrics'),
            child: _buildLyricsArea(context),
          )
        : KeyedSubtree(
            key: const ValueKey<String>('cover'),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: MusicCover(
                    coverPath: item?.coverPath,
                    size: 320,
                    borderRadius: FushiDesignTokens.of(
                      context,
                    ).radii.chipRadius,
                  ),
                ),
              ),
            ),
          );
    return Column(
      children: <Widget>[
        _buildTopRow(context),
        Expanded(
          // 封面 ↔ 歌词共享轴切换（时长取动效令牌，减弱动态 / 墨水屏归零）。
          child: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            transitionBuilder: (Widget child, Animation<double> a) =>
                FushiSharedAxisTransition(
                  animation: a,
                  secondaryAnimation: const AlwaysStoppedAnimation<double>(0),
                  child: child,
                ),
            child: face,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: _buildPanel(context, item, showCover: false),
        ),
      ],
    );
  }

  Widget _buildTopRow(BuildContext context) {
    return Row(
      children: <Widget>[
        FushiIconButtonControl(
          icon: const FushiIcon(FushiIcons.close),
          tooltip: t.music_lyrics_title,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        const Spacer(),
        FushiIconButtonControl(
          key: const ValueKey<String>('music_lyrics_toggle_face'),
          icon: FushiIcon(_showLyrics ? FushiIcons.image : FushiIcons.lyrics),
          tooltip: _showLyrics
              ? t.music_lyrics_show_cover
              : t.music_lyrics_title,
          onPressed: () => setState(() => _showLyrics = !_showLyrics),
        ),
        _buildMoreButton(context),
      ],
    );
  }

  Widget _buildMoreButton(BuildContext context) {
    return FushiIconButtonControl(
      key: const ValueKey<String>('music_lyrics_more'),
      icon: const FushiIcon(FushiIcons.moreHoriz),
      tooltip: t.music_lyrics_choose_source,
      onPressed: () => unawaited(_openSourceActions()),
    );
  }

  Future<void> _openSourceActions() async {
    final int? choice = await showFushiChoiceDialog<int>(
      context: context,
      title: t.music_lyrics_title,
      icon: FushiIcons.lyrics,
      options: <FushiChoiceOption<int>>[
        FushiChoiceOption<int>(
          value: 0,
          label: t.music_lyrics_choose_source,
          icon: FushiIcons.lyrics,
        ),
        FushiChoiceOption<int>(
          value: 1,
          label: t.music_lyrics_search_online,
          icon: FushiIcons.search,
        ),
        if (_lyrics?.timeline.isUserEdited ?? false)
          FushiChoiceOption<int>(
            value: 2,
            label: t.music_lyrics_reset_source,
            icon: FushiIcons.undo,
          ),
        if (_lyrics != null)
          FushiChoiceOption<int>(
            value: 3,
            label: t.music_lyrics_export_ttml,
            icon: FushiIcons.save,
          ),
      ],
    );
    switch (choice) {
      case 0:
        await _chooseSource();
      case 1:
        await _searchOnline();
      case 2:
        await _resetSource();
      case 3:
        await _exportTtml();
      default:
    }
  }

  Widget _buildLyricsArea(BuildContext context) {
    final MusicLyricsResolution? r = _lyrics;
    if (r == null) {
      final String message = _loading
          ? ''
          : (_error != null
                ? t.music_lyrics_online_failed
                : t.music_lyrics_empty);
      return Center(
        child: _loading
            ? const CircularProgressIndicator()
            : Text(message, style: context.fushiType.bodyLarge),
      );
    }
    return KaraokeLyricsView(
      key: ValueKey<String>('karaoke_${_loadedUid}_${r.source}'),
      timeline: r.timeline,
      clock: _clock,
      playing: _engine.isPlaying,
      offsetMs: _offsetMs,
      onSeek: (int ms) => unawaited(_engine.seek(Duration(milliseconds: ms))),
      onLookup: (KaraokeLookupHit hit) => unawaited(_onLookup(hit)),
    );
  }

  Widget _buildPanel(
    BuildContext context,
    MusicPlayItem? item, {
    required bool showCover,
  }) {
    final Duration position = _engine.position;
    final Duration? duration = _engine.duration;
    final double max = (duration?.inMilliseconds ?? 0).toDouble();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (showCover) ...<Widget>[
          Row(children: <Widget>[const Spacer(), _buildMoreButton(context)]),
          Flexible(
            child: FushiPressScale(
              child: AspectRatio(
                aspectRatio: 1,
                child: MusicCover(
                  coverPath: item?.coverPath,
                  size: 320,
                  borderRadius: FushiDesignTokens.of(context).radii.chipRadius,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        Text(
          item?.title ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.fushiType.titleLarge,
        ),
        Text(
          item?.artist ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.fushiType.bodyMedium,
        ),
        Slider(
          value: position.inMilliseconds.toDouble().clamp(
            0,
            max <= 0 ? 1 : max,
          ),
          max: max <= 0 ? 1 : max,
          onChanged: max <= 0
              ? null
              : (double v) =>
                    unawaited(_engine.seek(Duration(milliseconds: v.round()))),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(formatFushiPlaybackTime(position)),
            const Spacer(),
            FushiIconButtonControl(
              icon: const FushiIcon(FushiIcons.skipPrevious),
              tooltip: t.shortcut_action_music_previous_track,
              onPressed: () => unawaited(_engine.skipPrevious()),
            ),
            FushiIconButtonControl.filled(
              icon: FushiIcon(
                _engine.isPlaying
                    ? FushiIcons.filled(FushiIcons.pause)
                    : FushiIcons.filled(FushiIcons.play),
              ),
              tooltip: t.shortcut_action_music_toggle_play_pause,
              onPressed: () => unawaited(_engine.togglePlayPause()),
            ),
            FushiIconButtonControl(
              icon: const FushiIcon(FushiIcons.skipNext),
              tooltip: t.shortcut_action_music_next_track,
              onPressed: () => unawaited(_engine.skipNext()),
            ),
            const Spacer(),
            Text(formatFushiPlaybackTime(duration ?? Duration.zero)),
          ],
        ),
        if (_lyrics != null && _lyrics!.timeline.isSynced)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              FushiIconButtonControl(
                key: const ValueKey<String>('music_lyrics_offset_earlier'),
                icon: const FushiIcon(FushiIcons.remove),
                tooltip: t.music_lyrics_offset_later,
                onPressed: () => _nudgeOffset(-kMusicLyricsOffsetStepMs),
              ),
              Text(
                t.music_lyrics_offset_value(ms: _offsetMs),
                style: context.fushiType.bodySmall,
              ),
              FushiIconButtonControl(
                key: const ValueKey<String>('music_lyrics_offset_later'),
                icon: const FushiIcon(FushiIcons.add),
                tooltip: t.music_lyrics_offset_earlier,
                onPressed: () => _nudgeOffset(kMusicLyricsOffsetStepMs),
              ),
            ],
          ),
      ],
    );
  }
}
