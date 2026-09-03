import 'dart:async';
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
/// 制卡动图最长覆盖的整句时长。galgame 一句语音通常 1～6 s；再长的是长独白，
/// 动图撑到 8 s 还没播完就截断，卡片体积（AVIF 约 3 KB/帧）和抓帧时间都不该无界。
const Duration kGalAnimatedMaxDuration = Duration(seconds: 8);

/// 动图该抓多少帧：以 [fps] 回放时至少覆盖整句语音 [target]，不少于 [baseFrames]
/// （无时长信息时的旧行为 = 10 帧 / 1.25 s），不多于 [kGalAnimatedMaxDuration]。
///
/// [pending] = 整句时长还没算出来（引擎 PCM 要等语音播完才知道长度）：此时不能
/// 停——语音还在播，画面正是这句的画面，继续采样直到时长到达或撞上限。
/// 时长到达但为 null（字节不是 ADTS、帧头损坏）→ 回退基线帧数；此时已多抓的帧
/// 由 [trimSurplusAnimationFrames] 在编码前裁掉，落地行为才真的等于基线帧数。
int galAnimatedFrameBudget({
  required int baseFrames,
  required int fps,
  required Duration? target,
  required bool pending,
}) {
  final int maxFrames = (kGalAnimatedMaxDuration.inMilliseconds * fps) ~/ 1000;
  if (pending) return maxFrames;
  if (target == null || target <= Duration.zero) return baseFrames;
  final int wanted = (target.inMilliseconds * fps + 999) ~/ 1000;
  if (wanted <= baseFrames) return baseFrames;
  return wanted > maxFrames ? maxFrames : wanted;
}

/// 第 [index] 帧的落盘文件名。ffmpeg 的 `image2` 解复用器按 `frame_%03d.png` 连号
/// 读取，遇到第一个缺号就停 —— 命名规则和 [kGalAnimationFramePattern] 必须是同一处
/// 真相源，否则裁帧会裁不掉（改名后删的是别的文件）。
String galAnimationFrameName(int index) =>
    'frame_${index.toString().padLeft(3, '0')}.png';

/// 与 [galAnimationFrameName] 配套的 ffmpeg 输入模式。
const String kGalAnimationFramePattern = 'frame_%03d.png';

/// 把 [directory] 里已落盘的 [captured] 帧裁到 [budget] 帧，返回实际保留的帧数。
///
/// 采样循环在整句时长未知期间按上限抓帧，时长到达后预算会**收缩**；多出来的帧若
/// 留在目录里就会一起进 ffmpeg，动图比整句语音还长——这正是 [galAnimatedFrameBudget]
/// 的语义在生产路径上唯一可能落空的地方（BUG-2069 审查 B4）。
///
/// 删除是 best-effort：删失败的那一帧仍在序列里，此时不能上报一个比实际文件少的
/// 帧数（会让调用方以为已截断），故遇到删除失败就停在该帧。
Future<int> trimSurplusAnimationFrames({
  required Directory directory,
  required int captured,
  required int budget,
}) async {
  if (captured <= budget) return captured;
  for (int i = budget; i < captured; i++) {
    try {
      await File(p.join(directory.path, galAnimationFrameName(i))).delete();
    } catch (_) {
      return i; // 删不掉：序列到此为止，如实回报。
    }
  }
  return budget;
}

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
  // 本句语音时长（异步：制卡时音频与画面并行采集，资源音频立刻可知、引擎 PCM 要
  // 等整句播完）。给了就把动图抓到覆盖整句为止（上限 [kGalAnimatedMaxDuration]）；
  // null / 解析出 null 都退回 [frames] 帧的旧行为——**包括已经多抓的那些帧**，
  // 它们在编码前被 [trimSurplusAnimationFrames] 裁掉。见 [galAnimatedFrameBudget]。
  //
  // ⚠️ 已知代价：时长未定期间 capture lease 一直被持有，最坏 8 s 墙钟（旧行为固定
  // ~1.2 s）。lease 期间游戏内查词卡与高亮是隐藏的，用户会看到它消失更久。
  Future<Duration?>? targetDuration,
}) async {
  // 只在桌面有 CLI ffmpeg 时可用；移动端无 CLI ffmpeg，直接回退单帧（且外部窗口捕获
  // 本就只有 Windows）。不做平台早退硬编码——ffmpeg 后端跑不起来时下面自然 fail-open。
  Directory? tempDir;
  try {
    tempDir = await Directory.systemTemp.createTemp('fushi_gal_gif_');
    // 连续抓帧：任一帧失败跳过该帧；帧间 sleep [intervalMs]（捕获本身还有 WGC 延迟）。
    int captured = 0;
    final GalHookCaptureLease? captureLease =
        captureLeaseFactory == null ? null : await captureLeaseFactory();
    // 整句时长的到达状态：未到达期间维持采样（语音还在播，画面正是这句的画面），
    // 到达后按 [galAnimatedFrameBudget] 收口；永不到达则由上限兜底。
    bool targetResolved = targetDuration == null;
    Duration? resolvedTarget;
    if (targetDuration != null) {
      unawaited(
        targetDuration.then((Duration? value) {
          resolvedTarget = value;
          targetResolved = true;
        }, onError: (Object _) {
          targetResolved = true;
        }),
      );
    }
    // 最终采纳的帧预算。**采样期间会收缩**：`pending` 期间按 [kGalAnimatedMaxDuration]
    // 的上限抓（语音还在播，画面正是这句的画面），时长到达后回落到真实值。所以落盘
    // 帧数可能超过最终预算 —— 必须在编码前裁掉多的，否则 [galAnimatedFrameBudget]
    // 的语义只写在注释里、动图仍比整句长（BUG-2069 审查 B4）。
    int frameBudget = frames;
    try {
      // BUG-1096：native 的成功路径诊断（光标抑制是否真的生效 / 捕获目标是否被从
      // Magpie 缩放窗重定向）。每轮只记一次，逐帧刷会把日志淹掉。
      String? loggedDiagnostics;
      for (int i = 0;; i++) {
        if (i >= frames) {
          frameBudget = galAnimatedFrameBudget(
            baseFrames: frames,
            fps: fps,
            target: targetResolved ? resolvedTarget : null,
            pending: !targetResolved,
          );
          if (i >= frameBudget) break;
        }
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
        final String frameName = galAnimationFrameName(captured);
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
    // 预算收缩后多抓的帧不能进 ffmpeg（BUG-2069 审查 B4）。image2 解复用器从
    // `frame_000` 起连读到第一个缺号为止，所以删掉尾部即等于截断序列。
    captured = await trimSurplusAnimationFrames(
      directory: tempDir,
      captured: captured,
      budget: frameBudget,
    );
    // 抓到 <2 帧：不成动图，交调用方回退单帧。
    if (captured < 2) {
      return null;
    }

    final String inputPattern = p.join(tempDir.path, kGalAnimationFramePattern);

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
