// 内容指纹 / 统计指纹 / RWKV 刷新键 / 牌组树键 / 落库指纹是内核在内存里按 profile 持有的计数（native/fushi_fsrs/src/store/
// refresh.rs，`refresh_keys`），SrsDbStore 每次现读、不存。读者按「指纹相等 = 没变」跳过重读：远程客户端按主机回包的
// `fp` 缓存 dayContext、同步调度按位置记上次媒体对账时的内容指纹、RWKV 服务按 rwkvScoresKey 决定要不要整表重查。
//
// 第 14 步及以前这些计数在 SrsDbStore 对象的内存里、每个对象从头数：换一个副本对象计数回到以前出现过的值而内容已经
// 不同（ABA），于是指纹里拼了进程启动 ID 与对象序号；同一个 profile 的两个副本对象各数各的，一方写了另一方的指纹不动。
// 现在：同一次打开库里计数只增不减、所有副本对象读到同一组值；每次打开库换一个随机前缀。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show SrsDatabase;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_database_executor.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000f1';

typedef _Opened = ({SrsDbStore store, SrsDatabase db, SrsCore core});

typedef _Keys = ({
  String content,
  String stats,
  String rwkv,
  String tree,
  String landed,
});

_Keys _keys(SrsDbStore s) => (
  content: s.contentFingerprint,
  stats: s.statsFingerprint,
  rwkv: s.rwkvScoresKey,
  tree: s.deckTreeKey,
  landed: s.landedFingerprint,
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('srs_fp_instance_');
    path = p.join(dir.path, 'srs.db');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄晚释放。
    }
  });

  Future<SrsDbStore> openOn(SrsCore core, SrsDatabase db) => SrsDbStore.open(
    db: db,
    core: core,
    profileUid: kProfile,
    deviceId: 'A',
    engine: FfiFsrsEngine.tryCreate(),
  );

  Future<_Opened> open() async {
    final SrsCore core = SrsCore.open(path);
    final SrsDatabase db = SrsDatabase(srsInlineExecutor(core));
    return (store: await openOn(core, db), db: db, core: core);
  }

  Future<void> close(_Opened o) async {
    await o.db.close();
    o.core.close();
  }

  Future<String> addNote(SrsDbStore s, String expression) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(kProfile, 'Expression'): expression,
    },
  );

  void expectAllDiffer(_Keys a, _Keys b, String why) {
    expect(a.content, isNot(b.content), reason: 'content: $why');
    expect(a.stats, isNot(b.stats), reason: 'stats: $why');
    expect(a.rwkv, isNot(b.rwkv), reason: 'rwkv: $why');
    expect(a.tree, isNot(b.tree), reason: 'tree: $why');
    expect(a.landed, isNot(b.landed), reason: 'landed: $why');
  }

  test('关库重开之后，五个键都不会与关之前出现过的值相同', () async {
    // 第一次打开只为把库初始化好（内置笔记类型、本机状态行、纪元），之后每次打开都从同一个起点数。
    await close(await open());

    final _Opened a = await open();
    final _Keys k0 = _keys(a.store);
    final String change0 = await a.store.changeFingerprint();
    await addNote(a.store, '一');
    final _Keys k1 = _keys(a.store);
    expectAllDiffer(k1, k0, '一条内容写入');
    await close(a);
    expect(_keys(a.store), k1, reason: '库关了之后不再变：停在关之前最后读到的那一组');

    // 同一个库再开一次（纪元相同）：计数从头数，但前缀换了；库里多了一条笔记。
    final _Opened b = await open();
    addTearDown(() => close(b));
    expect(
      b.store.rwkvScoresClearKey,
      a.store.rwkvScoresClearKey,
      reason: '纪元落盘，重开不换纪元（换纪元 = RWKV 分数表清空重算）',
    );
    final _Keys kb = _keys(b.store);
    expectAllDiffer(kb, k0, '重开之后与写入之前那次打开的值');
    expectAllDiffer(kb, k1, '重开之后与写入之后那次打开的值');
    // 变化指纹（纪元 + 落盘的修订号）本来就不会撞。
    expect(await b.store.changeFingerprint(), isNot(change0));
  });

  test('同一个库上的两个副本对象读到同一组键，一方写了另一方跟着变', () async {
    final _Opened a = await open();
    addTearDown(() => close(a));
    final SrsDbStore b = await openOn(a.core, a.db);
    // 新开的副本对象（`local_state` 带 `reload`）让这个 profile 按键记的缓存作废一次：两个对象此刻读到同一组新值。
    final _Keys k0 = _keys(a.store);
    expect(_keys(b), k0);
    await addNote(a.store, '一');
    final _Keys k1 = _keys(b);
    expect(_keys(a.store), k1);
    expectAllDiffer(k1, k0, 'a 写了一条笔记，b 读到的键也变了');
  });

  test('同一个副本对象上：没有写入不变，只落日志不动内容指纹', () async {
    final _Opened a = await open();
    addTearDown(() => close(a));
    final _Keys k0 = _keys(a.store);
    expect(_keys(a.store), k0, reason: '读键本身不动键');
    await addNote(a.store, '一');
    final _Keys k1 = _keys(a.store);
    expect(k1.content, isNot(k0.content));
    expect(k1.stats, isNot(k0.stats));
    expect(_keys(a.store), k1);
    // 重读本机状态：按键记的缓存一律作废。
    await a.store.reloadLocal();
    final _Keys k2 = _keys(a.store);
    expect(k2.content, isNot(k1.content));
    expect(k2.rwkv, isNot(k1.rwkv));
    expect(k2.tree, isNot(k1.tree));
  });
}
