import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_download_controller.dart';
import 'package:fushi/src/models/dictionary_format_upgrade.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 词典格式升级的编排（[DictionaryFormatUpgradeCoordinator]）与它依赖的写锁语义
/// （[DictionaryDownloadController.runWhenIdle]）。拍板台 pr3554：升级前先问用户——
/// 静默检查不占写锁、不改写旧式词典；有待升级的才问；不同意什么都不写；同意了才占锁
/// 亮状态行升级，升级过才重载，重载 + 旧引擎释放之后静默补跑检查；失败只记日志；亮
/// 状态行的那段撞上别的写任务就排队。
void main() {
  late List<String> calls;
  late _RecordingKeepAlive keepAlive;
  late DictionaryDownloadController controller;
  late List<DictionaryDownloadPhase> phases;
  late List<String> messages;
  late List<(String, Object)> logs;
  late bool reloaded;
  late List<int> asked;

  setUp(() {
    calls = <String>[];
    keepAlive = _RecordingKeepAlive();
    controller = DictionaryDownloadController(
      showOutcome: (_) => calls.add('outcome'),
      keepAlive: keepAlive,
    );
    phases = <DictionaryDownloadPhase>[];
    messages = <String>[];
    logs = <(String, Object)>[];
    reloaded = false;
    asked = <int>[];
    controller.phase.addListener(() => phases.add(controller.phase.value));
    controller.message.addListener(() {
      if (controller.message.value.isNotEmpty) {
        messages.add(controller.message.value);
      }
    });
  });

  tearDown(() => controller.dispose());

  const List<String> all = <String>['/d/A', '/d/B', '/d/C'];

  String names(List<String> dirs) =>
      dirs.map((String d) => d.split('/').last).join(',');

  /// 假的原生调用：按目录给结果，记下 `<label> <目录> busy=<写锁>`；[before] 在返回
  /// 结果之前跑（卡住 / 抛异常用）。
  DictionaryUpgradeRunner fake(
    String label,
    List<FushiDictUpgradeOutcome> Function() outcomes, {
    Set<String> deferred = const <String>{},
    Future<void> Function(List<String> dirs)? before,
  }) {
    return (List<String> dirs, {FushiDictUpgradeProgress? onProgress}) async {
      calls.add('$label ${names(dirs)} busy=${controller.isBusy}');
      if (before != null) await before(dirs);
      final List<FushiDictUpgradeOutcome> table = outcomes();
      final Map<String, FushiDictUpgradeOutcome> results =
          <String, FushiDictUpgradeOutcome>{};
      final List<String> skipped = <String>[];
      for (int i = 0; i < dirs.length; i++) {
        if (deferred.contains(dirs[i])) {
          skipped.add(dirs[i]);
          continue;
        }
        final FushiDictUpgradeOutcome outcome = table[all.indexOf(dirs[i])];
        results[dirs[i]] = outcome;
        onProgress?.call(i + 1, dirs.length, dirs[i], outcome);
        // 每本之间让出一次，像真的逐本 await isolate 那样。
        await Future<void>.delayed(Duration.zero);
      }
      return FushiDictUpgradeReport(results: results, deferred: skipped);
    };
  }

  const FushiDictUpgradeOutcome up = FushiDictUpgradeOutcome.upgraded;
  const FushiDictUpgradeOutcome same = FushiDictUpgradeOutcome.upToDate;
  const FushiDictUpgradeOutcome fail = FushiDictUpgradeOutcome.failed;
  const FushiDictUpgradeOutcome na = FushiDictUpgradeOutcome.notApplicable;
  const FushiDictUpgradeOutcome pend = FushiDictUpgradeOutcome.pending;

  /// [check]：检查那一遍（重载前）的结果；[after]：重载后补跑检查的结果；[upgrade]：
  /// 升级那一遍的结果；[accept]：用户对确认框的回答。
  DictionaryFormatUpgradeCoordinator coordinator({
    required List<FushiDictUpgradeOutcome> check,
    List<FushiDictUpgradeOutcome> after = const <FushiDictUpgradeOutcome>[
      same,
      same,
      same,
    ],
    List<FushiDictUpgradeOutcome> upgrade = const <FushiDictUpgradeOutcome>[
      up,
      up,
      up,
    ],
    bool accept = true,
    List<String> dirs = all,
    Set<String> deferred = const <String>{},
    Future<void> Function(List<String> dirs)? beforeCheck,
    Future<void> Function(List<String> dirs)? beforeUpgrade,
  }) => DictionaryFormatUpgradeCoordinator(
    controller: controller,
    dictDirs: () => dirs,
    tidy: fake(
      'check',
      () => reloaded ? after : check,
      deferred: deferred,
      before: beforeCheck,
    ),
    upgrade: fake('upgrade', () => upgrade, before: beforeUpgrade),
    confirm: (int count) async {
      asked.add(count);
      calls.add('ask $count busy=${controller.isBusy}');
      return accept;
    },
    reload: () async {
      calls.add('reload busy=${controller.isBusy}');
      reloaded = true;
    },
    settleOldEngine: () async {
      calls.add('settle');
    },
    message: (int done, int total) => '$done/$total',
    log: (String tag, Object info) => logs.add((tag, info)),
  );

  Future<void> pump() async {
    for (int i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('全部已是最新：只静默检查一遍，不问、不占锁、状态行不出现、不重载', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      check: <FushiDictUpgradeOutcome>[same, same, same],
    ).run();

    expect(calls, <String>['check A,B,C busy=false']);
    expect(asked, isEmpty);
    expect(phases, isEmpty, reason: 'phase 必须始终是 idle');
    expect(messages, isEmpty);
    expect(keepAlive.events, isEmpty);
    expect(r.checked!.upToDate, all);
    expect(r.pending, isEmpty);
    expect(r.confirmed, isFalse);
    expect(r.upgrade, isNull);
    expect(r.reloaded, isFalse);
    expect(logs, isEmpty);
  });

  test('有待升级的：问一次（本数 = 待升级的），不同意就什么都不升级、不占锁、不重载', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      check: <FushiDictUpgradeOutcome>[pend, same, pend],
      accept: false,
    ).run();

    expect(calls, <String>['check A,B,C busy=false', 'ask 2 busy=false']);
    expect(asked, <int>[2]);
    expect(phases, isEmpty);
    expect(r.pending, <String>['/d/A', '/d/C']);
    expect(r.confirmed, isFalse);
    expect(r.upgrade, isNull);
    expect(r.reloaded, isFalse);
  });

  test('同意：只升级待升级的那几本，占锁、亮状态行、报进度；之后重载 → 等旧引擎 → 不占锁静默补跑检查', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      check: <FushiDictUpgradeOutcome>[pend, same, pend],
    ).run();

    expect(calls, <String>[
      'check A,B,C busy=false',
      'ask 2 busy=false',
      'upgrade A,C busy=true',
      'reload busy=false',
      'settle',
      'check A,B,C busy=false',
    ]);
    expect(phases, <DictionaryDownloadPhase>[
      DictionaryDownloadPhase.upgrading,
      DictionaryDownloadPhase.idle,
    ]);
    expect(messages, containsAllInOrder(<String>['0/2', '1/2', '2/2']));
    expect(r.confirmed, isTrue);
    expect(r.upgrade!.upgraded, <String>['/d/A', '/d/C']);
    expect(r.reloaded, isTrue);
    expect(r.cleanup!.upToDate, all);
    expect(controller.isBusy, isFalse);
  });

  test('同意但一本都没升级成（失败 / 不适用）：只记日志，不重载、不补跑', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      check: <FushiDictUpgradeOutcome>[pend, pend, same],
      upgrade: <FushiDictUpgradeOutcome>[fail, na, same],
    ).run();

    expect(calls.last, 'upgrade A,B busy=true');
    expect(r.reloaded, isFalse);
    expect(r.upgrade!.failed, <String>['/d/A']);
    expect(logs.length, 2);
    expect(controller.isBusy, isFalse);
  });

  test('检查那遍的失败 / 不适用只记日志，不算待升级、不问', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      check: <FushiDictUpgradeOutcome>[fail, na, same],
    ).run();
    expect(asked, isEmpty);
    expect(r.pending, isEmpty);
    expect(logs.length, 2);
  });

  test('被映射释放作用域推迟的目录：进结果的 deferred，不算待升级', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      check: <FushiDictUpgradeOutcome>[pend, pend, pend],
      deferred: <String>{'/d/B', '/d/C'},
    ).run();
    expect(r.checked!.deferred, <String>['/d/B', '/d/C']);
    expect(asked, <int>[1]);
    expect(calls, contains('upgrade A busy=true'));
  });

  test('没有词典：什么都不做', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      check: <FushiDictUpgradeOutcome>[],
      dirs: const <String>[],
    ).run();
    expect(r.checked, isNull);
    expect(calls, isEmpty);
  });

  test('静默检查期间不占写锁：用户发起的 run 照常开始（启动自动更新不会因此被跳过）', () async {
    final Completer<void> gate = Completer<void>();
    final Future<DictionaryFormatUpgradeRun> checking = coordinator(
      check: <FushiDictUpgradeOutcome>[same, same, same],
      beforeCheck: (List<String> dirs) => gate.future,
    ).run();
    await pump();
    expect(calls, <String>['check A,B,C busy=false']);
    expect(controller.isBusy, isFalse);
    bool ran = false;
    expect(
      await controller.run(
        initialMessage: 'x',
        body: (_) async {
          ran = true;
          return null;
        },
      ),
      isTrue,
    );
    expect(ran, isTrue);
    gate.complete();
    await checking;
    expect(
      phases.where((DictionaryDownloadPhase p) => p.name == 'upgrading'),
      isEmpty,
    );
  });

  test('升级撞上在跑的下载：排队等下载结束，不并发、不跳过', () async {
    final Completer<void> download = Completer<void>();
    final Future<bool> downloading = controller.run(
      initialMessage: 'downloading',
      body: (DictionaryDownloadJob job) async {
        calls.add('download start');
        await download.future;
        calls.add('download end');
        return null;
      },
    );
    final Future<DictionaryFormatUpgradeRun> upgrading = coordinator(
      check: <FushiDictUpgradeOutcome>[pend, pend, same],
    ).run();
    await pump();
    expect(calls, <String>[
      'download start',
      'check A,B,C busy=true',
      'ask 2 busy=true',
    ], reason: '下载没结束前不能开始升级');
    expect(controller.phase.value, DictionaryDownloadPhase.downloading);

    download.complete();
    expect(await downloading, isTrue);
    await upgrading;
    expect(calls.sublist(3), <String>[
      'download end',
      'upgrade A,B busy=true',
      'reload busy=false',
      'settle',
      'check A,B,C busy=false',
    ]);
  });

  test('亮着状态行升级时：用户发起的 run 被拒（忙）', () async {
    final Completer<void> gate = Completer<void>();
    final Future<DictionaryFormatUpgradeRun> upgrading = coordinator(
      check: <FushiDictUpgradeOutcome>[pend, same, same],
      beforeUpgrade: (List<String> dirs) => gate.future,
    ).run();
    await pump();
    expect(controller.isBusy, isTrue);
    expect(controller.phase.value, DictionaryDownloadPhase.upgrading);
    expect(controller.message.value, '0/1');
    bool ran = false;
    expect(
      await controller.run(
        initialMessage: 'x',
        body: (_) async {
          ran = true;
          return null;
        },
      ),
      isFalse,
    );
    expect(ran, isFalse);
    gate.complete();
    await upgrading;
    expect(controller.isBusy, isFalse);
    expect(controller.phase.value, DictionaryDownloadPhase.idle);
  });

  test('原生检查抛异常：异常交给调用方，锁与状态行都没碰过', () async {
    final DictionaryFormatUpgradeCoordinator c = coordinator(
      check: <FushiDictUpgradeOutcome>[same, same, same],
      beforeCheck: (_) async => throw UnsupportedError('no export'),
    );
    await expectLater(c.run(), throwsUnsupportedError);
    expect(controller.isBusy, isFalse);
    expect(phases, isEmpty);
  });

  test('原生升级抛异常：锁照样释放、状态行收起，异常交给调用方', () async {
    final DictionaryFormatUpgradeCoordinator c = coordinator(
      check: <FushiDictUpgradeOutcome>[pend, same, same],
      beforeUpgrade: (_) async => throw StateError('boom'),
    );
    await expectLater(c.run(), throwsStateError);
    expect(controller.isBusy, isFalse);
    expect(phases, <DictionaryDownloadPhase>[
      DictionaryDownloadPhase.upgrading,
      DictionaryDownloadPhase.idle,
    ]);
  });

  test('runWhenIdle：多个等待者依次占锁，互不并发', () async {
    final Completer<void> first = Completer<void>();
    int inside = 0;
    int maxInside = 0;
    Future<void> job(String name, [Future<void>? wait]) =>
        controller.runWhenIdle((DictionaryDownloadJob j) async {
          inside++;
          if (inside > maxInside) maxInside = inside;
          calls.add(name);
          if (wait != null) await wait;
          await Future<void>.delayed(Duration.zero);
          inside--;
        });
    final List<Future<void>> all = <Future<void>>[
      job('a', first.future),
      job('b'),
      job('c'),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(calls, <String>['a']);
    first.complete();
    await Future.wait(all);
    expect(calls, <String>['a', 'b', 'c']);
    expect(maxInside, 1);
    expect(controller.isBusy, isFalse);
  });
}

class _RecordingKeepAlive implements DownloadKeepAlive {
  final List<String> events = <String>[];
  int stops = 0;

  @override
  Future<void> update({
    required String title,
    required String text,
    int? percent,
  }) async {
    events.add('update');
  }

  @override
  Future<void> stop() async {
    events.add('stop');
    stops++;
  }
}
