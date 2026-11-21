/// 字幕工作台内嵌的「生成字幕」面板在**在线流**上的前置一步：先把整集音频拉到本机
/// （[VideoStreamSubtitleAudioStager]，有进度、可取消），拉好后原地换成与本机视频同一个
/// 生成面板（`VideoSubtitleGenerateSheet(embedded: true)`）。
///
/// 已有完整副本（上次拉好、任务没跑完）或同一集正在拉（播放器菜单那边点的）时直接接上，
/// 不重拉。拉取要消耗流量，所以面板打开时不自动开拉，用户点「拉取音频」才开始。
library;

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/subtitle/video_stream_subtitle_audio.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

class VideoStreamSubtitleAudioPanel extends StatefulWidget {
  const VideoStreamSubtitleAudioPanel({
    super.key,
    required this.existing,
    required this.inflight,
    required this.start,
    required this.ready,
    this.onFailed,
  });

  /// 已拉好的副本（打开时查一次）；没有为 null。
  final Future<File?> Function() existing;

  /// 同一集正在拉的那一次（播放器菜单那边开的）；没有为 null。
  final VideoStreamSubtitleAudioStaging? Function() inflight;

  /// 开拉（同一集已在拉就接上那一次）；null = 已经开不了（换了集 / 播放器重建）。
  final VideoStreamSubtitleAudioStaging? Function() start;

  /// 拉取失败（记日志用；面板自己显示原因）。
  final void Function(Object error, StackTrace stack)? onFailed;

  /// 副本就绪 → 生成面板；返回 null = 副本已失效（被清理），回到「拉取」。
  final Future<WidgetBuilder?> Function(File audio) ready;

  @override
  State<VideoStreamSubtitleAudioPanel> createState() =>
      _VideoStreamSubtitleAudioPanelState();
}

enum _Phase { checking, idle, running, failed, ready }

class _VideoStreamSubtitleAudioPanelState
    extends State<VideoStreamSubtitleAudioPanel> {
  _Phase _phase = _Phase.checking;
  VideoStreamSubtitleAudioStaging? _staging;
  String? _error;
  WidgetBuilder? _panel;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    final VideoStreamSubtitleAudioStaging? running = widget.inflight();
    if (running != null) {
      unawaited(_follow(running));
      return;
    }
    final File? audio = await widget.existing();
    if (!mounted) return;
    if (audio != null) {
      await _open(audio);
      return;
    }
    setState(() => _phase = _Phase.idle);
  }

  void _fetch() {
    final VideoStreamSubtitleAudioStaging? staging = widget.start();
    if (staging != null) unawaited(_follow(staging));
  }

  Future<void> _follow(VideoStreamSubtitleAudioStaging staging) async {
    setState(() {
      _staging = staging;
      _phase = _Phase.running;
      _error = null;
    });
    final File audio;
    try {
      audio = await staging.done;
    } on VideoStreamSubtitleAudioCancelled {
      if (mounted) setState(() => _phase = _Phase.idle);
      return;
    } on VideoStreamSubtitleAudioUnavailable catch (e, stack) {
      widget.onFailed?.call(e, stack);
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = e.message;
        });
      }
      return;
    }
    if (!mounted) return;
    await _open(audio);
  }

  Future<void> _open(File audio) async {
    final WidgetBuilder? panel = await widget.ready(audio);
    if (!mounted) return;
    setState(() {
      _panel = panel;
      _phase = panel == null ? _Phase.idle : _Phase.ready;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Widget child = switch (_phase) {
      _Phase.ready => KeyedSubtree(
        key: const ValueKey<String>('video-stream-subtitle-panel-ready'),
        child: _panel!(context),
      ),
      _Phase.checking => const Padding(
        key: ValueKey<String>('video-stream-subtitle-panel-checking'),
        padding: EdgeInsets.symmetric(vertical: 16),
        child: FushiLinearProgressIndicator(),
      ),
      _ => _fetchCard(context),
    };
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      child: child,
    );
  }

  Widget _fetchCard(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextStyle hint = tokens.type.metadata;
    final VideoStreamSubtitleAudioStaging? staging = _staging;
    final bool running = _phase == _Phase.running && staging != null;
    return Column(
      key: ValueKey<_Phase>(_phase),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          running
              ? t.video_subtitle_stream_audio_hint
              : t.video_subtitle_stream_audio_intro,
          style: hint,
        ),
        SizedBox(height: tokens.spacing.gap),
        if (running)
          ValueListenableBuilder<double?>(
            valueListenable: staging.progress,
            builder: (BuildContext context, double? value, Widget? _) =>
                FushiLinearProgressIndicator(
                  key: const ValueKey<String>(
                    'video-stream-subtitle-audio-progress',
                  ),
                  value: value,
                ),
          ),
        if (_phase == _Phase.failed && _error != null)
          Text(
            t.video_subtitle_stream_audio_failed(reason: _error!),
            key: const ValueKey<String>('video-stream-subtitle-audio-error'),
            style: hint.copyWith(color: Theme.of(context).colorScheme.error),
          ),
        SizedBox(height: tokens.spacing.gap),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: running
              ? FushiTextButton(
                  key: const ValueKey<String>(
                    'video-stream-subtitle-audio-cancel',
                  ),
                  onPressed: staging.cancel,
                  child: Text(t.cancel),
                )
              : FushiPressScale(
                  child: FushiFilledButton.tonalIcon(
                    key: const ValueKey<String>(
                      'video-stream-subtitle-audio-fetch',
                    ),
                    icon: const FushiIcon(FushiIcons.download, size: 18),
                    label: Text(
                      _phase == _Phase.failed
                          ? t.retry
                          : t.video_subtitle_stream_audio_fetch,
                    ),
                    onPressed: _fetch,
                  ),
                ),
        ),
      ],
    );
  }
}
