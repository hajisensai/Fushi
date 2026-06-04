import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_play_bar.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';

/// 视频页：照有声书 `_initAudiobookController` 范式装配播放器。
///
/// 装配顺序：无参构造 [VideoPlayerController] → 读 [VideoBookRepository]
/// 取行/cue → [VideoPlayerController.load] 实例化 Player → 赋
/// [VideoPlayerController.onPositionWrite] → setState 渲染。
///
/// 画面层为 [Stack]：[Video] 铺底 + [VideoSubtitleOverlay] 叠加；底部
/// [VideoPlayBar]。`videoController` 在 load 完成前为空，期间显 loader。
class VideoHibikiPage extends StatefulWidget {
  const VideoHibikiPage({
    required this.bookUid,
    required this.repo,
    super.key,
  });

  final String bookUid;
  final VideoBookRepository repo;

  @override
  State<VideoHibikiPage> createState() => _VideoHibikiPageState();
}

class _VideoHibikiPageState extends State<VideoHibikiPage> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final VideoBookRow? row = await widget.repo.getByBookUid(widget.bookUid);
    if (row == null) return;
    final List<AudioCue> cues = await widget.repo.loadCues(widget.bookUid);
    final VideoPlayerController controller = VideoPlayerController();
    await controller.load(
      bookUid: widget.bookUid,
      videoFile: File(row.videoPath),
      cues: cues,
      initialPositionMs: row.lastPositionMs,
      externalSubtitlePath: row.subtitleSource,
    );
    controller.onPositionWrite =
        (String uid, int posMs) => widget.repo.updatePosition(uid, posMs);
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() => _controller = controller);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? controller = _controller;
    final VideoController? videoController = controller?.videoController;
    return Scaffold(
      backgroundColor: Colors.black,
      body: (controller == null || videoController == null)
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: <Widget>[
                Expanded(
                  child: Stack(
                    children: <Widget>[
                      Positioned.fill(
                        child: Video(controller: videoController),
                      ),
                      Positioned.fill(
                        child: VideoSubtitleOverlay(controller: controller),
                      ),
                    ],
                  ),
                ),
                VideoPlayBar(controller: controller),
              ],
            ),
    );
  }
}
