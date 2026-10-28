/// SRS 媒体同步（docs/specs/2026-10-25-srs-sync-v2-design.md §6.4、§6.5、§10.5）。
///
/// 媒体内容寻址、不可变、只增：文件名就是内容哈希（制卡 / 导入时按内容命名），所以集合根下一个共用目录
/// `media/<文件名>` 就是内容寻址存储，不再按写入者分目录。每轮（操作同步之后）：
/// 1. 收集本 profile 全部存活笔记（含删除未满保留期的）与笔记类型引用的媒体文件名；
/// 2. 本机缺、位置上有 → 下载；位置上没有、本机有 → 上传（位置之间互为镜像，缺的从别处补）；
/// 3. 只被「删除已满 [kSrsMediaRetention]」的笔记引用、且不被任何存活引用的位置上的文件 → 删（要正面证据：
///    本机不认识的文件不删）。别的设备若还看不到那次删除，会把它再传上来，不丢。**归档位置永不删**。
///
/// 旧格式（`fushi-srs/<profileUid>/<写入者>/media/`）里已经传上去的文件只读兜底：v2 目录里没有、旧目录有的
/// 照样能下载，之后由持有它的设备补传进 v2 目录。旧目录不自动删（设计 P7：用户在位置管理里手动清理）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/srs/apkg/srs_apkg_common.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

/// 集合根下的媒体目录。
const String kSrsMediaFolder = 'media';

/// 被删笔记的媒体在同步 / 媒体位置上的保留期（设计 §10.5；本机媒体回收同一口径，见 srs_purge.dart）。
const Duration kSrsMediaRetention = Duration(days: 90);

/// 一轮媒体同步的结果。
class SrsMediaSyncReport {
  int uploaded = 0;
  int downloaded = 0;

  /// 从位置上删掉的过期 / 无引用文件数。
  int deleted = 0;

  /// 引用了但位置与本机都没有的文件（等持有它的设备上线）。
  final Set<String> missing = <String>{};
}

/// 本 profile 全部未删除笔记（含模板正文里下划线开头的静态文件）引用的媒体文件名。
///
/// 笔记字段的引用读笔记缓存的 `media_refs` 列（[SrsDbStore.noteMediaRefs]）：它随笔记缓存同一次刷新算出，
/// 每轮媒体同步不逐页读全部修改记录解析字段。[deletedAfterMs] 给出时，删除晚于它的已删笔记也算。
Future<Set<String>> srsReferencedMedia(
  SrsDbStore store, {
  int? deletedAfterMs,
}) async {
  final Set<String> out = await store.noteMediaRefs(
    deletedAfterMs: deletedAfterMs,
  );
  for (final SrsNoteTypeView t in await store.noteTypes()) {
    for (final SrsTemplateDef tpl in t.templates) {
      out.addAll(srsMediaRefsIn(tpl.front, includeStatic: true));
      out.addAll(srsMediaRefsIn(tpl.back, includeStatic: true));
    }
    out.addAll(srsMediaRefsIn(t.css, includeStatic: true));
  }
  return out.where(srsIsBareMediaName).toSet();
}

/// 媒体回收 / 位置清理用的「存活引用」：存活笔记、删除未满 [retention] 的笔记、全部笔记类型（含已删除的）的
/// 模板与 CSS。比 [srsReferencedMedia] 多算已删除的笔记类型（可能被恢复）。
Future<Set<String>> srsLiveMediaReferences(
  SrsDbStore store, {
  Duration retention = kSrsMediaRetention,
}) async {
  final int cutoff = store.now().$1 - retention.inMilliseconds;
  final Set<String> out = await store.noteMediaRefs(deletedAfterMs: cutoff);
  final Map<String, SrsNoteTypeView?> types = await store.noteTypesById(
    await store.entityIds(SrsEntityKind.noteType),
  );
  for (final SrsNoteTypeView? t in types.values) {
    if (t == null) continue;
    for (final SrsTemplateDef tpl in t.templates) {
      out.addAll(srsMediaRefsIn(tpl.front, includeStatic: true));
      out.addAll(srsMediaRefsIn(tpl.back, includeStatic: true));
    }
    out.addAll(srsMediaRefsIn(t.css, includeStatic: true));
  }
  return out.where(srsIsBareMediaName).toSet();
}

