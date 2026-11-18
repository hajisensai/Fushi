import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_engine/media/video/bluray/bluray_episode.dart'
    show isBlurayEpisodePath;
import 'package:fushi_engine/media/video/video_cover_extractor.dart'
    show isLocalFrameExtractableVideoSource;
import 'package:fushi_engine/media/video/video_duration_probe.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show extractVideoFrameViaFfmpeg;

/// 「从视频画面选取封面」（拍板 wb8RZZbn90）：在视频时间轴上拖动挑一帧，
/// 截成图片交给调用方落盘。
///
/// 取帧走与导入期自动封面同一条 ffmpeg 抽帧（[extractVideoFrameViaFfmpeg]），
/// 不经播放器：截出的是**干净画面**（不叠图形字幕、不叠播放器 OSD），也不要求
/// 先打开播放页。HDR 片源与导入期自动封面一样不做色调映射。
///
/// 把截好的帧交给 [apply]（单集走 `MediaCoverService.applyVideoCoverManual`，
/// 手选保护标记照记，批量刮削不覆盖）；临时文件在 [apply] 返回后删除。
/// 返回 true = 已应用；false = 用户取消，或失败已 toast + 记错误日志。
Future<bool> pickAndApplyVideoFrameCover({
  required BuildContext context,
  required String videoPath,
  required Future<void> Function(String framePath) apply,
  VideoFrameDurationProbe probeDurationMs = probeVideoDurationMs,
  VideoFrameFileGrabber grabFrame = grabVideoFrameToFile,
}) async {
  final int? atMs = await showVideoFrameCoverPicker(
    context: context,
    videoPath: videoPath,
    probeDurationMs: probeDurationMs,
    grabFrame: grabFrame,
  );
  if (atMs == null) return false;
  return applyVideoFrameCoverAt(
    videoPath: videoPath,
    atMs: atMs,
    apply: apply,
    grabFrame: grabFrame,
  );
}

/// 纯函数：单集菜单是否给 [videoPath] 出「从视频画面选取」入口。
///
/// 在「本地可抽帧」（[isLocalFrameExtractableVideoSource]）之外再排除蓝光分集的
/// **虚拟**路径（`<n>.pNN.mpls`，[isBlurayEpisodePath]）：它不是真实文件，
/// ffmpeg 抽帧对本地输入先查文件存在，必然失败，入口点开只会是失败态。
bool isVideoFrameCoverPickableSource(String videoPath) =>
    isLocalFrameExtractableVideoSource(videoPath) &&
    !isBlurayEpisodePath(videoPath.trim());

/// 打开挑帧弹窗，返回用户确认的时刻（毫秒）；null = 取消。
///
/// 预览帧写进本次弹窗专属的临时目录，读成字节后立刻删文件，弹窗关闭时整个
/// 目录一起删。
Future<int?> showVideoFrameCoverPicker({
  required BuildContext context,
  required String videoPath,
  VideoFrameDurationProbe probeDurationMs = probeVideoDurationMs,
  VideoFrameFileGrabber grabFrame = grabVideoFrameToFile,
}) async {
  final Directory tempDir = await Directory.systemTemp.createTemp(
    'fushi_frame_preview_',
  );
  // 弹窗关掉时仍在跑的预览 ffmpeg 会把已删的目录重新建出来（抽帧前
  // `createSync(recursive: true)`），所以在途请求回来后发现弹窗已关，
  // 就由它自己把整个目录删掉并丢弃结果。
  bool closed = false;
  try {
    if (!context.mounted) return null;
    return await showAppDialog<int>(
      context: context,
      builder: (_) => VideoFrameCoverPickerDialog(
        loadDurationMs: () => probeDurationMs(videoPath),
        grabPreview: (int ms, int seq) => grabVideoFramePreviewBytes(
          videoPath: videoPath,
          atMs: ms,
          seq: seq,
          tempDir: tempDir,
          isClosed: () => closed,
          grabFrame: grabFrame,
        ),
      ),
    );
  } finally {
    closed = true;
    await _deleteQuietly(tempDir);
  }
}

