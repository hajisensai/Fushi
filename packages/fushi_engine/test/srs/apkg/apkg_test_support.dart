// Anki 包导入 / 导出测试的公共夹具：假引擎、内存同步目录、旧 / 新 schema 集合构造、protobuf 写入器。
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fushi_engine/srs/apkg/anki_collection_db.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:sqlite3/sqlite3.dart';
import '../support/srs_test_storage.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

/// 协议测试用的确定性假引擎（与 test/srs/srs_db_store_test.dart 同一份行为）。
class FakeFsrsEngine implements FsrsEngine {
  const FakeFsrsEngine();

  @override
  String get fsrsRev => 'fake';
  @override
  List<double> defaultParams(SrsAlgorithm a) =>
      List<double>.filled(a.paramCount, 1);
  @override
  String? validateParams(SrsAlgorithm a, List<double> p) => null;
  SrsMemory _step(SrsMemory? m, int r) => SrsMemory(
    stability: switch (r) {
      1 => 0.3,
      2 => 1.5 + (m?.stability ?? 0),
      3 => 3 + (m?.stability ?? 0) * 2,
      _ => 6 + (m?.stability ?? 0) * 3,
    },
    difficulty: 5,
  );
  @override
  SrsNextStates nextStates({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double desiredRetention,
    required SrsMemory? memory,
    required double elapsedDays,
  }) {
    SrsItemState st(int r) {
      final SrsMemory m = _step(memory, r);
      return SrsItemState(memory: m, interval: m.stability);
    }

    return SrsNextStates(again: st(1), hard: st(2), good: st(3), easy: st(4));
  }

  @override
  SrsMemory? memoryState({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required List<SrsFsrsReview> reviews,
    SrsMemory? starting,
  }) {
    SrsMemory? m = starting;
    for (final SrsFsrsReview r in reviews) {
      m = _step(m, r.rating);
    }
    return m;
  }

  @override
  SrsMemory memoryStateFromSm2({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double easeFactor,
    required double intervalDays,
    required double sm2Retention,
  }) => SrsMemory(stability: intervalDays, difficulty: 5);
  @override
  double retrievability({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsMemory memory,
    required double elapsedDays,
  }) => 0.9;
  @override
  List<double> computeParameters({
    required SrsAlgorithm algorithm,
    required SrsFsrsTrainingSet items,
    SrsOptimizerControl? control,
  }) => defaultParams(algorithm);
  @override
  SrsEvaluation evaluateTimeSeries({
    required SrsAlgorithm algorithm,
    required SrsFsrsTrainingSet items,
  }) => const SrsEvaluation(logLoss: 0.3, rmseBins: 0.1);
  @override
  SrsEvaluation evaluate({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsFsrsTrainingSet items,
  }) => const SrsEvaluation(logLoss: 0.3, rmseBins: 0.1);
}

/// 打开一个内存数据库上的 SrsDbStore。
Future<SrsDbStore> openTestStore({
  required String profileUid,
  required String deviceId,
  required int Function() now,
}) async {
  final SrsStorage srsStorage = await openTestSrsStorage();
  return SrsDbStore.open(
    db: srsStorage.db,
    core: srsStorage.core,
    profileUid: profileUid,
    deviceId: deviceId,
    engine: const FakeFsrsEngine(),
    trustedClock: SrsTrustedClock(
      wallClockMs: () => now(),
      bootId: 'boot-$deviceId',
    ),
    fallbackRolloverHour: () => 4,
  );
}

