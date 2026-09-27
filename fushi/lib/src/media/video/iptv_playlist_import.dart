/// M3U / IPTV 频道列表导入（对齐 SenPlayer 的「IPTV 播放列表」）。
///
/// 不另造存储：每个频道一行 `VideoBooks`（`videoPath` = 频道流地址，播放走既有
/// 流媒体书链路），整份列表（或按 `group-title` 分组后的每一组）一个 `playlist`
/// 合集。
///
/// **身份按列表来源，不按名字**（审查阻断项）：
/// - 频道行的 bookUid 落在 `video/iptv/<来源摘要>-<频道地址摘要>` 命名空间
///   （[iptvChannelBookUid]）。来源 = 远端列表的归一 URL / 本地列表的归一路径
///   （[IptvPlaylistSource.sourceKey]）；频道 = 完整归一地址（[normalizeIptvUrl]）。
///   于是「这一行是哪份列表建的」「这一行对应哪条地址」都能从 uid 直接判定，
///   不靠文件名（大量频道地址都叫 `index.m3u8` / `playlist.m3u8`）也不靠合集名
///   （Xtream 的 `get.php?...` 列表名一律 `get`）。
/// - 某份列表的合集 = 含有该来源频道行的 playlist 合集。重复导入同一来源只对齐
///   这些合集；别的来源、用户自己的同名合集一个都不碰。新建合集时名字与已有
///   playlist 合集撞了就加序号（合集按 `(name, type)` 自然键复用与跨端同步，同名
///   必然串到别人的合集里）。
/// - 频道地址轮换（token / 签名变了）= 新地址新行；清单里已不存在的本来源频道行
///   从本来源合集解绑，且没有被用户放进其它合集时整行删除（不留孤儿行）。
///
/// HLS 媒体 / master 播放列表（[isHlsStreamPlaylist]）是**单条流**，不在这里拆：
/// 调用方把它当普通直链交给流导入。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
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
import 'package:fushi_engine/media/video/strm_file.dart'
    show isNetworkStreamUrl;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart'
    show videoCoverFileName;
import 'package:fushi_engine/media/video/video_storage.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart' show isDirectProxyTarget;
import 'package:fushi_engine/utils/net/bounded_read.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// 频道列表的读取上限（字节）。大型 IPTV 聚合列表也就几 MB；超过的多半不是
/// 列表（误填成视频直链），边读边计数、超限即停（[readBoundedBytes]）。
const int kIptvPlaylistMaxBytes = 16 * 1024 * 1024;

/// 单张台标的下载上限（字节）。
const int kIptvLogoMaxBytes = 2 * 1024 * 1024;

/// 一次导入最多下载的**不同**台标地址数（同一地址只下一次）。几千频道的聚合
/// 列表不该在后台连发几千个请求；超出的频道留占位，之后刮削 / 手动换封面照常。
const int kIptvLogoMaxDownloads = 300;

String _digest12(String s) =>
    sha1.convert(utf8.encode(s)).toString().substring(0, 12);

/// 纯函数：频道 / 列表地址的比较键——scheme 与 host 小写、去掉默认端口与
/// fragment，path 与 query **原样保留**（签名 token、Xtream 的
/// `username=…&password=…` 都是身份的一部分）。解析不出的地址按去空白原样返回。
String normalizeIptvUrl(String url) {
  final String trimmed = url.trim();
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return trimmed;
  return uri.removeFragment().toString();
}

/// 纯函数：列表来源身份。远端 = [normalizeIptvUrl]；本地 = 归一绝对路径。
String iptvPlaylistSourceKey({String? url, String? localPath}) {
  if (url != null && url.trim().isNotEmpty) return normalizeIptvUrl(url);
  final String path = (localPath ?? '').trim();
  return normalizeVideoPath(path.isEmpty ? path : p.absolute(path));
}

/// 纯函数：来源 [sourceKey] 建出的全部频道行共用的 bookUid 前缀。
String iptvSourceBookUidPrefix(String sourceKey) =>
    '$kIptvChannelBookUidPrefix${_digest12(sourceKey)}-';