/// 只认裸文件名（不含路径分隔、不是 `.` / `..`）：媒体目录外的路径一律不碰。
bool srsIsBareMediaName(String n) =>
    n.isNotEmpty &&
    !n.contains('/') &&
    !n.contains(r'\') &&
    n != '.' &&
    n != '..';

/// 旧格式媒体的只读兜底：`fushi-srs/<profileUid>/<写入者>/media/<name>`。
typedef SrsLegacyMediaReader = Future<Uint8List?> Function(String name);

/// [SyncAssetStore] 上旧格式媒体目录的只读兜底（一轮里列一次目录）。
SrsLegacyMediaReader srsLegacyMediaReader(
  SyncAssetStore backend,
  String profileUid, {
  Directory? tempDir,
}) {
  Map<String, String>? index;
  return (String name) async {
    if (index == null) {
      index = <String, String>{};
      final String ns = await backend.ensureNamespace(kSrsSync2Namespace);
      final String profile = await backend.ensureFolder(ns, profileUid);
      for (final AssetEntry w in await backend.listChildren(profile)) {
        if (!w.isFolder || w.name == kSrsSync2Folder) continue;
        for (final AssetEntry m in await backend.listChildren(w.id)) {
          if (!m.isFolder || m.name != kSrsMediaFolder) continue;
          for (final AssetEntry f in await backend.listChildren(m.id)) {
            if (!f.isFolder) index!.putIfAbsent(f.name, () => f.id);
          }
        }
      }
    }
    final String? id = index![name];
    if (id == null) return null;
    final File tmp = File(
      p.join(
        (tempDir ?? Directory.systemTemp).path,
        'fushi_srs_media_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      await backend.getAsset(id, tmp);
      return await tmp.readAsBytes();
    } on Object {
      return null;
    } finally {
      if (tmp.existsSync()) await tmp.delete();
    }
  };
}

/// 跑一轮媒体同步。[mediaRoot] 是本 profile 的本机媒体目录；[archive] = 归档位置（只写不删）；[cipher] = 位置开了
/// 加密时的媒体封装（文件放 `media-e/`、内容是密文，见 srs_location_crypto.dart）。
Future<SrsMediaSyncReport> srsSyncMedia({
  required SrsLocationStore location,
  required SrsDbStore store,
  required Directory mediaRoot,
  bool archive = false,
  SrsLegacyMediaReader? legacy,
  SrsMediaCipher? cipher,
}) async {
  final SrsMediaSyncReport report = SrsMediaSyncReport();
  // 加密媒体按密钥指纹分目录（换了密钥 = 新目录，全部按新密钥重传）。
  final String folder = cipher == null ? kSrsMediaFolder : cipher.folder;
  Future<void> put(String name, Uint8List plain) async => location.put(
    '$folder/$name',
    cipher == null ? plain : await cipher.seal(name, plain),
  );
  Future<Uint8List?> get(String name) async {
    final Uint8List? b = await location.get('$folder/$name');
    if (b == null || cipher == null) return b;
    return cipher.open(name, b);
  }

  final Set<String> wanted = await srsReferencedMedia(
    store,
    deletedAfterMs: store.now().$1 - kSrsMediaRetention.inMilliseconds,
  );
  final Set<String> remote = <String>{
    for (final SrsLocationEntry e in await location.list(folder))
      if (!e.isFolder) e.name,
  };
  // 本机有哪些文件：异步列一次目录，不逐个 `existsSync`。两边都有的文件后面没有任何真正挂起的 IO，逐个同步 stat
  // 会让整轮在微任务里跑完、不回事件循环——上万个媒体时 UI isolate 几秒到几十秒收不到帧和触摸（BUG-3865）。
  final _SrsLocalMediaIndex localIndex = await _SrsLocalMediaIndex.scan(
    mediaRoot,
  );
  Future<void> syncOne(String name) async {
    final File local = File(p.join(mediaRoot.path, name));
    final bool haveLocal = await localIndex.has(local, name);
    final bool haveRemote = remote.contains(name);
    if (!haveLocal) {
      final Uint8List? bytes = haveRemote
          ? await get(name)
          : await legacy?.call(name);
      if (bytes == null) {
        report.missing.add(name);
        return;
      }
      await mediaRoot.create(recursive: true);
      final File tmp = File('${local.path}.download');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(local.path);
      localIndex.add(name);
      report.downloaded++;
      if (!haveRemote) {
        await put(name, bytes);
        report.uploaded++;
      }
    } else if (!haveRemote) {
      await put(name, await local.readAsBytes());
      report.uploaded++;
    }
  }

  // 媒体是内容寻址的独立文件，彼此无先后：同时最多 [kSrsSync2Concurrency] 个在途（首次同步一个牌组上千个
  // 图片 / 音频时，逐个等每个请求的固定延迟是主要耗时）。只差大小写的名字在不分大小写的文件系统上是同一个本机
  // 文件，归成一组在同一个任务里依次处理（与原先逐个处理时的结果相同）。
  final Map<String, List<String>> byFolded = <String, List<String>>{};
  for (final String name in wanted) {
    byFolded.putIfAbsent(name.toLowerCase(), () => <String>[]).add(name);
  }
  await srsRunPooled(byFolded.values.toList(), kSrsSync2Concurrency, (
    List<String> names,
  ) async {
    for (final String name in names) {
      await syncOne(name);
    }
  });
  if (!archive) {
    // 只删有正面证据的：被「删除已满保留期」的笔记引用、且不被任何存活引用。本机不认识的文件一律不删——
    // 它可能是别的设备新笔记的媒体，而本机还没收到那条笔记。
    final Set<String> live = <String>{
      for (final String n in await srsLiveMediaReferences(store))
        n.toLowerCase(),
    };
    final Set<String> expired = <String>{
      for (final String n in await store.expiredNoteMediaRefs(
        store.now().$1 - kSrsMediaRetention.inMilliseconds,
      ))
        n.toLowerCase(),
    };
    final List<String> doomed = <String>[
      for (final String name in remote)
        if (expired.contains(name.toLowerCase()) &&
            !live.contains(name.toLowerCase()))
          name,
    ];
    await srsRunPooled(doomed, kSrsSync2Concurrency, (String name) async {
      await location.delete('$folder/$name');
      report.deleted++;
    });
  }
  return report;
}

/// 本机媒体目录的一次性文件名索引（一轮媒体同步开头异步列一次目录）。
///
/// 名字原样命中就算有；只差大小写命中时（不分大小写的文件系统上可能是同一个文件，分大小写的上不是）对这一个文件
/// 异步 `exists()` 复核，与原先逐个 stat 的结果相同。
class _SrsLocalMediaIndex {
  _SrsLocalMediaIndex._(this._names, this._folded);

  final Set<String> _names;
  final Set<String> _folded;

  static Future<_SrsLocalMediaIndex> scan(Directory root) async {
    final Set<String> names = <String>{};
    if (await root.exists()) {
      await for (final FileSystemEntity e in root.list(followLinks: false)) {
        if (e is! Directory) names.add(p.basename(e.path));
      }
    }
    return _SrsLocalMediaIndex._(names, <String>{
      for (final String n in names) n.toLowerCase(),
    });
  }

  Future<bool> has(File local, String name) async {
    if (_names.contains(name)) return true;
    if (!_folded.contains(name.toLowerCase())) return false;
    return local.exists();
  }

  void add(String name) {
    _names.add(name);
    _folded.add(name.toLowerCase());
  }
}
