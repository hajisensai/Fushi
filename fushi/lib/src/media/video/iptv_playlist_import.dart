/// M3U / IPTV 频道列表导入（对齐 SenPlayer 的「IPTV 播放列表」）。
///
/// 不另造存储：频道列表按既有「m3u 清单 → 拆集入库」路径落库——每个频道一行
/// `VideoBooks`（`videoPath` = 频道流地址，播放走既有流媒体书链路），整份列表
/// （或按 `group-title` 分组后的每一组）一个 `playlist` 合集
/// （[VideoBookRepository.importSplitPlaylist]）。重复导入同名列表按
/// [VideoBookRepository.reconcileSplitPlaylist] 对齐成员，不产生重复合集。
///
/// HLS 媒体 / master 播放列表（[isHlsStreamPlaylist]）是**单条流**，不在这里拆：
/// 调用方把它当普通直链交给流导入。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart' show readTextWithEncoding;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/cover_file_writer.dart'
    show writeCoverBytesAtomically;
import 'package:fushi_engine/media/metadata/image_download.dart'
    show looksLikeImageBytes;
import 'package:fushi_engine/media/video/external_video.dart'
    show decodedSourceBasename, normalizeVideoPath;
import 'package:fushi_engine/media/video/m3u8_playlist.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/scraper/cover_meta_store.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart'
    show videoCoverFileName;
import 'package:fushi_engine/media/video/video_storage.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// 远端频道列表的下载上限（字节）。大型 IPTV 聚合列表也就几 MB；超过的多半
/// 不是列表（误填成视频直链），不把它整个读进内存。
const int kIptvPlaylistMaxBytes = 16 * 1024 * 1024;

/// 一份 M3U 文本的性质（决定走哪条导入路径）。
enum M3uPlaylistKind {
  /// 频道 / 条目列表：拆成多条流入库。
  channelList,

  /// HLS 媒体 / master 播放列表：单条流，按直链导入。
  hlsStream,

  /// 没有任何条目。
  empty,
}

/// 纯函数：判定 [content] 是频道列表、HLS 流还是空列表。
M3uPlaylistKind classifyM3uPlaylist(String content) {
  if (isHlsStreamPlaylist(content)) return M3uPlaylistKind.hlsStream;
  final List<M3uChannel> channels =
      parseM3uChannels(content: content, baseDir: '');
  return channels.isEmpty ? M3uPlaylistKind.empty : M3uPlaylistKind.channelList;
}

/// 读到的一份频道列表：正文 + 解析相对条目用的基址 + 默认列表名。
class IptvPlaylistSource {
  const IptvPlaylistSource({
    required this.content,
    required this.baseDir,
    required this.listName,
    this.url,
  });

  final String content;

  /// 相对条目的解析基址（本地 = 文件所在目录；远端 = URL 所在目录）。
  final String baseDir;

  /// 默认列表名（文件名 / URL 末段，去扩展名）。
  final String listName;

  /// 远端列表的原始地址；本地文件为 null。
  final String? url;
}

/// 纯函数：列表名——取末段去扩展名；取不到回退 host；再不行回退 `IPTV`。
String iptvPlaylistNameFromLocation(String location) {
  final String trimmed = location.trim();
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
    final List<String> segs =
        uri.pathSegments.where((String s) => s.isNotEmpty).toList();
    if (segs.isNotEmpty) {
      final String name = p.basenameWithoutExtension(
        decodedSourceBasename(segs.last),
      );
      if (name.isNotEmpty) return name;
    }
    return uri.host;
  }
  final String name = p.basenameWithoutExtension(trimmed);
  return name.isEmpty ? 'IPTV' : name;
}

/// 纯函数：远端列表 URL 的「目录」（相对条目按它解析）。
String iptvPlaylistBaseUrl(String url) {
  final Uri uri = Uri.parse(url.trim());
  final Uri bare = Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path.isEmpty ? '/' : uri.path,
  );
  final String base = bare.resolve('.').toString();
  return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
}

