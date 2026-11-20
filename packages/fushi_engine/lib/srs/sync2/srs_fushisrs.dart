/// 手动导出 / 导入 `.fushisrs`（docs/specs/2026-10-25-srs-sync-v2-design.md §10.4；协议 4 第 2 版见
/// docs/specs/2026-11-15-srs-gen4-g7-g11-plan.md §1.9 与交接说明「G11-3」）：离线保存，或完全不连同步时搬到新设备。
/// 只有手动导出，不定时（归档位置已覆盖定期备份的需求）。
///
/// 包是一个 zip：
///
/// - `manifest.json`：`{v: 2, gen: 4, profile, collection, dir, salts, peers, exportedAt, media}`（**不带 `magic`**）。
///   `collection` / `dir` / `salts` / `peers` 是内核导出命令的回包原样（本机绑定与各设备公钥，缺口 G-12），其余由这里填。
/// - `ops.bin`：内核写的 `FSRS4EXP` 流（native/fushi_fsrs/src/store/gen4/cmd/fushisrs.rs），**不压缩存放**（流本身已是
///   zstd；不压缩才能在导入时不整份进内存地拷出来交给内核按文件流式读）。
/// - 可选的 `media/<文件名>`（媒体默认带上）。
///
/// 导入 = 操作**并入**（不覆盖任何一方），媒体只补本机缺的。文件来自另一个复习库（另一个集合），或同一个复习库的文件
/// 带来本机还不算数的盐 / 还不认识的设备公钥时，内核先回「需确认」、什么都不写；调用方确认（[srsImportFushiSrs] 的
/// `confirmForeign`）后才并入 / 落下这些再导入。包里本机身份的日志与本机分叉
/// 了（拷过数据目录）时内核先换身份。
///
/// 顺序：解包（不碰媒体目录）→ 内核**预检**（什么都不写，判要不要确认、会不会被拒）→ 需要时问用户，答否就此结束、本机一点
/// 没动 → 打还原点 → 补媒体 → 内核导入；内核这时拒收（坏在流中间的文件）就删掉这次补进来的媒体再抛错。
///
/// **旧格式**：
///
/// - 第 1 版（`v: 1`，协议 3 的 `FSRS2EXP` 操作流）：同样交给内核，内核用冻结的读入器转译导入；另一个 profile 的拒收。
/// - v2 同步之前的事件备份（清单魔数 [kSrsLegacyBackupMagic]，D34 长期支持；G11-4）：`events.jsonl` 校验摘要与条数后
///   写成「外来、已盖戳」的 JSONL（带 `server_times.json` 的逐事件服务器时间），交给内核 `legacy_backup_import`
///   （`source: "events"`）——在临时目录里用冻结的协议 3 代码落进一份临时库，再读进新代库，认领 / 确认与第 2 版同一口径。
///   只认本 profile 的（与协议 3 时代一样，另一个 profile 的拒收）；媒体取文件内嵌的 `media/<sha256>`，没内嵌（本机自动
///   备份）就到旧备份根的共享池 `<srs_backups>/media/<sha256>` 找，一律按 SHA-256 校验。
///
/// **旧版本**：新包的 `v` 是 2，已发布版本的读者（`v > 1` 一律「unsupported .fushisrs version」）在碰库之前就拒收；协议 3
/// 内核也不认 `FSRS4EXP` 魔数（Rust 测试 `old_binaries_refuse_the_new_stream_and_change_nothing`）。
///
/// **isolate 边界**：读包（解出清单与 `ops.bin`、写补进来的媒体）与写包（组 zip、写文件）都在后台 isolate（[Isolate.run]），
/// 主 isolate 只发内核命令（导出时内核直接把 `ops.bin` 写进临时文件，导入时内核直接读临时文件——操作字节不经 Dart 内存）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart' hide ZLibDecoder;
import 'package:crypto/crypto.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsOpTooLargeException;
import 'package:path/path.dart' as p;

const String kSrsFushiSrsExtension = 'fushisrs';

/// 本版本写的格式版本（第 2 版 = 协议 4）。
const int kSrsFushiSrsVersion = 2;

