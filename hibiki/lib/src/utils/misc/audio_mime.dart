/// 单词音频「扩展名 → audio MIME」共享真相源（命名统一轮 G8 续）。
///
/// 此前两处各持一份漂移副本：
/// - `lookup_audio_playback.dart` `audioMimeForPath`（弹窗 `data:` URL）——
///   `.opus` 给 audio/ogg、缺 `.m4b`、兜底 audio/mpeg；
/// - `sync/remote_audio_lookup_bytes.dart` `remoteAudioContentTypeForPath`
///   （127.0.0.1 短命 token 端点的 Content-Type）——`.opus` 给 audio/opus、
///   兜底 application/octet-stream。
/// 收敛为本表 + 各自兜底：映射一份、兜底按消费端行为参数化（见下）。
///
/// `.opus` 定值 audio/ogg：RFC 7845（Ogg 封装的 Opus）注册的文件类型是
/// `audio/ogg`（`codecs=opus`），`.opus` 只是推荐扩展名；`audio/opus`
/// （RFC 7587）是 RTP 载荷格式的类型，不用于文件。浏览器 `<audio>` 对
/// `data:audio/ogg` 的解码支持也远好于非标的 audio/opus。
///
/// 与 hibiki_core 通用表 `kMimeTypeByExtension`（mime_types.dart）的关系：
/// 那张是「文件下发/上传」的通用推断（`.mp4`→video/mp4、`.aac`→audio/aac、
/// `.webm`→video/webm）；本表是**单词音频语境**的刻意收窄——查词音频解析出的
/// `.mp4/.aac` 一定是音频轨（audio/mp4 让 `<audio>` 选对解码器）、`.webm` 同理
/// audio/webm。刻意分歧集合与一致性由 `test/utils/misc/audio_mime_test.dart`
/// 守卫锁定；除该集合外，两表交集必须逐项一致。
library;

/// 扩展名（小写、不含点）→ 单词音频 MIME。
const Map<String, String> kAudioMimeByExtension = <String, String>{
  'mp3': 'audio/mpeg',
  // RFC 7845：Ogg Opus 文件注册类型是 audio/ogg（见库注释），与 ogg/oga 同值。
  'opus': 'audio/ogg',
  'ogg': 'audio/ogg',
  'oga': 'audio/ogg',
  'm4a': 'audio/mp4',
  'm4b': 'audio/mp4',
  'mp4': 'audio/mp4', // 音频语境：与通用表的 video/mp4 刻意不同。
  'aac': 'audio/mp4', // 音频语境：<audio> 按 audio/mp4 选解码器。
  'wav': 'audio/wav',
  'flac': 'audio/flac',
  'webm': 'audio/webm', // 音频语境：与通用表的 video/webm 刻意不同。
};

/// 按 [path]（文件路径或裸文件名）的扩展名推单词音频 MIME；无/未知扩展名回
/// [fallback]——兜底值刻意由消费端定：
/// - 弹窗 `data:` URL 侧用 `audio/mpeg`（`data:` 无内容嗅探，必须给出确定的
///   audio/* 类型；且 Anki 侧按 MIME 反推扩展名，mp3 是词典音频主流格式）；
/// - HTTP 端点侧用 `application/octet-stream`（响应头诚实报未知，浏览器按字节
///   嗅探播放）。
String audioMimeForPathWithFallback(String path, {required String fallback}) {
  final int slash = path.lastIndexOf(RegExp(r'[/\\]'));
  final String name = path.substring(slash + 1);
  final int dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return fallback;
  final String ext = name.substring(dot + 1).toLowerCase();
  return kAudioMimeByExtension[ext] ?? fallback;
}
