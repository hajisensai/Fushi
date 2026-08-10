// P4 写侧收敛守卫（A3，2026-08 数据层重构）。
//
// 统计写侧收敛后，lib/ 里不许再有人绕开 DB 复合入口直调底层累加 DAO：
// - 阅读 session → recordReadingSession（既有收敛，addReadingStatistic 禁直调）；
// - 制卡记账   → recordMiningEvent（addMiningCount / addMineCountPerBook 禁直调，
//   旧散点正是「两表各自 await 各自吞异常」的漂移面 + PDF/漫画漏 per-book 的单边写点）；
// - 视频观看桶 → recordWatchFlush（addVideoWatchStatistic / addVideoHourlyWatchTime
//   禁直调，旧接线同一次 flush 两次独立 await 各自 fail-open，hourly/daily 可不同步丢）。
//
// 豁免（记录在案）：`lib/src/sync/**`（含 backup_merge_engine / sync_manager 等备份
// 合并文件，全在该目录下）——MAX-union / deficit-lift 落地面**必须**绕开复合入口：
// set* 直写投影是 OVERWRITE/MAX 语义、且 sync 落地不得替对端伪造 activity 行
// （负向断言见 aggregate_sync_service_cloud_test.dart）。
//
// 另钉三条「刻意差异」，防后人「顺手统一」：
// - recordWatchFlush 不写 activity（activity 是 stop 时刻 session 事件，跨午夜时
//   与桶的日归属口径差是故意的，ed2f36443f）；
// - VideoWatchTracker.stop() 的 activity dateKey 取 stop 时刻（_dateKey(now)）；
// - recordMiningEvent 事务内两表齐写。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// 复合入口收编的底层累加 DAO：lib/ 下（豁免目录外）禁直调。
const List<String> kConvergedAccumulators = <String>[
  'addReadingStatistic',
  'addMiningCount',
  'addMineCountPerBook',
  'addVideoWatchStatistic',
  'addVideoHourlyWatchTime',
];