/// 第 2 版清单的代号（协议 4）。
const int kSrsFushiSrsGen = 4;

/// 旧格式备份清单的魔数（develop f71b5aaa98 `srs_backup_store.dart` 的 `kSrsBackupMagic`，冻结）。
const String kSrsLegacyBackupMagic = 'fushi-srs-backup';

/// 旧格式能读的最高 `minReaderVersion`（冻结）。
const int _kLegacyReaderVersion = 1;

/// 旧格式的解压上限（冻结，与旧备份层同值）：事件正文、服务器时间表、单个内嵌媒体。
const int _kLegacyMaxEventsBytes = 1024 << 20;
const int _kLegacyMaxServerTimesBytes = 512 << 20;
const int _kLegacyMaxMediaBytes = 2047 << 20;

final RegExp _sha256Re = RegExp(r'^[0-9a-f]{64}$');

/// 清单的上限（外部文件不可信，防解压炸弹）。
const int _kMaxManifestBytes = 64 << 20;

/// 导出结果。
class SrsFushiSrsExport {
  const SrsFushiSrsExport({required this.bytes, required this.mediaFiles});

  final int bytes;
  final int mediaFiles;
}

/// 导入结果。
class SrsFushiSrsImport {
  const SrsFushiSrsImport({
    required this.applied,
    required this.mediaFiles,
    this.declined = false,
  });

  /// 并入的条数（已有的不算）。
  final int applied;

  /// 补进本机的媒体文件数。
  final int mediaFiles;

  /// 文件来自另一个复习库、用户没有确认合并：库没动。
  final bool declined;
}

/// 导入要用户确认的原因（内核导入命令 `needsConfirm` 回包的 `reason`，native/fushi_fsrs/src/store/gen4/cmd/fushisrs.rs
/// 文件头第 1 步）。
enum SrsFushiSrsConfirmReason {
  /// 文件来自另一个复习库（另一个集合）：导入会把两个库并成一个。
  join,

  /// 同一个复习库的文件，但带来本机还不算数的旧 profile 标识（盐，[SrsFushiSrsForeign.newSalts]）或本机还不认识的
  /// 设备公钥（[SrsFushiSrsForeign.newPeers]）：只有文件确实是自己的才该接受。
  identity,
}

/// 导入前要用户确认的事（[SrsFushiSrsConfirmReason]）；确认之前内核什么都没写。
class SrsFushiSrsForeign {
  const SrsFushiSrsForeign({
    required this.collection,
    required this.dir,
    this.reason = SrsFushiSrsConfirmReason.join,
    this.newSalts = const <String>[],
    this.newPeers = const <String>[],
  });

  /// 内核 `needsConfirm` 回包（预检或真导入）。
  factory SrsFushiSrsForeign.fromReply(Map<String, Object?> r) =>
      SrsFushiSrsForeign(
        collection: r['collection']! as String,
        dir: r['dir']! as String,
        reason: r['reason'] == 'identity'
            ? SrsFushiSrsConfirmReason.identity
            : SrsFushiSrsConfirmReason.join,
        newSalts: <String>[
          for (final Object? s
              in (r['newSalts'] as List<Object?>?) ?? const <Object?>[])
            s! as String,
        ],
        newPeers: <String>[
          for (final Object? d
              in (r['newPeers'] as List<Object?>?) ?? const <Object?>[])
            d! as String,
        ],
      );

  final String collection;
  final String dir;
  final SrsFushiSrsConfirmReason reason;

  /// 这次会加进本复习库的旧 profile 标识（盐）。
  final List<String> newSalts;

  /// 这次会记下公钥的新设备（设备 ID）。
  final List<String> newPeers;
}

