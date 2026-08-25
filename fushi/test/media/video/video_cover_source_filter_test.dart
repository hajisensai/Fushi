import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart'
    show kDragPlaylistExtensions;
import 'package:fushi/src/media/media_extensions.dart'
    show kPlaylistManifestExtensions;
import 'package:fushi/src/media/video/video_cover_extractor.dart';

/// BUG-1564 ①：封面抽帧的候选过滤。本地 m3u8/m3u 播放列表清单是**文本清单**不是
/// 媒体流本体，ffmpeg 对它必然 `Invalid data found`——不得进入抽帧队列；判定收在
/// 来源类型/扩展名抽象层（[isPlaylistManifestPath] /
/// [isLocalFrameExtractableVideoSource] + [extractVideoCover] 抽取器层拒收），
/// 不是调用点各自 if。
void main() {
  group('isPlaylistManifestPath', () {
    test('m3u8/m3u（含大写、两种分隔符）-> true', () {
      expect(isPlaylistManifestPath(r'D:\videos\k-on\k-on.m3u8'), isTrue);
      expect(isPlaylistManifestPath('/videos/k-on/k-on.m3u'), isTrue);
      expect(isPlaylistManifestPath(r'D:\v\SEASON.M3U8'), isTrue);
    });

    test('普通媒体扩展名 -> false', () {
      expect(isPlaylistManifestPath(r'D:\videos\ep1.mkv'), isFalse);
      expect(isPlaylistManifestPath('/videos/ep1.mp4'), isFalse);
      // 名字里含 m3u8 但扩展名不是清单：不误杀。
      expect(isPlaylistManifestPath('/videos/m3u8-notes.txt'), isFalse);
      expect(isPlaylistManifestPath('/videos/archive.m3u8.mkv'), isFalse);
    });

    test('与拖放分类的播放列表白名单同集（收敛守卫，禁各自漂移）', () {
      expect(
        kPlaylistManifestExtensions.map((String e) => e.substring(1)).toSet(),
        kDragPlaylistExtensions,
      );
    });
  });

  group('isLocalFrameExtractableVideoSource（回填候选判据）', () {
    test('本地媒体文件路径 -> true', () {
      expect(
        isLocalFrameExtractableVideoSource(r'D:\videos\ep1.mkv'),
        isTrue,
      );
      expect(isLocalFrameExtractableVideoSource('/videos/ep1.mp4'), isTrue);
    });

    test('m3u8/m3u 清单不进抽帧候选', () {
      expect(
        isLocalFrameExtractableVideoSource(r'D:\videos\k-on\k-on.m3u8'),
        isFalse,
      );
      expect(
        isLocalFrameExtractableVideoSource('/videos/list.m3u'),
        isFalse,
      );
    });

    test('空路径 / http(s) 流 URL 不进抽帧候选', () {
      expect(isLocalFrameExtractableVideoSource(''), isFalse);
      expect(isLocalFrameExtractableVideoSource('   '), isFalse);
      expect(
        isLocalFrameExtractableVideoSource('http://host/v/ep1.mkv'),
        isFalse,
      );
      expect(
        isLocalFrameExtractableVideoSource('https://host/hls/index.m3u8'),
        isFalse,
      );
    });
  });

  group('extractVideoCover 抽取器层拒收本地清单', () {
    test('本地 .m3u8 直接返回 null，不烧 ffmpeg 子进程', () async {
      // 早退发生在 AppPaths / ffmpeg 之前：本测试无 path_provider mock、无 ffmpeg，
      // 若有人删掉抽取器层的清单拒收，这里会因 MissingPluginException 立即红。
      final Directory tmp =
          Directory.systemTemp.createTempSync('hibiki_cover_filter_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final File manifest =
          File('${tmp.path}${Platform.pathSeparator}k-on.m3u8');
      manifest.writeAsStringSync('#EXTM3U\n#EXTINF:-1,ep1\nep1.mkv\n');

      final String? cover = await extractVideoCover(
        videoPath: manifest.path,
        bookUid: 'video/playlist/k-on-1',
      );
      expect(cover, isNull);
    });
  });

  group('isHollowMediaHeaderBytes（BUG-1867 内容已落盘判据 · 纯函数）', () {
    test('空 / 全零 -> true', () {
      expect(isHollowMediaHeaderBytes(const <int>[]), isTrue);
      expect(isHollowMediaHeaderBytes(List<int>.filled(65536, 0)), isTrue);
    });

    test('任一非零字节 -> false（含只有最后一字节非零）', () {
      final List<int> tailOnly = List<int>.filled(65536, 0);
      tailOnly[65535] = 0x47;
      expect(isHollowMediaHeaderBytes(tailOnly), isFalse);
      // 真容器魔数：MPEG-TS sync / MP4 ftyp / Matroska EBML / RIFF。
      expect(
        isHollowMediaHeaderBytes(const <int>[0x47, 0x40, 0x00, 0x10]),
        isFalse,
      );
      expect(
        isHollowMediaHeaderBytes(
          const <int>[0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70],
        ),
        isFalse,
      );
      expect(
        isHollowMediaHeaderBytes(const <int>[0x1A, 0x45, 0xDF, 0xA3]),
        isFalse,
      );
      expect(isHollowMediaHeaderBytes('RIFF'.codeUnits), isFalse);
    });
  });

  group('hasHollowMediaHeader（BUG-1867 · 真文件）', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_hollow_');
    });
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    File write(String name, List<int> bytes) {
      final File f = File('${tmp.path}${Platform.pathSeparator}$name');
      f.writeAsBytesSync(bytes);
      return f;
    }

    test('torrent 预分配的空洞文件（探测窗全零）-> true', () {
      final File hollow = write(
        'preallocated.m2ts',
        List<int>.filled(kHollowMediaHeaderProbeBytes * 2, 0),
      );
      expect(hasHollowMediaHeader(hollow.path), isTrue);
    });

    test('已下载完成的 m2ts（192 字节步长的 TS sync）-> false', () {
      // 真 .m2ts 布局：4 字节 TP_extra_header + 0x47 sync + 187 字节负载。
      final List<int> bytes = <int>[];
      while (bytes.length < kHollowMediaHeaderProbeBytes * 2) {
        bytes.addAll(<int>[0x26, 0xF0, 0x4B, 0xE8, 0x47]);
        bytes.addAll(List<int>.filled(187, 0xFF));
      }
      final File complete = write('downloaded.m2ts', bytes);
      expect(hasHollowMediaHeader(complete.path), isFalse);
    });

    test('内容只在探测窗之后才出现 -> 仍判 true（ffmpeg 此刻同样打不开）', () {
      final List<int> bytes =
          List<int>.filled(kHollowMediaHeaderProbeBytes * 3, 0);
      bytes[kHollowMediaHeaderProbeBytes + 4] = 0x47;
      final File partial = write('midfile.m2ts', bytes);
      expect(hasHollowMediaHeader(partial.path), isTrue);
    });

    test('短于探测窗的小文件按实际长度判定（不因读不满而误判）', () {
      expect(
        hasHollowMediaHeader(write('tiny_ok.ts', <int>[0x47, 1, 2]).path),
        isFalse,
      );
      expect(
        hasHollowMediaHeader(write('tiny_hollow.ts', <int>[0, 0, 0]).path),
        isTrue,
      );
    });

    test('零长文件 / 不存在的路径 -> true（此刻同样抽不出帧）', () {
      expect(
        hasHollowMediaHeader(write('empty.mkv', const <int>[]).path),
        isTrue,
      );
      expect(
        hasHollowMediaHeader('${tmp.path}${Platform.pathSeparator}nope.mkv'),
        isTrue,
      );
    });
  });

  group('extractVideoCover 抽取器层拒收空洞文件（BUG-1867）', () {
    test('头部全零的本地文件直接返回 null，不烧 ffmpeg 子进程', () async {
      // 与上面的清单拒收同一手法：早退发生在 AppPaths / ffmpeg 之前。若有人删掉抽取器
      // 层的空洞拒收，这里会因 path_provider 的 MissingPluginException 立即红。
      final Directory tmp =
          Directory.systemTemp.createTempSync('fushi_cover_hollow_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final File hollow =
          File('${tmp.path}${Platform.pathSeparator}00014.m2ts');
      hollow.writeAsBytesSync(
        List<int>.filled(kHollowMediaHeaderProbeBytes * 2, 0),
      );

      final String? cover = await extractVideoCover(
        videoPath: hollow.path,
        bookUid: 'video/local/bdmv-00014',
      );
      expect(cover, isNull);
    });
  });

  group('视频页回填接线守卫（源码扫描）', () {
    late String source;
    setUpAll(() {
      source = File('lib/src/pages/implementations/home_video_page.dart')
          .readAsStringSync();
    });

    /// 截取 [source] 中方法 [name] 的正文（从声明行到下一个顶格方法/类结束前的
    /// 粗粒度片段）：按声明起点向后取到下一次出现「\n  /// 」或「\n  Future<」等
    /// 兄弟成员边界。粒度够断言调用存在即可。
    String methodBody(String name) {
      final int start = source.indexOf('Future<void> $name(');
      expect(start, greaterThan(0), reason: '找不到方法 $name');
      final int end = source.indexOf('\n  /// ', start);
      return source.substring(start, end > start ? end : source.length);
    }

    test('_maybeBackfillCovers：候选、临界区重查与失败记账都在环内', () {
      final String body = methodBody('_maybeBackfillCovers');
      // ① m3u8 清单/流 URL/空路径 统一走来源判据，不进抽帧队列。
      expect(body, contains('isLocalFrameExtractableVideoSource(path)'));
      // ② 失败记账：先问账本再抽帧，失败落账。
      expect(
        body,
        contains('CoverBackfillLedger.instance.shouldAttempt(path)'),
      );
      expect(body, contains('CoverBackfillLedger.instance.recordFailure('));
      // ③ 排队取得封面写锁后必须丢弃旧 listAll 快照，重读当前路径/封面；否则
      // 刮削或手选刚提交的封面仍会被后台帧覆盖。
      final int gate = body.indexOf('VideoCoverMutationGate.runExclusive');
      final int freshBook = body.indexOf('widget.repo.getByBookUid(', gate);
      final int currentCover = body.indexOf('File(currentCover).existsSync()');
      expect(gate, greaterThanOrEqualTo(0));
      expect(freshBook, greaterThan(gate));
      expect(currentCover, greaterThan(freshBook));
    });

    test('_maybeBackfillCovers：空洞判据必须在封面写锁闸门之前（BUG-1867）', () {
      final String body = methodBody('_maybeBackfillCovers');
      final int hollow = body.indexOf('hasHollowMediaHeader(path)');
      final int gate = body.indexOf('VideoCoverMutationGate.runExclusive');
      expect(hollow, greaterThanOrEqualTo(0),
          reason: '回填必须在进 ffmpeg 前判「内容是否已落盘」');
      expect(gate, greaterThan(hollow),
          reason: '判据在闸门之后 = 一个必然失败的抽帧仍会独占进程级封面写锁');
      // 判掉的路径要记账，否则同一会话每轮 listAll 都重读一次头部。
      expect(body, contains("reason: 'hollow-header'"));
    });

    test('_maybeBackfillCovers：回填抽帧失败只进诊断日志（BUG-1867）', () {
      final String body = methodBody('_maybeBackfillCovers');
      final int call = body.indexOf('extractVideoCover(');
      expect(call, greaterThanOrEqualTo(0));
      final int flag = body.indexOf('diagnosticOnly: true', call);
      expect(flag, greaterThan(call),
          reason: 'best-effort 回填的「给不出帧」不是 app 错误，不该刷用户可见错误日志页');
    });

    test('_pullToRefresh：显式刷新是唯一清账入口', () {
      final String body = methodBody('_pullToRefresh');
      expect(body, contains('CoverBackfillLedger.instance.clearAll()'));
      // 清账只许接在显式刷新：全文件仅此一处 clearAll。
      expect(
        RegExp(r'CoverBackfillLedger\.instance\.clearAll\(\)')
            .allMatches(source)
            .length,
        1,
      );
    });
  });
}
