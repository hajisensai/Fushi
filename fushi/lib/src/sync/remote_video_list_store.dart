import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/sync/server_url_credentials.dart';
import 'package:fushi/src/utils/misc/build_version.dart';

/// 媒体服务器远端视频清单的磁盘缓存与重验规则（内存缓存那一侧的读法见
/// `persisted_remote_video_list.dart`）。
///
/// **它是缓存**：文件在 `<app cache>/remote_video_lists/`（系统可随时清掉，不进
/// 备份、不进数据根迁移，里面没有绝对路径）。读坏了、版本不对、作用域不对一律当
/// 没有，下次整库拉完覆盖重写，绝不抛到调用方。
///
/// **一个来源一个文件**（文件名 = 来源身份的 sha1）。文件里不存任何凭据：封面地址
/// 去掉 `api_key` 与线路只留相对路径，读回来按此刻的线路与令牌补上
/// （[ServerUrlCredentials]）——令牌换了 / 线路换了，读出来的地址照样对。
///
/// **重验**（[fetchList]）= 先问服务器「自上一份清单以来变了没」
/// （[PersistableRemoteVideoSource.remoteLibraryUnchangedSince]），没变就把**同一个**
/// 清单对象交回去（内存时刻刷新，库页按对象身份认出没变、什么都不重做）；变了 /
/// 没有戳 / 手动刷新 → 整库枚举并落盘。
///
/// 失效：登出 / 删服务器 → [retainSources] 删掉文件（由 `SyncRepository` 在服务器
/// 列表落库时调用）；换服务器 / 换账号 = 换来源身份 = 换文件；改媒体库勾选 =
/// 作用域不符；换了 app 构建 = 变更戳作废（清单照样先显示，但重验必走整库枚举，
/// 免得新版本改了映射、旧映射的清单却因「服务器没变」一直留着）。
class RemoteVideoListStore {
  RemoteVideoListStore._();

  /// 文件格式版本。改了信封或条目的序列化方式就 +1，旧文件随之被忽略并覆盖。
  /// 2：条目加作品级背景图 / logo 的条目 id（BUG-5614）。
  static const int formatVersion = 2;

  static const String directoryName = 'remote_video_lists';

  /// 缓存目录；null = 不落盘（纯 Dart 单测里没有 path_provider）。
  static Future<Directory?> Function() _dirResolver = _defaultDir;

  static Future<Directory?> _defaultDir() async {
    try {
      final Directory root = await AppPaths.appCacheRootDirectory();
      return Directory(p.join(root.path, directoryName));
    } on Object {
      return null;
    }
  }

  /// 测试注入：缓存目录（返回 null = 不落盘）；传 null 还原默认。
  @visibleForTesting
  static void debugSetDirResolver(Future<Directory?> Function()? resolver) {
    _dirResolver = resolver ?? _defaultDir;
  }

  /// 变更戳与之绑定的构建（[kFushiBuildVersionDefine]）。
  static String _buildVersion = kFushiBuildVersionDefine;

  /// 测试注入：模拟换了 app 构建；传 null 还原。
  @visibleForTesting
  static void debugSetBuildVersion(String? build) {
    _buildVersion = build ?? kFushiBuildVersionDefine;
  }

  /// 清单对象 → 取它之前拿到的变更戳。挂在**对象身份**上：只有「正是那次枚举 /
  /// 那个文件读出来的」清单才配用那个戳去问服务器，别的路径塞进缓存槽的清单
  /// 没有戳、重验时整库拉。
  static final Expando<String> _stamps = Expando<String>(
    'remote video list stamp',
  );

  /// 同一个文件的写入排队执行（连着两次整库拉完不会同时写同一个临时文件）。
  static final Map<String, Future<void>> _writes = <String, Future<void>>{};

  /// 最近一次 [retainSources] 给出的在册来源；null = 本进程还没给过（不拦）。
  static Set<String>? _liveSources;

