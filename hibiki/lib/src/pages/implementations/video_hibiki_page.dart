import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_sidecar.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_native.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';

/// 视频页：media_kit 播放器 + 可点击字幕 overlay（点词查词 + 制卡）。
///
/// 装配：[VideoPlayerController.load] 打开视频 + cue 同步 → [Stack] 叠
/// [Video]（media_kit 桌面控制：播放/进度/音量/全屏 + 顶栏字幕轨/音轨切换）
/// 与 [VideoSubtitleOverlay]（逐字符可点）。点字幕字符 → [_lookupAt] 取词查词
/// → [DictionaryPopupNative] 弹窗 → [_mine] 制卡（截图 coverPath + 字幕音频
/// sasayakiAudioPath + 例句 sentence，复用现有 Anki 字段，不改 hibiki_anki）。
class VideoHibikiPage extends ConsumerStatefulWidget {
  const VideoHibikiPage({
    required this.bookUid,
    required this.repo,
    super.key,
  });

  final String bookUid;
  final VideoBookRepository repo;

  @override
  ConsumerState<VideoHibikiPage> createState() => _VideoHibikiPageState();
}

class _VideoHibikiPageState extends ConsumerState<VideoHibikiPage> {
  VideoPlayerController? _controller;
  bool _failed = false;
  String? _title;

  /// 多集播放列表（单视频导入时为空）。
  List<PlaylistEntry> _episodes = const <PlaylistEntry>[];

  /// 当前集索引（[_episodes] 下标）；单视频恒 0。
  int _currentEpisode = 0;

  bool get _isPlaylist => _episodes.length > 1;

