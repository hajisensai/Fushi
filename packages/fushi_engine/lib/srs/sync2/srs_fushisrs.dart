/// 手动导出 / 导入 `.fushisrs`（docs/specs/2026-10-25-srs-sync-v2-design.md §10.4）：离线保存，或完全不连同步
/// 时搬到新设备。只有手动导出，不定时（归档位置已覆盖定期备份的需求）。
///
/// 包是一个 zip：`ops.bin`（内核导出的全部操作 + 各设备公钥，见 store/sync2/transport.rs `sync2_export`）、
/// `manifest.json`（格式版本、profile、导出时刻、带不带媒体）、可选的 `media/<文件名>`（媒体默认带上）。
/// 导入 = 操作**并入**（不覆盖任何一方），媒体只补本机缺的；包里有本机身份的操作时内核先换身份（§7.3）。
///
/// **旧格式**（v2 之前定时 / 手动备份写的同扩展名文件，清单魔数 [kSrsLegacyBackupMagic]）照样能导入：
/// `events.jsonl` 里的事件按「外来、已盖过戳」并入（[SrsDbStore.applyRemote]，保留原 dot / 因果上下文 / HLC，
/// `server_times.json` 给逐事件的 S(e)），与通用备份合并同一条路径；媒体取文件内嵌的 `media/<sha256>`，没内嵌
/// （本机自动备份）就到旧备份根的共享池 `<srs_backups>/media/<sha256>` 找，一律按 SHA-256 校验。旧备份层本身
/// 已删除，这里只保留最小的读取与转换。
///
/// **isolate 边界**：读包（读文件、解压、校验摘要、解析 JSON / 事件、写补进来的媒体）与写包（读媒体、组 zip、
/// 写文件）都在后台 isolate（[Isolate.run]），主 isolate 只做必须碰数据库连接的几步——导出时取操作字节与被引用
/// 媒体名、导入时打还原点并把解析好的操作 / 事件交给库。后台 isolate 只拿纯数据（路径、profile uid），不持有
/// [SrsDbStore]，也不往回传文件句柄。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsEvent;
import 'package:path/path.dart' as p;

const String kSrsFushiSrsExtension = 'fushisrs';
const int kSrsFushiSrsVersion = 1;

/// 导出结果。
class SrsFushiSrsExport {
  const SrsFushiSrsExport({required this.bytes, required this.mediaFiles});

  final int bytes;
  final int mediaFiles;
}

/// 导入结果。
class SrsFushiSrsImport {
  const SrsFushiSrsImport({required this.applied, required this.mediaFiles});

  /// 并入的操作条数（已有的不算）。
  final int applied;

  /// 补进本机的媒体文件数。
  final int mediaFiles;
}

/// 导出到 [out]（覆盖）。[withMedia] = 带上全部被引用的媒体（缺省带）。
Future<SrsFushiSrsExport> srsExportFushiSrs(
  SrsDbStore store,
  File out, {
  Directory? mediaRoot,
  bool withMedia = true,
}) async {
  final Uint8List ops = await store.sync2ExportOps();
  final bool media = withMedia && mediaRoot != null;
  final List<String> names = media
      ? (await srsReferencedMedia(store)).toList()
      : const <String>[];
  return _runWriteFushiSrs(
    ops: ops,
    manifestJson: jsonEncode(<String, Object?>{
      'v': kSrsFushiSrsVersion,
      'profile': store.profileUid,
      'exportedAt': store.now().$1,
      'media': media,
    }),
    outPath: out.path,
    mediaRootPath: mediaRoot?.path,
    mediaNames: names,
  );
}

/// 单独一个函数作用域：交给 [Isolate.run] 的闭包只捕获这里的纯数据参数，捕获不到调用方的 [SrsDbStore]。
Future<SrsFushiSrsExport> _runWriteFushiSrs({
  required Uint8List ops,
  required String manifestJson,
  required String outPath,
  required String? mediaRootPath,
  required List<String> mediaNames,
}) => Isolate.run(
  () => _writeFushiSrs(ops, manifestJson, outPath, mediaRootPath, mediaNames),
  debugName: 'srs-fushisrs-export',
);

