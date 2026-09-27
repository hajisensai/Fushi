/// 视频在线源（Aniyomi 扩展）一集的整片下载：直链 / HLS 两路。
///
/// 2026-09-27「浏览」阶段 2b。流地址由扩展现解析（短 TTL 签名链接，BUG-2617），
/// 本类只负责「拿到 url + 防盗链头之后把字节落到本地」：
/// - **直链**（mp4 / mkv / webm …）：[ResumableDownloader]（`.part` + Range 续传）。
/// - **HLS**：Dart 端逐分片下载（不交给 ffmpeg 读网络：ffmpeg 后端没有进度也不能从
///   外部取消，移动端 kit 只能靠 timeout）——master 选最高码率变体、`#EXT-X-MAP`
///   初始化段先写、`#EXT-X-KEY` AES-128 解密、图片伪装分片剥前缀（BUG-2609，与播放
///   中继同一套判据 `hls_relay_normalizer.dart`），按序追加进 `.hls.part`，已完成的
///   分片数与字节数记在 `.hls.progress` 里断点续传；全部下完后本地跑一次
///   `ffmpeg -c copy` 转封装成 mp4（本地文件转封装很快，没有进度也可接受）。
///   转封装失败时原样保留分片流（mpv 按内容识别容器，照样能播），不当下载失败。
///
/// 不支持的形态如实报错（[AnimeEpisodeDownloadUnsupported]），不猜：独立音轨的
/// master（音视频分开的 rendition）、`#EXT-X-BYTERANGE`、SAMPLE-AES / DRM。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/utils/misc/resumable_downloader.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:pointycastle/export.dart';

import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteDownloadCancelled;
import 'package:fushi/src/utils/net/hls_relay_normalizer.dart';

/// 流的形态不支持整片下载。
class AnimeEpisodeDownloadUnsupported implements Exception {
  const AnimeEpisodeDownloadUnsupported(this.reason);

  final String reason;

  @override
  String toString() => 'AnimeEpisodeDownloadUnsupported: $reason';
}

/// 一个 HLS 媒体分片。
@immutable
class HlsSegment {
  const HlsSegment({
    required this.uri,
    required this.sequence,
    this.key,
    this.initSection,
  });

  final Uri uri;

  /// 媒体序号（`#EXT-X-MEDIA-SEQUENCE` 起算）：AES-128 没给 IV 时 IV 就是它。
  final int sequence;
  final HlsKey? key;

  /// 该分片之前生效的 `#EXT-X-MAP` 初始化段（fMP4）。
  final Uri? initSection;
}

/// `#EXT-X-KEY` 的 AES-128 描述。
@immutable
class HlsKey {
  const HlsKey({required this.uri, this.iv});

  final Uri uri;
  final Uint8List? iv;
}

/// 解析好的 HLS 媒体播放列表。
@immutable
class HlsMediaPlaylist {
  const HlsMediaPlaylist(this.segments);

  final List<HlsSegment> segments;

  bool get isFragmentedMp4 =>
      segments.any((HlsSegment segment) => segment.initSection != null);
}

final RegExp _attributePattern = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');

Map<String, String> _attributes(String raw) => <String, String>{
  for (final RegExpMatch match in _attributePattern.allMatches(raw))
    match.group(1)!: match.group(2)!.replaceAll('"', ''),
};

