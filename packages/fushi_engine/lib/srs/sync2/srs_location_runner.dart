/// 一个同步位置上跑一轮复习同步 v2 / 一轮媒体同步的生产实现，app 与无头服务端共用。
///
/// 从 app 的 `srs_sync_scheduler.dart` 平移来：位置的后端身份 / 并发写上限是 app 的云盘细节（Dropbox 逐个写、
/// 防扫盘混淆包一层），由调用方经 [SrsLocationBackend] 传进来；本机设备信息怎么取（型号 / 版本）也由调用方给。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:path/path.dart' as p;

/// 同步数据来自更新版本的 Fushi（这一轮不同步该位置）。
const String kSrsSyncNeedsUpgrade = 'srs sync data needs a newer app';

/// 一个同步后端 + 它在 [SrsAssetLocationStore] 里的身份与并发写上限。
class SrsLocationBackend {
  const SrsLocationBackend(
    this.store, {
    this.maxConcurrentWrites,
    Object? identity,
  }) : _identity = identity;

  final SyncAssetStore store;

  /// 同时在途的写 / 删上限；null = 不限。
  final int? maxConcurrentWrites;

  final Object? _identity;

  /// 进程内建文件夹单飞按它认（包装后端传里层）；默认就是 [store] 本身。
  Object get identity => _identity ?? store;

  /// [store] 上 `fushi-srs/<dir>/<folder>/` 的位置实例（[dir] = 集合的位置目录名，[srsLocationDir]）。
  SrsAssetLocationStore location(
    String dir, {
    String folder = kSrsSync2Folder,
  }) => SrsAssetLocationStore(
    store: store,
    profileUid: dir,
    locationDir: dir,
    folder: folder,
    maxConcurrentWrites: maxConcurrentWrites,
    backendIdentity: identity,
  );
}

/// 这个 profile 的集合在同步位置上的目录名（`fushi-srs/<dir>/`）：内核 `identity` 回包的 `dir`（设计 §5.1），不再按
/// profile uid 拼——并入别的集合 / 采用对方集合之后两者不同。
Future<String> srsLocationDir(SrsDbStore store) async =>
    (await store.sync2Command(<String, Object?>{
          'op': 'identity',
          'now': store.now().$1,
        })).map['dir']!
        as String;

/// 现有同步后端上的集合目录（`fushi-srs/<dir>/`）跑一轮复习同步：新根 `v4/` 收发；旧根 `v3/` 的 `meta.json` 改写成让
/// 协议 3 的版本停下的围栏（内核 `location_root`，G8-7），旧根上的段收进本机承袭日志（旧根接手，G8-7b）。
/// [directoryKey] 就是这个位置的稳定身份（本机按它记每个位置传到了哪）。[publishDeviceInfo] = 本机型号 / 版本 / 平台
/// 随这一轮的 head 发布。
///
/// 只有协议 1 旧根 `v2/` 的位置内核明确拒绝（D21，`srs_location_protocol1_root`），不再一次性迁移（以前的
/// `srsPrepareLocation` 按协议 3 的命令写 `v3/`，会拆掉围栏）；v1 媒体搬家同样不跑，两者的装配已删（第五波）。
Future<SrsSync2Report> srsRunLocationRound(
  SrsLocationBackend backend,
  SrsDbStore store,
  String directoryKey, {
  SrsLocationKey? locationKey,
  Future<void> Function(SrsDbStore store)? publishDeviceInfo,
  void Function(int done, int total)? onFetchProgress,
  void Function()? onUploadStart,
  Future<void> Function(String? keyHex)? beforeUpload,
  bool Function()? shouldStop,
  SrsSyncStepCallback? onStep,
}) async {
  final String dir = await srsLocationDir(store);
  if (publishDeviceInfo != null) await publishDeviceInfo(store);
  bool rooted = false;
  final SrsSync2Report r = await srsSync2Round(
    host: store,
    location: backend.location(dir, folder: kSrs4Root),
    oldRoot: backend.location(dir),
    protocol1Root: backend.location(dir, folder: kSrsSync2V1Folder),
    locationId: directoryKey,
    nowMs: () => store.now().$1,
    bootClockMs: store.trustedClock.bootNowMs,
    key: locationKey,
    onFetchProgress: onFetchProgress,
    onUploadStart: onUploadStart,
    beforeUpload: beforeUpload,
    shouldStop: shouldStop,
    onStep: onStep,
    onLocationRoot: (SrsLocationRoot _) => rooted = true,
  );
  // 内核 `location_root` 认过这个位置的根（新根 `v4/` 在用、旧根围栏已立）才清 v3.0.x 写入者目录；没过（协议 1
  // 位置、需要更新、密钥不对、meta 读不到）一个不碰。
  if (rooted && !(shouldStop?.call() ?? false)) {
    onStep?.call('legacy_writers');
    await srsSweepLegacyWriters(backend.store, dir, r);
  }
  if (r.needsUpgrade) r.error = kSrsSyncNeedsUpgrade;
  return r;
}

