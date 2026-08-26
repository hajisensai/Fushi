import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart'
    show kDragPlaylistExtensions;
import 'package:fushi/src/media/media_extensions.dart'
    show kPlaylistManifestExtensions;
import 'package:fushi/src/media/video/video_cover_extractor.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart'
    show ErrorLogEntry, ErrorLogService;

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

    test('零长文件 -> true（打得开、内容确实是空的）', () {
      expect(
        hasHollowMediaHeader(write('empty.mkv', const <int>[]).path),
        isTrue,
      );
    });

    test('单字节 0x00 -> true', () {
      expect(
        hasHollowMediaHeader(write('one_zero.ts', const <int>[0]).path),
        isTrue,
      );
    });

    test('读不出来 != 空壳：不存在的路径 / 目录 -> false，且各留一条诊断', () {
      // BUG-1867 审查：把「打不开」算成空壳，会让所有调用方静默拿到 null——一条
      // 日志都没有，用户主动触发的导入/换封面也查不出为什么没封面。返回 false 是
      // 把这类输入交回下游 ffmpeg，走它自己那条可诊断路径。
      final int errorsBefore = ErrorLogService.instance.entries.length;
      final int diagBefore = ErrorLogService.instance.diagnosticEntries.length;

      expect(
        hasHollowMediaHeader('${tmp.path}${Platform.pathSeparator}nope.mkv'),
        isFalse,
      );
      // 根本不是普通文件（目录）：openSync 抛，同样按「读不出来」处理。
      expect(hasHollowMediaHeader(tmp.path), isFalse);

      final List<ErrorLogEntry> added =
          ErrorLogService.instance.diagnosticEntries.sublist(diagBefore);
      expect(added.length, 2, reason: '每次读失败都要留痕，不能静默吞掉');
      expect(
        added.every((ErrorLogEntry e) => e.source == 'hasHollowMediaHeader'),
        isTrue,
      );
      expect(
        ErrorLogService.instance.entries.length,
        errorsBefore,
        reason: '诊断不计入用户可见错误计数',
      );
    });
  });

  group('extractVideoCover 抽取器层拒收空洞文件（BUG-1867）', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_cover_hollow_');
    });
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    // 真 .m2ts 布局：4 字节 TP_extra_header + 0x47 sync + 187 字节负载。
    List<int> realM2tsBytes() {
      final List<int> bytes = <int>[];
      while (bytes.length < kHollowMediaHeaderProbeBytes) {
        bytes.addAll(<int>[0x26, 0xF0, 0x4B, 0xE8, 0x47]);
        bytes.addAll(List<int>.filled(187, 0xFF));
      }
      return bytes;
    }

    test('头部全零的本地文件直接返回 null，不烧 ffmpeg 子进程', () async {
      // 与上面的清单拒收同一手法：早退发生在 AppPaths / ffmpeg 之前。若有人删掉抽取器
      // 层的空洞拒收，这里会因 path_provider 的 MissingPluginException 立即红。
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

    test('正向对照：真容器头必须穿过拒收继续往下走', () async {
      // 上一条只钉住「空洞 -> null」。把 _extractVideoCoverUnlocked 改成无条件
      // `return null`，上一条照样绿。这条钉另一半：内容真实的文件不得被判据吞掉，
      // 它必须继续走到 AppPaths.videoCoversDirectory()——本测试无 path_provider
      // mock，于是抛。抛 = 判据放行了；拿到 null = 判据（或早退）把真文件也吞了。
      final File real = File('${tmp.path}${Platform.pathSeparator}00010.m2ts');
      real.writeAsBytesSync(realM2tsBytes());

      await expectLater(
        extractVideoCover(
          videoPath: real.path,
          bookUid: 'video/local/bdmv-00010',
        ),
        throwsA(anything),
        reason: '真容器头被判成空洞、或早退无条件返回 null 时，这里会拿到 null 而不是抛',
      );
    });
  });

  group('封面抽取器接线守卫（源码扫描 · BUG-1867）', () {
    late String source;
    setUpAll(() {
      source = File('lib/src/media/video/video_cover_extractor.dart')
          .readAsStringSync();
    });

    test('空洞拒收是唯一一道门，且在 AppPaths / ffmpeg 之前', () {
      final int gate = source
          .indexOf('if (!isRemoteInput && hasHollowMediaHeader(videoPath))');
      final int appPaths = source.indexOf('AppPaths.videoCoversDirectory()');
      final int embedded =
          source.indexOf('await extractEmbeddedVideoCoverViaFfmpeg(');
      expect(gate, greaterThanOrEqualTo(0), reason: '抽取器层必须有空洞拒收');
      expect(appPaths, greaterThan(gate),
          reason: '判据排在建目录之后 = 为一个必然失败的输入先建目录');
      expect(embedded, greaterThan(gate));
    });

    test('回填降级必须覆盖两段 ffmpeg，不能只降抽帧那一段', () {
      // 只给抽帧传 diagnosticOnly 的话，ffmpeg 缺失时内嵌封面那一段仍按错误级上报，
      // 34 条候选照样刷满用户可见错误日志——BUG-1867 只修了一半。
      final int embedded =
          source.indexOf('await extractEmbeddedVideoCoverViaFfmpeg(');
      final int frame = source.indexOf('return extractVideoFrameViaFfmpeg(');
      expect(embedded, greaterThanOrEqualTo(0));
      expect(frame, greaterThan(embedded));
      final int embeddedFlag =
          source.indexOf('diagnosticOnly: diagnosticOnly,', embedded);
      final int frameFlag =
          source.indexOf('diagnosticOnly: diagnosticOnly,', frame);
      expect(embeddedFlag, greaterThan(embedded));
      expect(embeddedFlag, lessThan(frame), reason: '内嵌封面那一段没吃到开关');
      expect(frameFlag, greaterThan(frame), reason: '抽帧那一段没吃到开关');
    });

    test('hasHollowMediaHeader 读失败：记诊断 + 返回 false（不得当成空壳）', () {
      final int fn = source.indexOf('bool hasHollowMediaHeader(String path)');
      expect(fn, greaterThanOrEqualTo(0),
          reason: '签名变了（例如又长出 probeBytes 这种没有调用方的参数）');
      final int catchAt = source.indexOf('} catch (e) {', fn);
      final int finallyAt = source.indexOf('} finally {', fn);
      final int diag =
          source.indexOf("logDiagnostic('hasHollowMediaHeader'", catchAt);
      final int ret = source.indexOf('return false;', catchAt);
      expect(catchAt, greaterThan(fn));
      expect(diag, greaterThan(catchAt));
      expect(diag, lessThan(finallyAt), reason: '诊断必须落在 catch 块里');
      expect(ret, greaterThan(diag));
      expect(ret, lessThan(finallyAt), reason: '读失败必须返回 false，不是 true');
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

    test('视频页不再自己预判空洞：判据唯一真相源在抽取器层（BUG-1867）', () {
      // 同一事实两处真相源 + 同一文件两次 64KB 读。真门在
      // video_cover_extractor.dart 的 _extractVideoCoverUnlocked，所有调用方
      // （回填 / 导入 / 拆集 / host 服务）一并免疫，page 层不必也不该重复。
      expect(
        source.contains('hasHollowMediaHeader'),
        isFalse,
        reason: '判据被复制回 page 层了；门只留在 video_cover_extractor.dart',
      );
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
