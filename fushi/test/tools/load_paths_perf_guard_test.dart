import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 加载路径性能守卫（性能三轮优化第三轮）。这些都活在私有方法 / 启动序列上，
/// 无法用 widget 测试量时间，源码级是最强可落地层。
///
/// - 视频书架的封面路径自愈不再对每一行 `existsSync`（目录列一次成集合）。
/// - 视频页封面回填不再每抽成一张就整页重列（节流）。
/// - 视频页 / 首页 / 统计事实面的独立全表查询一次全部发出（Future.wait），
///   不再逐个串行 await。
/// - 三条字体链并发解析，WOFF/WOFF2 解码进后台 isolate。
/// - 批量加游戏的封面补取有界并行，不再无界 unawaited。
/// - 迁移归档 SHA-256 进后台 isolate。
void main() {
  String read(String rel) => File(rel).readAsStringSync();

  /// [signature] 起到该成员的收尾大括号；[topLevel] 的收尾在列 0。
  String methodBody(String src, String signature, {bool topLevel = false}) {
    final int start = src.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: '找不到 $signature');
    final int end = src.indexOf(topLevel ? '\n}\n' : '\n  }\n', start);
    return src.substring(start, end < 0 ? src.length : end);
  }

  group('video shelf', () {
    final String repo = read('lib/src/media/video/video_book_repository.dart');
    final String page =
        read('lib/src/pages/implementations/home_video_page.dart');

    test('_repairMovedCoverPaths judges existence via one dir snapshot', () {
      final String body = methodBody(
          repo, 'Future<List<VideoBookRow>> _repairMovedCoverPaths(');
      expect(body.contains('_CoverDirSnapshot.take()'), isTrue);
      expect(body.contains('File(cover).existsSync()'), isFalse,
          reason: '每行一次同步 stat 在每次库页刷新都走');
      expect(repo.contains('class _CoverDirSnapshot'), isTrue);
    });

    test('cover backfill throttles the shelf re-list', () {
      final String body =
          methodBody(page, 'Future<void> _maybeBackfillCovers() async {');
      expect(body.contains('refreshShelfThrottled('), isTrue);
      // 直接重列只允许出现一次——在节流闭包里；循环体里不得再裸调。
      expect(
          'setState(() => _future = widget.repo.listForShelf())'
              .allMatches(body)
              .length,
          1,
          reason: '每张封面一次全库重列 + 整页重建');
      expect(page.contains('_coverBackfillRefreshInterval'), isTrue);
    });

    test('_loadLibraryMapsInner issues its table reads concurrently', () {
      final String body = methodBody(
          page, 'Future<void> _loadLibraryMapsInner(int requestGeneration)');
      expect(body.contains('await Future.wait<Object?>('), isTrue);
      for (final String q in <String>[
        'db.getAllMediaCollections()',
        'db.getAllCollectionItems()',
        'db.getAllVideoWatchStatistics()',
        'db.getAllMediaImages()',
      ]) {
        expect(body.contains('await $q'), isFalse,
            reason: '$q 应先发出、后 await，不得串行 await 直接调用');
      }
    });
  });

  group('dashboard / stat facts', () {
    test('loadStatFacts fans out its reads', () {
      final String src = read('lib/src/stats/stat_facts.dart');
      final String body =
          methodBody(src, 'Future<StatFacts> loadStatFacts(', topLevel: true);
      expect(body.contains('await Future.wait<Object?>('), isTrue);
      expect(body.contains('await db.getAllReadingStatistics()'), isFalse);
      expect(body.contains('await db.getStudySegments()'), isFalse);
    });

    test('_loadDashboardDataUnsafe fans out its reads', () {
      final String src =
          read('lib/src/pages/implementations/home_dashboard_page.dart');
      final String body =
          methodBody(src, 'Future<void> _loadDashboardDataUnsafe() async {');
      expect(body.contains('await Future.wait<Object?>('), isTrue);
      expect(body.contains('await db.getAllMediaImages()'), isFalse);
      expect(body.contains('await db.getAllCollectionItems()'), isFalse);
    });
  });

  group('startup', () {
    test('font targets resolve concurrently, web fonts decode off-thread', () {
      final String model = read('lib/src/models/app_model.dart');
      expect(
          model.contains(
              '<Future<Object?>>[appFontsF, subtitleFontF, gameFontsF]'),
          isTrue,
          reason: '三条字体链必须并发解析');
      final String loader = read('lib/src/models/app_font_loader.dart');
      expect(loader.contains('Future.wait<String?>('), isTrue,
          reason: '一条链内的条目并发解析');
      expect(loader.contains('_inFlight'), isTrue, reason: '并发下同名家族只注册一次');
      expect(loader.contains('await Isolate.run('), isTrue,
          reason: 'WOFF/WOFF2 解码不得留在 UI isolate');
    });

    test('main.dart runs the independent log/backend inits concurrently', () {
      final String main = read('lib/main.dart');
      expect(main.contains('await Future.wait<void>(<Future<void>>['), isTrue);
      expect(main.contains('await DebugLogService.instance.init();'), isFalse);
      expect(main.contains('await WgcCaptureLog.foldIntoErrorLog();'), isFalse);
    });
  });

  group('games / migration', () {
    test('batch game cover resolution is bounded', () {
      final String src = read('lib/src/mining/galgame_add_flow.dart');
      expect(src.contains('kGameCoverResolveConcurrency'), isTrue);
      final String body =
          methodBody(src, 'Future<void> addGamesFromPaths(', topLevel: true);
      expect(body.contains('unawaited(_autoCoverAllSilently('), isTrue);
      expect(
          body.contains('for (final GalgameEntry entry in added) {\n'
              '    unawaited(_autoCoverSilently('),
          isFalse,
          reason: 'N 个无界 isolate 各抱一个 exe');
    });

    test('archive sha256 runs in a background isolate', () {
      final String src = read('lib/src/migration/migration_manifest.dart');
      final String body =
          methodBody(src, 'static Future<String> sha256OfFile(File file)');
      expect(body.contains('Isolate.run('), isTrue);
    });
  });
}
