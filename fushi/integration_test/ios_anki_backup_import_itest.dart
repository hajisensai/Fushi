import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_backup_word_reader.dart';
import 'package:fushi/src/anki/ankimobile_mined_ledger.dart';
import 'package:fushi/src/anki/ankimobile_repository.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiDicts;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

/// iOS「导入 Anki 备份用于查重」真机链路：真 fushidicts 原生 zstd（Runner 静态链入、
/// `DynamicLibrary.process()` 解析）→ 后台 isolate 读 collection → 账本快照落应用
/// 支持目录 → `AnkiMobileRepository.isDuplicate` 转真。单测宿主上没有原生库，
/// 这几段只能在这里验。
///
/// 跑法：`.\tool\run_mac_itest.ps1 integration_test/ios_anki_backup_import_itest.dart -Ios`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    work = await (await getTemporaryDirectory()).createTemp(
      'anki_backup_itest_',
    );
  });
  tearDown(() async {
    if (work.existsSync()) await work.delete(recursive: true);
  });

  testWidgets('原生 zstd 解出 pzstd 真压缩样本（含 skippable 帧）', (
    WidgetTester tester,
  ) async {
    // Mac 上 `pzstd -19` 压的 "Fushi zstd probe: 見物 けんぶつ " ×40（1520 字节）。
    const String sample =
        'UCpNGAQAAAA8AAAAKLUv/QRofQEAZAJGdXNoaSB6c3RkIHByb2JlOiDopovniakg44GR44KT44G244Gk'
        'IAEAPi796gk1zHUj';
    final File input = File('${work.path}/in.zst')
      ..writeAsBytesSync(base64Decode(sample));
    final String outPath = '${work.path}/out.txt';
    FushiDicts.zstdDecompressFile(input.path, outPath);
    final String text = File(outPath).readAsStringSync();
    expect(utf8.encode(text).length, 1520);
    expect(text, 'Fushi zstd probe: 見物 けんぶつ ' * 40);
  });

  testWidgets('新版备份（anki21b + 占位 anki2）→ 账本快照 → isDuplicate 为真', (
    WidgetTester tester,
  ) async {
    // 造一个真 collection，按 zstd「raw block」帧封装成 anki21b（格式合法的 zstd
    // 帧，走的是同一个流式解码器），再配上 2.1.50+ 导出必带的占位 anki2。
    final Uint8List collection = _collection(<String>[
      '見物\u001fけんぶつ',
      '<b>勉強</b>\u001fべんきょう',
    ]);
    final Uint8List dummy = _collection(<String>[
      'Please update to the latest Anki version\u001f',
    ]);
    final Archive archive = Archive()
      ..addFile(ArchiveFile('collection.anki2', dummy.length, dummy))
      ..addFile(
        ArchiveFile(
          'collection.anki21b',
          _rawZstdFrame(collection).length,
          _rawZstdFrame(collection),
        ),
      );
    final String backup = '${work.path}/new.colpkg';
    File(backup).writeAsBytesSync(ZipEncoder().encode(archive)!);

    // 生产入口：后台 isolate + 原生 zstd。
    final Set<String> words =
        await tester.runAsync(
              () => readAnkiBackupFirstFields(
                backupPath: backup,
                workDir: '${work.path}/scratch',
              ),
            )
            as Set<String>;
    expect(words, <String>{'見物', '勉強'});

    final String snapshot = '${work.path}/snapshot.json';
    final AnkiMobileMinedLedger ledger = AnkiMobileMinedLedger(
      importedSnapshotPath: () async => snapshot,
    );
    final int count =
        await tester.runAsync(() => ledger.replaceImported(words)) as int;
    expect(count, 2);
    expect(File(snapshot).existsSync(), isTrue);

    final AnkiMobileRepository repo = AnkiMobileRepository(
      minedLedger: ledger,
      openUrl: (Uri _) async => true,
    );
    expect(await tester.runAsync(() => repo.isDuplicate('見物', '')), isTrue);
    expect(await tester.runAsync(() => repo.isDuplicate('勉強', '')), isTrue);
    expect(await tester.runAsync(() => repo.isDuplicate('猫', '')), isFalse);
  });

  testWidgets('生产默认快照路径在 iOS 应用支持目录可写', (WidgetTester tester) async {
    final AnkiMobileMinedLedger ledger = AnkiMobileMinedLedger();
    await tester.runAsync(() => ledger.replaceImported(<String>['見物']));
    final Directory support = await getApplicationSupportDirectory();
    final File file = File(
      '${support.path}/${AnkiMobileMinedLedger.importedSnapshotFileName}',
    );
    expect(file.existsSync(), isTrue);
    expect(
      await tester.runAsync(() => AnkiMobileMinedLedger().contains('見物')),
      isTrue,
    );
    await file.delete();
  });
}

Uint8List _collection(List<String> flds) {
  final Database db = sqlite3.openInMemory();
  db.execute('CREATE TABLE notes (id INTEGER PRIMARY KEY, flds TEXT NOT NULL)');
  final PreparedStatement insert = db.prepare(
    'INSERT INTO notes (flds) VALUES (?)',
  );
  for (final String f in flds) {
    insert.execute(<Object>[f]);
  }
  insert.dispose();
  final String path =
      '${Directory.systemTemp.path}/c_${DateTime.now().microsecondsSinceEpoch}.db';
  db.execute("VACUUM INTO '$path'");
  db.dispose();
  final Uint8List bytes = File(path).readAsBytesSync();
  File(path).deleteSync();
  return bytes;
}

/// 用 Raw_Block 拼一个合法的 zstd 帧（RFC 8878 §3.1.1）：不压缩，但走的是真解码器。
/// Window_Descriptor 取 0x38（exponent 7 → 窗口 128 KiB），块长上限 128 KiB。
Uint8List _rawZstdFrame(Uint8List data) {
  const int maxBlock = 128 * 1024;
  final BytesBuilder out = BytesBuilder()
    ..add(<int>[0x28, 0xB5, 0x2F, 0xFD]) // magic
    ..addByte(0x00) // FHD：无 FCS、非 single-segment、无校验、无字典
    ..addByte(0x38); // Window_Descriptor
  int offset = 0;
  do {
    final int size = (data.length - offset).clamp(0, maxBlock);
    final bool last = offset + size >= data.length;
    final int header = (last ? 1 : 0) | (0 << 1) | (size << 3);
    out.add(<int>[header & 0xFF, (header >> 8) & 0xFF, (header >> 16) & 0xFF]);
    out.add(data.sublist(offset, offset + size));
    offset += size;
  } while (offset < data.length);
  return out.toBytes();
}