/// 解析媒体播放列表（纯函数，便于测试）。[base] 是播放列表的最终 URL（相对地址
/// 按它解析）。
HlsMediaPlaylist parseHlsMediaPlaylist(String playlist, Uri base) {
  final List<HlsSegment> segments = <HlsSegment>[];
  int sequence = 0;
  HlsKey? key;
  Uri? init;
  for (final String rawLine in const LineSplitter().convert(playlist)) {
    final String line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
      sequence = int.tryParse(line.split(':').last.trim()) ?? 0;
    } else if (line.startsWith('#EXT-X-BYTERANGE')) {
      throw const AnimeEpisodeDownloadUnsupported('HLS byte-range segments');
    } else if (line.startsWith('#EXT-X-KEY:')) {
      final Map<String, String> attrs = _attributes(
        line.substring('#EXT-X-KEY:'.length),
      );
      final String method = attrs['METHOD'] ?? 'NONE';
      if (method == 'NONE') {
        key = null;
      } else if (method == 'AES-128' && attrs['URI'] != null) {
        key = HlsKey(
          uri: base.resolve(attrs['URI']!),
          iv: _parseIv(attrs['IV']),
        );
      } else {
        throw AnimeEpisodeDownloadUnsupported('HLS encryption $method');
      }
    } else if (line.startsWith('#EXT-X-MAP:')) {
      final Map<String, String> attrs = _attributes(
        line.substring('#EXT-X-MAP:'.length),
      );
      if (attrs.containsKey('BYTERANGE')) {
        throw const AnimeEpisodeDownloadUnsupported('HLS byte-range init');
      }
      final String? uri = attrs['URI'];
      if (uri != null) init = base.resolve(uri);
    } else if (!line.startsWith('#')) {
      segments.add(
        HlsSegment(
          uri: base.resolve(line),
          sequence: sequence,
          key: key,
          initSection: init,
        ),
      );
      sequence++;
    }
  }
  return HlsMediaPlaylist(segments);
}