/// 导出到 [out]（覆盖）。[withMedia] = 带上全部被引用的媒体（缺省带）。
Future<SrsFushiSrsExport> srsExportFushiSrs(
  SrsDbStore store,
  File out, {
  Directory? mediaRoot,
  bool withMedia = true,
}) async {
  final Directory staging = await Directory.systemTemp.createTemp(
    'fushi_srs_export_',
  );
  try {
    final String opsPath = p.join(staging.path, 'ops.bin');
    final Map<String, Object?> core = await store.sync2ExportOps(opsPath);
    final bool media = withMedia && mediaRoot != null;
    final List<String> names = media
        ? (await srsReferencedMedia(store)).toList()
        : const <String>[];
    return await _runWriteFushiSrs(
      opsPath: opsPath,
      manifestJson: jsonEncode(<String, Object?>{
        'v': kSrsFushiSrsVersion,
        'gen': kSrsFushiSrsGen,
        'profile': store.profileUid,
        'collection': core['collection'],
        'dir': core['dir'],
        'salts': core['salts'],
        'peers': core['peers'],
        'exportedAt': store.now().$1,
        'media': media,
      }),
      outPath: out.path,
      mediaRootPath: mediaRoot?.path,
      mediaNames: names,
    );
  } finally {
    try {
      await staging.delete(recursive: true);
    } on FileSystemException {
      // 句柄滞后（Windows）：留给系统清理临时目录。
    }
  }
}

/// 单独一个函数作用域：交给 [Isolate.run] 的闭包只捕获这里的纯数据参数，捕获不到调用方的 [SrsDbStore]。
Future<SrsFushiSrsExport> _runWriteFushiSrs({
  required String opsPath,
  required String manifestJson,
  required String outPath,
  required String? mediaRootPath,
  required List<String> mediaNames,
}) => Isolate.run(
  () =>
      _writeFushiSrs(opsPath, manifestJson, outPath, mediaRootPath, mediaNames),
  debugName: 'srs-fushisrs-export',
);

/// 组 zip：清单、`ops.bin`（不压缩，从内核写的文件流式拷进去）、媒体（逐个文件流式拷）。先写同目录临时文件再改名。
Future<SrsFushiSrsExport> _writeFushiSrs(
  String opsPath,
  String manifestJson,
  String outPath,
  String? mediaRootPath,
  List<String> mediaNames,
) async {
  final File out = File(outPath);
  await out.parent.create(recursive: true);
  final String tmp = '$outPath.tmp';
  final ZipFileEncoder zip = ZipFileEncoder()..create(tmp);
  int media = 0;
  try {
    zip.addArchiveFile(ArchiveFile.string('manifest.json', manifestJson));
    await zip.addFile(File(opsPath), 'ops.bin', ZipFileEncoder.STORE);
    if (mediaRootPath != null) {
      for (final String name in mediaNames) {
        final File f = File(p.join(mediaRootPath, name));
        if (!f.existsSync()) continue;
        await zip.addFile(f, 'media/$name');
        media++;
      }
    }
  } finally {
    await zip.close();
  }
  final File done = await File(tmp).rename(outPath);
  return SrsFushiSrsExport(bytes: await done.length(), mediaFiles: media);
}

