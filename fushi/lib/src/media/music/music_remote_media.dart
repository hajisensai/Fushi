/// 远程来源曲目（SFTP / WebDAV / AList 音乐来源，反馈 QAondMh4M5）起播时的流地址解析。
///
/// 按曲目的 **sourceId 对应来源的 transport** 分派，不按路径形态猜：音乐库里还有服务器曲库
/// （Jellyfin / Subsonic）的 http 曲目，它们没有 sourceId、走既有的直接播放；插件曲目走
/// 插件取流。复用视频起播同一条链路（`source_stream_headers.dart`）：
/// - WebDAV：条目地址即流地址，Basic 认证头只在来源根之内发（[resolveSourceStreamHeaders]）；
/// - AList：起播那一刻经 `fs/get` 换临期签名直链；
/// - SFTP：`sftp://` 稳定地址登记进进程内回环中继，按偏移读。
///
/// 解析器（AList 客户端 / SFTP 连接 + 中继登记）按来源缓存在**进程级**单例里，不放在播放
/// 后端实例上：交叉淡入时 [MusicCrossfadeBackend] 同时开两个 mpv 后端，放在实例上会各开
/// 一条 SSH 连接、各自的生命周期也对不上。来源被删除 / 改了连接参数时由来源管理调
/// [MusicRemoteMediaResolver.forgetSource] 关掉；进程退出随之释放。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/media/source_library/source_library_transports.dart';
import 'package:fushi/src/media/source_library/source_stream_headers.dart';
import 'package:fushi/src/media/video/stream_url_resolver.dart';

/// 一首远程曲目此刻可播的地址与请求头。
typedef MusicRemoteStream = ({String url, Map<String, String> headers});

/// 远程来源曲目的取流接口（测试注入替身）。
abstract interface class MusicRemoteMediaResolver {
  /// [item] 属于网络音乐来源时交回可播地址；本地来源 / 没有来源返回 null（走原路径）。
  /// 连接失败等抛 [MusicPluginStreamUnavailable]（与插件取流同一条「这一首拿不到流」路径）。
  Future<MusicRemoteStream?> resolve(MusicPlayItem item);

  /// 关掉某来源缓存的解析器（来源删除 / 改连接参数后）。
  void forgetSource(int sourceId);
}

/// 全局装配点：AppModel 启动时装上（持有数据库）；没装时远程曲目按原路径交给 mpv。
MusicRemoteMediaResolver? musicRemoteMediaResolver;

/// 曲目是否需要起播时联网取流：插件曲目，或带 sourceId 的 `sftp://` / http(s) 曲目
/// （网络音乐来源的条目地址）。服务器曲库曲目没有 sourceId，不算。
bool musicItemResolvesStream(MusicPlayItem? item) {
  if (item == null) return false;
  if (isMusicPluginPath(item.path)) return true;
  return isMusicRemoteSourceTrack(sourceId: item.sourceId, path: item.path);
}

/// 曲库曲目属于网络音乐来源（有 [sourceId]、[path] 是 `sftp://` / http(s) 条目地址）：
/// 本机没有这个文件——响度测量、同目录 sidecar、标签回写这类按本地文件工作的功能跳过它。
/// 服务器曲库曲目（http 但没有 sourceId）不算。
bool isMusicRemoteSourceTrack({required int? sourceId, required String path}) {
  if (sourceId == null) return false;
  final String lower = path.toLowerCase();
  return lower.startsWith('sftp://') ||
      lower.startsWith('https://') ||
      lower.startsWith('http://');
}

/// 真 app 实现：按来源行解析，解析器按来源缓存。
class SourceMusicRemoteMediaResolver implements MusicRemoteMediaResolver {
  /// [db] 每次取流时现取（会话可能先于数据库就绪建好）。
  SourceMusicRemoteMediaResolver(this._dbOf);

  final FushiDatabase Function() _dbOf;
  final Map<int, Future<StreamUrlResolver?>> _resolvers =
      <int, Future<StreamUrlResolver?>>{};

  @override
  Future<MusicRemoteStream?> resolve(MusicPlayItem item) async {
    final int? sourceId = item.sourceId;
    if (sourceId == null) return null;
    final FushiDatabase db = _dbOf();
    final SourceLibraryRow? source = await db.getMediaSourceById(sourceId);
    if (source == null ||
        !kStreamableVideoSourceTransports.contains(source.transport)) {
      return null;
    }
    try {
      if (source.transport == 'webdav') {
        return (
          url: item.path,
          headers: await resolveSourceStreamHeaders(
            db: db,
            sourceId: sourceId,
            targetUrl: item.path,
          ),
        );
      }
      final Future<StreamUrlResolver?> pending = _resolvers[sourceId] ??=
          resolveSourceStreamUrlResolver(db: db, sourceId: sourceId);
      final StreamUrlResolver? resolver;
      try {
        resolver = await pending;
      } catch (_) {
        // 建解析器失败不缓存：下一首重新建。
        _resolvers.remove(sourceId);
        rethrow;
      }
      if (resolver == null) return null;
      return (
        url: await resolver.resolve(item.path),
        headers: const <String, String>{},
      );
    } on MusicPluginStreamUnavailable {
      rethrow;
    } catch (e) {
      // 连接 / 认证 / 换直链失败：这一首拿不到流（引擎跳下一首），原因带给界面。
      throw MusicPluginStreamUnavailable('$e');
    }
  }

  @override
  void forgetSource(int sourceId) {
    final Future<StreamUrlResolver?>? r = _resolvers.remove(sourceId);
    r?.then((StreamUrlResolver? x) => x?.close(), onError: (Object _) {});
  }
}
