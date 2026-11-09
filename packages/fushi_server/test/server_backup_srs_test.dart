// 服务端整机备份带上复习库（docs/specs/2026-11-05-server-srs-design.md §4.7）：srs.db 走 Rust 一致快照，
// 不带活库的 -wal / -shm；serve 在跑（走开着的连接）与离线（临时打开）两条路都要能还原出原来的数据。
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_server/src/backup/server_backup.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_server/src/server_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String kJa = '01928c3e-0000-7000-8000-00000000a0a0';

void main() {
  late Directory tmp;
  late Directory dataDir;
  late FushiDatabase db;
  const ServerSrsConfig config = ServerSrsConfig(profiles: <String>[kJa]);

  ServerSrs srsAt(Directory support) => ServerSrs(
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

  /// 把包里的 srs.db 解到一个新的支持目录，用它开一份 ServerSrs，看牌组还在不在。
  Future<bool> restoredHasDeck(File zip, String deck) async {
    final Directory support = Directory(p.join(tmp.path, 'restored'))
      ..createSync();
    final InputFileStream input = InputFileStream(zip.path);
    try {
      final Archive archive = ZipDecoder().decodeBuffer(input);
      final ArchiveFile entry = archive.findFile('data/support/srs.db')!;
      File(
        p.join(support.path, 'srs.db'),
      ).writeAsBytesSync(entry.content as List<int>);
    } finally {
      input.closeSync();
    }
    final ServerSrs restored = srsAt(support);
    await restored.start();
    await restored.syncNow();
    try {
      final tree = await restored.storeFor(kJa)!.deckTree();
      return tree.decks.any((d) => tree.fullName(d.id) == deck);
    } finally {
      await restored.stop();
    }
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

  test('serve 在跑：走开着的连接出快照，包里有 srs.db、没有 -wal / -shm，还原后数据在', () async {
    final ServerSrs srs = srsAt(Directory(p.join(dataDir.path, 'support')));
    await srs.start();
    await srs.syncNow();
    await srs.storeFor(kJa)!.createDeck('Backed up');
    final File zip = await createServerBackup(
      db: db,
      dataDir: dataDir.path,
      configFile: null,
      output: File(p.join(tmp.path, 'out', 'live.zip')),
      snapshotSrs: srs.snapshotFn,
    );
    await srs.stop();
    final Set<String> entries = names(zip);
    expect(entries, contains('data/support/srs.db'));
    expect(entries.where((String n) => n.contains('srs.db-')), isEmpty);
    expect(await restoredHasDeck(zip, 'Backed up'), isTrue);
  });

  test('离线（没有开着的复习库连接）：临时打开 srs.db 出快照', () async {
    final ServerSrs srs = srsAt(Directory(p.join(dataDir.path, 'support')));
    await srs.start();
    await srs.syncNow();
    await srs.storeFor(kJa)!.createDeck('Offline');
    await srs.stop();
    expect(srs.snapshotFn, isNull);
    final File zip = await createServerBackup(
      db: db,
      dataDir: dataDir.path,
      configFile: null,
      output: File(p.join(tmp.path, 'out', 'offline.zip')),
    );
    expect(names(zip), contains('data/support/srs.db'));
    expect(await restoredHasDeck(zip, 'Offline'), isTrue);
  });

  test('从没开过复习库：包里没有 srs.db', () async {
    final File zip = await createServerBackup(
      db: db,
      dataDir: dataDir.path,
      configFile: null,
      output: File(p.join(tmp.path, 'out', 'none.zip')),
    );
    expect(names(zip).where((String n) => n.contains('srs.db')), isEmpty);
  });
}
