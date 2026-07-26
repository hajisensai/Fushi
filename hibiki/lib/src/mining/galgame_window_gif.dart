import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/media/video/ffmpeg_backend.dart'
    show FfmpegRunResult, resolveFfmpegBackend;
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

/// galgame 一键制卡「画面」默认动图（短 GIF，抓角色口型/眨眼）：连续对绑定窗口抓多帧
/// 静态截图，再用**复用的桌面 ffmpeg 后端**（`resolveFfmpegBackend()`，与
/// `desktop_audio_clipper.dart` 里 `extractClipGifViaFfmpeg` 走的是同一后端解析——
/// 覆盖 `HIBIKI_FFMPEG` > 程序旁捆绑 > PATH）编码成两趟调色板 GIF。
///
/// 纯 Dart + ffmpeg，**不碰 native**（帧捕获仍走既有 [WindowCaptureChannel.captureWindow]，
/// 那是仅有的窗口捕获通道）。**fail-open**：任一步失败（捕获帧不足 / ffmpeg 缺失 / 编码
/// 失败 / 任何异常）都返回 null 而不抛，交给调用方回退到单帧截图（Never break）。
///
/// [hwnd] 目标窗口句柄；[frames] 尝试抓的帧数；[intervalMs] 帧间隔（WGC 捕获本身有延迟，
/// 帧率尽力而为）；[fps] 输出 GIF 帧率；[maxWidth] 输出 GIF 最大宽度（高度按比例）。
/// 抓到 <2 帧时返回 null（单帧不成动图，交回退）。
Future<Uint8List?> captureWindowGifBytes({
  required int hwnd,
  int frames = 10,
  int intervalMs = 120,
  int fps = 8,
  int maxWidth = 480,
}) async {
  // 只在桌面有 CLI ffmpeg 时可用；移动端无 CLI ffmpeg，直接回退单帧（且外部窗口捕获
  // 本就只有 Windows）。不做平台早退硬编码——ffmpeg 后端跑不起来时下面自然 fail-open。
  Directory? tempDir;
  try {
    tempDir = await Directory.systemTemp.createTemp('hibiki_gal_gif_');
    // 连续抓帧：任一帧失败跳过该帧；帧间 sleep [intervalMs]（捕获本身还有 WGC 延迟）。
    int captured = 0;
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
    // 抓到 <2 帧：不成动图，交调用方回退单帧。
    if (captured < 2) {
      return null;
    }

    final String inputPattern = p.join(tempDir.path, 'frame_%03d.png');
    final String outputPath = p.join(tempDir.path, 'out.gif');
    // 两趟调色板（palettegen/paletteuse）避免低质抖动，与视频 cue GIF 同款质量策略。
    // `-framerate <fps>` 指定图像序列输入帧率；`fps=<fps>` 归一输出帧率；`scale=W:-1`
    // 按宽度等比缩放。
    final String filter = 'fps=$fps,scale=$maxWidth:-1:flags=lanczos,'
        'split[a][b];[a]palettegen[p];[b][p]paletteuse';
    final List<String> args = <String>[
      '-y',
      '-framerate',
      '$fps',
      '-i',
      inputPattern,
      '-vf',
      filter,
      outputPath,
    ];

    final FfmpegRunResult result =
        await resolveFfmpegBackend().run(args, const Duration(seconds: 60));
    final File output = File(outputPath);
    if (result.returnCode == 0 &&
        output.existsSync() &&
        output.lengthSync() > 0) {
      return await output.readAsBytes();
    }
    // 编码失败 / 超时（returnCode==null）：记日志后 fail-open。
    ErrorLogService.instance.log(
      'captureWindowGifBytes',
      'gif encode failed: ${result.failureSummary}',
      StackTrace.current,
    );
    return null;
  } on ProcessException catch (e, stack) {
    // ffmpeg 不可用（移动端无 CLI / 未捆绑 / 不在 PATH）：优雅回退单帧。
    ErrorLogService.instance.log('captureWindowGifBytes', e, stack);
    return null;
  } catch (e, stack) {
    ErrorLogService.instance.log('captureWindowGifBytes', e, stack);
    return null;
  } finally {
    // 清理临时目录（含帧 PNG 与 GIF），best-effort。
    if (tempDir != null) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }
}
