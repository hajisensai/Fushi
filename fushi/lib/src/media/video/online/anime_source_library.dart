/// 视频在线源（Aniyomi 扩展）作品的「加入媒体库」与「下载后入库」。
///
/// 2026-09-27「浏览」阶段 2b（设计见 `docs/specs/2026-09-27-browse-module.md`）：
/// **不升 schema**，复用 TODO-1157 流媒体书的形态——
/// - 每集一行 `VideoBooks`：`bookUid` = [AnimeSourceVideoClient.episodeVideoId]（播放页
///   本就按它记断点 / 字幕记忆 / 调轴，入库前后进度连续）；`videoPath` 是非 http 的
///   `anime-source://` 标识（[animeSourceVideoPath]，所有「按 http 判本地文件」的门都
///   认它）；`streamSpecJson` 是重开规格 [AnimeSourceBookSpec]（扩展包 / 源 / 作品 /
///   本集的 Mihon JSON），重开时不联网就能重建 [AnimeSourceVideoClient]；
/// - 同一作品的集经 [RemoteCollectionAdoptionService] 归进以作品名命名的 playlist
///   合集（与互联 / 媒体服务器下载入库同一条收养路径），合集封面经扩展取。
///
/// 下载完的集**替换同一 bookUid 的行**：`videoPath` 换成本地文件、清掉 spec，于是它
/// 从此是普通本地视频，进度与合集归属不变。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/anime_source_video_path.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart'
    show videoCoverFileName;
import 'package:fushi_engine/media/video/video_storage.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/remote_collection_adoption_service.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
import 'package:crypto/crypto.dart' show sha1;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/video/online/anime_source_video_client.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteDownloadCancelled;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 在线视频源入库集的重开规格（落 `VideoBooks.streamSpecJson`）。
@immutable
class AnimeSourceBookSpec {
  const AnimeSourceBookSpec({
    required this.extensionPackage,
    required this.sourceId,
    required this.anime,
    required this.episode,
  });

  /// spec 的类型标记：与 TODO-1157 的直链 spec（`StreamVideoSpec`）同列共存，
  /// 那边的 `fromStorageJson` 读到未知键只会得到空 spec，不会误用。
  static const String kind = 'anime-source';

  final String extensionPackage;
  final String sourceId;
  final MihonAnime anime;
  final MihonEpisode episode;

  String encode() => jsonEncode(<String, Object?>{
    'kind': kind,
    'extensionPackage': extensionPackage,
    'sourceId': sourceId,
    'anime': anime.toJson(),
    'episode': episode.toJson(),
  });

  /// 解析失败（不是本种 spec / 旧数据 / 坏 JSON）返回 null，**绝不抛**。
  static AnimeSourceBookSpec? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?> || decoded['kind'] != kind) {
        return null;
      }
      final Object? anime = decoded['anime'];
      final Object? episode = decoded['episode'];
      final String package = decoded['extensionPackage']?.toString() ?? '';
      final String source = decoded['sourceId']?.toString() ?? '';
      if (anime is! Map || episode is! Map || package.isEmpty) return null;
      return AnimeSourceBookSpec(
        extensionPackage: package,
        sourceId: source,
        anime: MihonAnime.fromJson(anime.cast<String, Object?>()),
        episode: MihonEpisode.fromJson(episode.cast<String, Object?>()),
      );
    } on Object {
      // 行上的数据来自扩展 / 备份 / 旧版本：字段类型不对（`status: "ongoing"`）会在
      // `fromJson` 的强转里抛 TypeError，一样按「不是可用的规格」处理。
      return null;
    }
  }

  /// 同一部作品（同扩展、同源、同作品 URL）。
  bool sameWorkAs(AnimeSourceBookSpec other) =>
      extensionPackage == other.extensionPackage &&
      sourceId == other.sourceId &&
      anime.url == other.anime.url;
}

/// 一集的可读标签（`videoPath` 末段 / 下载文件名）：作品名 - E03。
String animeSourceEpisodeLabel(MihonAnime anime, MihonEpisode episode) {
  final double number = episode.number;
  final String suffix = number > 0
      ? 'E${number == number.roundToDouble() ? number.round().toString().padLeft(2, '0') : number}'
      : episode.name;
  return '${anime.title} - $suffix';
}