/// 读本地频道列表文件（编码探测与字幕 / 清单导入同一套）。
Future<IptvPlaylistSource> readLocalIptvPlaylist(String path) async {
  final String content = await readTextWithEncoding(File(path));
  return IptvPlaylistSource(
    content: content,
    baseDir: p.dirname(path),
    listName: iptvPlaylistNameFromLocation(path),
  );
}

/// 下载远端频道列表（经全应用代理装配的 http client；超过
/// [kIptvPlaylistMaxBytes] 或非 2xx 抛 [HttpException]）。
Future<IptvPlaylistSource> fetchRemoteIptvPlaylist(
  String url, {
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final http.Client client = httpClient ?? createAppHttpIoClient();
  try {
    final http.Response res =
        await client.get(Uri.parse(url.trim())).timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
    }
    if (res.bodyBytes.length > kIptvPlaylistMaxBytes) {
      throw HttpException('playlist too large', uri: Uri.parse(url));
    }
    return IptvPlaylistSource(
      content: utf8.decode(res.bodyBytes, allowMalformed: true),
      baseDir: iptvPlaylistBaseUrl(url),
      listName: iptvPlaylistNameFromLocation(url),
      url: url.trim(),
    );
  } finally {
    if (httpClient == null) client.close();
  }
}

/// 按 `group-title` 切出的一组频道（= 一个 playlist 合集）。
class IptvChannelGroup {
  const IptvChannelGroup(
      {required this.collectionName, required this.channels});

  final String collectionName;
  final List<M3uChannel> channels;
}

/// 纯函数：把频道按 `group-title` 分组成合集（保持首次出现顺序）。
///
/// 只有一个分组（或全都没写分组）时整份列表就是一个合集，名字 = [listName]；
/// 多个分组时每组一个合集 `<listName> · <group>`，没写分组的频道留在
/// [listName] 合集里。
List<IptvChannelGroup> groupIptvChannels(
  List<M3uChannel> channels,
  String listName,
) {
  final Set<String> groups = <String>{
    for (final M3uChannel c in channels)
      if (c.groupTitle != null) c.groupTitle!,
  };
  if (groups.length <= 1) {
    return <IptvChannelGroup>[
      if (channels.isNotEmpty)
        IptvChannelGroup(collectionName: listName, channels: channels),
    ];
  }
  final Map<String, List<M3uChannel>> byName = <String, List<M3uChannel>>{};
  for (final M3uChannel c in channels) {
    final String? group = c.groupTitle;
    final String name = group == null ? listName : '$listName · $group';
    (byName[name] ??= <M3uChannel>[]).add(c);
  }
  return <IptvChannelGroup>[
    for (final MapEntry<String, List<M3uChannel>> e in byName.entries)
      IptvChannelGroup(collectionName: e.key, channels: e.value),
  ];
}

/// [importIptvChannels] 的结果。
class IptvPlaylistImportResult {
  const IptvPlaylistImportResult({
    required this.collectionIds,
    required this.channelCount,
    this.firstBookUid,
  });

  final List<int> collectionIds;
  final int channelCount;

  /// 首个新建合集的首个频道 uid（活动时间轴 / 回书架定位用）；全部是对齐已有
  /// 合集时为 null。
  final String? firstBookUid;
}