const String legacySchema = '''
CREATE TABLE col (id integer PRIMARY KEY, crt integer NOT NULL, mod integer NOT NULL,
  scm integer NOT NULL, ver integer NOT NULL, dty integer NOT NULL, usn integer NOT NULL,
  ls integer NOT NULL, conf text NOT NULL, models text NOT NULL, decks text NOT NULL,
  dconf text NOT NULL, tags text NOT NULL);
CREATE TABLE notes (id integer PRIMARY KEY, guid text NOT NULL, mid integer NOT NULL,
  mod integer NOT NULL, usn integer NOT NULL, tags text NOT NULL, flds text NOT NULL,
  sfld integer NOT NULL, csum integer NOT NULL, flags integer NOT NULL, data text NOT NULL);
CREATE TABLE cards (id integer PRIMARY KEY, nid integer NOT NULL, did integer NOT NULL,
  ord integer NOT NULL, mod integer NOT NULL, usn integer NOT NULL, type integer NOT NULL,
  queue integer NOT NULL, due integer NOT NULL, ivl integer NOT NULL, factor integer NOT NULL,
  reps integer NOT NULL, lapses integer NOT NULL, left integer NOT NULL, odue integer NOT NULL,
  odid integer NOT NULL, flags integer NOT NULL, data text NOT NULL);
CREATE TABLE revlog (id integer PRIMARY KEY, cid integer NOT NULL, usn integer NOT NULL,
  ease integer NOT NULL, ivl integer NOT NULL, lastIvl integer NOT NULL, factor integer NOT NULL,
  time integer NOT NULL, type integer NOT NULL);
''';

/// schema 18（新格式）多出来的配置表。DDL 照 Anki rslib
/// （`storage/upgrades/schema15_upgrade.sql` 起）：name 列与唯一索引都是
/// `COLLATE unicase`，fields / templates / config / tags 是 `WITHOUT ROWID`。
/// 建表与读表都要先注册 `unicase`（[buildSqlite] / [patchSqlite] 已代办，
/// 被测代码必须自己注册，见 BUG-3428）。
const String schema18Extra = '''
CREATE TABLE notetypes (id integer NOT NULL PRIMARY KEY, name text NOT NULL COLLATE unicase,
  mtime_secs integer NOT NULL, usn integer NOT NULL, config blob NOT NULL);
CREATE UNIQUE INDEX idx_notetypes_name ON notetypes (name);
CREATE INDEX idx_notetypes_usn ON notetypes (usn);
CREATE TABLE fields (ntid integer NOT NULL, ord integer NOT NULL,
  name text NOT NULL COLLATE unicase, config blob NOT NULL, PRIMARY KEY (ntid, ord))
  WITHOUT ROWID;
CREATE UNIQUE INDEX idx_fields_name_ntid ON fields (name, ntid);
CREATE TABLE templates (ntid integer NOT NULL, ord integer NOT NULL,
  name text NOT NULL COLLATE unicase, mtime_secs integer NOT NULL, usn integer NOT NULL,
  config blob NOT NULL, PRIMARY KEY (ntid, ord)) WITHOUT ROWID;
CREATE UNIQUE INDEX idx_templates_name_ntid ON templates (name, ntid);
CREATE INDEX idx_templates_usn ON templates (usn);
CREATE TABLE decks (id integer PRIMARY KEY NOT NULL, name text NOT NULL COLLATE unicase,
  mtime_secs integer NOT NULL, usn integer NOT NULL, common blob NOT NULL, kind blob NOT NULL);
CREATE UNIQUE INDEX idx_decks_name ON decks (name);
CREATE TABLE deck_config (id integer PRIMARY KEY NOT NULL, name text NOT NULL,
  mtime_secs integer NOT NULL, usn integer NOT NULL, config blob NOT NULL);
CREATE TABLE config (KEY text NOT NULL PRIMARY KEY, usn integer NOT NULL,
  mtime_secs integer NOT NULL, val blob NOT NULL) WITHOUT ROWID;
CREATE TABLE tags (tag text NOT NULL PRIMARY KEY COLLATE unicase, usn integer NOT NULL,
  collapsed boolean NOT NULL, config blob NULL) WITHOUT ROWID;
''';

/// 一张来源卡。
class FxCard {
  FxCard({
    required this.id,
    required this.ord,
    required this.did,
    this.type = 0,
    this.queue = 0,
    this.due = 0,
    this.ivl = 0,
    this.factor = 0,
    this.reps = 0,
    this.lapses = 0,
    this.data = '',
    this.revlog = const <FxRevlog>[],
  });

  final int id;
  final int ord;
  final int did;
  final int type;
  final int queue;
  final int due;
  final int ivl;
  final int factor;
  final int reps;
  final int lapses;
  final String data;
  final List<FxRevlog> revlog;
}