/// 一集在线播放留下的断点（播放页合集模式按 `(成员 id, 0)` 落 prefs 的位置与时刻，
/// 见 `videoRemotePositionEpisodePrefKey` / `videoRemotePositionEpisodeAtPrefKey`）。
typedef AnimeOnlinePosition = ({int positionMs, int playedAt});

/// 读一集的在线断点；没有返回 null。由调用方注入（prefs 在 app 层，本类不碰）。
typedef AnimeOnlinePositionReader =
    AnimeOnlinePosition? Function(String episodeId);

/// 本作品各集在媒体库里的状态（一次遍历读出）。三个集合互斥。
@immutable
class AnimeSourceEpisodeStatus {
  const AnimeSourceEpisodeStatus({
    required this.online,
    required this.downloaded,
    required this.missing,
  });

  /// 有在线行（`anime-source://`）的集：「移出媒体库」删的就是它们。
  final Set<String> online;

  /// 已下载成本地视频行的集（普通本地视频，移出不动它们）。
  final Set<String> downloaded;

  /// 库里一行都没有的集：「加入媒体库」补的就是它们（含刷新后多出来的新集）。
  final Set<String> missing;

  /// 还有集没进库：显示「加入媒体库」（与 [canRemove] 可以同时成立）。
  bool get canAdd => missing.isNotEmpty;

  /// 有在线行可删：显示「移出媒体库」。
  bool get canRemove => online.isNotEmpty;
}

/// 在线作品的入库 / 移出 / 下载后入库。
class AnimeSourceLibrary {
  AnimeSourceLibrary({
    required this.database,
    VideoBookRepository? repository,
    this.onlinePositionReader,
  }) : repository = repository ?? VideoBookRepository(database);

  final FushiDatabase database;
  final VideoBookRepository repository;

  /// 下载完登记成本地行时，把在线播放留下的断点接到行上（本地播放读
  /// `VideoBooks.lastPositionMs`，不读在线断点的 prefs）。为空时不接。
  final AnimeOnlinePositionReader? onlinePositionReader;

  /// 本作品各集的入库状态：有在线行 / 已下载 / 库里没有。
  Future<AnimeSourceEpisodeStatus> episodeStatus(
    AnimeSourceVideoClient client,
  ) async {
    final Set<String> online = <String>{};
    final Set<String> downloaded = <String>{};
    final Set<String> missing = <String>{};
    for (final RemoteVideoInfo info in client.remoteVideos) {
      final VideoBookRow? row = await repository.getByBookUid(info.id);
      if (row == null) {
        missing.add(info.id);
      } else if (isAnimeSourceVideoPath(row.videoPath)) {
        online.add(info.id);
      } else if (!isNetworkOnlyVideoPath(row.videoPath)) {
        downloaded.add(info.id);
      }
    }
    return AnimeSourceEpisodeStatus(
      online: online,
      downloaded: downloaded,
      missing: missing,
    );
  }

  /// 加入媒体库：每集一行在线行，归进作品合集。已在库的集跳过（刷新后只补新集，
  /// 不动已看 / 已下载的行）。返回新加的集数。
  Future<int> addToLibrary(AnimeSourceVideoClient client) async {
    final RemoteCollectionAdoptionService adoption =
        RemoteCollectionAdoptionService(database);
    final List<RemoteVideoInfo> infos = client.remoteVideos;
    final List<String> added = <String>[];
    for (int index = 0; index < infos.length; index++) {
      final RemoteVideoInfo info = infos[index];
      final MihonEpisode episode = client.episodes[index];
      if (await repository.getByBookUid(info.id) == null) {
        await repository.saveVideoBook(
          VideoBooksCompanion(
            bookUid: Value<String>(info.id),
            title: Value<String>(info.title),
            videoPath: Value<String>(
              animeSourceVideoPath(
                extensionPackage: client.context.source.extensionPackage,
                sourceId: client.context.source.id,
                label: animeSourceEpisodeLabel(client.anime, episode),
              ),
            ),
            streamSpecJson: Value<String?>(_specFor(client, episode).encode()),
            importedAt: Value<int?>(DateTime.now().millisecondsSinceEpoch),
          ),
        );
        added.add(info.id);
      }
      // 已在库的集也重新收养一次：合集被用户删掉后重新加入能回到合集里。
      await adoption.adoptVideo(info);
    }
    if (added.isNotEmpty) {
      await repository.recordVideoImportActivity(
        bookUid: added.first,
        title: client.anime.title,
      );
      await _applyCovers(client, added);
    }
    return added.length;
  }

