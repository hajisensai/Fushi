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
import 'dart:isolate';
import 'dart:math' as math;

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
import 'package:fushi/src/floating_ball/floating_ball_config.dart'
    show FloatingBallScope;
import 'package:fushi/src/floating_ball/floating_ball_scene.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_favorites.dart';
import 'package:fushi/src/media/shared/lyrics_shell/lyrics_shell_layout.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show rethemeFushiWithScheme;
import 'package:fushi/src/pages/base_source_page.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show ReaderHeaderAction;
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_item_links.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_backdrop.dart';
import 'package:fushi/src/pages/implementations/music/music_signal_path_panel.dart';
import 'package:fushi/src/pages/implementations/music/music_now_playing_bar.dart'
    show MusicEngineClock, musicPlayModeButton;
import 'package:fushi/src/pages/implementations/music/music_plugin_settings.dart'
    show musicPluginErrorText;
import 'package:fushi/src/pages/implementations/music/music_mv_page.dart'
    show MusicKaraokeTrack, openMusicKaraokePage;
import 'package:fushi/src/utils/adaptive/fushi_page_transitions.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
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
/// [musicCdgCompanionOf] 放后台 isolate 跑（大目录同步列目录会卡开页）。顶层函数：
/// 闭包要是写在 State 方法里，会把整个 State（含 Ticker 等不可发送对象）一起捕获，
/// `Isolate.run` 直接抛「对象不可发送」。插件 / 服务器曲目没有本地目录，不起 isolate。
Future<String?> musicCdgCompanionInBackground(MusicPlayItem item) async {
  if (item.startMs != null || !File(item.path).isAbsolute) return null;
  final String path = item.path;
  try {
    return await Isolate.run(() => _cdgCompanionOfPath(path));
  } on Object {
    return null;
  }
}

