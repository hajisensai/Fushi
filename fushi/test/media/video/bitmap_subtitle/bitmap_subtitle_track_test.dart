// 位图字幕整轨管线（编码无关）：编码识别、轨头（ffprobe extradata）、抽轨参数（PGS→sup、
// 其它→mpegts）、远端输入的请求头、抽轨编排（探测 → 写头 → 观察式抽取）、边抽边读解码，
// 以及入库的 Windows 精简 ffmpeg / ffprobe 对真编码器产出的 VobSub / DVB 样本跑通全链路。
//
// 样本（test/fixtures/video/）由完整版 ffmpeg 的 dvdsub / dvbsub **编码器**产出（不是本仓的
// 手工码流），再用完整版的解码器叠到黑底上取像素真值：
//   ffmpeg -i <手工 DVB mkv> -map 0:s:0 -c:s dvdsub -s 1920x1080 dvdsub_one_cue.mkv
//   ffmpeg -i <手工 VobSub mkv> -map 0:s:0 -c:s dvbsub dvbsub_two_cues.mkv
//   ffmpeg -i <手工 VobSub mkv> -map 0:s:0 -c:s dvbsub -f mpegts dvbsub_two_cues.ts
// 手工 mkv 见 bitmap_subtitle_fixtures.dart（buildSubtitleMatroska）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_track.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/dvd_subtitle_decoder.dart';
import 'package:fushi/src/media/video/graphic_subtitle_track_ocr.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_regions.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/unified_ffmpeg.dart';
import 'bitmap_subtitle_fixtures.dart';

/// ffprobe `-show_streams -show_data -of json` 对手工 VobSub mkv 的真实输出（节选）。
const String _vobSubProbeJson = r'''
{
    "streams": [
        {
            "index": 0,
            "codec_name": "dvd_subtitle",
            "codec_type": "subtitle",
            "extradata": "\n00000000: 2320 566f 6253 7562 2069 6e64 6578 2066  # VobSub index f\n00000010: 696c 652c 2076 3720 2864 6f20 6e6f 7420  ile, v7 (do not \n00000020: 6d6f 6469 6679 2074 6869 7320 6c69 6e65  modify this line\n00000030: 2129 0a73 697a 653a 2037 3230 7834 3830  !).size: 720x480\n00000040: 0a70 616c 6574 7465 3a20 3030 3030 3030  .palette: 000000\n00000050: 2c20 6666 6666 6666 2c20 3830 3830 3830  , ffffff, 808080\n00000060: 2c20 3230 3230 3230 2c20 3430 3430 3430  , 202020, 404040\n00000070: 2c20 3530 3530 3530 2c20 3630 3630 3630  , 505050, 606060\n00000080: 2c20 3730 3730 3730 2c20 3830 3830 3830  , 707070, 808080\n00000090: 2c20 3930 3930 3930 2c20 6130 6130 6130  , 909090, a0a0a0\n000000a0: 2c20 6230 6230 6230 2c20 6330 6330 6330  , b0b0b0, c0c0c0\n000000b0: 2c20 6430 6430 6430 2c20 6530 6530 6530  , d0d0d0, e0e0e0\n000000c0: 2c20 6630 6630 6630 0a                   , f0f0f0.\n",
            "extradata_size": 201
        }
    ]
}
''';

/// 假后端：探测回 [probe]；观察式抽取往载荷路径写 [payload]。记下全部参数。
class _ScriptedBackend implements FfmpegBackend, FfmpegWatchedRunner {
  _ScriptedBackend({required this.probe, required this.payload});

  final FfmpegRunResult probe;
  final Uint8List payload;
  List<String>? probeArgs;
  List<String>? args;

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async {
    probeArgs = args;
    return probe;
  }

  @override
  Future<FfmpegRunResult> runWatched(
    List<String> args,
    FfmpegWatch watch,
  ) async {
    this.args = args;
    final int f = args.indexOf('-f');
    File(args[f + 2]).writeAsBytesSync(payload);
    return const FfmpegRunResult(returnCode: 0, output: '');
  }

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) =>
      throw StateError('观察式后端不走 run');

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      throw UnimplementedError();
}

/// 直接起随包统一 FFmpeg（ffmpeg / ffprobe）。
class _BinaryBackend implements FfmpegBackend {
  _BinaryBackend(this.ffmpeg, this.ffprobe);

