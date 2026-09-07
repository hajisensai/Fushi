// v92 统计域守卫（2026-08-29 根本性重构）。
//
// 数据结构结论：学习时长 / 字数 / 页数只有**一张事实表** `study_segments`，只有
// **一种写法**（按 uid 绝对值 upsert，`FushiDatabase.upsertStudySegment`），只有
// **一个时钟**（`StudyClock`），读取侧只有**一个入口**（`loadStatFacts` → 统一事实面）
// 与**一个窗口定义**（`StatWindow`）。此前同一段学习被并行写进四张 `+=` 投影表、
// 身份用 title、四个页面各算各的窗口——BUG-892 / 1052 / 1085 / 1107 / 1212 / 1350 /
// 1761 / 1762 / 1763 全是这个形状的不同症状。本守卫钉死新结构，防止任何一条回潮：
//
//  ① 本地写入面零直写 legacy 表：`setReadingStatistic` / `setVideoWatchStatistic` /
//     `setReadingHourlyLog` / `setVideoHourlyLog` / `addUnattributedHourlyReadingTime`
//     只允许 `lib/src/sync/**`（legacy wire 家族的 MAX-union 落地面）调用；
//  ② `upsertStudySegment` 只允许两个写入方：`StudyClock`（fushi_audio）与
//     galgame hook 的 chars-only 段；页面不得自己拼段；
//  ③ 页面不得直读 legacy 统计表 / 活动表做统计（只许经 `loadStatFacts`）；
//  ④ 页面不得自己算窗口阈值（`subtract(const Duration(days:` 只许在 StatWindow）；
//  ⑤ 页面不得持有会话累计器（`_sessionReadingMs` / `_sessionCharsRead` /
//     `_sessionStartTime`）；
//  ⑥ 阅读面切屏暂停：三个阅读器 paused/inactive 分支 stop、resumed 分支 start；
//     视频面 inactive **不**停（用户拍板：视频以播放态为准）；
//  ⑦ `StudyClock.stop()` 结构性幂等：清引用在第一个 await 之前；
//  ⑧ 首页每日目标分子与阅读统计页同函数（`studyGoalCharsForDay`，学习域口径）。
//  ⑨ 三个统计页的异步加载 setState 都过 mounted 门（embedded tab 离屏即卸载）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// ① legacy 表的 OVERWRITE 写入口：只有同步落地面可调。
const List<String> kLegacySyncOnlyWriters = <String>[
  'setReadingStatistic',
  'setVideoWatchStatistic',
  'setReadingHourlyLog',
  'setVideoHourlyLog',
  'addUnattributedHourlyReadingTime',
];

/// ③ legacy 统计 / 活动读取口：统计展示只许经 loadStatFacts。
const List<String> kLegacyStatReaders = <String>[
  'getAllReadingStatistics',
  'getAllVideoWatchStatistics',
  'getAllReadingHourlyLogs',
  'getAllVideoHourlyLogs',
  'getHourlyLogsForDate',
  'getVideoHourlyLogsForDate',
  'getActivityDailyTotals',
  'getActivityTitleTotalsForDay',
  'getRecentActivityEvents',
];

/// ③ 的豁免（记录在案，逐条有理由）：
///  - `lib/src/stats/stat_facts.dart`：统一事实面的唯一加载器；
///  - `lib/src/sync/**`：legacy wire 物化 / 备份 / 比对；
///  - `home_video_page.dart`：只取 `video_watch_statistics.lastModified` 做「最近观看」
///    排序（不是统计展示），v92 起与 `getLatestStudyEndAtByMedia` 并集。
const List<String> kLegacyReaderExemptFiles = <String>[
  'lib/src/stats/stat_facts.dart',
  'lib/src/pages/implementations/home_video_page.dart',
];

/// ⑤ 会话累计器的旧形状。
const List<String> kSessionAccumulatorShapes = <String>[
  '_sessionReadingMs',
  '_sessionCharsRead',
  '_sessionPagesRead',
  '_sessionStartTime',
];

