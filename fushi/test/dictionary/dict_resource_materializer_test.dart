// BUG-2504：词典资源目录触读物化探测（`materializeDictResources`）的行为测试 +
// 生产接线守卫。
//
// 不变式：主 isolate 上的同步 FFI 装载只能碰已物化的字节。iCloud「优化储存空间」/
// OneDrive「按需文件」会把 `~/Documents` 下的词典文件驱逐成 dataless，同步读它会
// 在内核里无限期等云端回填，Timer 看门狗全部失效。探测跑在后台 isolate、带总预算，
// 预算内没证明可读的词典本次不装。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/dictionary/dict_resource_materializer.dart';
import 'package:path/path.dart' as p;

import '../helpers/source_guard.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dict_materializer_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 造一个像引擎资源目录的词典目录：几个小文件 + 一个空文件 + 一个子目录。
  String makeDictDir(String name, {int files = 3}) {
    final Directory dir = Directory(p.join(root.path, name))..createSync();
    for (int i = 0; i < files; i++) {
      File(p.join(dir.path, 'blob_$i.bin')).writeAsBytesSync(<int>[i, i + 1]);
    }
    File(p.join(dir.path, 'empty.idx')).writeAsBytesSync(const <int>[]);
    Directory(p.join(dir.path, 'nested')).createSync();
    return dir.path;
  }

  /// 三个集合互不重叠且并集恰好等于输入去重集——每条用例都要满足的结构契约。
  void expectPartition(DictResourceMaterializeResult r, List<String> input) {
    final List<String> all = <String>[
      ...r.ready,
      ...r.pending,
      ...r.failed.keys,
    ];
    expect(all.toSet().length, all.length, reason: '三个集合有重叠');
    expect(all.toSet(), input.toSet(), reason: '并集 != 输入');
  }

  test('正常目录（小文件 + 空文件 + 子目录）全部 ready，顺序保持', () async {
    final List<String> dirs = <String>[
      makeDictDir('a'),
      makeDictDir('b', files: 8),
      makeDictDir('c', files: 1),
    ];
    final DictResourceMaterializeResult r = await materializeDictResources(
      dirs,
      budget: const Duration(seconds: 30),
    );
    expect(r.ready, dirs);
    expect(r.pending, isEmpty);
    expect(r.failed, isEmpty);
    expectPartition(r, dirs);
  });

  test('空目录也是 ready：没有文件要物化', () async {
    final String empty = Directory(p.join(root.path, 'empty')).path;
    Directory(empty).createSync();
    final DictResourceMaterializeResult r = await materializeDictResources(
      <String>[empty],
      budget: const Duration(seconds: 30),
    );
    expect(r.ready, <String>[empty]);
    expect(r.pending, isEmpty);
    expect(r.failed, isEmpty);
  });

  test('不存在的目录归 failed，不拖累同批其它目录', () async {
    final String ok = makeDictDir('ok');
    final String missing = p.join(root.path, 'does-not-exist');
    final DictResourceMaterializeResult r = await materializeDictResources(
      <String>[missing, ok],
      budget: const Duration(seconds: 30),
    );
    expect(r.ready, <String>[ok]);
    expect(r.pending, isEmpty);
    expect(r.failed.keys, <String>[missing]);
    expect(r.failed[missing], startsWith('directory missing'));
    expectPartition(r, <String>[missing, ok]);
  });

  test('输入为空直接返回空结果（不起 isolate）', () async {
    final DictResourceMaterializeResult r = await materializeDictResources(
      const <String>[],
      budget: Duration.zero,
    );
    expect(r.ready, isEmpty);
    expect(r.pending, isEmpty);
    expect(r.failed, isEmpty);
  });

  test('预算耗尽：未回报的目录归 pending，worker 不被 kill、预算后仍把剩余目录做完', () async {
    final List<String> dirs = <String>[
      for (int i = 0; i < 4; i++) makeDictDir('slow_$i'),
    ];
    final List<String> late = <String>[];
    // worker 每个目录前 sleep 150ms，预算 20ms：第一个目录的回报都到不了，全部 pending。
    // 用显式的 per-directory 延迟而不是「堆一大堆目录赌机器慢」，结果不依赖时序。
    final DictResourceMaterializeResult r = await materializeDictResources(
      dirs,
      budget: const Duration(milliseconds: 20),
      debugPerDirectoryDelay: const Duration(milliseconds: 150),
      onLateReport: (String dir, String? error) {
        expect(error, isNull);
        late.add(dir);
      },
    );
    expect(r.ready, isEmpty);
    expect(r.failed, isEmpty);
    expect(r.pending, dirs);
    expectPartition(r, dirs);

    // worker 继续跑：预算后 4 × 150ms 内全部回报都会经 onLateReport 到达。
    final Stopwatch sw = Stopwatch()..start();
    while (late.length < dirs.length &&
        sw.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(late, dirs, reason: '预算耗尽后 worker 应继续物化剩余目录并逐个回报');
  });

  test('预算耗尽时已回报的目录仍按各自结果归类（ready / failed 不被超时抹平）', () async {
    final String ok = makeDictDir('fast_ok');
    final String missing = p.join(root.path, 'fast_missing');
    final List<String> slow = <String>[
      for (int i = 0; i < 3; i++) makeDictDir('after_$i'),
    ];
    final List<String> dirs = <String>[ok, missing, ...slow];
    // worker 每个目录前 sleep 500ms：回报分别落在 ~500 / ~1000 / ~1500ms…，预算
    // 1250ms 恰好放前两个进来、后三个到不了。看门狗 Timer 只可能晚触发（预算变长），
    // 两侧各留 250ms 余量。
    final DictResourceMaterializeResult r = await materializeDictResources(
      dirs,
      budget: const Duration(milliseconds: 1250),
      debugPerDirectoryDelay: const Duration(milliseconds: 500),
    );
    expect(r.ready, <String>[ok]);
    expect(r.failed.keys, <String>[missing]);
    expect(r.pending, slow);
    expectPartition(r, dirs);
  });

  group('DictResourceAvailability（BUG-4510）', () {
    /// 可控的假探测器：每次调用记一笔，返回预设结果，并把 onLateReport 交给测试，
    /// 由测试决定「预算后回报」何时到达——不赌机器快慢。
    late List<List<String>> calls;
    late List<void Function(String dir, String? error)> lateSinks;
    late DictResourceMaterializeResult Function(List<String>) answer;

    DictResourceAvailability makeTracker({void Function()? onLateReady}) {
      calls = <List<String>>[];
      lateSinks = <void Function(String dir, String? error)>[];
      return DictResourceAvailability(
        probe:
            (
              List<String> dirs, {
              void Function(String dir, String? error)? onLateReport,
            }) async {
              calls.add(List<String>.of(dirs));
              if (onLateReport != null) lateSinks.add(onLateReport);
              return answer(dirs);
            },
        onLateReady: onLateReady,
      );
    }

    DictResourceMaterializeResult allPending(List<String> dirs) =>
        DictResourceMaterializeResult(
          ready: const <String>[],
          pending: dirs,
          failed: const <String, String>{},
        );

    test('在途目录不重复探：第二轮 resolve 不为预算内没读完的目录再起 worker', () async {
      final DictResourceAvailability t = makeTracker();
      answer = allPending;
      final List<String> dirs = <String>['/d/a', '/d/b', '/d/c'];

      final DictResourceResolution first = await t.resolve(dirs);
      expect(first.pending, dirs);
      expect(first.ready, isEmpty);

      // 旧实现：每次重装都对全部目录重起 worker → worker 无界叠加、彼此抢 IO。
      final DictResourceResolution second = await t.resolve(dirs);
      expect(calls, hasLength(1), reason: '在途目录不能再交给新的探测 worker');
      expect(second.probedNow, isEmpty);
      expect(second.pending, dirs);
      expect(t.inFlightCount, 3);
    });

    test('已证明物化的目录单调累积：后续轮次不覆盖、不重探', () async {
      final DictResourceAvailability t = makeTracker();
      answer = (List<String> dirs) => DictResourceMaterializeResult(
        ready: <String>[
          for (final String d in dirs)
            if (d != '/d/slow') d,
        ],
        pending: <String>[
          for (final String d in dirs)
            if (d == '/d/slow') d,
        ],
        failed: const <String, String>{},
      );
      await t.resolve(<String>['/d/a', '/d/slow']);
      expect(t.isReady('/d/a'), isTrue);
      expect(t.isLoadable('/d/slow'), isFalse, reason: '探过且未证明可读的不进引擎');

      lateSinks.single('/d/slow', null);
      expect(t.isReady('/d/slow'), isTrue);

      // 旧实现在下一轮用「本轮 ready」覆盖可读集；这里再 resolve 不探任何目录，
      // 两本都保持可读。
      final DictResourceResolution again = await t.resolve(<String>[
        '/d/a',
        '/d/slow',
      ]);
      expect(calls, hasLength(1));
      expect(again.ready, <String>['/d/a', '/d/slow']);
    });

    test('预算后回报：在途全部到齐才触发一次 onLateReady，不是每本一次', () async {
      int reloads = 0;
      final DictResourceAvailability t = makeTracker(
        onLateReady: () => reloads++,
      );
      answer = allPending;
      await t.resolve(<String>['/d/a', '/d/b', '/d/c']);

      lateSinks.single('/d/a', null);
      lateSinks.single('/d/b', null);
      expect(reloads, 0, reason: '还有在途目录时不重装（旧实现每本回报后 2s 就重装一次）');
      lateSinks.single('/d/c', null);
      expect(reloads, 1);
      expect(t.inFlightCount, 0);
    });

    test('预算后全部失败：不触发重装（没有新可读的目录）', () async {
      int reloads = 0;
      final DictResourceAvailability t = makeTracker(
        onLateReady: () => reloads++,
      );
      answer = allPending;
      await t.resolve(<String>['/d/a']);
      lateSinks.single('/d/a', 'boom');
      expect(reloads, 0);
      expect(t.isLoadable('/d/a'), isFalse);
    });

    test('失败的目录下一轮会重探；没探过的目录放行给同步路径', () async {
      final DictResourceAvailability t = makeTracker();
      answer = (List<String> dirs) => DictResourceMaterializeResult(
        ready: const <String>[],
        pending: const <String>[],
        failed: <String, String>{for (final String d in dirs) d: 'io'},
      );
      expect(t.isLoadable('/d/new'), isTrue, reason: '没探过（刚导入）的目录放行');
      await t.resolve(<String>['/d/x']);
      expect(t.isLoadable('/d/x'), isFalse);
      await t.resolve(<String>['/d/x']);
      expect(calls, <List<String>>[
        <String>['/d/x'],
        <String>['/d/x'],
      ]);
    });

    test('真探测器：预算后到齐只重装一次，重装那轮不再起 worker', () async {
      final List<String> dirs = <String>[
        for (int i = 0; i < 3; i++) makeDictDir('real_$i'),
      ];
      int probes = 0;
      final Completer<DictResourceResolution> reloaded =
          Completer<DictResourceResolution>();
      late final DictResourceAvailability t;
      t = DictResourceAvailability(
        probe:
            (
              List<String> d, {
              void Function(String dir, String? error)? onLateReport,
            }) {
              probes++;
              return materializeDictResources(
                d,
                budget: const Duration(milliseconds: 20),
                debugPerDirectoryDelay: const Duration(milliseconds: 100),
                onLateReport: onLateReport,
              );
            },
        onLateReady: () {
          t.resolve(dirs).then(reloaded.complete);
        },
      );
      final DictResourceResolution first = await t.resolve(dirs);
      expect(first.pending, dirs);
      final DictResourceResolution after = await reloaded.future.timeout(
        const Duration(seconds: 10),
      );
      expect(after.ready, dirs);
      expect(probes, 1, reason: '重装那轮所有目录都已证明可读，不应再起 worker');
    });
  });

  test('生产接线守卫：异步重建经 _dictResources 探测、先探后排期再装载', () {
    final String src = File('lib/src/models/app_model.dart').readAsStringSync();
    final String body = maskCommentsAndStrings(
      methodBody(
        src,
        'Future<bool> _scheduleDictPathsAsync([bool onlyIfChanged = false]) async {',
      ),
    );
    final int resolve = body.indexOf('await _dictResources.resolve(');
    final int migrate = body.indexOf('_migrateDictionaryTypes();');
    final int schedule = body.indexOf('FushiDicts.scheduleTyped(');
    expect(resolve, greaterThanOrEqualTo(0), reason: '装载前必须先做触读物化探测（BUG-2504）');
    expect(schedule, greaterThan(resolve), reason: '物化探测必须在 scheduleTyped 之前');
    expect(
      migrate,
      greaterThan(resolve),
      reason: '类型自愈是主 isolate 同步读，必须在物化探测之后（BUG-4510）',
    );
    expect(
      body,
      contains('readyDirs.contains('),
      reason: '探测结果必须参与 DictPathEntry.exists 的判定',
    );
    expect(
      body,
      isNot(contains('materializeDictResources(')),
      reason: '物化状态只归 DictResourceAvailability 持有，不许旁路另起 worker',
    );

    final String rebuild = maskCommentsAndStrings(
      methodBody(src, 'Future<void> _rebuildDictPathsCacheAsync() async {'),
    );
    final int sched = rebuild.indexOf('await _scheduleDictPathsAsync();');
    final int load = rebuild.indexOf('FushiDicts.loadPendingAsync(');
    expect(sched, greaterThanOrEqualTo(0));
    expect(load, greaterThan(sched));

    // 启动看门狗只罩「数据根 IO」那一段，不罩逐本让出的装载（BUG-4510）。
    final String code = maskComments(src);
    expect(
      code,
      contains("_guardInitIo('rebuild-dict-paths', _scheduleDictPathsAsync())"),
    );
    expect(code, isNot(contains('_rebuildDictPathsCacheAsync());')));

    final String migrateBody = maskCommentsAndStrings(
      methodBody(src, 'void _migrateDictionaryTypes() {'),
    );
    expect(
      migrateBody,
      contains('_dictResources.isReady('),
      reason: '类型自愈只能同步读已证明物化的目录',
    );
  });

  test('生产接线守卫：同步 _rebuildDictPathsCache 同样只排期已物化的目录', () {
    // 同步路径挂在每一次词典元数据写入上（隐藏 / 折叠 / 语言开关）。它若仍只看
    // existsSync 就把全部目录排期，启动期被跳过的 dataless 词典会在用户改任一开关
    // 后被重新排进引擎，首次查词在主 isolate 同步读它——原症状换个入口复现。
    final String src = File('lib/src/models/app_model.dart').readAsStringSync();
    final String body = maskCommentsAndStrings(
      methodBody(src, 'void _rebuildDictPathsCache() {'),
    );
    expect(body, contains('FushiDicts.scheduleTyped('));
    expect(
      body,
      contains(
        'exists: Directory(p).existsSync() && _dictResources.isLoadable(p)',
      ),
      reason: '同步路径的 exists 判据必须与物化探测的结论相与',
    );
  });
}
