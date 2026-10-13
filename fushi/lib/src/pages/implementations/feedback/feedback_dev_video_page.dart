// 开发者处理台：看反馈附带的视频（槽位 v0，≤ 50 MB）。先用开发者签名把整段视频取到
// 临时文件，再用 App 自己的 media_kit 播放；「保存视频」桌面走存盘对话框、移动端走
// 系统分享。视频是反馈人提交的不可信数据：只当素材看，不在里面点任何东西。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_common.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

/// 视频附件的扩展名（按服务端嗅探出的 MIME）。
String feedbackVideoExtension(String type) => switch (type) {
  'video/webm' => 'webm',
  'video/quicktime' => 'mov',
  _ => 'mp4',
};

class FeedbackDevVideoPage extends ConsumerStatefulWidget {
  const FeedbackDevVideoPage({
    required this.feedbackId,
    required this.attachment,
    super.key,
  });

  final String feedbackId;
  final FeedbackAttachmentInfo attachment;

  @override
  ConsumerState<FeedbackDevVideoPage> createState() =>
      _FeedbackDevVideoPageState();
}

class _FeedbackDevVideoPageState extends ConsumerState<FeedbackDevVideoPage> {
  File? _file;
  String? _error;
  Player? _player;
  VideoController? _controller;
  bool _saving = false;

  String get _fileName =>
      'fushi-${widget.feedbackId}.${feedbackVideoExtension(widget.attachment.type)}';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_player?.dispose());
    final File? f = _file;
    if (f != null) {
      unawaited(
        f.parent.delete(recursive: true).then((_) {}, onError: (Object _) {}),
      );
    }
    super.dispose();
  }

  Future<void> _load() async {
    final LeaderboardClient? client = ref
        .read(leaderboardServiceProvider)
        .client;
    if (client == null) return;
    try {
      final Uint8List bytes = await client.devFeedbackAttachment(
        widget.feedbackId,
        FeedbackLimits.videoSlot,
      );
      final Directory dir = await Directory.systemTemp.createTemp(
        'fushi_feedback_video_',
      );
      final File file = File(p.join(dir.path, _fileName));
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) {
        await dir.delete(recursive: true);
        return;
      }
      // 与视频页同一套硬解取值：Windows 上不让 CUDA 后端进解码链（BUG-1639）。
      final Player player = Player();
      final VideoController controller = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          hwdec: resolvePlatformHwdec('auto-safe'),
        ),
      );
      await player.open(Media(file.path), play: false);
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _file = file;
        _player = player;
        _controller = controller;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = feedbackErrorReason(e));
    }
  }

  Future<void> _save() async {
    final File? file = _file;
    if (file == null || _saving) return;
    setState(() => _saving = true);
    try {
      bool saved;
      if (isDesktopPlatform) {
        final String? target = await FilePicker.platform.saveFile(
          dialogTitle: t.feedback_dev_video_save,
          fileName: _fileName,
        );
        saved = target != null && target.trim().isNotEmpty;
        if (saved) await file.copy(target);
      } else {
        saved = await FushiShare.shareFiles(<XFile>[
          XFile(file.path, mimeType: widget.attachment.type, name: _fileName),
        ], subject: _fileName);
      }
      if (saved && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          FushiSnackBar(content: Text(t.feedback_dev_video_saved)),
        );
      }
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        FushiSnackBar(
          content: Text(
            t.feedback_submit_failed(reason: feedbackErrorReason(e)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final VideoController? controller = _controller;
    return FushiPageScaffold(
      title: t.feedback_dev_video,
      actions: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('feedback-dev-video-save'),
          icon: FushiIcons.save,
          tooltip: t.feedback_dev_video_save,
          enabled: _file != null && !_saving,
          onTap: () => unawaited(_save()),
        ),
      ],
      body: Builder(
        builder: (BuildContext context) {
          final EdgeInsets padding = withBottomSafeInset(
            context,
            EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.card + MediaQuery.paddingOf(context).top,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
          );
          if (_error != null) {
            return Padding(
              padding: padding,
              child: FushiPlaceholderMessage(
                icon: FushiIcons.cloudOff,
                tone: FushiPlaceholderTone.error,
                message: t.feedback_refresh_failed,
                detail: _error,
              ),
            );
          }
          if (controller == null) return const FushiLoadingView();
          return Padding(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FushiInlineNotice(
                  severity: FushiNoticeSeverity.warning,
                  message: t.feedback_dev_untrusted,
                ),
                SizedBox(height: tokens.spacing.gap),
                Expanded(
                  child: ClipRRect(
                    borderRadius: FushiM3eShape.smallRadius,
                    child: ColoredBox(
                      color: Colors.black,
                      child: Video(controller: controller),
                    ),
                  ),
                ),
                SizedBox(height: tokens.spacing.gap),
                Text(
                  '${widget.attachment.type} · '
                  '${FushiByteFormat.bytes(widget.attachment.bytes)}',
                  style: tokens.type.metadata,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