/// v3.0.x 写入者目录名：`<设备>#<化身号>`（v3.0.x 旧事件同步与它的 profile 关联写在位置目录 `fushi-srs/<dir>/`
/// 下，协议 1 起的版本都只写 `v2/` / `v3/` / `v4/`）。
final RegExp _kSrsLegacyWriterDir = RegExp(r'^[^#/\\]+#[0-9]+$');

/// v3.0.x 写入者目录里旧事件同步（`batch-<序号>` / `snapshot-<序号>` / `cursor` / `probe`）与它的 profile 关联
/// （`profile.json`）写的文件。
final RegExp _kSrsLegacyWriterFile = RegExp(
  r'^(?:(?:batch|snapshot)-[0-9]+|cursor|probe|profile\.json)$',
);

/// v3.0.x 写入者目录里放媒体的子目录（协议 1 → 3 的迁移 v3.3.0 逐个文件搬进集合根、搬一个删一个）。
const String _kSrsLegacyWriterMedia = 'media';

/// 位置目录 `fushi-srs/<[dir]>/`（同名的几份都算）下的 v3.0.x 写入者目录；列失败记进 [errors]、交回已列到的。
Future<List<AssetEntry>> _srsLegacyWriters(
  SyncAssetStore store,
  String dir,
  List<String> errors,
) async {
  final List<AssetEntry> locations;
  try {
    final String ns = await store.ensureNamespace(kSrsSync2Namespace);
    locations = <AssetEntry>[
      for (final AssetEntry e in await store.listChildren(ns))
        if (e.isFolder && e.name == dir) e,
    ];
  } on Object catch (e) {
    errors.add('$dir: $e');
    return const <AssetEntry>[];
  }
  final List<AssetEntry> writers = <AssetEntry>[];
  for (final AssetEntry location in locations) {
    try {
      writers.addAll(<AssetEntry>[
        for (final AssetEntry e in await store.listChildren(location.id))
          if (e.isFolder && _kSrsLegacyWriterDir.hasMatch(e.name)) e,
      ]);
    } on Object catch (e) {
      errors.add('$dir: $e');
    }
  }
  return writers;
}

