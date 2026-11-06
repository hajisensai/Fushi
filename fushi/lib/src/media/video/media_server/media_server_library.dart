/// 媒体服务器（Jellyfin / Emby / 飞牛 / Plex）条目的「加入媒体库」与从媒体库重开。
///
/// 2026-10-23：与在线视频源的入库（`anime_source_library.dart`）同一形态，**不升
/// schema**——
/// - 每个可播叶子（电影 / 集）一行 `VideoBooks`：`bookUid` = 服务器条目 id（分区里
///   直接播放时 `RemoteVideoInfo.id` 就是它，入库前后断点 / 字幕记忆连续）；
///   `videoPath` 是非 http 的 `media-server://` 标识（[mediaServerVideoPath]，所有
///   「按 http 判本地文件」的门都认它）；`streamSpecJson` 是重开规格
///   [MediaServerBookSpec]（服务器身份 + 条目快照），重开时按设置里同一台服务器的
///   配置现建客户端取流——流地址带令牌、换线路就变，不落库；
/// - 同一部剧的集经 [RemoteCollectionAdoptionService] 归进以剧名命名的 playlist
///   合集（与媒体服务器混排 / 互联下载入库同一条收养路径），合集与各集封面用剧的
///   海报。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/media_server_video_path.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart'
    show videoCoverFileName;
import 'package:fushi_engine/media/video/video_storage.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/remote_collection_adoption_service.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 媒体服务器入库条目的重开规格（落 `VideoBooks.streamSpecJson`）。
@immutable
class MediaServerBookSpec {
  const MediaServerBookSpec({
    required this.serverId,
    required this.info,
    this.workId,
  });

  /// spec 的类型标记：与直链 spec / 在线视频源 spec 同列共存，互不误读。
  static const String kind = 'media-server';

  /// [MediaServerBrowser.serverId] / [MediaServerConfig.sourceId]（服务器 + 账号）。
  final String serverId;

  /// 条目快照（不含令牌：封面 URL 与断点在编码时剥掉，见 [encode]）。
  final RemoteVideoInfo info;

  /// 所属作品：集 = 剧 id，电影 = 自身 id。详情页按它判「这部作品在不在库」，
  /// 重开时按它挑同一部剧的连播成员。
  final String? workId;

  String get itemId => info.id;

  String encode() {
    // 封面 URL 可能带访问令牌（Jellyfin `api_key`），断点是入库那一刻的旧值：都不
    // 落库。重开时按服务器现取（见 [buildMediaServerLaunch]）。
    final Map<String, Object?> json = info.toJson()
      ..remove('coverUrl')
      ..remove('positionMs')
      ..remove('positionUpdatedAtMs');
    return jsonEncode(<String, Object?>{
      'kind': kind,
      'serverId': serverId,
      'workId': ?workId,
      'info': json,
    });
  }

  /// 解析失败（不是本种 spec / 旧数据 / 坏 JSON）返回 null，**绝不抛**。
  static MediaServerBookSpec? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?> || decoded['kind'] != kind) {
        return null;
      }
      final String serverId = decoded['serverId']?.toString() ?? '';
      final Object? info = decoded['info'];
      if (serverId.isEmpty || info is! Map) return null;
      final RemoteVideoInfo parsed = RemoteVideoInfo.fromJson(
        info.cast<String, Object?>(),
      );
      if (parsed.id.isEmpty) return null;
      final String? workId = decoded['workId']?.toString();
      return MediaServerBookSpec(
        serverId: serverId,
        info: parsed,
        workId: workId == null || workId.isEmpty ? null : workId,
      );
    } on Object {
      return null;
    }
  }
}

/// 一部作品在媒体库里的状态：已入库的叶子 id（有 `media-server://` 行的）。
@immutable
class MediaServerWorkLibraryStatus {
  const MediaServerWorkLibraryStatus(this.online);

  final Set<String> online;

  bool get inLibrary => online.isNotEmpty;
}

/// 媒体服务器条目的入库 / 移出。
class MediaServerVideoLibrary {
  MediaServerVideoLibrary({
    required this.database,
    VideoBookRepository? repository,
  }) : repository = repository ?? VideoBookRepository(database);