  /// 移出媒体库：删掉本作品的**在线行**。已下载到本机的集是普通本地视频，
  /// 不跟着移出（删它们走媒体库自己的删除，那里有「同时删除本地文件」的确认）。
  Future<int> removeFromLibrary(AnimeSourceVideoClient client) async {
    final List<String> online = <String>[];
    for (final RemoteVideoInfo info in client.remoteVideos) {
      final VideoBookRow? row = await repository.getByBookUid(info.id);
      if (row != null && isAnimeSourceVideoPath(row.videoPath)) {
        online.add(info.id);
      }
    }
    if (online.isEmpty) return 0;
    return repository.deleteVideoBooksAndReclaimAssets(online);
  }

  /// 下载完成：把 [file] 登记成本地视频行（同 bookUid 覆盖在线行），归进作品合集，
  /// 补封面与默认字幕，并把在线播放留下的断点接过来（见 [onlinePositionReader]）。
  Future<void> registerDownloaded(
    AnimeSourceVideoClient client,
    RemoteVideoInfo info,
    File file,
  ) async {
    final VideoBookRow? existing = await repository.getByBookUid(info.id);
    final ({String? source, String? format}) subtitle =
        await _downloadDefaultSubtitle(client, info, file);
    final bool hasSubtitle = subtitle.source != null;
    // 在线看过的断点（prefs）比行上的新就接到行上：没进库时在作品页在线看、或进库
    // 后仍从作品页在线看，进度只落 prefs，行上是 0 / 更旧的值——本地播放只读行。
    final AnimeOnlinePosition? online = onlinePositionReader?.call(info.id);
    final AnimeOnlinePosition? adopted =
        online != null &&
            online.positionMs > 0 &&
            (existing == null ||
                existing.lastPositionMs <= 0 ||
                (existing.lastPlayedAt ?? 0) < online.playedAt)
        ? online
        : null;
    await repository.saveVideoBook(
      VideoBooksCompanion(
        bookUid: Value<String>(info.id),
        title: Value<String>(info.title),
        videoPath: Value<String>(file.path),
        // 已是本地文件：不再是流媒体书，重开规格清掉。
        streamSpecJson: const Value<String?>(null),
        // 源没有默认字幕轨时保留行上原有的字幕（用户在线时挂的外挂字幕等），
        // 不拿 null 盖掉。
        subtitleSource: hasSubtitle
            ? Value<String?>(subtitle.source)
            : const Value<String?>.absent(),
        subtitleFormat: hasSubtitle
            ? Value<String?>(subtitle.format)
            : const Value<String?>.absent(),
        lastPositionMs: adopted != null
            ? Value<int>(adopted.positionMs)
            : const Value<int>.absent(),
        lastPlayedAt: adopted != null && adopted.playedAt > 0
            ? Value<int?>(adopted.playedAt)
            : const Value<int?>.absent(),
        importedAt: Value<int?>(
          existing?.importedAt ?? DateTime.now().millisecondsSinceEpoch,
        ),
      ),
    );
    await RemoteCollectionAdoptionService(database).adoptVideo(info);
    if (existing?.coverPath == null) {
      await _applyCovers(client, <String>[info.id]);
    }
  }

  AnimeSourceBookSpec _specFor(
    AnimeSourceVideoClient client,
    MihonEpisode episode,
  ) => AnimeSourceBookSpec(
    extensionPackage: client.context.source.extensionPackage,
    sourceId: client.context.source.id,
    anime: client.anime,
    episode: episode,
  );