const List<String> kReaderPages = <String>[
  'lib/src/pages/implementations/reader_fushi_page.dart',
  'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
  'lib/src/pages/implementations/reader_pdf_page.dart',
  'lib/src/media/manga/reader/manga_fushi_page.dart',
];

const List<String> kStatPages = <String>[
  'lib/src/pages/implementations/reading_statistics_page.dart',
  'lib/src/pages/implementations/video_statistics_page.dart',
  'lib/src/pages/implementations/game_statistics_page.dart',
  'lib/src/pages/implementations/home_dashboard_page.dart',
  'lib/src/pages/implementations/statistics_center_page.dart',
  'lib/src/pages/implementations/stat_period_detail_sheet.dart',
  'lib/src/pages/implementations/video_stat_aggregates.dart',
  'lib/src/pages/implementations/game_stat_aggregates.dart',
  'lib/src/pages/implementations/stat_activity.dart',
  'lib/src/pages/implementations/stat_source_totals.dart',
  'lib/src/pages/implementations/activity_feed.dart',
  // 阅读器内统计浮层：今日 / 累计卡按 StatWindow.isToday 切片（BUG-2218 起走统计口径）。
  'lib/src/reader/reader_statistics_dialog.dart',
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
  String read(String path) => maskComments(File(path).readAsStringSync());

  test('扫描规模哨兵：lib/ 确实被枚举到了', () {
    expectScanScale(
      dartFiles().length,
      what: 'lib/ 下的 .dart',
      atLeast: 800,
      measured: 1021,
    );
  });

  test('① legacy 表 OVERWRITE 写入口只许 lib/src/sync/ 调（本地写入面零直写）', () {
    final List<String> offenders = <String>[];
    for (final File f in dartFiles()) {
      final String path = norm(f.path);
      if (path.startsWith('lib/src/sync/')) continue;
      final String src = f.readAsStringSync();
      for (final String name in kLegacySyncOnlyWriters) {
        if (containsIdentifierCall(src, name, allowNamedConstructor: false)) {
          offenders.add('$path → $name');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'v92 起 reading_statistics / video_watch_statistics / *_hourly_logs '
          '冻结为 legacy，本地写入面只写 study_segments（经 StudyClock）：\n'
          '${offenders.join('\n')}',
    );
  });

  test('② upsertStudySegment 只有两个写入方：StudyClock 与 galgame hook 字数', () {
    final List<String> offenders = <String>[];
    for (final File f in dartFiles()) {
      final String path = norm(f.path);
      if (path == 'lib/src/mining/gal_hook_session_controller.dart') continue;
      if (containsIdentifierCall(
        f.readAsStringSync(),
        'upsertStudySegment',
        allowNamedConstructor: false,
      )) {
        offenders.add(path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '页面 / 仓库不得自己拼段：时长与字数必须经 StudyClock 进同一段同一 uid，'
          '否则又是第二本账：\n${offenders.join('\n')}',
    );
    // fushi_audio 侧：StudyClock 是唯一持有 sink 默认值的地方。
    final String clock = read(
      '../packages/fushi_audio/lib/src/audiobook/study_clock.dart',
    );
    expect(containsIdentifier(clock, 'database.upsertStudySegment'), isTrue);
  });

  test('③ 统计展示不直读 legacy 表 / 活动表，只经 loadStatFacts', () {
    final List<String> offenders = <String>[];
    for (final File f in dartFiles()) {
      final String path = norm(f.path);
      if (path.startsWith('lib/src/sync/')) continue;
      if (kLegacyReaderExemptFiles.contains(path)) continue;
      final String src = f.readAsStringSync();
      for (final String name in kLegacyStatReaders) {
        if (containsIdentifierCall(src, name, allowNamedConstructor: false)) {
          offenders.add('$path → $name');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '首页与统计页数字必须同源（用户拍板）：只许经 loadStatFacts 的统一事实面，'
          '不许各页各读各表：\n${offenders.join('\n')}',
    );
    for (final String path in <String>[
      'lib/src/pages/implementations/reading_statistics_page.dart',
      'lib/src/pages/implementations/video_statistics_page.dart',
      'lib/src/pages/implementations/home_dashboard_page.dart',
    ]) {
      expect(
        containsIdentifierCall(read(path), 'loadStatFacts'),
        isTrue,
        reason: '$path 必须经 loadStatFacts 取数',
      );
    }
  });

  test('④a kStatPages 清单自校验：用 StatWindow 的页面必须已登记', () {
    // ④ 是本文件里唯一按**命名清单**扫描的守卫（①②③⑤都 listSync 全树枚举），
    // 所以新增统计页漏登记时，目录枚举守卫整批和按功能域挑的定向测试**结构上都
    // 挑不到它**——统计中心大改造新增的 statistics_center_page /
    // stat_period_detail_sheet 就是这么漏进来的。修法不是「记得手加」，是让漏登记
    // 本身变红：谁用了 StatWindow 谁就在做窗口统计，谁就必须受 ④ 管辖。
    final List<String> unregistered = <String>[];
    for (final File f in dartFiles()) {
      final String path = norm(f.path);
      // StatWindow 的定义方与它自己的测试语料不在管辖范围内。
      if (path.startsWith('lib/src/stats/')) continue;
      if (!containsIdentifier(f.readAsStringSync(), 'StatWindow')) continue;
      if (!kStatPages.contains(path)) unregistered.add(path);
    }
    expect(
      unregistered,
      isEmpty,
      reason: '这些文件用了 StatWindow 却没进 kStatPages，④ 的窗口阈值扫描'
          '看不见它们：$unregistered',
    );
  });

  test('④ 窗口阈值只在 StatWindow 定义（近 7 天恰 7 天，不再 8 天）', () {
    // 「昨天」标签之类的 `days: 1` 不是窗口阈值，只盯周 / 月窗口的四个数。
    const List<String> windowShapes = <String>[
      'Duration(days: 6)',
      'Duration(days: 7)',
      'Duration(days: 13)',
      'Duration(days: 14)',
      'Duration(days: 29)',
      'Duration(days: 30)',
    ];
    for (final String path in kStatPages) {
      final String src = read(path);
      for (final String shape in windowShapes) {
        expect(
          src.contains(shape),
          isFalse,
          reason: '$path 含 $shape：不得自己算窗口起点——此前四处手算 `now-7d` + '
              '`>=` 让「近 7 天」含 8 天、环比分母却 7 天；只许用 StatWindow',
        );
      }
    }
    final String window = read('lib/src/stats/stat_window.dart');
    expect(
      containsCodeLine(window, '_keyDaysAgo(now, 6)'),
      isTrue,
      reason: '近 7 天起点 = 6 天前（含今日恰 7 天）',
    );
    expect(containsCodeLine(window, '_keyDaysAgo(now, 29)'), isTrue);
    expect(
      containsCodeLine(window, '_keyDaysAgo(now, 13)'),
      isTrue,
      reason: '上周窗口与本周不重叠且同长',
    );
  });

  test('⑤ 阅读器页面不再持有任何会话累计器（只有 StudyClock 一本账）', () {
    for (final String path in kReaderPages) {
      final String src = read(path);
      for (final String shape in kSessionAccumulatorShapes) {
        expect(
          containsIdentifier(src, shape),
          isFalse,
          reason: '$path 含 $shape：会话累计器是 BUG-1052 / 1107「第二本账被重锚吃掉 / '
              '口径分叉」的根因，v92 起只有 StudyClock 持有累计',
        );
      }
      expect(
        containsIdentifier(src, 'ReadingTimeTracker'),
        isFalse,
        reason: '$path：旧 tracker 已删',
      );
    }
    expect(
      containsCodeLine(
        read('lib/src/pages/implementations/reader_fushi/navigation.part.dart'),
        '_readLedger.arrive(',
      ),
      isTrue,
      reason: 'EPUB 新读字数经 ReadUnitLedger（翻走即计）记进当前段',
    );
    final String manga = read(
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    );
    expect(
      containsCodeLine(manga, '_studyClock?.addChars(added.chars)'),
      isTrue,
    );
    expect(
      containsCodeLine(manga, '_studyClock?.addPages(added.pages)'),
      isTrue,
    );
  });

  test('⑥ 阅读面切屏暂停（paused/inactive stop、resumed start）；视频面 inactive 不停', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/reader_fushi_page.dart',
      'lib/src/pages/implementations/reader_pdf_page.dart',
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    ]) {
      final String body = methodBody(
        read(path),
        'void didChangeAppLifecycleState(',
      );
      final int inactive = body.indexOf('AppLifecycleState.inactive');
      final int resumed = body.indexOf('AppLifecycleState.resumed');
      expect(inactive, greaterThanOrEqualTo(0), reason: path);
      expect(resumed, greaterThan(inactive), reason: path);
      final String bg = body.substring(inactive, resumed);
      final String fg = body.substring(resumed);
      // EPUB 面（BUG-2209）：start / stop 决策收敛到统一判据 studyClockMayRun——生命
      // 周期分支只置旗再 _syncStudyClockRunState()（后台听书跟随经 _ensureStudyClock
      // 到达时看到旗子不会重新起表）。PDF / 漫画仍是直接 stop / start。
      final bool unifiedGate = path.endsWith('reader_fushi_page.dart');
      expect(
        unifiedGate
            ? bg.contains('_studyClockLifecycleStopped = true;') &&
                  bg.contains('_syncStudyClockRunState();')
            : bg.contains('_studyClock?.stop()'),
        isTrue,
        reason: '$path：失焦 / 进后台必须停表（切屏自动暂停，用户拍板只对阅读面）',
      );
      expect(
        unifiedGate
            ? fg.contains('_studyClockLifecycleStopped = false;') &&
                  fg.contains('_syncStudyClockRunState();')
            : fg.contains('_studyClock?.start()'),
        isTrue,
        reason: '$path：回前台重启（后台段靠停表丢弃，不靠重锚）',
      );
    }
    final String video = methodBody(
      read('lib/src/pages/implementations/video_fushi_page.dart'),
      'void didChangeAppLifecycleState(',
    );
    final int inactive = video.indexOf('case AppLifecycleState.inactive:');
    final int paused = video.indexOf('case AppLifecycleState.paused:');
    expect(inactive, greaterThanOrEqualTo(0));
    expect(paused, greaterThan(inactive));
    expect(
      video.substring(inactive, paused).contains('_watchTracker?.stop()'),
      isFalse,
      reason: '视频切走仍在播就照常计时（用户拍板）：inactive 不得停表',
    );
    expect(
      video.substring(paused).contains('_watchTracker?.stop()'),
      isTrue,
      reason: '真后台 / 熄屏才停',
    );
  });

  test('⑦ StudyClock.stop() 结构性幂等：清引用在第一个 await 之前', () {
    final String clock = read(
      '../packages/fushi_audio/lib/src/audiobook/study_clock.dart',
    );
    final String body = methodBody(clock, 'Future<void> stop() async {');
    final int clearOpen = body.indexOf('_open = null;');
    final int clearTimer = body.indexOf('_timer = null;');
    final int firstAwait = body.indexOf('await ');
    expect(clearOpen, greaterThanOrEqualTo(0));
    expect(clearTimer, greaterThanOrEqualTo(0));
    expect(
      firstAwait,
      greaterThan(clearOpen),
      reason: '旧 VideoWatchTracker.stop 在 await 之后才清零累计器：dispose 与进程退出'
          '并发各写一条活动行（时长翻倍）。清引用必须在任何 await 之前',
    );
    expect(firstAwait, greaterThan(clearTimer));
    expect(body.contains('+='), isFalse, reason: 'stop 不做任何累加');
    // 唯一写法：绝对值 upsert（写侧没有 +=）。
    final String write = methodBody(clock, 'Future<void> _write(');
    expect(
      write.contains('insertOnConflictUpdate') || write.contains('_sink('),
      isTrue,
    );
    expect(write.contains('+='), isFalse);
  });

  test('⑧ 首页每日目标分子与阅读统计页同函数', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/home_dashboard_page.dart',
      'lib/src/pages/implementations/reading_statistics_page.dart',
    ]) {
      expect(
        containsIdentifierCall(read(path), 'studyGoalCharsForDay'),
        isTrue,
        reason: '$path：目标分子必须走 studyGoalCharsForDay（学习域：书 + 字幕 + '
            '游戏 hook，BUG-1993），首页与统计页各自手搓求和迟早再对不上',
      );
    }
    // 光钉函数名不够：v92 时域是写死在函数体里的 `f.isBook`，所以「同函数」自动
    // 等价于「同口径」；BUG-1993 把域上移成调用方传的行集之后，两页传不同切片
    // 照样能让守卫全绿。而 reading_statistics_page 本来就有两处调用（阅读域
    // _bookFacts 供 CPH、学习域 _dailyFacts 供目标），文件级 contains 分辨不出
    // 目标分子用的是哪一处——必须把**目标分子那一处的实参**一起钉死。
    expect(
      containsCodeLine(
        read('lib/src/pages/implementations/home_dashboard_page.dart'),
        'studyGoalCharsForDay(_dailyRows,',
      ),
      isTrue,
      reason: '首页目标分子的实参必须是完整日面 _dailyRows（书 ∪ 视频 ∪ 游戏），'
          '换成任何单域切片都会让 BUG-1993 原地复发',
    );
    expect(
      containsCodeLine(
        read('lib/src/pages/implementations/reading_statistics_page.dart'),
        'studyGoalCharsForDay(_dailyFacts,',
      ),
      isTrue,
      reason: '统计页目标分子的实参必须是完整日面 _dailyFacts，与首页同口径',
    );
  });

  test('⑨ 三个统计页的异步加载 setState 都过 mounted 门（embedded tab 离屏即卸载）', () {
    // 统计中心把三页塞进 TabBarView，没有 keepAlive——离屏即 unmount。
    // 「点开 tab → loadStatFacts 还在查 → 切到另一个 tab」是一秒可复现的常规
    // 操作，而三页的加载函数在首帧 postFrameCallback 与多次 await 之后各有一处
    // setState。改造前它们是独立路由，要在几百毫秒的查询窗口里按返回键才撞得上，
    // 所以裸 setState 存量地活了很久；tab 化把可达性放大了两个数量级。
    // 三页曾经不一致（只有 game 页有门），这里把三页一起钉住。
    const Map<String, String> loaders = <String, String>{
      'lib/src/pages/implementations/reading_statistics_page.dart':
          'Future<void> _syncAndLoad() async {',
      'lib/src/pages/implementations/video_statistics_page.dart':
          'Future<void> _syncAndLoad() async {',
      'lib/src/pages/implementations/game_statistics_page.dart':
          'Future<void> _load() async {',
    };
    loaders.forEach((String path, String signature) {
      final String body = methodBody(read(path), signature);
      expect(
        containsCodeLine(body, 'if (!mounted) return;'),
        isTrue,
        reason: '$path：加载入口首帧由 postFrameCallback 触发，State 可能已 dispose，'
            '第一处 setState 前必须过 mounted 门',
      );
    });
    // 收尾那处 setState 在多次 await 之后，裸调即 use-after-dispose。
    for (final String path in loaders.keys) {
      final String src = read(path);
      expect(
        containsCodeLine(src, 'setState(() => _loading = false);') &&
            !containsCodeLine(
                src, 'if (mounted) setState(() => _loading = false);'),
        isFalse,
        reason: '$path：await 之后的收尾 setState 必须写成 '
            '`if (mounted) setState(() => _loading = false);`',
      );
    }
  });

  test('legacy 累加 DAO 已从 DB 层彻底删除（编译层守卫的文本镜像）', () {
    final String core = File(
      '../packages/fushi_core/lib/src/database/database_statistics.part.dart',
    ).readAsStringSync();
    for (final String name in <String>[
      'addReadingStatistic',
      'addHourlyReadingTime',
      'addVideoWatchStatistic',
      'addVideoHourlyWatchTime',
      'recordReadingSession',
      'recordWatchFlush',
    ]) {
      expect(
        RegExp('Future<void> $name\\(').hasMatch(core),
        isFalse,
        reason: '$name 是 += 投影写入口，v92 起不得复活',
      );
    }
  });
}