/// 清掉位置目录 `fushi-srs/<[dir]>/`（同名的几份都算）下 v3.0.x 写入者目录里的死文件（BUG-5017）。只在内核认过这个
/// 位置的根之后调（[srsRunLocationRound]）：新根 `v4/` 在用、旧根 `v3/` 与 `v2/` 都立着让旧版本停下的围栏。
///
/// 为什么这时删是安全的：
/// - 能读这些文件的只有 v3.0.x。旧事件同步早已删掉（守卫 `fushi/test/build/srs_sync_v1_removed_guard_test.dart`），协议 1 起的版本从不
///   读 `batch-*` / `snapshot-*` / `cursor` / `probe`，也从不往写入者目录写（profile 说明文件写在 `v2|v3|v4/devices/`）；
///   v3.0.x 客户端所有者已拍板放弃（BUG-5017）。v3.0.x 写下的事件从来没有经文件迁进过 sync2（v3.3.0 的迁移只搬
///   `media/`），所以这些文件里也没有哪个受支持的版本将来还能捡回来的东西。
/// - `profile.json` 唯一的读者是 [srsListRemoteProfiles] 的最低优先级回退：这个位置的写入者已经在 `v3/devices/` /
///   `v4/devices/` 下，删了只是不再把 v3.0.x 时代的旧名字 / 旧笔记数算进候选。
/// - `media/` 是 v3.3.0 迁移还没搬完的媒体（那是用户文件）：这里**不删**，目录跟着留下；由完整的一趟媒体对账
///   （[srsRunLocationMedia] → [srsRescueLegacyWriterMedia]，那里有本机媒体目录和已收齐的笔记引用）搬完 / 认定
///   用不上之后清掉。只有 `media/` 不在或为空时这里整个目录删掉。
/// - 名字认不出的文件一律不删（目录也就留着）；不是 `<设备>#<化身号>` 形状的目录、`v2` / `v3` / `v4` 一个不碰。
///
/// 删掉的目录记进 [SrsSync2Report.legacyWritersRemoved]；列 / 删失败记进 [SrsSync2Report.legacyWriterErrors]（不算这一轮
/// 失败，下一轮再清）。幂等：清完之后每轮只多列一次位置目录。
Future<void> srsSweepLegacyWriters(
  SyncAssetStore store,
  String dir,
  SrsSync2Report report,
) async {
  for (final AssetEntry writer in await _srsLegacyWriters(
    store,
    dir,
    report.legacyWriterErrors,
  )) {
    try {
      await _srsSweepLegacyWriter(
        store,
        writer,
        report.legacyWritersRemoved,
        report.legacyWriterErrors,
      );
    } on Object catch (e) {
      report.legacyWriterErrors.add('${writer.name}: $e');
    }
  }
}

/// 清一个 v3.0.x 写入者目录（[srsSweepLegacyWriters]）：里面只有死文件与空的 `media/` 就整个删（记进 [removed]），
/// 否则只删死文件（失败记进 [errors]）。
Future<void> _srsSweepLegacyWriter(
  SyncAssetStore store,
  AssetEntry writer,
  List<String> removed,
  List<String> errors,
) async {
  final List<AssetEntry> dead = <AssetEntry>[];
  bool keep = false;
  for (final AssetEntry e in await store.listChildren(writer.id)) {
    if (e.isFolder && e.name == _kSrsLegacyWriterMedia) {
      if ((await store.listChildren(e.id)).isNotEmpty) keep = true;
    } else if (!e.isFolder && _kSrsLegacyWriterFile.hasMatch(e.name)) {
      dead.add(e);
    } else {
      keep = true;
    }
  }
  if (!keep) {
    await store.deleteAsset(writer.id, isFolder: true);
    removed.add(writer.name);
    return;
  }
  for (final AssetEntry f in dead) {
    try {
      await store.deleteAsset(f.id);
    } on Object catch (e) {
      errors.add('${writer.name}/${f.name}: $e');
    }
  }
}

/// [srsRescueLegacyWriterMedia] 的结论。
class SrsLegacyWriterMedia {
  /// 搬进本机媒体目录（并按「没人绑过才绑」记成已对齐）的文件数。
  int imported = 0;

  /// 不必搬、直接删掉的文件数：集合里没有任何存活引用，或本机媒体目录里已有同名文件（集合在这台设备上已有这个名字）。
  int dropped = 0;

  /// 收尾后整个删掉的写入者目录。
  final List<String> removed = <String>[];

  /// 列 / 下载 / 删失败的（`<写入者目录>[/media/<名字>]: <原因>`）：文件留着，下一趟媒体对账再来。
  final List<String> errors = <String>[];

  /// [srsRescueLegacyWriterMedia] 的 `shouldStop` 让收手时，当前写入者目录 `media/` 里还没处理的文件数（≥1；之后的
  /// 写入者目录没列，不算在内）。非 0 = 这一趟没收完，调用方记进 [SrsMediaSyncReport.deferred]，不把位置记成已对账。
  int deferred = 0;
}