void main() {
  final Directory libDir = Directory('lib');

  List<File> dartFiles() => libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));

  String norm(String path) => p.split(path).join('/');

  test('扫描规模哨兵：lib/ 确实被枚举到了', () {
    expectScanScale(dartFiles().length,
        what: 'lib/ 下的 .dart', atLeast: 800, measured: 1021);
  });

  test('lib/ 禁直调被收敛的统计累加 DAO（sync 落地面豁免）', () {
    final List<String> offenders = <String>[];
    for (final File f in dartFiles()) {
      final String path = norm(f.path);
      // MAX-union / deficit-lift 落地面：set* 直写 + 不产 activity 行，结构上
      // 必须绕开复合入口（见文件头豁免说明）。
      if (path.startsWith('lib/src/sync/')) continue;
      final String src = f.readAsStringSync();
      for (final String name in kConvergedAccumulators) {
        if (containsIdentifierCall(src, name, allowNamedConstructor: false)) {
          offenders.add('$path → $name');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: '这些调用绕开了 P4 复合入口（recordReadingSession / '
            'recordMiningEvent / recordWatchFlush）。散点直调两表就是当年'
            '「各自 await 各自吞异常 → 投影漂移」的根因，别再开新洞：\n'
            '${offenders.join('\n')}');
  });

  test('制卡记账五个写点全部走 recordMiningEvent', () {
    const List<String> miningSites = <String>[
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
      'lib/src/pages/implementations/reader_fushi/mining.part.dart',
      'lib/src/lookup/overlay_bridge_handlers.dart',
      'lib/src/pages/implementations/reader_pdf_page.dart',
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    ];
    for (final String path in miningSites) {
      final String src = File(path).readAsStringSync();
      expect(containsIdentifierCall(src, 'recordMiningEvent'), isTrue,
          reason: '$path 是制卡记账写点，必须经 FushiDatabase.recordMiningEvent '
              '复合入口（同事务全局汇总 + per-book）');
    }
  });

  test('PDF / 漫画的书身份覆写在位（此前漏覆写 → 计数全落 \'\' 汇总桶）', () {
    for (final (String path, String bookRowTitle) in <(String, String)>[
      ('lib/src/pages/implementations/reader_pdf_page.dart', '_bookRow?.title'),
      ('lib/src/media/manga/reader/manga_fushi_page.dart', '_bookRow?.title'),
    ]) {
      final String src = File(path).readAsStringSync();
      final String body = methodBody(src, 'get lookupBookIdentity');
      expect(body.contains('widget.bookKey'), isTrue,
          reason: '$path 的 lookupBookIdentity 必须以 widget.bookKey 为身份键'
              '（口径照抄 reader_fushi_page 的同名覆写）');
      expect(body.contains(bookRowTitle), isTrue,
          reason: '$path 的统计聚合 title 必须恒 raw（书行原始 title），'
              '不得过 display-title 门面——否则改名前后计数分叉两桶');
    }
  });

  test('视频观看统计接线走 recordWatchFlush（页面 + tracker 两侧）', () {
    final String page =
        File('lib/src/pages/implementations/video_fushi_page.dart')
            .readAsStringSync();
    expect(containsIdentifierCall(page, 'recordWatchFlush'), isTrue,
        reason: 'video_fushi_page 的观看统计接线必须走 recordWatchFlush 复合入口');

    final String tracker =
        File('lib/src/media/video/video_watch_tracker.dart').readAsStringSync();
    final String flushBody = methodBody(tracker, 'Future<void> _flush()');
    expect(containsIdentifierCall(flushBody, '_recordFlush'), isTrue,
        reason: '_flush 的观看时长桶必须整批交给 _recordFlush（单次 await，'
            '同一事务两表齐落）');
    expect(containsIdentifier(flushBody, '_addHourly'), isFalse,
        reason: '_flush 不得回到「hourly 与 daily 两次独立 await 各自 fail-open」'
            '的旧形状');
  });

  test('刻意差异①：recordWatchFlush 事务内两表齐写、不派生 activity 行', () {
    final String core = File(
            '../packages/fushi_core/lib/src/database/database_statistics.part.dart')
        .readAsStringSync();
    final String body = methodBody(core, 'Future<void> recordWatchFlush(');
    expect(containsIdentifierCall(body, 'transaction'), isTrue,
        reason: 'recordWatchFlush 的两表写必须包在同一事务里');
    expect(containsIdentifierCall(body, 'addVideoHourlyWatchTime'), isTrue);
    expect(containsIdentifierCall(body, 'addVideoWatchStatistic'), isTrue);
    expect(containsIdentifierCall(body, 'addActivityEvent'), isFalse,
        reason: 'activity 行是 stop 时刻的 session 事件（VideoWatchTracker.stop '
            '另写），跨午夜时与桶的日归属口径差是**故意的**（ed2f36443f）——'
            '不得从桶派生 activity、不得「顺手统一」');
  });

  test('刻意差异②：tracker.stop() 的 activity dateKey 取 stop 时刻', () {
    final String tracker =
        File('lib/src/media/video/video_watch_tracker.dart').readAsStringSync();
    final String stopBody = methodBody(tracker, 'Future<void> stop()');
    expect(containsIdentifierCall(stopBody, '_recordActivity'), isTrue,
        reason: 'session 结束的活动事件在 stop() 落（只此一行）');
    expect(containsCodeLine(stopBody, '_dateKey(now)'), isTrue,
        reason: 'activity 的 dateKey 必须取 stop 时刻（session 事件语义），'
            '不得改从观看桶的 dateKey 派生');
  });

  test('recordMiningEvent 事务内两表齐写、dateKey 经 statDateKeyOf 派生', () {
    final String core = File(
            '../packages/fushi_core/lib/src/database/database_statistics.part.dart')
        .readAsStringSync();
    final String body = methodBody(core, 'Future<void> recordMiningEvent(');
    expect(containsIdentifierCall(body, 'transaction'), isTrue);
    expect(containsIdentifierCall(body, 'addMiningCount'), isTrue);
    expect(containsIdentifierCall(body, 'addMineCountPerBook'), isTrue,
        reason: '两份投影必须在同一事务里齐写——半写就是恒等式漂移的根因');
    expect(containsCodeLine(body, 'statDateKeyOf(at)'), isTrue,
        reason: 'dateKey 只许从 at 经权威派生一次，两表共用');
  });
}
