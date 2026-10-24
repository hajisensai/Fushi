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
/// **本机布局**（`<备份根>/`，app 里是数据根的 documents 根下 `srs_backups/`——与 Anki 一样放在用户看得到、
/// 卸载 / 换设备时能带走的位置；不进同步，通用备份按类别显式收文件、不会收它）：
/// - `<profileUid>/fushi-review-<日期_时刻>-<种类>.fushisrs` + 隐藏的 `.<同名>.json`（清单副本，列表时不用解压）；
/// - `media/<sha256>`：所有备份共享的媒体池，按内容哈希存，同一个文件只存一份；与媒体目录同卷时是
///   媒体文件的硬链接（不占第二份空间；跨卷 / 文件系统不支持时退回复制）。媒体文件一律「先写临时文件
///   再改名」，换的是新文件，不会经链接改到池里那份。清理旧备份后，没有任何清单引用的媒体随之删除。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' hide ZLibEncoder;
import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'package:fushi_engine/platform/file_hard_link.dart';
import 'package:fushi_engine/srs/srs_backup_retention.dart';
import 'package:fushi_engine/srs/srs_backup_snapshot.dart';
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

/// 解压上限（外部文件不可信，防解压炸弹）：清单、服务器时间表、事件正文、单个内嵌媒体。
const int _kMaxManifestBytes = 64 << 20;
const int _kMaxServerTimesBytes = 512 << 20;
const int _kMaxEventsBytes = 1024 << 20;
const int _kMaxMediaBytes = 2047 << 20;

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

/// [SrsBackupStore.create] 被 `shouldStop` 叫停（没有产出备份，暂存文件已删）。
class SrsBackupCancelled implements Exception {
  const SrsBackupCancelled();