/// 按 [atMs] 截**原尺寸**帧到临时文件，交给 [apply] 落盘，返回后删临时目录。
///
/// 返回 true = 已应用；false = 截不到帧或 [apply] 抛错（已 toast + 记错误日志）。
Future<bool> applyVideoFrameCoverAt({
  required String videoPath,
  required int atMs,
  required Future<void> Function(String framePath) apply,
  VideoFrameFileGrabber grabFrame = grabVideoFrameToFile,
}) async {
  Directory? tempDir;
  try {
    tempDir = await Directory.systemTemp.createTemp('fushi_frame_cover_');
    final String? framePath = await grabFrame(
      videoPath: videoPath,
      atMs: atMs,
      outputPath: p.join(tempDir.path, 'cover.jpg'),
      scaleWidth: null,
    );
    if (framePath == null) {
      FushiToast.show(
        msg: t.video_cover_frame_failed,
        severity: ToastSeverity.error,
      );
      return false;
    }
    await apply(framePath);
    return true;
  } on Object catch (e, stack) {
    ErrorLogService.instance.log('video.frameCover', e, stack);
    FushiToast.show(
      msg: t.video_cover_frame_failed,
      severity: ToastSeverity.error,
    );
    return false;
  } finally {
    if (tempDir != null) await _deleteQuietly(tempDir);
  }
}

/// 弹窗里的一次预览取帧：截缩略帧到 [tempDir]，读成字节后删文件。
///
/// 请求回来时弹窗已关（[isClosed]）就丢弃结果并删掉整个 [tempDir]——关弹窗时
/// 删过的目录可能已被这次在途的抽帧重新建出来。
@visibleForTesting
Future<Uint8List?> grabVideoFramePreviewBytes({
  required String videoPath,
  required int atMs,
  required int seq,
  required Directory tempDir,
  required bool Function() isClosed,
  required VideoFrameFileGrabber grabFrame,
}) async {
  final String? path = await grabFrame(
    videoPath: videoPath,
    atMs: atMs,
    outputPath: p.join(tempDir.path, 'preview_$seq.jpg'),
    scaleWidth: kVideoFrameCoverPreviewWidth,
  );
  if (isClosed()) {
    await _deleteQuietly(tempDir);
    return null;
  }
  if (path == null) return null;
  final File file = File(path);
  final Uint8List bytes = await file.readAsBytes();
  // 预览字节已在内存里，文件立刻删，拖动几十次也不堆临时文件。
  unawaited(file.delete().then((_) {}, onError: (Object _) {}));
  return bytes;
}

Future<void> _deleteQuietly(Directory dir) async {
  try {
    await dir.delete(recursive: true);
  } on FileSystemException catch (_) {}
}

/// 预览帧宽度（px）：够在弹窗里看清，又让 ffmpeg 少编码几倍像素。
const int kVideoFrameCoverPreviewWidth = 640;

/// 时长探测接缝：拿不到时长返回 null。
typedef VideoFrameDurationProbe = Future<int?> Function(String videoPath);

/// 取帧接缝：把 [atMs] 处一帧写到 [outputPath]，成功返回该路径，失败返回 null。
/// [scaleWidth] 为 null = 原尺寸（最终封面），否则按宽度缩放（预览）。
typedef VideoFrameFileGrabber =
    Future<String?> Function({
      required String videoPath,
      required int atMs,
      required String outputPath,
      required int? scaleWidth,
    });

/// 生产取帧：[extractVideoFrameViaFfmpeg]（staged 写 + 完整性校验后原子发布）。
/// 用户主动操作，失败照常进错误计数（`diagnosticOnly` 保持 false）。
Future<String?> grabVideoFrameToFile({
  required String videoPath,
  required int atMs,
  required String outputPath,
  required int? scaleWidth,
}) {
  return extractVideoFrameViaFfmpeg(
    inputPath: videoPath,
    outputPath: outputPath,
    atSeconds: atMs / 1000.0,
    scaleWidth: scaleWidth,
  );
}

