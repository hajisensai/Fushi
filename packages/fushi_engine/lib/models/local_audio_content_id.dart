/// 本地音频库的**内容身份**（拍板 pr3481）：跨设备同步 / 导入去重 / 删除墓碑认
/// 「库里装的是什么」，不再认用户可改、各版本默认值也不同的显示名。
///
/// 起因：本地音频跨设备同步原本只按 displayName 做 union。PR #3481 让新导入库的
/// 默认显示名从 `android.db` 改成按子来源起名、推荐包里的库也改叫 Japanese audio，
/// 新旧设备 / 新旧推荐包混用时，同一份 GB 级库会因为名字不同被两边各拉一次、在
/// 各端留两份。身份改成内容指纹后，名字怎么改都不影响去重。
///
/// **身份覆盖真实录音**（`la2`，HBK-AUDIT-001 / BUG 见 docs/BUGS.md）：第一版
/// （`la1`）只读 `entries` 元数据和 `android` 行数、不读音频 BLOB，两份录音不同但
/// 元数据与条数相同的库身份相同——启动整理会把其中一份当重复删掉，同步 / 导入会把
/// 另一份当「已有」跳过，删除墓碑也会删到另一份。身份是去重、清理、删除的唯一依据，
/// 只能对内容负责，所以 `la2` 把每一行的音频字节都算进去。代价是扫一遍整库（实测
/// 见 BUG 文件）；身份在导入 / 回填时算一次就存进登记，之后不再扫。
///
/// 规范化（与行序无关、与库文件字节无关）：
/// * `entries` 按 (expression, reading, source, file) 排序后逐行入哈希；
/// * `android` 先只把 (source, file, rowid) 三列小键排进 TEMP 表（不把 BLOB 拖进
///   排序器），再按它驱动一条 rowid 连接查询顺序取 (source, file, data) 入哈希——
///   取数在 SQLite 内部按主键查，不逐行回 Dart 发语句。完全同键的重复行按 rowid
///   定序——顺序不同只会算出两个身份（多留一份），不会把不同的库认成一份。
/// * 每个值带类型与长度前缀，字段边界与 NULL / 空串不会混淆。
/// 不按文件字节算：绑定时 `LocalAudioDb.ensureIndexes` 会往库文件里补索引，同一份
/// 库在两台设备上的字节本来就会不同。
///
/// 哈希是 native/fushi_compute 的流式 SHA-256（Rust 胖核心）：行数据攒进 1 MiB 原生
/// 缓冲区，满了才跨一次 FFI，不逐行跨边界。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart' show FfcSha256Hasher;
import 'package:fushi_engine/models/local_audio_db_entry.dart';
import 'package:sqlite3/sqlite3.dart';

/// 指纹格式前缀；算法变了就换前缀（旧前缀的身份与新前缀互不相等，退回按名匹配
/// 之前先各自重算）。`la1-`（不读音频 BLOB）已作废：不再被认作身份。
const String kLocalAudioContentIdPrefix = 'la2-';

/// [contentId] 是不是本版本认得的内容身份（防 wire 上来的任意串冒充）。
bool isLocalAudioContentId(String? contentId) =>
    contentId != null &&
    contentId.length == kLocalAudioContentIdPrefix.length + 32 &&
    contentId.startsWith(kLocalAudioContentIdPrefix) &&
    RegExp(
      r'^[0-9a-f]+$',
    ).hasMatch(contentId.substring(kLocalAudioContentIdPrefix.length));

/// 把 SQLite 值按「类型 + 长度 + 字节」写进原生哈希缓冲区，满了才 [FfcSha256Hasher.update]。
/// 字节一律走 `Uint8List` → `Uint8List` 的 `setRange`（memmove），不走泛型 List 拷贝。
final class _CanonicalHashSink {
  _CanonicalHashSink(this._hasher) : _buffer = _hasher.buffer;

  final FfcSha256Hasher _hasher;
  final Uint8List _buffer;
  int _fill = 0;
  final ByteData _scratch = ByteData(8);
  late final Uint8List _scratchBytes = _scratch.buffer.asUint8List(0, 8);

  void _flush() {
    if (_fill == 0) return;
    _hasher.update(_fill);
    _fill = 0;
  }

