// 视频进度条缩略图取帧的真机实测（TODO-1082 阶段②）。
//
// 覆盖三件用户真能感知的事，每件都用**可测量的量**而不是「看着挺快」：
//   B1 冷取一串位置：单帧延迟 + **帧是不是目标位置的画面**。
//   B2 回扫同一串位置：应当全部命中缓存，延迟塌到 ~0。
//   B3 **匀速划过进度条不停手**：预览图必须持续更新。旧实现的 120ms 防抖要求
//      指针停下才取帧，这一段里一帧都不会换——正是用户报的「鼠标动了还不会
//      重新加载」。
//
// 素材：亮度随时间线性扫描（`geq=lum='T/120*235+16'`）的 120s / 1080p / GOP=60
// 灰度视频，帧中心像素亮度反推该帧时间，于是「拿到的是哪一帧」是**像素可测量**
// 的，而不是「字节非空 = 成功」这种伪证据。用 ffmpeg 生成：
//
//   ffmpeg -y -f lavfi -i "color=c=black:s=64x36:r=30:d=120" \
//     -vf "geq=lum='T/120*235+16':cb=128:cr=128,scale=1920:1080" \
//     -c:v libx264 -preset veryfast -g 60 -pix_fmt yuv420p lumasweep_1080p.mp4
//
// 路径经 `FUSHI_BENCH_VIDEO` 传入；未设置则整组跳过（本机实测用，不进 CI 门）。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_thumbnail_preview_controller.dart';
import 'package:integration_test/integration_test.dart';

const int _durationMs = 120000;

/// 帧中心像素亮度（`[0,255]`）。素材是全屏灰度纯色，中心像素即代表整帧。
Future<int?> _centerLuma(ui.Image image) async {
  final ByteData? data =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return null;
  final int offset =
      ((image.height ~/ 2) * image.width + (image.width ~/ 2)) * 4;
  if (offset + 2 >= data.lengthInBytes) return null;
  final int r = data.getUint8(offset);
  final int g = data.getUint8(offset + 1);
  final int b = data.getUint8(offset + 2);
  return ((r + g + b) / 3).round();
}

/// 亮度 → 素材时间（毫秒）。两点标定（Y=22→10s，Y=182→80s）：`t = Y*0.4375+0.375`s。
/// Y>=254 已进入饱和区（t>112s），返回 null。
int? _frameTimeMs(int? luma) {
  if (luma == null || luma >= 254) return null;
  return ((luma * 0.4375 + 0.375) * 1000).round();
}

