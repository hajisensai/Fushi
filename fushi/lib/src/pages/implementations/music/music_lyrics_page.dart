/// 音乐播放页 / 歌词页（设计 §6.1–6.2、§11.2、§12）：封面 ↔ 逐字歌词共享轴切换，Apple /
/// MD3 两套背景，宽屏双栏 / 窄屏单栏几何取自 `media/shared/lyrics_shell/`（与有声书歌词模式
/// 同一份）。
///
/// - 歌词：`MusicLyricsService.resolve`（sidecar → 内嵌 → LRCLIB），`KaraokeLyricsView`
///   原生渲染，时钟是本地插值的 [MusicLyricsClock]，逐帧不跨 FFI；
/// - 偏移：±100 ms 实时生效并持久化到该来源的 `music_lyrics.offset_ms`；
/// - 查词：长按 / 点词 → 既有查词弹窗（本页是 [BaseSourcePage]，弹窗层就在树里），
///   查词时按设置自动暂停；
/// - 制卡（§12）：句子 = 查词所在那行，音频片段 = 该行前后各扩 0.5 s，卡图 = 封面，出处 =
///   `music` 来源链接 + 制卡历史 `position_ms` / `duration_ms`（L3）；
/// - AB 循环一行 / 多行（mpv 原生 ab-loop）；
/// - 来源：选来源（本地候选 + 在线模糊搜索）写成用户行，可恢复自动来源，可显式导出 TTML。
///   不做歌词编辑与自动注音（所有者 2026-10-24 拍板，设计 D11）；
/// - 卡拉 OK 字幕页（P3，§6.3 / §9.2）：歌词来源是 ASS 或音频旁有同名 `.cdg` 时出现入口；
///   ASS 带字幕组特效且设置为「自动 / 原样」时，歌词区顶上提示去原样渲染。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, kStatSourceMusic;
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show immersionMiningAudioExtension;
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_channel.dart';
import 'package:fushi/src/media/favorites/favorite_lookup_context.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_lyrics_view.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_stage_plan.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_clock.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_learning.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart'
    show pickCdgCompanion;
import 'package:fushi/src/media/music/music_mining_origin.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/shared/lyrics_shell/lyrics_shell_backgrounds.dart';
import 'package:fushi/src/media/shared/lyrics_shell/lyrics_shell_layout.dart';
import 'package:fushi/src/pages/base_source_page.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_mv_page.dart'
    show MusicKaraokeTrack, openMusicKaraokePage;
import 'package:fushi/src/utils/adaptive/fushi_page_transitions.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
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

/// 播放项旁同名 `.cdg`（CD+G，设计 §9.2）：CUE 曲目不认（一份整轨对应的是整张盘）。
/// 列目录用同步 API（与歌词 sidecar 同一口径；异步 `Directory.list` 在 widget 测试的
/// fake-async 里永远不完成）。
String? musicCdgCompanionOf(MusicPlayItem item) {
  if (item.startMs != null) return null;
  final List<String> siblings;
  try {
    siblings = <String>[
      for (final FileSystemEntity e in File(item.path).parent.listSync())
        if (e is File) e.path,
    ];
  } on FileSystemException {
    return null;
  }
  return pickCdgCompanion(item.path, siblings);
}

/// 纯函数：查词命中 → 查词起点文本（从命中字符到行尾，查词引擎自己取最长匹配）。
String musicLyricsLookupTerm(KaraokeLookupHit hit) {
  final int at = hit.charIndexInLine.clamp(0, hit.lineText.length);
  return hit.lineText.substring(at);
}

/// 纯函数：查词时要不要暂停（设置开着且正在播）。
bool musicLyricsShouldPauseForLookup({
  required bool settingEnabled,
  required bool playing,
}) => settingEnabled && playing;

/// 截一段音频（制卡句子音频）。生产 = ffmpeg（[TtsChannel.extractAudioSegment]）；widget
/// 测试换成不起子进程的替身。失败返回 null，原因经 [onFailure] 带出。
typedef MusicLyricsClipExtractor =
    Future<String?> Function({
      required String inputPath,
      required int startMs,
      required int endMs,
      required String outputPath,
      required int audioChannels,
      required String audioBitrate,
      required void Function(String summary) onFailure,
    });

Future<String?> _ffmpegClip({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  required int audioChannels,
  required String audioBitrate,
  required void Function(String summary) onFailure,
}) => TtsChannel.instance.extractAudioSegment(
  inputPath: inputPath,
  startMs: startMs,
  endMs: endMs,
  outputPath: outputPath,
  audioChannels: audioChannels,
  audioBitrate: audioBitrate,
  onFailure: onFailure,
);