/// 纯函数：来源 [sourceKey] 里地址为 [channelUrl] 的频道行 bookUid。
String iptvChannelBookUid(String sourceKey, String channelUrl) =>
    '${iptvSourceBookUidPrefix(sourceKey)}'
    '${_digest12(normalizeIptvUrl(channelUrl))}';

/// 一份 M3U 文本的性质（决定走哪条导入路径）。
enum M3uPlaylistKind {
  /// 频道 / 条目列表：拆成多条流入库。
  channelList,

  /// HLS 媒体 / master 播放列表：单条流，按直链导入。
  hlsStream,

  /// 没有任何（可接受的）条目。
  empty,
}

/// 纯函数：判定 [content] 是频道列表、HLS 流还是空列表。[baseDir] 与导入时
/// 一致（远端列表传 URL 目录）：远端列表里被解析层拒收的本地条目不算频道。
M3uPlaylistKind classifyM3uPlaylist(String content, {String baseDir = ''}) {
  if (isHlsStreamPlaylist(content)) return M3uPlaylistKind.hlsStream;
  final List<M3uChannel> channels =
      parseM3uChannels(content: content, baseDir: baseDir);
  return channels.isEmpty ? M3uPlaylistKind.empty : M3uPlaylistKind.channelList;
}

/// 读到的一份频道列表：正文 + 解析相对条目用的基址 + 默认列表名 + 来源。
class IptvPlaylistSource {
  const IptvPlaylistSource({
    required this.content,
    required this.baseDir,
    required this.listName,
    this.url,
    this.localPath,
  });

  final String content;

  /// 相对条目的解析基址（本地 = 文件所在目录；远端 = URL 所在目录）。
  final String baseDir;

  /// 默认列表名（文件名 / URL 末段，去扩展名；通用脚本名退回 host）。
  final String listName;

  /// 远端列表的原始地址；本地文件为 null。
  final String? url;

  /// 本地列表文件路径；远端为 null。
  final String? localPath;

  /// 远端列表（内容由第三方决定）：只接受网络流频道，台标不打本机 / 内网。
  bool get isRemote => url != null;

  /// 来源身份（[iptvPlaylistSourceKey]）：重复导入按它找回同一份列表的合集。
  String get sourceKey => iptvPlaylistSourceKey(url: url, localPath: localPath);
}

/// URL 末段是这些「通用」名字时它不是列表名（`get.php?username=…` 这类 Xtream
/// 接口、`playlist.m3u` / `index.m3u8`），退回 host。
const Set<String> _kGenericListNames = <String>{
  'get',
  'index',
  'playlist',
  'list',
};

/// URL 末段是这些动态脚本扩展名时退回 host。
const Set<String> _kScriptExtensions = <String>{
  '.php',
  '.asp',
  '.aspx',
  '.jsp',
  '.cgi',
  '.pl',
  '.py',
};