Future<SrsFushiSrsExport> _writeFushiSrs(
  Uint8List ops,
  String manifestJson,
  String outPath,
  String? mediaRootPath,
  List<String> mediaNames,
) async {
  final Archive zip = Archive();
  zip.addFile(ArchiveFile.string('manifest.json', manifestJson));
  zip.addFile(ArchiveFile('ops.bin', ops.length, ops));
  int media = 0;
  if (mediaRootPath != null) {
    for (final String name in mediaNames) {
      final File f = File(p.join(mediaRootPath, name));
      if (!f.existsSync()) continue;
      final Uint8List b = await f.readAsBytes();
      zip.addFile(ArchiveFile('media/$name', b.length, b));
      media++;
    }
  }
  final List<int> bytes = ZipEncoder().encode(zip)!;
  final File out = File(outPath);
  await out.parent.create(recursive: true);
  final File tmp = File('$outPath.tmp');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(outPath);
  return SrsFushiSrsExport(bytes: bytes.length, mediaFiles: media);
}

/// 导入 [file]：操作并入、媒体补缺。不是本 profile 的包抛 [FormatException]。新旧两种格式都认（见文件头）；
/// [legacyMediaPool] = 旧备份的共享媒体池（旧格式没内嵌媒体时到这里找；另外总会看文件所在备份根的 `media/`）。
Future<SrsFushiSrsImport> srsImportFushiSrs(
  SrsDbStore store,
  File file, {
  Directory? mediaRoot,
  Directory? legacyMediaPool,
}) async {
  final _ParsedFushiSrs parsed = await _runReadFushiSrs(
    path: file.path,
    profileUid: store.profileUid,
    mediaRootPath: mediaRoot?.path,
    poolPaths: <String>[
      ?legacyMediaPool?.path,
      // 本机旧备份的布局：`<备份根>/<profileUid>/<文件>`，共享池在 `<备份根>/media/`。
      p.join(p.dirname(p.dirname(file.path)), 'media'),
    ],
  );
  await store.sync2Checkpoint(p.basename(file.path), 'import');
  switch (parsed) {
    case _ParsedOps(:final Uint8List ops, :final int mediaFiles):
      final int applied = await store.sync2ImportOps(ops);
      return SrsFushiSrsImport(applied: applied, mediaFiles: mediaFiles);
    case _ParsedLegacy(
      :final List<SrsEvent> events,
      :final Map<String, int> serverTimes,
      :final int mediaFiles,
    ):
      final int before = store.revision;
      await store.applyRemote(events, serverTimes: serverTimes);
      // 修订号只随真正落进投影的事件推进（已有的、被支配的不算）：与新格式「并入条数」同一口径。
      return SrsFushiSrsImport(
        applied: store.revision - before,
        mediaFiles: mediaFiles,
      );
  }
}

/// 后台 isolate 读包的结果：要交给库的数据 + 已补进本机的媒体数。只含可跨 isolate 传递的纯数据。
sealed class _ParsedFushiSrs {
  const _ParsedFushiSrs(this.mediaFiles);

  final int mediaFiles;
}

/// 新格式：内核导出的操作字节。
final class _ParsedOps extends _ParsedFushiSrs {
  const _ParsedOps(this.ops, super.mediaFiles);

  final Uint8List ops;
}

/// 旧格式：已校验摘要与条数的事件 + 服务器时间表。
final class _ParsedLegacy extends _ParsedFushiSrs {
  const _ParsedLegacy(this.events, this.serverTimes, super.mediaFiles);

  final List<SrsEvent> events;
  final Map<String, int> serverTimes;
}

/// 同 [_runWriteFushiSrs]：闭包只捕获纯数据参数。
Future<_ParsedFushiSrs> _runReadFushiSrs({
  required String path,
  required String profileUid,
  required String? mediaRootPath,
  required List<String> poolPaths,
}) => Isolate.run(
  () => _readFushiSrs(path, profileUid, mediaRootPath, poolPaths),
  debugName: 'srs-fushisrs-import',
);