  /// 默认字幕轨（与起播同一个挑法）落到视频旁；源没有字幕轨 / 取不到时不挂。
  Future<({String? source, String? format})> _downloadDefaultSubtitle(
    AnimeSourceVideoClient client,
    RemoteVideoInfo info,
    File video,
  ) async {
    try {
      final String? name = await client.defaultSubtitleFileName(info.id);
      if (name == null) return (source: null, format: null);
      final File dest = File(
        p.join(
          video.parent.path,
          '${p.basenameWithoutExtension(video.path)}${p.extension(name)}',
        ),
      );
      await client.getRemoteVideoSubtitle(info.id, dest);
      if (!await dest.exists() || await dest.length() == 0) {
        return (source: null, format: null);
      }
      final String ext = p.extension(dest.path).replaceFirst('.', '');
      return (source: dest.path, format: ext.isEmpty ? null : ext);
    } on Object catch (error) {
      debugPrint('[anime-library] subtitle for ${info.id} failed: $error');
      return (source: null, format: null);
    }
  }

  /// 作品封面经扩展取（防盗链站点裸 GET 是空图），**每部作品落一份**
  /// （[animeSourceWorkCoverFileName]），本作品各集行的 `coverPath` 都指向它；合集
  /// 还没有自有封面时再拷一份给合集。作品封面已在盘上就不再联网取、只回写新行的指针。
  ///
  /// 共用一个文件是安全的：删行回收（`VideoBookRepository.deleteVideoBooksAndReclaimAssets`
  /// → `VideoStorage.deleteBookAssets`）只删**不再被任何幸存行引用**的封面路径，孤儿
  /// GC（`VideoStorage.gcOrphanCovers`）也保留全库仍引用的路径——作品里还剩一集行，
  /// 文件就在；最后一集的行删掉才回收。用户给某一集手选封面落的是那一集自己的
  /// 路径，不动共用文件。
  ///
  /// 文件名按作品身份哈希定长（作品 URL 可以很长，拼进文件名会撞 Windows 路径上限）。
  /// 写文件与回写各行指针在 [VideoCoverMutationGate] 里一起做：与删行回收 / 孤儿 GC
  /// 互斥，GC 不会在「文件已写、指针未落」的窗口把新图当孤儿收走；联网取图在门外。
  /// 取不到 / 写不进封面都不算入库失败（库页退回占位），失败记错误日志。
  Future<void> _applyCovers(
    AnimeSourceVideoClient client,
    List<String> bookUids,
  ) async {
    final String? coverUrl = client.anime.coverUrl;
    if (coverUrl == null || coverUrl.isEmpty || bookUids.isEmpty) return;
    try {
      final Directory covers = await VideoStorage.coversDir();
      final String workCover = p.join(
        covers.path,
        animeSourceWorkCoverFileName(client),
      );
      // 已有作品封面：只回写指针。没有（或刚被回收）才联网取一次再写。
      if (await _pointAtWorkCover(client, bookUids, workCover)) return;
      final Uint8List bytes = await client.fetchRemoteCover(coverUrl);
      if (bytes.isEmpty) return;
      await _pointAtWorkCover(client, bookUids, workCover, bytes: bytes);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('AnimeSourceLibrary.cover', error, stack);
    }
  }