String _stats(List<int> values) {
  if (values.isEmpty) return 'n/a';
  final List<int> sorted = List<int>.of(values)..sort();
  final int sum = sorted.fold<int>(0, (int a, int b) => a + b);
  return 'min=${sorted.first} median=${sorted[sorted.length ~/ 2]} '
      'max=${sorted.last} mean=${(sum / sorted.length).round()}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final String? videoPath = Platform.environment['FUSHI_BENCH_VIDEO'];
  final bool haveAsset = videoPath != null && File(videoPath).existsSync();

  group('缩略图取帧真机实测', () {
    test('B1/B2 冷取正确且有界，回扫命中缓存', () async {
      final OffscreenVideoFrameGrabber grabber =
          OffscreenVideoFrameGrabber(videoPath: videoPath!);
      // 与调度器同源的量化：同一格才谈得上缓存命中。
      final List<int> targets = <double>[0.1, 0.25, 0.4, 0.55, 0.7, 0.85]
          .map((double f) => thumbnailBucketTargetMs(f, _durationMs)!)
          .toList();

      final List<int> coldLatency = <int>[];
      final List<String> wrong = <String>[];
      for (final int targetMs in targets) {
        final Stopwatch sw = Stopwatch()..start();
        final ui.Image? image = await grabber.grab(targetMs);
        sw.stop();
        coldLatency.add(sw.elapsedMilliseconds);
        expect(image, isNotNull, reason: 'target=${targetMs}ms 一帧都没取到');
        final int? frameAt = _frameTimeMs(await _centerLuma(image!));
        final int? drift = frameAt == null ? null : frameAt - targetMs;
        // ffmpeg 的 `-ss` 输入定位落在目标之前最近的关键帧上（素材 GOP=2s）；
        // 判据放宽到 [-3200, +1200] 容忍亮度反推的 <0.5s 误差。正 drift 明显超界
        // 意味着拿到了目标**之后**的帧，那绝不可能是本次请求的产物。
        if (drift == null || drift > 1200 || drift < -3200) {
          wrong.add('target=$targetMs frameAt=$frameAt drift=$drift');
        }
        image.dispose();
      }
      // ignore: avoid_print
      print('[BENCH] B1 cold latency ms: ${_stats(coldLatency)}');
      expect(wrong, isEmpty, reason: '取到的帧不属于目标位置：$wrong');

      final List<int> warmLatency = <int>[];
      for (final int targetMs in targets) {
        final Stopwatch sw = Stopwatch()..start();
        final ui.Image? image = await grabber.grab(targetMs);
        sw.stop();
        warmLatency.add(sw.elapsedMilliseconds);
        expect(image, isNotNull);
        image!.dispose();
      }
      // ignore: avoid_print
      print('[BENCH] B2 warm latency ms: ${_stats(warmLatency)}');

      final List<int> warmSorted = List<int>.of(warmLatency)..sort();
      final List<int> coldSorted = List<int>.of(coldLatency)..sort();
      expect(warmSorted[warmSorted.length ~/ 2], lessThan(10),
          reason: '回扫必须命中缓存（中位数 <10ms），否则来回移动会反复起 ffmpeg');
      expect(warmSorted.last, lessThan(coldSorted.first),
          reason: '最慢的缓存命中也应快过最快的冷取');

      // 同步查询是「不闪 spinner」的前提，必须真的同步返回。
      final ui.Image? sync = grabber.cachedFrame(targets.first);
      expect(sync, isNotNull, reason: 'cachedFrame 必须同步命中');
      sync!.dispose();

      grabber.dispose();
    }, skip: haveAsset ? false : 'FUSHI_BENCH_VIDEO 未设置或素材不存在');

    test('B3 匀速划过进度条不停手 → 预览图持续更新', () async {
      final OffscreenVideoFrameGrabber grabber =
          OffscreenVideoFrameGrabber(videoPath: videoPath!);
      final VideoThumbnailPreviewController controller =
          VideoThumbnailPreviewController(
        grabber: grabber.grab,
        cachedFrameLookup: grabber.cachedFrame,
        durationMsProvider: () => _durationMs,
        onWarmUp: () => unawaited(grabber.warmUp()),
      );

      // 记录浮层真正换过几张图（按 image 实例身份计）。
      final Set<int> distinctFrames = <int>{};
      controller.addListener(() {
        final ui.Image? image = controller.state.image;
        if (image != null) distinctFrames.add(identityHashCode(image));
      });

      // 指针从 10% 匀速划到 90%，每 16ms 一个 hover 事件，**全程不停手**。
      const int steps = 50;
      for (int i = 0; i < steps; i++) {
        controller.request(0.1 + 0.8 * i / (steps - 1), desktop: true);
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      // 给最后一次在途取帧一点收尾时间。
      await Future<void>.delayed(const Duration(milliseconds: 400));

      // ignore: avoid_print
      print('[BENCH] B3 distinct frames during a single sweep: '
          '${distinctFrames.length}');
      expect(distinctFrames.length, greaterThanOrEqualTo(3),
          reason: '匀速划过 ~800ms 期间预览图必须换过几次。旧实现的 120ms 防抖要求'
              '指针停下才取帧，这一段里一帧都不会换（用户报的「鼠标动了还不会重新加载」）');
      expect(controller.state.phase, isNot(ThumbnailPreviewPhase.hidden));

      controller.dispose();
      grabber.dispose();
    }, skip: haveAsset ? false : 'FUSHI_BENCH_VIDEO 未设置或素材不存在');
  });
}
