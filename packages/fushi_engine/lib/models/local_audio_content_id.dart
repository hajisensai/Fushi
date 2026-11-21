/// 本地音频库的**内容身份**（拍板 pr3481）：跨设备同步 / 导入去重认「库里装的是
/// 什么」，不再认用户可改、各版本默认值也不同的显示名。
///
/// 起因：本地音频跨设备同步原本只按 displayName 做 union。PR #3481 让新导入库的
/// 默认显示名从 `android.db` 改成按子来源起名、推荐包里的库也改叫 Japanese audio，
/// 新旧设备 / 新旧推荐包混用时，同一份 GB 级库会因为名字不同被两边各拉一次、在
/// 各端留两份。身份改成内容指纹后，名字怎么改都不影响去重。
///
/// 指纹只读 `entries` 元数据表（每行 expression / reading / source / file）加
/// `android` 音频表的行数，**不读音频 BLOB**：GB 级库整读一遍太慢，而元数据表
/// 完全一致、音频条数也一致的两份库实际上就是同一份库。不按文件字节算：绑定时
/// `LocalAudioDb.ensureIndexes` 会往库文件里补索引，同一份库在两台设备上的字节
/// 本来就会不同。
///
/// 行哈希用与顺序无关的组合（求和 + 异或），不需要排序整张表，VACUUM / 重建
/// 索引改变扫描顺序也不影响结果。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' show sha256;
import 'package:fushi_engine/models/local_audio_db_entry.dart';
import 'package:sqlite3/sqlite3.dart';

/// 指纹格式前缀；算法变了就换前缀（旧前缀的身份与新前缀互不相等，退回按名匹配
/// 之前先各自重算）。
const String kLocalAudioContentIdPrefix = 'la1-';

/// [contentId] 是不是本版本认得的内容身份（防 wire 上来的任意串冒充）。
bool isLocalAudioContentId(String? contentId) =>
    contentId != null &&
    contentId.length == kLocalAudioContentIdPrefix.length + 32 &&
    contentId.startsWith(kLocalAudioContentIdPrefix) &&
    RegExp(
      r'^[0-9a-f]+$',
    ).hasMatch(contentId.substring(kLocalAudioContentIdPrefix.length));

const int _fnvOffset64 = 0xcbf29ce484222325;
const int _fnvPrime64 = 0x100000001b3;

int _fnv1a64(List<int> bytes) {
  int h = _fnvOffset64;
  for (final int b in bytes) {
    h ^= b;
    h *= _fnvPrime64; // Dart VM int 是 64 位补码，乘法按 2^64 回绕。
  }
  return h;
}

String _hex64(int v) => v.toUnsigned(64).toRadixString(16).padLeft(16, '0');

/// 同步计算 [dbPath] 的内容身份；文件不存在 / 不是本地音频库 / 读失败返回 null。
/// 只读打开，不改动库文件。GB 级库要扫一遍元数据表，调用方放后台 isolate
/// （见 [computeLocalAudioContentIdInBackground]）。
String? computeLocalAudioContentId(String dbPath) {
  if (dbPath.isEmpty || !File(dbPath).existsSync()) return null;
  Database? db;
  try {
    db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    // 绑定期 app 会在库上后台补索引（持写锁）；读连接等它而不是直接 SQLITE_BUSY
    // ——忙着时返回 null 会让这份库被当成「没有身份」退回按名匹配。
    db.execute('PRAGMA busy_timeout = 60000');
    int count = 0;
    int sum = 0;
    int xor = 0;
    final Map<String, int> perSource = <String, int>{};
    final PreparedStatement stmt = db.prepare(
      "SELECT COALESCE(CAST(expression AS TEXT), ''), "
      "COALESCE(CAST(reading AS TEXT), ''), "
      "COALESCE(CAST(source AS TEXT), ''), "
      "COALESCE(CAST(file AS TEXT), '') FROM entries",
    );
    try {
      final IteratingCursor cursor = stmt.selectCursor();
      while (cursor.moveNext()) {
        final Row row = cursor.current;
        final String source = row.columnAt(2) as String;
        final int h = _fnv1a64(
          utf8.encode(
            '${row.columnAt(0)}\u001f${row.columnAt(1)}\u001f'
            '$source\u001f${row.columnAt(3)}',
          ),
        );
        count++;
        sum += h;
        xor ^= h;
        perSource[source] = (perSource[source] ?? 0) + 1;
      }
    } finally {
      stmt.close();
    }
    final int androidRows =
        db.select('SELECT COUNT(*) AS n FROM android').first['n'] as int;
    if (count == 0 && androidRows == 0) return null;
    final List<String> sources = perSource.keys.toList()..sort();
    final StringBuffer summary = StringBuffer()
      ..writeln('fushi-local-audio-v1')
      ..writeln('entries=$count')
      ..writeln('sum=${_hex64(sum)}')
      ..writeln('xor=${_hex64(xor)}')
      ..writeln('android=$androidRows');
    for (final String s in sources) {
      summary.writeln('source=$s\t${perSource[s]}');
    }
    final String digest = sha256
        .convert(utf8.encode(summary.toString()))
        .toString();
    return '$kLocalAudioContentIdPrefix${digest.substring(0, 32)}';
  } on SqliteException {
    return null;
  } finally {
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
