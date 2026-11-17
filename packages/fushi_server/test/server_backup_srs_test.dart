// 服务端整机备份带上复习库（docs/specs/2026-11-05-server-srs-design.md §4.7；格式第 2 版 = G11-4）：新代库 srs4.db
// 走内核一致快照，不带活库的 -wal / -shm；serve 在跑（走开着的连接）与离线（临时打开）两条路都要能还原出原来的数据。
// 协议 3 的旧库 srs.db（迁移之后的封存副本）原样随包、原样还原。
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_server/src/backup/server_backup.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_server/src/server_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_rwkv.dart';

const String kJa = '01928c3e-0000-7000-8000-00000000a0a0';

void main() {
  late Directory tmp;
  late Directory dataDir;
  late FushiDatabase db;
  const ServerSrsConfig config = ServerSrsConfig(profiles: <String>[kJa]);

  ServerSrs srsAt(Directory support) => ServerSrs(
    // RWKV 权重不联网下载（下载当场失败 = RWKV 没就绪）。
    rwkvHttpClient: noNetworkHttpClient,
    support: support,
    syncData: Directory(p.join(tmp.path, 'interconnect'))
      ..createSync(recursive: true),
    deviceId: 'server-device',
    hostId: 'host',
    config: () => config,
    engine: () => null,
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_backup_srs_');
    dataDir = Directory(p.join(tmp.path, 'data'));
    Directory(p.join(dataDir.path, 'support')).createSync(recursive: true);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  /// 直接开 [support] 里的复习库跑 [body]（不经 ServerSrs：它要第一轮同步跑完才把库交出来，这里只关心库里的数据）。
  Future<T> withStore<T>(
    Directory support,
    Future<T> Function(SrsDbStore store) body,
  ) async {
    final SrsStorage storage = await SrsStorage.open(directory: support.path);
    try {
      return await body(
        await SrsDbStore.open(
          core: storage.core,
          profileUid: kJa,
          deviceId: 'server-device',
        ),
      );
    } finally {
      await storage.close();
    }
  }

  Future<void> seedDeck(Directory support, String deck) =>
      withStore(support, (SrsDbStore s) => s.createDeck(deck));

  /// 支持目录 [support] 里的复习库还有没有牌组 [deck]。
  Future<bool> hasDeck(Directory support, String deck) =>
      withStore(support, (SrsDbStore s) async {
        final tree = await s.deckTree();
        return tree.decks.any((d) => tree.fullName(d.id) == deck);
      });

  /// 把包里的 srs4.db 解到一个新的支持目录，看牌组还在不在。
  Future<bool> restoredHasDeck(File zip, String deck) async {
    final Directory support = Directory(p.join(tmp.path, 'restored'))
      ..createSync();
    final InputFileStream input = InputFileStream(zip.path);
    try {
      final Archive archive = ZipDecoder().decodeBuffer(input);
      final ArchiveFile entry = archive.findFile('data/support/srs4.db')!;
      File(
        p.join(support.path, 'srs4.db'),
      ).writeAsBytesSync(entry.content as List<int>);
    } finally {
      input.closeSync();
    }
    return hasDeck(support, deck);
  }

  Set<String> names(File zip) {
    final InputFileStream input = InputFileStream(zip.path);
    try {
      return ZipDecoder()
          .decodeBuffer(input)
          .files
          .map((ArchiveFile f) => f.name)
          .toSet();
    } finally {
      input.closeSync();
    }
  }

  test('serve 在跑：走开着的连接出快照，包里有 srs4.db、没有 -wal / -shm，还原后数据在', () async {
    final Directory support = Directory(p.join(dataDir.path, 'support'));
    await seedDeck(support, 'Backed up');
    final ServerSrs srs = srsAt(support);
    await srs.start();
    expect(srs.snapshotFn, isNotNull);
    final File zip = await createServerBackup(
      db: db,
      dataDir: dataDir.path,
      configFile: null,
      output: File(p.join(tmp.path, 'out', 'live.zip')),
      snapshotSrs: srs.snapshotFn,
    );
    await srs.stop();
    final Set<String> entries = names(zip);
    expect(entries, contains('data/support/srs4.db'));
    expect(entries.where((String n) => n.contains('srs4.db-')), isEmpty);
    expect(readServerBackupManifest(zip).formatVersion, 2);
    expect(await restoredHasDeck(zip, 'Backed up'), isTrue);
  });

  test('离线（没有开着的复习库连接）：临时打开库目录出快照', () async {
    final Directory support = Directory(p.join(dataDir.path, 'support'));
    await seedDeck(support, 'Offline');
    final ServerSrs srs = srsAt(support);
    await srs.start();
    await srs.stop();
    expect(srs.snapshotFn, isNull);
    final File zip = await createServerBackup(
      db: db,
      dataDir: dataDir.path,
      configFile: null,
      output: File(p.join(tmp.path, 'out', 'offline.zip')),
    );
    expect(names(zip), contains('data/support/srs4.db'));
    expect(await restoredHasDeck(zip, 'Offline'), isTrue);
  });

  test('从没开过复习库：包里没有复习库', () async {
    final File zip = await createServerBackup(
      db: db,
      dataDir: dataDir.path,
      configFile: null,
      output: File(p.join(tmp.path, 'out', 'none.zip')),
    );
    expect(names(zip).where((String n) => n.contains('srs')), isEmpty);
  });

  test('v2 往返：整机还原后新代库照常打开、封存的旧库逐字节原样回来', () async {
    final Directory support = Directory(p.join(dataDir.path, 'support'));
    await seedDeck(support, 'Round trip');
    // 迁移之后原位封存的协议 3 库（没人打开它）：内容不透明，只要求原样往返。
    final List<int> sealed = List<int>.generate(4096, (int i) => i * 7 % 251);
    File(p.join(support.path, 'srs.db')).writeAsBytesSync(sealed);
    File(p.join(support.path, 'srs.db-shm')).writeAsBytesSync(<int>[1, 2, 3]);
    final File zip = await createServerBackup(
      db: db,
      dataDir: dataDir.path,
      configFile: null,
      output: File(p.join(tmp.path, 'out', 'rt.zip')),
    );
    final Set<String> entries = names(zip);
    expect(entries, contains('data/support/srs.db'));
    expect(entries, isNot(contains('data/support/srs.db-shm')));

    final Directory target = Directory(p.join(tmp.path, 'target'));
    final ServerRestoreResult r = await restoreServerBackup(
      backup: zip,
      dataDir: target.path,
      configFile: null,
    );
    expect(r.manifest.formatVersion, 2);
    final Directory restored = Directory(p.join(target.path, 'support'));
    expect(
      File(p.join(restored.path, 'srs.db')).readAsBytesSync(),
      orderedEquals(sealed),
    );
    // 封存的旧库原样回来、新代库在：开新代库（不碰旧库）。旧库是测试造的假字节，开库时新代库已在，状态是 ready。
    File(p.join(restored.path, 'srs.db')).deleteSync();
    expect(await hasDeck(restored, 'Round trip'), isTrue);
  });
}