Uint8List? _parseIv(String? raw) {
  if (raw == null) return null;
  String hex = raw.trim();
  if (hex.startsWith('0x') || hex.startsWith('0X')) hex = hex.substring(2);
  if (hex.isEmpty || hex.length > 32) return null;
  hex = hex.padLeft(32, '0');
  return Uint8List.fromList(<int>[
    for (int i = 0; i < 32; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

/// 媒体序号 → 16 字节大端 IV（RFC 8216 §5.2：没给 IV 时用序号）。
Uint8List hlsSequenceIv(int sequence) {
  final Uint8List iv = Uint8List(16);
  int value = sequence;
  for (int i = 15; i >= 8 && value > 0; i--) {
    iv[i] = value & 0xff;
    value >>= 8;
  }
  return iv;
}

/// AES-128-CBC + PKCS7 解一个分片。
Uint8List decryptHlsSegment(Uint8List data, Uint8List key, Uint8List iv) {
  final PaddedBlockCipher cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))..init(
        false,
        PaddedBlockCipherParameters<CipherParameters, CipherParameters?>(
          ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
          null,
        ),
      );
  return cipher.process(data);
}

/// 分片的真实媒体字节：图片伪装前缀剥掉（BUG-2609），其余原样。
Uint8List unwrapHlsSegmentPayload(Uint8List bytes) {
  if (!looksLikeImagePrefix(bytes)) return bytes;
  final int? offset = disguisedMediaPayloadOffset(bytes);
  if (offset == null || offset <= 0) return bytes;
  return Uint8List.sublistView(bytes, offset);
}

typedef AnimeEpisodeHttpClientFactory = HttpClient Function();

/// 一集的整片下载器。
class AnimeEpisodeDownloader {
  AnimeEpisodeDownloader({
    AnimeEpisodeHttpClientFactory? httpClientFactory,
    FfmpegBackend Function()? ffmpeg,
  }) : _httpClientFactory = httpClientFactory ?? createAppHttpClient,
       _ffmpeg = ffmpeg ?? resolveFfmpegBackend;

  final AnimeEpisodeHttpClientFactory _httpClientFactory;
  final FfmpegBackend Function() _ffmpeg;

  /// 判流的形态：URL 后缀认不出时按响应内容嗅探（有的 hoster 的 m3u8 没后缀）。
  static bool looksLikeHlsUrl(String url) {
    final String path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return path.endsWith('.m3u8') || path.endsWith('.m3u');
  }

  Future<void> download({
    required String url,
    required Map<String, String> headers,
    required File dest,
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) async {
    final HttpClient client = _httpClientFactory();
    bool cancelled = false;
    unawaited(
      cancelSignal?.then((_) {
        cancelled = true;
        client.close(force: true);
      }),
    );
    try {
      await dest.parent.create(recursive: true);
      if (looksLikeHlsUrl(url)) {
        await _downloadHls(
          client,
          Uri.parse(url),
          headers,
          dest,
          onProgress: onProgress,
          isCancelled: () => cancelled,
        );
      } else {
        await _downloadDirect(
          client,
          url,
          headers,
          dest,
          onProgress: onProgress,
          onBytes: onBytes,
        );
        // 有的 hoster 的 m3u8 地址没有后缀：下回来的其实是播放列表文本，按内容认出
        // 来就改走分片下载（播放列表很小，这一趟白下的代价可以忽略）。
        if (await _isPlaylistFile(dest)) {
          await dest.delete();
          await _downloadHls(
            client,
            Uri.parse(url),
            headers,
            dest,
            onProgress: onProgress,
            isCancelled: () => cancelled,
          );
        }
      }
    } on Object {
      if (cancelled) throw const RemoteDownloadCancelled();
      rethrow;
    } finally {
      client.close(force: true);
    }
    if (cancelled) throw const RemoteDownloadCancelled();
  }

  Future<void> _downloadDirect(
    HttpClient client,
    String url,
    Map<String, String> headers,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
  }) async {
    final ResumableDownloader downloader = ResumableDownloader(
      url: url,
      destination: dest,
      partFile: File('${dest.path}.part'),
      open: (Uri uri, Map<String, String> rangeHeaders) =>
          _open(client, uri, <String, String>{...headers, ...rangeHeaders}),
      onProgress: (int received, int? total) {
        onBytes?.call(received, total);
        if (total != null && total > 0) onProgress?.call(received / total);
      },
    );
    await downloader.download();
  }

  static Future<bool> _isPlaylistFile(File file) async {
    if (!await file.exists() || await file.length() > 4 * 1024 * 1024) {
      return false;
    }
    final RandomAccessFile handle = await file.open();
    try {
      return looksLikeHlsPlaylist(await handle.read(64));
    } finally {
      await handle.close();
    }
  }

  static Future<ResumableDownloadResponse> _open(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final HttpClientRequest request = await client.getUrl(uri);
    request.followRedirects = true;
    request.maxRedirects = 8;
    headers.forEach(request.headers.set);
    final HttpClientResponse response = await request.close();
    final Map<String, String> responseHeaders = <String, String>{};
    response.headers.forEach(
      (String name, List<String> values) =>
          responseHeaders[name] = values.join(', '),
    );
    return ResumableDownloadResponse(
      statusCode: response.statusCode,
      headers: responseHeaders,
      stream: response,
    );
  }

  Future<({Uint8List body, Uri finalUri})> _get(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final HttpClientRequest request = await client.getUrl(uri);
    request.followRedirects = true;
    request.maxRedirects = 8;
    headers.forEach(request.headers.set);
    final HttpClientResponse response = await request.close();
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in response) {
      builder.add(chunk);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    final Uri finalUri = response.redirects.isEmpty
        ? uri
        : uri.resolveUri(response.redirects.last.location);
    return (body: builder.takeBytes(), finalUri: finalUri);
  }

  /// 取媒体播放列表：master 先选最高码率变体（音视频分开的 rendition 不支持）。
  Future<HlsMediaPlaylist> _loadMediaPlaylist(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    Uri current = uri;
    for (int depth = 0; depth < 3; depth++) {
      final ({Uint8List body, Uri finalUri}) response = await _get(
        client,
        current,
        headers,
      );
      final String text = utf8.decode(response.body, allowMalformed: true);
      if (!text.contains('#EXT-X-STREAM-INF')) {
        return parseHlsMediaPlaylist(text, response.finalUri);
      }
      final String? variant = selectHlsMasterVariant(text);
      if (variant == null) {
        throw const AnimeEpisodeDownloadUnsupported(
          'HLS master with separate audio/video renditions',
        );
      }
      current = response.finalUri.resolve(variant);
    }
    throw const AnimeEpisodeDownloadUnsupported('HLS master nesting too deep');
  }

  Future<void> _downloadHls(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
    File dest, {
    required bool Function() isCancelled,
    void Function(double progress)? onProgress,
  }) async {
    final HlsMediaPlaylist playlist = await _loadMediaPlaylist(
      client,
      uri,
      headers,
    );
    final List<HlsSegment> segments = playlist.segments;
    if (segments.isEmpty) {
      throw const AnimeEpisodeDownloadUnsupported('empty HLS playlist');
    }
    final File part = File('${dest.path}.hls.part');
    final File progressFile = File('${dest.path}.hls.progress');
    // 断点：记的是「已完整写入的分片数 + 字节数」。part 比记录长（上次写到一半被杀）
    // 就截回记录的长度；比记录短（part 被删）就从头来。
    int done = 0;
    int written = 0;
    if (await progressFile.exists() && await part.exists()) {
      final List<String> fields = (await progressFile.readAsString()).split(
        ',',
      );
      final int? recordedDone = int.tryParse(fields.first);
      final int? recordedBytes = fields.length > 1
          ? int.tryParse(fields[1])
          : null;
      final int length = await part.length();
      if (recordedDone != null &&
          recordedBytes != null &&
          recordedDone <= segments.length &&
          length >= recordedBytes) {
        done = recordedDone;
        written = recordedBytes;
      }
    }
    final RandomAccessFile sink = await part.open(
      mode: done == 0 ? FileMode.write : FileMode.append,
    );
    final Map<Uri, Uint8List> keys = <Uri, Uint8List>{};
    try {
      if (done > 0) await sink.truncate(written);
      await sink.setPosition(written);
      Uri? writtenInit = done > 0 ? segments[done - 1].initSection : null;
      for (int index = done; index < segments.length; index++) {
        if (isCancelled()) throw const RemoteDownloadCancelled();
        final HlsSegment segment = segments[index];
        final Uri? init = segment.initSection;
        if (init != null && init != writtenInit) {
          final Uint8List initBytes = (await _get(client, init, headers)).body;
          await sink.writeFrom(unwrapHlsSegmentPayload(initBytes));
          writtenInit = init;
        }
        Uint8List bytes = (await _get(client, segment.uri, headers)).body;
        final HlsKey? key = segment.key;
        if (key != null) {
          final Uint8List keyBytes = keys[key.uri] ??= (await _get(
            client,
            key.uri,
            headers,
          )).body;
          bytes = decryptHlsSegment(
            bytes,
            keyBytes,
            key.iv ?? hlsSequenceIv(segment.sequence),
          );
        }
        await sink.writeFrom(unwrapHlsSegmentPayload(bytes));
        await sink.flush();
        written = await sink.position();
        await progressFile.writeAsString('${index + 1},$written', flush: true);
        onProgress?.call((index + 1) / segments.length);
      }
    } finally {
      await sink.close();
    }
    await _finishHls(part, dest, fragmented: playlist.isFragmentedMp4);
    if (await progressFile.exists()) await progressFile.delete();
  }

  /// 分片流 → mp4：`-c copy` 转封装（TS 里的 ADTS AAC 要 `aac_adtstoasc`）。
  /// 转封装失败原样保留分片流（mpv 按内容识别容器），不当下载失败。
  Future<void> _finishHls(
    File part,
    File dest, {
    required bool fragmented,
  }) async {
    if (await dest.exists()) await dest.delete();
    final File remuxed = File('${dest.path}.remux.mp4');
    try {
      final FfmpegRunResult result = await _ffmpeg().run(<String>[
        '-hide_banner',
        '-y',
        '-i',
        part.path,
        '-map',
        '0',
        '-c',
        'copy',
        if (!fragmented) ...<String>['-bsf:a', 'aac_adtstoasc'],
        '-movflags',
        '+faststart',
        remuxed.path,
      ], const Duration(minutes: 30));
      if (result.returnCode == 0 &&
          await remuxed.exists() &&
          await remuxed.length() > 0) {
        await remuxed.rename(dest.path);
        await part.delete();
        return;
      }
      debugPrint('[anime-download] remux failed: ${result.output}');
    } on Object catch (error) {
      debugPrint('[anime-download] remux unavailable: $error');
    }
    if (await remuxed.exists()) await remuxed.delete();
    await part.rename(dest.path);
  }
}
