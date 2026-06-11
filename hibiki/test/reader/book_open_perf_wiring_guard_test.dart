import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// TODO-131 守卫：锁定「打开书籍白屏优化」的开书路径接线，防回归。
/// reader_hibiki_page.dart 太重（WebView + DB + profile providers）不便在 host
/// widget 测试里整页 mount，纯函数等价性由 book_open_char_counts_test.dart 覆盖；
/// 这里用源码扫描守住 _initBook 的关键时序/数据流不变量。
void main() {
  late String src;

  setUpAll(() {
    src = File('lib/src/pages/implementations/reader_hibiki_page.dart')
        .readAsStringSync();
  });

  test('_initBook 并行起跑 profile/settings 链与书本定位/解析链', () {
    final int profileIdx = src.indexOf('_resolveProfileAndSettings(db)');
    final int locateIdx = src.indexOf('_locateBookOnDisk(db)');
    final int firstAwaitIdx = src.indexOf('await profileSettingsFuture;');
    expect(profileIdx, greaterThan(0));
    expect(locateIdx, greaterThan(0));
    expect(firstAwaitIdx, greaterThan(0));
    // 两条链的 Future 必须都在第一个 await 之前就被创建（并行起跑），否则退化成
    // 串行，白屏优化失效。
    expect(profileIdx, lessThan(firstAwaitIdx),
        reason: 'profile/settings Future 必须在 await 之前起跑');
    expect(locateIdx, lessThan(firstAwaitIdx),
        reason: 'book-locate Future 必须在 await 之前起跑（与 profile 链并行）');
  });

  test('开书优先复用 DB 已存的 per-chapter 字符数（跳过整本 html_parser 计数）', () {
    expect(src.contains('parseBookOnly'), isTrue,
        reason: '冷开首屏走 parseBookOnly（不在 isolate 里整本计数）');
    expect(src.contains('charCountsFromChaptersJson('), isTrue,
        reason: '必须从 chaptersJson 复用 DB 计数');
    // 整本「解析+计数」入口 parseAndCountChapters 不应再出现在开书路径
    // （只保留给等价性测试/旧路径），否则等于没省下计数。
    expect(src.contains('compute(parseAndCountChapters'), isFalse,
        reason: '_initBook 不应再 compute(parseAndCountChapters)——那会整本计数');
  });

  test('DB 计数缺失时后台补算并重置统计基准（避免 charDiff 幻象 spike）', () {
    expect(src.contains('_recomputeCharCountsInBackground'), isTrue);
    // 后台补算落定后必须重置 _lastAbsoluteCount，否则零计数期间它停在 0，
    // 计数落定后首个进度回调会把整段前缀误当本次新读字数累进统计。
    final int recomputeIdx =
        src.indexOf('void _recomputeCharCountsInBackground()');
    expect(recomputeIdx, greaterThan(0));
    final int nextMethodIdx = src.indexOf('void _setupVolumeKeyHandlers()');
    final String body = src.substring(recomputeIdx, nextMethodIdx);
    expect(body.contains('_lastAbsoluteCount = _absoluteCharPosition('), isTrue,
        reason: '补算落定后必须把 _lastAbsoluteCount 校到当前位置，杜绝统计 spike');
    expect(body.contains('identical(_book, book)'), isTrue,
        reason: '只在仍是同一本书时采用补算结果（防换书竞态）');
  });

  test('_applyCharCounts 重建累计前缀并刷新进度总字数', () {
    final int idx = src.indexOf('void _applyCharCounts(List<int> counts)');
    expect(idx, greaterThan(0));
    final int end = src.indexOf('void _recomputeCharCountsInBackground()');
    final String body = src.substring(idx, end);
    expect(body.contains('_chapterCumulativeChars'), isTrue);
    expect(body.contains('_progressTotalChars'), isTrue);
  });
}