  void _bytes(Uint8List bytes) {
    final int len = bytes.length;
    int offset = 0;
    while (offset < len) {
      if (_fill == _buffer.length) _flush();
      final int room = _buffer.length - _fill;
      final int n = (len - offset) < room ? len - offset : room;
      _buffer.setRange(_fill, _fill + n, bytes, offset);
      _fill += n;
      offset += n;
    }
  }

  void _byte(int b) {
    if (_fill == _buffer.length) _flush();
    _buffer[_fill++] = b;
  }

  void _u64(int v) {
    _scratch.setUint64(0, v, Endian.little);
    _bytes(_scratchBytes);
  }

  /// 行标记（区分 entries / android 两段）。
  void tag(int t) => _byte(t);

  void value(Object? v) {
    switch (v) {
      case null:
        _byte(0);
      case int():
        _byte(1);
        _u64(v);
      case double():
        _byte(2);
        _scratch.setFloat64(0, v, Endian.little);
        _bytes(_scratchBytes);
      case String():
        final Uint8List b = utf8.encode(v);
        _byte(3);
        _u64(b.length);
        _bytes(b);
      case Uint8List():
        _byte(4);
        _u64(v.length);
        _bytes(v);
      default:
        final Uint8List b = utf8.encode(v.toString());
        _byte(5);
        _u64(b.length);
        _bytes(b);
    }
  }

  String finishHex() {
    _flush();
    return _hasher.finishHex();
  }
}

/// 同步计算 [dbPath] 的内容身份；文件不存在 / 不是本地音频库 / 读失败返回 null。
/// 只读打开，不改动库文件（排序键落在连接私有的 TEMP 库）。要扫整库（含音频
/// BLOB），调用方放后台 isolate（见 [computeLocalAudioContentIdInBackground]）。
/// native/fushi_compute 缺失抛 `FushiComputeUnavailableError`（原生库是硬依赖，
/// 不静默退回）。
String? computeLocalAudioContentId(String dbPath) {
  if (dbPath.isEmpty || !File(dbPath).existsSync()) return null;
  Database? db;
  FfcSha256Hasher? hasher;
  final List<PreparedStatement> statements = <PreparedStatement>[];
  try {
    db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    // 绑定期 app 会在库上后台补索引（持写锁）；读连接等它而不是直接 SQLITE_BUSY
    // ——忙着时返回 null 会让这份库被当成「没有身份」退回按名匹配。
    db.execute('PRAGMA busy_timeout = 60000');
    // 排序键只含小列：不把音频 BLOB 拖进排序器。
    db.execute(
      'CREATE TEMP TABLE fushi_la_order AS SELECT rowid AS r FROM main.android '
      'ORDER BY source, file, rowid',
    );
    final PreparedStatement entriesStmt = db.prepare(
      'SELECT expression, reading, source, file FROM main.entries '
      'ORDER BY expression, reading, source, file',
    );
    statements.add(entriesStmt);
    // CROSS JOIN 固定 TEMP 表为外层（按其 rowid = 插入顺序扫描），内层按主键查。
    final PreparedStatement androidStmt = db.prepare(
      'SELECT a.source, a.file, a.data FROM temp.fushi_la_order AS k '
      'CROSS JOIN main.android AS a ON a.rowid = k.r ORDER BY k.rowid',
    );
    statements.add(androidStmt);
    hasher = FfcSha256Hasher.create();
    final _CanonicalHashSink sink = _CanonicalHashSink(hasher)
      ..value('fushi-local-audio-v2');
    int entries = 0;
    final IteratingCursor entryCursor = entriesStmt.selectCursor();
    while (entryCursor.moveNext()) {
      final Row row = entryCursor.current;
      sink.tag(0x45); // 'E'
      for (int c = 0; c < 4; c++) {
        sink.value(row.columnAt(c));
      }
      entries++;
    }
    int androidRows = 0;
    final IteratingCursor audioCursor = androidStmt.selectCursor();
    while (audioCursor.moveNext()) {
      final Row row = audioCursor.current;
      sink
        ..tag(0x41) // 'A'
        ..value(row.columnAt(0))
        ..value(row.columnAt(1))
        ..value(row.columnAt(2));
      androidRows++;
    }
    if (entries == 0 && androidRows == 0) return null;
    sink
      ..tag(0x2e) // '.'
      ..value(entries)
      ..value(androidRows);
    final String digest = sink.finishHex();
    return '$kLocalAudioContentIdPrefix${digest.substring(0, 32)}';
  } on SqliteException {
    return null;
  } finally {
    for (final PreparedStatement s in statements) {
      s.close();
    }
    hasher?.close();
    db?.dispose();
  }
}