  static String fileNameFor(String sourceId) =>
      '${sha1.convert(utf8.encode(sourceId))}.json';

  /// 重验 / 取数：见类注释。[current] 是内存槽里此刻的清单（可能为 null）。
  ///
  /// [forceRefresh]（用户手动刷新，BUG-1891 语义）永远整库枚举，不问变更戳。
  /// 戳在枚举**之前**取：枚举期间服务器上的改动会让下一次重验判「变了」，宁可多拉
  /// 一次也不漏。
  static Future<List<RemoteVideoInfo>> fetchList({
    required PersistableRemoteVideoSource source,
    required bool forceRefresh,
    required List<RemoteVideoInfo>? current,
  }) async {
    if (!forceRefresh && current != null) {
      final String? stamp = _stamps[current];
      if (stamp != null && await source.remoteLibraryUnchangedSince(stamp)) {
        return current;
      }
    }
    final String? stamp = await source.takeRemoteLibraryStamp();
    final List<RemoteVideoInfo> videos = await source.listRemoteVideos();
    if (stamp != null) _stamps[videos] = stamp;
    unawaited(save(source: source, videos: videos, stamp: stamp));
    return videos;
  }

  /// 读 [source] 的落盘清单（地址已按此刻的线路与令牌补好）；没有 / 读坏了 /
  /// 版本或作用域不符 → null。换了 app 构建的文件照样交出清单，只是不带变更戳。
  static Future<List<RemoteVideoInfo>?> load(
    PersistableRemoteVideoSource source,
  ) async {
    final Directory? dir = await _dirResolver();
    if (dir == null) return null;
    try {
      final String sourceId = source.remoteLibrarySourceId;
      final _Decoded? decoded = await _decodeInBackground(
        _DecodeJob(
          path: p.join(dir.path, fileNameFor(sourceId)),
          sourceId: sourceId,
          scope: source.remoteVideoListScope,
          build: _buildVersion,
          credentials: source.remoteVideoUrlCredentials,
        ),
      );
      if (decoded == null) return null;
      if (decoded.stamp case final String stamp) {
        _stamps[decoded.videos] = stamp;
      }
      return decoded.videos;
    } on Object catch (e) {
      // 缓存尽力而为：权限 / 竞态删除 / 任何解码异常都当没有。
      debugPrint('[remote-video-list] load failed: $e');
      return null;
    }
  }

  /// 落盘（同一文件排队、先写临时文件再改名，崩在半路也不会留下半个文件）。
  /// 任何异常吞掉：写不进去只是下次冷启动没有可先显示的清单。
  static Future<void> save({
    required PersistableRemoteVideoSource source,
    required List<RemoteVideoInfo> videos,
    required String? stamp,
  }) {
    final String sourceId = source.remoteLibrarySourceId;
    final String scope;
    final ServerUrlCredentials credentials;
    try {
      scope = source.remoteVideoListScope;
      credentials = source.remoteVideoUrlCredentials;
    } on Object catch (e) {
      debugPrint('[remote-video-list] save skipped: $e');
      return Future<void>.value();
    }
    final String build = _buildVersion;
    final Future<void> previous = _writes[sourceId] ?? Future<void>.value();
    final Future<void> next = previous.then((_) async {
      final Set<String>? live = _liveSources;
      if (live != null && !live.contains(sourceId)) return;
      final Directory? dir = await _dirResolver();
      if (dir == null) return;
      try {
        await _encodeInBackground(
          _EncodeJob(
            dir: dir.path,
            fileName: fileNameFor(sourceId),
            sourceId: sourceId,
            scope: scope,
            build: build,
            stamp: stamp,
            savedAt: DateTime.now().millisecondsSinceEpoch,
            credentials: credentials,
            videos: videos,
          ),
        );
      } on Object catch (e) {
        debugPrint('[remote-video-list] save failed: $e');
      }
    });
    _writes[sourceId] = next;
    return next.whenComplete(() {
      if (identical(_writes[sourceId], next)) _writes.remove(sourceId);
    });
  }

