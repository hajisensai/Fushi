import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_backup_store.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_test_storage.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000c2';

/// 复习备份写盘时的流式摘要（`_deflateFile`）改走 Rust：CRC-32 链式 `ffcCrc32`、
/// SHA-256 `FfcSha256Hasher`。钉住产物与第三方实现逐字节对得上：
/// - 两个 deflate 条目的头 CRC = archive `getCrc32(解压后正文)`，archive
///   `verify: true` 能解开整包（别的读端校验 CRC 不会拒收）；
/// - 清单 `eventsSha256` = `package:crypto` 的 SHA-256(事件正文)；
/// - 事件正文跨过 `openRead()` 的多个 64 KiB 块（链式状态被真正用到）；
/// - 现有读端 [SrsBackupStore.read] 照常通过完整校验。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('srs_backup_crc_test_');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('备份 zip 的 CRC / SHA-256 与 archive、crypto 对拍一致，读端完整校验通过', () async {
    int t = DateTime.utc(2026, 10, 18, 9).millisecondsSinceEpoch;
    final SrsStorage srsStorage = await openTestSrsStorage();
    final SrsDbStore store = await SrsDbStore.open(
      db: srsStorage.db,
      core: srsStorage.core,
      profileUid: kProfile,
      deviceId: 'a',
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        monotonicMs: () => t,
        bootId: 'boot-a',
      ),
    );
    final String expr = srsLapisFieldId(kProfile, 'Expression');
    final String sentence = srsLapisFieldId(kProfile, 'Sentence');
    for (int i = 0; i < 300; i++) {
      t += 1000;
      await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: <String, String>{
          expr: '単語$i',
          sentence: '単語$i を使った少し長めの例文です。' * 4,
        },
      );
    }

    final SrsBackupStore backups = SrsBackupStore(
      root: Directory(p.join(tmp.path, 'srs_backups')),
      profileUid: kProfile,
      mediaDir: Directory(p.join(tmp.path, 'srs_media')),
    );
    t += 60 * 1000;
    final SrsBackupInfo info = await backups.create(
      store,
      kind: SrsBackupKind.manual,
      profileName: '日语',
      nowMs: t,
    );

    final Archive verified = ZipDecoder().decodeBytes(
      info.file.readAsBytesSync(),
      verify: true,
    );
    final ArchiveFile events = verified.findFile('events.jsonl')!;
    final List<int> body = events.content as List<int>;
    expect(body.length, greaterThan(3 * 64 * 1024), reason: '要跨多个读块');
    expect(events.crc32, getCrc32(body));
    expect(info.manifest.eventsSha256, crypto.sha256.convert(body).toString());
    final ArchiveFile serverTimes = verified.findFile('server_times.json')!;
    expect(serverTimes.crc32, getCrc32(serverTimes.content as List<int>));

    final SrsBackupArchive read = await SrsBackupStore.read(info.file);
    read.close();
  });
}