@visibleForTesting
MusicLyricsClipExtractor musicLyricsClipExtractor = _ffmpegClip;

class MusicLyricsPage extends BaseSourcePage {
  const MusicLyricsPage({super.key, this.startWithLyrics = true})
    : super(item: null);

  /// true = 打开就在歌词面（窄屏）；false = 封面面。
  final bool startWithLyrics;

  @override
  BaseSourcePageState<MusicLyricsPage> createState() => _MusicLyricsPageState();
}

class _MusicLyricsPageState extends BaseSourcePageState<MusicLyricsPage> {
  // 进程级单例，不随 provider 变：用缓存的 AppModel 取（initState 里就要挂监听，那时
  // 还不能经 ref.watch 读 inherited widget——之前这里在 debug 下开页即断言）。
  MusicPlayerEngine get _engine => appModelNoUpdate.musicSession.engine;
  MusicLyricsService get _service => appModelNoUpdate.musicLyrics;

  late final MusicLyricsClock _clock = MusicLyricsClock(_engine);
  late bool _showLyrics = widget.startWithLyrics;

  String? _loadedUid;
  MusicLyricsResolution? _lyrics;

  /// 音频旁同名 `.cdg`（CD+G 画面，§9.2）；CUE 曲目不认。
  String? _cdgPath;
  bool _loading = false;
  Object? _error;
  int _offsetMs = 0;
  bool _pausedForLookup = false;

  /// 最近一次查词所在的行（制卡的句子 / 音频片段取它）。
  int? _lookupLine;