/// 在后台 isolate 跑：解压、校验、解析，并把包里本机缺的媒体先写进 [mediaRootPath]（媒体先于引用它的操作
/// 落地，与上传纪律一致）。任何校验失败抛 [FormatException]（[Isolate.run] 原样转抛给调用方），此时库没被碰过。
Future<_ParsedFushiSrs> _readFushiSrs(
  String path,
  String profileUid,
  String? mediaRootPath,
  List<String> poolPaths,
) async {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(await File(path).readAsBytes());
  } on Object {
    throw const FormatException('not a .fushisrs file');
  }
  final ArchiveFile? manifest = zip.findFile('manifest.json');
  if (manifest == null || manifest.size > _kLegacyMaxManifestBytes) {
    throw const FormatException('not a .fushisrs file');
  }
  final Object? m;
  try {
    m = jsonDecode(utf8.decode(manifest.content as List<int>));
  } on FormatException {
    throw const FormatException('not a .fushisrs file');
  }
  final Directory? mediaRoot = mediaRootPath == null
      ? null
      : Directory(mediaRootPath);
  if (m is Map && m['magic'] == kSrsLegacyBackupMagic) {
    return _readLegacy(
      zip,
      m.cast<String, Object?>(),
      profileUid: profileUid,
      mediaRoot: mediaRoot,
      pools: <Directory>[for (final String d in poolPaths) Directory(d)],
    );
  }
  final ArchiveFile? ops = zip.findFile('ops.bin');
  if (ops == null) {
    throw const FormatException('not a .fushisrs file');
  }
  if (m is! Map || ((m['v'] as int?) ?? 0) > kSrsFushiSrsVersion) {
    throw const FormatException('unsupported .fushisrs version');
  }
  if (m['profile'] != profileUid) {
    throw const FormatException('this .fushisrs belongs to another profile');
  }
  int media = 0;
  if (mediaRoot != null) {
    for (final ArchiveFile f in zip.files) {
      if (!f.isFile || !f.name.startsWith('media/')) continue;
      final String name = f.name.substring('media/'.length);
      if (!srsIsBareMediaName(name)) continue;
      final File local = File(p.join(mediaRoot.path, name));
      if (local.existsSync()) continue;
      await mediaRoot.create(recursive: true);
      await local.writeAsBytes(f.content as List<int>, flush: true);
      media++;
    }
  }
  return _ParsedOps(Uint8List.fromList(ops.content as List<int>), media);
}

// ---------------------------------------------------------------- 旧格式（v2 之前的备份）

/// 旧格式备份清单的魔数（develop f71b5aaa98 `srs_backup_store.dart` 的 `kSrsBackupMagic`，冻结）。
const String kSrsLegacyBackupMagic = 'fushi-srs-backup';

/// 本版本还能读的旧格式最高版本（旧清单的 `minReaderVersion` 比它高 = 来自更新版本）。
const int _kLegacyReaderVersion = 1;

/// 解压上限（外部文件不可信，防解压炸弹；与旧实现相同）。
const int _kLegacyMaxManifestBytes = 64 << 20;
const int _kLegacyMaxServerTimesBytes = 512 << 20;
const int _kLegacyMaxEventsBytes = 1024 << 20;
const int _kLegacyMaxMediaBytes = 2047 << 20;

final RegExp _sha256Re = RegExp(r'^[0-9a-f]{64}$');