/// 导入 [file]：操作并入、媒体补缺。不是 `.fushisrs`、另一个 profile 的第 1 版 / 旧事件备份、来自更新版本、坏文件抛
/// [FormatException]；文件来自另一个复习库，或同一个复习库的文件带来新的旧 profile 标识 / 设备公钥时问 [confirmForeign]
/// （原因见 [SrsFushiSrsForeign.reason]；没给或答否 = 不导入，[SrsFushiSrsImport.declined]）。
Future<SrsFushiSrsImport> srsImportFushiSrs(
  SrsDbStore store,
  File file, {
  Directory? mediaRoot,
  Future<bool> Function(SrsFushiSrsForeign foreign)? confirmForeign,
}) async {
  final Directory staging = await Directory.systemTemp.createTemp(
    'fushi_srs_import_',
  );
  try {
    final String opsPath = p.join(staging.path, 'ops.bin');
    final _FushiSrsRead read = await _runReadFushiSrs(
      path: file.path,
      opsPath: opsPath,
    );
    final _KernelLanding land;
    switch (read) {
      case _OpsRead(:final Map<String, Object?>? manifest):
        land = ({required bool confirmed, bool preflight = false}) =>
            _kernelImport(
              store,
              opsPath,
              manifest,
              confirmed: confirmed,
              preflight: preflight,
            );
      case _LegacyEventsRead(:final String profileUid):
        // 与协议 3 时代一样只认本 profile 的旧备份（D34：另一个复习库的旧输入继续拒收）。
        if (profileUid != store.profileUid) {
          throw const FormatException(
            'this .fushisrs belongs to another profile',
          );
        }
        final Directory scratch = Directory(p.join(staging.path, 'scratch'));
        await scratch.create();
        land = ({required bool confirmed, bool preflight = false}) =>
            _kernelLegacyImport(
              store,
              opsPath,
              scratch.path,
              profileUid,
              confirmed: confirmed,
              preflight: preflight,
            );
    }
    // 先预检（内核什么都不写）：要确认就先问，用户答否 = 本机一点没动（不打还原点、不写媒体）。
    final Map<String, Object?> pre = await land(
      confirmed: false,
      preflight: true,
    );
    bool confirmed = false;
    if (pre['outcome'] == 'needsConfirm') {
      final SrsFushiSrsForeign foreign = SrsFushiSrsForeign.fromReply(pre);
      if (confirmForeign == null || !await confirmForeign(foreign)) {
        return const SrsFushiSrsImport(
          applied: 0,
          mediaFiles: 0,
          declined: true,
        );
      }
      confirmed = true;
    }
    await store.sync2Checkpoint(p.basename(file.path), 'import');
    // 媒体先于引用它的操作落地（与上传纪律一致）；内核随后拒收就删掉这次补进来的，不留孤儿文件。
    final List<String> added = mediaRoot == null
        ? const <String>[]
        : await _runCopyFushiSrsMedia(
            path: file.path,
            mediaRootPath: mediaRoot.path,
            legacy: read is _LegacyEventsRead,
          );
    final Map<String, Object?> r;
    try {
      r = await land(confirmed: confirmed);
      if (r['outcome'] == 'needsConfirm') {
        // 预检之后别的调用改了这个 profile 的绑定：不按旧的确认结论并入，交给用户重来。
        throw StateError(
          'the profile binding changed while importing; import again',
        );
      }
    } on Object {
      if (mediaRoot != null) await _dropAddedMedia(mediaRoot, added);
      rethrow;
    }
    return SrsFushiSrsImport(
      applied: (r['applied'] as int?) ?? 0,
      mediaFiles: added.length,
    );
  } finally {
    try {
      await staging.delete(recursive: true);
    } on FileSystemException {
      // 句柄滞后（Windows）：留给系统清理临时目录。
    }
  }
}

/// 发一次内核落库（[preflight] = 只预检）。
typedef _KernelLanding =
    Future<Map<String, Object?>> Function({
      required bool confirmed,
      bool preflight,
    });

/// 读包的结果（纯数据，跨 isolate 传）。
sealed class _FushiSrsRead {
  const _FushiSrsRead();
}

/// 第 1 / 2 版：`ops.bin` 已拷进临时文件；[manifest] 是第 2 版清单里归内核的几项（第 1 版为 null）。
final class _OpsRead extends _FushiSrsRead {
  const _OpsRead(this.manifest);

  final Map<String, Object?>? manifest;
}

/// v2 同步之前的事件备份：事件已写成 JSONL（同一个临时文件路径）；[profileUid] 是清单里的 profile。
final class _LegacyEventsRead extends _FushiSrsRead {
  const _LegacyEventsRead(this.profileUid);

  final String profileUid;
}

/// 删掉这次导入补进 [mediaRoot] 的媒体 [added]（内核拒收之后；本机原有的文件不在 [added] 里，不会被碰）。
Future<void> _dropAddedMedia(Directory mediaRoot, List<String> added) async {
  for (final String name in added) {
    final File f = File(p.join(mediaRoot.path, name));
    if (await f.exists()) await f.delete();
  }
}