/// 把 v3.0.x 写入者目录 `fushi-srs/<[dir]>/<设备>#<化身号>/media/` 里 v3.3.0 迁移没搬完的媒体收尾（拍板台
/// `bug-5017-legacy-writer-media`：所有者拍板「做」，搬完再删、不丢用户文件）。v3.3.0 的迁移已随 gen4 删除，现版本
/// 不读这些文件，它们只能在这里搬。只在完整的一趟媒体对账里调（[srsRunLocationMedia] 的非 `uploadOnly`）：那时新根
/// `v4/meta.json` 已由内核 `location_root` 写定、这一轮的操作已收进本机（调用方只在一轮成功之后跑完整对账），
/// 「集合里谁还引用这个名字」是收齐之后的结论。
///
/// 每个媒体文件（名字不是裸文件名的认不出、不碰）：
/// - 集合里没有任何存活引用（[srsLiveMediaReferences]：存活笔记、删除未满保留期的笔记、全部笔记类型）→ 删。口径与
///   媒体同步 / 本机媒体回收相同：没有笔记用它，受支持的版本里也没有谁会再读它。
/// - 本机媒体目录 [mediaRoot] 已有同名文件 → 删：集合在这台设备上已有这个名字（同一份内容，或之后改过的版本；
///   v3.3.0 的迁移同样不跟已有的绑定抢），写入者目录那份是旧副本。
/// - 否则搬进 [mediaRoot]：先下载到同目录的临时文件再改名（原子，半截文件不会冒充媒体），然后内核 `media_landed`
///   记成「本机已与绑定对齐」、名字还没有绑定的才绑上（不覆盖别的设备已有的绑定：有绑定的，媒体同步照常下载绑定的
///   内容；那份内容哪里都没有时本机留着搬来的这份）。记账成功之后才删写入者目录里那份；记账失败就撤掉刚放进来的
///   文件、写入者那份留着。搬进来的文件由同一趟的 [srsSyncMedia] 按内容传上位置。
///
/// 处理完后写入者目录只剩死文件与空的 `media/` 就整个删（同 [srsSweepLegacyWriters]）。[shouldStop] 每个文件之前
/// 问一次。幂等：没有写入者目录时只多列一次位置目录。
Future<SrsLegacyWriterMedia> srsRescueLegacyWriterMedia(
  SyncAssetStore store,
  String dir,
  SrsDbStore srs,
  Directory mediaRoot, {
  bool Function()? shouldStop,
}) async {
  final SrsLegacyWriterMedia out = SrsLegacyWriterMedia();
  Set<String>? live;
  for (final AssetEntry writer in await _srsLegacyWriters(
    store,
    dir,
    out.errors,
  )) {
    try {
      AssetEntry? media;
      for (final AssetEntry e in await store.listChildren(writer.id)) {
        if (e.isFolder && e.name == _kSrsLegacyWriterMedia) media = e;
      }
      if (media != null) {
        final List<AssetEntry> files = <AssetEntry>[
          for (final AssetEntry f in await store.listChildren(media.id))
            if (!f.isFolder && srsIsBareMediaName(f.name)) f,
        ];
        for (int i = 0; i < files.length; i++) {
          final AssetEntry f = files[i];
          if (shouldStop?.call() ?? false) {
            out.deferred = files.length - i;
            return out;
          }
          try {
            live ??= await srsLiveMediaReferences(srs);
            await _srsRescueLegacyMediaFile(
              store,
              srs,
              mediaRoot,
              f,
              live,
              out,
            );
          } on Object catch (e) {
            out.errors.add('${writer.name}/media/${f.name}: $e');
          }
        }
      }
      await _srsSweepLegacyWriter(store, writer, out.removed, out.errors);
    } on Object catch (e) {
      out.errors.add('${writer.name}: $e');
    }
  }
  return out;
}

