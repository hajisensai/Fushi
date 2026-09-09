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
      // 直接重列只允许出现一次——在节流闭包里；循环体里不得再裸调。钉的是「几次
      // 重列」这个不变式，不是那行的写法（写法从箭头体改成了块体，见下一条）。
      expect(
          'widget.repo.listForShelf()'.allMatches(body).length,
          1,
          reason: '每张封面一次全库重列 + 整页重建');
      expect(page.contains('_coverBackfillRefreshInterval'), isTrue);
    });

    test('cover backfill never hands setState a closure returning a Future',
        () {
      final String body =
          methodBody(page, 'Future<void> _maybeBackfillCovers() async {');
      // `setState(() => _future = ...)` 的箭头体会把赋值结果（Future）当返回值
      // 交给 setState，debug 断言当场抛出并掀掉整个回填循环；release 因断言被
      // 编译掉而侥幸跑通，于是这条失效路径只在 debug 生效、长期无人发现。
      expect(body.contains('setState(() => _future'), isFalse,
          reason: 'setState() callback argument returned a Future');
    });

    test('returning from the player does not rerun the whole library load', () {
      final String open = methodBody(
          page, 'Future<void> _open(VideoBookRow book, {int? playlistCollectionId}) async {');
      expect(open.contains('_refreshAfterPlayback()'), isTrue,
          reason: '播放返回必须走窄刷新');
      expect(open.contains('_refresh()'), isFalse,
          reason: '全量 _refresh 会重算 12 张与观看无关的表并拖起封面回填产线');

      final String narrow =
          methodBody(page, 'void _refreshAfterPlayback() {');
      expect(narrow.contains('widget.repo.listForShelf()'), isTrue,
          reason: '断点 / 完成时刻 / 字幕源 / 音轨都在 video_books 上');
      expect(narrow.contains('_loadWatchRecency()'), isTrue,
          reason: 'study_segments 驱动的「最近观看」会变');
      expect(narrow.contains('_maybeBackfillCovers('), isFalse,
          reason: '播放不产生新的缺封面行，回填是后台产线不该压在退出这一帧上');
      expect(narrow.contains('_loadLibraryMaps('), isFalse,
          reason: '合集 / 刮削 / 元数据播放页一行都不写');

      // 窄重载与全量重载必须给出同一份「最近观看」映射，否则排序随刷新来路漂移。
      final String recency =
          methodBody(page, 'Future<void> _loadWatchRecency() async {');
      expect(recency.contains('_buildWatchRecency('), isTrue);
      final String full = methodBody(
          page, 'Future<void> _loadLibraryMapsInner(int requestGeneration)');
      expect(full.contains('_buildWatchRecency('), isTrue);
      // 两条路径各记各的代，互不取消。
      expect(recency.contains('_watchRecencyRequestGeneration'), isTrue);
      expect(full.contains('_libraryMapsRequestGeneration'), isTrue);
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
