import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/player_decoded_subtitle_cues.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_regions.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_cue.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_track.dart'
    show bitmapSubtitleTrackHeaderPath;
import 'package:fushi_engine/media/video/bitmap_subtitle/graphic_subtitle_track_extract.dart'
    show readGraphicSubtitleTrackInBackground;
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

/// 远端播放（互联 host / 媒体服务器 / 通用 http / 在线源）的图形字幕逐句时间表。
///
/// 1. 边播边记：libmpv `sub-start` / `sub-end`（位图驱动 `sd_lavc` 的 `get_times`）
///    每显示一句记一句——任何来源、任何位图编码都成立；
/// 2. 整轨来源：互联 host 回传整轨 / 网络流 URL + 请求头抽取 / 本地文件；到了以后
///    以它为准，边播边记只补它没有的句子。
///
/// 宿主无 libmpv：边播边记经测试钩子喂 mpv 原始秒值，走与真实采样同一条落地函数。
AudioCue _timing(int start, int end) => AudioCue()
  ..bookKey = ''
  ..chapterHref = ''
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = ''
  ..startMs = start
  ..endMs = end
  ..audioFileIndex = 0;

VideoPlayerController _graphicController({
  int streamIndex = 2,
  String codec = 'hdmv_pgs_subtitle',
}) => VideoPlayerController()
  ..debugSetGraphicSubtitleActiveForTesting(
    true,
    streamIndex: streamIndex,
    codec: codec,
  );

