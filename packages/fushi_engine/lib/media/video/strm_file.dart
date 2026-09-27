/// `.strm` 流指针文件（Kodi / Jellyfin / Emby / SenPlayer 通行约定）的纯解析。
///
/// `.strm` 是一个纯文本文件，内容是一条可播地址（常见 http(s) 直链 / HLS、
/// rtsp / rtmp 直播流，少数写本地路径）。来源库扫描把它当普通视频入库（标题取
/// `.strm` 文件名、照常走刮削与进度），`videoPath` 存 `.strm` 自身的路径——
/// 指向的地址在**起播那一刻**现读现解析（改 `.strm` 内容无需重扫，也不把第三方
/// 地址写进行级数据）。
///
/// 本文件只做字符串判定，不碰文件系统 / 网络，app 与服务端共用。
library;

/// `.strm` 扩展名（小写，不带点）。
const String kStrmExtension = 'strm';

/// `.strm` 文件读取上限（字节）。正常文件只有一行地址；超过这个量级的不是
/// `.strm`（误命名的大文件），读取方据此拒绝，不把整个大文件读进内存。
const int kStrmMaxBytes = 64 * 1024;

/// 播放内核（libmpv / ffmpeg）能直接吃的网络流协议。http(s) 之外的直播协议
/// （rtsp / rtmp / mms / srt / udp 组播）在 IPTV 频道列表与 `.strm` 里都很常见。
const Set<String> kNetworkStreamSchemes = <String>{
  'http',
  'https',
  'rtsp',
  'rtsps',
  'rtmp',
  'rtmps',
  'rtmpe',
  'rtmpt',
  'mms',
  'mmsh',
  'mmst',
  'srt',
  'rtp',
  'udp',
};

/// 纯函数：[url] 是否是 [kNetworkStreamSchemes] 里的网络流地址（host 非空）。
///
/// 与 app 侧 `isPlayableStreamUrl`（只认 http(s)，导入对话框的输入校验）的区别：
/// 这里是「播放内核能不能直接打开」的判据，覆盖 IPTV 常见的 rtsp / rtmp 等直播
/// 协议。`udp://@239.0.0.1:1234` 这类组播地址的 host 同样非空。
bool isNetworkStreamUrl(String url) {
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  if (!kNetworkStreamSchemes.contains(uri.scheme.toLowerCase())) return false;
  return uri.host.isNotEmpty;
}

/// 纯函数：[path] 是否指向一个 `.strm` 文件。本地路径与来源库网络条目（WebDAV /
/// AList 的 http(s) 地址）都认；URL 只看路径段，忽略 query / fragment。
bool isStrmPath(String path) {
  String candidate = path.trim();
  if (candidate.isEmpty) return false;
  if (candidate.contains('://')) {
    final Uri? uri = Uri.tryParse(candidate);
    if (uri == null) return false;
    candidate = uri.path;
  }
  final int dot = candidate.lastIndexOf('.');
  if (dot < 0) return false;
  final int sep = candidate.lastIndexOf(RegExp(r'[/\\]'));
  if (dot < sep) return false;
  return candidate.substring(dot + 1).toLowerCase() == kStrmExtension;
}

/// 纯函数：从 `.strm` 文本 [content] 取出目标地址——首个非空、非 `#` 注释行
/// （去掉 UTF-8 BOM 与首尾空白）。没有这样的行返回 null。
///
/// 只取第一条：`.strm` 约定一文件一流，后续行（多源备份等非标写法）忽略。
String? parseStrmTarget(String content) {
  String text = content;
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  for (final String rawLine in text.split(RegExp(r'\r?\n|\r'))) {
    final String line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    return line;
  }
  return null;
}

/// `.strm` 目标地址的类别（决定起播路径）。
enum StrmTargetKind {
  /// 网络流（[isNetworkStreamUrl]）：走既有流播链路。
  networkStream,

  /// 本地文件路径（绝对路径 / `file://`）：`.strm` 指回本机文件，不支持
  /// （跨设备同步后路径必然失效，且本地文件应直接放进来源库），给用户可见提示。
  localPath,

  /// 其它（相对路径、未知协议如 `plugin://` / `smb://`、空串）：不支持。
  unsupported,
}

/// 纯函数：给 [parseStrmTarget] 的结果分类。
StrmTargetKind classifyStrmTarget(String target) {
  final String t = target.trim();
  if (t.isEmpty) return StrmTargetKind.unsupported;
  if (isNetworkStreamUrl(t)) return StrmTargetKind.networkStream;
  if (t.toLowerCase().startsWith('file://')) return StrmTargetKind.localPath;
  if (_isAbsoluteLocalPath(t)) return StrmTargetKind.localPath;
  return StrmTargetKind.unsupported;
}

/// 纯字符串判绝对本地路径（与主机平台无关）：POSIX `/`、Windows 盘符根
/// `X:\` / `X:/`、UNC `\\host\share`。
bool _isAbsoluteLocalPath(String s) {
  if (s.startsWith('/') || s.startsWith(r'\\')) return true;
  if (s.length >= 3 &&
      RegExp(r'^[A-Za-z]$').hasMatch(s[0]) &&
      s[1] == ':' &&
      (s[2] == '\\' || s[2] == '/')) {
    return true;
  }
  return false;
}