  final String ffmpeg;
  final String ffprobe;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    final ProcessResult r = await Process.run(
      ffmpeg,
      <String>['-hide_banner', '-loglevel', 'error', ...args],
    ).timeout(timeout);
    return FfmpegRunResult(returnCode: r.exitCode, output: '${r.stderr}');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async {
    final ProcessResult r = await Process.run(
      ffprobe,
      args,
    ).timeout(timeout);
    return FfmpegRunResult(returnCode: r.exitCode, output: '${r.stdout}');
  }

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);
}

/// 渲染图里非黑像素的外包框，换回画布坐标（右 / 下开区间）。
Rect _visibleBox(BitmapSubtitleCue cue) {
  const int pad = 4;
  final BitmapSubtitleImage image = cue.renderRgba(padding: pad);
  int l = 1 << 30, t = 1 << 30, r = -1, b = -1;
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final int o = (y * image.width + x) * 4;
      if (image.rgba[o] + image.rgba[o + 1] + image.rgba[o + 2] > 30) {
        if (x < l) l = x;
        if (y < t) t = y;
        if (x > r) r = x;
        if (y > b) b = y;
      }
    }
  }
  final int ox = cue.bounds.left - pad;
  final int oy = cue.bounds.top - pad;
  return Rect.fromLTRB(
    (l + ox).toDouble(),
    (t + oy).toDouble(),
    (r + 1 + ox).toDouble(),
    (b + 1 + oy).toDouble(),
  );
}