void main() {
  group('mergeGraphicSubtitleLiveTiming（边播边记合一句）', () {
    test('新起点按序插入、无文字、按位置重排序号', () {
      final ({List<AudioCue> cues, AudioCue cue, bool changed, bool inserted})
      a = mergeGraphicSubtitleLiveTiming(
        const <AudioCue>[],
        startMs: 5000,
        endMs: 7000,
      );
      final ({List<AudioCue> cues, AudioCue cue, bool changed, bool inserted})
      b = mergeGraphicSubtitleLiveTiming(a.cues, startMs: 1000, endMs: 3000);
      expect(b.inserted, isTrue);
      expect(
        b.cues.map((AudioCue c) => (c.sentenceIndex, c.startMs, c.endMs)),
        <(int, int, int)>[(0, 1000, 3000), (1, 5000, 7000)],
      );
      expect(b.cues.every((AudioCue c) => c.text.isEmpty), isTrue);
    });

    test('结束未知 → 暂定时长；同一句的真实结束到了原地改（对象不换）', () {
      final ({List<AudioCue> cues, AudioCue cue, bool changed, bool inserted})
      a = mergeGraphicSubtitleLiveTiming(
        const <AudioCue>[],
        startMs: 1000,
        endMs: null,
      );
      expect(a.cue.endMs, 1000 + kPlayerDecodedCueProvisionalMs);
      final ({List<AudioCue> cues, AudioCue cue, bool changed, bool inserted})
      b = mergeGraphicSubtitleLiveTiming(a.cues, startMs: 1000, endMs: 2400);
      expect(b.changed, isTrue);
      expect(b.inserted, isFalse);
      expect(identical(b.cue, a.cue), isTrue, reason: '制卡流按身份认 cue');
      expect(a.cue.endMs, 2400);
    });

    test('同一句重复上报、结束仍未知 / 相同 → 不动', () {
      final ({List<AudioCue> cues, AudioCue cue, bool changed, bool inserted})
      a = mergeGraphicSubtitleLiveTiming(
        const <AudioCue>[],
        startMs: 1000,
        endMs: 2000,
      );
      expect(
        mergeGraphicSubtitleLiveTiming(
          a.cues,
          startMs: 1000,
          endMs: null,
        ).changed,
        isFalse,
        reason: 'seek 回看时结束段可能还没解码，不能把真实结束覆盖成暂定',
      );
      expect(
        mergeGraphicSubtitleLiveTiming(
          a.cues,
          startMs: 1000,
          endMs: 2000,
        ).changed,
        isFalse,
      );
      expect(a.cue.endMs, 2000);
    });
  });

  group('mergeGraphicSubtitleTimingTables（整轨抽取为准）', () {
    test('还没有抽取结果 → 边播边记就是整张表', () {
      final List<AudioCue> live = <AudioCue>[_timing(1000, 2000)];
      final List<AudioCue> merged = mergeGraphicSubtitleTimingTables(
        extracted: const <AudioCue>[],
        live: live,
      );
      expect(identical(merged.single, live.single), isTrue);
    });

    test('抽取结果到了：重叠的边播边记句让位，不重叠的补进来，对象原样复用', () {
      final AudioCue e1 = _timing(1000, 3000);
      final AudioCue e2 = _timing(8000, 9000);
      final AudioCue liveSame = _timing(1000, 6000); // 暂定时长的同一句
      final AudioCue liveOverlap = _timing(2500, 3500);
      final AudioCue liveGap = _timing(5000, 6000); // 抽取解析丢掉的一句
      final List<AudioCue> merged = mergeGraphicSubtitleTimingTables(
        extracted: <AudioCue>[e1, e2],
        live: <AudioCue>[liveSame, liveOverlap, liveGap],
      );
      expect(merged.length, 3);
      expect(identical(merged[0], e1), isTrue);
      expect(identical(merged[1], liveGap), isTrue);
      expect(identical(merged[2], e2), isTrue);
      expect(merged.map((AudioCue c) => c.sentenceIndex), <int>[0, 1, 2]);
    });
  });

  group('VideoPlayerController 边播边记（mpv sub-start / sub-end）', () {
    test('非图形模式不记', () {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      expect(
        c.debugAcceptGraphicLiveTimingForTesting(
          rawStart: '1.000000',
          rawEnd: '2.000000',
        ),
        isFalse,
      );
      expect(c.graphicSubtitleTimingCues, isEmpty);
    });

    test('每显示一句记一句：制卡流 / 调轴 / 所属流全认它', () {
      final VideoPlayerController c = _graphicController()
        ..setSecondaryCues(<AudioCue>[
          AudioCue()
            ..bookKey = ''
            ..chapterHref = ''
            ..sentenceIndex = 0
            ..textFragmentId = ''
            ..text = 'sec'
            ..startMs = 0
            ..endMs = 99999
            ..audioFileIndex = 0,
        ]);
      addTearDown(c.dispose);
      int notified = 0;
      c.addListener(() => notified++);
      expect(
        c.debugAcceptGraphicLiveTimingForTesting(
          rawStart: '12.040000',
          rawEnd: '14.500000',
        ),
        isTrue,
      );
      c.debugAcceptGraphicLiveTimingForTesting(
        rawStart: '3.000000',
        rawEnd: '4.200000',
      );
      expect(notified, 2);
      c.setDelayMs(250);
      c.setSecondaryDelayMs(-2000);
      expect(
        c.miningCues.map((AudioCue x) => (x.startMs, x.endMs)),
        <(int, int)>[(3000, 4200), (12040, 14500)],
      );
      expect(c.miningDelayMs, 250);
      expect(c.delayMsForCue(c.miningCues.first), 250);
      expect(c.cueStreamOwning(c.miningCues.last).length, 2);
    });

    test('mpv 还没给 sub-end：暂定时长，下一句出现时按 mpv 规则夹到下一句起点', () {
      final VideoPlayerController c = _graphicController();
      addTearDown(c.dispose);
      c.debugAcceptGraphicLiveTimingForTesting(
        rawStart: '10.000000',
        rawEnd: '',
      );
      final AudioCue first = c.graphicSubtitleTimingCues.single;
      expect(first.endMs, 10000 + kPlayerDecodedCueProvisionalMs);
      c.debugAcceptGraphicLiveTimingForTesting(
        rawStart: '12.300000',
        rawEnd: '',
      );
      expect(first.endMs, 12300, reason: 'sd_lavc：prev->endpts = 下一句 pts');
      // 同一句的结束段解码出来了：原地改成真实结束。
      c.debugAcceptGraphicLiveTimingForTesting(
        rawStart: '12.300000',
        rawEnd: '13.100000',
      );
      expect(
        c.graphicSubtitleTimingCues.map((AudioCue x) => (x.startMs, x.endMs)),
        <(int, int)>[(10000, 12300), (12300, 13100)],
      );
    });

    test('画面上没有字幕（mpv 无 sub-start）→ 不记', () {
      final VideoPlayerController c = _graphicController();
      addTearDown(c.dispose);
      expect(
        c.debugAcceptGraphicLiveTimingForTesting(rawStart: '', rawEnd: ''),
        isFalse,
      );
      expect(c.graphicSubtitleTimingCues, isEmpty);
    });

    test('暂停 OCR 锚点：mpv 缺 sub-end 时用边播边记里已收尾的真实结束', () {
      final VideoPlayerController c = _graphicController();
      addTearDown(c.dispose);
      c.debugAcceptGraphicLiveTimingForTesting(
        rawStart: '20.000000',
        rawEnd: '21.800000',
      );
      final AudioCue? anchor = c.debugAdoptGraphicSubtitleAnchorForTesting(
        text: 'あいう',
        rawStart: '20.000000',
        rawEnd: '',
      );
      expect(
        (anchor!.startMs, anchor.endMs, anchor.text),
        (20000, 21800, 'あいう'),
      );
      expect(c.cueStreamOwning(anchor).length, 1);
    });

    test('整轨（互联 host 回传）到了：与边播边记合并，抽取为准；换轨后迟到结果丢弃', () async {
      final VideoPlayerController c = _graphicController();
      addTearDown(c.dispose);
      c.debugAcceptGraphicLiveTimingForTesting(
        rawStart: '1.000000',
        rawEnd: '',
      );
      final Completer<GraphicSubtitleRegionTrack?> parsed =
          Completer<GraphicSubtitleRegionTrack?>();
      GraphicSubtitleHostTrackFiles? received;
      c.graphicSubtitleTrackFileRegionLoad =
          (
            GraphicSubtitleHostTrackFiles files, {
            required Size fallbackCanvas,
          }) {
            received = files;
            return parsed.future;
          };
      final Directory tmp = Directory.systemTemp.createTempSync('gfx_host_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final File payload = File('${tmp.path}/track.bin')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      c.debugLoadGraphicSubtitleTimingsWithInputForTesting(
        GraphicSubtitleTimingHostTrack(
          streamIndex: 2,
          codec: 'hdmv_pgs_subtitle',
          download: () async => (payload: payload, header: null),
        ),
      );
      await pumpEventQueue();
      expect(received?.payload.path, payload.path);
      parsed.complete(
        GraphicSubtitleRegionTrack(
          canvas: const Size(1920, 1080),
          regions: const <GraphicSubtitleRegion>[
            GraphicSubtitleRegion(
              startMs: 1000,
              endMs: 2600,
              rect: Rect.fromLTRB(0, 0, 1, 1),
            ),
            GraphicSubtitleRegion(
              startMs: 4000,
              endMs: 5000,
              rect: Rect.fromLTRB(0, 0, 1, 1),
            ),
          ],
        ),
      );
      await pumpEventQueue();
      expect(
        c.graphicSubtitleTimingCues.map((AudioCue x) => (x.startMs, x.endMs)),
        <(int, int)>[(1000, 2600), (4000, 5000)],
        reason: '暂定时长的边播边记句让位给整轨里的真实结束',
      );
      expect(payload.existsSync(), isFalse, reason: '回传的整轨解析完即删');
      expect(
        c.graphicSubtitleRegionTrack.value?.regions,
        hasLength(2),
        reason: '同一份位图时间表交给模糊遮蔽层（互联播放按位图糊的唯一来源）',
      );

      // 第二次加载还没回来时又换了一次：第二次的结果作废，表不被它覆盖。
      final Completer<GraphicSubtitleRegionTrack?> stale =
          Completer<GraphicSubtitleRegionTrack?>();
      c.graphicSubtitleTrackFileRegionLoad =
          (
            GraphicSubtitleHostTrackFiles files, {
            required Size fallbackCanvas,
          }) => stale.future;
      final File payload2 = File('${tmp.path}/track2.bin')
        ..writeAsBytesSync(<int>[1]);
      c.debugLoadGraphicSubtitleTimingsWithInputForTesting(
        GraphicSubtitleTimingHostTrack(
          streamIndex: 2,
          codec: 'hdmv_pgs_subtitle',
          download: () async => (payload: payload2, header: null),
        ),
      );
      await pumpEventQueue();
      c.debugLoadGraphicSubtitleTimingsWithInputForTesting(
        GraphicSubtitleTimingHostTrack(
          streamIndex: 2,
          codec: 'hdmv_pgs_subtitle',
          download: () async => null,
        ),
      );
      stale.complete(
        GraphicSubtitleRegionTrack(
          canvas: const Size(1920, 1080),
          regions: const <GraphicSubtitleRegion>[
            GraphicSubtitleRegion(
              startMs: 90000,
              endMs: 91000,
              rect: Rect.fromLTRB(0, 0, 1, 1),
            ),
          ],
        ),
      );
      await pumpEventQueue();
      expect(c.graphicSubtitleTimingCues.first.startMs, 1000);
      expect(
        c.graphicSubtitleRegionTrack.value?.regions.first.startMs,
        1000,
        reason: '迟到的作废结果也不覆盖遮蔽层的位图时间表',
      );
    });

    test('换轨：位图时间表随两张时间表一起清空', () {
      final VideoPlayerController c = _graphicController();
      addTearDown(c.dispose);
      c.debugSetGraphicRegionTrackForTesting(
        GraphicSubtitleRegionTrack(
          canvas: const Size(1920, 1080),
          regions: const <GraphicSubtitleRegion>[
            GraphicSubtitleRegion(
              startMs: 0,
              endMs: 1,
              rect: Rect.fromLTRB(0, 0, 1, 1),
            ),
          ],
        ),
      );
      expect(c.graphicSubtitleRegionTrack.value, isNotNull);
      // 选轨 / load() 换片走的同一个复位（宿主无 libmpv，经测试钩子直调）。
      c.debugResetGraphicTimingTablesForTesting();
      expect(c.graphicSubtitleRegionTrack.value, isNull);
    });

    test('整轨 OCR 取数：host 整轨下完落到载荷位置（轨头一并落位），下载件删掉', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('gfx_ocr_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final File payload = File('${tmp.path}/dl.bin')
        ..writeAsBytesSync(_oneCueSup(canvasW: 1920, canvasH: 1080));
      final File header = File('${tmp.path}/dl.header.download.json')
        ..writeAsStringSync(
          '{"codec":"hdmv_pgs_subtitle","width":0,"height":0}',
        );
      final String out = '${tmp.path}/work/track.bin';
      final bool ok = await materializeGraphicSubtitleTrack(
        input: GraphicSubtitleTimingHostTrack(
          streamIndex: 0,
          codec: 'hdmv_pgs_subtitle',
          download: () async => (payload: payload, header: header),
        ),
        outputPath: out,
      );
      expect(ok, isTrue);
      expect(File(bitmapSubtitleTrackHeaderPath(out)).existsSync(), isTrue);
      expect(payload.existsSync(), isFalse);
      expect(header.existsSync(), isFalse);
      expect(
        (await readGraphicSubtitleTrackInBackground(
          out,
          complete: true,
        )).map((BitmapSubtitleCue c) => (c.startMs, c.endMs)),
        <(int, int)>[(1000, 3000)],
      );
    });

    test('整轨 OCR 取数：host 下载失败 → false 并报失败，不读流', () async {
      final List<String> failures = <String>[];
      final bool ok = await materializeGraphicSubtitleTrack(
        input: GraphicSubtitleTimingHostTrack(
          streamIndex: 0,
          codec: 'dvd_subtitle',
          download: () async => null,
        ),
        outputPath: '${Directory.systemTemp.path}/never/track.bin',
        onFailure: failures.add,
      );
      expect(ok, isFalse);
      expect(failures, hasLength(1));
    });

    test('host 下载失败（老 host 404）→ 只剩边播边记，不抛', () async {
      final VideoPlayerController c = _graphicController();
      addTearDown(c.dispose);
      c.debugAcceptGraphicLiveTimingForTesting(
        rawStart: '7.000000',
        rawEnd: '8.000000',
      );
      c.debugLoadGraphicSubtitleTimingsWithInputForTesting(
        GraphicSubtitleTimingHostTrack(
          streamIndex: 2,
          codec: 'hdmv_pgs_subtitle',
          download: () async => null,
        ),
      );
      await pumpEventQueue();
      expect(c.graphicSubtitleTimingCues.single.startMs, 7000);
    });

    test('host 回传的 PGS 整轨（无轨头）走与本地抽轨同一条解码路径', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('gfx_sup_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final File payload = File('${tmp.path}/host.bin')
        ..writeAsBytesSync(_oneCueSup(canvasW: 1920, canvasH: 1080));
      final GraphicSubtitleRegionTrack? track =
          await loadGraphicSubtitleRegionsFromTrackFile((
            payload: payload,
            header: null,
          ), fallbackCanvas: const Size(1280, 720));
      expect(track, isNotNull);
      expect(track!.canvas, const Size(1920, 1080));
      expect(
        graphicSubtitleTimingCuesFromRegions(
          track,
        ).map((AudioCue x) => (x.startMs, x.endMs)),
        <(int, int)>[(1000, 3000)],
      );
    });
  });

  group('整轨取数输入（按播放源）', () {
    test('本地文件 → ffmpeg 读盘', () {
      final GraphicSubtitleTimingInput? input =
          graphicSubtitleTimingInputForSource(
            videoPath: r'D:\anime\ep01.mkv',
            mediaUri: null,
            httpHeaders: const <String, String>{},
            streamIndex: 1,
            codec: 'hdmv_pgs_subtitle',
          );
      expect(input, isA<GraphicSubtitleTimingStream>());
      final GraphicSubtitleTimingStream stream =
          input! as GraphicSubtitleTimingStream;
      expect(stream.input.isRemote, isFalse);
      expect(stream.input.uri, r'D:\anime\ep01.mkv');
      expect(stream.streamIndex, 1);
    });

    test('媒体服务器 / 通用 http / 在线源直链 → URL + 与播放器同一份请求头', () {
      const String jellyfin =
          'https://jf.example/Videos/abc/stream.mkv?static=true&api_key=K';
      final GraphicSubtitleTimingStream stream =
          graphicSubtitleTimingInputForSource(
                videoPath: null,
                mediaUri: jellyfin,
                httpHeaders: const <String, String>{
                  'Referer': 'https://site.example/',
                  'User-Agent': 'UA',
                },
                streamIndex: 3,
                codec: 'dvd_subtitle',
              )!
              as GraphicSubtitleTimingStream;
      expect(stream.input.isRemote, isTrue);
      expect(stream.input.uri, jellyfin);
      expect(stream.input.headers, <String, String>{
        'Referer': 'https://site.example/',
        'User-Agent': 'UA',
      });
      expect(stream.streamIndex, 3);
      expect(stream.codec, 'dvd_subtitle');
    });

    test('在线源入库集：videoPath 是 anime-source://，取的是解析后的直链', () {
      final GraphicSubtitleTimingStream stream =
          graphicSubtitleTimingInputForSource(
                videoPath: 'anime-source://ext/123/ep/4',
                mediaUri: 'https://cdn.example/v.mp4',
                httpHeaders: const <String, String>{},
                streamIndex: 0,
                codec: 'hdmv_pgs_subtitle',
              )!
              as GraphicSubtitleTimingStream;
      expect(stream.input.uri, 'https://cdn.example/v.mp4');
    });

    test('ffmpeg 读不了的源（edl 拼接 / bd 菜单 / 无源）→ null，只靠边播边记', () {
      for (final String? uri in <String?>['edl://a;b', 'bd://menu', null]) {
        expect(
          graphicSubtitleTimingInputForSource(
            videoPath: null,
            mediaUri: uri,
            httpHeaders: const <String, String>{},
            streamIndex: 0,
            codec: 'hdmv_pgs_subtitle',
          ),
          isNull,
        );
      }
    });

    test('控制器：显式给的整轨来源优先；否则按 load 进来的流地址 + 请求头推导', () {
      final VideoPlayerController c = _graphicController();
      addTearDown(c.dispose);
      c.debugSetMediaSourceForTesting(
        mediaUri: 'https://pms.example/library/parts/9/file.mkv?X-Plex-Token=T',
        httpHeaders: const <String, String>{'Referer': 'r'},
      );
      final GraphicSubtitleTimingInput? derived = c
          .debugGraphicTimingInputForTesting(streamIndex: 2, codec: 'x');
      expect(derived, isA<GraphicSubtitleTimingStream>());
      expect(
        (derived! as GraphicSubtitleTimingStream).input.headers['Referer'],
        'r',
      );
      // 模糊遮蔽层拿同一份网络流输入（同一个在途抽取，整条流只读一遍）。
      expect(
        c.activeGraphicSubtitleRemoteInput?.uri,
        startsWith('https://pms'),
      );
      expect(c.activeGraphicSubtitleRemoteInput?.headers['Referer'], 'r');
      final GraphicSubtitleTimingHostTrack host =
          GraphicSubtitleTimingHostTrack(
            streamIndex: 2,
            codec: 'x',
            download: () async => null,
          );
      c.debugLoadGraphicSubtitleTimingsWithInputForTesting(host);
      expect(
        c.debugGraphicTimingInputForTesting(streamIndex: 2, codec: 'x'),
        same(host),
      );
      expect(
        c.activeGraphicSubtitleRemoteInput,
        isNull,
        reason: '互联 host 整轨：遮蔽层也不许按流地址整片读',
      );
      // 整轨 OCR 取数同一口径：轨序号对上沿用 host 整轨，别的轨按流地址 + 请求头推导。
      expect(
        c.graphicSubtitleTimingInputForTrack(streamIndex: 2, codec: 'x'),
        same(host),
      );
      final GraphicSubtitleTimingInput? other = c
          .graphicSubtitleTimingInputForTrack(streamIndex: 3, codec: 'x');
      expect(other, isA<GraphicSubtitleTimingStream>());
      expect(
        (other! as GraphicSubtitleTimingStream).input.headers['Referer'],
        'r',
      );
    });
  });

  group('buildRemoteGraphicSubtitleTimingInput（远端播放页）', () {
    const RemoteVideoEmbeddedSubtitleTrack pgs =
        RemoteVideoEmbeddedSubtitleTrack(
          streamIndex: 7,
          codec: 'hdmv_pgs_subtitle',
          isText: false,
          containerTrackOrdinal: 1,
        );

    test('互联 host：给 host 整轨来源（按 host 流号 + 集下标下载），绝不退回整片读流', () async {
      final _FakeInterconnectClient client = _FakeInterconnectClient();
      final Directory tmp = Directory.systemTemp.createTempSync('gfx_remote_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final GraphicSubtitleTimingInput? input =
          buildRemoteGraphicSubtitleTimingInput(
            client: client,
            videoId: 'video/show ep',
            track: pgs,
            containerOrdinal: 1,
            episodeIndex: 3,
            tempDirectory: () async => tmp,
          );
      expect(input, isA<GraphicSubtitleTimingHostTrack>());
      expect(input!.streamIndex, 1, reason: '播放器选轨用容器内序号');
      final GraphicSubtitleHostTrackFiles? files =
          await (input as GraphicSubtitleTimingHostTrack).download();
      expect(client.calls, <String>[
        'track video/show ep s7 e3',
        'header video/show ep s7 e3',
      ]);
      expect(files!.payload.readAsBytesSync(), <int>[0x50, 0x47]);
      expect(files.header!.readAsStringSync(), '{"codec":"hdmv_pgs_subtitle"}');
    });

    test('轨头取不到（PGS 无轨头 / host 404）→ 只交载荷', () async {
      final _FakeInterconnectClient client = _FakeInterconnectClient()
        ..headerFails = true;
      final Directory tmp = Directory.systemTemp.createTempSync('gfx_remote_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final GraphicSubtitleHostTrackFiles? files =
          await (buildRemoteGraphicSubtitleTimingInput(
                    client: client,
                    videoId: 'v',
                    track: pgs,
                    containerOrdinal: 1,
                    episodeIndex: 0,
                    tempDirectory: () async => tmp,
                  )!
                  as GraphicSubtitleTimingHostTrack)
              .download();
      expect(files!.header, isNull);
    });

    test('载荷下载失败（老 host 无端点）→ null，时间表退回边播边记', () async {
      final _FakeInterconnectClient client = _FakeInterconnectClient()
        ..trackFails = true;
      final Directory tmp = Directory.systemTemp.createTempSync('gfx_remote_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      expect(
        await (buildRemoteGraphicSubtitleTimingInput(
                  client: client,
                  videoId: 'v',
                  track: pgs,
                  containerOrdinal: 1,
                  episodeIndex: 0,
                  tempDirectory: () async => tmp,
                )!
                as GraphicSubtitleTimingHostTrack)
            .download(),
        isNull,
      );
    });

    test('媒体服务器 / URL 流（无整轨回传能力）→ null，交播放器按流地址抽取', () {
      expect(
        buildRemoteGraphicSubtitleTimingInput(
          client: _FakePlainClient(),
          videoId: 'v',
          track: pgs,
          containerOrdinal: 1,
          episodeIndex: 0,
          tempDirectory: () async => Directory.systemTemp,
        ),
        isNull,
      );
    });
  });
}

/// 只实现本测试用到的成员；其余远端视频能力不该被触达。
class _FakePlainClient implements RemoteVideoClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeInterconnectClient extends _FakePlainClient
    implements RemoteVideoGraphicSubtitleTrackFetch {
  final List<String> calls = <String>[];
  bool trackFails = false;
  bool headerFails = false;

  @override
  Future<void> getRemoteVideoGraphicSubtitleTrack(
    String id,
    File dest, {
    required int embeddedStreamIndex,
    int episodeIndex = 0,
  }) async {
    calls.add('track $id s$embeddedStreamIndex e$episodeIndex');
    if (trackFails) throw const HttpException('404');
    dest.writeAsBytesSync(<int>[0x50, 0x47]);
  }

  @override
  Future<void> getRemoteVideoGraphicSubtitleTrackHeader(
    String id,
    File dest, {
    required int embeddedStreamIndex,
    int episodeIndex = 0,
  }) async {
    calls.add('header $id s$embeddedStreamIndex e$episodeIndex');
    if (headerFails) throw const HttpException('404');
    dest.writeAsStringSync('{"codec":"hdmv_pgs_subtitle"}');
  }
}

/// 一条 1s→3s 的 PGS cue（4x2 对象落在 (100, 200)），PCS 声明 [canvasW]x[canvasH]。
Uint8List _oneCueSup({required int canvasW, required int canvasH}) {
  List<int> u16(int v) => <int>[(v >> 8) & 0xFF, v & 0xFF];
  final List<int> rle = <int>[
    0x00, 0x84, 0x01, 0x00, 0x00, //
    0x00, 0x84, 0x01, 0x00, 0x00,
  ];
  List<int> pcs(bool show, bool epoch) => <int>[
    ...u16(canvasW),
    ...u16(canvasH),
    0x10,
    ...u16(0),
    epoch ? 0x80 : 0x00,
    0x00,
    0x00,
    if (show) ...<int>[1, ...u16(0), 0x00, 0x00, ...u16(100), ...u16(200)] else
      0,
  ];
  final List<(int, List<(int, List<int>)>)> sets =
      <(int, List<(int, List<int>)>)>[
        (
          90000,
          <(int, List<int>)>[
            (0x16, pcs(true, true)),
            (0x14, <int>[0x00, 0x00, 0x01, 235, 128, 128, 0xFF]),
            (
              0x15,
              <int>[
                ...u16(0),
                0x00,
                0xC0,
                0x00,
                ...u16(rle.length + 4),
                ...u16(4),
                ...u16(2),
                ...rle,
              ],
            ),
            (0x80, <int>[]),
          ],
        ),
        (
          270000,
          <(int, List<int>)>[(0x16, pcs(false, false)), (0x80, <int>[])],
        ),
      ];
  final BytesBuilder out = BytesBuilder();
  for (final (int pts, List<(int, List<int>)> segments) in sets) {
    for (final (int type, List<int> body) in segments) {
      out
        ..add(<int>[0x50, 0x47])
        ..add(<int>[
          (pts >> 24) & 0xFF,
          (pts >> 16) & 0xFF,
          (pts >> 8) & 0xFF,
          pts & 0xFF,
        ])
        ..add(<int>[0, 0, 0, 0])
        ..add(<int>[type, ...u16(body.length)])
        ..add(body);
    }
  }
  return out.toBytes();
}
