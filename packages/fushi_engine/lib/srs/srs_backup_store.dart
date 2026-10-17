/// 复习（Fushi SRS）自动全量备份：备份文件格式与本机备份库（docs/specs/2026-10-17-srs-auto-backup-restore.md）。
///
/// 对标 Anki / AnkiMobile 的「备份」：定期给复习数据存一份完整快照，可以按时间点恢复。与通用备份
/// （设置 › 同步与备份，整 app 打包、手动）分开：这里只有复习数据，设备本地，自动做、自动清理。
///
/// **文件格式**（zip，扩展名 `.fushisrs`，[kSrsBackupFormatVersion]）：
/// - `manifest.json`：魔数、格式版本、最低可读版本、创建时刻、种类、profile、计数、事件摘要、媒体清单。
///   读方只认识自己支持的版本：`minReaderVersion` 高于本机支持的版本 → 拒绝（「备份来自更新版本」）；
///   多出来的字段忽略（前向兼容）。
/// - `events.jsonl`：该 profile 的全部事件（身份记录 / 修改记录 / 复习日志 / 不认识的事件），每行一条规范 JSON，
///   与同步批次同一种编码（事件创建即不可变，备份也不改它们）。清单里有 SHA-256，对不上 = 损坏。
/// - `server_times.json`：已知的「事件 ID → 发布时服务器时间 S」（铁律 F，排序键要用）。
/// - `media/<sha256>`：媒体正文，只在**导出的自包含文件**里有。
///
/// **本机布局**（`<支持目录>/srs_backups/`，设备本地：不进同步，通用备份按类别显式收文件、不会收它）：
/// - `<profileUid>/<id>.fushisrs` + `<id>.json`（清单副本，列表时不用解压）；
/// - `media/<sha256>`：所有备份共享的媒体池，按内容哈希存，同一个文件只存一份；
///   清理旧备份后，没有任何清单引用的媒体随之删除。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/srs/srs_backup_retention.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_point_in_time_restore.dart';

const String kSrsBackupMagic = 'fushi-srs-backup';

/// 本版本写出的格式版本。
const int kSrsBackupFormatVersion = 1;

/// 本版本能读的最高格式版本（读方据清单的 minReaderVersion 判断）。
const int kSrsBackupReaderVersion = 1;

const String kSrsBackupExtension = 'fushisrs';
const String kSrsBackupsDirName = 'srs_backups';
const String _kMediaPool = 'media';
const String _kManifest = 'manifest.json';
const String _kEvents = 'events.jsonl';
const String _kServerTimes = 'server_times.json';
const String _kEmbeddedMediaPrefix = 'media/';

/// 备份的来由。持久化名冻结。
enum SrsBackupKind {
  /// 定时 / 离开复习页时自动做的。
  auto('auto'),

  /// 用户点「立即备份」。
  manual('manual'),

  /// 恢复前自动给当时的状态存的一份（可撤回恢复）。
  preRestore('preRestore');

  const SrsBackupKind(this.wire);

  final String wire;

  static SrsBackupKind parse(String? wire) {
    for (final SrsBackupKind k in values) {
      if (k.wire == wire) return k;
    }
    return SrsBackupKind.auto;
  }
}

/// 读备份文件失败的原因。
enum SrsBackupInvalidReason {
  /// 不是复习备份（解不开 zip、或没有本格式的清单）。
  notBackup,

  /// 是复习备份，但内容损坏（摘要对不上、事件解析失败）。
  corrupt,

  /// 来自更新版本、本机读不了。
  newerVersion,
}

class SrsBackupFormatException implements Exception {
  const SrsBackupFormatException(this.reason, [this.detail]);

  final SrsBackupInvalidReason reason;
  final String? detail;

  @override
  String toString() => 'SrsBackupFormatException(${reason.name}: $detail)';
}

/// 清单里的一个媒体文件。
class SrsBackupMediaEntry {
  const SrsBackupMediaEntry({
    required this.name,
    required this.sha256,
    required this.size,
  });

  /// 在 profile 媒体目录里的文件名。
  final String name;
  final String sha256;
  final int size;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'sha256': sha256,
    'size': size,
  };

  static SrsBackupMediaEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? name = json['name'];
    final Object? sha = json['sha256'];
    final Object? size = json['size'];
    if (name is! String || sha is! String || size is! int) return null;
    if (!_isBareName(name) || !_isSha256(sha)) return null;
    return SrsBackupMediaEntry(name: name, sha256: sha, size: size);
  }
}

