import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_download_controller.dart';
import 'package:fushi/src/models/dictionary_format_upgrade.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 启动期词典格式升级的编排（[DictionaryFormatUpgradeCoordinator]）与它依赖的写锁语义
/// （[DictionaryDownloadController.runWhenIdle]）：静默段不占写锁（不挡下载 / 自动更新）、
/// 常态启动不闪 UI、确有升级且后面还有词典才占锁亮状态行、升级过才重载、重载 + 旧引擎
/// 释放之后静默补跑、失败只记日志、亮状态行的那段撞上别的写任务就排队。
void main() {
  late List<String> calls;
  late _RecordingKeepAlive keepAlive;
  late DictionaryDownloadController controller;
  late List<DictionaryDownloadPhase> phases;
  late List<String> messages;
  late List<(String, Object)> logs;
  late bool reloaded;

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
    controller.phase.addListener(() => phases.add(controller.phase.value));
    controller.message.addListener(() {
      if (controller.message.value.isNotEmpty) {
        messages.add(controller.message.value);
      }
    });
  });

  tearDown(() => controller.dispose());

  String names(List<String> dirs) =>
      dirs.map((String d) => d.split('/').last).join(',');

  /// 按目录给结果：重载之前的调用用 [first]，重载之后（补跑）用 [cleanup]。每次调用
  /// 记下它拿到的目录与当时写锁的状态；[before] 在返回结果之前跑（卡住某一次调用用）。
  DictionaryUpgradeRunner fakeUpgrade(
    List<FushiDictUpgradeOutcome> first, {
    List<FushiDictUpgradeOutcome>? cleanup,
    Set<String> deferred = const <String>{},
    Future<void> Function(List<String> dirs)? before,
  }) {
    const List<String> all = <String>['/d/A', '/d/B', '/d/C'];
    return (List<String> dirs, {FushiDictUpgradeProgress? onProgress}) async {
      calls.add('upgrade ${names(dirs)} busy=${controller.isBusy}');
      if (before != null) await before(dirs);
      final List<FushiDictUpgradeOutcome> outcomes = reloaded
          ? cleanup!
          : first;
      final Map<String, FushiDictUpgradeOutcome> results =
          <String, FushiDictUpgradeOutcome>{};
      final List<String> skipped = <String>[];
      for (int i = 0; i < dirs.length; i++) {
        if (deferred.contains(dirs[i])) {
          skipped.add(dirs[i]);
          continue;
        }
        final FushiDictUpgradeOutcome outcome = outcomes[all.indexOf(dirs[i])];
        results[dirs[i]] = outcome;
        onProgress?.call(i + 1, dirs.length, dirs[i], outcome);
        // 每本之间让出一次，像真的逐本 await isolate 那样。
        await Future<void>.delayed(Duration.zero);
      }
      return FushiDictUpgradeReport(results: results, deferred: skipped);
    };
  }

  DictionaryFormatUpgradeCoordinator coordinator(
    DictionaryUpgradeRunner upgrade, {
    List<String> dirs = const <String>['/d/A', '/d/B', '/d/C'],
  }) => DictionaryFormatUpgradeCoordinator(
    controller: controller,
    dictDirs: () => dirs,
    upgrade: upgrade,
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

  const FushiDictUpgradeOutcome up = FushiDictUpgradeOutcome.upgraded;
  const FushiDictUpgradeOutcome same = FushiDictUpgradeOutcome.upToDate;
  const FushiDictUpgradeOutcome fail = FushiDictUpgradeOutcome.failed;
  const FushiDictUpgradeOutcome na = FushiDictUpgradeOutcome.notApplicable;

  Future<void> pump() async {
    for (int i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('全部已是最新：逐本静默检查，不占写锁、状态行一帧都不出现、不碰保活、不重载、不补跑', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      fakeUpgrade(<FushiDictUpgradeOutcome>[same, same, same]),
    ).run();

    expect(phases, isEmpty, reason: 'phase 必须始终是 idle');
    expect(messages, isEmpty);
    expect(keepAlive.events, isEmpty);
    expect(calls, <String>[
      'upgrade A busy=false',
      'upgrade B busy=false',
      'upgrade C busy=false',
    ]);
    expect(r.first!.upToDate, <String>['/d/A', '/d/B', '/d/C']);
    expect(r.revealed, isFalse);
    expect(r.reloaded, isFalse);
    expect(r.cleanup, isNull);
    expect(logs, isEmpty);
    expect(controller.isBusy, isFalse);
  });

  test('有一本升级且后面还有：剩下的占锁、亮状态行、报进度；之后重载 → 等旧引擎 → 不占锁静默补跑', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      fakeUpgrade(
        <FushiDictUpgradeOutcome>[same, up, same],
        cleanup: <FushiDictUpgradeOutcome>[same, same, same],
      ),
    ).run();

    // 占到锁时先报「已处理 2 / 3」（静默段做掉的两本），C 做完报 3 / 3。
    expect(messages, <String>['2/3', '3/3']);
    expect(phases, <DictionaryDownloadPhase>[
      DictionaryDownloadPhase.upgrading,
      DictionaryDownloadPhase.idle,
    ], reason: '补跑那一遍不再亮');
    expect(controller.cancellable.value, isFalse);
    expect(calls, <String>[
      'upgrade A busy=false',
      'upgrade B busy=false',
      'upgrade C busy=true',
      'reload busy=false',
      'settle',
      'upgrade A,B,C busy=false',
    ]);
    expect(r.revealed, isTrue);
    expect(r.reloaded, isTrue);
    expect(r.first!.upgraded, <String>['/d/B']);
    expect(r.first!.upToDate, <String>['/d/A', '/d/C']);
    expect(r.cleanup!.upgraded, isEmpty);
    expect(keepAlive.events.last, 'stop', reason: '亮过就要在收尾撤保活');
    expect(keepAlive.stops, 1);
    expect(controller.isBusy, isFalse);
  });

  test('只有最后一本升级：后面没有词典了，不占锁、不亮状态行，但照样重载 + 补跑', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      fakeUpgrade(
        <FushiDictUpgradeOutcome>[same, same, up],
        cleanup: <FushiDictUpgradeOutcome>[same, same, same],
      ),
    ).run();
    expect(phases, isEmpty);
    expect(keepAlive.events, isEmpty);
    expect(r.revealed, isFalse);
    expect(r.reloaded, isTrue);
    expect(calls, <String>[
      'upgrade A busy=false',
      'upgrade B busy=false',
      'upgrade C busy=false',
      'reload busy=false',
      'settle',
      'upgrade A,B,C busy=false',
    ]);
  });

  test('补跑那一遍即使报「已升级」也不再亮、不再重载', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      fakeUpgrade(
        <FushiDictUpgradeOutcome>[up, same, same],
        cleanup: <FushiDictUpgradeOutcome>[same, same, up],
      ),
    ).run();
    expect(calls.where((String c) => c.startsWith('reload')), hasLength(1));
    expect(
      phases.where((DictionaryDownloadPhase p) => p.name == 'upgrading'),
      hasLength(1),
    );
    expect(r.cleanup!.upgraded, <String>['/d/C']);
  });

  test('失败 / 不适用：只记日志，不亮状态行、不重载', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      fakeUpgrade(<FushiDictUpgradeOutcome>[fail, na, same]),
    ).run();
    expect(phases, isEmpty);
    expect(r.reloaded, isFalse);
    expect(calls.where((String c) => c.startsWith('reload')), isEmpty);
    expect(logs, hasLength(2));
    expect(
      logs.every(
        ((String, Object) l) =>
            l.$1 == DictionaryFormatUpgradeCoordinator.logTag,
      ),
      isTrue,
    );
    expect('${logs[0].$2}', contains('A'));
    expect('${logs[1].$2}', contains('B'));
    expect(calls, isNot(contains('outcome')), reason: '不给用户弹结果');
  });

  test('被映射释放作用域推迟的目录：静默段与占锁段的都汇进结果', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      fakeUpgrade(
        <FushiDictUpgradeOutcome>[up, same, same],
        cleanup: <FushiDictUpgradeOutcome>[same, same, same],
        deferred: <String>{'/d/C'},
      ),
    ).run();
    expect(r.first!.upgraded, <String>['/d/A']);
    expect(r.first!.deferred, <String>['/d/C']);
    expect(r.cleanup!.deferred, <String>['/d/C']);
  });

  test('没有词典：什么都不做', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      fakeUpgrade(<FushiDictUpgradeOutcome>[]),
      dirs: const <String>[],
    ).run();
    expect(r.first, isNull);
    expect(calls, isEmpty);
  });

  test('静默检查期间不占写锁：用户发起的 run 照常开始（启动自动更新不会因此被跳过）', () async {
    final Completer<void> gate = Completer<void>();
    final Future<DictionaryFormatUpgradeRun> upgrading = coordinator(
      fakeUpgrade(<FushiDictUpgradeOutcome>[
        same,
        same,
        same,
      ], before: (List<String> dirs) => gate.future),
    ).run();
    await pump();
    expect(calls, <String>['upgrade A busy=false'], reason: '卡在第一本的检查上');
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
    await upgrading;
    expect(controller.isBusy, isFalse);
    expect(
      phases.where((DictionaryDownloadPhase p) => p.name == 'upgrading'),
      isEmpty,
    );
  });

  test('占锁升级撞上在跑的下载：静默段照常做，要亮状态行的那段排队等下载结束，不并发、不跳过', () async {
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
      fakeUpgrade(
        <FushiDictUpgradeOutcome>[up, up, same],
        cleanup: <FushiDictUpgradeOutcome>[same, same, same],
      ),
    ).run();
    await pump();
    expect(calls, <String>[
      'download start',
      'upgrade A busy=true',
    ], reason: '下载没结束前不能开始占锁的那一段');
    expect(controller.phase.value, DictionaryDownloadPhase.downloading);

    download.complete();
    expect(await downloading, isTrue);
    final DictionaryFormatUpgradeRun r = await upgrading;
    expect(calls, <String>[
      'download start',
      'upgrade A busy=true',
      'download end',
      'upgrade B,C busy=true',
      'reload busy=false',
      'settle',
      'upgrade A,B,C busy=false',
    ]);
    expect(messages, containsAllInOrder(<String>['1/3', '2/3', '3/3']));
    expect(r.first!.upgraded, <String>['/d/A', '/d/B']);
  });

  test('亮着状态行升级时：用户发起的 run 被拒（忙），状态行说明了是什么占着', () async {
    final Completer<void> gate = Completer<void>();
    final Future<DictionaryFormatUpgradeRun> upgrading = coordinator(
      fakeUpgrade(
        <FushiDictUpgradeOutcome>[up, same, same],
        cleanup: <FushiDictUpgradeOutcome>[same, same, same],
        before: (List<String> dirs) async {
          if (!reloaded && dirs.length == 2) await gate.future;
        },
      ),
    ).run();
    await pump();
    expect(controller.isBusy, isTrue);
    expect(controller.phase.value, DictionaryDownloadPhase.upgrading);
    expect(controller.message.value, '1/3');
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

  test('原生升级抛异常（静默段）：异常交给调用方，锁与状态行都没碰过', () async {
    final DictionaryFormatUpgradeCoordinator c = coordinator((
      List<String> dirs, {
      FushiDictUpgradeProgress? onProgress,
    }) async {
      throw UnsupportedError('no export');
    });
    await expectLater(c.run(), throwsUnsupportedError);
    expect(controller.isBusy, isFalse);
    expect(phases, isEmpty);
  });

  test('原生升级抛异常（占锁段）：锁照样释放、状态行收起，异常交给调用方', () async {
    final DictionaryFormatUpgradeCoordinator c = coordinator(
      fakeUpgrade(
        <FushiDictUpgradeOutcome>[up, same, same],
        before: (List<String> dirs) async {
          if (dirs.length == 2) throw StateError('boom');
        },
      ),
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