  AppModel get appModel => ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final VideoBookRow? row = await widget.repo.getByBookUid(widget.bookUid);
    if (row == null) {
      if (mounted) setState(() => _failed = true);
      return;
    }

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
      await _loadEpisode(
        idx,
        initialPositionMs: row.lastPositionMs,
        subtitleSource: row.subtitleSource,
      );
      return;
    }

    // 单视频路径（无播放列表）。
    await _loadSingle(row);
  }

  /// 载入单视频（无播放列表）：优先用 DB 已存 cue；无则探测 sidecar 字幕。
  Future<void> _loadSingle(VideoBookRow row) async {
    List<AudioCue> cues = await widget.repo.loadCues(widget.bookUid);
    String? externalSub = row.subtitleSource;
    if (cues.isEmpty && externalSub == null) {
      final ({String path, List<AudioCue> cues})? sidecar =
          await _detectSidecar(row.videoPath, widget.bookUid);
      if (sidecar != null) {
        cues = sidecar.cues;
        externalSub = sidecar.path;
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

  /// 载入播放列表第 [index] 集：用该集 videoPath + 自动探测的 sidecar 字幕。
  ///
  /// cue 不存 DB——每集 load 时按 sidecar 文件动态解析（播放列表各集字幕是外部
  /// 文件，本就随磁盘存在；存 DB 只会与磁盘真相重复且引入跨集 book_uid 错配）。
  Future<void> _loadEpisode(
    int index, {
    int initialPositionMs = 0,
    String? subtitleSource,
  }) async {
    if (index < 0 || index >= _episodes.length) return;
    final PlaylistEntry episode = _episodes[index];

    List<AudioCue> cues = const <AudioCue>[];
    String? externalSub = subtitleSource;
    final ({String path, List<AudioCue> cues})? sidecar =
        await _detectSidecar(episode.path, widget.bookUid);
    if (sidecar != null) {
      cues = sidecar.cues;
      externalSub = sidecar.path;
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
  /// 优先级 `.ja.srt > .ja.ass > .srt > .ass`（见 [findSidecarSubtitle]）；按
  /// 扩展名路由 [SrtParser] / [AssParser]。IO + 解析失败静默返回 null。
  Future<({String path, List<AudioCue> cues})?> _detectSidecar(
    String videoPath,
    String bookUid,
  ) async {
    final String? sidecarPath = findSidecarSubtitle(videoPath);
    if (sidecarPath == null) return null;
    try {
      final String text = await readTextWithEncoding(File(sidecarPath));
      final List<AudioCue> cues = sidecarPath.toLowerCase().endsWith('.ass')
          ? AssParser.parseString(content: text, bookUid: bookUid)
          : SrtParser.parseString(content: text, bookUid: bookUid);
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
    try {
      await controller.load(
        bookUid: widget.bookUid,
        videoFile: File(videoPath),
        cues: cues,
        initialPositionMs: initialPositionMs,
        externalSubtitlePath: externalSubtitlePath,
      );
    } catch (e, stack) {
      debugPrint('[VideoHibikiPage] video load failed: $e\n$stack');
      if (_controller == null) controller.dispose();
      if (mounted) setState(() => _failed = true);
      return;
    }
    controller.onPositionWrite =
        (String uid, int posMs) => widget.repo.updatePosition(uid, posMs);
    if (!mounted) {
      if (_controller == null) controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _title = title;
      _failed = false;
    });
  }

  /// 切到第 [index] 集：持久化 currentEpisode（位置归零）+ 重新 load 新集字幕。
  Future<void> _switchEpisode(int index) async {
    if (index < 0 || index >= _episodes.length) return;
    if (index == _currentEpisode) return;
    await widget.repo.updateCurrentEpisode(widget.bookUid, index);
    // 切集从头播：位置归零（避免把上一集的进度套到新集）。
    await widget.repo.updatePosition(widget.bookUid, 0);
    await _loadEpisode(index, initialPositionMs: 0);
  }

  void _showEpisodeList() {
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
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// 点字幕第 [graphemeIndex] 个字符：暂停 → 从该位置起取词 → 查词 → 弹词典。
  Future<void> _lookupAt(String sentence, int graphemeIndex) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    await controller.pause();
    final String term = sentence.characters.skip(graphemeIndex).join();
    debugPrint('[video-lookup] tap idx=$graphemeIndex term="$term"');
    if (term.isEmpty) return;
    final DictionarySearchResult result = await appModel.searchDictionary(
      searchTerm: term,
      searchWithWildcards: false,
      overrideMaximumTerms: appModel.maximumTerms,
    );
    debugPrint('[video-lookup] entries=${result.entries.length}');
    if (!mounted || result.entries.isEmpty) {
      if (mounted && result.entries.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未找到该词')),
        );
      }
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xF2101010),
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.6,
          ),
          child: DictionaryPopupNative(
            result: result,
            onMineEntry: (Map<String, String> fields) =>
                _mine(fields, sentence),
          ),
        ),
      ),
    );
  }

  /// 制卡：词典字段 + 当前字幕例句 + 视频截图（coverPath→{book-cover}）
  /// + 字幕音频片段（sasayakiAudioPath→{sasayaki-audio}）。复用现有 Anki 字段。
  Future<void> _mine(Map<String, String> fields, String sentence) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final Directory tmp = await getTemporaryDirectory();

    // 视频截图（当前帧）→ coverPath。
    String? coverPath;
    final Uint8List? shot = await controller.screenshot();
    if (shot != null && shot.isNotEmpty) {
      final File f = File('${tmp.path}/video_mine_shot.jpg');
      await f.writeAsBytes(shot);
      coverPath = f.path;
    }

    // 当前字幕 cue 的音频片段（桌面 ffmpeg 按时间裁）→ sasayakiAudioPath。
    String? audioPath;
    final AudioCue? cue = controller.currentCue;
    final String? videoPath = controller.videoPath;
    if (cue != null && videoPath != null) {
      audioPath = await extractAudioSegmentViaFfmpeg(
        inputPath: videoPath,
        startMs: cue.startMs,
        endMs: cue.endMs,
        outputPath: '${tmp.path}/video_mine_audio.aac',
      );
    }

    final AnkiMiningContext miningContext = AnkiMiningContext(
      sentence: sentence,
      cueSentence: cue?.text,
      documentTitle: _title,
      coverPath: coverPath,
      sasayakiAudioPath: audioPath,
    );
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final MineResult result = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );
    if (!mounted) return;
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
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(message)));
    if (mounted) Navigator.of(context).pop();
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
          onPressed: () => _showTrackMenu(
            controller.subtitleTracks
                .map((SubtitleTrack tr) => (
                      label: _trackLabel(tr.title, tr.language, tr.id),
                      onSelected: () => controller.selectSubtitleTrack(tr),
                    ))
                .toList(),
          ),
        ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.audiotrack),
          onPressed: () => _showTrackMenu(
            controller.audioTracks
                .map((AudioTrack tr) => (
                      label: _trackLabel(tr.title, tr.language, tr.id),
                      onSelected: () => controller.selectAudioTrack(tr),
                    ))
                .toList(),
          ),
        ),
      ],
    );
  }

  void _showTrackMenu(
    List<({String label, VoidCallback onSelected})> tracks,
  ) {
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
    );
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
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(_title ?? ''),
        actions: _isPlaylist
            ? <Widget>[
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
              ]
            : null,
      ),
      body: _failed
          ? Center(
              child: Icon(Icons.error_outline, color: cs.error, size: 48),
            )
          : (controller == null || videoController == null)
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: MaterialDesktopVideoControlsTheme(
                        normal: _desktopControlsTheme(controller),
                        fullscreen: _desktopControlsTheme(controller),
                        child: Video(
                          controller: videoController,
                          controls: AdaptiveVideoControls,
                        ),
                      ),
                    ),
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