void main() {
  group('编码与轨头', () {
    test('codec 名 → 编码；抽轨容器 PGS 走 sup、其它走 mpegts', () {
      expect(
        bitmapSubtitleCodecOf('hdmv_pgs_subtitle'),
        BitmapSubtitleCodec.pgs,
      );
      expect(bitmapSubtitleCodecOf('S_HDMV/PGS'), BitmapSubtitleCodec.pgs);
      expect(bitmapSubtitleCodecOf('dvd_subtitle'), BitmapSubtitleCodec.dvd);
      expect(bitmapSubtitleCodecOf('S_VOBSUB'), BitmapSubtitleCodec.dvd);
      expect(bitmapSubtitleCodecOf('dvb_subtitle'), BitmapSubtitleCodec.dvb);
      expect(bitmapSubtitleCodecOf('S_DVBSUB'), BitmapSubtitleCodec.dvb);
      expect(bitmapSubtitleCodecOf('dvb_teletext'), isNull);
      expect(BitmapSubtitleCodec.pgs.muxer, 'sup');
      expect(BitmapSubtitleCodec.dvd.muxer, 'mpegts');
      expect(BitmapSubtitleCodec.dvb.muxer, 'mpegts');
    });

    test('轨头 JSON 往返；坏头当没有', () {
      final BitmapSubtitleTrackHeader h = BitmapSubtitleTrackHeader(
        codec: BitmapSubtitleCodec.dvd,
        extradata: Uint8List.fromList(<int>[1, 2, 3]),
        width: 720,
        height: 576,
      );
      final BitmapSubtitleTrackHeader back = BitmapSubtitleTrackHeader.fromJson(
        jsonDecode(jsonEncode(h.toJson())),
      )!;
      expect(back.codec, BitmapSubtitleCodec.dvd);
      expect(back.extradata, <int>[1, 2, 3]);
      expect((back.width, back.height), (720, 576));
      expect(
        BitmapSubtitleTrackHeader.fromJson(<String, Object?>{'codec': 'srt'}),
        isNull,
      );
      expect(BitmapSubtitleTrackHeader.fromJson('x'), isNull);
    });

    test('ffprobe JSON → 轨头：十六进制转储只取数据区，ASCII 列不混进来', () {
      String? name;
      final BitmapSubtitleTrackHeader h = parseBitmapSubtitleProbe(
        'some log line\n$_vobSubProbeJson',
        codecName: (String? n) => name = n,
      )!;
      expect(name, 'dvd_subtitle');
      expect(h.codec, BitmapSubtitleCodec.dvd);
      expect(h.extradata, hasLength(201));
      final VobSubHeader idx = VobSubHeader.parse(h.extradata);
      expect((idx.width, idx.height), (720, 480));
      expect(idx.palette![15], 0xF0F0F0);
    });

    test('ffprobe JSON：文字字幕 / 没有流 → null，并报出探到的编码', () {
      String? name;
      expect(
        parseBitmapSubtitleProbe(
          '{"streams":[{"codec_name":"subrip"}]}',
          codecName: (String? n) => name = n,
        ),
        isNull,
      );
      expect(name, 'subrip');
      expect(parseBitmapSubtitleProbe('{"streams":[]}'), isNull);
      expect(parseBitmapSubtitleProbe('garbage'), isNull);
    });
  });

  group('输入与参数', () {
    test('本地 / 远端 / 不支持的 scheme', () {
      expect(const GraphicSubtitleInput.local('/v/a.mkv').isSupported, isTrue);
      expect(
        const GraphicSubtitleInput.local(r'C:\v\a.mkv').isSupported,
        isTrue,
      );
      expect(const GraphicSubtitleInput(uri: 'https://h/a.mkv').isRemote, true);
      expect(
        const GraphicSubtitleInput(uri: 'anime-source://x').isSupported,
        isFalse,
      );
    });

    test('VobSub / DVB 抽成单轨 TS，带 -muxdelay 0（否则 PTS 整体 +1.4 s）', () {
      final List<String> args = buildGraphicSubtitleExtractArgs(
        input: const GraphicSubtitleInput.local('/v/a.mkv'),
        streamIndex: 1,
        outputPath: '/t/track.ts',
        codec: BitmapSubtitleCodec.dvd,
      );
      expect(args, <String>[
        '-y',
        '-i',
        '/v/a.mkv',
        '-map',
        '0:s:1',
        '-c',
        'copy',
        '-muxdelay',
        '0',
        '-muxpreload',
        '0',
        '-f',
        'mpegts',
        '/t/track.ts',
        '-map',
        '0:v:0?',
        '-map',
        '0:s:1',
        '-c',
        'copy',
        '-f',
        'null',
        '-',
      ]);
    });

    test('远端输入：会话请求头 / UA / Referer 在 -i 之前，ffmpeg 与 ffprobe 同一套', () {
      const GraphicSubtitleInput remote = GraphicSubtitleInput(
        uri: 'https://cdn.example/v.mkv',
        headers: <String, String>{
          'User-Agent': 'UA/1',
          'Referer': 'https://site.example/',
          'Cookie': 'sid=1',
          'X-Bad': 'a\r\nHost: evil',
        },
      );
      for (final List<String> args in <List<String>>[
        buildGraphicSubtitleExtractArgs(
          input: remote,
          streamIndex: 0,
          outputPath: '/t/x.ts',
          codec: BitmapSubtitleCodec.dvb,
        ),
        buildGraphicSubtitleProbeArgs(input: remote, streamIndex: 0),
      ]) {
        final int input = args.indexOf('-i');
        expect(args[input + 1], 'https://cdn.example/v.mkv');
        final List<String> before = args.sublist(0, input);
        expect(before[before.indexOf('-user_agent') + 1], 'UA/1');
        expect(before[before.indexOf('-referer') + 1], 'https://site.example/');
        expect(before[before.indexOf('-headers') + 1], 'Cookie: sid=1\r\n');
        expect(before, contains('-reconnect'));
      }
      // 本地输入不带任何网络参数。
      expect(
        buildGraphicSubtitleProbeArgs(
          input: const GraphicSubtitleInput.local('/v/a.mkv'),
          streamIndex: 3,
        ),
        <String>[
          '-v',
          'error',
          '-print_format',
          'json',
          '-show_streams',
          '-show_data',
          '-select_streams',
          's:3',
          '-i',
          '/v/a.mkv',
        ],
      );
    });
  });

  group('抽轨编排', () {
    late Directory dir;
    late File video;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('fushi_bitmap_track_');
      video = File(p.join(dir.path, 'v.mkv'))..writeAsBytesSync(<int>[0]);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Uint8List spuTs() => buildSubtitleTs(<(int, Uint8List)>[
      (
        90000,
        buildSpuPacket(
          x: 100,
          y: 400,
          pixels: <List<int>>[
            for (int y = 0; y < 6; y++) <int>[for (int x = 0; x < 20; x++) 1],
          ],
          stopDelay: 176,
        ),
      ),
    ]);

    test('VobSub：先探测 extradata 写进头文件，再抽 TS；读回的 cue 用上调色板与画布', () async {
      final _ScriptedBackend backend = _ScriptedBackend(
        probe: const FfmpegRunResult(returnCode: 0, output: _vobSubProbeJson),
        payload: spuTs(),
      );
      final String out = p.join(dir.path, 'track.bin');
      final bool ok = await extractGraphicSubtitleTrack(
        input: GraphicSubtitleInput.local(video.path),
        streamIndex: 0,
        outputPath: out,
        backend: backend,
      );
      expect(ok, isTrue);
      expect(backend.probeArgs, contains('-show_data'));
      expect(backend.args, containsAllInOrder(<String>['-f', 'mpegts', out]));
      final List<BitmapSubtitleCue> cues =
          await readGraphicSubtitleTrackInBackground(out, complete: true);
      expect(cues, hasLength(1));
      expect((cues.single.startMs, cues.single.endMs), (1000, 3002));
      expect((cues.single.canvasWidth, cues.single.canvasHeight), (720, 480));
      // 下标 1 → idx palette[1] = 白。
      final BitmapSubtitleImage image = cues.single.renderRgba(padding: 0);
      expect(image.rgba.sublist(0, 3), <int>[255, 255, 255]);
      // 历史入口同一条路。
      expect(await readGraphicSubtitleSupInBackground(out), hasLength(1));
    });

    test('探测明确是文字字幕：不抽，报出编码', () async {
      final _ScriptedBackend backend = _ScriptedBackend(
        probe: const FfmpegRunResult(
          returnCode: 0,
          output: '{"streams":[{"codec_name":"subrip"}]}',
        ),
        payload: Uint8List(0),
      );
      final List<String> failures = <String>[];
      final bool ok = await extractGraphicSubtitleTrack(
        input: GraphicSubtitleInput.local(video.path),
        streamIndex: 0,
        outputPath: p.join(dir.path, 'track.bin'),
        codec: 'dvd_subtitle',
        onFailure: failures.add,
        backend: backend,
      );
      expect(ok, isFalse);
      expect(backend.args, isNull);
      expect(failures.single, contains('subrip'));
    });

    test('探测失败但已知是 VobSub：照抽（少了调色板，按灰阶猜）', () async {
      final _ScriptedBackend backend = _ScriptedBackend(
        probe: const FfmpegRunResult(returnCode: 1, output: ''),
        payload: spuTs(),
      );
      final String out = p.join(dir.path, 'track.bin');
      expect(
        await extractGraphicSubtitleTrack(
          input: GraphicSubtitleInput.local(video.path),
          streamIndex: 0,
          outputPath: out,
          codec: 'dvd_subtitle',
          backend: backend,
        ),
        isTrue,
      );
      final List<BitmapSubtitleCue> cues =
          await readGraphicSubtitleTrackInBackground(out, complete: true);
      expect(cues.single.canvasWidth, 0);
    });

    test('探测失败且不知道编码：失败，不抽', () async {
      final _ScriptedBackend backend = _ScriptedBackend(
        probe: const FfmpegRunResult(returnCode: 1, output: 'no such file'),
        payload: Uint8List(0),
      );
      final List<String> failures = <String>[];
      expect(
        await extractGraphicSubtitleTrack(
          input: GraphicSubtitleInput.local(video.path),
          streamIndex: 0,
          outputPath: p.join(dir.path, 'track.bin'),
          onFailure: failures.add,
          backend: backend,
        ),
        isFalse,
      );
      expect(backend.args, isNull);
      expect(failures.single, contains('probe'));
    });

    test('远端输入不查本地文件，地址原样交给 ffmpeg', () async {
      final _ScriptedBackend backend = _ScriptedBackend(
        probe: const FfmpegRunResult(returnCode: 0, output: _vobSubProbeJson),
        payload: spuTs(),
      );
      expect(
        await extractGraphicSubtitleTrack(
          input: const GraphicSubtitleInput(uri: 'http://nas.local/v.mkv'),
          streamIndex: 0,
          outputPath: p.join(dir.path, 'track.bin'),
          backend: backend,
        ),
        isTrue,
      );
      expect(
        backend.args,
        containsAllInOrder(<String>['-i', 'http://nas.local/v.mkv']),
      );
    });

    test('没有头文件的旧式 .sup 按内容认成 PGS；认不出的当空', () async {
      final String junk = p.join(dir.path, 'junk.bin');
      File(junk).writeAsBytesSync(<int>[1, 2, 3]);
      expect(await readGraphicSubtitleTrackInBackground(junk), isEmpty);
      expect(
        await readGraphicSubtitleTrackInBackground(p.join(dir.path, 'none')),
        isEmpty,
      );
    });
  });

  group('随包统一 FFmpeg（ffmpeg / ffprobe） × 真编码器样本', () {
    final UnifiedFfmpegForTests? unified =
        resolveBundledUnifiedFfmpegForTests();
    final Object skip = unified != null
        ? false
        : '找不到随包统一 FFmpeg（ffmpeg + ffprobe）';
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('fushi_bitmap_bin_'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<List<BitmapSubtitleCue>> extract(String fixture) async {
      final String out = p.join(dir.path, 'track.bin');
      final List<String> failures = <String>[];
      final bool ok = await extractGraphicSubtitleTrack(
        input: GraphicSubtitleInput.local('test/fixtures/video/$fixture'),
        streamIndex: 0,
        outputPath: out,
        onFailure: failures.add,
        backend: _BinaryBackend(unified!.ffmpeg, unified.ffprobe),
      );
      expect(ok, isTrue, reason: failures.join('\n'));
      return readGraphicSubtitleTrackInBackground(out, complete: true);
    }

    test('dvdsub 编码器产出的 VobSub mkv：探测 → TS 抽轨 → SPU 解码', () async {
      final List<BitmapSubtitleCue> cues = await extract('dvdsub_one_cue.mkv');
      expect(cues, hasLength(1));
      final BitmapSubtitleCue cue = cues.single;
      expect(cue, isA<DvdSubtitleCue>());
      expect(cue.startMs, 2000);
      expect(cue.endMs, inInclusiveRange(3980, 4010));
      expect((cue.canvasWidth, cue.canvasHeight), (1920, 1080));
      // 完整版 ffmpeg 解码器叠黑底的非黑像素框：(112, 906)–(157, 923) 含端点。
      expect(_visibleBox(cue), const Rect.fromLTRB(112, 906, 158, 924));
    }, skip: skip);

    test('dvbsub 编码器产出的 DVB mkv：两句、清屏集收尾、DDS 画布', () async {
      final List<BitmapSubtitleCue> cues = await extract('dvbsub_two_cues.mkv');
      expect(
        cues.map((BitmapSubtitleCue c) => (c.startMs, c.endMs)),
        <(int, int)>[(1000, 3002), (5000, 6001)],
      );
      expect((cues.first.canvasWidth, cues.first.canvasHeight), (720, 480));
      expect(_visibleBox(cues[0]), const Rect.fromLTRB(102, 401, 138, 409));
      expect(_visibleBox(cues[1]), const Rect.fromLTRB(202, 411, 228, 417));
    }, skip: skip);

    test('DVB 广播式 TS 源：时间轴归零到容器起点，两句间隔不变', () async {
      final List<BitmapSubtitleCue> cues = await extract('dvbsub_two_cues.ts');
      expect(cues, hasLength(2));
      expect(cues[1].startMs - cues[0].startMs, 4000);
      expect(cues[0].endMs - cues[0].startMs, inInclusiveRange(1990, 2010));
      expect(_visibleBox(cues[0]), const Rect.fromLTRB(102, 401, 138, 409));
    }, skip: skip);

    test('位图时间表加载器对 VobSub 跑通（模糊遮蔽 / 制卡时间表同一来源）', () async {
      final FfmpegGraphicSubtitleRegionLoader loader =
          FfmpegGraphicSubtitleRegionLoader(
            cacheDir: Directory(p.join(dir.path, 'cache')),
            backend: _BinaryBackend(unified!.ffmpeg, unified.ffprobe),
          );
      final GraphicSubtitleRegionTrack? track = await loader.load(
        graphicSubtitleRegionRequestFor(
          videoPath: 'test/fixtures/video/dvdsub_one_cue.mkv',
          track: (streamIndex: 0, codec: 'dvd_subtitle'),
        )!,
        fallbackCanvas: const Size(640, 360),
      );
      expect(track, isNotNull);
      expect(track!.canvas, const Size(1920, 1080));
      expect(track.regions, hasLength(1));
      expect(track.regions.single.startMs, 2000);
      expect(
        track.regions.single.rect.contains(const Offset(130, 915)),
        isTrue,
      );
    }, skip: skip);
  });
}