/// 发内核导入（[preflight] = 只预检、什么都不写）；内核拒收（另一个集合 / 坏流）的错误换成 [FormatException]，界面按它
/// 给提示。
Future<Map<String, Object?>> _kernelImport(
  SrsDbStore store,
  String opsPath,
  Map<String, Object?>? manifest, {
  required bool confirmed,
  bool preflight = false,
}) async {
  try {
    if (preflight) {
      return await store.sync2ImportPreflight(
        path: opsPath,
        manifest: manifest,
      );
    }
    return await store.sync2ImportOps(
      path: opsPath,
      manifest: manifest,
      confirmed: confirmed,
    );
  } on Object catch (e) {
    final Object mapped = srsFushiSrsKernelError(e);
    if (identical(mapped, e)) rethrow;
    throw mapped;
  }
}

/// 内核导入（第 2 版流）拒收的错误 [e] 换成界面认得的 [FormatException]：另一个集合 → `another profile`；别的坏流 →
/// `corrupt .fushisrs`。一条改动超过载荷上限的已在 FFI 边界类型化成 [SrsOpTooLargeException]（文件没坏，是那一条太大），
/// 与认不出的一样原样交回（调用方 rethrow），导入页按类型给专门的提示。
Object srsFushiSrsKernelError(Object e) {
  if (e is SrsOpTooLargeException) return e;
  final String m = e.toString();
  if (m.contains('belongs to another collection')) {
    return const FormatException('this .fushisrs belongs to another profile');
  }
  if (m.contains('gen4 import:')) {
    return FormatException('corrupt .fushisrs: $m');
  }
  return e;
}

/// 发内核旧事件备份读入（[SrsDbStore.sync2LegacyEventsImport]）；坏事件 / 副本备不好的错误换成 [FormatException]。
Future<Map<String, Object?>> _kernelLegacyImport(
  SrsDbStore store,
  String jsonlPath,
  String scratch,
  String backupProfile, {
  required bool confirmed,
  bool preflight = false,
}) async {
  try {
    return await store.sync2LegacyEventsImport(
      path: jsonlPath,
      scratch: scratch,
      backupProfile: backupProfile,
      confirmed: confirmed,
      preflight: preflight,
    );
  } on Object catch (e) {
    final String m = e.toString();
    if (m.contains('belongs to another collection')) {
      throw const FormatException('this .fushisrs belongs to another profile');
    }
    if (m.contains('legacy_backup_import:') ||
        m.contains('gen4 legacy backup import')) {
      throw FormatException('corrupt legacy .fushisrs backup: $m');
    }
    rethrow;
  }
}

/// 同 [_runWriteFushiSrs]：闭包只捕获纯数据参数。回读包结果（[_FushiSrsRead]），纯数据。
Future<_FushiSrsRead> _runReadFushiSrs({
  required String path,
  required String opsPath,
}) => Isolate.run(
  () => _readFushiSrs(path, opsPath),
  debugName: 'srs-fushisrs-import',
);

/// 同上：把包里本机缺的媒体写进 [mediaRootPath]，回补进来的文件名（内核随后拒收时据此删掉）。
Future<List<String>> _runCopyFushiSrsMedia({
  required String path,
  required String mediaRootPath,
  bool legacy = false,
}) => Isolate.run(
  () => legacy
      ? _copyLegacyMedia(path, mediaRootPath)
      : _copyFushiSrsMedia(path, mediaRootPath),
  debugName: 'srs-fushisrs-import-media',
);

FormatException _invalid() => const FormatException('not a .fushisrs file');

