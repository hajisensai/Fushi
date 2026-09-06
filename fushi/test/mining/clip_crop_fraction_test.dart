// BUG-2192：网飞录屏片段裁掉播放器黑边。
//
// 扩展在录制那一刻按 <video> 几何算出「可见视频画面占视口的比例矩形」随 mineClip 上 wire；
// 服务端解析成 [ClipCropFraction]，在 ffmpeg 抽动图/静帧的滤镜链最前面插一段 crop。
// 这里钉住：payload 解析（容错：坏输入 → null，不让整张卡 400）、crop 滤镜串形状（偶数
// 宽高）、两条 ffmpeg 参数构造里 crop 必须排在 scale/fps 之前（先裁后缩）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/immersion_mining_request.dart';
import 'package:fushi/src/sync/immersion_mine_payload.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart';

void main() {
  group('ClipCropFraction.fromJson', () {
    test('合法对象解析；越界/缺分量/非对象 → null', () {
      final ClipCropFraction? ok = ClipCropFraction.fromJson(
          <String, Object?>{'x': 0.0556, 'y': 0, 'w': 0.8889, 'h': 1});
      expect(ok, isNotNull);
      expect(ok!.x, 0.0556);
      expect(ok.h, 1.0);
      expect(ClipCropFraction.fromJson(null), isNull);
      expect(ClipCropFraction.fromJson('x'), isNull);
      expect(
          ClipCropFraction.fromJson(<String, Object?>{'x': 0, 'y': 0}), isNull);
      expect(
          ClipCropFraction.fromJson(
              <String, Object?>{'x': -0.1, 'y': 0, 'w': 0.5, 'h': 0.5}),
          isNull);
      expect(
          ClipCropFraction.fromJson(
              <String, Object?>{'x': 0.6, 'y': 0, 'w': 0.5, 'h': 0.5}),
          isNull,
          reason: 'x + w > 1 越界');
      expect(
          ClipCropFraction.fromJson(
              <String, Object?>{'x': 0, 'y': 0, 'w': 0, 'h': 0.5}),
          isNull,
          reason: '零宽');
    });

    test('ffmpegFilter：先裁再缩、宽高截偶数', () {
      const ClipCropFraction c =
          ClipCropFraction(x: 0.0556, y: 0, w: 0.8889, h: 1);
      expect(c.ffmpegFilter,
          'crop=trunc(iw*0.8889/2)*2:trunc(ih*1.0000/2)*2:trunc(iw*0.0556):trunc(ih*0.0000)');
    });
  });

  test('ImmersionMinePayload 透传 clipCrop；缺失/坏值 → null', () {
    final ImmersionMinePayload p =
        ImmersionMinePayload.fromJson(<String, dynamic>{
      'fields': <String, String>{'expression': '鼠'},
      'clipCrop': <String, Object?>{'x': 0.1, 'y': 0.2, 'w': 0.5, 'h': 0.6},
    });
    expect(p.clipCrop, isNotNull);
    expect(p.clipCrop!.w, 0.5);
    final ImmersionMinePayload none =
        ImmersionMinePayload.fromJson(<String, dynamic>{
      'fields': <String, String>{'expression': '鼠'}
    });
    expect(none.clipCrop, isNull);
    final ImmersionMinePayload bad =
        ImmersionMinePayload.fromJson(<String, dynamic>{
      'fields': <String, String>{'expression': '鼠'},
      'clipCrop': 'nope',
    });
    expect(bad.clipCrop, isNull);
  });

  group('ffmpeg 参数：crop 排在 scale/fps 之前', () {
    test('buildFfmpegFrameArgs', () {
      final List<String> args = buildFfmpegFrameArgs(
        inputPath: 'clip.webm',
        outputPath: 'f.jpg',
        cropFilter: 'crop=1:2:3:4',
        scaleWidth: 640,
      );
      final int vf = args.indexOf('-vf');
      expect(vf, greaterThan(0));
      expect(args[vf + 1], 'crop=1:2:3:4,scale=640:-2');
      // 无 crop 时逐字不变。
      final List<String> plain = buildFfmpegFrameArgs(
          inputPath: 'clip.webm', outputPath: 'f.jpg', scaleWidth: 640);
      expect(plain[plain.indexOf('-vf') + 1], 'scale=640:-2');
      final List<String> none =
          buildFfmpegFrameArgs(inputPath: 'clip.webm', outputPath: 'f.jpg');
      expect(none.contains('-vf'), isFalse);
    });

    test('buildFfmpegClipAnimatedArgs（gif filter_complex 与 -vf 单链）', () {
      final List<String> gif = buildFfmpegClipAnimatedArgs(
        format: MiningAnimatedFormat.gif,
        inputPath: 'clip.webm',
        startMs: 0,
        endMs: 3000,
        outputPath: 'c.gif',
        fps: 10,
        width: 480,
        cropFilter: 'crop=1:2:3:4',
      );
      final String chain = gif[gif.indexOf('-filter_complex') + 1];
      expect(
          chain, startsWith('crop=1:2:3:4,fps=10,scale=480:-2:flags=lanczos,'));
      final List<String> webp = buildFfmpegClipAnimatedArgs(
        format: MiningAnimatedFormat.webp,
        inputPath: 'clip.webm',
        startMs: 0,
        endMs: 3000,
        outputPath: 'c.webp',
        fps: 10,
        width: 480,
        cropFilter: 'crop=1:2:3:4',
      );
      expect(webp[webp.indexOf('-vf') + 1],
          'crop=1:2:3:4,fps=10,scale=480:-2:flags=lanczos');
    });
  });
}
