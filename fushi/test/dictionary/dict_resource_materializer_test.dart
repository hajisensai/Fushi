// BUG-2504：词典资源目录触读物化探测（`materializeDictResources`）的行为测试 +
// 生产接线守卫。
//
// 不变式：主 isolate 上的同步 FFI 装载只能碰已物化的字节。iCloud「优化储存空间」/
// OneDrive「按需文件」会把 `~/Documents` 下的词典文件驱逐成 dataless，同步读它会
// 在内核里无限期等云端回填，Timer 看门狗全部失效。探测跑在后台 isolate、带总预算，
// 预算内没证明可读的词典本次不装。
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

  test('生产接线守卫：_rebuildDictPathsCacheAsync 在 scheduleTyped 之前做物化探测', () {
    final String src = File('lib/src/models/app_model.dart').readAsStringSync();
    final String body = maskCommentsAndStrings(
      methodBody(src, 'Future<void> _rebuildDictPathsCacheAsync() async {'),
    );
    final int materialize = body.indexOf('materializeDictResources(');
    final int schedule = body.indexOf('FushiDicts.scheduleTyped(');
    final int load = body.indexOf('FushiDicts.loadPendingAsync(');
    expect(
      materialize,
      greaterThanOrEqualTo(0),
      reason: '装载前必须先做触读物化探测（BUG-2504）',
    );
    expect(schedule, greaterThanOrEqualTo(0));
    expect(load, greaterThanOrEqualTo(0));
    expect(
      materialize,
      lessThan(schedule),
      reason: '物化探测必须在 scheduleTyped 之前——分桶之后再探就晚了',
    );
    expect(schedule, lessThan(load));
    // 探测结果必须真的喂进 exists 判据，而不是只调一下、结果丢掉。
    expect(
      body,
      contains('readyDirs.contains('),
      reason: '探测结果必须参与 DictPathEntry.exists 的判定',
    );
    expect(
      body,
      contains('await materializeDictResources('),
      reason: '探测必须被 await，否则装载照样先跑',
    );
    // 探测结论要留给同步路径复用，而不是用完即丢。
    expect(body, contains('_probedDictDirs = existingDirs.toSet();'));
    expect(body, contains('_materializedDictDirs = readyDirs;'));
    expect(
      body,
      contains('onLateReport: _onDictDirMaterializedLate'),
      reason: '预算后拉回本地的目录要能补进可读集并触发重装，不能只打日志',
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
      contains('exists: Directory(p).existsSync() && _dictDirMaterialized(p)'),
      reason: '同步路径的 exists 判据必须与上一轮物化探测的结论相与',
    );
    // 判据本身：没探过的目录（刚导入 / 互联传输落盘）放行，探过且未证明可读的挡住。
    final String predicate = maskCommentsAndStrings(
      methodBody(src, 'bool _dictDirMaterialized(String dir) =>'),
    );
    expect(predicate, contains('!_probedDictDirs.contains(dir)'));
    expect(predicate, contains('_materializedDictDirs.contains(dir)'));
  });
}