const Set<String> _kWindowsReservedNames = <String>{
  'CON', 'PRN', 'AUX', 'NUL', //
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

/// 旧清单里的媒体名只认裸文件名（旧实现同一套规则：无路径分隔 / 盘符 / 控制字符 / Windows 保留名）。
bool _isLegacyBareName(String n) {
  if (!srsIsBareMediaName(n) || n.contains(':')) return false;
  if (n.trim() != n || n.endsWith('.')) return false;
  if (n.codeUnits.any((int c) => c < 0x20)) return false;
  return !_kWindowsReservedNames.contains(n.split('.').first.toUpperCase());
}

FormatException _corrupt(String detail) =>
    FormatException('corrupt legacy .fushisrs backup: $detail');

List<int> _legacyContent(ArchiveFile f, int max, String what) {
  if (f.size > max) throw _corrupt('$what too large');
  final Object? c = f.content;
  if (c is List<int>) return c;
  throw _corrupt(what);
}

Future<_ParsedLegacy> _readLegacy(
  Archive zip,
  Map<String, Object?> manifest, {
  required String profileUid,
  required Directory? mediaRoot,
  required List<Directory> pools,
}) async {
  final Object? minReader = manifest['minReaderVersion'];
  if (minReader is! int || minReader > _kLegacyReaderVersion) {
    throw const FormatException('unsupported .fushisrs version');
  }
  if (manifest['profileUid'] != profileUid) {
    throw const FormatException('this .fushisrs belongs to another profile');
  }
  final Object? ev = manifest['events'];
  if (ev is! Map || ev['sha256'] is! String || ev['count'] is! int) {
    throw _corrupt('manifest events');
  }
  final ArchiveFile? eventsFile = zip.findFile('events.jsonl');
  if (eventsFile == null) throw _corrupt('events missing');
  final List<int> body = _legacyContent(
    eventsFile,
    _kLegacyMaxEventsBytes,
    'events',
  );
  if (sha256.convert(body).toString() != ev['sha256']) {
    throw _corrupt('events sha256 mismatch');
  }
  final List<SrsEvent> events = <SrsEvent>[];
  try {
    for (final String line in const LineSplitter().convert(utf8.decode(body))) {
      if (line.isEmpty) continue;
      events.add(
        SrsEvent.fromJson((jsonDecode(line) as Map).cast<String, Object?>()),
      );
    }
  } on Object catch (e) {
    throw _corrupt('events: $e');
  }
  if (events.length != ev['count']) throw _corrupt('event count mismatch');
  final Map<String, int> serverTimes = <String, int>{};
  final ArchiveFile? st = zip.findFile('server_times.json');
  if (st != null) {
    final Object? j;
    try {
      j = jsonDecode(
        utf8.decode(
          _legacyContent(st, _kLegacyMaxServerTimesBytes, 'server times'),
        ),
      );
    } on FormatException {
      throw _corrupt('server times');
    }
    if (j is Map) {
      for (final MapEntry<Object?, Object?> e in j.entries) {
        if (e.key is String && e.value is int) {
          serverTimes[e.key! as String] = e.value! as int;
        }
      }
    }
  }
  // 先补媒体（媒体先于引用它的事件落地）。清单条目逐条校验，坏条目跳过（旧实现同样只认合法条目）。
  int media = 0;
  if (mediaRoot != null) {
    for (final Object? raw
        in (manifest['media'] as List?) ?? const <Object?>[]) {
      if (raw is! Map) continue;
      final Object? name = raw['name'];
      final Object? sha = raw['sha256'];
      if (name is! String || sha is! String) continue;
      if (!_isLegacyBareName(name) || !_sha256Re.hasMatch(sha)) continue;
      final File local = File(p.join(mediaRoot.path, name));
      if (local.existsSync()) continue;
      final List<int>? bytes = await _legacyMedia(zip, sha, pools);
      if (bytes == null) continue;
      await mediaRoot.create(recursive: true);
      final File tmp = File('${local.path}.import.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(local.path);
      media++;
    }
  }
  return _ParsedLegacy(events, serverTimes, media);
}

/// 旧格式媒体正文：先取文件内嵌的 `media/<sha256>`，再到各共享池找；一律按内容哈希校验，对不上当没有。
Future<List<int>?> _legacyMedia(
  Archive zip,
  String sha,
  List<Directory> pools,
) async {
  final ArchiveFile? embedded = zip.findFile('media/$sha');
  if (embedded != null && embedded.size <= _kLegacyMaxMediaBytes) {
    final Object? c = embedded.content;
    if (c is List<int> && sha256.convert(c).toString() == sha) return c;
  }
  for (final Directory pool in pools) {
    final File f = File(p.join(pool.path, sha));
    if (!f.existsSync() || f.lengthSync() > _kLegacyMaxMediaBytes) continue;
    final Uint8List b = await f.readAsBytes();
    if (sha256.convert(b).toString() == sha) return b;
  }
  return null;
}
