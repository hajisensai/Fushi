/// 手动导出 / 导入 `.fushisrs`（docs/specs/2026-10-25-srs-sync-v2-design.md §10.4）：离线保存，或完全不连同步
/// 时搬到新设备。只有手动导出，不定时（归档位置已覆盖定期备份的需求）。
///
/// 包是一个 zip：`ops.bin`（内核导出的全部操作 + 各设备公钥，见 store/sync2/transport.rs `sync2_export`）、
/// `manifest.json`（格式版本、profile、导出时刻、带不带媒体）、可选的 `media/<文件名>`（媒体默认带上）。
/// 导入 = 操作**并入**（不覆盖任何一方），媒体只补本机缺的；包里有本机身份的操作时内核先换身份（§7.3）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
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
  final Archive zip = Archive();
  zip.addFile(
    ArchiveFile.string(
      'manifest.json',
      jsonEncode(<String, Object?>{
        'v': kSrsFushiSrsVersion,
        'profile': store.profileUid,
        'exportedAt': store.now().$1,
        'media': withMedia && mediaRoot != null,
      }),
    ),
  );
  zip.addFile(ArchiveFile('ops.bin', ops.length, ops));
  int media = 0;
  if (withMedia && mediaRoot != null) {
    for (final String name in await srsReferencedMedia(store)) {
      final File f = File(p.join(mediaRoot.path, name));
      if (!f.existsSync()) continue;
      final Uint8List b = await f.readAsBytes();
      zip.addFile(ArchiveFile('media/$name', b.length, b));
      media++;
    }
  }
  final List<int> bytes = ZipEncoder().encode(zip)!;
  await out.parent.create(recursive: true);
  final File tmp = File('${out.path}.tmp');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(out.path);
  return SrsFushiSrsExport(bytes: bytes.length, mediaFiles: media);
}

/// 导入 [file]：操作并入、媒体补缺。不是本 profile 的包抛 [FormatException]。
Future<SrsFushiSrsImport> srsImportFushiSrs(
  SrsDbStore store,
  File file, {
  Directory? mediaRoot,
}) async {
  final Archive zip = ZipDecoder().decodeBytes(await file.readAsBytes());
  final ArchiveFile? manifest = zip.findFile('manifest.json');
  final ArchiveFile? ops = zip.findFile('ops.bin');
  if (manifest == null || ops == null) {
    throw const FormatException('not a .fushisrs file');
  }
  final Object? m = jsonDecode(utf8.decode(manifest.content as List<int>));
  if (m is! Map || ((m['v'] as int?) ?? 0) > kSrsFushiSrsVersion) {
    throw const FormatException('unsupported .fushisrs version');
  }
  if (m['profile'] != store.profileUid) {
    throw const FormatException('this .fushisrs belongs to another profile');
  }
  // 先补媒体（媒体先于引用它的操作落地，与上传纪律一致）。
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
  final int applied = await store.sync2ImportOps(
    Uint8List.fromList(ops.content as List<int>),
  );
  return SrsFushiSrsImport(applied: applied, mediaFiles: media);
}