bool _isBareName(String n) =>
    n.isNotEmpty &&
    !n.contains('/') &&
    !n.contains(r'\') &&
    n != '.' &&
    n != '..';

final RegExp _sha256Re = RegExp(r'^[0-9a-f]{64}$');
bool _isSha256(String s) => _sha256Re.hasMatch(s);

/// 备份清单。
class SrsBackupManifest {
  const SrsBackupManifest({
    required this.createdAt,
    required this.kind,
    required this.profileUid,
    required this.profileName,
    required this.noteCount,
    required this.cardCount,
    required this.reviewCount,
    required this.eventCount,
    required this.eventsSha256,
    required this.fingerprint,
    required this.media,
    this.formatVersion = kSrsBackupFormatVersion,
    this.minReaderVersion = kSrsBackupFormatVersion,
    this.mediaEmbedded = false,
  });

  final int formatVersion;
  final int minReaderVersion;
  final int createdAt;
  final SrsBackupKind kind;
  final String profileUid;
  final String profileName;
  final int noteCount;
  final int cardCount;
  final int reviewCount;
  final int eventCount;
  final String eventsSha256;

  /// 做备份时库的变化指纹（[SrsDbStore.changeFingerprint]），自动备份据此判断「有没有变动」。
  final String fingerprint;
  final List<SrsBackupMediaEntry> media;

  /// 媒体正文是否在文件里（导出的自包含文件）。
  final bool mediaEmbedded;

  int get mediaBytes =>
      media.fold<int>(0, (int s, SrsBackupMediaEntry m) => s + m.size);

  SrsBackupManifest copyWith({bool? mediaEmbedded}) => SrsBackupManifest(
    createdAt: createdAt,
    kind: kind,
    profileUid: profileUid,
    profileName: profileName,
    noteCount: noteCount,
    cardCount: cardCount,
    reviewCount: reviewCount,
    eventCount: eventCount,
    eventsSha256: eventsSha256,
    fingerprint: fingerprint,
    media: media,
    formatVersion: formatVersion,
    minReaderVersion: minReaderVersion,
    mediaEmbedded: mediaEmbedded ?? this.mediaEmbedded,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'magic': kSrsBackupMagic,
    'formatVersion': formatVersion,
    'minReaderVersion': minReaderVersion,
    'createdAt': createdAt,
    'kind': kind.wire,
    'profileUid': profileUid,
    'profileName': profileName,
    'counts': <String, Object?>{
      'notes': noteCount,
      'cards': cardCount,
      'reviews': reviewCount,
    },
    'events': <String, Object?>{'count': eventCount, 'sha256': eventsSha256},
    'fingerprint': fingerprint,
    'media': <Object?>[for (final SrsBackupMediaEntry m in media) m.toJson()],
    'mediaEmbedded': mediaEmbedded,
  };

  /// 解析清单；不是本格式抛 [SrsBackupInvalidReason.notBackup]，版本太新抛 [SrsBackupInvalidReason.newerVersion]。
  static SrsBackupManifest fromJson(Object? json) {
    if (json is! Map || json['magic'] != kSrsBackupMagic) {
      throw const SrsBackupFormatException(SrsBackupInvalidReason.notBackup);
    }
    final Object? minReader = json['minReaderVersion'];
    if (minReader is! int || minReader > kSrsBackupReaderVersion) {
      throw SrsBackupFormatException(
        SrsBackupInvalidReason.newerVersion,
        'minReaderVersion=$minReader',
      );
    }
    try {
      final Map<Object?, Object?> counts =
          (json['counts'] as Map?) ?? const <Object?, Object?>{};
      final Map<Object?, Object?> events = json['events']! as Map;
      return SrsBackupManifest(
        formatVersion: (json['formatVersion'] as int?) ?? minReader,
        minReaderVersion: minReader,
        createdAt: json['createdAt']! as int,
        kind: SrsBackupKind.parse(json['kind'] as String?),
        profileUid: json['profileUid']! as String,
        profileName: (json['profileName'] as String?) ?? '',
        noteCount: (counts['notes'] as int?) ?? 0,
        cardCount: (counts['cards'] as int?) ?? 0,
        reviewCount: (counts['reviews'] as int?) ?? 0,
        eventCount: events['count']! as int,
        eventsSha256: events['sha256']! as String,
        fingerprint: (json['fingerprint'] as String?) ?? '',
        media: <SrsBackupMediaEntry>[
          for (final Object? m in (json['media'] as List?) ?? const <Object?>[])
            ?SrsBackupMediaEntry.fromJson(m),
        ],
        mediaEmbedded: json['mediaEmbedded'] == true,
      );
    } on Object catch (e) {
      throw SrsBackupFormatException(SrsBackupInvalidReason.corrupt, '$e');
    }
  }
}

/// 本机备份库里的一份备份。
class SrsBackupInfo {
  const SrsBackupInfo({
    required this.file,
    required this.manifest,
    required this.fileBytes,
  });

  final File file;
  final SrsBackupManifest manifest;

  /// 备份文件本身的字节数（不含共享媒体池）。
  final int fileBytes;

  String get id => p.basenameWithoutExtension(file.path);

  /// 逻辑大小：事件文件 + 它引用的媒体（导出的自包含文件大致这么大）。
  int get totalBytes => fileBytes + manifest.mediaBytes;

  DateTime get createdAt =>
      DateTime.fromMillisecondsSinceEpoch(manifest.createdAt);
}

/// 一份读进内存、校验过的备份（恢复用）。
class SrsBackupArchive {
  SrsBackupArchive._({
    required this.manifest,
    required this.events,
    required this.serverTimes,
    required Map<String, ArchiveFile> embeddedMedia,
    required this.id,
    required InputFileStream input,
  }) : _embedded = embeddedMedia,
       _input = input;

  final SrsBackupManifest manifest;
  final List<SrsEvent> events;
  final Map<String, int> serverTimes;

  /// 来源文件名（不含扩展名），写进恢复日志作追溯。
  final String id;
  final Map<String, ArchiveFile> _embedded;
  final InputFileStream _input;
  bool _closed = false;

  /// 关掉备份文件的句柄（之后不能再读内嵌媒体）。
  void close() {
    if (_closed) return;
    _closed = true;
    _input.closeSync();
  }
}

/// 本机备份库（一个 profile）。见库注释。
class SrsBackupStore {
  SrsBackupStore({
    required this.root,
    required this.profileUid,
    required this.mediaDir,
  });

  /// `<支持目录>/srs_backups`。
  final Directory root;
  final String profileUid;

  /// 本 profile 的媒体目录（`<支持目录>/srs_media/<profileUid>`）。
  final Directory mediaDir;

  static Directory rootFor(Directory supportRoot) =>
      Directory(p.join(supportRoot.path, kSrsBackupsDirName));

  Directory get profileDir => Directory(p.join(root.path, profileUid));
  Directory get mediaPool => Directory(p.join(root.path, _kMediaPool));

  /// 本 profile 的备份，从新到旧。清单坏了的文件跳过（不在列表里出现，也不会被自动清理误删别的）。
  Future<List<SrsBackupInfo>> list() async {
    final Directory dir = profileDir;
    if (!await dir.exists()) return const <SrsBackupInfo>[];
    final List<SrsBackupInfo> out = <SrsBackupInfo>[];
    await for (final FileSystemEntity e in dir.list()) {
      if (e is! File || p.extension(e.path) != '.$kSrsBackupExtension') {
        continue;
      }
      final SrsBackupInfo? info = await _infoOf(e);
      if (info != null) out.add(info);
    }
    out.sort(
      (SrsBackupInfo a, SrsBackupInfo b) =>
          b.manifest.createdAt.compareTo(a.manifest.createdAt),
    );
    return out;
  }

  Future<SrsBackupInfo?> _infoOf(File f) async {
    SrsBackupManifest? m;
    final File side = File(p.setExtension(f.path, '.json'));
    try {
      if (await side.exists()) {
        m = SrsBackupManifest.fromJson(jsonDecode(await side.readAsString()));
      }
    } on Object {
      m = null;
    }
    if (m == null) {
      try {
        m = _readManifestOnly(f);
        await side.writeAsString(jsonEncode(m.toJson()), flush: true);
      } on Object {
        return null;
      }
    }
    return SrsBackupInfo(file: f, manifest: m, fileBytes: await f.length());
  }

  /// 本机所有备份占用的磁盘空间（全部 profile 的备份文件 + 共享媒体池）。
  Future<int> diskUsage() async {
    if (!await root.exists()) return 0;
    int total = 0;
    await for (final FileSystemEntity e in root.list(recursive: true)) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  /// 做一份备份。[profileName] 只用于显示。
  Future<SrsBackupInfo> create(
    SrsDbStore store, {
    required SrsBackupKind kind,
    required String profileName,
    int? nowMs,
  }) async {
    if (store.profileUid != profileUid) {
      throw ArgumentError('store belongs to ${store.profileUid}');
    }
    final int createdAt = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final String fingerprint = await store.changeFingerprint();
    final List<SrsEvent> events = await store.exportAll();
    final Map<String, int> serverTimes = await store.exportServerTimes();
    final ({int notes, int cards, int reviews}) counts = await store
        .backupCounts();
    final Uint8List eventsBody = _encodeEvents(events);
    final List<SrsBackupMediaEntry> media = await _captureMedia();
    final SrsBackupManifest manifest = SrsBackupManifest(
      createdAt: createdAt,
      kind: kind,
      profileUid: profileUid,
      profileName: profileName,
      noteCount: counts.notes,
      cardCount: counts.cards,
      reviewCount: counts.reviews,
      eventCount: events.length,
      eventsSha256: sha256.convert(eventsBody).toString(),
      fingerprint: fingerprint,
      media: media,
    );
    await profileDir.create(recursive: true);
    String id = '$createdAt-${kind.wire}';
    for (int i = 2; File(_pathOf(id)).existsSync(); i++) {
      id = '$createdAt-${kind.wire}-$i';
    }
    final File out = File(_pathOf(id));
    await _writeArchive(
      out: out,
      manifest: manifest,
      eventsBody: eventsBody,
      serverTimes: serverTimes,
    );
    await File(
      p.setExtension(out.path, '.json'),
    ).writeAsString(jsonEncode(manifest.toJson()), flush: true);
    return SrsBackupInfo(
      file: out,
      manifest: manifest,
      fileBytes: await out.length(),
    );
  }

  String _pathOf(String id) =>
      p.join(profileDir.path, '$id.$kSrsBackupExtension');

  /// 按保留策略删掉旧备份，再回收没人引用的媒体。返回删掉的备份数。
  Future<int> thin({required SrsBackupLimits limits, DateTime? now}) async {
    final List<SrsBackupInfo> all = await list();
    final List<SrsBackupInfo> obsolete = srsObsoleteBackups<SrsBackupInfo>(
      all,
      localTimeOf: (SrsBackupInfo b) => b.createdAt,
      now: now ?? DateTime.now(),
      limits: limits,
    );
    for (final SrsBackupInfo b in obsolete) {
      await _deleteFiles(b);
    }
    await collectMediaGarbage();
    return obsolete.length;
  }

  /// 删一份备份（并回收媒体）。
  Future<void> delete(SrsBackupInfo info) async {
    await _deleteFiles(info);
    await collectMediaGarbage();
  }

  Future<void> _deleteFiles(SrsBackupInfo b) async {
    for (final File f in <File>[
      b.file,
      File(p.setExtension(b.file.path, '.json')),
    ]) {
      try {
        if (await f.exists()) await f.delete();
      } on FileSystemException {
        // 删不掉（被占用）下次清理再试；不影响别的备份。
      }
    }
  }

  /// 删掉共享媒体池里没有任何备份清单（全部 profile）引用的文件。
  Future<void> collectMediaGarbage() async {
    final Directory pool = mediaPool;
    if (!await pool.exists()) return;
    final Set<String> referenced = <String>{};
    await for (final FileSystemEntity d in root.list()) {
      if (d is! Directory || p.basename(d.path) == _kMediaPool) continue;
      final SrsBackupStore other = SrsBackupStore(
        root: root,
        profileUid: p.basename(d.path),
        mediaDir: mediaDir,
      );
      for (final SrsBackupInfo b in await other.list()) {
        for (final SrsBackupMediaEntry m in b.manifest.media) {
          referenced.add(m.sha256);
        }
      }
    }
    await for (final FileSystemEntity f in pool.list()) {
      if (f is! File) continue;
      final String name = p.basename(f.path);
      if (name == _kMediaIndex) continue;
      if (!referenced.contains(name)) {
        try {
          await f.delete();
        } on FileSystemException {
          // 下次再收。
        }
      }
    }
    final Map<String, Object?> index = await _readMediaIndex();
    index.removeWhere(
      (String _, Object? v) => v is! Map || !referenced.contains(v['sha256']),
    );
    await _writeMediaIndex(index);
  }

  // ---------------------------------------------------------------- 媒体

  static const String _kMediaIndex = 'index.json';

  Future<Map<String, Object?>> _readMediaIndex() async {
    final File f = File(p.join(mediaPool.path, _kMediaIndex));
    try {
      if (await f.exists()) {
        final Object? j = jsonDecode(await f.readAsString());
        if (j is Map) return j.cast<String, Object?>();
      }
    } on Object {
      // 索引只是哈希缓存，坏了就重算。
    }
    return <String, Object?>{};
  }

  Future<void> _writeMediaIndex(Map<String, Object?> index) async {
    await mediaPool.create(recursive: true);
    final File f = File(p.join(mediaPool.path, _kMediaIndex));
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(index), flush: true);
    await tmp.rename(f.path);
  }

  /// 把本 profile 媒体目录里的文件按内容哈希放进共享池（已有的不重复复制），返回清单。
  /// 哈希按 (文件名, 大小, 修改时间) 缓存，没变的文件不重读。
  Future<List<SrsBackupMediaEntry>> _captureMedia() async {
    if (!await mediaDir.exists()) return const <SrsBackupMediaEntry>[];
    final Map<String, Object?> index = await _readMediaIndex();
    bool dirty = false;
    final List<SrsBackupMediaEntry> out = <SrsBackupMediaEntry>[];
    await mediaPool.create(recursive: true);
    final List<File> files = <File>[
      await for (final FileSystemEntity e in mediaDir.list())
        if (e is File) e,
    ]..sort((File a, File b) => a.path.compareTo(b.path));
    for (final File f in files) {
      final String name = p.basename(f.path);
      if (!_isBareName(name) ||
          name.endsWith('.tmp') ||
          name.endsWith('.download')) {
        continue;
      }
      final FileStat st = await f.stat();
      final String key = '$profileUid/$name';
      final Object? cached = index[key];
      String? sha;
      if (cached is Map &&
          cached['size'] == st.size &&
          cached['mtime'] == st.modified.millisecondsSinceEpoch &&
          cached['sha256'] is String) {
        sha = cached['sha256']! as String;
      }
      sha ??= (await sha256.bind(f.openRead()).first).toString();
      if (cached is! Map || cached['sha256'] != sha) {
        index[key] = <String, Object?>{
          'size': st.size,
          'mtime': st.modified.millisecondsSinceEpoch,
          'sha256': sha,
        };
        dirty = true;
      }
      final File pooled = File(p.join(mediaPool.path, sha));
      if (!await pooled.exists() || await pooled.length() != st.size) {
        final File tmp = File('${pooled.path}.tmp');
        await f.copy(tmp.path);
        await tmp.rename(pooled.path);
      }
      out.add(SrsBackupMediaEntry(name: name, sha256: sha, size: st.size));
    }
    if (dirty) await _writeMediaIndex(index);
    return out;
  }

  // ---------------------------------------------------------------- 文件读写

  static Uint8List _encodeEvents(List<SrsEvent> events) {
    final StringBuffer sb = StringBuffer();
    for (final SrsEvent e in events) {
      sb
        ..write(e.canonical())
        ..write('\n');
    }
    return Uint8List.fromList(utf8.encode(sb.toString()));
  }

  Future<void> _writeArchive({
    required File out,
    required SrsBackupManifest manifest,
    required Uint8List eventsBody,
    required Map<String, int> serverTimes,
    List<(String, File)> media = const <(String, File)>[],
  }) async {
    final File tmp = File('${out.path}.tmp');
    final ZipFileEncoder enc = ZipFileEncoder()..create(tmp.path);
    try {
      final List<int> m = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
      );
      enc.addArchiveFile(ArchiveFile(_kManifest, m.length, m));
      enc.addArchiveFile(ArchiveFile(_kEvents, eventsBody.length, eventsBody));
      final List<int> st = utf8.encode(jsonEncode(serverTimes));
      enc.addArchiveFile(ArchiveFile(_kServerTimes, st.length, st));
      for (final (String name, File f) in media) {
        await enc.addFile(f, name, ZipFileEncoder.STORE);
      }
      await enc.close();
    } on Object {
      try {
        await enc.close();
      } on Object {
        // 已关闭。
      }
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
    if (await out.exists()) await out.delete();
    await tmp.rename(out.path);
  }

  static (Archive, InputFileStream) _openZip(File f) {
    InputFileStream? input;
    try {
      input = InputFileStream(f.path);
      return (ZipDecoder().decodeBuffer(input), input);
    } on Object catch (e) {
      // 打开失败时流可能已建好：关掉，否则 Windows 上这个文件删不掉。
      input?.closeSync();
      throw SrsBackupFormatException(SrsBackupInvalidReason.notBackup, '$e');
    }
  }

  static List<int> _content(ArchiveFile f) {
    final Object? c = f.content;
    if (c is List<int>) return c;
    throw const SrsBackupFormatException(SrsBackupInvalidReason.corrupt);
  }

  static ArchiveFile? _find(Archive a, String name) {
    for (final ArchiveFile f in a.files) {
      if (f.isFile && f.name == name) return f;
    }
    return null;
  }

  static SrsBackupManifest _readManifestOnly(File f) {
    final (Archive a, InputFileStream input) = _openZip(f);
    try {
      return _manifestOf(a);
    } finally {
      input.closeSync();
    }
  }

  static SrsBackupManifest _manifestOf(Archive a) {
    final ArchiveFile? m = _find(a, _kManifest);
    if (m == null) {
      throw const SrsBackupFormatException(SrsBackupInvalidReason.notBackup);
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(_content(m)));
    } on FormatException {
      throw const SrsBackupFormatException(SrsBackupInvalidReason.notBackup);
    }
    return SrsBackupManifest.fromJson(json);
  }

  /// 读一份备份文件（本机的或外部选来的），完整校验。失败抛 [SrsBackupFormatException]。
  ///
  /// 返回的对象持有文件句柄（内嵌媒体按需读），用完调 [SrsBackupArchive.close]。
  static Future<SrsBackupArchive> read(File f) async {
    final (Archive a, InputFileStream input) = _openZip(f);
    try {
      return _readOpened(a, input, f);
    } on Object {
      input.closeSync();
      rethrow;
    }
  }

  static SrsBackupArchive _readOpened(
    Archive a,
    InputFileStream input,
    File f,
  ) {
    final SrsBackupManifest manifest = _manifestOf(a);
    final ArchiveFile? ev = _find(a, _kEvents);
    if (ev == null) {
      throw const SrsBackupFormatException(
        SrsBackupInvalidReason.corrupt,
        'events missing',
      );
    }
    final List<int> body = _content(ev);
    if (sha256.convert(body).toString() != manifest.eventsSha256) {
      throw const SrsBackupFormatException(
        SrsBackupInvalidReason.corrupt,
        'events sha256 mismatch',
      );
    }
    final List<SrsEvent> events = <SrsEvent>[];
    try {
      for (final String line in const LineSplitter().convert(
        utf8.decode(body),
      )) {
        if (line.isEmpty) continue;
        events.add(
          SrsEvent.fromJson((jsonDecode(line) as Map).cast<String, Object?>()),
        );
      }
    } on Object catch (e) {
      throw SrsBackupFormatException(SrsBackupInvalidReason.corrupt, '$e');
    }
    if (events.length != manifest.eventCount) {
      throw const SrsBackupFormatException(
        SrsBackupInvalidReason.corrupt,
        'event count mismatch',
      );
    }
    final Map<String, int> serverTimes = <String, int>{};
    final ArchiveFile? st = _find(a, _kServerTimes);
    if (st != null) {
      try {
        final Object? j = jsonDecode(utf8.decode(_content(st)));
        if (j is Map) {
          for (final MapEntry<Object?, Object?> e in j.entries) {
            if (e.key is String && e.value is int) {
              serverTimes[e.key! as String] = e.value! as int;
            }
          }
        }
      } on FormatException {
        throw const SrsBackupFormatException(
          SrsBackupInvalidReason.corrupt,
          'server times',
        );
      }
    }
    final Map<String, ArchiveFile> embedded = <String, ArchiveFile>{
      for (final ArchiveFile x in a.files)
        if (x.isFile && x.name.startsWith(_kEmbeddedMediaPrefix))
          x.name.substring(_kEmbeddedMediaPrefix.length): x,
    };
    return SrsBackupArchive._(
      manifest: manifest,
      events: events,
      serverTimes: serverTimes,
      embeddedMedia: embedded,
      id: p.basenameWithoutExtension(f.path),
      input: input,
    );
  }

  /// 导出一份自包含的备份文件（带媒体正文），供另存 / 分享。
  Future<File> exportSelfContained(SrsBackupInfo info, File out) async {
    final SrsBackupArchive a = await read(info.file);
    try {
      return await _export(a, out);
    } finally {
      a.close();
    }
  }

  Future<File> _export(SrsBackupArchive a, File out) async {
    final List<(String, File)> media = <(String, File)>[];
    final List<SrsBackupMediaEntry> present = <SrsBackupMediaEntry>[];
    final Set<String> added = <String>{};
    for (final SrsBackupMediaEntry m in a.manifest.media) {
      final File pooled = File(p.join(mediaPool.path, m.sha256));
      if (!await pooled.exists()) continue;
      present.add(m);
      if (added.add(m.sha256)) {
        media.add(('$_kEmbeddedMediaPrefix${m.sha256}', pooled));
      }
    }
    final SrsBackupManifest manifest = SrsBackupManifest(
      createdAt: a.manifest.createdAt,
      kind: a.manifest.kind,
      profileUid: a.manifest.profileUid,
      profileName: a.manifest.profileName,
      noteCount: a.manifest.noteCount,
      cardCount: a.manifest.cardCount,
      reviewCount: a.manifest.reviewCount,
      eventCount: a.manifest.eventCount,
      eventsSha256: a.manifest.eventsSha256,
      fingerprint: a.manifest.fingerprint,
      media: present,
      formatVersion: a.manifest.formatVersion,
      minReaderVersion: a.manifest.minReaderVersion,
      mediaEmbedded: true,
    );
    await _writeArchive(
      out: out,
      manifest: manifest,
      eventsBody: _encodeEvents(a.events),
      serverTimes: a.serverTimes,
      media: media,
    );
    return out;
  }

  /// 恢复前先把备份引用的媒体放回本 profile 的媒体目录：本机已有同名同大小的不动，缺的从共享池或
  /// 文件内嵌的正文取（校验哈希）。本机多出来的文件不删（媒体删除不跨设备传播，也不在恢复里删）。
  /// 返回取不到的文件数。
  Future<int> restoreMedia(SrsBackupArchive a) async {
    int missing = 0;
    for (final SrsBackupMediaEntry m in a.manifest.media) {
      final File target = File(p.join(mediaDir.path, m.name));
      if (await target.exists() && await target.length() == m.size) continue;
      await mediaDir.create(recursive: true);
      final File tmp = File('${target.path}.tmp');
      final File pooled = File(p.join(mediaPool.path, m.sha256));
      final ArchiveFile? embedded = a._embedded[m.sha256];
      bool ok = false;
      if (await pooled.exists()) {
        await pooled.copy(tmp.path);
        ok = true;
      } else if (embedded != null) {
        final OutputFileStream os = OutputFileStream(tmp.path);
        try {
          embedded.writeContent(os);
        } finally {
          await os.close();
        }
        ok = true;
      }
      if (ok) {
        final String sha = (await sha256.bind(tmp.openRead()).first).toString();
        if (sha == m.sha256) {
          await tmp.rename(target.path);
          continue;
        }
        await tmp.delete();
      }
      missing++;
    }
    return missing;
  }

  /// 恢复到备份 [a] 的时间点（见 srs_point_in_time_restore.dart）：先放回媒体，再写恢复事件。
  /// 调用方负责在此之前做一份 [SrsBackupKind.preRestore] 备份。
  Future<SrsRestoreReport> restore(SrsDbStore store, SrsBackupArchive a) async {
    if (a.manifest.profileUid != store.profileUid) {
      throw SrsRestoreProfileMismatch(a.manifest.profileUid, store.profileUid);
    }
    await restoreMedia(a);
    return srsRestoreToBackup(
      store: store,
      backupEvents: a.events,
      backupServerTimes: a.serverTimes,
      backupId: a.id,
    );
  }
}