  /// 只留 [sourceIds] 这些来源的文件，其余删掉（登出 / 删服务器）。之后再到的
  /// 写入若属于已不在册的来源也会被丢弃（登出时还在途的整库枚举）。
  static Future<void> retainSources(Iterable<String> sourceIds) async {
    final Set<String> live = sourceIds.toSet();
    _liveSources = live;
    final Set<String> keep = <String>{
      for (final String id in live) fileNameFor(id),
    };
    await Future.wait<void>(<Future<void>>[..._writes.values]);
    final Directory? dir = await _dirResolver();
    if (dir == null) return;
    try {
      if (!await dir.exists()) return;
      await for (final FileSystemEntity entity in dir.list()) {
        if (entity is! File) continue;
        if (keep.contains(p.basename(entity.path))) continue;
        try {
          await entity.delete();
        } on FileSystemException {
          // 删不掉（占用）就留着：文件里没有凭据，作用域 / 来源身份也对不上新的登录。
        }
      }
    } on FileSystemException catch (e) {
      debugPrint('[remote-video-list] prune failed: $e');
    }
  }

  /// 等所有排队中的写入完成（测试断言落盘结果前用）。
  @visibleForTesting
  static Future<void> debugFlushWrites() =>
      Future.wait<void>(<Future<void>>[..._writes.values]);

  /// 测试隔离：清掉进程内状态（在册来源、在途写入的登记、模拟的构建号）。
  @visibleForTesting
  static void debugReset() {
    _liveSources = null;
    _writes.clear();
    _buildVersion = kFushiBuildVersionDefine;
  }
}

/// 解码结果（后台 isolate 交回）。
class _Decoded {
  const _Decoded(this.videos, this.stamp);

  final List<RemoteVideoInfo> videos;
  final String? stamp;
}

/// 读文件的全部输入（纯数据，可跨 isolate）。
class _DecodeJob {
  const _DecodeJob({
    required this.path,
    required this.sourceId,
    required this.scope,
    required this.build,
    required this.credentials,
  });

  final String path;
  final String sourceId;
  final String scope;
  final String build;
  final ServerUrlCredentials credentials;
}

/// 写文件的全部输入（纯数据，可跨 isolate）。
class _EncodeJob {
  const _EncodeJob({
    required this.dir,
    required this.fileName,
    required this.sourceId,
    required this.scope,
    required this.build,
    required this.stamp,
    required this.savedAt,
    required this.credentials,
    required this.videos,
  });

  final String dir;
  final String fileName;
  final String sourceId;
  final String scope;
  final String build;
  final String? stamp;
  final int savedAt;
  final ServerUrlCredentials credentials;
  final List<RemoteVideoInfo> videos;
}

// 后台 isolate 的入口单独成函数：闭包只捕获 job 本身。写在调用方里的闭包会连带
// 捕获外层作用域里的 Future / client（不可跨 isolate 发送）。
Future<_Decoded?> _decodeInBackground(_DecodeJob job) =>
    Isolate.run(() => _decodeFile(job));

Future<void> _encodeInBackground(_EncodeJob job) =>
    Isolate.run(() => _encodeFile(job));

