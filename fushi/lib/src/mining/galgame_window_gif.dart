import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/media/video/ffmpeg_backend.dart'
    show FfmpegRunResult, resolveFfmpegBackend;
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart'
    show animatedEncoderArgs;
import 'package:fushi/src/mining/immersion_mining_request.dart'
    show MiningAnimatedFormat;
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

/// 捕获产物：字节 + **实际编码成的格式**。
///
/// 必须把格式带出来，不能让调用方按「用户选了什么」去拼文件名——[captureWindowGifBytes]
/// 内部会在首选格式编码失败时降级 GIF，两者可以不一致。若调用方自行拼名，就会出现
/// `external_window.avif` 里装着 GIF 字节：Anki 按扩展名判 MIME，卡片直接显示不出来。
typedef GalWindowAnimatedCapture = ({
  Uint8List bytes,
  MiningAnimatedFormat format,
});

/// 游戏画面采样期间持有的可释放屏障。
///
/// 游戏内查词卡本身画在目标游戏窗口里，所以场景截图必须先由 hook 确认卡片与高亮
/// 已隐藏。lease 的生命周期只覆盖真正读取窗口像素的区间；ffmpeg 编码和 Anki 写入
/// 不得占着它，否则卡片会在与截图无关的慢任务期间一直消失。
abstract class GalHookCaptureLease {
  Future<void> release();
}

typedef GalHookCaptureLeaseFactory = Future<GalHookCaptureLease> Function();

/// 无法确认游戏内查词层已经隐藏时的 fail-closed 信号。
///
/// [captureWindowGifBytes] 平时 fail-open 回退静图，但这个异常绝不能被吞成普通 GIF
/// 失败，否则调用方会在隐藏状态未知时继续截图，仍可能把 popup 制进卡片。
class GalHookCaptureSuppressionException implements Exception {
  const GalHookCaptureSuppressionException(this.message);

  final String message;

  @override
  String toString() => 'GalHookCaptureSuppressionException: $message';
}