  final FushiDatabase database;
  final VideoBookRepository repository;

  /// 本作品（[work] 是剧或电影）已入库的叶子。纯读库，不联网。
  Future<MediaServerWorkLibraryStatus> statusOf(
    MediaServerBrowser browser,
    MediaServerItem work,
  ) async {
    final Set<String> online = <String>{
      for (final ({VideoBookRow row, MediaServerBookSpec spec}) entry
          in await _rowsOfWork(browser.serverId, work.id))
        entry.row.bookUid,
    };
    return MediaServerWorkLibraryStatus(online);
  }

  /// 加入媒体库：电影一行；剧把**全部季**的集逐页取回各落一行，归进剧名合集。
  /// 已在库的集跳过（再点一次只补新集，不动已看 / 已下载的行）。返回新加的条数。
  /// 之后服务器上新出的集由后台库更新探针补（`video_library_update_probe.dart`）。
  Future<int> addToLibrary(
    MediaServerBrowser browser,
    MediaServerItem work,
  ) async => (await addMissing(browser, work)).length;

  /// [addToLibrary] 的本体：返回这次新加的条目（探针据此投递新集提醒）。
  Future<List<RemoteVideoInfo>> addMissing(
    MediaServerBrowser browser,
    MediaServerItem work,
  ) async {
    final List<MediaServerItem> leaves = await _playableLeavesOf(browser, work);
    final RemoteCollectionAdoptionService adoption =
        RemoteCollectionAdoptionService(database);
    final List<String> added = <String>[];
    final List<RemoteVideoInfo> addedInfos = <RemoteVideoInfo>[];
    for (final MediaServerItem leaf in leaves) {
      final RemoteVideoInfo info = browser.toRemoteVideoInfo(leaf);
      if (await repository.getByBookUid(info.id) == null) {
        await repository.saveVideoBook(
          VideoBooksCompanion(
            bookUid: Value<String>(info.id),
            title: Value<String>(info.title),
            videoPath: Value<String>(
              mediaServerVideoPath(itemId: info.id, label: info.title),
            ),
            streamSpecJson: Value<String?>(
              MediaServerBookSpec(
                serverId: browser.serverId,
                info: info,
                workId: work.id,
              ).encode(),
            ),
            importedAt: Value<int?>(DateTime.now().millisecondsSinceEpoch),
          ),
        );
        added.add(info.id);
        addedInfos.add(info);
      }
      // 已在库的集也重新收养一次：合集被用户删掉后重新加入能回到合集里。
      await adoption.adoptVideo(info);
    }
    if (added.isNotEmpty) {
      await repository.recordVideoImportActivity(
        bookUid: added.first,
        title: work.name,
      );
      await _applyCovers(
        browser,
        work,
        added,
        collectionName: work.type == MediaServerItemType.series
            ? work.name
            : null,
      );
    }
    return addedInfos;
  }

  /// 库里全部「剧」类入库作品（服务器 + 剧 id），按入库行分组；电影没有新集可补，
  /// 不在其中。纯读库，后台库更新探针用。
  Future<List<({String serverId, String workId})>>
  seriesWorksInLibrary() async {
    final Set<({String serverId, String workId})> works =
        <({String serverId, String workId})>{};
    for (final VideoBookRow row in await database.allVideoBooks()) {
      if (!isMediaServerVideoPath(row.videoPath)) continue;
      final MediaServerBookSpec? spec = MediaServerBookSpec.tryParse(
        row.streamSpecJson,
      );
      final String? workId = spec?.workId;
      if (spec == null || workId == null || workId == spec.itemId) continue;
      works.add((serverId: spec.serverId, workId: workId));
    }
    return works.toList(growable: false);
  }

  /// 移出媒体库：删本作品的 `media-server://` 行。已下载到本机的集是普通本地视频，
  /// 不跟着移出。
  Future<int> removeFromLibrary(
    MediaServerBrowser browser,
    MediaServerItem work,
  ) async {
    final List<String> uids = <String>[
      for (final ({VideoBookRow row, MediaServerBookSpec spec}) entry
          in await _rowsOfWork(browser.serverId, work.id))
        entry.row.bookUid,
    ];
    if (uids.isEmpty) return 0;
    return repository.deleteVideoBooksAndReclaimAssets(uids);
  }

