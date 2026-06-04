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
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
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
    final List<AudioCue> cues = await widget.repo.loadCues(widget.bookUid);
    final VideoPlayerController controller = VideoPlayerController();
    try {
      await controller.load(
        bookUid: widget.bookUid,
        videoFile: File(row.videoPath),
        cues: cues,
        initialPositionMs: row.lastPositionMs,
        externalSubtitlePath: row.subtitleSource,
      );
    } catch (e, stack) {
      debugPrint('[VideoHibikiPage] video load failed: $e\n$stack');
      controller.dispose();
      if (mounted) setState(() => _failed = true);
      return;
    }
    controller.onPositionWrite =
        (String uid, int posMs) => widget.repo.updatePosition(uid, posMs);
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _title = row.title;
    });
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
    return MaterialDesktopVideoControlsThemeData(
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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(_title ?? ''),
      ),
      body: _failed
          ? const Center(
              child: Icon(Icons.error_outline, color: Colors.white70, size: 48),
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
