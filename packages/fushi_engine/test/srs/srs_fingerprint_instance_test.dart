// 内容指纹 / 统计指纹 / RWKV 刷新键里的计数只在 SrsDbStore 对象的内存里、每个对象从头数，而纪元是落盘的：同一个
// profile 换一个副本对象（进程重启，或同一进程里副本关掉重开）之后，计数会回到以前出现过的值而内容已经不同
// （ABA）。读者按「指纹相等 = 没变」跳过重读：远程客户端按主机回包的 `fp` 缓存 dayContext、同步调度按位置记上次
// 媒体对账时的内容指纹、RWKV 服务按 rwkvScoresKey 决定要不要整表重查。指纹里拼上副本对象的实例号之后，换对象
// 指纹必然不同。
import 'dart:io';

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000f1';

typedef _Opened = ({SrsDbStore store, SrsCore core});

void main() {
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

  Future<_Opened> open() async {
    final SrsCore core = SrsCore.open(path);
    final SrsDbStore store = await SrsDbStore.open(
      core: core,
      profileUid: kProfile,
      deviceId: 'A',
      engine: FfiFsrsEngine.tryCreate(),
    );
    return (store: store, core: core);
  }

  Future<void> close(_Opened o) async {
    o.core.close();
  }

  Future<String> addNote(SrsDbStore s, String expression) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(kProfile, 'Expression'): expression,
    },
  );

  test('换一个副本对象之后，三个带内存计数的指纹都不会与换之前的值相同', () async {
    // 第一次打开只为把库初始化好（内置笔记类型、本机状态行、纪元），之后每次打开都从同一个起点数。
    await close(await open());

    final _Opened a = await open();
    final String content0 = a.store.contentFingerprint;
    final String stats0 = a.store.statsFingerprint;
    final String rwkv0 = a.store.rwkvScoresKey;
    final String change0 = await a.store.changeFingerprint();
    // 一条内容写入：落了笔记与卡，内容、统计都变了。
    await addNote(a.store, '一');
    expect(a.store.contentFingerprint, isNot(content0));
    await close(a);

    // 同一个库再开一个副本对象（纪元相同）：内存计数从头数，回到 [a] 刚打开时的值；但库里多了一条笔记。
    final _Opened b = await open();
    addTearDown(() => close(b));
    expect(
      b.store.rwkvScoresClearKey,
      a.store.rwkvScoresClearKey,
      reason: '纪元落盘，换对象不换纪元（换纪元 = RWKV 分数表清空重算）',
    );
    expect(
      b.store.contentFingerprint,
      isNot(content0),
      reason: '内容已经不同（多了一条笔记），内容指纹却与写入之前的那个相同',
    );
    expect(b.store.statsFingerprint, isNot(stats0));
    expect(b.store.rwkvScoresKey, isNot(rwkv0));
    // 变化指纹（纪元 + 落盘的修订号）本来就不会撞：它不带实例号，跨对象可比。
    expect(await b.store.changeFingerprint(), isNot(change0));
  });

  test('同一个副本对象上指纹照旧：没有写入不变，只落日志不动内容指纹', () async {
    final _Opened a = await open();
    addTearDown(() => close(a));
    final String content0 = a.store.contentFingerprint;
    final String stats0 = a.store.statsFingerprint;
    expect(a.store.contentFingerprint, content0);
    expect(a.store.statsFingerprint, stats0);
    await addNote(a.store, '一');
    final String content1 = a.store.contentFingerprint;
    final String stats1 = a.store.statsFingerprint;
    expect(content1, isNot(content0));
    expect(stats1, isNot(stats0));
    expect(a.store.contentFingerprint, content1);
    expect(a.store.statsFingerprint, stats1);
  });
}
