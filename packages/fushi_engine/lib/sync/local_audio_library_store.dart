/// 本地音频库的**存储中转**登记表（BUG-2815）：无头服务端不做查词发音，只把
/// 客户端推来的本地音频库（SQLite DB + 子来源偏好 + enabled + displayName）落盘
/// 并登记，供其它客户端列出 / 拉取 / 删除——与服务端对词典包的做法同一形态。
///
/// 登记格式与 app `LocalAudioManager` 逐字节同形：偏好键 `local_audio_dbs`（JSON
/// 数组，元素是 [LocalAudioDbEntry.toJson]），库副本落在库目录下
/// `local_audio_<数字>.db`。同一份数据根被桌面 Fushi 打开时能直接认出这些库。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/models/local_audio_content_id.dart';
import 'package:fushi_engine/models/local_audio_db_entry.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

/// 推来的包里的 DB 不是 SQLite 文件（空文件 / zip / 截断）。服务端不装查词
/// 引擎，只做最便宜的头部校验，拒绝把明显无用的文件登记成音频库。
class InvalidLocalAudioPackageException implements Exception {
  const InvalidLocalAudioPackageException(this.displayName);

  final String displayName;

  @override
  String toString() =>
      'InvalidLocalAudioPackageException: package "$displayName" does not '
      'carry a SQLite database';
}

class LocalAudioLibraryStore {
  LocalAudioLibraryStore({
    required PrefStore prefs,
    required Directory databaseDirectory,
  }) : _prefs = prefs,
       _databaseDirectory = databaseDirectory;

  /// 与 app `LocalAudioManager` 共用的登记偏好键。
  static const String entriesPrefKey = 'local_audio_dbs';

  static final RegExp _internalCopyNamePattern = RegExp(
    r'^local_audio_\d+\.db$',
  );

  static const List<int> _sqliteMagic = <int>[
    0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, // "SQLite f"
    0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00, // "ormat 3\0"
  ];

  static int _lastStamp = 0;

  final PrefStore _prefs;
  final Directory _databaseDirectory;

  /// 当前登记的本地音频库（登记顺序 = 优先级序）。内部副本的 path 按文件名
  /// 重挂到本机库目录——数据根整体搬家后源绝对前缀失效，只有文件名可信。
  List<LocalAudioDbEntry> get entries => <LocalAudioDbEntry>[
    for (final LocalAudioDbEntry e in _readStored())
      e.copyWith(path: _resolve(e.path)),
  ];

  /// 登记一个已解包的本地音频包：把 DB 拷进库目录并追加登记。按**内容身份**
  /// 去重（拍板 pr3481，与 app `importSyncedLocalAudioDb` 同语义）：同一份库换了
  /// 名字也不再登记第二份；名字撞了但内容不同的库换个不撞的名字登记。只有一边
  /// 读不出身份（包里的 DB 损坏 / 已登记的库文件不在）时才退回按 displayName
  /// 认。返回是否真的新增了。
  Future<bool> importPackage(LocalAudioPackageContents contents) async {
    final List<LocalAudioDbEntry> stored = _readStored();
    if (!await _isSqliteFile(contents.dbFile)) {
      throw InvalidLocalAudioPackageException(contents.displayName);
    }
    final String? incomingId = isLocalAudioContentId(contents.contentId)
        ? contents.contentId
        : await computeLocalAudioContentIdInBackground(contents.dbFile.path);
    for (final LocalAudioDbEntry e in stored) {
      final String? have = await resolveLocalAudioContentId(
        e.copyWith(path: _resolve(e.path)),
      );
      if (isSameLocalAudioLibrary(
        nameA: e.displayName,
        contentIdA: have,
        nameB: contents.displayName,
        contentIdB: incomingId,
      )) {
        return false;
      }
    }
    final String displayName = uniqueLocalAudioDisplayName(
      contents.displayName,
      stored.map((LocalAudioDbEntry e) => e.displayName),
    );
    await _databaseDirectory.create(recursive: true);
    // 文件名只要唯一：毫秒相同强制 +1，撞上已有文件（上次进程留下）也跳过。
    int stamp = DateTime.now().millisecondsSinceEpoch;
    if (stamp <= _lastStamp) stamp = _lastStamp + 1;
    String internalPath = p.join(
      _databaseDirectory.path,
      'local_audio_$stamp.db',
    );
    while (await File(internalPath).exists()) {
      stamp++;
      internalPath = p.join(_databaseDirectory.path, 'local_audio_$stamp.db');
    }
    _lastStamp = stamp;
    await contents.dbFile.copy(internalPath);
    try {
      await _writeStored(<LocalAudioDbEntry>[
        ...stored,
        LocalAudioDbEntry(
          path: internalPath,
          displayName: displayName,
          enabled: contents.enabled,
          sources: contents.sources,
          contentId: incomingId,
        ),
      ]);
    } catch (_) {
      // 登记没落库：副本不留孤儿。
      await _deleteFiles(internalPath);
      rethrow;
    }
    return true;
  }