/// 把 [channels] 按分组落成 playlist 合集（见文件头）。同名 playlist 合集已存在
/// 时对齐成员，否则新建；新建时按频道地址复用已入库的行（重复导入不出副本）。
Future<IptvPlaylistImportResult> importIptvChannels({
  required FushiDatabase db,
  required VideoBookRepository repo,
  required String listName,
  required List<M3uChannel> channels,
}) async {
  final Map<String, int> existing = <String, int>{
    for (final MediaCollectionRow c in await db.getAllMediaCollections())
      if (c.collectionType == 'playlist') c.name: c.id,
  };
  final List<int> ids = <int>[];
  String? firstUid;
  for (final IptvChannelGroup group in groupIptvChannels(channels, listName)) {
    final List<PlaylistEntry> entries = <PlaylistEntry>[
      for (final M3uChannel c in group.channels) c.toPlaylistEntry(),
    ];
    final int? existingId = existing[group.collectionName];
    if (existingId != null) {
      await repo.reconcileSplitPlaylist(
        collectionId: existingId,
        entries: entries,
      );
      ids.add(existingId);
      continue;
    }
    final SplitPlaylistImportResult result = await repo.importSplitPlaylist(
      collectionName: group.collectionName,
      entries: entries,
      reuseExistingPaths: true,
    );
    existing[group.collectionName] = result.collectionId;
    ids.add(result.collectionId);
    firstUid ??= result.episodeUids.isEmpty ? null : result.episodeUids.first;
  }
  return IptvPlaylistImportResult(
    collectionIds: ids,
    channelCount: channels.length,
    firstBookUid: firstUid,
  );
}

/// 用频道的 `tvg-logo` 给还没有封面的频道行补封面（best-effort，返回补上的数量）。
///
/// 下载在封面互斥门**之外**进行（带超时，死掉的台标主机不能卡住全局门）；只有
/// 落盘 + 写 DB 指针 + provenance 提交在 [VideoCoverMutationGate] 里，并且与导入
/// 对话框同样先过 [VideoScrapeOperationGate]（维护中不写自动封面）。台标记为
/// 「自动」封面：之后刮削 / 手动换封面照常可以覆盖它。
Future<int> applyIptvChannelLogos({
  required VideoBookRepository repo,
  required List<M3uChannel> channels,
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final List<M3uChannel> withLogo = <M3uChannel>[
    for (final M3uChannel c in channels)
      if (_isHttpUrl(c.tvgLogo)) c,
  ];
  if (withLogo.isEmpty) return 0;
  final Map<String, VideoBookRow> byPath = <String, VideoBookRow>{
    for (final VideoBookRow r in await repo.listAll())
      normalizeVideoPath(r.videoPath): r,
  };
  final Directory coverDir = await VideoStorage.coversDir();
  final CoverMetaStore store = CoverMetaStore(coverDir);
  final http.Client client = httpClient ?? createAppHttpIoClient();
  int applied = 0;
  try {
    for (final M3uChannel c in withLogo) {
      final VideoBookRow? row = byPath[normalizeVideoPath(c.url)];
      if (row == null || (row.coverPath ?? '').isNotEmpty) continue;
      final List<int>? bytes = await _downloadLogo(client, c.tvgLogo!, timeout);
      if (bytes == null) continue;
      final VideoScrapeOperationLease? lease =
          VideoScrapeOperationGate.tryEnterOperation();
      if (lease == null) break;
      try {
        final bool ok = await VideoCoverMutationGate.runExclusive<bool>(
          () async {
            if (!await store.allowsAutoFrameWrite(row.bookUid)) return false;
            final String out =
                p.join(coverDir.path, videoCoverFileName(row.bookUid));
            await writeCoverBytesAtomically(bytes: bytes, destPath: out);
            await repo.updateCover(row.bookUid, out);
            await store.markAutoFrameAfterWrite(row.bookUid);
            return true;
          },
        );
        if (ok) applied++;
      } on Object {
        // 单个台标坏图 / 写盘失败只丢这一张。
      } finally {
        lease.release();
      }
    }
  } finally {
    if (httpClient == null) client.close();
  }
  return applied;
}

bool _isHttpUrl(String? s) =>
    s != null && (s.startsWith('http://') || s.startsWith('https://'));

Future<List<int>?> _downloadLogo(
  http.Client client,
  String url,
  Duration timeout,
) async {
  try {
    final http.Response res = await client.get(Uri.parse(url)).timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    if (res.bodyBytes.isEmpty) return null;
    if (!looksLikeImageBytes(res.bodyBytes, res.headers['content-type'])) {
      return null;
    }
    return res.bodyBytes;
  } on Object {
    return null;
  }
}