/// 后台 isolate：读文件 → 校验信封 → 还原条目（补凭据）。不符 / 坏文件 → null。
Future<_Decoded?> _decodeFile(_DecodeJob job) async {
  final String sourceId = job.sourceId;
  final String scope = job.scope;
  final String build = job.build;
  final ServerUrlCredentials credentials = job.credentials;
  final File file = File(job.path);
  if (!await file.exists()) return null;
  final Object? json;
  try {
    json = jsonDecode(await file.readAsString());
  } on FormatException {
    return null;
  }
  if (json is! Map<String, Object?>) return null;
  if (json['format'] != RemoteVideoListStore.formatVersion ||
      json['sourceId'] != sourceId ||
      json['scope'] != scope) {
    return null;
  }
  final Object? rawVideos = json['videos'];
  if (rawVideos is! List<Object?>) return null;
  final List<RemoteVideoInfo> videos = <RemoteVideoInfo>[];
  for (final Object? raw in rawVideos) {
    if (raw is! Map<String, Object?>) return null;
    final RemoteVideoInfo info = RemoteVideoInfo.fromJson(raw);
    if (info.id.isEmpty) return null;
    final Object? cover = raw['coverUrl'];
    final Object? seriesCover = raw[_kSeriesCoverUrlKey];
    final Object? workBackdrop = raw[_kWorkBackdropItemIdKey];
    final Object? workLogo = raw[_kWorkLogoItemIdKey];
    videos.add(
      info.copyWith(
        coverUrl: cover is String ? credentials.authorize(cover) : null,
        seriesCoverUrl: seriesCover is String
            ? credentials.authorize(seriesCover)
            : null,
        workBackdropItemId: workBackdrop is String ? workBackdrop : null,
        workLogoItemId: workLogo is String ? workLogo : null,
      ),
    );
  }
  final Object? stamp = json['stamp'];
  return _Decoded(
    videos,
    stamp is String && json['build'] == build ? stamp : null,
  );
}

/// `RemoteVideoInfo.toJson` 是互联 wire 格式，不带 [RemoteVideoInfo.seriesCoverUrl]
/// （那是 client 侧拼出来的地址），落盘时单独存在这个键下。
const String _kSeriesCoverUrlKey = 'seriesCoverUrl';

/// 同理：作品级背景图 / logo 的条目 id（[RemoteVideoInfo.workBackdropItemId] /
/// [RemoteVideoInfo.workLogoItemId]）只在 client 侧派生、不进 wire。是服务器条目
/// id，不含凭据，原样落盘。
const String _kWorkBackdropItemIdKey = 'workBackdropItemId';
const String _kWorkLogoItemIdKey = 'workLogoItemId';

/// 后台 isolate：条目去凭据 → 编码 → 写临时文件 → 改名覆盖。
Future<void> _encodeFile(_EncodeJob job) async {
  final ServerUrlCredentials credentials = job.credentials;
  final List<Map<String, Object?>> items = <Map<String, Object?>>[];
  for (final RemoteVideoInfo video in job.videos) {
    final Map<String, Object?> item = video.toJson()..remove('coverUrl');
    // 去不掉凭据的地址（别的主机 / 换线路前拼的）不落盘：读回来那张卡暂时没封面，
    // 下一次整库拉完就补上，好过把令牌写进缓存文件。
    if (video.coverUrl case final String url) {
      if (credentials.strip(url) case final String path) {
        item['coverUrl'] = path;
      }
    }
    if (video.seriesCoverUrl case final String url) {
      if (credentials.strip(url) case final String path) {
        item[_kSeriesCoverUrlKey] = path;
      }
    }
    if (video.workBackdropItemId case final String id) {
      item[_kWorkBackdropItemIdKey] = id;
    }
    if (video.workLogoItemId case final String id) {
      item[_kWorkLogoItemIdKey] = id;
    }
    items.add(item);
  }
  final String encoded = jsonEncode(<String, Object?>{
    'format': RemoteVideoListStore.formatVersion,
    'sourceId': job.sourceId,
    'scope': job.scope,
    'build': job.build,
    'stamp': job.stamp,
    'savedAt': job.savedAt,
    'videos': items,
  });
  await Directory(job.dir).create(recursive: true);
  final File target = File(p.join(job.dir, job.fileName));
  final File temp = File('${target.path}.tmp');
  await temp.writeAsString(encoded, flush: true);
  await temp.rename(target.path);
}