/// 在后台 isolate 跑：读清单、校验版本，把 `ops.bin` 拷进 [opsPath]（不压缩存放的条目按文件流式拷，不整份进内存）。
/// **不碰媒体目录**：媒体等内核预检通过、用户确认之后才由 [_copyFushiSrsMedia] 写（复核：用户拒绝后不留孤儿文件）。
/// 任何校验失败抛 [FormatException]（[Isolate.run] 原样转抛给调用方），此时本机什么都没被碰过。
Future<_FushiSrsRead> _readFushiSrs(String path, String opsPath) async {
  final InputFileStream input;
  try {
    input = InputFileStream(path);
  } on Object {
    throw _invalid();
  }
  try {
    final ZipDecoder decoder = ZipDecoder();
    final Archive zip;
    try {
      zip = decoder.decodeBuffer(input);
    } on Object {
      throw _invalid();
    }
    final ArchiveFile? manifest = zip.findFile('manifest.json');
    if (manifest == null || manifest.size > _kMaxManifestBytes) {
      throw _invalid();
    }
    final Object? m;
    try {
      m = jsonDecode(utf8.decode(manifest.content as List<int>));
    } on FormatException {
      throw _invalid();
    }
    if (m is! Map) throw _invalid();
    if (m['magic'] == kSrsLegacyBackupMagic) {
      return _readLegacy(decoder, zip, m.cast<String, Object?>(), opsPath);
    }
    final Object? v = m['v'];
    if (v is! int || v < 1) throw _invalid();
    if (v > kSrsFushiSrsVersion ||
        (v == kSrsFushiSrsVersion && m['gen'] != kSrsFushiSrsGen)) {
      throw const FormatException('unsupported .fushisrs version');
    }
    final ZipFile? ops = _entry(decoder, 'ops.bin');
    if (ops == null) throw _invalid();
    final OutputFileStream out = OutputFileStream(opsPath);
    try {
      final InputStreamBase? raw = ops.rawContent;
      if (ops.compressionMethod == ZipFile.zipCompressionStore && raw != null) {
        out.writeInputStream(raw);
      } else {
        // 第 1 版的包把 `ops.bin` 压过一道（deflate）：解压只能整份进内存，第 1 版只会越来越少。
        out.writeBytes(ops.content);
      }
    } finally {
      out.closeSync();
    }
    return _OpsRead(
      v == kSrsFushiSrsVersion
          ? <String, Object?>{
              'collection': m['collection'],
              'dir': m['dir'],
              'salts': m['salts'],
              'peers': m['peers'],
            }
          : null,
    );
  } finally {
    input.closeSync();
  }
}

/// 在后台 isolate 跑：把包 [path] 里本机缺的媒体写进 [mediaRootPath]（已有的不覆盖），回补进来的文件名。包已经由
/// [_readFushiSrs] 校验过。
Future<List<String>> _copyFushiSrsMedia(
  String path,
  String mediaRootPath,
) async {
  final InputFileStream input = InputFileStream(path);
  final List<String> added = <String>[];
  try {
    final Archive zip = ZipDecoder().decodeBuffer(input);
    final Directory mediaRoot = Directory(mediaRootPath);
    for (final ArchiveFile f in zip.files) {
      if (!f.isFile || !f.name.startsWith('media/')) continue;
      final String name = f.name.substring('media/'.length);
      if (!srsIsBareMediaName(name)) continue;
      final File local = File(p.join(mediaRoot.path, name));
      if (local.existsSync()) continue;
      await mediaRoot.create(recursive: true);
      final File tmp = File('${local.path}.import.tmp');
      await tmp.writeAsBytes(f.content as List<int>, flush: true);
      await tmp.rename(local.path);
      added.add(name);
    }
  } finally {
    input.closeSync();
  }
  return added;
}

FormatException _corruptLegacy(String detail) =>
    FormatException('corrupt legacy .fushisrs backup: $detail');

/// 旧格式条目正文（超过 [max] 当坏包）。
List<int> _legacyContent(ArchiveFile f, int max, String what) {
  if (f.size > max) throw _corruptLegacy('$what too large');
  final Object? c = f.content;
  if (c is List<int>) return c;
  throw _corruptLegacy(what);
}

