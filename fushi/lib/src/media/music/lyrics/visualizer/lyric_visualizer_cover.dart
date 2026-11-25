/// 封面图的共享加载：样式不再各自 import 歌词页的 `musicLyricsBackdropCoverProvider`，也不各写一遍
/// ImageStream 监听 / 释放。歌词页的同名函数委托到这里。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/server/interconnect_music_client.dart'
    show fushiHostMusicCoverProvider;
import 'package:fushi/src/utils/net/app_http_image.dart';

/// 在线封面请求头：部分音乐 CDN 对 `Dart/x (dart:io)` 这个默认 UA 一律回 403，
/// 浏览器形态的 UA 才放行（2026-10-29 实测）。
const Map<String, String> kMusicCoverRequestHeaders = <String, String>{
  'User-Agent': 'Mozilla/5.0',
};

/// 在线封面（插件 / 服务器曲库的 `http(s)://` 地址）的唯一 provider：走全应用代理、
/// 带 [kMusicCoverRequestHeaders]，**落磁盘缓存**（[AppCachedHttpImage]）。
///
/// 同一张封面会被播放条 / 列表（按显示尺寸 `ResizeImage`）、歌词背景（160px）、取色各要
/// 一份，`ResizeImage` 宽度不同 = 内存 ImageCache 的 key 不同；无字节缓存的 provider
/// 会让每个尺寸各下载一遍原图，切回听过的歌也重新下。磁盘缓存按 URL 存原图字节，
/// 各尺寸共用一次下载，之后切歌直接读盘。
ImageProvider musicRemoteCoverProvider(String url) =>
    AppCachedHttpImage(url, headers: kMusicCoverRequestHeaders);

/// 封面地址 → ImageProvider：`http(s)://` 走 [musicRemoteCoverProvider]，本地文件
/// 存在才用 [FileImage]，其余 null。
ImageProvider? lyricVisualizerCoverProvider(String? coverPath) {
  if (coverPath == null || coverPath.isEmpty) return null;
  if (coverPath.startsWith('http://') || coverPath.startsWith('https://')) {
    return musicRemoteCoverProvider(coverPath);
  }
  // 互联 host 的封面占位：经钉扎通道取字节。
  final ImageProvider? host = fushiHostMusicCoverProvider(coverPath);
  if (host != null) return host;
  final File file = File(coverPath);
  return file.existsSync() ? FileImage(file) : null;
}

/// 把一张图（封面或用户素材）解成 `ui.Image` 交给画家：换地址时自动退订旧流、释放旧图；
/// [dispose] 后不再回调。图到手 / 换掉时通知监听者（画家 `repaint` 可直接挂它）。
class LyricVisualizerImageLoader extends ChangeNotifier {
  LyricVisualizerImageLoader();

  String? _path;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _info;
  bool _disposed = false;

  /// 当前图（还没加载完 / 没有为 null）。所有权归加载器，画家只借用。
  ui.Image? get image => _info?.image;

  /// 当前地址。
  String? get path => _path;

  /// 加载封面（`http(s)://` 或本地路径）；与当前地址相同时什么都不做。
  void load(String? coverPath, {ImageConfiguration? configuration}) {
    if (coverPath == _path && (_stream != null || coverPath == null)) return;
    loadProvider(
      lyricVisualizerCoverProvider(coverPath),
      key: coverPath,
      configuration: configuration,
    );
  }

  /// 加载任意 ImageProvider（用户素材等）。[key] 用来判断「同一张」。
  void loadProvider(
    ImageProvider? provider, {
    String? key,
    ImageConfiguration? configuration,
  }) {
    if (_disposed) return;
    _path = key;
    _detach();
    final bool hadImage = _info != null;
    _info?.dispose();
    _info = null;
    if (hadImage) notifyListeners();
    if (provider == null) return;
    final ImageStream stream = provider.resolve(
      configuration ?? ImageConfiguration.empty,
    );
    final ImageStreamListener listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        if (_disposed) {
          info.dispose();
          return;
        }
        _info?.dispose();
        _info = info;
        notifyListeners();
      },
      onError: (Object _, StackTrace? _) {
        // 封面坏了 / 网络失败：样式按「没有封面」画，不抛到框架层。
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _detach() {
    final ImageStreamListener? l = _listener;
    if (l != null) _stream?.removeListener(l);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _detach();
    _info?.dispose();
    _info = null;
    super.dispose();
  }
}