/// 弹窗打开时预览的初始位置：片长 10%（多半已过片头 logo / 黑场），夹在
/// [0, durationMs) 内。时长未知时不应调用（弹窗直接显示失败态）。
int initialVideoFrameCoverPositionMs(int durationMs) {
  if (durationMs <= 0) return 0;
  return (durationMs / 10).round().clamp(0, durationMs - 1);
}

/// 时间戳显示：`m:ss`，满一小时 `h:mm:ss`。
String formatVideoFrameCoverTimestamp(int ms) {
  final int totalSeconds = (ms < 0 ? 0 : ms) ~/ 1000;
  final int h = totalSeconds ~/ 3600;
  final int m = (totalSeconds % 3600) ~/ 60;
  final int s = totalSeconds % 60;
  final String ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// 单步跳转的步长（与播放器底栏 ±10 秒同一手感）。
const int kVideoFrameCoverStepMs = 10000;

/// 挑帧弹窗：上方预览、下方时间轴滑块 + ±10 秒微调，「用这一帧」返回所选毫秒。
///
/// 预览只在松手（[Slider.onChangeEnd]）或点微调时取：拖动过程中不连发 ffmpeg。
/// 取帧单飞：同一时刻最多一个在途请求；在途期间的新选择只记最后一次，在途请求
/// 回来后丢掉它的结果、改取最后那次，预览永远对应最后一次选择。
/// 导出 widget 便于测试直接构造。
class VideoFrameCoverPickerDialog extends StatefulWidget {
  const VideoFrameCoverPickerDialog({
    required this.loadDurationMs,
    required this.grabPreview,
    super.key,
  });

  /// 读片长（毫秒）；null = 读不到，弹窗显示失败态。
  final Future<int?> Function() loadDurationMs;

  /// 取 [atMs] 处的预览帧字节；[seq] 是本次请求序号（可用来派生临时文件名）。
  final Future<Uint8List?> Function(int atMs, int seq) grabPreview;

  @override
  State<VideoFrameCoverPickerDialog> createState() =>
      _VideoFrameCoverPickerDialogState();
}

class _VideoFrameCoverPickerDialogState
    extends State<VideoFrameCoverPickerDialog> {
  int? _durationMs;
  bool _durationFailed = false;
  int _positionMs = 0;

  /// 预览请求序号（递增，交给 [VideoFrameCoverPickerDialog.grabPreview] 派生
  /// 临时文件名）。
  int _requestSeq = 0;

  /// 是否有预览取帧在途。单飞：一次 ffmpeg 抽帧要几百毫秒到几秒，连点微调若每次
  /// 都新起一个，就是 N 路并发解码（Android 上是 app 进程内的 ffmpeg-kit）。
  bool _grabInFlight = false;

  /// 在途期间用户又选的位置：只留最后一次，在途请求回来后改取它，中间值丢弃。
  int? _pendingMs;

  /// 当前显示的预览（对应 [_previewMs]）。
  Uint8List? _preview;
  int? _previewMs;
  bool _loading = false;
  bool _previewFailed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDuration());
  }

  Future<void> _loadDuration() async {
    int? duration;
    try {
      duration = await widget.loadDurationMs();
    } on Object catch (e, stack) {
      ErrorLogService.instance.log('video.frameCover.duration', e, stack);
    }
    if (!mounted) return;
    if (duration == null || duration <= 0) {
      setState(() => _durationFailed = true);
      return;
    }
    final int start = initialVideoFrameCoverPositionMs(duration);
    setState(() {
      _durationMs = duration;
      _positionMs = start;
    });
    unawaited(_requestPreview(start));
  }

  Future<void> _requestPreview(int atMs) async {
    setState(() {
      _loading = true;
      _previewFailed = false;
    });
    if (_grabInFlight) {
      _pendingMs = atMs;
      return;
    }
    _grabInFlight = true;
    int target = atMs;
    while (true) {
      final int seq = ++_requestSeq;
      Uint8List? bytes;
      try {
        bytes = await widget.grabPreview(target, seq);
      } on Object catch (e, stack) {
        ErrorLogService.instance.log('video.frameCover.preview', e, stack);
      }
      if (!mounted) return;
      final int? next = _pendingMs;
      _pendingMs = null;
      if (next != null && next != target) {
        // 这次结果已过期：不显示，改取在途期间的最后一次选择。
        target = next;
        continue;
      }
      _grabInFlight = false;
      setState(() {
        _loading = false;
        if (bytes == null) {
          _previewFailed = true;
        } else {
          _preview = bytes;
          _previewMs = target;
        }
      });
      return;
    }
  }

  void _seekTo(int ms) {
    final int? duration = _durationMs;
    if (duration == null) return;
    final int clamped = ms.clamp(0, duration - 1);
    setState(() => _positionMs = clamped);
    unawaited(_requestPreview(clamped));
  }

  /// 「用这一帧」只在预览已对上当前位置时可点：用户确认的就是眼前看到的那帧。
  bool get _canConfirm =>
      !_loading && _preview != null && _previewMs == _positionMs;

  @override
  Widget build(BuildContext context) {
    final int? duration = _durationMs;
    return FushiAlertDialog(
      title: Text(t.video_cover_from_frame),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AspectRatio(aspectRatio: 16 / 9, child: _buildPreview(context)),
            const SizedBox(height: 12),
            if (duration != null) _buildTimeline(context, duration),
          ],
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_cancel),
        ),
        FushiFilledButton(
          key: const ValueKey<String>('video-frame-cover-confirm'),
          onPressed: _canConfirm
              ? () => Navigator.of(context).pop(_positionMs)
              : null,
          child: Text(t.video_cover_frame_use),
        ),
      ],
    );
  }

  Widget _buildPreview(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Widget child;
    final String key;
    if (_durationFailed || (_previewFailed && !_loading)) {
      key = 'failed';
      child = Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            t.video_cover_frame_failed,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    } else if (_preview != null) {
      key = 'frame-$_previewMs';
      child = Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Image.memory(_preview!, fit: BoxFit.contain, gaplessPlayback: true),
          if (_loading) const Center(child: FushiCircularProgressIndicator()),
        ],
      );
    } else {
      key = 'loading';
      child = const Center(child: FushiCircularProgressIndicator());
    }
    return ClipRRect(
      borderRadius: FushiM3eShape.smallRadius,
      child: ColoredBox(
        color: FushiDesignTokens.of(context).surfaces.card,
        child: AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.short),
          switchInCurve: FushiMotion.enter,
          switchOutCurve: FushiMotion.exit,
          child: KeyedSubtree(key: ValueKey<String>(key), child: child),
        ),
      ),
    );
  }

  Widget _buildTimeline(BuildContext context, int duration) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _buildSeekRow(context, duration),
        Text(
          '${formatVideoFrameCoverTimestamp(_positionMs)} / '
          '${formatVideoFrameCoverTimestamp(duration)}',
          key: const ValueKey<String>('video-frame-cover-timestamp'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildSeekRow(BuildContext context, int duration) {
    return Row(
      children: <Widget>[
        FushiIconButton(
          icon: FushiIcons.replay10,
          tooltip: t.video_bottom_seek_back,
          onTap: () => _seekTo(_positionMs - kVideoFrameCoverStepMs),
        ),
        Expanded(
          child: adaptiveSlider(
            context: context,
            value: _positionMs.toDouble(),
            max: (duration - 1).toDouble(),
            label: formatVideoFrameCoverTimestamp(_positionMs),
            onChanged: (double v) => setState(() => _positionMs = v.round()),
            onChangeEnd: (double v) => _seekTo(v.round()),
          ),
        ),
        FushiIconButton(
          icon: FushiIcons.forward10,
          tooltip: t.video_bottom_seek_forward,
          onTap: () => _seekTo(_positionMs + kVideoFrameCoverStepMs),
        ),
      ],
    );
  }
}
