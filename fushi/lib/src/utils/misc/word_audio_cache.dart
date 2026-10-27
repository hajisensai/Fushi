/// 单词音频字节的落盘缓存 + 「这段响应是不是音频」判别。
///
/// 两个消费端：
/// - `lookup_audio_playback.dart` `webViewWordAudioUrlToPlayableRef`：弹窗交回的
///   `data:` / 词典媒体字节落盘给原生播放器；
/// - `word_audio_resolver.dart` 远端音源：Yomitan「Custom URL」型（URL 直接回
///   音频，而不是 `audioSourceList` JSON）的响应字节落盘，返回本地路径——同一次
///   请求的字节直接复用，不让播放端再打一遍（GPT-SoVITS 这类 TTS 端点会再合成
///   一遍）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show md5;

/// 单词音频落盘缓存目录（`systemTemp/fushi_word_audio`）最多保留的文件数；超出按
/// mtime 淘汰最旧的。每段都是一两秒的词音频，几十个足够覆盖「反复点同一批词」。
const int kWordAudioCacheMaxFiles = 64;

/// 默认缓存目录：`systemTemp/fushi_word_audio`。
Directory defaultWordAudioCacheDir() => Directory(
  '${Directory.systemTemp.path}${Platform.pathSeparator}fushi_word_audio',
);

/// 把 [bytes] 落到 [cacheDir]（缺省 [defaultWordAudioCacheDir]）下按内容寻址的
/// `<md5>.<fileExt>` 文件并返回其路径：同一段音频复用同一文件（播放中的文件不会
/// 被下一次播放覆写），复用时刷新 mtime；目录最多留 [maxFiles] 个文件，按 mtime
/// 淘汰最旧。
Future<String> cacheWordAudioBytes(
  Uint8List bytes,
  String fileExt, {
  Directory? cacheDir,
  int maxFiles = kWordAudioCacheMaxFiles,
}) async {
  final Directory dir = cacheDir ?? defaultWordAudioCacheDir();
  await dir.create(recursive: true);
  final String name = '${md5.convert(bytes)}.$fileExt';
  final File file = File('${dir.path}${Platform.pathSeparator}$name');
  if (!await file.exists() || await file.length() != bytes.length) {
    await file.writeAsBytes(bytes, flush: true);
  } else {
    // 复用即续命：淘汰按 mtime，刚要播的这段不能被当成最旧的删掉。
    await file.setLastModified(DateTime.now());
  }
  _pruneWordAudioCache(dir, keep: file.path, maxFiles: maxFiles);
  return file.path;
}

/// 把 [dir] 收到至多 [maxFiles] 个文件：按 mtime 从旧到新删，[keep] 永不删。
/// 用 listSync（目录很小；异步 list 在 widget 测试的 fake-async 里永不完成）。
/// 单个文件删不掉（已被并发删除等）只跳过它——下一次播放会再收一次。
void _pruneWordAudioCache(
  Directory dir, {
  required String keep,
  required int maxFiles,
}) {
  final List<File> files = dir.listSync().whereType<File>().toList();
  if (files.length <= maxFiles) return;
  final List<(File, DateTime)> aged = <(File, DateTime)>[];
  for (final File f in files) {
    if (f.path == keep) continue;
    try {
      aged.add((f, f.lastModifiedSync()));
    } on FileSystemException {
      continue;
    }
  }
  aged.sort(((File, DateTime) a, (File, DateTime) b) => a.$2.compareTo(b.$2));
  final int excess = files.length - maxFiles;
  for (final (File f, DateTime _) in aged.take(excess)) {
    try {
      f.deleteSync();
    } on FileSystemException {
      continue;
    }
  }
}

/// 远端响应是不是一段音频；是则返回落盘扩展名，不是返回 null。
///
/// 判据（确定性，不靠「先当 JSON 解析、失败再说」）：
/// 1. 文件魔数——最可靠，也给出准确扩展名；
/// 2. `Content-Type: audio/*`——服务器明说是音频（魔数没认出的编码，扩展名按
///    子类型给，认不出用 `mp3`，原生播放器按内容嗅探）。
///
/// `application/octet-stream` 这类不表态的类型只看魔数。
String? sniffWordAudioExtension(Uint8List bytes, {String? contentType}) {
  final String? magic = _audioExtensionByMagic(bytes);
  if (magic != null) return magic;
  final String mime = (contentType ?? '').split(';').first.trim().toLowerCase();
  if (!mime.startsWith('audio/')) return null;
  return _audioExtensionByMimeSubtype(mime.substring('audio/'.length));
}

String? _audioExtensionByMagic(Uint8List b) {
  bool ascii(int offset, String tag) {
    if (b.length < offset + tag.length) return false;
    for (int i = 0; i < tag.length; i++) {
      if (b[offset + i] != tag.codeUnitAt(i)) return false;
    }
    return true;
  }

  if (ascii(0, 'ID3')) return 'mp3';
  if (ascii(0, 'OggS')) return 'ogg';
  if (ascii(0, 'fLaC')) return 'flac';
  if (ascii(0, 'RIFF') && ascii(8, 'WAVE')) return 'wav';
  if (ascii(4, 'ftyp')) return 'm4a';
  if (b.length >= 4 &&
      b[0] == 0x1A &&
      b[1] == 0x45 &&
      b[2] == 0xDF &&
      b[3] == 0xA3) {
    return 'webm';
  }
  // MPEG 音频帧同步字 0xFFE/0xFFF：layer 位为 00 的是 ADTS（AAC），否则是 MP3
  // （无 ID3 头的裸 MP3 帧）。
  if (b.length >= 2 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) {
    return (b[1] & 0x06) == 0 ? 'aac' : 'mp3';
  }
  return null;
}

String _audioExtensionByMimeSubtype(String subtype) {
  switch (subtype) {
    case 'aac':
    case 'aacp':
    case 'x-aac':
      return 'aac';
    case 'ogg':
    case 'opus':
    case 'vorbis':
      return 'ogg';
    case 'wav':
    case 'wave':
    case 'x-wav':
    case 'vnd.wave':
      return 'wav';
    case 'flac':
    case 'x-flac':
      return 'flac';
    case 'mp4':
    case 'm4a':
    case 'x-m4a':
      return 'm4a';
    case 'webm':
      return 'webm';
    default:
      return 'mp3';
  }
}