  /// 在封面写锁里：有 [bytes] 就先写作品封面文件；文件不在（且没有字节可写）返回
  /// false 交给调用方联网取。随后回写 [bookUids] 的指针，合集没有自有封面时拷一份。
  Future<bool> _pointAtWorkCover(
    AnimeSourceVideoClient client,
    List<String> bookUids,
    String workCover, {
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
        final MediaCollectionRow? collection = await database
            .getMediaCollectionByNaturalKey(client.anime.title, 'playlist');
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

/// 一部在线作品的共用封面文件名：`anime_source_<sha1(扩展包|源|作品 URL)>.jpg`。
/// 定长（作品 URL 可以很长）、按作品身份稳定（同一部作品重复入库落同一个文件）。
String animeSourceWorkCoverFileName(AnimeSourceVideoClient client) {
  final String identity =
      '${client.context.source.extensionPackage}\n'
      '${client.context.source.id}\n'
      '${client.anime.url}';
  return 'anime_source_${sha1.convert(utf8.encode(identity))}.jpg';
}

/// 从媒体库重开一集在线行：按行里的规格重建 [AnimeSourceVideoClient]（不联网拉剧集），
/// 合集里同一作品的其它在线行作为连播成员。
///
/// [playlistCollectionId] 是库页 / 合集详情打开时传的合集；为空时只有这一集。
/// 扩展被卸载 / 停用时抛 [AnimeSourceLaunchUnavailable]，播放页据此给明确提示。
Future<
  ({
    AnimeSourceVideoClient client,
    RemoteVideoInfo info,
    List<RemoteVideoInfo> members,
    int startIndex,
  })
>
buildAnimeSourceLaunch({
  required VideoBookRow row,
  required FushiDatabase database,
  required VideoBookRepository repository,
  required MihonManager manager,
  int? playlistCollectionId,
  String? Function()? subtitleLanguageResolver,
}) async {
  final AnimeSourceBookSpec? spec = AnimeSourceBookSpec.tryParse(
    row.streamSpecJson,
  );
  if (spec == null) {
    throw const AnimeSourceLaunchUnavailable('missing anime-source spec');
  }
  final List<({String bookUid, MihonEpisode episode})> members =
      <({String bookUid, MihonEpisode episode})>[];
  if (playlistCollectionId != null) {
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
      if (member == null || !isAnimeSourceVideoPath(member.videoPath)) {
        continue;
      }
      final AnimeSourceBookSpec? memberSpec = AnimeSourceBookSpec.tryParse(
        member.streamSpecJson,
      );
      if (memberSpec == null || !memberSpec.sameWorkAs(spec)) continue;
      members.add((bookUid: member.bookUid, episode: memberSpec.episode));
    }
  }
  if (!members.any(
    (({String bookUid, MihonEpisode episode}) m) => m.bookUid == row.bookUid,
  )) {
    members
      ..clear()
      ..add((bookUid: row.bookUid, episode: spec.episode));
  }
  // 起播只要本地已装的扩展与源行：只读库（reload），不走 initialise()——那条会
  // 联网刷新仓库索引（慢网 / 仓库站点不通时一挂就是几十秒），扩展装没装跟它无关。
  // 真实 app 里 manager 首次取用时已在后台跑 initialise，这里不等它。
  await manager.reload();
  MangaOnlineSourceRow? sourceRow;
  for (final MangaOnlineSourceRow candidate in manager.sources) {
    if (candidate.extensionPackage == spec.extensionPackage &&
        candidate.sourceId == spec.sourceId &&
        candidate.enabled) {
      sourceRow = candidate;
      break;
    }
  }
  if (sourceRow == null) {
    throw AnimeSourceLaunchUnavailable(
      'extension ${spec.extensionPackage} / source ${spec.sourceId} '
      'is not installed or enabled',
    );
  }
  final MihonSourceContext context;
  try {
    context = await manager.contextForSource(sourceRow);
  } on Object catch (error) {
    throw AnimeSourceLaunchUnavailable('$error');
  }
  final AnimeSourceVideoClient client = AnimeSourceVideoClient(
    manager: manager,
    context: context,
    anime: spec.anime,
    episodes: <MihonEpisode>[
      for (final ({String bookUid, MihonEpisode episode}) m in members)
        m.episode,
    ],
    episodeIds: <String>[
      for (final ({String bookUid, MihonEpisode episode}) m in members)
        m.bookUid,
    ],
    subtitleLanguageResolver: subtitleLanguageResolver,
  );
  final List<RemoteVideoInfo> infos = client.remoteVideos;
  final int startIndex = infos.indexWhere(
    (RemoteVideoInfo info) => info.id == row.bookUid,
  );
  return (
    client: client,
    info: infos[startIndex < 0 ? 0 : startIndex],
    members: infos,
    startIndex: startIndex < 0 ? 0 : startIndex,
  );
}

/// 在线行重开不了：扩展被卸载 / 停用，或行上的规格坏了。
class AnimeSourceLaunchUnavailable implements Exception {
  const AnimeSourceLaunchUnavailable(this.message);

  final String message;

  @override
  String toString() => 'AnimeSourceLaunchUnavailable: $message';
}

/// 下载落点文件名：可读标签 + 集 id 的哈希（与互联下载同一命名口径：标题只为好认，
/// 哈希把落点钉在身份上，同名的两集不会共用一个 `.part`）。
String animeEpisodeDownloadFileName(
  AnimeSourceVideoClient client,
  RemoteVideoInfo info,
) {
  final MihonEpisode? episode = client.episodeForVideoId(info.id);
  String stem = episode == null
      ? info.title
      : animeSourceEpisodeLabel(client.anime, episode);
  stem = safeWindowsFileName(stem).trim();
  if (stem.length > 80) stem = stem.substring(0, 80);
  final String hash = sha1
      .convert(utf8.encode(info.id))
      .toString()
      .substring(0, 10);
  return stem.isEmpty ? '$hash.mp4' : '$stem.$hash.mp4';
}

/// 把若干集交给 app 级下载管理器（任务出现在「浏览 › 下载」，切页 / 退出作品页
/// 仍在推进）。串行下载：同一个源站并发拉多集既慢又容易被限流。
///
/// 下载用**专属的** client 副本：作品页退出时会释放自己的 client，下载不能跟着断。
/// 副本在这一批全部结束后释放。已在跑的集跳过；已经下完的集（落点文件已在——
/// 管理器里任务已完成、只是作品页的库状态还没刷新，或上次下完还没来得及登记进程
/// 就被杀了）不重下，只在库里还不是本地行时补登记。
Future<void> startAnimeEpisodeDownloads({
  required InterconnectDownloadManager manager,
  required AnimeSourceLibrary library,
  required AnimeSourceVideoClient template,
  required List<String> episodeIds,
  Directory? destinationDirectory,
}) async {
  final AnimeSourceVideoClient client = template.copyForDownload();
  final Directory dir =
      destinationDirectory ??
      Directory(
        p.join((await AppPaths.remoteVideosDirectory()).path, 'anime_sources'),
      );
  await dir.create(recursive: true);
  final Map<String, RemoteVideoInfo> byId = <String, RemoteVideoInfo>{
    for (final RemoteVideoInfo info in client.remoteVideos) info.id: info,
  };
  try {
    await manager.holdKeepAliveDuring(() async {
      for (final String id in episodeIds) {
        final RemoteVideoInfo? info = byId[id];
        if (info == null || manager.isRunning(id)) continue;
        final File dest = File(
          p.join(dir.path, animeEpisodeDownloadFileName(client, info)),
        );
        // 落点只在下载成功时由 `.part` / 分片流换名而来：它在就是这一集已经下完。
        if (await dest.exists()) {
          try {
            final VideoBookRow? row = await library.repository.getByBookUid(id);
            if (row == null || isNetworkOnlyVideoPath(row.videoPath)) {
              await library.registerDownloaded(client, info, dest);
            }
          } on Object catch (error, stack) {
            ErrorLogService.instance.log(
              'startAnimeEpisodeDownloads.register',
              error,
              stack,
            );
          }
          continue;
        }
        try {
          await manager.startVideoDownload(
            id: id,
            title: info.title,
            dest: dest,
            run:
                (
                  File target, {
                  void Function(double progress)? onProgress,
                  void Function(int received, int? total)? onBytes,
                  Future<void>? cancelSignal,
                }) => client.downloadRemoteVideo(
                  id,
                  target,
                  onProgress: onProgress,
                  onBytes: onBytes,
                  cancelSignal: cancelSignal,
                ),
            onComplete: (File downloaded) =>
                library.registerDownloaded(client, info, downloaded),
          );
        } on RemoteDownloadCancelled {
          // 用户在下载中心暂停了这一集：留在暂停态，接着下一集。
          continue;
        } on Object catch (error) {
          // 失败原因已落在任务快照里（下载中心可见、可重试）；不挡后面的集。
          debugPrint('[anime-download] $id failed: $error');
          continue;
        }
      }
    });
  } finally {
    // 暂停 / 失败的任务之后从下载中心「继续 / 重试」时，管理器仍握着这批 run 闭包：
    // 副本不能在这里立刻释放，交给 GC（http 客户端空闲连接会自己超时关掉）。
    if (episodeIds.every(
      (String id) =>
          manager.taskFor(id)?.isRunning != true &&
          manager.taskFor(id)?.isPaused != true &&
          manager.taskFor(id)?.status != InterconnectDownloadStatus.failed,
    )) {
      client.dispose();
    }
  }
}