  @override
  String toString() => 'SrsBackupCancelled';
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

bool _isBareName(String n) {
  if (n.isEmpty || n == '.' || n == '..') return false;
  // 路径分隔符、Windows 盘符 / 备用数据流（':'）、首尾空格与结尾的点（Windows 会悄悄去掉）、控制字符。
  if (n.contains('/') || n.contains(r'\') || n.contains(':')) return false;
  if (n.trim() != n || n.endsWith('.')) return false;
  if (n.codeUnits.any((int c) => c < 0x20)) return false;
  // Windows 保留设备名（不分大小写，带不带扩展名都算）。
  return !_kWindowsReservedNames.contains(n.split('.').first.toUpperCase());
}

const Set<String> _kWindowsReservedNames = <String>{
  'CON', 'PRN', 'AUX', 'NUL', //
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

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

  SrsBackupManifest copyWith({bool? mediaEmbedded, String? eventsSha256}) =>
      SrsBackupManifest(
        createdAt: createdAt,
        kind: kind,
        profileUid: profileUid,
        profileName: profileName,
        noteCount: noteCount,
        cardCount: cardCount,
        reviewCount: reviewCount,
        eventCount: eventCount,
        eventsSha256: eventsSha256 ?? this.eventsSha256,
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

/// 清单副本：备份文件旁的隐藏文件 `.<备份名>.json`（列表不用解压；点开头，「文件」app / Finder 里不显示）。
File _sidecarOf(File backup) => File(
  p.join(
    p.dirname(backup.path),
    '.${p.basenameWithoutExtension(backup.path)}.json',
  ),
);

/// 备份文件名（不含扩展名）：用户在文件管理器 /「文件」app 里一眼能看懂——
/// `fushi-review-2026-10-17_093015-auto`（本地时间 + 种类）。只用于显示与排序，读回一律以清单为准。
String srsBackupFileStem(int createdAtMs, SrsBackupKind kind) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
  String two(int v) => v.toString().padLeft(2, '0');
  final String label = switch (kind) {
    SrsBackupKind.auto => 'auto',
    SrsBackupKind.manual => 'manual',
    SrsBackupKind.preRestore => 'before-restore',
  };
  return 'fushi-review-${d.year}-${two(d.month)}-${two(d.day)}_'
      '${two(d.hour)}${two(d.minute)}${two(d.second)}-$label';
}

/// [srsRelocateBackupRoot] 的结果。
enum SrsBackupRelocation {
  /// 旧位置不存在（或与新位置相同）：什么也没做。
  none,

  /// 同卷改名，整体搬过去。
  renamed,

  /// 跨卷：整体复制到新位置后删掉旧位置。
  copied,

  /// 新位置已存在：把旧位置里新位置没有的文件逐个搬过去（同名的不覆盖、留在旧位置）。
  merged,
}

/// 把旧位置的备份库整体搬到新位置（见 [SrsBackupStore.rootFor]）。
///
/// - 新位置不存在：先试同卷改名；失败（跨卷等）就复制到新位置旁的临时目录、校验文件数与大小、
///   改名就位，再删旧位置。复制中途失败删掉临时目录、旧位置原样保留，异常抛给调用方记日志——
///   任何失败都不丢文件。
/// - 新位置已存在：逐个文件搬「新位置没有的」，同名文件不覆盖（留在旧位置，下次再看）。
Future<SrsBackupRelocation> srsRelocateBackupRoot({
  required Directory from,
  required Directory to,
  @visibleForTesting
  Future<void> Function(Directory from, String to)? debugRenameDirectory,
  @visibleForTesting Future<void> Function()? debugAfterCopy,
}) async {
  if (!await from.exists()) return SrsBackupRelocation.none;
  if (p.equals(p.canonicalize(from.path), p.canonicalize(to.path))) {
    return SrsBackupRelocation.none;
  }
  if (!await to.exists()) {
    await to.parent.create(recursive: true);
    try {
      if (debugRenameDirectory != null) {
        await debugRenameDirectory(from, to.path);
      } else {
        await from.rename(to.path);
      }
      return SrsBackupRelocation.renamed;
    } on FileSystemException {
      // 跨卷：复制。
    }
    final Directory staging = Directory('${to.path}.relocating');
    try {
      if (await staging.exists()) await staging.delete(recursive: true);
      final (int files, int bytes) = await _copyTree(from, staging);
      await debugAfterCopy?.call();
      final (int gotFiles, int gotBytes) = await _treeStats(staging);
      if (gotFiles != files || gotBytes != bytes) {
        throw FileSystemException('backup relocation copy incomplete', to.path);
      }
      await staging.rename(to.path);
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
    await from.delete(recursive: true);
    return SrsBackupRelocation.copied;
  }
  await for (final FileSystemEntity e in from.list(recursive: true)) {
    if (e is! File) continue;
    final String rel = p.relative(e.path, from: from.path);
    final File target = File(p.join(to.path, rel));
    if (await target.exists()) continue;
    await target.parent.create(recursive: true);
    try {
      await e.rename(target.path);
    } on FileSystemException {
      final File tmp = File('${target.path}.relocating');
      await e.copy(tmp.path);
      await tmp.rename(target.path);
      await e.delete();
    }
  }
  // 旧位置只剩空目录（或同名未搬的文件）：能删就删，删不掉不要紧。
  try {
    if (!await _hasFiles(from)) await from.delete(recursive: true);
  } on FileSystemException {
    // 留着。
  }
  return SrsBackupRelocation.merged;
}

Future<(int, int)> _copyTree(Directory from, Directory to) async {
  int files = 0;
  int bytes = 0;
  await to.create(recursive: true);
  await for (final FileSystemEntity e in from.list(recursive: true)) {
    final String rel = p.relative(e.path, from: from.path);
    if (e is Directory) {
      await Directory(p.join(to.path, rel)).create(recursive: true);
    } else if (e is File) {
      final File target = File(p.join(to.path, rel));
      await target.parent.create(recursive: true);
      await e.copy(target.path);
      files++;
      bytes += await e.length();
    }
  }
  return (files, bytes);
}

Future<(int, int)> _treeStats(Directory d) async {
  int files = 0;
  int bytes = 0;
  await for (final FileSystemEntity e in d.list(recursive: true)) {
    if (e is File) {
      files++;
      bytes += await e.length();
    }
  }
  return (files, bytes);
}

Future<bool> _hasFiles(Directory d) async {
  await for (final FileSystemEntity e in d.list(recursive: true)) {
    if (e is File) return true;
  }
  return false;
}

/// 本机备份库（一个 profile）。见库注释。
class SrsBackupStore {
  SrsBackupStore({
    required this.root,
    required this.profileUid,
    required this.mediaDir,
  });

  /// 备份根（宿主给；app 里是 `<documents>/srs_backups`，旧位置见 [rootFor]）。
  final Directory root;
  final String profileUid;

  /// 本 profile 的媒体目录（`<支持目录>/srs_media/<profileUid>`）。
  final Directory mediaDir;

  /// 旧位置（2026-10-17 第一版）：`<支持目录>/srs_backups`。现在的位置由宿主给（app 放在数据根
  /// 的 documents 根下，与 Anki 一样放在用户看得到、换设备能带走的地方），旧位置的备份由
  /// [srsRelocateBackupRoot] 搬过去。
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
    final File side = _sidecarOf(f);
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

  /// 本机所有备份占用的磁盘空间（全部 profile 的备份文件 + 共享媒体池）。媒体池里与媒体目录硬链接的
  /// 文件也按全尺寸计（Dart 读不到链接数），实际多占的空间比这个数小。
  Future<int> diskUsage() async {
    if (!await root.exists()) return 0;
    int total = 0;
    await for (final FileSystemEntity e in root.list(recursive: true)) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  /// 做一份备份。[profileName] 只用于显示。
  ///
  /// 真实库三十万条复习日志要读二三十秒。在后台 isolate 里、srs.db 上另开的一条 Rust 只读连接里读
  /// （[SrsBackupSnapshotReader]），写连接上的复习查询与写入不排在它后面（BUG-3579 起先只是让路）。
  /// [shouldStop] 每读完一页问一次，为 true 时抛 [SrsBackupCancelled]：
  /// 读事务回滚（只读，没有副作用）、暂存文件删掉。
  Future<SrsBackupInfo> create(
    SrsDbStore store, {
    required SrsBackupKind kind,
    required String profileName,
    int? nowMs,
    bool Function()? shouldStop,
  }) async {
    void checkStop() {
      if (shouldStop?.call() ?? false) throw const SrsBackupCancelled();
    }

    if (store.profileUid != profileUid) {
      throw ArgumentError('store belongs to ${store.profileUid}');
    }
    final int createdAt = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    await profileDir.create(recursive: true);
    // 上一次没做完（进程在读快照 / 压缩时退出）留下的暂存文件：一份几百 MB，没人会再用。
    // 同一 profile 的备份由控制器串行做，这里不会碰到另一份正在写的。
    await for (final FileSystemEntity e in profileDir.list()) {
      final String name = p.basename(e.path);
      if (e is File &&
          name.startsWith('.') &&
          (name.endsWith('.events.tmp') ||
              name.endsWith('.server_times.tmp'))) {
        await _deleteQuietly(e);
      }
    }
    final String base = srsBackupFileStem(createdAt, kind);
    String id = base;
    for (int i = 2; File(_pathOf(id)).existsSync(); i++) {
      id = '$base-$i';
    }
    final File out = File(_pathOf(id));
    // 事件正文与服务器时间表先按页流式写进隐藏的暂存文件（内存只占一页），再由后台 isolate 流式压进 zip。
    final File eventsTmp = File(p.join(profileDir.path, '.$id.events.tmp'));
    final File serverTimesTmp = File(
      p.join(profileDir.path, '.$id.server_times.tmp'),
    );
    try {
      // 指纹、事件、服务器时间、计数必须是同一个快照。
      late final String fingerprint;
      late final ({int eventCount, SrsBackupCounts counts}) snap;
      // 写锁里取指纹并让后台独立只读连接（srs.db 上的 Rust 只读会话）拿到快照：这一刻没有进行中的
      // SRS 写入，两者一致；锁一放开就把写连接还给复习页，读取全在后台 isolate，写连接不等它。
      late final SrsBackupSnapshotReader reader;
      await store.runExclusive(() async {
        checkStop();
        fingerprint = await store.changeFingerprint();
        reader = await SrsBackupSnapshotReader.start(
          core: store.core,
          profileUid: profileUid,
          eventsPath: eventsTmp.path,
          serverTimesPath: serverTimesTmp.path,
          shouldStop: shouldStop,
        );
      });
      try {
        snap = await reader.done;
      } on SrsSnapshotCancelled {
        throw const SrsBackupCancelled();
      }
      final int eventCount = snap.eventCount;
      final SrsBackupCounts counts = snap.counts;
      final List<SrsBackupMediaEntry> media = await _captureMedia();
      final SrsBackupManifest template = SrsBackupManifest(
        createdAt: createdAt,
        kind: kind,
        profileUid: profileUid,
        profileName: profileName,
        noteCount: counts.notes,
        cardCount: counts.cards,
        reviewCount: counts.reviews,
        eventCount: eventCount,
        eventsSha256: '',
        fingerprint: fingerprint,
        media: media,
      );
      // 摘要、deflate 与写盘在后台 isolate 流式做，不卡界面、不把正文整份读进内存。
      final SrsBackupManifest manifest = await _writeInBackground(
        outPath: out.path,
        template: template,
        eventsPath: eventsTmp.path,
        serverTimesPath: serverTimesTmp.path,
      );
      await _sidecarOf(
        out,
      ).writeAsString(jsonEncode(manifest.toJson()), flush: true);
      return SrsBackupInfo(
        file: out,
        manifest: manifest,
        fileBytes: await out.length(),
      );
    } finally {
      await _deleteQuietly(eventsTmp);
      await _deleteQuietly(serverTimesTmp);
    }
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
      _sidecarOf(b.file),
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
  ///
  /// 只要有一份备份的清单读不出媒体列表（损坏、来自更新版本、读文件失败），这一轮就不回收：
  /// 读不懂不等于没引用，删了它要的媒体就再也恢复不全了。
  Future<void> collectMediaGarbage() async {
    final Directory pool = mediaPool;
    if (!await pool.exists()) return;
    final Set<String> referenced = <String>{};
    await for (final FileSystemEntity d in root.list()) {
      if (d is! Directory || p.basename(d.path) == _kMediaPool) continue;
      await for (final FileSystemEntity f in d.list()) {
        if (f is! File || p.extension(f.path) != '.$kSrsBackupExtension') {
          continue;
        }
        final Set<String>? shas = await _mediaShasOf(f);
        if (shas == null) return;
        referenced.addAll(shas);
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

  /// 宽松地读一份备份引用的媒体哈希（不校验版本，只认 `media[].sha256`）；读不出返回 null。
  static Future<Set<String>?> _mediaShasOf(File f) async {
    Object? json;
    final File side = _sidecarOf(f);
    try {
      if (await side.exists()) json = jsonDecode(await side.readAsString());
    } on Object {
      json = null;
    }
    if (json is! Map) {
      try {
        final (Archive a, InputFileStream input) = _openZip(f);
        try {
          final ArchiveFile? m = _find(a, _kManifest);
          if (m == null || m.size > _kMaxManifestBytes) return null;
          json = jsonDecode(utf8.decode(_content(m)));
        } finally {
          input.closeSync();
        }
      } on Object {
        return null;
      }
    }
    if (json is! Map) return null;
    final Object? media = json['media'];
    if (media == null) return <String>{};
    if (media is! List) return null;
    final Set<String> out = <String>{};
    for (final Object? m in media) {
      final Object? sha = m is Map ? m['sha256'] : null;
      if (sha is! String) return null;
      out.add(sha);
    }
    return out;
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
    final Set<String> listed = <String>{};
    for (final File f in files) {
      final String name = p.basename(f.path);
      if (!_isBareName(name) ||
          name.endsWith('.tmp') ||
          name.endsWith('.download')) {
        continue;
      }
      final FileStat st = await f.stat();
      // 列出之后被删掉的（墓碑清除回收了不再被引用的媒体，见 srs_purge.dart）：不进这份备份。
      if (st.type == FileSystemEntityType.notFound) continue;
      final String key = '$profileUid/$name';
      listed.add(key);
      final Object? cached = index[key];
      String? sha;
      if (cached is Map &&
          cached['size'] == st.size &&
          cached['mtime'] == st.modified.millisecondsSinceEpoch &&
          cached['sha256'] is String) {
        sha = cached['sha256']! as String;
      }
      final String hash;
      try {
        hash = sha ?? await ffcSha256File(f.path);
      } on Object {
        if (!await f.exists()) {
          listed.remove(key);
          continue;
        }
        rethrow;
      }
      final bool sameEntry = cached is Map && cached['sha256'] == hash;
      if (!sameEntry) {
        index[key] = <String, Object?>{
          'size': st.size,
          'mtime': st.modified.millisecondsSinceEpoch,
          'sha256': hash,
        };
        dirty = true;
      }
      // 池文件与媒体文件同卷时是硬链接（不占第二份空间）。旧版本复制进池的文件在这里换成
      // 链接；换过的在索引里记一笔（`linked`），之后不再每次重链。
      final File pooled = File(p.join(mediaPool.path, hash));
      try {
        final bool present =
            await pooled.exists() && await pooled.length() == st.size;
        if (!present || !(sameEntry && cached['linked'] == true)) {
          final File tmp = File('${pooled.path}.tmp');
          await _deleteQuietly(tmp);
          final bool linked = tryCreateHardLink(f.path, tmp.path);
          if (linked || !present) {
            if (!linked) await f.copy(tmp.path);
            await tmp.rename(pooled.path);
          }
          if (linked) {
            (index[key]! as Map<String, Object?>)['linked'] = true;
            dirty = true;
          }
        }
      } on Object {
        // 列出之后被删掉的（墓碑清除回收）：不进这份备份，索引条目由下面的过期清理丢掉。
        if (!await f.exists()) {
          listed.remove(key);
          continue;
        }
        rethrow;
      }
      out.add(SrsBackupMediaEntry(name: name, sha256: hash, size: st.size));
    }
    // 本 profile 已不在媒体目录里的文件：哈希缓存条目一起丢掉（不然随回收的媒体只增不减）。
    final String own = '$profileUid/';
    final List<String> stale = <String>[
      for (final String k in index.keys)
        if (k.startsWith(own) && !listed.contains(k)) k,
    ];
    if (stale.isNotEmpty) {
      stale.forEach(index.remove);
      dirty = true;
    }
    if (dirty) await _writeMediaIndex(index);
    return out;
  }

  // ---------------------------------------------------------------- 文件读写

  /// 在后台 isolate 里流式算事件摘要、deflate、写 zip。静态方法：闭包只带这几个可发送的参数。
  static Future<SrsBackupManifest> _writeInBackground({
    required String outPath,
    required SrsBackupManifest template,
    required String eventsPath,
    required String serverTimesPath,
  }) => Isolate.run(() async {
    final File evDeflated = File('$eventsPath.deflate');
    final File stDeflated = File('$serverTimesPath.deflate');
    try {
      final _Deflated ev = await _deflateFile(File(eventsPath), evDeflated);
      final _Deflated st = await _deflateFile(
        File(serverTimesPath),
        stDeflated,
      );
      final SrsBackupManifest m = template.copyWith(eventsSha256: ev.sha256);
      await _writeArchiveFiles(
        out: File(outPath),
        manifest: m,
        entries: <(String, File, _Deflated)>[
          (_kEvents, evDeflated, ev),
          (_kServerTimes, stDeflated, st),
        ],
      );
      return m;
    } finally {
      for (final File f in <File>[evDeflated, stDeflated]) {
        if (await f.exists()) await f.delete();
      }
    }
  });

  /// 把 [src] 流式压成 zip 用的裸 deflate 流写到 [dst]，同时算原文的长度、CRC-32 与 SHA-256。
  static Future<_Deflated> _deflateFile(File src, File dst) async {
    int size = 0;
    int crc = 0;
    final FfcSha256Hasher sha = FfcSha256Hasher.create();
    try {
      final IOSink out = dst.openWrite();
      try {
        await out.addStream(
          src
              .openRead()
              .map((List<int> chunk) {
                size += chunk.length;
                crc = ffcCrc32(chunk, crc);
                sha.add(chunk);
                return chunk;
              })
              .transform(ZLibEncoder(raw: true)),
        );
      } finally {
        await out.close();
      }
      return _Deflated(size: size, crc32: crc, sha256: sha.finishHex());
    } finally {
      // 读 / 压缩 / 写任一步抛错都要释放原生上下文。
      sha.close();
    }
  }

  /// 写 zip：清单（内存里，小）+ 已经压好的条目（按块拷贝进 zip，不解压、不整份读入）。
  static Future<void> _writeArchiveFiles({
    required File out,
    required SrsBackupManifest manifest,
    required List<(String, File, _Deflated)> entries,
  }) async {
    final File tmp = File('${out.path}.tmp');
    final ZipFileEncoder enc = ZipFileEncoder()..create(tmp.path);
    final List<InputFileStream> inputs = <InputFileStream>[];
    try {
      final List<int> m = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
      );
      enc.addArchiveFile(ArchiveFile(_kManifest, m.length, m));
      for (final (String name, File deflated, _Deflated d) in entries) {
        final InputFileStream input = InputFileStream(deflated.path);
        inputs.add(input);
        enc.addArchiveFile(
          ArchiveFile(name, d.size, input, ArchiveFile.DEFLATE)
            ..crc32 = d.crc32,
        );
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
    } finally {
      for (final InputFileStream i in inputs) {
        await i.close();
      }
    }
    await _commitArchive(tmp, out);
  }

  /// 落盘后再改名：断电时不会留下「改名成功、内容还在缓存里」的半个备份。
  static Future<void> _commitArchive(File tmp, File out) async {
    final RandomAccessFile raf = await tmp.open(mode: FileMode.append);
    try {
      await raf.flush();
    } finally {
      await raf.close();
    }
    if (await out.exists()) await out.delete();
    await tmp.rename(out.path);
  }

  static Uint8List _encodeEvents(List<SrsEvent> events) =>
      _joinLines(<String>[for (final SrsEvent e in events) e.canonical()]);

  static Uint8List _joinLines(List<String> lines) {
    final StringBuffer sb = StringBuffer();
    for (final String l in lines) {
      sb
        ..write(l)
        ..write('\n');
    }
    return Uint8List.fromList(utf8.encode(sb.toString()));
  }

  static Future<void> _writeArchive({
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
    await _commitArchive(tmp, out);
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
    if (m == null || m.size > _kMaxManifestBytes) {
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
    if (ev.size > _kMaxEventsBytes) {
      throw const SrsBackupFormatException(
        SrsBackupInvalidReason.corrupt,
        'events too large',
      );
    }
    final List<int> body = _content(ev);
    if (ffcSha256Bytes(body) != manifest.eventsSha256) {
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
    if (st != null && st.size > _kMaxServerTimesBytes) {
      throw const SrsBackupFormatException(
        SrsBackupInvalidReason.corrupt,
        'server times too large',
      );
    }
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
    final Map<String, bool> verified = <String, bool>{};
    for (final SrsBackupMediaEntry m in a.manifest.media) {
      final File pooled = File(p.join(mediaPool.path, m.sha256));
      // 池文件按内容哈希核对一次：损坏的不打进导出文件（否则读方校验不过、等于没带），并删掉让下次备份从
      // 媒体目录重新入池。
      final bool good = verified[m.sha256] ??=
          await pooled.exists() && await _sha256Of(pooled) == m.sha256;
      if (!good) {
        await _deleteQuietly(pooled);
        continue;
      }
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

  /// 恢复前先把备份引用的媒体放回本 profile 的媒体目录。一律按**内容哈希**判定（共享池本来就是内容寻址的）：
  /// - 本机已有同名文件且内容哈希与清单一致 → 不动；同名但内容不同（哪怕大小相同）→ 换成备份里的那份。
  /// - 先从共享池取；池文件哈希不符（损坏）→ 删掉坏的池文件，改从文件内嵌的正文取，取到后连同池文件一起修好。
  /// - 都取不到才记缺失（本机原有的同名文件保持原样，不删）。
  /// 本机多出来的文件不删（媒体删除不跨设备传播，也不在恢复里删）。返回取不到的文件数。
  Future<int> restoreMedia(SrsBackupArchive a) async {
    int missing = 0;
    for (final SrsBackupMediaEntry m in a.manifest.media) {
      final File target = File(p.join(mediaDir.path, m.name));
      if (await target.exists() &&
          await target.length() == m.size &&
          await _sha256Of(target) == m.sha256) {
        continue;
      }
      await mediaDir.create(recursive: true);
      final File tmp = File('${target.path}.tmp');
      final File pooled = File(p.join(mediaPool.path, m.sha256));
      bool ok = false;
      bool poolCorrupt = false;
      if (await pooled.exists()) {
        if (await _sha256Of(pooled) == m.sha256) {
          // 同卷时硬链接回去（与入池同理）；不行再复制、复制后再核一次哈希。
          await _deleteQuietly(tmp);
          if (tryCreateHardLink(pooled.path, tmp.path)) {
            ok = true;
          } else {
            await pooled.copy(tmp.path);
            ok = await _sha256Of(tmp) == m.sha256;
          }
        } else {
          poolCorrupt = true;
          await _deleteQuietly(pooled);
        }
      }
      if (!ok) {
        await _deleteQuietly(tmp);
        final ArchiveFile? embedded = a._embedded[m.sha256];
        if (embedded != null &&
            embedded.size == m.size &&
            m.size <= _kMaxMediaBytes) {
          final OutputFileStream os = OutputFileStream(tmp.path);
          try {
            embedded.writeContent(os);
          } finally {
            await os.close();
          }
          ok = await _sha256Of(tmp) == m.sha256;
          if (ok && poolCorrupt) {
            // 坏池文件换成校验过的正文：别的备份引用的也是这份内容。
            final File poolTmp = File('${pooled.path}.tmp');
            await tmp.copy(poolTmp.path);
            await poolTmp.rename(pooled.path);
          }
        }
      }
      if (ok) {
        await tmp.rename(target.path);
        continue;
      }
      await _deleteQuietly(tmp);
      missing++;
    }
    return missing;
  }

  static Future<String?> _sha256Of(File f) async {
    try {
      return await ffcSha256File(f.path);
    } on FileSystemException {
      return null;
    }
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // 删不掉（被占用）：不影响结果判定，下次再收。
    }
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

/// 一个已经压好的 zip 条目：原文长度、CRC-32、SHA-256。
class _Deflated {
  const _Deflated({
    required this.size,
    required this.crc32,
    required this.sha256,
  });

  final int size;
  final int crc32;
  final String sha256;
}
