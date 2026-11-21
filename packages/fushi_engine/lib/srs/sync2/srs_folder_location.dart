/// 用户自己加的「文件夹」存储位置（docs/specs/2026-10-25-srs-sync-v2-design.md §6.5、§10.3）。
///
/// 已有的同步通道（云盘 / 互联）各自就是一个同步 + 媒体位置；这里补上设计里的「＋ 本地文件夹」：U 盘、NAS 挂载点、
/// 被别的同步工具（Syncthing 等）同步的目录。每个位置有三种用途，可多选：
/// - **同步**：收发操作段（与云盘通道同一协议、同一目录布局）；
/// - **媒体**：镜像媒体文件，按 90 天保留期清理；
/// - **归档**：接收全部段 / head / 媒体，**永不删除任何东西**（不清旧 head、不清媒体；只有用户确认的
///   彻底清除会重写段），默认不开。
///
/// 目录布局与云盘的集合根相同（新根 `<文件夹>/fushi-srs/<dir>/v4/`，旧根 `…/v3/` 只剩围栏），所以归档位置随时能改成
/// 同步位置直接用。协议 1 旧根 `v2/` 的迁移与旧根媒体搬家暂不在新代跑（见 [srsSyncFolderLocation]）。
library;

import 'dart:io';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:path/path.dart' as p;

/// 一个文件夹位置的配置（设备本地：路径只在这台设备上有意义）。
class SrsFolderLocation {
  const SrsFolderLocation({
    required this.id,
    required this.path,
    this.sync = true,
    this.media = true,
    this.archive = false,
  });

  factory SrsFolderLocation.fromJson(Map<String, Object?> j) =>
      SrsFolderLocation(
        id: j['id'] as String? ?? '',
        path: j['path'] as String? ?? '',
        sync: j['sync'] as bool? ?? true,
        media: j['media'] as bool? ?? true,
        archive: j['archive'] as bool? ?? false,
      );

  /// 稳定身份（本机按 `folder:<id>` 记这个位置传到了哪）。
  final String id;
  final String path;
  final bool sync;
  final bool media;
  final bool archive;

  /// 本机记上传进度用的位置身份。
  String get locationId => 'folder:$id';

  /// 一个用途都没勾：保留配置但不跑（取消用途不删文件）。
  bool get idle => !sync && !media && !archive;

  SrsFolderLocation copyWith({bool? sync, bool? media, bool? archive}) =>
      SrsFolderLocation(
        id: id,
        path: path,
        sync: sync ?? this.sync,
        media: media ?? this.media,
        archive: archive ?? this.archive,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'path': path,
    'sync': sync,
    'media': media,
    'archive': archive,
  };
}

/// [location] 在磁盘上协议 3 的集合根（`<文件夹>/fushi-srs/<dir>/v3/`；新代只读它的 `meta.json` 并改写成围栏，存量
/// 集合的媒体仍在这里）。[dir] = 集合的位置目录名（内核 `identity` 的 `dir`，[srsFolderLocationDir]）。
Directory srsFolderCollectionRoot(SrsFolderLocation location, String dir) =>
    Directory(p.join(location.path, kSrsSync2Namespace, dir, kSrsSync2Folder));

/// [location] 在磁盘上新代的集合根（`<文件夹>/fushi-srs/<dir>/v4/`）。
Directory srsFolderNewRoot(SrsFolderLocation location, String dir) =>
    Directory(p.join(location.path, kSrsSync2Namespace, dir, kSrs4Root));

/// [location] 上协议 1 的旧集合根（`<文件夹>/fushi-srs/<dir>/v2/`，迁移之后只剩围栏）。
Directory srsFolderV1CollectionRoot(SrsFolderLocation location, String dir) =>
    Directory(
      p.join(location.path, kSrsSync2Namespace, dir, kSrsSync2V1Folder),
    );

/// 这个 profile 的集合在位置上的目录名：内核 `identity` 回包的 `dir`（设计 §5.1），不按 profile uid 拼。
Future<String> srsFolderLocationDir(SrsDbStore store) async =>
    (await store.sync2Command(<String, Object?>{
          'op': 'identity',
          'now': store.now().$1,
        })).map['dir']!
        as String;

