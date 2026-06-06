import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_shader_manager.dart';
import 'package:hibiki/src/media/video/video_watch_tracker.dart';
import 'package:hibiki/src/pages/implementations/jimaku_subtitle_dialog.dart';
import 'package:hibiki/src/pages/implementations/video_shader_dialog.dart';
import 'package:hibiki/src/media/video/video_sidecar.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki/src/media/video/video_subtitle_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';

/// 视频页：media_kit 播放器 + 可点击字幕 overlay（点词查词 + 制卡）。
///
/// 装配：[VideoPlayerController.load] 打开视频 + cue 同步 → [Stack] 叠
/// [Video]（media_kit 桌面控制：播放/进度/音量/全屏 + 顶栏字幕轨/音轨切换）
/// 与 [VideoSubtitleOverlay]（逐字符可点）。
///
/// 查词浮层与阅读器/词典页**统一**：点字幕字符 → [_lookupAt] 经
/// [DictionaryPageMixin] 的 [pushNestedPopup] 推入 [DictionaryPopupLayer] 浮层
/// （popup.html WebView，与书内/词典页同款：递归查词 + 单词发音 + auto-read +
/// 制卡），并用被点字符的屏幕 rect 定位。制卡走 mixin 的 [onMineEntry]——视频页
/// 覆写它注入视频专属上下文：当前帧截图 coverPath + 当前字幕 cue 的音频片段
/// （裁**当前选中音轨**）sasayakiAudioPath + 例句 sentence + 单词发音
/// （popup.js 已把 `{audio}` 写进 fields）。
///
/// 全屏：media_kit 全屏是独立 root 路由，复用同一 `controls` builder，故
/// [VideoSubtitleOverlay] 包进 controls builder（[_buildVideoControls]）随全屏
/// 一起进路由，保证全屏时字幕仍显示且可点查词。
///
/// 查词浮层用**根 Overlay**（`Overlay.of(context, rootOverlay: true)`）渲染，而非本页
/// `Stack`——这样全屏（media_kit 推到根 navigator 的独立路由）时浮层也能浮在全屏画面
/// **之上**，窗口/全屏统一一套。根 Overlay 在 [HibikiAppUiScale] 的 `FittedBox` 之内
/// （挂在 `MaterialApp.builder`），其坐标空间是**缩放后的小画布（view/s）**；若浮层直接在
/// 此渲染，其词典 WebView 会按小画布尺寸栅格化、再被外层 `FittedBox` 拉大 → **字糊**
/// （与 BUG-039 阅读器同源；BUG-051）。故 [_buildPopupOverlay] 把整棵浮层子树用
/// [HibikiAppUiScaleNeutralizer] 中和回**真实视口尺寸、净缩放=1**，WebView 按原生像素密度
/// 渲染 → 清晰。中和后浮层坐标系即真实屏幕空间（净变换=1），与 `localToGlobal` 的字符
/// rect 同系，故 [_lookupAt] **直接**用该屏幕 rect 定位（不再 ÷s 换算到画布），界面任意
/// 缩放下定位都不偏。
class VideoHibikiPage extends ConsumerStatefulWidget {
  const VideoHibikiPage({
    required this.bookUid,
    required this.repo,
    super.key,
  });

  final String bookUid;
  final VideoBookRepository repo;

  /// 查词浮层关闭后是否应恢复播放：仅当浮层栈**已全部关闭**（[stackEmpty]）且本次确实
  /// 是因查词而由我们暂停了正在播放的视频（[pausedForLookup]）。两条件缺一不可——关掉
  /// 递归查词的子层但父层仍在（栈非空）不恢复；查词前本就暂停的视频（未置位）也不恢复。
  /// 纯函数：与 [_VideoHibikiPageState._popNestedPopupAt] 共用，供单测直接验证（BUG-072）。
  @visibleForTesting
  static bool shouldResumeAfterLookupDismiss({
    required bool stackEmpty,
    required bool pausedForLookup,
  }) =>
      stackEmpty && pausedForLookup;

  @override
  ConsumerState<VideoHibikiPage> createState() => _VideoHibikiPageState();
}

/// 集成测试钩子（仅测试用）：对当前 [VideoHibikiPage] 的 [State] 读播放位置 /
/// 驱动真实播放，验证「退出→再进续播」链路而不暴露页面私有字段。State 以
/// [VideoHibikiTestHooks] 形式按接口暴露，测试经 `tester.state` 拿到后 `as` 转型。
@visibleForTesting
abstract class VideoHibikiTestHooks {
  /// 当前播放位置（毫秒）；未就绪为 null。
  int? get debugPositionMs;

  /// 开始真实播放（驱动 libmpv），让位置自然前进。
  Future<void> debugPlay();
}