/// 在后台 isolate 跑：校验旧事件备份（`minReaderVersion`、`events.jsonl` 的 SHA-256 与条数），把事件写成内核
/// `legacy_backup_import`（`source: "events"`）读的 JSONL 到 [jsonlPath]：每行 `{e, stamped: true, server?}`（事件原样，
/// `server` 取 `server_times.json`）。日志不带笔记 ID：内核在临时协议 3 库里按派生出的卡片补（与协议 3 `applyRemote`
/// 同口径）。不碰媒体目录。
///
/// `events.jsonl` 按块流式读（[_streamLegacyEvents]）：解压、算 SHA-256、按行解码一遍走完，峰值内存与正文大小无关；
/// 摘要要等读完才知道，所以先写 JSONL、最后核对，不符时删掉写了一半的文件再抛。
_LegacyEventsRead _readLegacy(
  ZipDecoder decoder,
  Archive zip,
  Map<String, Object?> manifest,
  String jsonlPath,
) {
  final Object? minReader = manifest['minReaderVersion'];
  if (minReader is! int || minReader > _kLegacyReaderVersion) {
    throw const FormatException('unsupported .fushisrs version');
  }
  final Object? profileUid = manifest['profileUid'];
  if (profileUid is! String || profileUid.isEmpty) {
    throw _corruptLegacy('manifest profile');
  }
  final Object? ev = manifest['events'];
  if (ev is! Map || ev['sha256'] is! String || ev['count'] is! int) {
    throw _corruptLegacy('manifest events');
  }
  final ZipFile? eventsFile = _entry(decoder, 'events.jsonl');
  if (eventsFile == null) throw _corruptLegacy('events missing');
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
      throw _corruptLegacy('server times');
    }
    if (j is Map) {
      for (final MapEntry<Object?, Object?> e in j.entries) {
        if (e.key is String && e.value is int) {
          serverTimes[e.key! as String] = e.value! as int;
        }
      }
    }
  }
  final File jsonl = File(jsonlPath);
  final RandomAccessFile out = jsonl.openSync(mode: FileMode.write);
  int n = 0;
  final String digest;
  try {
    digest = _streamLegacyEvents(eventsFile, (String line) {
      if (line.isEmpty) return;
      final Object? e;
      try {
        e = jsonDecode(line);
      } on FormatException {
        throw _corruptLegacy('event line ${n + 1}');
      }
      if (e is! Map) throw _corruptLegacy('event line ${n + 1}');
      final Object? x = e['x'];
      final Object? id = x is Map ? x['id'] : null;
      final int? server = id is String ? serverTimes[id] : null;
      final Map<String, Object?> item = <String, Object?>{
        'e': e,
        'stamped': true,
        'server': ?server,
      };
      out.writeStringSync('${jsonEncode(item)}\n');
      n++;
    });
  } on Object {
    out.closeSync();
    jsonl.deleteSync();
    rethrow;
  }
  // 后台 isolate 里同步写完、关文件，内核随后按文件读（旧格式只会越来越少，不为它做异步流水线）。
  out.closeSync();
  if (digest != ev['sha256'] || n != ev['count']) {
    jsonl.deleteSync();
    throw _corruptLegacy(
      digest != ev['sha256']
          ? 'events sha256 mismatch'
          : 'event count mismatch',
    );
  }
  return _LegacyEventsRead(profileUid);
}

/// 旧事件备份 `events.jsonl` 条目的块大小（压缩后的读窗口）。
const int _kLegacyEventsChunk = 1 << 16;

/// 按块读 zip 条目 [f]（只认不加密的存放 / deflate）：解压后的字节一边算 SHA-256、一边按 UTF-8 解码切行交给 [onLine]，
/// 回正文的 SHA-256（小写十六进制）。解压后超过 [_kLegacyMaxEventsBytes] 当坏包（声明的大小与实际都查：外部文件不可信）。
String _streamLegacyEvents(ZipFile f, void Function(String line) onLine) {
  final int? declared = f.uncompressedSize;
  if (declared != null && declared > _kLegacyMaxEventsBytes) {
    throw _corruptLegacy('events too large');
  }
  final InputStreamBase? raw = f.rawContent;
  final bool stored = f.compressionMethod == ZipFile.zipCompressionStore;
  if (raw == null ||
      (f.flags & 0x1) != 0 ||
      !(stored || f.compressionMethod == ZipFile.zipCompressionDeflate)) {
    throw _corruptLegacy('events entry');
  }
  final _DigestCapture captured = _DigestCapture();
  final ByteConversionSink hash = sha256.startChunkedConversion(captured);
  final ByteConversionSink text = const Utf8Decoder().startChunkedConversion(
    const LineSplitter().startChunkedConversion(_LineSink(onLine)),
  );
  final _EventBytesSink plain = _EventBytesSink(hash, text);
  final Sink<List<int>> input = stored
      ? plain
      : ZLibDecoder(raw: true).startChunkedConversion(plain);
  try {
    while (!raw.isEOS) {
      final int take = raw.length < _kLegacyEventsChunk
          ? raw.length
          : _kLegacyEventsChunk;
      input.add(raw.readBytes(take).toUint8List());
    }
    input.close();
  } on FormatException {
    rethrow;
  } on Object {
    throw _corruptLegacy('events');
  }
  return captured.value!.toString();
}