  Future<List<({VideoBookRow row, MediaServerBookSpec spec})>> _rowsOfWork(
    String serverId,
    String workId,
  ) async {
    return <({VideoBookRow row, MediaServerBookSpec spec})>[
      for (final VideoBookRow row in await database.allVideoBooks())
        if (isMediaServerVideoPath(row.videoPath))
          if (MediaServerBookSpec.tryParse(row.streamSpecJson)
              case final MediaServerBookSpec spec
              when spec.serverId == serverId &&
                  (spec.workId ?? spec.itemId) == workId)
            (row: row, spec: spec),
    ];
  }

  /// 电影 = 自身；剧 = 整部剧的集（不带 SeasonId，按季集号升序，逐页取完）。
  Future<List<MediaServerItem>> _playableLeavesOf(
    MediaServerBrowser browser,
    MediaServerItem work,
  ) async {
    if (work.isPlayable) return <MediaServerItem>[work];
    final List<MediaServerItem> leaves = <MediaServerItem>[];
    int startIndex = 0;
    while (true) {
      final MediaServerPage page = await browser.listEpisodes(
        seriesId: work.id,
        startIndex: startIndex,
      );
      leaves.addAll(page.items.where((MediaServerItem e) => e.isPlayable));
      if (!page.hasMore || page.nextStartIndex <= startIndex) break;
      startIndex = page.nextStartIndex;
    }
    return leaves;
  }

  /// 作品海报**每部作品落一份**（[mediaServerWorkCoverFileName]），本作品各行的
  /// `coverPath` 都指向它；剧的合集还没有自有封面时再拷一份给合集。共用文件的回收
  /// 口径与在线视频源同款（删行只回收不再被引用的封面）。取不到 / 写不进封面不算
  /// 入库失败（库页退回占位），失败记错误日志。
  Future<void> _applyCovers(
    MediaServerBrowser browser,
    MediaServerItem work,
    List<String> bookUids, {
    String? collectionName,
  }) async {
    final String? coverUrl = browser.coverUrl(work);
    if (coverUrl == null || coverUrl.isEmpty || bookUids.isEmpty) return;
    try {
      final Directory covers = await VideoStorage.coversDir();
      final String workCover = p.join(
        covers.path,
        mediaServerWorkCoverFileName(browser.serverId, work.id),
      );
      if (await _pointAtWorkCover(bookUids, workCover, collectionName)) return;
      final Uint8List bytes = await browser.fetchRemoteCover(coverUrl);
      if (bytes.isEmpty) return;
      await _pointAtWorkCover(
        bookUids,
        workCover,
        collectionName,
        bytes: bytes,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MediaServerVideoLibrary.cover',
        error,
        stack,
      );
    }
  }

  Future<bool> _pointAtWorkCover(
    List<String> bookUids,
    String workCover,
    String? collectionName, {
    Uint8List? bytes,
  }) async {
    final VideoScrapeOperationLease? lease =
        VideoScrapeOperationGate.tryEnterOperation();
    if (lease == null) throw StateError('视频刮削资料正在清理');
    try {
      return await VideoCoverMutationGate.runExclusive(() async {
        if (bytes != null) {
          await Directory(p.dirname(workCover)).create(recursive: true);
          await MediaCoverService.applyCoverBytes(
            bytes: bytes,
            destPath: workCover,
          );
        } else if (!await File(workCover).exists()) {
          return false;
        }
        for (final String uid in bookUids) {
          await repository.updateCover(uid, workCover);
        }
        if (collectionName == null) return true;
        final MediaCollectionRow? collection = await database
            .getMediaCollectionByNaturalKey(collectionName, 'playlist');
        if (collection != null && collection.coverPath == null) {
          final Directory collectionCovers =
              await VideoStorage.collectionCoversDir();
          await collectionCovers.create(recursive: true);
          final String path = p.join(
            collectionCovers.path,
            videoCoverFileName('${collection.id}'),
          );
          await MediaCoverService.applyCoverFile(
            source: File(workCover),
            destPath: path,
          );
          await repository.updateMediaCollectionCoverPath(collection.id, path);
        }
        return true;
      });
    } finally {
      lease.release();
    }
  }
}