/// 一个文件夹位置这一轮的结果（[ops] 里带加密握手的结论：kdf / encryptionEnabled / 口令错误）。
class SrsFolderSyncReport {
  SrsFolderSyncReport({this.ops, this.media, this.handshake});

  /// 操作同步这一轮的结果（只做媒体的位置：握手没过时带着错误，否则为 null）。
  final SrsSync2Report? ops;
  final SrsMediaSyncReport? media;

  /// 只做媒体的位置的 `meta.json` 握手结论（kdf / 本机刚开的加密已写上 / 用没用密钥）。
  final SrsSync2Report? handshake;

  /// 这个位置这一轮的加密结论（调度器据此记加密状态、把本机刚开的加密标成已生效）。
  SrsSync2Report? get crypto => ops ?? handshake;
}

/// 对一个文件夹位置跑一轮：同步 / 归档用途跑操作同步，媒体 / 归档用途跑媒体镜像。文件夹不在（U 盘没插）时
/// 抛 [FileSystemException]，调用方记一次、下次再试。
///
/// 位置的根一律先走内核 `location_root`（[srsSync4LocationRoot]，同步用途在 [srsSync2Round] 里）：新根 `v4/` 的
/// meta 与 loc 标记、旧根 `v3/` 的围栏都由它写；判「新集合」只看 `v3/meta.json` 在不在，所以这一轮在它之前不往旧根
/// 写任何东西。旧根 `v3/` 上的段由一轮同步收进本机承袭日志（旧根接手，G8-7b）；只有协议 1 旧根 `v2/` 的位置内核
/// 明确拒绝（D21），不再一次性迁移；旧根媒体搬家同样不跑（协议 1 位置迁移的装配已删，第五波）。
/// 媒体按新根 meta 的 `media` 落在旧根（存量集合）或新根（新集合）。
///
/// 进度 / 收手 / 诊断与云盘、互联那条路径（[srsSync2Round]）同一套：[onFetchProgress] / [onUploadStart] /
/// [shouldStop] / [onStep] 原样交给这一轮，[onMediaStart] 在开始传媒体之前调一次（发段前那一步只在真有媒体要传时）。以前这里一个都不传：大库
/// 首次从文件夹收几百个段要跑好几分钟，界面全程停在「正在准备」、切 profile 停不下来、进程死在里面也不留面包屑。
/// [shouldStop] 也管完整媒体对账：开头前看一次，为真就以 [kSrsSync2Stopped] 交回。
Future<SrsFolderSyncReport> srsSyncFolderLocation({
  required SrsFolderLocation location,
  required SrsDbStore store,
  Directory? mediaRoot,
  SrsLocationKey? key,
  void Function(int done, int total)? onFetchProgress,
  void Function()? onUploadStart,
  void Function()? onMediaStart,
  bool Function()? shouldStop,
  SrsSyncStepCallback? onStep,
}) async {
  if (location.idle) return SrsFolderSyncReport();
  if (!Directory(location.path).existsSync()) {
    throw FileSystemException('storage location not available', location.path);
  }
  final String dir = await srsFolderLocationDir(store);
  final SrsLocationStore root = SrsDirectoryLocationStore(
    srsFolderCollectionRoot(location, dir),
  );
  final SrsLocationStore root4 = SrsDirectoryLocationStore(
    srsFolderNewRoot(location, dir),
  );
  // 只看它的 `meta.json` 在不在：只有协议 1 旧根的位置内核明确拒绝（D21）。
  final SrsLocationStore root1 = SrsDirectoryLocationStore(
    srsFolderV1CollectionRoot(location, dir),
  );
  // 媒体所在的根（新根 meta 的 `media`）。
  SrsLocationStore mediaAt(String? media) =>
      media == kSrsSync2Folder ? root : root4;
  SrsSync2Report? ops;
  // 发段之前那一步传上去的媒体数（并进下面完整对账的结果）。
  int uploadedEarly = 0;
  if (location.sync || location.archive) {
    String? roundMedia;
    ops = await srsSync2Round(
      host: store,
      location: root4,
      oldRoot: root,
      protocol1Root: root1,
      locationId: location.locationId,
      nowMs: () => store.now().$1,
      key: key,
      // 勾了归档就一个旧 head 也不删（归档位置永不删除，§10.3）。
      archive: location.archive,
      onFetchProgress: onFetchProgress,
      onUploadStart: onUploadStart,
      shouldStop: shouldStop,
      onStep: onStep,
      onLocationRoot: (SrsLocationRoot r) => roundMedia = r.media,
      // 媒体先于引用它的段（设计 §6.1 写入纪律 3，审查 S-10）：发段之前先把本机的媒体传上去。这一步出错不拦操作
      // 同步——同一个错误在下面的完整媒体对账里照样抛给调用方。
      beforeUpload: mediaRoot != null && (location.media || location.archive)
          ? (String? keyHex) async {
              try {
                uploadedEarly += (await srsSyncMedia(
                  location: mediaAt(roundMedia),
                  store: store,
                  mediaRoot: mediaRoot,
                  archive: location.archive,
                  cipher: keyHex == null ? null : SrsMediaCipher(store, keyHex),
                  uploadOnly: true,
                  // 本机没有要先传的媒体就不报「媒体」阶段（云盘那条路径同样只在内容可能变了时才报）。
                  onTransferStart: onMediaStart,
                )).uploaded;
              } on FileSystemException {
                // 见上：完整对账会再报。
              }
            }
          : null,
    );
    // 加密位置口令不对 / 没有：媒体也不碰（明文媒体不能写进加密位置）。位置来自更新版本（`minReader` 比本机新）
    // 同样整个位置都不碰：以前这里只看 error，needsUpgrade 时照样按明文跑媒体对账（往 `media/` 写、按过期清），
    // 旧版本就不能靠提高最低读者版本把自己挡在新格式的位置之外。
    if (ops.error != null || ops.needsUpgrade) {
      return SrsFolderSyncReport(ops: ops);
    }
  }
  String? mediaKey = (ops?.encrypted ?? false) ? key!.keyHex : null;
  String? media = ops?.mediaRoot;
  SrsSync2Report? handshake;
  if (ops == null && mediaRoot != null && location.media) {
    // 只做媒体的位置：同一步位置的根（本机开过加密而位置上 kdf 不见了同样停下，不传明文媒体；本机刚开加密由内核
    // 写进新根 meta）。不拉段、不发段。
    handshake = SrsSync2Report();
    final SrsLocationRoot? r = await srsSync4LocationRoot(
      host: store,
      location: root4,
      oldRoot: root,
      protocol1Root: root1,
      locationId: location.locationId,
      nowMs: () => store.now().$1,
      key: key,
      collection: (await store.sync2Command(<String, Object?>{
        'op': 'identity',
        'now': store.now().$1,
      })).map['collection'],
      report: handshake,
    );
    // 握手结论照样交回（调度器据此记加密状态、把本机刚开的加密标成已生效）。
    if (r == null) return SrsFolderSyncReport(ops: handshake);
    mediaKey = r.keyHex;
    media = r.media;
  }
  if (shouldStop?.call() ?? false) {
    // 收手了（库要关 / 位置被关掉）：完整媒体对账不开头，按「收手」交回（调度器不记成这个位置的错）。
    return SrsFolderSyncReport(
      ops: (ops ?? handshake ?? SrsSync2Report())..error = kSrsSync2Stopped,
    );
  }
  SrsMediaSyncReport? mediaReport;
  if (mediaRoot != null && (location.media || location.archive)) {
    onMediaStart?.call();
    mediaReport = await srsSyncMedia(
      location: mediaAt(media),
      store: store,
      mediaRoot: mediaRoot,
      archive: location.archive,
      cipher: mediaKey == null ? null : SrsMediaCipher(store, mediaKey),
    );
  }
  mediaReport?.uploaded += uploadedEarly;
  return SrsFolderSyncReport(
    ops: ops,
    media: mediaReport,
    handshake: handshake,
  );
}