String? _cdgCompanionOfPath(String path) {
  final List<String> siblings;
  try {
    siblings = <String>[
      for (final FileSystemEntity e in File(path).parent.listSync())
        if (e is File) e.path,
    ];
  } on FileSystemException {
    return null;
  }
  return pickCdgCompanion(path, siblings);
}

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

  // 封面取色（与有声书歌词播放器同一算法 [ColorScheme.fromImageProvider]）：MD3 下
  // 整页按钮 / 进度条 / 高亮换成封面的颜色，不再是应用主题色。取色是异步的，取到
  // 前先用应用主题。
  ImageProvider? _schemeSource;
  Brightness? _schemeBrightness;
  int _schemeRequest = 0;
  ColorScheme? _coverScheme;
  ThemeData? _themedBase;
  ColorScheme? _themedScheme;
  ThemeData? _themed;

  /// 封面主题之下的一个节点：页内弹出的对话框 / 浮窗用它的 context 打开，
  /// [showDialog] 会把这里的主题捕获进弹窗路由。
  final GlobalKey _themedKey = GlobalKey();
  BuildContext get _themedContext => _themedKey.currentContext ?? context;

  /// build 里调：封面或明暗变了才重新取色。
  void _resolveCoverScheme(String? coverPath, Brightness brightness) {
    final ImageProvider? cover = musicLyricsBackdropCoverProvider(coverPath);
    // ImageProvider 按值比较（FileImage 比路径），同一封面不重取。
    if (cover == _schemeSource && brightness == _schemeBrightness) return;
    _schemeSource = cover;
    _schemeBrightness = brightness;
    final int request = ++_schemeRequest;
    if (cover == null) {
      _coverScheme = null;
      return;
    }
    ColorScheme.fromImageProvider(provider: cover, brightness: brightness)
        .then((ColorScheme scheme) {
          if (!mounted || request != _schemeRequest) return;
          setState(() => _coverScheme = scheme);
        })
        .catchError((Object _) {
          // 封面解码失败：保留应用主题配色，不是错误。
        });
  }

  /// [rethemeFushiWithScheme] 按 (base, scheme) 缓存，整页重建不重算组件主题。
  ThemeData _themeFor(ThemeData base, ColorScheme scheme) {
    final ThemeData? cached = _themed;
    if (cached != null &&
        identical(base, _themedBase) &&
        identical(scheme, _themedScheme)) {
      return cached;
    }
    _themedBase = base;
    _themedScheme = scheme;
    return _themed = rethemeFushiWithScheme(base, scheme);
  }

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

  /// 上次整页重建时引擎的「形状」：曲目 / 播放态 / 时长 / 循环。位置变化不在
  /// 里面——进度条、单行歌词各自听引擎，整页不跟着每个位置事件重建（之前每次
  /// 位置通知都整页 setState，连带左栏材质封面、顶栏测宽、所有歌词行 widget 一起
  /// 重建，是歌词页卡顿的一半）。
  Object? _engineShape;

  void _onEngine() {
    if (!mounted) return;
    final MusicPlayItem? item = _engine.current;
    if (item != null && item.trackUid != _loadedUid) {
      unawaited(_load(item));
    }
    // 引擎换曲 / 关循环后，页上的循环行跟着清。
    if (_loopLines != null && _engine.abLoop == null) _loopLines = null;
    final Object shape = (
      item?.trackUid,
      item?.coverPath,
      _engine.isPlaying,
      _engine.duration,
      _engine.abLoop,
      _loopLines,
      _engine.repeatMode,
      _engine.shuffled,
    );
    if (shape == _engineShape) return;
    _engineShape = shape;
    setState(() {});
  }

  late MusicLyricsLayout _layout = MusicLyricsLayout.fromPref(
    appModelNoUpdate.prefsRepo.musicLyricsLayout,
  );

  void _setLayout(MusicLyricsLayout layout) {
    if (layout == _layout) return;
    setState(() => _layout = layout);
    unawaited(appModel.prefsRepo.setMusicLyricsLayout(layout.prefValue));
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
    // 同目录列一遍找 .cdg：大目录同步 listSync 会卡开页，放后台。
    final String? cdg = await musicCdgCompanionInBackground(item);
    if (!mounted || _loadedUid != item.trackUid) return;
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
      context: _themedContext,
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
      context: _themedContext,
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
    // 背景不再画有声书几何的「歌词底板」：音乐页布局与那套几何对不上，底板落在
    // 歌词区中间、什么都不托（用户截图里那块空的大深色面板）。流体背景两套设计
    // 系统共用（样式 / 动效 / 饱和度见 设置 › 音乐 › 歌词页背景）。
    final Widget background = MusicLyricsBackdrop(
      coverPath: item?.coverPath,
      style: MusicLyricsBackdropStyle.fromPref(
        appModel.prefsRepo.musicLyricsBackdropStyle,
      ),
      animate: appModel.prefsRepo.musicLyricsBackdropAnimate,
      saturation: appModel.prefsRepo.musicLyricsBackdropSaturation,
    );
    // 整页（歌词 + 同坐标系的查词弹窗）放在界面缩放中和层下：查词 WebView 要求
    // 净缩放 = 1，只包弹窗会和歌词选区的坐标对不上（同 reader_fushi_source）。
    Widget page = Scaffold(
      backgroundColor: Colors.transparent,
      body: FushiAppUiScaleNeutralizer(
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: background),
            Positioned.fill(
              child: SafeArea(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) {
                    final bool wide = lyricsPlayerIsWide(box.biggest);
                    return AnimatedSwitcher(
                      duration: fushiMotionDuration(
                        context,
                        FushiMotion.medium,
                      ),
                      child: KeyedSubtree(
                        key: ValueKey<String>('${_layout.name}-$wide'),
                        child: switch ((_layout, wide)) {
                          (MusicLyricsLayout.split, true) => _buildSplit(
                            context,
                            item,
                          ),
                          (MusicLyricsLayout.stage, true) => _buildStage(
                            context,
                            item,
                          ),
                          (MusicLyricsLayout.disc, _) => _buildDisc(
                            context,
                            item,
                            wide: wide,
                          ),
                          (_, false) => _buildNarrow(context, item),
                        },
                      ),
                    );
                  },
                ),
              ),
            ),
            buildDictionary(),
            // 悬浮球按登记场景处的主题画：登记在封面主题之下，球也跟封面取色。
            const FloatingBallScene(
              scope: FloatingBallScope.general,
              actions: <String, ReaderHeaderAction>{},
            ),
          ],
        ),
      ),
    );
    // 弹窗 / 浮窗从 [_themedContext]（这层主题之下）打开，才会带上封面配色。
    page = KeyedSubtree(key: _themedKey, child: page);
    if (apple) {
      page = FushiAppleDarkTier(child: page);
    } else {
      final ThemeData base = Theme.of(context);
      _resolveCoverScheme(item?.coverPath, base.brightness);
      final ColorScheme? scheme = _coverScheme;
      // 结构恒定（没取到色时也挂一层原主题）：换色不重挂整页。
      page = Theme(
        data: scheme == null ? base : _themeFor(base, scheme),
        child: page,
      );
    }
    return page;
  }

  // ---------------------------------------------------------------------------
  // 三种布局（用户 2026-10-29：「ABC 都做可切换，C 底下留一行歌词」，设计稿
  // fushi/build/music_design/lyrics_page.html）
  // ---------------------------------------------------------------------------

  /// A：左封面 + 控件列，右边整块歌词。
  Widget _buildSplit(BuildContext context, MusicPlayItem? item) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // 左右各占一半（用户 2026-10-29 参考图）：左半封面在中线上居中，歌名 /
        // 歌手居中跟在下面，再往下是波浪进度与按钮组；右半歌词左对齐、从半区
        // 起点留一段空再开始。顶栏横贯整页：返回在左上，动作固定在右上角。
        final double cover = math
            .min(c.maxWidth * 0.5 * 0.56, c.maxHeight * 0.42)
            .clamp(180.0, 380.0);
        final double controls = math.max(cover * 1.3, 320.0);
        final ColorScheme cs = Theme.of(context).colorScheme;
        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: _buildTopActions(context, showBack: true),
            ),
            Expanded(
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        // 右半歌词列表才是本页的主滚动；两个都认 PrimaryScrollController
                        // 时桌面滚动条报「一个控制器挂了两个位置」。
                        primary: false,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        child: SizedBox(
                          width: controls,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              SizedBox.square(
                                dimension: cover,
                                child: _LyricsCover(item: item, size: cover),
                              ),
                              const SizedBox(height: 40),
                              Text(
                                item?.title ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: context.fushiType.titleLarge.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              _buildArtistAlbumLinks(
                                context,
                                item,
                                context.fushiType.bodyMedium.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                                align: TextAlign.center,
                              ),
                              const SizedBox(height: 20),
                              _buildSeek(),
                              const SizedBox(height: 12),
                              _buildTransport(context),
                              const SizedBox(height: 4),
                              _buildTools(context),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 24,
                        end: 48,
                      ),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 760),
                          child: _buildLyricsArea(context, item),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// B：歌词居中占满舞台，底部停靠控件条（与宽屏迷你播放条同一套）。
  Widget _buildStage(BuildContext context, MusicPlayItem? item) {
    return Column(
      children: <Widget>[
        _buildHeaderRow(context, item),
        // 歌词在舞台中间一栏（最宽 880），不贴着窗口左边缘。
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: _buildLyricsArea(context, item),
              ),
            ),
          ),
        ),
        _buildDock(context),
      ],
    );
  }

  /// C：居中唱片（饼干形封面嵌在唱片里，播放时转）+ 底下一行当前歌词。
  Widget _buildDisc(
    BuildContext context,
    MusicPlayItem? item, {
    required bool wide,
  }) {
    return Column(
      children: <Widget>[
        _buildHeaderRow(context, item, showCover: false),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              final double disc = (math.min(c.maxWidth, c.maxHeight) * 0.74)
                  .clamp(180.0, 560.0);
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  _SpinningDisc(
                    coverPath: item?.coverPath,
                    size: disc,
                    spinning: _engine.isPlaying,
                  ),
                  const SizedBox(height: 28),
                  Text(
                    item?.title ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.headlineSmall.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  _buildArtistAlbumLinks(
                    context,
                    item,
                    context.fushiType.bodyMedium.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    align: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  _buildSingleLine(context),
                ],
              );
            },
          ),
        ),
        if (wide)
          _buildDock(context)
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[_buildSeek(), _buildTransport(context)],
            ),
          ),
      ],
    );
  }

  /// 窄屏（A / B 共用）：顶行 + 封面 / 歌词切换 + 底部控件。
  Widget _buildNarrow(BuildContext context, MusicPlayItem? item) {
    final Widget face = _showLyrics
        ? KeyedSubtree(
            key: const ValueKey<String>('lyrics'),
            child: _buildLyricsArea(context, item),
          )
        : KeyedSubtree(
            key: const ValueKey<String>('cover'),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: _LyricsCover(item: item, size: 320),
                ),
              ),
            ),
          );
    return Column(
      children: <Widget>[
        _buildTopActions(context, showBack: true, showFaceToggle: true),
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildMeta(context, item),
              _buildSeek(),
              Center(child: _buildTransport(context)),
              _buildTools(context),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 共用零件
  // ---------------------------------------------------------------------------

  /// 顶部动作：返回 + 布局切换 + 卡拉 OK / 桌面歌词 / 更多（放不下自适应收进「⋯」）。
  Widget _buildTopActions(
    BuildContext context, {
    required bool showBack,
    bool showFaceToggle = false,
  }) {
    return FushiFloatingTopBar(
      key: const ValueKey<String>('music_lyrics_back'),
      // 右上动作与左上返回一样裸露图标，不套悬浮胶囊（用户 2026-10-29）。
      bare: true,
      leading: <FushiToolbarItem>[
        if (showBack)
          FushiToolbarItem(
            icon: FushiIcons.back,
            label: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: () => unawaited(Navigator.of(context).maybePop()),
          ),
      ],
      actions: <List<FushiToolbarItem>>[
        <FushiToolbarItem>[
          // 窄屏下「分栏」「舞台」都落成同一个竖排版面，只留一个（选中时记为分栏），
          // 不然两个按钮看着重复（用户 2026-10-29）。
          for (final MusicLyricsLayout l
              in lyricsPlayerIsWide(MediaQuery.sizeOf(context))
                  ? MusicLyricsLayout.values
                  : const <MusicLyricsLayout>[
                      MusicLyricsLayout.split,
                      MusicLyricsLayout.disc,
                    ])
            FushiToolbarItem(
              key: ValueKey<String>('music_lyrics_layout_${l.name}'),
              icon: l.icon,
              label: l.label,
              selected:
                  l == MusicLyricsLayout.split &&
                      !lyricsPlayerIsWide(MediaQuery.sizeOf(context))
                  ? _layout != MusicLyricsLayout.disc
                  : _layout == l,
              onPressed: () => _setLayout(l),
            ),
        ],
        <FushiToolbarItem>[
          if (showFaceToggle && _layout != MusicLyricsLayout.disc)
            FushiToolbarItem(
              key: const ValueKey<String>('music_lyrics_toggle_face'),
              icon: _showLyrics ? FushiIcons.image : FushiIcons.lyrics,
              label: _showLyrics
                  ? t.music_lyrics_show_cover
                  : t.music_lyrics_title,
              onPressed: () => setState(() => _showLyrics = !_showLyrics),
            ),
          if (_hasKaraokeStage)
            FushiToolbarItem(
              key: const ValueKey<String>('music_lyrics_karaoke'),
              icon: FushiIcons.mic,
              label: t.music_karaoke_open,
              selected: _prefersOriginal,
              onPressed: () => unawaited(_openKaraoke()),
            ),
          if (FloatingLyricChannel.supported)
            FushiToolbarItem(
              key: const ValueKey<String>('music_lyrics_desktop'),
              icon: FushiIcons.pictureInPicture,
              label: t.music_desktop_lyrics_title,
              selected: appModel.musicDesktopLyrics,
              onPressed: () => unawaited(_toggleDesktopLyrics()),
            ),
          FushiToolbarItem(
            key: const ValueKey<String>('music_lyrics_more'),
            icon: FushiIcons.moreHoriz,
            label: MaterialLocalizations.of(context).moreButtonTooltip,
            onPressed: () => unawaited(_openSourceActions()),
          ),
        ],
      ],
    );
  }

  /// B / C 的顶行：小封面 + 歌名在左，动作在右。
  Widget _buildHeaderRow(
    BuildContext context,
    MusicPlayItem? item, {
    bool showCover = true,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Row(
              children: <Widget>[
                FushiIconButtonControl(
                  icon: const FushiIcon(FushiIcons.back),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: () => unawaited(Navigator.of(context).maybePop()),
                ),
                if (showCover) ...<Widget>[
                  const SizedBox(width: 12),
                  SizedBox.square(
                    dimension: 64,
                    child: _LyricsCover(item: item, size: 64, compact: true),
                  ),
                  const SizedBox(width: 14),
                  Flexible(child: _buildMeta(context, item, dense: true)),
                ],
              ],
            ),
          ),
          Flexible(child: _buildTopActions(context, showBack: false)),
        ],
      ),
    );
  }

  /// 歌名 + 歌手。
  Widget _buildMeta(
    BuildContext context,
    MusicPlayItem? item, {
    bool dense = false,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          item?.title ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: dense
              ? context.fushiType.titleMedium.copyWith(
                  fontWeight: FontWeight.w800,
                )
              : context.fushiType.headlineSmall.copyWith(
                  fontWeight: FontWeight.w800,
                ),
        ),
        _buildArtistAlbumLinks(
          context,
          item,
          context.fushiType.bodyMedium.copyWith(color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  /// 「歌手 · 专辑」一行：两段各自可点（用户 2026-10-29：歌词页点歌手进歌手页、
  /// 点专辑进专辑页）。来源不支持跳转的那段只是普通文字。
  Widget _buildArtistAlbumLinks(
    BuildContext context,
    MusicPlayItem? item,
    TextStyle style, {
    TextAlign align = TextAlign.start,
  }) {
    if (item == null) return const SizedBox.shrink();
    final String? artist = item.artist?.isEmpty ?? true ? null : item.artist;
    final String? album = item.album?.isEmpty ?? true ? null : item.album;
    final List<Widget> parts = <Widget>[
      if (artist != null)
        _LinkText(
          key: const ValueKey<String>('music_lyrics_artist_link'),
          text: artist,
          style: style,
          onTap: musicItemHasArtistLink(item)
              ? () => unawaited(openMusicArtistOf(context, appModel, item))
              : null,
        ),
      if (artist != null && album != null) Text(' · ', style: style),
      if (album != null)
        _LinkText(
          key: const ValueKey<String>('music_lyrics_album_link'),
          text: album,
          style: style,
          onTap: musicItemHasAlbumLink(item)
              ? () => unawaited(openMusicAlbumOf(context, appModel, item))
              : null,
        ),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: align == TextAlign.center
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      children: <Widget>[
        for (final Widget w in parts) w is _LinkText ? Flexible(child: w) : w,
      ],
    );
  }

  /// 波浪进度（自带位置监听与拖动，不随整页重建）。
  Widget _buildSeek() => FushiWavySeekBar(
    key: const ValueKey<String>('music_lyrics_seek'),
    clock: MusicEngineClock(_engine),
    clockListenable: _engine,
    isPlaying: _engine.isPlaying,
    onSeek: (Duration d) => unawaited(_engine.seek(d)),
    strokeWidth: 4,
    barHeight: 20,
    debugLabel: 'music-lyrics-seek',
  );

  /// 播放器按钮行（用户 2026-10-29 参考图）：播放模式 · 上一首 · 播放 · 下一首 ·
  /// 收藏，五格等宽、等距，图标同一尺寸，只有播放键是实心圆。
  Widget _buildTransport(BuildContext context) {
    final MusicSession session = appModelNoUpdate.musicSession;
    final MusicPlayerEngine engine = session.engine;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 五格 64dp + 四道 12dp 间距 = 368dp；窄于此（手机竖屏的歌词栏常只有 320dp 上下）时
        // 格子等比收窄，下限 48dp 命中区，不让按钮行溢出。
        const double maxSlot = 64;
        const double gap = 12;
        final double fit = constraints.maxWidth.isFinite
            ? (constraints.maxWidth - 4 * gap) / 5
            : maxSlot;
        final double slot = fit.clamp(48, maxSlot).toDouble();
        return _buildTransportRow(context, engine, session, cs, slot, gap);
      },
    );
  }

  Widget _buildTransportRow(
    BuildContext context,
    MusicPlayerEngine engine,
    MusicSession session,
    ColorScheme cs,
    double slot,
    double gap,
  ) {
    const double icon = 30;
    Widget cell(Widget child) => SizedBox(
      width: slot,
      height: slot,
      child: Center(child: child),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        cell(musicPlayModeButton(context, engine, iconSize: icon)),
        SizedBox(width: gap),
        cell(
          FushiIconButtonControl(
            iconSize: icon,
            tooltip: t.shortcut_action_music_previous_track,
            onPressed: () => unawaited(engine.skipPrevious()),
            icon: const FushiIcon(FushiIcons.skipPrevious),
          ),
        ),
        SizedBox(width: gap),
        cell(
          FushiExpressivePlayButton(
            key: const ValueKey<String>('music_lyrics_play_pause'),
            isPlaying: engine.isPlaying,
            size: slot,
            onPressed: () => unawaited(engine.togglePlayPause()),
          ),
        ),
        SizedBox(width: gap),
        cell(
          FushiIconButtonControl(
            iconSize: icon,
            tooltip: t.shortcut_action_music_next_track,
            onPressed: () => unawaited(engine.skipNext()),
            icon: const FushiIcon(FushiIcons.skipNext),
          ),
        ),
        SizedBox(width: gap),
        cell(_buildFavoriteButton(session, icon, cs)),
      ],
    );
  }

  /// 收藏（在线平台的「喜欢」）：只有声明了收藏能力的插件曲目才有，其余留空位
  /// 保持五格对称。
  Widget _buildFavoriteButton(
    MusicSession session,
    double icon,
    ColorScheme cs,
  ) {
    return ListenableBuilder(
      listenable: session,
      builder: (BuildContext context, _) {
        final MusicPlayItem? item = session.engine.current;
        if (item == null || !session.canFavorite(item)) {
          return const SizedBox.shrink();
        }
        final bool liked = session.isFavorite(item);
        return FushiIconButtonControl(
          key: const ValueKey<String>('music_lyrics_favorite'),
          iconSize: icon,
          tooltip: liked ? t.music_favorite_remove : t.music_favorite_add,
          onPressed: () => unawaited(_toggleFavorite(session, item)),
          icon: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.short),
            transitionBuilder: (Widget child, Animation<double> a) =>
                ScaleTransition(scale: a, child: child),
            child: FushiIcon(
              liked
                  ? FushiIcons.filled(FushiIcons.favorite)
                  : FushiIcons.favorite,
              key: ValueKey<bool>(liked),
              color: liked ? const Color(0xFFFF4D6D) : null,
            ),
          ),
        );
      },
    );
  }

  Future<void> _toggleFavorite(MusicSession session, MusicPlayItem item) async {
    try {
      await session.toggleFavorite(item);
    } on MusicFavoriteLoginRequired catch (e) {
      final String name =
          session.favorites?.states
              .where((MusicPluginLikeState s) => s.manifest.id == e.pluginId)
              .firstOrNull
              ?.manifest
              .name ??
          e.pluginId;
      FushiToast.show(
        msg: t.music_favorite_login_required(name: name),
        severity: ToastSeverity.warning,
      );
    } on MusicFavoriteUnsupported {
      // 按钮只在能收藏时出现；竞态下插件刚被停用，静默。
    } catch (e) {
      FushiToast.show(
        msg: t.music_favorite_failed(error: musicPluginErrorText(e)),
        severity: ToastSeverity.error,
      );
    }
  }

  /// 小工具：偏移 ± 与 AB 循环（只有带时间轴的歌词才有）。
  Widget _buildTools(BuildContext context) {
    final bool synced = _lyrics?.timeline.isSynced ?? false;
    if (!synced) return const SizedBox.shrink();
    return Wrap(
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
                  key: const ValueKey<String>('music_lyrics_ab_loop_extend'),
                  icon: const FushiIcon(FushiIcons.addCircle),
                  tooltip: t.music_lyrics_ab_loop_extend,
                  onPressed: () => unawaited(_extendLoop()),
                ),
        ),
      ],
    );
  }

  /// B / C 宽屏底部控件：不再画整宽的实色底板（用户 2026-10-29：「好丑」，
  /// 右侧大半截空着）。居中一列、最宽 720：波浪进度在上，按钮组居中，偏移 /
  /// AB 循环收在左侧、右侧留同宽占位让按钮组真居中；底下一层渐隐压暗保证
  /// 流体背景上的可读性。
  Widget _buildDock(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(alpha: 0.22),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _buildSeek(),
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    Expanded(
                      // 偏移 ± 与 AB 循环恒一行（用户 2026-10-29：「放在同一行」）：
                      // 放不下就等比缩小，不折行。
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: _buildTools(context),
                      ),
                    ),
                    _buildTransport(context),
                    const Expanded(child: SizedBox.shrink()),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 唱片布局底下的一行当前歌词（+ 下一行淡出）。没歌词时换成「纯音乐 · 找歌词」。
  Widget _buildSingleLine(BuildContext context) {
    final LyricTimeline? timeline = _timeline;
    if (timeline == null || timeline.lines.isEmpty) {
      return _buildNoLyrics(context);
    }
    return _CurrentLyricLine(
      engine: _engine,
      timeline: timeline,
      synced: timeline.isSynced,
    );
  }

  /// 没有歌词（或加载失败）：纯音乐提示 + 找歌词。
  Widget _buildNoLyrics(BuildContext context) {
    if (_loading) return const FushiCircularProgressIndicator();
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: <Widget>[
        Text(
          _error != null ? t.music_lyrics_online_failed : t.music_lyrics_empty,
          style: context.fushiType.bodyLarge,
        ),
        FushiFilledButton.tonalIcon(
          key: const ValueKey<String>('music_lyrics_find'),
          onPressed: () => unawaited(_openSourceActions()),
          icon: const FushiIcon(FushiIcons.search),
          label: Text(t.music_lyrics_search_online),
        ),
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

  Future<void> _openSourceActions() async {
    final int? choice = await showFushiChoiceDialog<int>(
      context: _themedContext,
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
        // 信号路径从底部播放条挪进这里（用户 2026-10-29：底栏只留循环与音量）。
        FushiChoiceOption<int>(
          value: 4,
          label: t.music_signal_path_title,
          icon: FushiIcons.highQuality,
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
      case 4:
        if (mounted) {
          await showMusicSignalPathPanel(_themedContext, appModelNoUpdate);
        }
      default:
    }
  }

  Widget _buildLyricsArea(BuildContext context, MusicPlayItem? item) {
    final MusicLyricsResolution? r = _lyrics;
    if (r == null || r.timeline.lines.isEmpty) {
      // A / B 遇到没歌词的歌切到唱片态（与 C 同一个唱片），不再一行字挂在空处。
      if (_loading) {
        return const Center(child: FushiCircularProgressIndicator());
      }
      return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) => Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _SpinningDisc(
              coverPath: item?.coverPath,
              size: (math.min(c.maxWidth, c.maxHeight) * 0.5).clamp(
                140.0,
                360.0,
              ),
              spinning: _engine.isPlaying,
            ),
            const SizedBox(height: 24),
            _buildNoLyrics(context),
          ],
        ),
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
}

/// 歌词页布局（偏好 `music_lyrics_layout`）。
enum MusicLyricsLayout {
  /// A：左封面 + 右歌词。
  split('split'),

  /// B：歌词居中 + 底部停靠条。
  stage('stage'),

  /// C：唱片 + 一行歌词。
  disc('disc');

  const MusicLyricsLayout(this.prefValue);

  final String prefValue;

  static MusicLyricsLayout fromPref(String value) =>
      MusicLyricsLayout.values
          .where((MusicLyricsLayout l) => l.prefValue == value)
          .firstOrNull ??
      MusicLyricsLayout.split;

  IconData get icon => switch (this) {
    MusicLyricsLayout.split => FushiIcons.sidebar,
    MusicLyricsLayout.stage => FushiIcons.lyrics,
    MusicLyricsLayout.disc => FushiIcons.music,
  };

  String get label => switch (this) {
    MusicLyricsLayout.split => t.music_lyrics_layout_split,
    MusicLyricsLayout.stage => t.music_lyrics_layout_stage,
    MusicLyricsLayout.disc => t.music_lyrics_layout_disc,
  };
}

/// 歌词页封面：专辑材质；[compact] 是顶行小缩略图。
class _LyricsCover extends StatelessWidget {
  const _LyricsCover({
    required this.item,
    required this.size,
    this.compact = false,
  });

  final MusicPlayItem? item;
  final double size;
  final bool compact;

  @override
  Widget build(BuildContext context) => musicMaterialCover(
    MusicCover(coverPath: item?.coverPath, size: compact ? size : 640),
    compact: compact,
    // 播放器里的大封面跟随指针 3D 倾斜（用户 2026-10-29：「加回去」）；顶行的
    // 小封面不倾斜。
    tilt: !compact,
  );
}

/// 唱片：深色同心纹盘面，中央嵌十二角饼干形封面；播放时匀速转，暂停停在原角度。
class _SpinningDisc extends StatefulWidget {
  const _SpinningDisc({
    required this.coverPath,
    required this.size,
    required this.spinning,
  });

  final String? coverPath;
  final double size;
  final bool spinning;

  @override
  State<_SpinningDisc> createState() => _SpinningDiscState();
}

class _SpinningDiscState extends State<_SpinningDisc>
    with SingleTickerProviderStateMixin {
  /// 一圈 12 秒（与设计稿一致；慢到不抢歌词的注意力）。
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_SpinningDisc old) {
    super.didUpdateWidget(old);
    if (old.spinning != widget.spinning) _sync();
  }

  void _sync() {
    final bool motion = fushiExpressiveMotionEnabled(context);
    if (widget.spinning && motion) {
      if (!_turn.isAnimating) unawaited(_turn.repeat());
    } else {
      _turn.stop();
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double size = widget.size;
    // 黑胶（用户 2026-10-29：「唱片那个材质改成黑胶」）：密纹盘面 + 两道随盘面
    // 转动的扇形反光 + 中央圆形贴标（封面）+ 中心轴孔。整张一起转，反光跟着转
    // 读作「光打在转动的胶片上」。
    // 贴标约占盘面 2/3（用户 2026-10-29 参考图：封面显示大一点）。
    final double label = size * 0.66;
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: size * 0.1,
                offset: Offset(0, size * 0.05),
              ),
            ],
          ),
          child: RotationTransition(
            turns: _turn,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                const Positioned.fill(
                  child: CustomPaint(painter: _VinylPainter()),
                ),
                ClipOval(
                  child: SizedBox.square(
                    dimension: label,
                    child: MusicCover(
                      coverPath: widget.coverPath,
                      size: label,
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                ),
                // 中心轴孔。
                Container(
                  width: size * 0.028,
                  height: size * 0.028,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF0B0B0D),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 黑胶盘面：近黑底、一圈圈细密纹（亮暗交替的同心圆）、外缘一道唇边、贴标外
/// 一圈无纹带，再叠两道对角的扇形反光（SweepGradient）。
class _VinylPainter extends CustomPainter {
  const _VinylPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF121214));
    // 密纹：从贴标外的无纹带到外缘唇边。
    final Paint groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;
    final double inner = r * 0.69;
    final double outer = r * 0.955;
    int i = 0;
    for (double rr = inner; rr < outer; rr += 1.6, i++) {
      groove.color = i.isEven
          ? const Color(0x14FFFFFF)
          : const Color(0x22000000);
      canvas.drawCircle(c, rr, groove);
    }
    // 几道较宽的「曲间空隙」。
    final Paint gap = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = const Color(0xFF0A0A0B);
    for (final double f in <double>[0.76, 0.85, 0.92]) {
      canvas.drawCircle(c, r * f, gap);
    }
    // 外缘唇边。
    canvas.drawCircle(
      c,
      r * 0.985,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.03
        ..color = const Color(0xFF1B1B1E),
    );
    // 扇形反光：两道对角的亮楔。
    final Rect box = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const SweepGradient(
          colors: <Color>[
            Color(0x00FFFFFF),
            Color(0x2EFFFFFF),
            Color(0x00FFFFFF),
            Color(0x00FFFFFF),
            Color(0x24FFFFFF),
            Color(0x00FFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: <double>[0.02, 0.1, 0.18, 0.52, 0.6, 0.68, 1],
        ).createShader(box),
    );
  }

  @override
  bool shouldRepaint(covariant _VinylPainter oldDelegate) => false;
}

/// 唱片布局底下的一行当前歌词 + 淡出的下一行；只这一小块跟着播放位置重建。
class _CurrentLyricLine extends StatelessWidget {
  const _CurrentLyricLine({
    required this.engine,
    required this.timeline,
    required this.synced,
  });

  final MusicPlayerEngine engine;
  final LyricTimeline timeline;
  final bool synced;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: engine,
      builder: (BuildContext context, _) {
        final int cur = synced
            ? musicLyricCurrentLine(timeline, engine.position.inMilliseconds)
            : 0;
        final int i = cur < 0 ? 0 : cur;
        final LyricLine line = timeline.lines[i];
        final LyricLine? next = i + 1 < timeline.lines.length
            ? timeline.lines[i + 1]
            : null;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            child: Column(
              key: ValueKey<int>(i),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  line.text,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.fushiType.headlineMedium.copyWith(
                    fontWeight: FontWeight.w800,
                    color: cur < 0 ? cs.onSurfaceVariant : cs.onSurface,
                  ),
                ),
                if (line.translations.isNotEmpty)
                  Text(
                    line.translations.first.text,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.bodyLarge.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                if (next != null && synced)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      next.text,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.fushiType.titleMedium.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 可点的一段文字：悬停加下划线、鼠标变手形；[onTap] 为 null 时就是普通文字。
class _LinkText extends StatefulWidget {
  const _LinkText({
    super.key,
    required this.text,
    required this.style,
    required this.onTap,
  });

  final String text;
  final TextStyle style;
  final VoidCallback? onTap;

  @override
  State<_LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<_LinkText> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Widget text = Text(
      widget.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _hover
          ? widget.style.copyWith(
              decoration: TextDecoration.underline,
              decorationColor: widget.style.color,
            )
          : widget.style,
    );
    final VoidCallback? onTap = widget.onTap;
    if (onTap == null) return text;
    return Semantics(
      link: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: text,
        ),
      ),
    );
  }
}