/// galgame 一键制卡「画面」动图（抓角色口型/眨眼）：连续对绑定窗口抓多帧静态截图，
/// 再用**复用的桌面 ffmpeg 后端**（`resolveFfmpegBackend()`，与 `desktop_audio_clipper.dart`
/// 里 `extractClipGifViaFfmpeg` 走的是同一后端解析——覆盖 `FUSHI_FFMPEG` > 程序旁捆绑
/// > PATH）按 [format] 编码（默认格式由用户偏好给出，见 [MiningAnimatedFormat]）。
///
/// 纯 Dart + ffmpeg，**不碰 native**（帧捕获仍走既有 [WindowCaptureChannel.captureWindow]，
/// 那是仅有的窗口捕获通道）。**fail-open**：任一步失败（捕获帧不足 / ffmpeg 缺失 / 编码
/// 失败 / 任何异常）都返回 null 而不抛，交给调用方回退到单帧截图（Never break）。
///
/// [hwnd] 目标窗口句柄；[frames] 尝试抓的帧数；[intervalMs] 帧间隔（WGC 捕获本身有延迟，
/// 帧率尽力而为）；[fps] 输出帧率；[maxWidth] 输出最大宽度（高度按比例）。
/// 抓到 <2 帧时返回 null（单帧不成动图，交回退）。
Future<GalWindowAnimatedCapture?> captureWindowGifBytes({
  required int hwnd,
  int frames = 10,
  int intervalMs = 120,
  int fps = 8,
  int maxWidth = 480,
  // 动图编码格式。默认 [MiningAnimatedFormat.gif] = 旧行为逐字等价（未传的既有调用点
  // 与测试不受影响）；真实调用点传用户偏好 `gal_mining_animated_format`。
  MiningAnimatedFormat format = MiningAnimatedFormat.gif,
  GalHookCaptureLeaseFactory? captureLeaseFactory,
}) async {
  // 只在桌面有 CLI ffmpeg 时可用；移动端无 CLI ffmpeg，直接回退单帧（且外部窗口捕获
  // 本就只有 Windows）。不做平台早退硬编码——ffmpeg 后端跑不起来时下面自然 fail-open。
  Directory? tempDir;
  try {
    tempDir = await Directory.systemTemp.createTemp('hibiki_gal_gif_');
    // 连续抓帧：任一帧失败跳过该帧；帧间 sleep [intervalMs]（捕获本身还有 WGC 延迟）。
    int captured = 0;
    final GalHookCaptureLease? captureLease =
        captureLeaseFactory == null ? null : await captureLeaseFactory();
    try {
      // BUG-1096：native 的成功路径诊断（光标抑制是否真的生效 / 捕获目标是否被从
      // Magpie 缩放窗重定向）。每轮只记一次，逐帧刷会把日志淹掉。
      String? loggedDiagnostics;
      for (int i = 0; i < frames; i++) {
        if (i > 0 && intervalMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: intervalMs));
        }
        final WindowCaptureResult cap =
            await WindowCaptureChannel.captureWindow(hwnd);
        final String? diagnostics = cap.diagnostics;
        if (diagnostics != null &&
            diagnostics.isNotEmpty &&
            diagnostics != loggedDiagnostics) {
          loggedDiagnostics = diagnostics;
          ErrorLogService.instance.log(
            'captureWindowGifBytes',
            'window capture diagnostics: $diagnostics',
            StackTrace.current,
          );
        }
        if (!cap.ok) {
          continue; // 该帧失败：跳过，尽力而为。
        }
        final Uint8List png = cap.pngBytes!;
        final String frameName =
            'frame_${captured.toString().padLeft(3, '0')}.png';
        try {
          await File(p.join(tempDir.path, frameName))
              .writeAsBytes(png, flush: true);
        } catch (_) {
          continue; // 写盘失败：跳过该帧。
        }
        captured++;
      }
    } finally {
      // 只包住上面的窗口采样区间。下面可能运行 60 秒的 ffmpeg 编码不应让游戏内
      // popup 一直消失；release 也必须覆盖捕获/写帧异常。
      if (captureLease != null) await captureLease.release();
    }
    // 抓到 <2 帧：不成动图，交调用方回退单帧。
    if (captured < 2) {
      return null;
    }

    final String inputPattern = p.join(tempDir.path, 'frame_%03d.png');

    // 首选用户所选格式；失败则降级 GIF 再试一次。这不是「重试掩盖症状」——两次调用
    // 的**参数不同**，第二次是能力降级：捆绑 ffmpeg 若来自旧版本包，没有 libsvtav1 /
    // libwebp 编码器（见 tool/ffmpeg-min/build-ffmpeg-min.sh），首选格式必然失败而
    // GIF 恒可用。链本身由格式自己声明（见 [MiningAnimatedFormat.encodeAttempts]），
    // 与视频/Netflix 侧同一处真相源；本函数的输入是 PNG 帧序列、跑的是另一套 ffmpeg
    // 参数，故只共用链而不共用抽取函数。
    final List<MiningAnimatedFormat> attempts = format.encodeAttempts;

    for (final MiningAnimatedFormat attempt in attempts) {
      final String outputPath =
          p.join(tempDir.path, 'out.${attempt.fileExtension}');
      final List<String> args = buildGalWindowAnimatedArgs(
        format: attempt,
        inputPattern: inputPattern,
        outputPath: outputPath,
        fps: fps,
        maxWidth: maxWidth,
      );
      final FfmpegRunResult result =
          await resolveFfmpegBackend().run(args, const Duration(seconds: 60));
      final File output = File(outputPath);
      if (result.returnCode == 0 &&
          output.existsSync() &&
          output.lengthSync() > 0) {
        return (bytes: await output.readAsBytes(), format: attempt);
      }
      // 编码失败 / 超时（returnCode==null）。**非末次尝试只记诊断日志**：捆绑的
      // ffmpeg 缺 libsvtav1/libwebp 时首选格式是 100% 必然失败的，随后降级 GIF 会
      // 成功、卡照样建得出来。把这条必然发生的能力探测写进用户可见错误日志，等于
      // 每制一张卡就塞一条「错误」。末次（GIF 也失败）才是真失败，仍进错误日志。
      final String summary =
          '${attempt.wireName} encode failed: ${result.failureSummary}';
      if (attempt == attempts.last) {
        ErrorLogService.instance
            .log('captureWindowGifBytes', summary, StackTrace.current);
      } else {
        ErrorLogService.instance.logDiagnostic('captureWindowGifBytes',
            '$summary (falling back to ${MiningAnimatedFormat.gif.wireName})');
      }
    }
    return null;
  } on GalHookCaptureSuppressionException {
    rethrow;
  } on ProcessException catch (e, stack) {
    // ffmpeg 不可用（移动端无 CLI / 未捆绑 / 不在 PATH）：优雅回退单帧。
    ErrorLogService.instance.log('captureWindowGifBytes', e, stack);
    return null;
  } catch (e, stack) {
    ErrorLogService.instance.log('captureWindowGifBytes', e, stack);
    return null;
  } finally {
    // 清理临时目录（含帧 PNG 与动图产物），best-effort。
    if (tempDir != null) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }
}