/// [srsRescueLegacyWriterMedia] 的一个文件 [f]：删 / 搬进 [mediaRoot] 后删（见那里）。
Future<void> _srsRescueLegacyMediaFile(
  SyncAssetStore store,
  SrsDbStore srs,
  Directory mediaRoot,
  AssetEntry f,
  Set<String> live,
  SrsLegacyWriterMedia out,
) async {
  final File local = File(p.join(mediaRoot.path, f.name));
  if (!live.contains(f.name) || await local.exists()) {
    await store.deleteAsset(f.id);
    out.dropped++;
    return;
  }
  await mediaRoot.create(recursive: true);
  // 临时文件名按媒体名定死：进程死在半路留下的那份，下一趟同一个名字重来时先被清掉。
  final File part = File(
    p.join(mediaRoot.path, '.fushi-legacy-${f.name}.part'),
  );
  try {
    if (await part.exists()) await part.delete();
    await store.getAsset(f.id, part);
    if (await local.exists()) {
      // 下载期间本机有了这个名字（别的一趟同步落地了）：集合已有它。
      await store.deleteAsset(f.id);
      out.dropped++;
      return;
    }
    final String sha = await srsMediaSha256File(part);
    await part.rename(local.path);
    try {
      await srs.sync2Command(<String, Object?>{
        'op': 'media_landed',
        'root': mediaRoot.path,
        'items': <Map<String, String>>[
          <String, String>{'name': f.name, 'sha': sha},
        ],
        'now': srs.now().$1,
      });
    } on Object {
      // 没记成「已对齐」的文件留在本机，下一趟对账会把它当成本机新写、抢掉别的设备的绑定：撤掉，写入者那份留着。
      try {
        await local.delete();
      } on FileSystemException {
        // 删不掉也照样把原错误抛出去；那份内容写入者目录里还有，不丢字节。
      }
      rethrow;
    }
    await store.deleteAsset(f.id);
    out.imported++;
  } finally {
    try {
      if (await part.exists()) await part.delete();
    } on FileSystemException {
      // 留给下一趟同名重来时清。
    }
  }
}

/// 一轮媒体同步：见 srs_media_sync.dart。[uploadOnly] = 发段之前只传本机的媒体（[srsSyncMedia]）。媒体在哪个根由
/// 新根 `v4/meta.json` 的 `media` 定（存量集合 `v3`、新集合 `v4`，内核 `location_root` 写定，[srsLocationMediaFolder]）。
/// 完整的一趟（非 [uploadOnly]）先把 v3.0.x 写入者目录里没搬完的媒体收尾（[srsRescueLegacyWriterMedia]，结论记进
/// 报告的 `legacy*`；搬进本机的文件也算进 [SrsMediaSyncReport.downloaded]），再对账：搬进来的同一趟就传上位置。
Future<SrsMediaSyncReport> srsRunLocationMedia(
  SrsLocationBackend backend,
  SrsDbStore store,
  Directory mediaRoot, {
  SrsMediaCipher? cipher,
  required String locationId,
  bool uploadOnly = false,
  void Function(int done, int total)? onProgress,
  bool Function()? deferRemaining,
}) async {
  final String dir = await srsLocationDir(store);
  final String folder = await srsLocationMediaFolder(
    backend.location(dir, folder: kSrs4Root),
  );
  final SrsLegacyWriterMedia? legacy = uploadOnly
      ? null
      : await srsRescueLegacyWriterMedia(
          backend.store,
          dir,
          store,
          mediaRoot,
          shouldStop: deferRemaining,
        );
  final SrsMediaSyncReport report = await srsSyncMedia(
    cipher: cipher,
    locationId: locationId,
    uploadOnly: uploadOnly,
    onProgress: onProgress,
    deferRemaining: deferRemaining,
    location: backend.location(dir, folder: folder),
    store: store,
    mediaRoot: mediaRoot,
  );
  if (legacy != null) {
    report
      ..downloaded += legacy.imported
      // 到点收手没收完的：记成没做，调用方不把位置记成已对账（BUG-5061 的口径），下一趟接着收。
      ..deferred += legacy.deferred
      ..legacyMediaImported = legacy.imported
      ..legacyMediaDropped = legacy.dropped
      ..legacyWritersRemoved.addAll(legacy.removed)
      ..legacyWriterErrors.addAll(legacy.errors);
  }
  return report;
}

/// 位置上媒体所在的根目录名：新根 [root4] 的 `meta.json` 的 `media`（只认 `v3` / `v4`）。新根 meta 只由一轮同步的
/// `location_root` 写，媒体同步总在它之后跑；读不到或认不得就报错（不猜，猜错会把媒体写进被围栏的旧根或反过来）。
Future<String> srsLocationMediaFolder(SrsLocationStore root4) async {
  final Uint8List? meta = await root4.get('meta.json');
  if (meta == null) {
    throw StateError('srs media: the location has no v4/meta.json yet');
  }
  final Object? media = (jsonDecode(utf8.decode(meta)) as Map)['media'];
  if (media != kSrsSync2Folder && media != kSrs4Root) {
    throw StateError('srs media: unknown media root $media in v4/meta.json');
  }
  return media! as String;
}