/// 解压后的正文：计数（上限）、送进摘要与按行解码。
final class _EventBytesSink implements Sink<List<int>> {
  _EventBytesSink(this._hash, this._text);

  final ByteConversionSink _hash;
  final ByteConversionSink _text;
  int _total = 0;

  @override
  void add(List<int> chunk) {
    _total += chunk.length;
    if (_total > _kLegacyMaxEventsBytes) {
      throw _corruptLegacy('events too large');
    }
    _hash.add(chunk);
    _text.add(chunk);
  }

  @override
  void close() {
    _hash.close();
    _text.close();
  }
}

/// 切好的每一行交给回调。
final class _LineSink implements Sink<String> {
  _LineSink(this._onLine);

  final void Function(String line) _onLine;

  @override
  void add(String line) => _onLine(line);

  @override
  void close() {}
}

/// 接 [sha256] 分块计算的结果。
final class _DigestCapture implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest d) => value = d;

  @override
  void close() {}
}

/// 在后台 isolate 跑：旧事件备份的媒体（清单 `media: [{name, sha256}]`）补进 [mediaRootPath]（已有的不覆盖）：先取文件
/// 内嵌的 `media/<sha256>`，再到旧备份根的共享池（`<备份根>/<profileUid>/<文件>` 布局下的 `<备份根>/media/`）找；一律按
/// SHA-256 校验，对不上当没有。回补进来的文件名。
Future<List<String>> _copyLegacyMedia(String path, String mediaRootPath) async {
  final InputFileStream input = InputFileStream(path);
  final List<String> added = <String>[];
  try {
    final Archive zip = ZipDecoder().decodeBuffer(input);
    final ArchiveFile? mf = zip.findFile('manifest.json');
    if (mf == null) return added;
    final Object? m = jsonDecode(utf8.decode(mf.content as List<int>));
    if (m is! Map) return added;
    final Directory pool = Directory(
      p.join(p.dirname(p.dirname(path)), 'media'),
    );
    final Directory mediaRoot = Directory(mediaRootPath);
    for (final Object? raw in (m['media'] as List?) ?? const <Object?>[]) {
      if (raw is! Map) continue;
      final Object? name = raw['name'];
      final Object? sha = raw['sha256'];
      if (name is! String || sha is! String) continue;
      if (!srsIsBareMediaName(name) || !_sha256Re.hasMatch(sha)) continue;
      final File local = File(p.join(mediaRoot.path, name));
      if (local.existsSync()) continue;
      final List<int>? bytes = _legacyMediaBytes(zip, sha, pool);
      if (bytes == null) continue;
      await mediaRoot.create(recursive: true);
      final File tmp = File('${local.path}.import.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(local.path);
      added.add(name);
    }
  } finally {
    input.closeSync();
  }
  return added;
}

/// 旧格式媒体正文（[_copyLegacyMedia]）。
List<int>? _legacyMediaBytes(Archive zip, String sha, Directory pool) {
  final ArchiveFile? embedded = zip.findFile('media/$sha');
  if (embedded != null && embedded.size <= _kLegacyMaxMediaBytes) {
    final Object? c = embedded.content;
    if (c is List<int> && sha256.convert(c).toString() == sha) return c;
  }
  final File f = File(p.join(pool.path, sha));
  if (!f.existsSync() || f.lengthSync() > _kLegacyMaxMediaBytes) return null;
  final List<int> b = f.readAsBytesSync();
  return sha256.convert(b).toString() == sha ? b : null;
}

/// zip 目录里名为 [name] 的条目（取 [ZipFile] 才拿得到不解压的原始字节流）。
ZipFile? _entry(ZipDecoder decoder, String name) {
  for (final ZipFileHeader h in decoder.directory.fileHeaders) {
    if (h.filename == name) return h.file;
  }
  return null;
}