/// 纯函数：构建「PNG 帧序列 → 循环动图」的 ffmpeg 参数表（可单测）。
///
/// 与视频侧的 `buildFfmpegClipAnimatedArgs` 是**两条独立链路**，不强行合并：输入形态
/// 不同（这里是 `-framerate N -i frame_%03d.png` 图像序列，那边是带 `-ss/-t` 的视频
/// 时间窗），硬合并只会造出一个两边都用不顺的参数集。共享的只有「按格式选编码器」这条
/// 规则，它由 [MiningAnimatedFormat] 承载。
///
/// - GIF：`fps,scale` + 两趟调色板（`palettegen`/`paletteuse`）避免抖动。
/// - WebP/AVIF：真彩，无需调色板，滤镜退化为 `fps,scale` 单遍。
///
/// `scale=W:-1` 按宽度等比缩放。⚠️ GIF 对高度奇偶不敏感，但 AVIF/WebP 编码器要求偶数
/// 维度，故非 GIF 分支用 `-2`（等比且取偶）而非 `-1`。
///
/// 三条分支的参数形态已在带 libsvtav1/libwebp 的真实 ffmpeg 上验证可产出非空文件
/// （见 `tool/ffmpeg-min/smoke-test.sh` 的同款命令）。**但入库的 ffmpeg-min 尚未含这两个
/// 编码器**——须重跑 `.github/workflows/ffmpeg-min.yml` 并重新 vendor exe，在那之前
/// AVIF/WebP 会走 [captureWindowGifBytes] 的降级路径落回 GIF。
List<String> buildGalWindowAnimatedArgs({
  required MiningAnimatedFormat format,
  required String inputPattern,
  required String outputPath,
  required int fps,
  required int maxWidth,
}) {
  final bool isGif = format == MiningAnimatedFormat.gif;
  final String scale = isGif
      ? 'scale=$maxWidth:-1:flags=lanczos'
      : 'scale=$maxWidth:-2:flags=lanczos';
  final String filter = isGif
      ? 'fps=$fps,$scale,split[a][b];[a]palettegen[p];[b][p]paletteuse'
      : 'fps=$fps,$scale';
  return <String>[
    '-y',
    '-framerate',
    '$fps',
    '-i',
    inputPattern,
    '-vf',
    filter,
    // 编码器参数与视频 cue 动图**共用同一处真相源**，两条链路不各持一份。
    ...animatedEncoderArgs(format),
    if (format != MiningAnimatedFormat.gif) ...<String>['-loop', '0'],
    outputPath,
  ];
}