class FxRevlog {
  const FxRevlog(
    this.id, {
    required this.type,
    required this.ease,
    required this.ivl,
    this.factor = 2500,
    this.time = 5000,
  });

  final int id;
  final int type;
  final int ease;
  final int ivl;
  final int factor;
  final int time;
}

class FxNote {
  FxNote({
    required this.id,
    required this.guid,
    required this.mid,
    required this.fields,
    this.tags = const <String>[],
    required this.cards,
  });

  final int id;
  final String guid;
  final int mid;
  final List<String> fields;
  final List<String> tags;
  final List<FxCard> cards;
}

/// 写一个临时 SQLite，返回字节。
Uint8List buildSqlite(void Function(Database db) fill) {
  final Directory dir = Directory.systemTemp.createTempSync('fx_anki_');
  final String path = '${dir.path}${Platform.pathSeparator}c.db';
  final Database db = sqlite3.open(path);
  // Anki 自己写库时注册了 unicase；夹具同样注册才建得出 schema 18 的索引。
  registerAnkiCollations(db);
  try {
    fill(db);
  } finally {
    db.close();
  }
  final Uint8List bytes = File(path).readAsBytesSync();
  try {
    dir.deleteSync(recursive: true);
  } on FileSystemException {
    // 句柄晚释放。
  }
  return bytes;
}

/// 改一个现成的 SQLite（写临时文件、改、读回）。
Uint8List patchSqlite(Uint8List bytes, void Function(Database db) fn) {
  final Directory dir = Directory.systemTemp.createTempSync('fx_anki_');
  final String path = '${dir.path}${Platform.pathSeparator}c.db';
  File(path).writeAsBytesSync(bytes);
  final Database db = sqlite3.open(path);
  registerAnkiCollations(db);
  try {
    fn(db);
  } finally {
    db.close();
  }
  final Uint8List out = File(path).readAsBytesSync();
  try {
    dir.deleteSync(recursive: true);
  } on FileSystemException {
    // 句柄晚释放。
  }
  return out;
}

void insertNotes(Database db, List<FxNote> notes) {
  for (final FxNote n in notes) {
    db.execute('INSERT INTO notes VALUES (?,?,?,?,?,?,?,?,?,?,?)', <Object?>[
      n.id,
      n.guid,
      n.mid,
      0,
      0,
      n.tags.isEmpty ? '' : ' ${n.tags.join(' ')} ',
      n.fields.join('\x1f'),
      n.fields.first,
      0,
      0,
      '',
    ]);
    for (final FxCard c in n.cards) {
      db.execute(
        'INSERT INTO cards VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        <Object?>[
          c.id,
          n.id,
          c.did,
          c.ord,
          0,
          0,
          c.type,
          c.queue,
          c.due,
          c.ivl,
          c.factor,
          c.reps,
          c.lapses,
          0,
          0,
          0,
          0,
          c.data,
        ],
      );
      for (final FxRevlog r in c.revlog) {
        db.execute('INSERT INTO revlog VALUES (?,?,?,?,?,?,?,?,?)', <Object?>[
          r.id,
          c.id,
          0,
          r.ease,
          r.ivl,
          0,
          r.factor,
          r.time,
          r.type,
        ]);
      }
    }
  }
}

/// 旧格式集合（schema 11）。
Uint8List buildLegacyCollection({
  required int crtSecs,
  required Map<String, Object?> conf,
  required Map<String, Object?> models,
  required Map<String, Object?> decks,
  required Map<String, Object?> dconf,
  required List<FxNote> notes,
}) => buildSqlite((Database db) {
  db.execute(legacySchema);
  db.execute('INSERT INTO col VALUES (1,?,0,0,11,0,0,0,?,?,?,?,?)', <Object?>[
    crtSecs,
    jsonEncode(conf),
    jsonEncode(models),
    jsonEncode(decks),
    jsonEncode(dconf),
    '{}',
  ]);
  // 一个事务：大夹具（导入基准的上万条笔记）逐条自动提交要几分钟。
  db.execute('BEGIN');
  insertNotes(db, notes);
  db.execute('COMMIT');
});

