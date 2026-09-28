import 'dart:io';

import 'anki_models.dart';
import 'anki_remote_media_http.dart';
import 'ankiconnect/ankiconnect_repository.dart'
    show fushiAnkiMediaFilenameForBytesAsync;

/// 单词音频引用落成本地文件的结果：[file] 为 null 时 [failureReason] 说明原因
/// （都为 null = 这张卡没有单词音频）。文件名按内容哈希（`fushi_audio_<sha>.ext`），
/// 同名即同内容。
class AnkiLocalAudio {
  const AnkiLocalAudio.none() : file = null, failureReason = null;
  const AnkiLocalAudio.file(File this.file) : failureReason = null;
  const AnkiLocalAudio.failed(String this.failureReason) : file = null;

  final File? file;
  final String? failureReason;
}

/// 把 `fields['audio']`（`data:` URI / 本地路径 / 公网 URL）落成一个本地文件。
///
/// 不上传到任何 Anki：只负责「拿到字节、按内容命名、写进缓存目录」。本地文件原样
/// 返回，不复制。公网下载经应用代理出口（BUG-1498），非 200 不落盘（HBK-AUDIT-019）。
/// 失败文案由调用方的 `BaseAnkiRepository.audioFetch*Reason` 给，全仓只有那一份。
Future<AnkiLocalAudio> materializeAnkiWordAudio(
  String ref, {
  required String Function(int statusCode, String url) httpFailureReason,
  required String Function(Object error, String url) errorReason,
  Directory? cacheDir,
}) async {
  try {
    switch (AnkiAudioRef.classify(ref)) {
      case AnkiAudioRefKind.empty:
        return const AnkiLocalAudio.none();
      case AnkiAudioRefKind.dataUri:
        final data = AnkiAudioRef.decodeDataUri(ref);
        if (data == null) return const AnkiLocalAudio.none();
        return AnkiLocalAudio.file(
          await _writeHashed(
            data.bytes,
            sourceName: 'word_audio.${data.extension}',
            fallbackExtension: data.extension,
            cacheDir: cacheDir,
          ),
        );
      case AnkiAudioRefKind.localFile:
        final File file = File(AnkiAudioRef.localPath(ref));
        return file.existsSync()
            ? AnkiLocalAudio.file(file)
            : const AnkiLocalAudio.none();
      case AnkiAudioRefKind.remoteUrl:
        final HttpClient client = createAnkiRemoteMediaHttpClient();
        try {
          final HttpClientRequest request = await client.getUrl(Uri.parse(ref));
          final HttpClientResponse response = await request.close();
          if (response.statusCode != 200) {
            await response.drain<void>();
            return AnkiLocalAudio.failed(
              httpFailureReason(response.statusCode, ref),
            );
          }
          final List<int> bytes = await response.fold<List<int>>(
            <int>[],
            (List<int> a, List<int> b) => a..addAll(b),
          );
          return AnkiLocalAudio.file(
            await _writeHashed(
              bytes,
              sourceName: ref,
              fallbackExtension: ankiAudioExtensionFor(
                response.headers.contentType,
                ref,
              ),
              cacheDir: cacheDir,
            ),
          );
        } finally {
          client.close();
        }
    }
  } catch (e) {
    return AnkiLocalAudio.failed(errorReason(e, ref));
  }
}

/// 下载音频的扩展名：先看 Content-Type，再看 URL 路径，最后退回 mp3。
String ankiAudioExtensionFor(ContentType? contentType, String url) {
  switch (contentType?.mimeType) {
    case 'audio/mpeg':
      return 'mp3';
    case 'audio/aac':
      return 'aac';
    case 'audio/mp4':
    case 'audio/x-m4a':
      return 'm4a';
    case 'audio/wav':
    case 'audio/x-wav':
      return 'wav';
    case 'audio/ogg':
    case 'audio/opus':
      return 'ogg';
    case 'audio/webm':
      return 'webm';
    case 'audio/flac':
    case 'audio/x-flac':
      return 'flac';
  }
  final String path = Uri.tryParse(url)?.path ?? url;
  final int lastDot = path.lastIndexOf('.');
  final int lastSlash = path.lastIndexOf('/');
  if (lastDot > lastSlash && lastDot < path.length - 1) {
    return path.substring(lastDot + 1).toLowerCase();
  }
  return 'mp3';
}

Future<File> _writeHashed(
  List<int> bytes, {
  required String sourceName,
  required String fallbackExtension,
  Directory? cacheDir,
}) async {
  final Directory dir =
      cacheDir ?? Directory(ankiDictionaryMediaCacheDirPath());
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final String name = await fushiAnkiMediaFilenameForBytesAsync(
    prefix: 'fushi_audio_',
    bytes: bytes,
    sourceName: sourceName,
    fallbackExtension: fallbackExtension,
  );
  final File file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}