/// 纯函数：列表名——取末段去扩展名；末段是通用接口名 / 动态脚本、或取不到时
/// 回退 host；再不行回退 `IPTV`。列表名只是显示名，**不是**身份（身份见
/// [IptvPlaylistSource.sourceKey]）。
String iptvPlaylistNameFromLocation(String location) {
  final String trimmed = location.trim();
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
    final List<String> segs =
        uri.pathSegments.where((String s) => s.isNotEmpty).toList();
    if (segs.isNotEmpty) {
      final String last = decodedSourceBasename(segs.last);
      final String name = p.basenameWithoutExtension(last);
      final bool generic =
          _kScriptExtensions.contains(p.extension(last).toLowerCase()) ||
              _kGenericListNames.contains(name.toLowerCase());
      if (name.isNotEmpty && !generic) return name;
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

/// 读本地频道列表文件（编码探测与字幕 / 清单导入同一套）。超过
/// [kIptvPlaylistMaxBytes] 抛 [BodyTooLargeException]。
Future<IptvPlaylistSource> readLocalIptvPlaylist(String path) async {
  final File file = File(path);
  if (await file.length() > kIptvPlaylistMaxBytes) {
    throw const BodyTooLargeException(kIptvPlaylistMaxBytes);
  }
  final String content = await readTextWithEncoding(file);
  return IptvPlaylistSource(
    content: content,
    baseDir: p.dirname(path),
    listName: iptvPlaylistNameFromLocation(path),
    localPath: path,
  );
}

/// 下载远端频道列表（经全应用代理装配的 http client）。非 2xx 抛
/// [HttpException]；正文边读边计数，超过 [kIptvPlaylistMaxBytes] 抛
/// [BodyTooLargeException]（连接随即放弃，不会先把整份正文读进内存）。
Future<IptvPlaylistSource> fetchRemoteIptvPlaylist(
  String url, {
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final Uri uri = Uri.parse(url.trim());
  final http.Client client = httpClient ?? createAppHttpIoClient();
  try {
    final http.StreamedResponse res =
        await client.send(http.Request('GET', uri)).timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      unawaited(res.stream.listen(null).cancel());
      throw HttpException('HTTP ${res.statusCode}', uri: uri);
    }
    final List<int> bytes =
        await readBoundedBytes(res.stream, kIptvPlaylistMaxBytes)
            .timeout(timeout);
    return IptvPlaylistSource(
      content: utf8.decode(bytes, allowMalformed: true),
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

/// 纯函数：导入层兜底过滤。远端列表（[remote]）只收网络流频道——解析层
/// （[resolveM3uEntryPath]）已经拒收远端列表里的本地 / UNC / `file://` 条目，这里
/// 防的是绕过解析层直接喂频道的调用方。空地址一律丢。
List<M3uChannel> acceptedIptvChannels(
  List<M3uChannel> channels, {
  required bool remote,
}) =>
    <M3uChannel>[
      for (final M3uChannel c in channels)
        if (c.url.trim().isNotEmpty && (!remote || isNetworkStreamUrl(c.url)))
          c,
    ];

/// [importIptvChannels] 的结果。
class IptvPlaylistImportResult {
  const IptvPlaylistImportResult({
    required this.collectionIds,
    required this.channelCount,
    this.firstBookUid,
    this.removedChannelCount = 0,
  });

  /// 本来源当前对应的合集（按分组顺序）。
  final List<int> collectionIds;

  /// 实际入库（通过兜底过滤）的频道数。
  final int channelCount;

  /// 首个新建合集的首个频道 uid（活动时间轴 / 回书架定位用）；全部是对齐已有
  /// 合集时为 null。
  final String? firstBookUid;

  /// 本次从本来源合集移出的频道行数（清单里已没有的旧地址）。
  final int removedChannelCount;
}

/// 在 [taken] 里给 [name] 找一个没被占用的合集名（`name` / `name (2)` / …）。
String _uniqueCollectionName(String name, Set<String> taken) {
  if (!taken.contains(name)) return name;
  for (int i = 2;; i++) {
    final String candidate = '$name ($i)';
    if (!taken.contains(candidate)) return candidate;
  }
}

/// 把 [channels] 按分组落成 [source] 这份列表的 playlist 合集（身份规则见文件头）。
Future<IptvPlaylistImportResult> importIptvChannels({
  required FushiDatabase db,
  required VideoBookRepository repo,
  required IptvPlaylistSource source,
  required List<M3uChannel> channels,
}) async {
  final List<M3uChannel> accepted =
      acceptedIptvChannels(channels, remote: source.isRemote);
  final String sourceKey = source.sourceKey;
  final String prefix = iptvSourceBookUidPrefix(sourceKey);
  final String videoType = MediaKind.video.dbValue;
  final List<IptvChannelGroup> groups =
      groupIptvChannels(accepted, source.listName);

  final List<int> ids = <int>[];
  String? firstUid;
  int removed = 0;
  Set<String> staleUids = <String>{};

  await db.transaction(() async {
    final List<MediaCollectionRow> collections =
        await db.getAllMediaCollections();
    final Map<int, List<MediaCollectionItemRow>> itemsByCollection =
        <int, List<MediaCollectionItemRow>>{};
    for (final MediaCollectionItemRow item
        in await db.getAllCollectionItems()) {
      (itemsByCollection[item.collectionId] ??= <MediaCollectionItemRow>[])
          .add(item);
    }
    bool ownsMember(MediaCollectionItemRow i) =>
        i.mediaType == videoType && i.entryKey.startsWith(prefix);
    // 本来源的合集：含有本来源频道行的 playlist 合集。别的合集（其它来源、
    // 用户自己的同名合集）不在其列，下面一个都不碰。
    final List<MediaCollectionRow> owned = <MediaCollectionRow>[
      for (final MediaCollectionRow c in collections)
        if (c.collectionType == 'playlist' &&
            (itemsByCollection[c.id] ?? const <MediaCollectionItemRow>[])
                .any(ownsMember))
          c,
    ];
    final Set<String> playlistNames = <String>{
      for (final MediaCollectionRow c in collections)
        if (c.collectionType == 'playlist') c.name,
    };

    // 分组 → 既有合集：先按名字配；剩下恰好各一个时（用户改过合集名、列表仍是
    // 单分组）直接配对。其余分组新建。
    final List<MediaCollectionRow?> targets =
        List<MediaCollectionRow?>.filled(groups.length, null);
    final List<MediaCollectionRow> unmatched =
        List<MediaCollectionRow>.of(owned);
    for (int i = 0; i < groups.length; i++) {
      final int hit = unmatched.indexWhere(
          (MediaCollectionRow c) => c.name == groups[i].collectionName);
      if (hit >= 0) targets[i] = unmatched.removeAt(hit);
    }
    final List<int> unpaired = <int>[
      for (int i = 0; i < groups.length; i++)
        if (targets[i] == null) i,
    ];
    if (unpaired.length == 1 && unmatched.length == 1) {
      targets[unpaired.single] = unmatched.removeAt(0);
    }

    final Set<String> existingOwnUids = <String>{
      for (final VideoBookRow row in await db.allVideoBooks())
        if (row.bookUid.startsWith(prefix)) row.bookUid,
    };
    final Set<String> desiredAll = <String>{};
    final int nowMs = DateTime.now().millisecondsSinceEpoch;

    for (int i = 0; i < groups.length; i++) {
      final IptvChannelGroup group = groups[i];
      // 本分组的频道行（同一地址在组内重复只算一次），缺的行现建。
      final List<String> desired = <String>[];
      final Set<String> desiredSet = <String>{};
      for (final M3uChannel c in group.channels) {
        final String uid = iptvChannelBookUid(sourceKey, c.url);
        if (!desiredSet.add(uid)) continue;
        desired.add(uid);
        if (existingOwnUids.add(uid)) {
          await repo.saveVideoBook(VideoBooksCompanion(
            bookUid: Value(uid),
            title: Value(c.title),
            videoPath: Value(c.url),
            embeddedSubtitleTrack: const Value<int?>(0),
            importedAt: Value(nowMs),
          ));
        }
      }
      desiredAll.addAll(desired);

      final MediaCollectionRow? target = targets[i];
      final bool created = target == null;
      final int collectionId;
      if (target == null) {
        final String name =
            _uniqueCollectionName(group.collectionName, playlistNames);
        playlistNames.add(name);
        collectionId =
            await db.createMediaCollection(name, collectionType: 'playlist');
      } else {
        collectionId = target.id;
      }
      ids.add(collectionId);

      // 先加后删：合集绝不瞬时变空（移空会被自动删掉）。
      final List<MediaCollectionItemRow> current =
          itemsByCollection[collectionId] ?? const <MediaCollectionItemRow>[];
      final Set<String> currentKeys = <String>{
        for (final MediaCollectionItemRow item in current)
          if (item.mediaType == videoType) item.entryKey,
      };
      int added = 0;
      for (final String uid in desired) {
        if (currentKeys.contains(uid)) continue;
        await db.addToCollection(collectionId, MediaKind.video, uid);
        added++;
      }
      for (final MediaCollectionItemRow item in current) {
        if (!ownsMember(item) || desiredSet.contains(item.entryKey)) continue;
        await db.removeFromCollection(
            collectionId, MediaKind.video, item.entryKey);
        removed++;
      }
      // 有新频道加入时按列表顺序排本来源的成员（其余成员的相对位置不动）。
      if (added > 0 && !created) {
        await db.reorderCollectionItemsAutomatically(
          collectionId,
          <CollectionMemberKey>[
            for (final String uid in desired)
              (mediaType: videoType, entryKey: uid),
          ],
        );
      }
      if (created && desired.isNotEmpty) firstUid ??= desired.first;
    }

    // 清单里已没有对应分组的本来源合集：移出本来源的频道（移空即随之删除）。
    for (final MediaCollectionRow c in unmatched) {
      for (final MediaCollectionItemRow item
          in itemsByCollection[c.id] ?? const <MediaCollectionItemRow>[]) {
        if (!ownsMember(item)) continue;
        await db.removeFromCollection(c.id, MediaKind.video, item.entryKey);
        removed++;
      }
    }
    staleUids = existingOwnUids.difference(desiredAll);
  });

  // 不在新清单里的本来源频道行：已经不属于任何合集（没被用户放进别的合集）
  // 的整行删除，连同台标封面等 app 自有资产；仍被其它合集引用的保留。
  if (staleUids.isNotEmpty) {
    final Set<String> referenced = <String>{
      for (final MediaCollectionItemRow item
          in await db.getAllCollectionItems())
        if (item.mediaType == videoType) item.entryKey,
    };
    final List<String> orphans = <String>[
      for (final String uid in staleUids)
        if (!referenced.contains(uid)) uid,
    ];
    if (orphans.isNotEmpty) {
      try {
        await repo.deleteVideoBooksAndReclaimAssets(
          orphans,
          compactDatabase: false,
        );
      } on StateError {
        // 刮削资料维护正占着操作门：资产回收要等门，行本身不能等——先只删行，
        // 封面文件留给下次维护的孤儿清理。
        for (final String uid in orphans) {
          await repo.deleteVideoBook(uid);
        }
      }
    }
  }

  return IptvPlaylistImportResult(
    collectionIds: ids,
    channelCount: accepted.length,
    firstBookUid: firstUid,
    removedChannelCount: removed,
  );
}

/// 台标下载任务的取消令牌。
class IptvLogoCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

final Map<String, IptvLogoCancelToken> _activeLogoJobs =
    <String, IptvLogoCancelToken>{};

/// 为来源 [sourceKey] 开一个台标任务：同一来源上一个还没跑完的任务先取消
/// （重复导入同一列表不叠两路后台下载）。
IptvLogoCancelToken beginIptvLogoJob(String sourceKey) {
  _activeLogoJobs.remove(sourceKey)?.cancel();
  final IptvLogoCancelToken token = IptvLogoCancelToken();
  _activeLogoJobs[sourceKey] = token;
  return token;
}

/// 取消所有在跑的台标任务。
void cancelAllIptvLogoJobs() {
  for (final IptvLogoCancelToken token in _activeLogoJobs.values) {
    token.cancel();
  }
  _activeLogoJobs.clear();
}

/// 纯函数：台标地址是否允许下载。只收 http(s)；远端列表（[remoteSource]）的
/// 台标不打回环 / 私网 / `.local` 目标（判据同代理直连闸门 [isDirectProxyTarget]）
/// ——第三方写的列表不该能驱使本机去探内网服务。
bool isIptvLogoUrlAllowed(String? url, {required bool remoteSource}) {
  if (url == null) return false;
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return false;
  final String scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;
  return !(remoteSource && isDirectProxyTarget(uri.host));
}

/// 用频道的 `tvg-logo` 给 [source] 这份列表还没有封面的频道行补封面
/// （best-effort，返回补上的行数）。
///
/// - 同一台标地址只下载一次，结果分给所有用它的频道；最多下载
///   [maxDownloads] 个不同地址，单张不超过 [kIptvLogoMaxBytes]（边读边计数）。
/// - [cancelToken] 被取消时在下一张之前停下（见 [beginIptvLogoJob]）。
/// - 下载在封面互斥门**之外**进行（带超时，死掉的台标主机不能卡住全局门）；只有
///   落盘 + 写 DB 指针 + provenance 提交在 [VideoCoverMutationGate] 里，并且先过
///   [VideoScrapeOperationGate]（维护中不写自动封面）。台标记为「自动」封面：之后
///   刮削 / 手动换封面照常可以覆盖它。
Future<int> applyIptvChannelLogos({
  required VideoBookRepository repo,
  required IptvPlaylistSource source,
  required List<M3uChannel> channels,
  IptvLogoCancelToken? cancelToken,
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 10),
  int maxDownloads = kIptvLogoMaxDownloads,
}) async {
  final String sourceKey = source.sourceKey;
  // 台标地址 → 用它的频道行（保持首次出现顺序，同一行只记一次）。
  final Map<String, List<String>> uidsByLogo = <String, List<String>>{};
  for (final M3uChannel c in channels) {
    final String? logo = c.tvgLogo?.trim();
    if (!isIptvLogoUrlAllowed(logo, remoteSource: source.isRemote)) continue;
    final List<String> uids = uidsByLogo[logo!] ??= <String>[];
    final String uid = iptvChannelBookUid(sourceKey, c.url);
    if (!uids.contains(uid)) uids.add(uid);
  }
  if (uidsByLogo.isEmpty) return 0;
  final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
    for (final VideoBookRow r in await repo.listAll())
      if (r.bookUid.startsWith(kIptvChannelBookUidPrefix)) r.bookUid: r,
  };
  final Directory coverDir = await VideoStorage.coversDir();
  await coverDir.create(recursive: true);
  final CoverMetaStore store = CoverMetaStore(coverDir);
  final http.Client client = httpClient ?? createAppHttpIoClient();
  int applied = 0;
  int downloads = 0;
  try {
    for (final MapEntry<String, List<String>> e in uidsByLogo.entries) {
      if (cancelToken?.isCancelled ?? false) break;
      final List<VideoBookRow> needing = <VideoBookRow>[
        for (final String uid in e.value)
          if (byUid[uid] case final VideoBookRow row
              when (row.coverPath ?? '').isEmpty)
            row,
      ];
      if (needing.isEmpty) continue;
      if (downloads >= maxDownloads) break;
      downloads++;
      final List<int>? bytes = await _downloadLogo(client, e.key, timeout);
      if (bytes == null) continue;
      if (cancelToken?.isCancelled ?? false) break;
      for (final VideoBookRow row in needing) {
        final VideoScrapeOperationLease? lease =
            VideoScrapeOperationGate.tryEnterOperation();
        if (lease == null) return applied;
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
    }
  } finally {
    if (httpClient == null) client.close();
  }
  return applied;
}

Future<List<int>?> _downloadLogo(
  http.Client client,
  String url,
  Duration timeout,
) async {
  try {
    final http.StreamedResponse res =
        await client.send(http.Request('GET', Uri.parse(url))).timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      unawaited(res.stream.listen(null).cancel());
      return null;
    }
    final List<int> bytes =
        await readBoundedBytes(res.stream, kIptvLogoMaxBytes).timeout(timeout);
    if (bytes.isEmpty) return null;
    if (!looksLikeImageBytes(bytes, res.headers['content-type'])) {
      return null;
    }
    return bytes;
  } on Object {
    return null;
  }
}
