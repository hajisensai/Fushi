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
/// 导入 = 操作**并入**（不覆盖任何一方），媒体只补本机缺的。文件来自另一个复习库（另一个集合）时内核先回「需确认」、
/// 什么都不写；调用方确认（[srsImportFushiSrs] 的 `confirmForeign`）后两个库并成一个再导入。包里本机身份的日志与本机分叉
/// 了（拷过数据目录）时内核先换身份。
///
/// **旧格式**：
///
/// - 第 1 版（`v: 1`，协议 3 的 `FSRS2EXP` 操作流）：同样交给内核，内核用冻结的读入器转译导入；另一个 profile 的拒收。
/// - v2 同步之前的事件备份（清单魔数 [kSrsLegacyBackupMagic]）：新代内核已不收「带来源身份的外来事件」，冻结侧的转换器
///   还没有（交接说明 G11-3 一节），明确拒绝（[SrsFushiSrsLegacyFormat]）并提示先在 3.x 版本里导入、升级后随库迁移。
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

import 'package:archive/archive_io.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:path/path.dart' as p;

const String kSrsFushiSrsExtension = 'fushisrs';

/// 本版本写的格式版本（第 2 版 = 协议 4）。
const int kSrsFushiSrsVersion = 2;

/// 第 2 版清单的代号（协议 4）。
const int kSrsFushiSrsGen = 4;

/// 旧格式备份清单的魔数（develop f71b5aaa98 `srs_backup_store.dart` 的 `kSrsBackupMagic`，冻结）：认出来只为明确拒绝。
const String kSrsLegacyBackupMagic = 'fushi-srs-backup';

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

/// 文件来自另一个复习库（另一个集合）：导入会把两个库并成一个，要用户确认。
class SrsFushiSrsForeign {
  const SrsFushiSrsForeign({required this.collection, required this.dir});

  final String collection;
  final String dir;
}

/// v2 同步之前的事件备份：这一版不能导入（见文件头）。
class SrsFushiSrsLegacyFormat extends FormatException {
  const SrsFushiSrsLegacyFormat()
    : super(
        'legacy .fushisrs backup (before sync v2) can no longer be imported; '
        'import it with Fushi 3.x first',
      );
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

/// 导入 [file]：操作并入、媒体补缺。不是 `.fushisrs`、另一个 profile 的第 1 版、来自更新版本、坏文件抛
/// [FormatException]（v2 同步之前的事件备份抛它的子类 [SrsFushiSrsLegacyFormat]）；文件来自另一个复习库时问
/// [confirmForeign]（没给或答否 = 不导入，[SrsFushiSrsImport.declined]）。
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
    final _ParsedFushiSrs parsed = await _runReadFushiSrs(
      path: file.path,
      opsPath: opsPath,
      mediaRootPath: mediaRoot?.path,
    );
    await store.sync2Checkpoint(p.basename(file.path), 'import');
    Map<String, Object?> r = await _kernelImport(
      store,
      opsPath,
      parsed.manifest,
      confirmed: false,
    );
    if (r['outcome'] == 'needsConfirm') {
      final SrsFushiSrsForeign foreign = SrsFushiSrsForeign(
        collection: r['collection']! as String,
        dir: r['dir']! as String,
      );
      if (confirmForeign == null || !await confirmForeign(foreign)) {
        return SrsFushiSrsImport(
          applied: 0,
          mediaFiles: parsed.mediaFiles,
          declined: true,
        );
      }
      r = await _kernelImport(store, opsPath, parsed.manifest, confirmed: true);
    }
    return SrsFushiSrsImport(
      applied: (r['applied'] as int?) ?? 0,
      mediaFiles: parsed.mediaFiles,
    );
  } finally {
    try {
      await staging.delete(recursive: true);
    } on FileSystemException {
      // 句柄滞后（Windows）：留给系统清理临时目录。
    }
  }
}

/// 发内核导入；内核拒收（另一个集合 / 坏流）的错误换成 [FormatException]，界面按它给提示。
Future<Map<String, Object?>> _kernelImport(
  SrsDbStore store,
  String opsPath,
  Map<String, Object?>? manifest, {
  required bool confirmed,
}) async {
  try {
    return await store.sync2ImportOps(
      path: opsPath,
      manifest: manifest,
      confirmed: confirmed,
    );
  } on Object catch (e) {
    final String m = e.toString();
    if (m.contains('belongs to another collection')) {
      throw const FormatException('this .fushisrs belongs to another profile');
    }
    if (m.contains('gen4 import:')) {
      throw FormatException('corrupt .fushisrs: $m');
    }
    rethrow;
  }
}

/// 后台 isolate 读包的结果：交给内核的清单（第 2 版；第 1 版为 null）+ 已补进本机的媒体数。只含可跨 isolate 传递的纯数据。
final class _ParsedFushiSrs {
  const _ParsedFushiSrs(this.manifest, this.mediaFiles);

  final Map<String, Object?>? manifest;
  final int mediaFiles;
}

/// 同 [_runWriteFushiSrs]：闭包只捕获纯数据参数。
Future<_ParsedFushiSrs> _runReadFushiSrs({
  required String path,
  required String opsPath,
  required String? mediaRootPath,
}) => Isolate.run(
  () => _readFushiSrs(path, opsPath, mediaRootPath),
  debugName: 'srs-fushisrs-import',
);

FormatException _invalid() => const FormatException('not a .fushisrs file');

/// 在后台 isolate 跑：读清单、校验版本，把 `ops.bin` 拷进 [opsPath]（不压缩存放的条目按文件流式拷，不整份进内存），
/// 再把包里本机缺的媒体写进 [mediaRootPath]（媒体先于引用它的操作落地，与上传纪律一致）。任何校验失败抛
/// [FormatException]（[Isolate.run] 原样转抛给调用方），此时库没被碰过。
Future<_ParsedFushiSrs> _readFushiSrs(
  String path,
  String opsPath,
  String? mediaRootPath,
) async {
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
      throw const SrsFushiSrsLegacyFormat();
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
    int media = 0;
    if (mediaRootPath != null) {
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
        media++;
      }
    }
    return _ParsedFushiSrs(
      v == kSrsFushiSrsVersion
          ? <String, Object?>{
              'collection': m['collection'],
              'dir': m['dir'],
              'salts': m['salts'],
              'peers': m['peers'],
            }
          : null,
      media,
    );
  } finally {
    input.closeSync();
  }
}

/// zip 目录里名为 [name] 的条目（取 [ZipFile] 才拿得到不解压的原始字节流）。
ZipFile? _entry(ZipDecoder decoder, String name) {
  for (final ZipFileHeader h in decoder.directory.fileHeaders) {
    if (h.filename == name) return h.file;
  }
  return null;
}