/// 打 zip。
Uint8List zipOf(Map<String, List<int>> entries) {
  final Archive a = Archive();
  for (final MapEntry<String, List<int>> e in entries.entries) {
    a.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(a)!);
}

// ---------------------------------------------------------------------- protobuf 写入器

class PbWriter {
  final BytesBuilder _b = BytesBuilder();

  void _varint(int v) {
    int x = v;
    while (true) {
      final int low = x & 0x7f;
      x = x >>> 7;
      if (x == 0) {
        _b.addByte(low);
        return;
      }
      _b.addByte(low | 0x80);
    }
  }

  void _key(int field, int wire) => _varint((field << 3) | wire);

  void varint(int field, int v) {
    _key(field, 0);
    _varint(v);
  }

  void bytes(int field, List<int> v) {
    _key(field, 2);
    _varint(v.length);
    _b.add(v);
  }

  void string(int field, String v) => bytes(field, utf8.encode(v));

  void message(int field, PbWriter m) => bytes(field, m.toBytes());

  void float(int field, double v) {
    _key(field, 5);
    final ByteData d = ByteData(4)..setFloat32(0, v, Endian.little);
    _b.add(d.buffer.asUint8List());
  }

  void packedFloats(int field, List<double> v) {
    final ByteData d = ByteData(v.length * 4);
    for (int i = 0; i < v.length; i++) {
      d.setFloat32(i * 4, v[i], Endian.little);
    }
    bytes(field, d.buffer.asUint8List());
  }

  Uint8List toBytes() => _b.toBytes();
}

/// 只含 Raw 块的 zstd 帧（不压缩，但是合法的 zstd：解码路径与真压缩包相同）。
Uint8List zstdRawFrame(Uint8List data) {
  const int block = 128 * 1024;
  final BytesBuilder b = BytesBuilder(copy: false)
    // 魔数；帧头描述符 0（无内容大小、非单段、无校验）；窗口描述符：2^(10+7) = 128 KB。
    ..add(<int>[0x28, 0xB5, 0x2F, 0xFD, 0x00, 7 << 3]);
  int off = 0;
  do {
    final int n = min(block, data.length - off);
    final bool last = off + n >= data.length;
    final int header = (last ? 1 : 0) | (0 << 1) | (n << 3);
    b
      ..add(<int>[header & 0xff, (header >> 8) & 0xff, (header >> 16) & 0xff])
      ..add(Uint8List.sublistView(data, off, off + n));
    off += n;
  } while (off < data.length);
  return b.takeBytes();
}

/// 本机 python 的 zstandard 压缩（没有返回 null）。
Future<Uint8List?> pythonZstd(List<int> data) async {
  try {
    final Process p = await Process.start('python', <String>[
      '-I',
      '-c',
      'import sys,zstandard;'
          'sys.stdout.buffer.write(zstandard.ZstdCompressor(level=3)'
          '.compress(sys.stdin.buffer.read()))',
    ]);
    p.stdin.add(data);
    await p.stdin.close();
    final List<int> out = <int>[];
    await p.stdout.forEach(out.addAll);
    await p.stderr.drain<void>();
    if (await p.exitCode != 0 || out.isEmpty) return null;
    return Uint8List.fromList(out);
  } on Object {
    return null;
  }
}

/// 本仓 prebuilt 的 fushi_fsrs 原生库路径（相对 packages/fushi_engine）。
String fushiFsrsPrebuiltPath() {
  final String? env = Platform.environment[kFushiFsrsLibEnv];
  if (env != null && env.isNotEmpty) return env;
  final String sep = Platform.pathSeparator;
  final String root = '..$sep..${sep}native${sep}fushi_fsrs${sep}prebuilt';
  final String rel = Platform.isWindows
      ? '$root${sep}windows-x64${sep}fushi_fsrs.dll'
      : Platform.isMacOS
      ? '$root${sep}macos${sep}libfushi_fsrs.dylib'
      : '$root${sep}linux-x64${sep}libfushi_fsrs.so';
  return File(rel).absolute.path;
}
