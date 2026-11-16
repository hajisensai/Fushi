import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_download_controller.dart';
import 'package:fushi/src/models/dictionary_format_upgrade.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 启动期词典格式升级的编排（[DictionaryFormatUpgradeCoordinator]）与它依赖的写锁语义
/// （[DictionaryDownloadController.runWhenIdle]）：常态启动不闪 UI、确有升级才亮状态行、
/// 升级过才重载、重载 + 旧引擎释放之后静默补跑、失败只记日志、撞上别的写任务就排队。
void main() {
  late List<String> calls;
  late _RecordingKeepAlive keepAlive;
  late DictionaryDownloadController controller;
  late List<DictionaryDownloadPhase> phases;
  late List<String> messages;
  late List<(String, Object)> logs;

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
    controller.phase.addListener(() => phases.add(controller.phase.value));
    controller.message.addListener(() {
      if (controller.message.value.isNotEmpty) {
        messages.add(controller.message.value);
      }
    });
  });

  tearDown(() => controller.dispose());

  /// 按 [passes] 逐遍给出每本的结果；每一遍记下调用时锁与 phase 的状态。
  DictionaryUpgradeRunner fakeUpgrade(
    List<List<FushiDictUpgradeOutcome>> passes, {
    Future<void>? gate,
  }) {
    int pass = 0;
    return (List<String> dirs, {FushiDictUpgradeProgress? onProgress}) async {
      calls.add('upgrade#$pass busy=${controller.isBusy}');
      if (gate != null) await gate;
      final List<FushiDictUpgradeOutcome> outcomes = passes[pass++];
      final Map<String, FushiDictUpgradeOutcome> results =
          <String, FushiDictUpgradeOutcome>{};
      for (int i = 0; i < dirs.length; i++) {
        results[dirs[i]] = outcomes[i];
        onProgress?.call(i + 1, dirs.length, dirs[i], outcomes[i]);
        // 每本之间让出一次，像真的逐本 await isolate 那样。
        await Future<void>.delayed(Duration.zero);
      }
      return FushiDictUpgradeReport(
        results: results,
        deferred: const <String>[],
      );
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

  test('全部已是最新：状态行一帧都不出现、不碰保活、不重载、不补跑', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      fakeUpgrade(<List<FushiDictUpgradeOutcome>>[
        <FushiDictUpgradeOutcome>[same, same, same],
      ]),
    ).run();

    expect(phases, isEmpty, reason: 'phase 必须始终是 idle');
    expect(messages, isEmpty);
    expect(keepAlive.events, isEmpty, reason: '静默占锁不能拉起前台服务');
    expect(calls, <String>['upgrade#0 busy=true']);
    expect(r.revealed, isFalse);
    expect(r.reloaded, isFalse);
    expect(r.cleanup, isNull);
    expect(logs, isEmpty);
    expect(controller.isBusy, isFalse);
  });

  test('有一本升级：收到第一个「已升级」才亮状态行，之后报进度；出锁后重载 → 等旧引擎 → 锁里静默补跑', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      fakeUpgrade(<List<FushiDictUpgradeOutcome>>[
        <FushiDictUpgradeOutcome>[same, up, same],
        <FushiDictUpgradeOutcome>[same, same, same],
      ]),
    ).run();

    // 第一本（已是最新）时状态行没亮：没有 1/3。
    expect(messages, <String>['2/3', '3/3']);
    expect(phases, <DictionaryDownloadPhase>[
      DictionaryDownloadPhase.upgrading,
      DictionaryDownloadPhase.idle,
    ], reason: '补跑那一遍不再亮');
    expect(controller.cancellable.value, isFalse);
    expect(calls, <String>[
      'upgrade#0 busy=true',
      'reload busy=false',
      'settle',
      'upgrade#1 busy=true',
    ]);
    expect(r.revealed, isTrue);
    expect(r.reloaded, isTrue);
    expect(r.first!.upgraded, <String>['/d/B']);
    expect(r.cleanup!.upgraded, isEmpty);
    expect(keepAlive.events.last, 'stop', reason: '亮过就要在收尾撤保活');
    expect(keepAlive.stops, 1, reason: '静默补跑那一遍不碰保活');
    expect(controller.isBusy, isFalse);
  });

  test('补跑那一遍即使报「已升级」也不再亮、不再重载', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      fakeUpgrade(<List<FushiDictUpgradeOutcome>>[
        <FushiDictUpgradeOutcome>[up, same, same],
        <FushiDictUpgradeOutcome>[same, same, up],
      ]),
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
      fakeUpgrade(<List<FushiDictUpgradeOutcome>>[
        <FushiDictUpgradeOutcome>[fail, na, same],
      ]),
    ).run();
    expect(phases, isEmpty);
    expect(r.reloaded, isFalse);
    expect(calls, <String>['upgrade#0 busy=true']);
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

  test('没有词典：什么都不做', () async {
    final DictionaryFormatUpgradeRun r = await coordinator(
      fakeUpgrade(<List<FushiDictUpgradeOutcome>>[]),
      dirs: const <String>[],
    ).run();
    expect(r.first, isNull);
    expect(calls, isEmpty);
  });

  test('撞上在跑的下载：排队等它结束再升级，不并发、不跳过', () async {
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
      fakeUpgrade(<List<FushiDictUpgradeOutcome>>[
        <FushiDictUpgradeOutcome>[same, same, same],
      ]),
    ).run();
    for (int i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(calls, <String>['download start'], reason: '下载没结束前不能开始升级');

    download.complete();
    expect(await downloading, isTrue);
    await upgrading;
    expect(calls, <String>[
      'download start',
      'download end',
      'upgrade#0 busy=true',
    ]);
  });

  test('静默升级占着锁时：用户发起的 run 照旧被拒（isBusy），且状态行仍不亮', () async {
    final Completer<void> gate = Completer<void>();
    final Future<DictionaryFormatUpgradeRun> upgrading = coordinator(
      fakeUpgrade(<List<FushiDictUpgradeOutcome>>[
        <FushiDictUpgradeOutcome>[same, same, same],
      ], gate: gate.future),
    ).run();
    await Future<void>.delayed(Duration.zero);
    expect(controller.isBusy, isTrue);
    expect(controller.phase.value, DictionaryDownloadPhase.idle);
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
    expect(phases, isEmpty);
  });

  test('原生升级抛异常：锁照样释放，异常交给调用方', () async {
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
