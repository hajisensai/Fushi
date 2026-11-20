import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:fushi/src/media/video/raw_video_frame.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// BUG-4910（路线图 #3722 video-4）：制卡截帧不能把「制卡后立刻续播」挡在 JPEG 编码
/// 后面。
///
/// media_kit 的 `screenshot` 整段持 Player 串行锁：`screenshot-raw` 取帧之后还在锁里
/// 用纯 Dart 把 1080p 帧编成 JPEG（几百毫秒），排在它后面的 `play()` / `pause()` 要等
/// 编码跑完才轮到。补丁只让取原始帧持锁，编码在锁外的辅助 isolate 上跑。
///
/// 判据：截帧请求之后立刻排一个走同一把锁的 `pause()`，它必须先于截帧完成——修前它
/// 排在编码后面，必然后完成。
///
/// 需要真实 libmpv 与 ffmpeg（生成样片）：`FUSHI_TEST_LIBMPV`（libmpv-2.dll）与
/// `FUSHI_TEST_FFMPEG`，缺一个就跳过。
String? _existing(String? path) =>
    path != null && File(path).existsSync() ? File(path).absolute.path : null;

void main() {
  final String? libmpv = _existing(Platform.environment['FUSHI_TEST_LIBMPV']);
  final String? ffmpeg = _existing(Platform.environment['FUSHI_TEST_FFMPEG']);
  final String? skip = libmpv == null || ffmpeg == null
      ? 'Set FUSHI_TEST_LIBMPV (libmpv-2.dll) and FUSHI_TEST_FFMPEG'
      : null;

  setUpAll(() {
    if (libmpv != null) MediaKit.ensureInitialized(libmpv: libmpv);
  });

  test(
    'a lock-queued pause() is not held behind the screenshot encode',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'screenshot-lock-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final String fixture = p.join(temp.path, 'v.mkv');
      final ProcessResult made = await Process.run(ffmpeg!, <String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=1920x1080:rate=24:duration=5',
        '-c:v',
        'libx264',
        '-preset',
        'ultrafast',
        fixture,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');

      final Player player = Player();
      addTearDown(player.dispose);
      final dynamic native = player.platform;
      await native.setProperty('vo', 'null');
      await native.setProperty('ao', 'null');
      await player.open(Media(fixture), play: false);
      // 不挂 VideoController 时 media_kit 让 vid=no，没有解码帧可截。
      await native.setProperty('vid', '1');

      // 等首帧解码出来（screenshot-raw 有帧才返回 map）。
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
      while (await player.screenshot(format: null) == null) {
        if (DateTime.now().isAfter(deadline)) fail('no decoded frame');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final Uint8List? raw = await player.screenshot(format: null);
      expect(
        raw!.length,
        greaterThanOrEqualTo(1920 * 1080 * 4),
        reason: 'format: null 仍返回整帧 BGRA',
      );

      final List<String> order = <String>[];
      final Future<Uint8List?> shot = player
          .screenshot(format: 'image/jpeg')
          .then((Uint8List? bytes) {
            order.add('screenshot');
            return bytes;
          });
      final Future<void> paused = player.pause().then((_) {
        order.add('pause');
      });
      final Uint8List? jpeg = await shot;
      await paused;

      expect(jpeg, isNotNull);
      expect(jpeg!.sublist(0, 2), <int>[0xFF, 0xD8], reason: '编出来的是 JPEG');
      expect(order, <String>[
        'pause',
        'screenshot',
      ], reason: '排在截帧后面的 pause() 只该等取帧，不该等 JPEG 编码');
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // `image/x-fushi-bgra`（智能遮布）落在 BUG-4910 拆开后的取帧 isolate 上：变换对
  // mpv node 的视图就地裁剪，产出原样返回（不是整帧、不是 JPEG），持锁 / 不持锁两条
  // 路径都一样；缺变换是参数错误。
  test(
    'image/x-fushi-bgra returns the transform output from the capture isolate',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'screenshot-bgra-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final String fixture = p.join(temp.path, 'v.mkv');
      final ProcessResult made = await Process.run(ffmpeg!, <String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=640x360:rate=24:duration=2',
        '-c:v',
        'libx264',
        '-preset',
        'ultrafast',
        fixture,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');

      final Player player = Player();
      addTearDown(player.dispose);
      final dynamic native = player.platform;
      await native.setProperty('vo', 'null');
      await native.setProperty('ao', 'null');
      await player.open(Media(fixture), play: false);
      await native.setProperty('vid', '1');

      final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
      while (await player.screenshot(format: null) == null) {
        if (DateTime.now().isAfter(deadline)) fail('no decoded frame');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      expect(
        () => native.screenshot(format: kRawVideoFrameFormat),
        throwsArgumentError,
        reason: 'x-fushi-bgra 必须带 fushiRawTransform',
      );

      for (final bool synchronized in <bool>[true, false]) {
        final Object? bytes = await native.screenshot(
          format: kRawVideoFrameFormat,
          synchronized: synchronized,
          fushiRawTransform: rawVideoFrameCropTransform(
            const Rect.fromLTRB(0.25, 0.5, 0.75, 1),
          ),
        );
        final RawVideoFrameCrop? crop = parseRawVideoFrameCrop(
          bytes as Uint8List?,
        );
        expect(crop, isNotNull, reason: 'synchronized=$synchronized');
        expect(crop!.frameWidth, 640);
        expect(crop.frameHeight, 360);
        expect(crop.left, 160);
        expect(crop.top, 180);
        expect(crop.width, 320);
        expect(crop.height, 180);
        expect(
          bytes!.length,
          kRawVideoFrameCropHeaderBytes + 320 * 180 * 4,
          reason: '只传回裁剪，不是整帧',
        );
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