/// 进程内缓存：路径 → (文件长度, 修改时间, 身份)。长度 / mtime 变了就重算。
final Map<String, ({int length, int modifiedMs, String? id})> _cache =
    <String, ({int length, int modifiedMs, String? id})>{};

({int length, int modifiedMs})? _statOf(String path) {
  final FileStat st = FileStat.statSync(path);
  if (st.type == FileSystemEntityType.notFound) return null;
  return (length: st.size, modifiedMs: st.modified.millisecondsSinceEpoch);
}

/// 后台 isolate 里算 [dbPath] 的内容身份（带进程内缓存）。
Future<String?> computeLocalAudioContentIdInBackground(String dbPath) async {
  if (dbPath.isEmpty) return null;
  final ({int length, int modifiedMs})? st = _statOf(dbPath);
  if (st == null) return null;
  final ({int length, int modifiedMs, String? id})? hit = _cache[dbPath];
  if (hit != null &&
      hit.length == st.length &&
      hit.modifiedMs == st.modifiedMs) {
    return hit.id;
  }
  final String? id = await Isolate.run(
    () => computeLocalAudioContentId(dbPath),
  );
  // 读不出（不是音频库 / 一时打不开）不进缓存：下次再试，不把一次失败钉成
  // 「这份库没有身份」。
  if (id != null) {
    _cache[dbPath] = (length: st.length, modifiedMs: st.modifiedMs, id: id);
  }
  return id;
}

/// 只查进程内缓存、不扫库：[dbPath] 这一版文件（长度 + mtime 没变）算过身份就
/// 返回，否则 null。给同步路径上的登记写入顺手补身份用（不能在那里等扫库）。
String? cachedLocalAudioContentId(String dbPath) {
  final ({int length, int modifiedMs, String? id})? hit = _cache[dbPath];
  if (hit == null) return null;
  final ({int length, int modifiedMs})? st = _statOf(dbPath);
  if (st == null ||
      st.length != hit.length ||
      st.modifiedMs != hit.modifiedMs) {
    return null;
  }
  return hit.id;
}

/// 已登记条目的内容身份：登记里存了就用存的；没存（旧版本导入的库）且文件在
/// 本机就现算。文件不在本机、也没存身份时返回 null（调用方退回按名匹配）。
Future<String?> resolveLocalAudioContentId(LocalAudioDbEntry entry) async {
  final String? stored = entry.contentId;
  if (isLocalAudioContentId(stored)) return stored;
  return computeLocalAudioContentIdInBackground(entry.path);
}

/// 两条本地音频库记录是不是同一份库：两边都有内容身份就只比身份（名字不同也
/// 算同一份、名字相同但内容不同也算两份）；任一边没有身份（对端是旧版本、或
/// 引用的文件不在本机）才退回比显示名。
bool isSameLocalAudioLibrary({
  required String nameA,
  required String? contentIdA,
  required String nameB,
  required String? contentIdB,
}) {
  final bool hasA = isLocalAudioContentId(contentIdA);
  final bool hasB = isLocalAudioContentId(contentIdB);
  if (hasA && hasB) return contentIdA == contentIdB;
  return nameA == nameB;
}

/// 给一份要新登记的库挑一个不与 [taken] 撞名的显示名：[preferred] 没被占用就
/// 原样用，否则追加 ` (2)`、` (3)`……内容不同的两份库撞了名，必须让用户在列表里
/// 分得清，同步也不能再把它们当同一份。
String uniqueLocalAudioDisplayName(String preferred, Iterable<String> taken) {
  final Set<String> used = taken.toSet();
  if (!used.contains(preferred)) return preferred;
  for (int i = 2; ; i++) {
    final String candidate = '$preferred ($i)';
    if (!used.contains(candidate)) return candidate;
  }
}