  /// AB 循环覆盖的行（含）；没开为 null。
  (int, int)? _loopLines;

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
    // 引擎换曲 / 关循环后，页上的循环行跟着清。
    if (_loopLines != null && _engine.abLoop == null) _loopLines = null;
    setState(() {});
  }

  Future<void> _load(MusicPlayItem item) async {
    _loadedUid = item.trackUid;
    setState(() {
      _loading = true;
      _error = null;
      _lyrics = null;
      _cdgPath = null;
      _lookupLine = null;
      _loopLines = null;
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
    final String? cdg = musicCdgCompanionOf(item);
    setState(() {
      _loading = false;
      _lyrics = r;
      _cdgPath = cdg;
      _error = error;
      _offsetMs = r?.timeline.offsetMs ?? 0;
    });
  }

  /// 当前生效的时间轴（带界面上实时调的偏移）。
  LyricTimeline? get _timeline =>
      _lyrics?.timeline.copyWith(offsetMs: _offsetMs);

  void _nudgeOffset(int deltaMs) {
    final MusicLyricsResolution? r = _lyrics;
    if (r == null) return;
    setState(() => _offsetMs += deltaMs);
    // 每次点按直接落库（单行 UPDATE，远比一帧便宜），不做防抖。
    unawaited(
      _service
          .setOffset(_loadedUid!, r.source, _offsetMs)
          .then((_) => appModel.musicLyricsLive.reload()),
    );
    // 循环区间跟着偏移走（循环点是曲目时间，偏移改的是歌词 ↔ 曲目的对应）。
    final (int, int)? loop = _loopLines;
    if (loop != null) unawaited(_applyLoop(loop.$1, loop.$2));
  }

  Future<void> _onLookup(KaraokeLookupHit hit) async {
    _lookupLine = hit.lineIndex;
    appModel.musicStudy.noteLearningAction();
    if (musicLyricsShouldPauseForLookup(
      settingEnabled: appModel.musicLyricsLookupPause,
      playing: _engine.isPlaying,
    )) {
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

  // ── 学习闭环：统计归属 / 收藏上下文 / 制卡 ──────────────────────────────

  @override
  String get dictionarySourceType => kStatSourceMusic;

  @override
  ({String? bookKey, String? title})? get lookupBookIdentity {
    final MusicPlayItem? item = _engine.current;
    if (item == null) return null;
    return (bookKey: item.trackUid, title: item.title);
  }

  MusicLyricLineWindow? get _lookupWindow {
    final LyricTimeline? t = _timeline;
    final int? line = _lookupLine;
    if (t == null || line == null) return null;
    return musicLyricLineWindow(
      t,
      line,
      trackDurationMs: _engine.duration?.inMilliseconds,
    );
  }

  /// 收藏词的上下文：查词所在那行；时间锚点沿用收藏句的音乐口径（起点 / 时长毫秒复用
  /// normCharOffset / normCharLength，制卡历史边界上再拆成 position_ms / duration_ms）。
  @override
  FavoriteLookupContext? get favoriteLookupContext {
    final MusicLyricLineWindow? w = _lookupWindow;
    if (w == null || w.text.isEmpty) return super.favoriteLookupContext;
    return FavoriteLookupContext(
      sentence: w.text,
      normCharOffset: w.startMs,
      normCharLength: w.durationMs,
    );
  }

  /// 查词弹窗点「+」制卡（设计 §12）：句子 = 查词那行，音频片段 = 该行（前后扩 0.5 s），
  /// 卡图 = 封面，出处 = `music` 来源链接（复习时「回到出处」按它播原曲片段）。
  @override
  Future<MinePopupResult> onMineFromPopup(Map<String, String> fields) async {
    // 第一个 await 之前把这次制卡用到的状态读齐：排队期间用户可能已经点了别的行。
    final MusicPlayItem? item = _engine.current;
    final MusicLyricLineWindow? window = _lookupWindow;
    final String sentence = window?.text.isNotEmpty ?? false
        ? window!.text
        : (fields['sentence'] ?? '');
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final String rawPayloadJson = jsonEncode(fields);
    appModel.musicStudy.noteLearningAction();
    Directory? tempDir;
    try {
      String? audioPath;
      if (item != null && window != null && window.durationMs > 0) {
        final ({int startMs, int endMs}) clip = window.clipInFile(
          fileOffsetMs: item.startMs ?? 0,
          trackDurationMs: item.durationMs,
        );
        final MiningMediaCompression compression =
            MiningMediaCompression.resolve(
              imageTier: appModel.miningImageQuality,
              audioTier: appModel.miningAudioQuality,
              format: appModel.videoMiningAnimatedFormat,
            );
        tempDir = await Directory.systemTemp.createTemp(
          'fushi_music_mine_audio_',
        );
        String? failure;
        audioPath = await musicLyricsClipExtractor(
          inputPath: item.path,
          startMs: clip.startMs,
          endMs: clip.endMs,
          outputPath: p.join(
            tempDir.path,
            'sentence.${immersionMiningAudioExtension()}',
          ),
          audioChannels: compression.audioChannels,
          audioBitrate: compression.audioBitrate,
          onFailure: (String summary) => failure ??= summary,
        );
        if (audioPath == null) {
          // 有歌词行、有音频文件却截不出片段：不悄悄降成纯文字卡，报失败（多半是
          // ffmpeg 缺失 / 文件被移走）。
          final String reason = failure == null
              ? 'sentence audio export failed'
              : 'sentence audio export failed: $failure';
          ErrorLogService.instance.log(
            'MusicLyricsPage.mineAudio',
            reason,
            StackTrace.current,
          );
          return MinePopupResult.failed(
            MineOutcome(MineResult.error, errorDetail: reason),
            message: reason,
          );
        }
      }
      final String? cover = item?.coverPath;
      final AnkiMiningContext miningContext = AnkiMiningContext(
        sentence: sentence,
        cueSentence: audioPath != null && sentence.isNotEmpty ? sentence : null,
        documentTitle: item?.title,
        coverPath: cover != null && File(cover).existsSync() ? cover : null,
        sentenceAudioPath: audioPath,
        // 音乐卡单独打 `music` 分类标签（所有者 2026-10-24），与收藏夹批量制卡
        // 的 ankiMiningSourceOf 同口径。
        source: AnkiMiningSource.music,
        bookTitleTag: appModel.autoAddBookNameToTags
            ? BaseAnkiRepository.sanitizeTitleTag(item?.title)
            : null,
        clipStartMs: window?.startMs,
        clipEndMs: window?.endMs,
        sourceLink: item == null || window == null
            ? null
            : musicCardSourceLink(
                trackUid: item.trackUid,
                lineStartMs: window.startMs,
                lineEndMs: window.endMs,
              ),
      );
      FushiToast.showMine(
        msg: t.card_mining_pending,
        status: MineToastStatus.pending,
      );
      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: rawPayloadJson,
        context: miningContext,
      );
      final described = describeMineOutcome(outcome);
      if (described.record && item != null) {
        unawaited(
          _recordMined(
            item: item,
            window: window,
            fields: fields,
            sentence: sentence,
            noteId: outcome.noteId,
          ),
        );
      }
      if (described.success) {
        FushiToast.showMine(msg: described.message, status: described.status);
        return MinePopupResult.mined(outcome);
      }
      return MinePopupResult.failed(outcome, message: described.message);
    } catch (e, stack) {
      ErrorLogService.instance.log('MusicLyricsPage.onMineFromPopup', e, stack);
      return const MinePopupResult();
    } finally {
      final Directory? dir = tempDir;
      if (dir != null) {
        // 后端在 mineEntry 时已把音频读走；临时片段到这里就没人要了。
        unawaited(
          dir
              .delete(recursive: true)
              .then<void>((_) {}, onError: (Object _) {}),
        );
      }
    }
  }

  /// 制卡统计（按曲目）+ 制卡历史（`mined_sentences`，source = music，可回到出处）。
  Future<void> _recordMined({
    required MusicPlayItem item,
    required MusicLyricLineWindow? window,
    required Map<String, String> fields,
    required String sentence,
    required int? noteId,
  }) async {
    final FushiDatabase db = appModel.database;
    try {
      await db.recordMiningEvent(
        bookKey: item.trackUid,
        title: item.title,
        sourceType: kStatSourceMusic,
        at: DateTime.now(),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('MusicLyricsPage.recordMining', e, stack);
    }
    try {
      await recordMusicMinedSentence(
        db: db,
        trackUid: item.trackUid,
        dateKey: FushiDatabase.statDateKeyOf(DateTime.now()),
        lineStartMs: window?.startMs ?? _engine.position.inMilliseconds,
        lineEndMs: window?.endMs,
        trackTitle: item.title,
        artist: item.artist,
        expression: fields['expression'] ?? '',
        reading: fields['reading'] ?? '',
        glossary: fields['glossary'] ?? '',
        sentence: sentence,
        noteId: noteId,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('MusicLyricsPage.recordMined', e, stack);
    }
  }

  // ── AB 循环 ─────────────────────────────────────────────────────────

  /// 当前（或查词）所在的主行；都没有为 -1。
  int get _anchorLine {
    final LyricTimeline? t = _timeline;
    if (t == null) return -1;
    final int cur = musicLyricCurrentLine(t, _engine.position.inMilliseconds);
    return cur >= 0 ? cur : (_lookupLine ?? -1);
  }

  Future<void> _applyLoop(int first, int last) async {
    final LyricTimeline? t = _timeline;
    if (t == null) return;
    final MusicAbLoop? loop = musicAbLoopForLines(
      t,
      first,
      last,
      trackDurationMs: _engine.duration?.inMilliseconds,
    );
    if (loop == null) return;
    setState(() => _loopLines = (first, last));
    await _engine.setAbLoop(loop);
    // 从循环起点开始：用户点的是「循环这一行」，不是「下次播到这里再循环」。
    final Duration pos = _engine.position;
    if (pos < loop.a || pos >= loop.b) await _engine.seek(loop.a);
  }

  Future<void> _toggleLoop() async {
    if (_loopLines != null) {
      setState(() => _loopLines = null);
      await _engine.setAbLoop(null);
      return;
    }
    final int line = _anchorLine;
    if (line < 0) return;
    appModel.musicStudy.noteLearningAction();
    await _applyLoop(line, line);
  }

  Future<void> _extendLoop() async {
    final (int, int)? loop = _loopLines;
    final LyricTimeline? t = _timeline;
    if (loop == null || t == null) return;
    final int next = musicLyricNextMainLine(t, loop.$2);
    if (next < 0) return;
    appModel.musicStudy.noteLearningAction();
    await _applyLoop(loop.$1, next);
  }

  // ── 来源 ─────────────────────────────────────────────────────────────

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
    await _afterSourceChanged(item);
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
    await _afterSourceChanged(item);
  }

  Future<void> _resetSource() async {
    final MusicPlayItem? item = _engine.current;
    if (item == null) return;
    await _service.clearUserEdit(item.trackUid);
    await _afterSourceChanged(item);
  }

  Future<void> _afterSourceChanged(MusicPlayItem item) async {
    // 换了歌词，原来的循环行号对不上了。
    if (_loopLines != null) await _engine.setAbLoop(null);
    unawaited(appModel.musicLyricsLive.reload());
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

  Future<void> _toggleDesktopLyrics() async {
    await appModel.setMusicDesktopLyrics(!appModel.musicDesktopLyrics);
    if (mounted) setState(() {});
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
        if (_hasKaraokeStage) _buildKaraokeButton(),
        if (FloatingLyricChannel.supported) _buildDesktopLyricsButton(),
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

  /// 有 ASS 原文或 CD+G 时才有卡拉 OK 字幕页可开。
  bool get _hasKaraokeStage => _lyrics?.rawAss != null || _cdgPath != null;

  /// 这份 ASS 打开卡拉 OK 字幕页时默认走原样渲染（特效检测 + 设置项）。
  bool get _prefersOriginal =>
      _lyrics?.rawAss != null &&
      musicKaraokeDefaultOverlay(
            hasRawAss: true,
            hasEffects: _lyrics?.timeline.hasEffects ?? false,
            hasTimeline: _lyrics?.timeline.isSynced ?? false,
            preference: appModel.musicKaraokeAssRender,
          ) ==
          MusicKaraokeOverlay.original;

  Future<void> _openKaraoke() async {
    final MusicPlayItem? item = _engine.current;
    if (item == null) return;
    await openMusicKaraokePage(
      context: context,
      track: MusicKaraokeTrack.fromPlayItem(item),
      cdgPath: _cdgPath,
    );
  }

  Widget _buildKaraokeButton() {
    return FushiIconButtonControl(
      key: const ValueKey<String>('music_lyrics_karaoke'),
      icon: const FushiIcon(FushiIcons.mic),
      isSelected: _prefersOriginal,
      tooltip: t.music_karaoke_open,
      onPressed: () => unawaited(_openKaraoke()),
    );
  }

  Widget _buildDesktopLyricsButton() {
    return FushiIconButtonControl(
      key: const ValueKey<String>('music_lyrics_desktop'),
      icon: const FushiIcon(FushiIcons.pictureInPicture),
      isSelected: appModel.musicDesktopLyrics,
      tooltip: t.music_desktop_lyrics_title,
      onPressed: () => unawaited(_toggleDesktopLyrics()),
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
            ? const FushiCircularProgressIndicator()
            : Text(message, style: context.fushiType.bodyLarge),
      );
    }
    final Widget view = KaraokeLyricsView(
      key: ValueKey<String>('karaoke_${_loadedUid}_${r.source}'),
      timeline: r.timeline,
      clock: _clock,
      playing: _engine.isPlaying,
      offsetMs: _offsetMs,
      onSeek: (int ms) => unawaited(_engine.seek(Duration(milliseconds: ms))),
      onLookup: (KaraokeLookupHit hit) => unawaited(_onLookup(hit)),
    );
    // 字幕组特效 ASS：结构化会丢特效，提示去卡拉 OK 字幕页原样渲染（§6.3）。
    return Column(
      children: <Widget>[
        FushiAnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: context.fushiMotion.spatialDefault.curve,
          child: _prefersOriginal
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: FushiInlineNotice(
                    key: const ValueKey<String>('music_lyrics_karaoke_notice'),
                    message: t.music_karaoke_effects_hint,
                    icon: FushiIcons.mic,
                    actions: <Widget>[
                      FushiTextButton(
                        key: const ValueKey<String>(
                          'music_lyrics_karaoke_notice_open',
                        ),
                        onPressed: () => unawaited(_openKaraoke()),
                        child: Text(t.music_karaoke_open),
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        Expanded(child: view),
      ],
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
    final bool synced = _lyrics?.timeline.isSynced ?? false;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (showCover) ...<Widget>[
          Row(
            children: <Widget>[
              const Spacer(),
              if (_hasKaraokeStage) _buildKaraokeButton(),
              if (FloatingLyricChannel.supported) _buildDesktopLyricsButton(),
              _buildMoreButton(context),
            ],
          ),
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
        FushiSlider(
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
        if (synced)
          // 窄栏（宽屏左栏 380）放不下偏移 + 循环一整排时自动换行，不溢出。
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
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
              FushiIconButtonControl(
                key: const ValueKey<String>('music_lyrics_ab_loop'),
                icon: const FushiIcon(FushiIcons.repeat),
                isSelected: _loopLines != null,
                tooltip: _loopLines == null
                    ? t.music_lyrics_ab_loop_line
                    : t.music_lyrics_ab_loop_off,
                onPressed: () => unawaited(_toggleLoop()),
              ),
              // 循环开着时才出现「再加一行」（多行循环），带进出场动效。
              AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.short),
                child: _loopLines == null
                    ? const SizedBox.shrink()
                    : FushiIconButtonControl(
                        key: const ValueKey<String>(
                          'music_lyrics_ab_loop_extend',
                        ),
                        icon: const FushiIcon(FushiIcons.addCircle),
                        tooltip: t.music_lyrics_ab_loop_extend,
                        onPressed: () => unawaited(_extendLoop()),
                      ),
              ),
            ],
          ),
      ],
    );
  }
}