class _VideoHibikiPageState extends ConsumerState<VideoHibikiPage>
    with DictionaryPageMixin, WidgetsBindingObserver
    implements VideoHibikiTestHooks {
  @override
  int? get debugPositionMs => _controller?.positionMs;

  @override
  Future<void> debugPlay() async => _controller?.play();

  VideoPlayerController? _controller;
  bool _failed = false;
  String? _title;

  /// media_kit [Video] 的键盘焦点节点。media_kit 的 `Video` 自带 FocusNode + 内置
  /// 快捷键（空格=播放/暂停、方向键=快进/快退/音量等）。本页把这个节点提到 State 持有，
  /// 是为了在任何**会夺走窗口键盘焦点的覆盖层**（对话框 / bottom sheet / 系统文件选择器）
  /// 关闭后，能主动把焦点还给 [Video]——否则那些覆盖层关闭后焦点悬空，空格等快捷键失灵
  /// （根因：FilePicker 打开系统对话框抢走焦点，关闭后不会自动归还）。见 [_refocusVideo]。
  final FocusNode _videoFocusNode = FocusNode(debugLabel: 'videoKeyboard');

  /// 观看统计采集器（观看时长 + 字幕字数 + 完成标记）；首次 load 建，dispose 释放。
  VideoWatchTracker? _watchTracker;

  /// 查词浮层栈（与阅读器/词典页同款，由 [DictionaryPageMixin] 管理）。
  final List<NestedPopupEntry> _popupStack = <NestedPopupEntry>[];

  /// 承载查词浮层栈的根 Overlay 入口；非空时浮层栈渲染在根 Overlay（窗口/全屏统一，
  /// 全屏时浮在 media_kit 全屏路由之上）。栈空时移除、栈变化时 `markNeedsBuild`。
  OverlayEntry? _popupOverlayEntry;

  /// 最近一次查词所在字幕句（整条 cue 文本）；[onMineEntry] 制卡时作 sentence。
  /// 点字符查词时即时记录，确保制卡例句是「点词那一刻的那句字幕」。
  String _lastLookupSentence = '';

  /// 「本次查词浮层是我们因查词而主动暂停了正在播放的视频」标记。
  ///
  /// 查词暂停 / 关浮层恢复与阅读器 [ReaderHibikiPage] 同源：浮层打开时若视频在播放则
  /// 暂停（让用户读词），浮层栈**全部关闭**后再自动恢复播放。video 页用
  /// [DictionaryPageMixin]（没有 reader 的 `onAllPopupsDismissed` 钩子），故用本标记 +
  /// 在 [_popNestedPopupAt] 这唯一的关栈汇聚点恢复，覆盖遮罩点击 / 返回键 / 浮层
  /// 滑动·Esc 全部关闭路径。仅当查词前视频确在播放才置位，避免把查词前本就暂停的
  /// 视频自动播起来；递归查词（已暂停，`isPlaying==false`）不会覆写它（BUG-072）。
  bool _pausedForLookup = false;

  // ── DictionaryPageMixin 必需的抽象成员 ──────────────────────────────
  @override
  AppModel get mixinAppModel => appModel;

  @override
  ThemeData get mixinTheme => Theme.of(context);

  /// 多集播放列表（单视频导入时为空）。
  List<PlaylistEntry> _episodes = const <PlaylistEntry>[];

  /// 当前集索引（[_episodes] 下标）；单视频恒 0。
  int _currentEpisode = 0;

  /// 当前播放的视频文件绝对路径（枚举字幕源用）；未 load 时为 null。
  String? _currentVideoPath;

  /// 当前选中的字幕源持久化值（外挂路径 / `embedded:<n>` / null=关闭）；
  /// 用于字幕源菜单高亮当前项。
  String? _currentSubtitleSource;

  /// 当前选中的音轨 id（libmpv `AudioTrack.id`）；null=未选过跟随默认。
  /// 多集换集时复用同一值（用户选了日语音轨，每集都用日语）。
  String? _currentAudioTrackId;

  /// 音画延迟（毫秒）：字幕 cue 同步偏移，跨重启保留；换集复用同一值。
  int _delayMs = 0;

  /// 播放倍速：用户在设置面板调，跨重启保留；换集复用同一值（速度记忆）。
  double _playbackSpeed = 1.0;

  bool get _isPlaylist => _episodes.length > 1;

  AppModel get appModel => ref.read(appProvider);

  /// app 当前目标学习语言代码（如 `'ja'`/`'ko'`），用于 sidecar 字幕语言优先检测。
  String get _targetLangCode => appModel.targetLanguage.locale.languageCode;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  /// app 进后台（[AppLifecycleState.inactive]/`.paused`/`.hidden`）时把当前播放
  /// 位置 **await 落库**：dispose 在硬杀进程时不会跑，周期保存是 fire-and-forget
  /// 且后台定时器会挂起。趁 controller 仍存活把退出瞬间位置写穿（对齐阅读器
  /// `_syncAndFlushPosition`）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        // inactive 仅瞬态过渡（通知栏下拉 / 多任务切换）：落库即可，不停观看计时
        // （频繁误停丢真实时长）；clamp（[isContinuousWatchGap]）兜底任何残留异常间隔。
        unawaited(_controller?.flushPosition());
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // 真后台 / 熄屏：落库 + 暂停观看计时器，避免把后台时长计入。stop() 内部先 flush
        // 退出瞬间的部分窗口（≤60s）再 cancel，不丢已观看时长。
        unawaited(_controller?.flushPosition());
        _watchTracker?.stop();
      case AppLifecycleState.resumed:
        // 回前台：重启观看计时器（start() 重置 _tickStart=now，下一窗从此刻起算）。
        _watchTracker?.start();
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _init() async {
    final VideoBookRow? row = await widget.repo.getByBookUid(widget.bookUid);
    if (row == null) {
      if (mounted) setState(() => _failed = true);
      return;
    }

    // 记录持久化的字幕源（菜单高亮当前项用）+ 音轨偏好（换集复用）+ 音画延迟
    // （跨重启保留）+ 播放倍速（per-book 偏好，速度记忆）。
    _currentSubtitleSource = row.subtitleSource;
    _currentAudioTrackId = row.audioTrackId;
    _delayMs = row.delayMs;
    _playbackSpeed = _readPersistedSpeed();

    // 解析播放列表（若有）。非空则按 currentEpisode 载对应集；否则走单视频路径。
    final String? playlistJson = row.playlistJson;
    if (playlistJson != null && playlistJson.isNotEmpty) {
      final List<dynamic> raw = jsonDecode(playlistJson) as List<dynamic>;
      _episodes = raw
          .map((dynamic e) => PlaylistEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    if (_episodes.isNotEmpty) {
      final int idx = row.currentEpisode.clamp(0, _episodes.length - 1);
      // 每集各记自己的进度：恢复到 currentEpisode 那集的 entry.positionMs
      // （取代旧的「整个 VideoBook 一个 lastPositionMs」）。
      await _loadEpisode(
        idx,
        initialPositionMs: _episodes[idx].positionMs,
        subtitleSource: row.subtitleSource,
      );
      return;
    }

    // 单视频路径（无播放列表）。
    await _loadSingle(row);
  }

  /// per-book 播放倍速偏好 key（速度记忆，跨重启保留）。
  String get _speedPrefKey => 'video_speed_${widget.bookUid}';

  /// 读 per-book 持久化倍速（无则 1.0）。
  double _readPersistedSpeed() {
    final double v =
        (appModel.prefsRepo.getPref(_speedPrefKey, defaultValue: 1.0) as num)
            .toDouble();
    return v.clamp(0.25, 4.0);
  }

  /// 载入单视频（无播放列表）：优先用 DB 已存 cue；否则先尝试恢复用户上次选的
  /// 字幕源（[row.subtitleSource] 跨重启保留），无匹配再退默认 sidecar 探测。
  Future<void> _loadSingle(VideoBookRow row) async {
    List<AudioCue> cues = await widget.repo.loadCues(widget.bookUid);
    String? externalSub = row.subtitleSource;

    if (cues.isEmpty) {
      // ① 优先恢复持久化的字幕源（精确匹配本视频的同一源）。
      if (row.subtitleSource != null && row.subtitleSource!.isNotEmpty) {
        final ({String persisted, List<AudioCue> cues})? restored =
            await _restorePersistedSubtitle(
          videoPath: row.videoPath,
          persisted: row.subtitleSource,
          crossEpisode: false,
        );
        if (restored != null) {
          cues = restored.cues;
          externalSub = restored.persisted;
        }
      }
      // ② 无持久化 / 无匹配：退默认 sidecar 探测。
      if (cues.isEmpty && externalSub == null) {
        final ({String path, List<AudioCue> cues})? sidecar =
            await _detectSidecar(row.videoPath, widget.bookUid);
        if (sidecar != null) {
          cues = sidecar.cues;
          externalSub = sidecar.path;
        }
      }
    }
    await _applyLoad(
      videoPath: row.videoPath,
      cues: cues,
      title: row.title,
      initialPositionMs: row.lastPositionMs,
      externalSubtitlePath: externalSub,
    );
  }

  /// 尝试用持久化偏好 [persisted] 在 [videoPath] 的可用字幕源里选一个并加载 cue。
  ///
  /// [crossEpisode]=false（单视频重启恢复）：用 [SubtitleSource.matchesPersisted]
  /// 精确匹配同一源。[crossEpisode]=true（播放列表换集）：用
  /// [pickEpisodeSubtitleSource] 按「同类偏好」（内嵌同 streamIndex / 外挂同语言
  /// 后缀）从新集源里选。
  ///
  /// 返回所选源的「实际持久化值 + 解析出的 cue」；无匹配 / 解析空 cue 返回 null
  /// （调用方退默认 sidecar）。返回的 persisted 用作 [_applyLoad] 的
  /// externalSubtitlePath（内嵌源也走 `embedded:<n>` 字符串，与既有约定一致）。
  Future<({String persisted, List<AudioCue> cues})?> _restorePersistedSubtitle({
    required String videoPath,
    required String? persisted,
    required bool crossEpisode,
  }) async {
    if (persisted == null || persisted.isEmpty) return null;
    final List<SubtitleSource> sources =
        await listAllSubtitleSources(videoPath, langCode: _targetLangCode);
    if (sources.isEmpty) return null;

    final SubtitleSource? chosen = crossEpisode
        ? pickEpisodeSubtitleSource(persisted, sources)
        : _firstMatching(sources, persisted);
    if (chosen == null) return null;

    final List<AudioCue> cues =
        await loadCuesForSource(chosen, videoPath, widget.bookUid);
    if (cues.isEmpty) return null;
    return (persisted: chosen.toPersistedValue(), cues: cues);
  }

  /// 在 [sources] 中找第一个 [matchesPersisted] 命中的源（精确恢复用）。
  SubtitleSource? _firstMatching(
    List<SubtitleSource> sources,
    String persisted,
  ) {
    for (final SubtitleSource s in sources) {
      if (s.matchesPersisted(persisted)) return s;
    }
    return null;
  }

  /// 载入播放列表第 [index] 集：先按上次选择的「同类偏好」选新集字幕源
  /// （[subtitleSource] 是上次持久化的偏好），无匹配再退默认 sidecar 探测。
  ///
  /// cue 不存 DB——每集 load 时按文件动态解析（播放列表各集字幕是外部文件，本就随
  /// 磁盘存在；存 DB 只会与磁盘真相重复且引入跨集 book_uid 错配）。
  Future<void> _loadEpisode(
    int index, {
    int initialPositionMs = 0,
    String? subtitleSource,
  }) async {
    if (index < 0 || index >= _episodes.length) return;
    final PlaylistEntry episode = _episodes[index];

    List<AudioCue> cues = const <AudioCue>[];
    String? externalSub;

    // ① 按上次偏好（同类）选新集字幕源：内嵌同 streamIndex / 外挂同语言后缀。
    if (subtitleSource != null && subtitleSource.isNotEmpty) {
      final ({String persisted, List<AudioCue> cues})? restored =
          await _restorePersistedSubtitle(
        videoPath: episode.path,
        persisted: subtitleSource,
        crossEpisode: true,
      );
      if (restored != null) {
        cues = restored.cues;
        externalSub = restored.persisted;
      }
    }

    // ② 无偏好 / 无匹配：退默认 sidecar 探测。
    if (cues.isEmpty) {
      final ({String path, List<AudioCue> cues})? sidecar =
          await _detectSidecar(episode.path, widget.bookUid);
      if (sidecar != null) {
        cues = sidecar.cues;
        externalSub = sidecar.path;
      }
    }

    _currentEpisode = index;
    await _applyLoad(
      videoPath: episode.path,
      cues: cues,
      title: episode.title,
      initialPositionMs: initialPositionMs,
      externalSubtitlePath: externalSub,
    );
  }

  /// 探测视频同目录 sidecar 字幕并解析为 cue（无则 null）。
  ///
  /// 按 app 学习语言优先（学日语 → `.ja.srt > .ja.ass > … > .srt > .ass …`，
  /// 见 [findSidecarSubtitle]）；按扩展名路由 [SrtParser] / [AssParser]。IO + 解析
  /// 失败静默返回 null。
  Future<({String path, List<AudioCue> cues})?> _detectSidecar(
    String videoPath,
    String bookUid,
  ) async {
    final String? sidecarPath =
        findSidecarSubtitle(videoPath, langCode: _targetLangCode);
    if (sidecarPath == null) return null;
    try {
      final String text = await readTextWithEncoding(File(sidecarPath));
      final List<AudioCue> cues = sidecarPath.toLowerCase().endsWith('.ass')
          ? AssParser.parseString(content: text, bookKey: bookUid)
          : SrtParser.parseString(content: text, bookKey: bookUid);
      if (cues.isEmpty) return null;
      return (path: sidecarPath, cues: cues);
    } catch (e) {
      debugPrint('[VideoHibikiPage] sidecar parse failed: $e');
      return null;
    }
  }

  /// 共享 load 装配：复用或新建 controller，载入视频 + cue，挂位置持久化回调。
  Future<void> _applyLoad({
    required String videoPath,
    required List<AudioCue> cues,
    required String title,
    required int initialPositionMs,
    String? externalSubtitlePath,
  }) async {
    final VideoPlayerController controller =
        _controller ?? VideoPlayerController();
    // 解析启用的 mpv 着色器为绝对路径（桌面 libmpv 生效，移动端最终静默）。
    final List<String> shaderPaths = await resolveEnabledShaderPaths(
        decodeEnabledShaders(appModel.videoShadersEnabled));
    try {
      await controller.load(
        bookUid: widget.bookUid,
        videoFile: File(videoPath),
        cues: cues,
        initialPositionMs: initialPositionMs,
        initialSpeed: _playbackSpeed,
        externalSubtitlePath: externalSubtitlePath,
        shaderPaths: shaderPaths,
      );
    } catch (e, stack) {
      debugPrint('[VideoHibikiPage] video load failed: $e\n$stack');
      if (_controller == null) controller.dispose();
      if (mounted) setState(() => _failed = true);
      return;
    }
    // 应用持久化的音画延迟（换集复用同一值；load 不重置 delay）。
    controller.setDelayMs(_delayMs);
    controller.onPositionWrite = _persistPosition;
    if (!mounted) {
      if (_controller == null) controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _title = title;
      _failed = false;
      _currentVideoPath = videoPath;
      // 外挂字幕路径即持久化值；内嵌自动加载（externalSubtitlePath==null）时
      // 当前选中由 _currentSubtitleSource 保留（菜单切换时再写）。
      _currentSubtitleSource = externalSubtitlePath ?? _currentSubtitleSource;
    });

    // 首次 load 建观看统计采集器；换片复用同一 controller 实例，已 attach 不重建。
    if (_watchTracker == null) {
      final HibikiDatabase db = appModel.database;
      _watchTracker = VideoWatchTracker(
        title: title,
        bookUid: widget.bookUid,
        // dateKey 由采集器决定（字幕字数=当下日期；观看时长=各桶各自日期），直接透传，
        // 不在此另算「今日」——否则跨午夜的 flush 会与小时日志的日归属不一致。
        addStat: (String t, String dateKey, int chars, int ms) => unawaited(
          db.addVideoWatchStatistic(
            title: t,
            dateKey: dateKey,
            subtitleChars: chars,
            watchTimeMs: ms,
          ),
        ),
        markCompleted: (String uid) =>
            db.markVideoCompleted(uid, DateTime.now()),
        addHourly: (String dateKey, int hour, int deltaMs) =>
            db.addVideoHourlyWatchTime(
                dateKey: dateKey, hour: hour, deltaMs: deltaMs),
      )
        ..attach(controller)
        ..start();
    }

    // 恢复用户选过的音轨（含多集换集复用）：audioTracks 在 player open 后才填充，
    // 延迟一拍再读，按 id 匹配；找不到（轨不存在/未选过）就跳过保留 libmpv 默认。
    unawaited(_restoreAudioTrack(controller));
  }

  /// 位置持久化（controller 每秒至多一次回调）。
  ///
  /// 播放列表：把进度记到**当前集**的 [PlaylistEntry.positionMs] 并回写整段
  /// playlistJson（每集各记自己的进度，换集互不干扰）。单视频：仍走
  /// VideoBook.lastPositionMs 不变。
  Future<void> _persistPosition(String uid, int posMs) async {
    if (_episodes.isEmpty) {
      await widget.repo.updatePosition(uid, posMs);
      return;
    }
    _episodes = updateEntryPosition(_episodes, _currentEpisode, posMs);
    await widget.repo.updatePlaylistJson(uid, _encodeEpisodes());
  }

  /// 把当前 [_episodes] 序列化回 playlistJson（带各集 positionMs）。
  String _encodeEpisodes() => jsonEncode(
        _episodes.map((PlaylistEntry e) => e.toJson()).toList(),
      );

  /// 若有持久化音轨偏好 [_currentAudioTrackId]，在 [controller] 的 audioTracks 里
  /// 按 id 匹配并切换。延迟读取以等待 libmpv open 后填充音轨列表。
  Future<void> _restoreAudioTrack(VideoPlayerController controller) async {
    final String? wantId = _currentAudioTrackId;
    if (wantId == null || wantId.isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted || _controller != controller) return;
    for (final AudioTrack track in controller.audioTracks) {
      if (track.id == wantId) {
        await controller.selectAudioTrack(track);
        return;
      }
    }
  }

  /// 选中某音轨：切轨 + 持久化 id（换集复用）+ SnackBar。
  Future<void> _selectAudioTrack(
    VideoPlayerController controller,
    AudioTrack track,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await controller.selectAudioTrack(track);
    await widget.repo.updateAudioTrackId(widget.bookUid, track.id);
    if (!mounted) return;
    setState(() => _currentAudioTrackId = track.id);
    messenger.showSnackBar(SnackBar(
      content: Text(t.video_audio_track_switched(
        label: _trackLabel(track.title, track.language, track.id),
      )),
    ));
  }

  /// 切到第 [index] 集：保存当前集进度 → 持久化 currentEpisode → 用**目标集自己
  /// 保存的进度**作为起播位置（不再归零）+ 重新 load 新集字幕。
  ///
  /// 当前集进度由 125ms tick 经 [_persistPosition] 已实时记进 `_episodes[当前集]`
  /// 并落库；切集前再补记一次当前播放位置（覆盖 tick 整秒节流的尾差），确保下次
  /// 回到本集精确续播。
  Future<void> _switchEpisode(int index) async {
    if (index < 0 || index >= _episodes.length) return;
    if (index == _currentEpisode) return;

    // 切前补记当前集精确位置（tick 只整秒写，补这一下避免丢尾部几百 ms）。
    final int? curPos = _controller?.positionMs;
    if (curPos != null) {
      _episodes = updateEntryPosition(_episodes, _currentEpisode, curPos);
      await widget.repo.updatePlaylistJson(widget.bookUid, _encodeEpisodes());
    }

    await widget.repo.updateCurrentEpisode(widget.bookUid, index);
    // 换集：清空字幕去重集，新集字幕从头计（完成标记按整本书不变）。
    _watchTracker?.onEpisodeChanged();
    // 把上次选择的字幕偏好带进新集（同类应用：内嵌同轨 / 外挂同语言后缀）。
    await _loadEpisode(
      index,
      initialPositionMs: _episodes[index].positionMs,
      subtitleSource: _currentSubtitleSource,
    );
  }

  void _showEpisodeList() {
    // sheet 关闭后把键盘焦点还给 Video（覆盖层夺焦后不会自动归还）。
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _episodes.length,
            itemBuilder: (BuildContext _, int i) {
              final bool selected = i == _currentEpisode;
              return ListTile(
                selected: selected,
                selectedColor: Theme.of(ctx).colorScheme.primary,
                textColor: Colors.white,
                leading: selected
                    ? const Icon(Icons.play_arrow)
                    : Text('${i + 1}',
                        style: const TextStyle(color: Colors.white70)),
                title: Text(
                  _episodes[i].title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _switchEpisode(i);
                },
              );
            },
          ),
        ),
      ),
    ).whenComplete(_refocusVideo);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _popupStack.clear();
    final OverlayEntry? entry = _popupOverlayEntry;
    if (entry != null) {
      // remove() asserts if already detached（路由先 pop 时根 Overlay 可能已摘除）。
      if (entry.mounted) entry.remove();
      entry.dispose();
      _popupOverlayEntry = null;
    }
    _watchTracker?.dispose();
    _watchTracker = null;
    _controller?.dispose();
    _videoFocusNode.dispose();
    super.dispose();
  }

  /// 把键盘焦点还给 media_kit [Video]，恢复其内置快捷键（空格=播放/暂停等）。
  ///
  /// 在任何会盖在视频上 / 夺走窗口焦点的覆盖层（对话框、bottom sheet、系统文件选择器）
  /// 关闭后调用——这些覆盖层关闭后 Flutter 不会自动把焦点还给 [Video] 的 FocusNode，
  /// 导致空格等快捷键失灵（BUG：导入着色器后空格失灵）。统一在覆盖层的 `await` 返回点
  /// 调用即覆盖全部入口。查词浮层（[_popupStack]）**不**在此 refocus：浮层活动期间用户在
  /// 查词，不应让空格控制视频；浮层关闭由其自身路径处理。
  void _refocusVideo() {
    if (!mounted) return;
    // 仅当播放器已就绪（Video 已挂载）才请求焦点；否则节点未 attach，requestFocus 无意义。
    if (_controller == null) return;
    _videoFocusNode.requestFocus();
  }

  /// 点字幕第 [graphemeIndex] 个字符：暂停 → 从该位置起取词 → 推入与阅读器/词典页
  /// 同款的 [DictionaryPopupLayer] 浮层（定位到被点字符的屏幕 [charRect] 附近）。
  ///
  /// [charRect] 来自字符 box 的 `localToGlobal`，是 [HibikiAppUiScale] 缩放后的**真实
  /// 屏幕坐标**。浮层子树经 [_buildPopupOverlay] 的 [HibikiAppUiScaleNeutralizer] 中和回
  /// 真实视口空间（净变换=1），其坐标系即真实屏幕空间，故这里**直接**用 [charRect] 定位、
  /// 不再换算到缩放画布——界面任意缩放下定位都不偏（BUG-051）。
  ///
  /// 查词/递归查词/单词发音/auto-read/制卡全部走 [DictionaryPageMixin]，与书内一致。
  Future<void> _lookupAt(
    String sentence,
    int graphemeIndex,
    Rect charRect,
  ) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final String term = sentence.characters.skip(graphemeIndex).join();
    debugPrint('[video-lookup] tap idx=$graphemeIndex term="$term"');
    // 先判空再暂停：空词不弹浮层，不能暂停后无浮层可关→恢复路径永不触发（卡暂停）。
    if (term.isEmpty) return;
    // 仅当视频正在播放才暂停并标记，浮层全关后据此恢复（BUG-072）。查词前本就
    // 暂停 / 递归查词（已暂停）时 isPlaying==false，不暂停也不覆写标记。
    if (controller.isPlaying) {
      await controller.pause();
      _pausedForLookup = true;
    }
    _lastLookupSentence = sentence;
    await pushNestedPopup(
      query: term,
      selectionRect: charRect,
      popupStack: _popupStack,
      replaceStack: true,
      autoRead: true,
    );
  }

  /// 关闭查词浮层栈中第 [index] 层及其之上（点遮罩 / 返回 / 浮层滑动·Esc 都汇聚到此）。
  ///
  /// 关栈后若整栈已空且本次是因查词暂停了播放，则恢复播放——这是恢复播放的唯一汇聚点，
  /// 覆盖所有关闭路径（BUG-072）。
  void _popNestedPopupAt(int index) {
    popNestedPopupAt(index, _popupStack);
    if (VideoHibikiPage.shouldResumeAfterLookupDismiss(
      stackEmpty: _popupStack.isEmpty,
      pausedForLookup: _pausedForLookup,
    )) {
      _pausedForLookup = false;
      unawaited(_controller?.play());
    }
  }

  Widget _buildNestedPopupLayer(int index, Size screen) {
    return buildNestedPopupLayer(
      index: index,
      screen: screen,
      popupStack: _popupStack,
      onPush: (String text, Rect rect) {
        // 递归查词不属于某条字幕句：制卡例句仍用最近一次字幕句。
        // [rect] 已是中和后浮层坐标（父浮层 pos + WebView 局部 rect 叠出，均在同一
        // 真实视口空间），直接复用，无需任何缩放换算。
        pushNestedPopup(
          query: text,
          selectionRect: rect,
          popupStack: _popupStack,
          autoRead: true,
        );
      },
      onPop: _popNestedPopupAt,
    );
  }

  /// 把查词浮层栈同步到根 Overlay：栈非空且未插入则插入、栈空则移除、否则
  /// `markNeedsBuild` 刷新。在 [build] 的 post-frame 调，使根 Overlay 总是反映
  /// 当前栈（[DictionaryPageMixin] 的 push/pop 都走 `setState` → 重 build → 本同步）。
  ///
  /// 用根 Overlay（而非本页 `Stack`）的原因：media_kit 全屏是推到根 navigator 的独立
  /// 路由，本页 `Stack` 会被全屏路由盖住；根 Overlay 浮在所有路由之上，窗口/全屏统一。
  void _syncPopupOverlay() {
    if (!mounted) return;
    if (_popupStack.isEmpty) {
      final OverlayEntry? entry = _popupOverlayEntry;
      if (entry != null) {
        if (entry.mounted) entry.remove();
        entry.dispose();
        _popupOverlayEntry = null;
      }
      return;
    }
    if (_popupOverlayEntry != null) {
      _popupOverlayEntry!.markNeedsBuild();
      return;
    }
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(builder: _buildPopupOverlay);
    _popupOverlayEntry = entry;
    overlay.insert(entry);
  }

  /// 根 Overlay 里的查词浮层栈内容：透明遮罩（点击关栈）+ 各层 [DictionaryPopupLayer]。
  ///
  /// 根 Overlay 在 [HibikiAppUiScale] 的 `FittedBox` 之内＝缩放后的小画布，浮层 WebView
  /// 在此栅格化再被拉大会字糊（BUG-051）。用 [HibikiAppUiScaleNeutralizer] 把整棵浮层
  /// 子树中和回真实视口尺寸、净缩放=1，WebView 按原生密度渲染＝清晰。中和后 `screen`
  /// （内层 [LayoutBuilder] 约束）即真实视口，与 [_lookupAt] 直接传入的 `localToGlobal`
  /// 屏幕 rect 同坐标系（净变换=1），定位自洽。
  Widget _buildPopupOverlay(BuildContext overlayContext) {
    return HibikiAppUiScaleNeutralizer(
      child: Theme(
        data: appModel.overrideDictionaryTheme ?? Theme.of(context),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Size screen =
                Size(constraints.maxWidth, constraints.maxHeight);
            return Stack(
              children: <Widget>[
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => _popNestedPopupAt(0),
                    child: const ColoredBox(color: Colors.transparent),
                  ),
                ),
                for (int i = 0; i < _popupStack.length; i++)
                  _buildNestedPopupLayer(i, screen),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 制卡（覆写 [DictionaryPageMixin.onMineEntry]）：在词典 [fields]（已含单词
  /// 发音 `{audio}`、例句字段等）基础上，注入视频专属上下文——当前帧截图
  /// coverPath（→`{book-cover}`）+ 当前字幕 cue 的音频片段（裁**当前选中音轨**）
  /// sasayakiAudioPath（→`{sasayaki-audio}`）+ 例句 sentence。复用现有 Anki 字段。
  @override
  Future<bool> onMineEntry(Map<String, String> fields) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return false;
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final Directory tmp = await getTemporaryDirectory();

    // 视频截图（当前帧）→ coverPath。
    String? coverPath;
    final Uint8List? shot = await controller.screenshot();
    if (shot != null && shot.isNotEmpty) {
      final File f = File('${tmp.path}/video_mine_shot.jpg');
      await f.writeAsBytes(shot);
      coverPath = f.path;
    }

    // 当前字幕 cue 的音频片段（桌面 ffmpeg 按时间裁，映射到当前选中音轨）
    // → sasayakiAudioPath。
    String? audioPath;
    final AudioCue? cue = controller.currentCue;
    final String? videoPath = controller.videoPath;
    if (cue != null && videoPath != null) {
      audioPath = await extractAudioSegmentViaFfmpeg(
        inputPath: videoPath,
        startMs: cue.startMs,
        endMs: cue.endMs,
        outputPath: '${tmp.path}/video_mine_audio.aac',
        audioStreamIndex: controller.currentAudioStreamIndex,
      );
    }

    final AnkiMiningContext miningContext = AnkiMiningContext(
      sentence: _lastLookupSentence,
      cueSentence: cue?.text,
      documentTitle: _title,
      coverPath: coverPath,
      sasayakiAudioPath: audioPath,
    );
    final MineResult result = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );
    if (!context.mounted) return result == MineResult.success;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String message;
    switch (result) {
      case MineResult.success:
        final AnkiSettings settings = await repo.loadSettings();
        message = t.card_exported(deck: settings.selectedDeckName ?? '');
      case MineResult.duplicate:
        message = t.card_duplicate;
      case MineResult.notConfigured:
        message = t.card_export_not_configured;
      case MineResult.error:
        message = t.card_export_failed;
    }
    if (mounted) messenger.showSnackBar(SnackBar(content: Text(message)));
    return result == MineResult.success;
  }

  /// media_kit 桌面控制主题：底部默认控制条（播放/进度/音量/全屏）+ 顶栏
  /// 加字幕轨、音轨切换按钮（点击弹 track 列表，调 libmpv 切轨）。
  MaterialDesktopVideoControlsThemeData _desktopControlsTheme(
    VideoPlayerController controller,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return MaterialDesktopVideoControlsThemeData(
      seekBarPositionColor: cs.primary,
      seekBarThumbColor: cs.primary,
      buttonBarButtonColor: cs.onSurface,
      topButtonBar: <Widget>[
        const Spacer(),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.subtitles),
          onPressed: () => _showSubtitleSourceMenu(controller),
        ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.audiotrack),
          onPressed: () => _showTrackMenu(
            controller.audioTracks
                .map((AudioTrack tr) => (
                      label: _trackLabel(tr.title, tr.language, tr.id),
                      onSelected: () => _selectAudioTrack(controller, tr),
                    ))
                .toList(),
          ),
        ),
      ],
    );
  }

  /// media_kit 移动控制主题（Android/iOS）：[AdaptiveVideoControls] 在移动端渲染
  /// [MaterialVideoControls]（读本主题），桌面端渲染 [MaterialDesktopVideoControls]
  /// （读 [MaterialDesktopVideoControlsTheme]），两套互斥，故两层主题都配置安全。
  ///
  /// 移动端全屏走 media_kit 独立 root 路由、丢掉 Scaffold AppBar，故把字幕、音轨、
  /// 设置（playlist 时再加剧集）入口全放进 [topButtonBar]，保证普通与全屏都可达。
  MaterialVideoControlsThemeData _mobileControlsTheme(
    VideoPlayerController controller,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return MaterialVideoControlsThemeData(
      seekBarPositionColor: cs.primary,
      seekBarThumbColor: cs.primary,
      buttonBarButtonColor: Colors.white,
      topButtonBar: <Widget>[
        const Spacer(),
        if (_isPlaylist)
          MaterialCustomButton(
            icon: const Icon(Icons.playlist_play),
            onPressed: _showEpisodeList,
          ),
        MaterialCustomButton(
          icon: const Icon(Icons.subtitles),
          onPressed: () => _showSubtitleSourceMenu(controller),
        ),
        MaterialCustomButton(
          icon: const Icon(Icons.audiotrack),
          onPressed: () => _showTrackMenu(
            controller.audioTracks
                .map((AudioTrack tr) => (
                      label: _trackLabel(tr.title, tr.language, tr.id),
                      onSelected: () => _selectAudioTrack(controller, tr),
                    ))
                .toList(),
          ),
        ),
        MaterialCustomButton(
          icon: const Icon(Icons.tune),
          onPressed: _showPlayerSettings,
        ),
      ],
    );
  }

  void _showTrackMenu(
    List<({String label, VoidCallback onSelected})> tracks,
  ) {
    // sheet 关闭后把键盘焦点还给 Video（覆盖层夺焦后不会自动归还）。
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      builder: (BuildContext ctx) => ListView(
        shrinkWrap: true,
        children: tracks
            .map((({String label, VoidCallback onSelected}) o) => ListTile(
                  textColor: Colors.white,
                  title: Text(o.label),
                  onTap: () {
                    o.onSelected();
                    Navigator.pop(ctx);
                  },
                ))
            .toList(),
      ),
    ).whenComplete(_refocusVideo);
  }

  /// 设置音画延迟（毫秒）：即时调 controller（字幕 cue 同步偏移立即生效）+ 持久化
  /// 到 VideoBook.delayMs（换集复用、跨重启保留）+ 刷新面板显示。
  Future<void> _setDelayMs(int delayMs) async {
    final int clamped = delayMs.clamp(-600000, 600000);
    if (clamped == _delayMs) return;
    _delayMs = clamped;
    _controller?.setDelayMs(clamped);
    await widget.repo.updateDelayMs(widget.bookUid, clamped);
    if (mounted) setState(() {});
  }

  /// 设置播放倍速：即时调 controller + 持久化到 per-book 偏好（速度记忆）+ 刷新。
  Future<void> _setSpeed(double speed) async {
    final double clamped = speed.clamp(0.25, 4.0).toDouble();
    if ((clamped - _playbackSpeed).abs() < 0.001) return;
    _playbackSpeed = clamped;
    await _controller?.setSpeed(clamped);
    await appModel.prefsRepo.setPref(_speedPrefKey, clamped);
    if (mounted) setState(() {});
  }

  /// 弹视频播放设置面板：音画延迟（±50/±1000ms 步进 + 归零）+ 播放倍速（预设档）。
  ///
  /// 参照有声书 [AudiobookPlayBar] 的 A/V Sync 步进设计；面板用 [StatefulBuilder]
  /// 局部刷新，调用方法即时生效 + 持久化（见 [_setDelayMs] / [_setSpeed]）。
  void _showPlayerSettings() {
    const List<double> speedPresets = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    // sheet 关闭后把键盘焦点还给 Video，恢复空格快捷键（覆盖层夺焦后不会自动归还）。
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        final ColorScheme cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: StatefulBuilder(
            builder: (BuildContext ctx, StateSetter setSheet) {
              Future<void> bumpDelay(int delta) async {
                await _setDelayMs(_delayMs + delta);
                setSheet(() {});
              }

              Future<void> pickSpeed(double s) async {
                await _setSpeed(s);
                setSheet(() {});
              }

              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      t.video_settings_title,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 16),
                    // ── 音画延迟 ──
                    Text(t.video_setting_av_delay,
                        style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 4),
                    Text(t.video_setting_av_delay_hint,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12)),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        IconButton(
                          color: Colors.white,
                          icon: const Icon(Icons.keyboard_double_arrow_left),
                          tooltip: '-1000ms',
                          onPressed: () => bumpDelay(-1000),
                        ),
                        IconButton(
                          color: Colors.white,
                          icon: const Icon(Icons.chevron_left),
                          tooltip: '-50ms',
                          onPressed: () => bumpDelay(-50),
                        ),
                        GestureDetector(
                          onTap: _delayMs == 0
                              ? null
                              : () async {
                                  await _setDelayMs(0);
                                  setSheet(() {});
                                },
                          child: SizedBox(
                            width: 96,
                            child: Text(
                              '${_delayMs >= 0 ? '+' : ''}$_delayMs ms',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color:
                                    _delayMs == 0 ? Colors.white54 : cs.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          color: Colors.white,
                          icon: const Icon(Icons.chevron_right),
                          tooltip: '+50ms',
                          onPressed: () => bumpDelay(50),
                        ),
                        IconButton(
                          color: Colors.white,
                          icon: const Icon(Icons.keyboard_double_arrow_right),
                          tooltip: '+1000ms',
                          onPressed: () => bumpDelay(1000),
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white24, height: 24),
                    // ── 播放倍速 ──
                    Text(t.video_setting_speed,
                        style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: <Widget>[
                        for (final double s in speedPresets)
                          ChoiceChip(
                            label: Text('${s}x'),
                            selected: (s - _playbackSpeed).abs() < 0.001,
                            onSelected: (_) => pickSpeed(s),
                          ),
                      ],
                    ),
                    const Divider(color: Colors.white24, height: 24),
                    // ── mpv 着色器（Anime4K 等；桌面 libmpv 生效）──
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white24),
                        ),
                        icon: const Icon(Icons.auto_fix_high_outlined),
                        label: Text(t.video_setting_shaders),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _openShaderDialog();
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    ).whenComplete(_refocusVideo);
  }

  /// 打开 mpv 着色器对话框：导入/勾选着色器 → 持久化启用集 → 解析绝对路径 →
  /// 实时应用到当前播放器（仅桌面 libmpv 生效，移动端静默）。
  Future<void> _openShaderDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => VideoShaderDialog(
        initialEnabled: decodeEnabledShaders(appModel.videoShadersEnabled),
        onApply: (List<String> enabledNames) async {
          await appModel
              .setVideoShadersEnabled(encodeEnabledShaders(enabledNames));
          final List<String> paths =
              await resolveEnabledShaderPaths(enabledNames);
          await _controller?.applyShaders(paths);
        },
      ),
    );
    // 着色器对话框内含 FilePicker（导入）/ Anime4K 下载，会夺走窗口键盘焦点；
    // 对话框关闭后把焦点还给 Video，恢复空格快捷键（BUG：导入着色器后空格失灵）。
    _refocusVideo();
  }

  /// 弹「字幕源」菜单：枚举当前视频的全部字幕源（内嵌轨 + 同目录外挂文件）+
  /// 顶部「关闭字幕」项。选某源 → 解析成 cue → 切 overlay + 持久化 + SnackBar。
  ///
  /// 这是运行时覆盖；默认 load 行为（自动 sidecar 优先 + 内嵌兜底）不变。
  Future<void> _showSubtitleSourceMenu(
    VideoPlayerController controller,
  ) async {
    final String? videoPath = _currentVideoPath;
    if (videoPath == null) return;

    final List<SubtitleSource> sources =
        await listAllSubtitleSources(videoPath, langCode: _targetLangCode);
    if (!context.mounted) return;

    // sheet 关闭后把键盘焦点还给 Video（覆盖层夺焦后不会自动归还）。
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              // 自动获取字幕（Jimaku）：用番名搜 → 下载 → 应用为外挂源。
              ListTile(
                textColor: Colors.white,
                leading: const Icon(Icons.cloud_download_outlined,
                    color: Colors.white),
                title: Text(t.video_jimaku_fetch),
                onTap: () {
                  Navigator.pop(ctx);
                  _openJimakuDialog(controller);
                },
              ),
              // 从本地文件导入字幕：FilePicker 选 srt/ass/ssa/vtt → 拷到持久目录 →
              // 复用 _selectSubtitleSource 应用（解决 sidecar 名对不上 / 字幕在别目录）。
              ListTile(
                textColor: Colors.white,
                leading:
                    const Icon(Icons.file_open_outlined, color: Colors.white),
                title: Text(t.video_subtitle_import_file),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndImportSubtitle(controller);
                },
              ),
              const Divider(color: Colors.white24, height: 1),
              ListTile(
                textColor: Colors.white,
                leading: const Icon(Icons.subtitles_off, color: Colors.white),
                title: Text(t.video_subtitle_off),
                selected: _currentSubtitleSource == null,
                selectedColor: Theme.of(ctx).colorScheme.primary,
                onTap: () {
                  Navigator.pop(ctx);
                  _selectSubtitleOff(controller);
                },
              ),
              for (final SubtitleSource source in sources)
                ListTile(
                  textColor: Colors.white,
                  leading: Icon(
                    source.isEmbedded ? Icons.movie : Icons.subtitles,
                    color: Colors.white,
                  ),
                  title: Text(source.label),
                  selected: source.matchesPersisted(_currentSubtitleSource),
                  selectedColor: Theme.of(ctx).colorScheme.primary,
                  onTap: () {
                    Navigator.pop(ctx);
                    _selectSubtitleSource(controller, source);
                  },
                ),
            ],
          ),
        ),
      ),
    ).whenComplete(_refocusVideo);
  }

  /// 打开「自动获取字幕（Jimaku）」对话框：用番名（文件名解析）搜 → 下载到
  /// `<appDocs>/video_subtitles/` → 构造外挂 [SubtitleSource] 复用既有 cue 加载/切换/
  /// 持久化链路应用。真实拉取需有效 Jimaku API key + 联网（验证待用户）。
  Future<void> _openJimakuDialog(VideoPlayerController controller) async {
    final String? videoPath = _currentVideoPath;
    if (videoPath == null) return;
    final Directory docs = await getApplicationDocumentsDirectory();
    final String saveDir = p.join(docs.path, 'video_subtitles');
    final String query = parseVideoFilename(p.basename(videoPath)).series;
    if (!context.mounted) return;
    final String? downloaded = await showDialog<String>(
      context: context,
      builder: (_) => JimakuSubtitleDialog(
        initialQuery: query,
        initialApiKey: appModel.jimakuApiKey,
        onApiKeyChanged: (String key) => appModel.setJimakuApiKey(key),
        saveDirectory: saveDir,
      ),
    );
    // Jimaku 对话框内含联网搜索/下载，会夺焦；关闭后把焦点还给 Video。
    _refocusVideo();
    if (downloaded == null || !context.mounted) return;
    final SubtitleSource source = SubtitleSource.external(
      externalPath: downloaded,
      label: p.basename(downloaded),
    );
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool applied = await _selectSubtitleSource(controller, source);
    // 仅在字幕真被应用（解析出 cue）时报「已下载并应用」；cue 为空时
    // _selectSubtitleSource 已弹失败提示，不再叠加误导性的成功提示。
    if (applied && mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.video_jimaku_downloaded)),
      );
    }
  }

  /// 弹系统文件选择器挑一个字幕文件（srt/ass/ssa/vtt）→ 经 [_importExternalSubtitle]
  /// 落盘并应用。FilePicker 会夺走视频键盘焦点，关闭后 [_refocusVideo] 归还。
  Future<void> _pickAndImportSubtitle(VideoPlayerController controller) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa'],
      allowMultiple: false,
    );
    _refocusVideo();
    final String? path = result?.files.single.path;
    if (path == null) return;
    await _importExternalSubtitle(controller, path);
  }

  /// 把用户挑选/拖入的外部字幕文件 [srcPath] 拷到持久化
  /// `<appDocs>/video_subtitles/`（与 Jimaku 下载同目录），构造外挂
  /// [SubtitleSource] 后经 [_selectSubtitleSource] 应用（复用 cue 解析/切换/
  /// 持久化/失败提示全链路）。
  ///
  /// 拷贝到持久目录而非直接用原路径：原文件可能在临时/缓存区或后续被移动，落盘后
  /// 持久化的 `subtitleSource` 路径才稳定可恢复。格式不支持或拷贝失败时弹提示、
  /// 不切换。源路径已在持久目录内时跳过自拷贝（File.copy 自拷会报错）。
  ///
  /// 落点是 `video_subtitles/<basename>`：同 basename 直接覆盖，是「当前集导入
  /// 覆盖」语义，有意不做去重——避免堆积同名副本，且换集恢复按文件名匹配，去重
  /// 后缀反而干扰匹配。
  Future<void> _importExternalSubtitle(
    VideoPlayerController controller,
    String srcPath,
  ) async {
    if (_currentVideoPath == null) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    if (subtitleFormatForPath(srcPath) == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.video_subtitle_import_unsupported)),
      );
      return;
    }
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory destDir = Directory(p.join(docs.path, 'video_subtitles'));
    await destDir.create(recursive: true);
    final String dest = p.join(destDir.path, p.basename(srcPath));
    if (!p.equals(srcPath, dest)) {
      try {
        await File(srcPath).copy(dest);
      } catch (_) {
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(content: Text(t.video_subtitle_import_failed)),
        );
        return;
      }
    }
    if (!mounted) return;
    final SubtitleSource source = SubtitleSource.external(
      externalPath: dest,
      label: p.basename(dest),
    );
    await _selectSubtitleSource(controller, source);
  }

  /// 选中某字幕源：加载 cue → 切 overlay → 持久化 → SnackBar。
  /// 返回 true 表示字幕真被应用（解析出 cue 并切换/持久化）；false 表示空 cue
  /// 失败（已弹失败提示、未切换、未持久化、未覆盖当前可用字幕）。
  Future<bool> _selectSubtitleSource(
    VideoPlayerController controller,
    SubtitleSource source,
  ) async {
    final String? videoPath = _currentVideoPath;
    if (videoPath == null) return false;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    final List<AudioCue> cues =
        await loadCuesForSource(source, videoPath, widget.bookUid);
    if (!mounted) return false;
    // 抽取/解析后无任何 cue（图形字幕、ffmpeg 缺失、轨损坏等）：诚实告知失败，
    // **不切换、不持久化**——避免谎报「已切换」却空屏，也避免用一个坏内封轨覆盖掉
    // 当前正常工作的字幕源（下次进来还是空）。
    if (cues.isEmpty) {
      messenger.showSnackBar(SnackBar(
        content: Text(t.video_subtitle_load_failed(label: source.label)),
      ));
      return false;
    }
    controller.setCues(cues);
    // BUG-081: 单视频把解析出的 cue 落库，重进时 `_loadSingle` 的 `loadCues`
    // 直接命中，无需用户再手动加载。播放列表各集有意不存 DB（每集外部文件按
    // 磁盘动态解析，避免跨集 bookUid 错配，见 `_loadEpisode` 注释），故仅在
    // 无播放列表（`_episodes.isEmpty`）时持久化。
    if (_episodes.isEmpty) {
      await widget.repo.saveCues(bookUid: widget.bookUid, cues: cues);
    }
    // 选了文本字幕源就关掉 libmpv 画面字幕，避免与可点 overlay 双重渲染。
    await controller.selectSubtitleTrack(SubtitleTrack.no());

    final String persisted = source.toPersistedValue();
    await widget.repo.updateSubtitleSource(widget.bookUid, persisted);
    if (!mounted) return false;
    setState(() => _currentSubtitleSource = persisted);
    messenger.showSnackBar(SnackBar(
      content: Text(t.video_subtitle_switched(label: source.label)),
    ));
    return true;
  }

  /// 关闭字幕：清空 cue overlay + 关 libmpv 字幕轨 + 持久化 null。
  Future<void> _selectSubtitleOff(VideoPlayerController controller) async {
    controller.setCues(const <AudioCue>[]);
    // BUG-081: 关字幕也要清掉单视频已落库的 cue，否则重进时 `loadCues` 命中旧
    // cue 又把字幕显示回来。播放列表不入 DB，无需清。
    if (_episodes.isEmpty) {
      await widget.repo
          .saveCues(bookUid: widget.bookUid, cues: const <AudioCue>[]);
    }
    await controller.selectSubtitleTrack(SubtitleTrack.no());
    await widget.repo.updateSubtitleSource(widget.bookUid, null);
    if (!mounted) return;
    setState(() => _currentSubtitleSource = null);
  }

  String _trackLabel(String? title, String? language, String id) {
    if ((title ?? '').isNotEmpty) return title!;
    if ((language ?? '').isNotEmpty) return language!;
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? controller = _controller;
    final VideoController? videoController = controller?.videoController;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return PopScope(
      // 始终 `canPop: false` 自管退出：① 浮层栈非空时 back 先关栈（一层一层退），
      // 浮层在根 Overlay 退出视频路由不会自动清它，必须在 pop 前拦截；② 栈空真退出
      // 时，**先 await `flushPosition()` 把退出瞬间位置可靠落库再手动 pop**——否则只剩
      // controller.dispose() 里 fire-and-forget 的 `_forceSavePositionSync()`，drift
      // 写库 Future 与 Navigator 同步销毁 State 竞争、常写不完，导致「退出再进没回到
      // 上次位置」（对齐阅读器 `onWillPop` 先 await 落库再 pop 的做法）。
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) async {
        if (didPop) return;
        if (_popupStack.isNotEmpty) {
          _popNestedPopupAt(_popupStack.length - 1);
          return;
        }
        final NavigatorState nav = Navigator.of(context);
        await _controller?.flushPosition();
        if (mounted) nav.pop();
      },
      child: _buildScaffold(controller, videoController, cs),
    );
  }

  Widget _buildScaffold(
    VideoPlayerController? controller,
    VideoController? videoController,
    ColorScheme cs,
  ) {
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(_title ?? ''),
        actions: <Widget>[
          if (_isPlaylist) ...<Widget>[
            IconButton(
              tooltip: t.video_prev_episode,
              icon: const Icon(Icons.skip_previous),
              onPressed: _currentEpisode > 0
                  ? () => _switchEpisode(_currentEpisode - 1)
                  : null,
            ),
            IconButton(
              tooltip: t.video_next_episode,
              icon: const Icon(Icons.skip_next),
              onPressed: _currentEpisode < _episodes.length - 1
                  ? () => _switchEpisode(_currentEpisode + 1)
                  : null,
            ),
            IconButton(
              tooltip: t.video_episode_list,
              icon: const Icon(Icons.playlist_play),
              onPressed: _showEpisodeList,
            ),
          ],
          IconButton(
            tooltip: t.video_settings_title,
            icon: const Icon(Icons.tune),
            // controller 未就绪时禁用（无可调对象）。
            onPressed: controller == null ? null : _showPlayerSettings,
          ),
        ],
      ),
      body: _failed
          ? Center(
              child: Icon(Icons.error_outline, color: cs.error, size: 48),
            )
          : (controller == null || videoController == null)
              ? const Center(child: CircularProgressIndicator())
              : _buildVideoBody(controller, videoController),
    );
  }

  /// 视频本体：media_kit [Video] + 可点字幕 overlay。查词浮层栈不在这里渲染——它走
  /// 根 Overlay（[_syncPopupOverlay] / [_buildPopupOverlay]），以便全屏时浮在全屏
  /// 路由之上。每次 build 在 post-frame 同步根 Overlay 与当前栈。
  Widget _buildVideoBody(
    VideoPlayerController controller,
    VideoController videoController,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPopupOverlay());
    // 两层主题嵌套：[AdaptiveVideoControls] 按平台互斥择一渲染（桌面读 Desktop
    // 主题、移动读 Material 主题），故同时提供两套互不干扰，让字幕/音轨/设置入口
    // 在桌面、移动、全屏三种场景都可达。嵌套顺序不影响——各自被对应平台 controls 读取。
    return MaterialVideoControlsTheme(
      normal: _mobileControlsTheme(controller),
      fullscreen: _mobileControlsTheme(controller),
      child: MaterialDesktopVideoControlsTheme(
        normal: _desktopControlsTheme(controller),
        fullscreen: _desktopControlsTheme(controller),
        child: Video(
          controller: videoController,
          // 用本页持有的 FocusNode 替换 Video 内置的匿名节点，以便覆盖层（对话框 /
          // bottom sheet / 文件选择器）关闭后能主动把键盘焦点还给它，恢复空格等内置
          // 快捷键（见 [_refocusVideo]）。
          focusNode: _videoFocusNode,
          // 视频不满屏时的 letterbox/pillarbox 填充色吃主题 surface（默认黑边换成
          // 跟随主题的中性底色，与 Scaffold 背景一致，深浅主题统一）。
          fill: Theme.of(context).colorScheme.surface,
          // 字幕 overlay + 拖拽挂载都包进 controls builder：media_kit 全屏推独立 root
          // 路由并复用同一 controls，故 overlay 随全屏一起进路由，全屏时字幕仍显示且
          // 可点查词、拖字幕也能挂载（见 [_buildVideoControls]）。
          controls: (VideoState state) =>
              _buildVideoControls(state, controller),
        ),
      ),
    );
  }

  /// media_kit `controls` builder：默认桌面控制条 + 可点字幕 [VideoSubtitleOverlay]
  /// 叠加。返回的 widget 同时用于普通与全屏路由（media_kit 复用同一 builder），
  /// 故全屏时字幕一并显示。
  Widget _buildVideoControls(
    VideoState state,
    VideoPlayerController controller,
  ) {
    // 拖字幕文件到正在播放的视频上 → 即时挂载（asbplayer 式）。包在 controls
    // overlay 层（而非 [_buildVideoBody] 外层）：media_kit 全屏推独立 root 路由、
    // 复用同一 controls builder，故拖拽目标随全屏一起进路由——窗口与全屏两种场景
    // 用同一个目标都能挂载（覆盖 overlay 即视频可视区）。仅桌面三端启用
    // （[HibikiFileDropTarget] 内部门控），其余平台透传 child 零开销。只取第一个
    // 受支持字幕；拖入纯视频/图片等忽略。desktop_drop 只接管 OS 文件拖放、不吃
    // Flutter 指针事件，故内层字幕点击查词（onCharTap）不受影响；不夺焦故无需
    // _refocusVideo。
    return HibikiFileDropTarget(
      onDrop: (List<String> paths, Offset _) {
        final String? sub = firstSubtitlePath(paths);
        if (sub == null) return;
        unawaited(_importExternalSubtitle(controller, sub));
      },
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: AdaptiveVideoControls(state)),
          Positioned.fill(
            child: VideoSubtitleOverlay(
              controller: controller,
              onCharTap: _lookupAt,
            ),
          ),
        ],
      ),
    );
  }
}