/// 一部媒体服务器作品的共用封面文件名：`media_server_<sha1(服务器\n作品 id)>.jpg`。
String mediaServerWorkCoverFileName(String serverId, String workId) =>
    'media_server_${sha1.convert(utf8.encode('$serverId\n$workId'))}.jpg';

/// 重开入库条目时那台服务器已不在设置的登录列表里（登出 / 换账号），或行上的规格
/// 读不出。播放页据此给明确提示。
class MediaServerLaunchUnavailable implements Exception {
  const MediaServerLaunchUnavailable(this.message);

  final String message;

  @override
  String toString() => 'MediaServerLaunchUnavailable($message)';
}

/// 从媒体库重开一个媒体服务器入库条目：按行里的服务器身份在 [loadConfigs] 里找到
/// 同一台服务器的配置现建客户端，合集里同一部剧的其它入库行作为连播成员。
///
/// 起播那一条先向服务器取一次详情（服务器端断点 / 带令牌的封面），失败就用规格里
/// 的快照照常起播。[playlistCollectionId] 为空时只有这一条。
Future<
  ({
    RemoteVideoClient client,
    RemoteVideoInfo info,
    List<RemoteVideoInfo> members,
    int startIndex,
  })
>
buildMediaServerLaunch({
  required VideoBookRow row,
  required FushiDatabase database,
  required VideoBookRepository repository,
  required Future<List<MediaServerConfig>> Function() loadConfigs,
  int? playlistCollectionId,
}) async {
  final MediaServerBookSpec? spec = MediaServerBookSpec.tryParse(
    row.streamSpecJson,
  );
  if (spec == null) {
    throw const MediaServerLaunchUnavailable('missing media-server spec');
  }
  MediaServerConfig? config;
  for (final MediaServerConfig candidate in await loadConfigs()) {
    if (candidate.sourceId == spec.serverId) {
      config = candidate;
      break;
    }
  }
  if (config == null) {
    throw const MediaServerLaunchUnavailable('media server is not signed in');
  }
  final List<RemoteVideoInfo> members = <RemoteVideoInfo>[];
  if (playlistCollectionId != null && spec.workId != null) {
    final List<MediaCollectionItemRow> items = await database
        .getCollectionItems(playlistCollectionId);
    items.sort(
      (MediaCollectionItemRow a, MediaCollectionItemRow b) =>
          a.sortIndex.compareTo(b.sortIndex),
    );
    for (final MediaCollectionItemRow item in items) {
      if (item.mediaType != MediaKind.video.dbValue) continue;
      final VideoBookRow? member = item.entryKey == row.bookUid
          ? row
          : await repository.getByBookUid(item.entryKey);
      if (member == null || !isMediaServerVideoPath(member.videoPath)) {
        continue;
      }
      final MediaServerBookSpec? memberSpec = MediaServerBookSpec.tryParse(
        member.streamSpecJson,
      );
      if (memberSpec == null ||
          memberSpec.serverId != spec.serverId ||
          memberSpec.workId != spec.workId) {
        continue;
      }
      members.add(memberSpec.info);
    }
  }
  if (!members.any((RemoteVideoInfo m) => m.id == spec.itemId)) {
    members
      ..clear()
      ..add(spec.info);
  }
  final MediaServerBrowser browser = config.buildBrowser();
  int startIndex = members.indexWhere(
    (RemoteVideoInfo m) => m.id == spec.itemId,
  );
  if (startIndex < 0) startIndex = 0;
  try {
    final MediaServerItem detail = await browser.itemDetail(spec.itemId);
    if (detail.isPlayable) {
      members[startIndex] = browser.toRemoteVideoInfo(detail);
    }
  } on Object catch (error) {
    debugPrint('[media-server-library] detail ${spec.itemId} failed: $error');
  }
  return (
    client: browser.playbackClient,
    info: members[startIndex],
    members: List<RemoteVideoInfo>.unmodifiable(members),
    startIndex: startIndex,
  );
}
