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

    test('_maybeBackfillCovers：候选过滤 + 失败记账双闸门都在环内', () {
      final String body = methodBody('_maybeBackfillCovers');
      // ① m3u8 清单/流 URL/空路径 统一走来源判据，不进抽帧队列。
      expect(body, contains('isLocalFrameExtractableVideoSource(path)'));
      // ② 失败记账：先问账本再抽帧，失败落账。
      expect(
        body,
        contains('CoverBackfillLedger.instance.shouldAttempt(path)'),
      );
      expect(body, contains('CoverBackfillLedger.instance.recordFailure('));
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