  /// 删除内容身份为 [contentId] 的所有登记，并删掉库目录里的内部副本（含 -wal /
  /// -shm）；库目录之外的路径（外部引用）只摘登记、不动文件。找不到 / [contentId]
  /// 不是合格身份时幂等返回。
  ///
  /// 只按内容身份删（HBK-AUDIT-022）：显示名在各端可以不同，同名的可能是另一份库。
  Future<void> remove(String contentId) async {
    if (!isLocalAudioContentId(contentId)) return;
    final List<LocalAudioDbEntry> stored = _readStored();
    final List<LocalAudioDbEntry> kept = <LocalAudioDbEntry>[];
    final List<LocalAudioDbEntry> removed = <LocalAudioDbEntry>[];
    for (final LocalAudioDbEntry e in stored) {
      final String? id = await resolveLocalAudioContentId(
        e.copyWith(path: _resolve(e.path)),
      );
      (id == contentId ? removed : kept).add(e);
    }
    if (removed.isEmpty) return;
    await _writeStored(kept);
    for (final LocalAudioDbEntry r in removed) {
      if (_isInternalCopyName(r.path)) await _deleteFiles(_resolve(r.path));
    }
  }

  /// 启动时跑一次：给旧版本登记、没存内容身份的库补写身份，并把内容相同的重复
  /// 登记收成一条（保留先登记的那条，删掉后来者的内部副本）。拍板 pr3481 之前
  /// 同步按显示名去重，新旧版本混用时同一份库会在这里登记两份、占两份磁盘。
  /// 返回删掉的重复条数。
  Future<int> normalizeContentIdentities() async {
    final List<LocalAudioDbEntry> stored = _readStored();
    final List<LocalAudioDbEntry> kept = <LocalAudioDbEntry>[];
    final List<LocalAudioDbEntry> duplicates = <LocalAudioDbEntry>[];
    final Set<String> seen = <String>{};
    bool changed = false;
    for (final LocalAudioDbEntry e in stored) {
      final String? id = await resolveLocalAudioContentId(
        e.copyWith(path: _resolve(e.path)),
      );
      if (id != null && !seen.add(id)) {
        duplicates.add(e);
        changed = true;
        continue;
      }
      if (id != null && e.contentId != id) {
        kept.add(e.copyWith(contentId: id));
        changed = true;
      } else {
        kept.add(e);
      }
    }
    if (!changed) return 0;
    await _writeStored(kept);
    for (final LocalAudioDbEntry d in duplicates) {
      if (_isInternalCopyName(d.path)) await _deleteFiles(_resolve(d.path));
    }
    return duplicates.length;
  }

  List<LocalAudioDbEntry> _readStored() {
    final Object? raw = _prefs.getPref(entriesPrefKey, defaultValue: '');
    if (raw is! String || raw.isEmpty) return <LocalAudioDbEntry>[];
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      return <LocalAudioDbEntry>[
        for (final dynamic e in list)
          LocalAudioDbEntry.fromJson(e as Map<String, dynamic>),
      ];
    } on FormatException {
      return <LocalAudioDbEntry>[];
    } on TypeError {
      return <LocalAudioDbEntry>[];
    }
  }

  Future<void> _writeStored(List<LocalAudioDbEntry> entries) => _prefs.setPref(
    entriesPrefKey,
    jsonEncode(<Map<String, dynamic>>[
      for (final LocalAudioDbEntry e in entries) e.toJson(),
    ]),
  );

  static String _basenameAnySep(String path) {
    final int cut = path.lastIndexOf('/') > path.lastIndexOf('\\')
        ? path.lastIndexOf('/')
        : path.lastIndexOf('\\');
    return cut < 0 ? path : path.substring(cut + 1);
  }

  static bool _isInternalCopyName(String path) =>
      path.isNotEmpty &&
      _internalCopyNamePattern.hasMatch(_basenameAnySep(path));

  String _resolve(String storedPath) => _isInternalCopyName(storedPath)
      ? p.join(_databaseDirectory.path, _basenameAnySep(storedPath))
      : storedPath;

  static Future<bool> _isSqliteFile(File file) async {
    if (!await file.exists()) return false;
    final RandomAccessFile handle = await file.open();
    try {
      final List<int> head = await handle.read(_sqliteMagic.length);
      if (head.length < _sqliteMagic.length) return false;
      for (int i = 0; i < _sqliteMagic.length; i++) {
        if (head[i] != _sqliteMagic[i]) return false;
      }
      return true;
    } finally {
      await handle.close();
    }
  }

  static Future<void> _deleteFiles(String dbPath) async {
    for (final String suffix in <String>['', '-wal', '-shm']) {
      final File f = File('$dbPath$suffix');
      if (await f.exists()) await f.delete();
    }
  }
}
