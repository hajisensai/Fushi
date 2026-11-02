/// 视频在线源（Aniyomi 扩展）一集的整片下载：直链 / HLS 两路。
///
/// 2026-09-27「浏览」阶段 2b。流地址由扩展现解析（短 TTL 签名链接，BUG-2617），
/// 本类只负责「拿到 url + 防盗链头之后把字节落到本地」：
/// - **直链**（mp4 / mkv / webm …）：[ResumableDownloader]（`.part` + Range 续传）。
///   续传前必须确认还是**同一份字节**：流地址每次由扩展现解析，这一次拿到的可能是
///   另一个 hoster / 另一种画质，也可能源站换了文件。上次响应的 ETag / Last-Modified /
///   总长落在 `.part.validator` 侧车（[DirectStreamValidator]），续传以 `If-Range`
///   携带——服务器换了字节就回 200，旧 part 丢弃从 0 写；服务器无视 `If-Range` 照回
///   206 时再拿 206 的 ETag / 总长比对侧车，不符就不带 Range 重开、同样从 0 写。没有
///   侧车（旧版本留下的 part / 服务器一个验证器都不给）的 part 不续，直接从 0。
/// - **HLS**：Dart 端逐分片下载（不交给 ffmpeg 读网络：ffmpeg 后端没有进度也不能从
///   外部取消，移动端 kit 只能靠 timeout）——master 选最高码率变体、`#EXT-X-MAP`
///   初始化段先写、`#EXT-X-KEY` AES-128 解密、图片伪装分片剥前缀（BUG-2609，与播放
///   中继同一套判据 `hls_relay_normalizer.dart`），按序追加进 `.hls.part`，已完成的
///   分片数与字节数连同**流指纹**（[hlsStreamFingerprint]）记在 `.hls.progress` 里
///   断点续传——指纹对不上（换了线路 / 画质 / 源站重切了片）就从 0 下，不把两条流
///   拼进同一个文件；全部下完后本地跑一次 `ffmpeg -c copy` 转封装成 mp4（本地文件
///   转封装很快，没有进度也可接受）。转封装失败时原样保留分片流（mpv 按内容识别
///   容器，照样能播），不当下载失败，但记进错误日志。
///
/// 网络等待都有上限：连接超时（HttpClient）+ 首字节 / 流内空闲超时
/// （[AnimeEpisodeDownloader.stallTimeout]）。超时如实抛 [TimeoutException]——任务
/// 落到失败态、`.part` / 断点记录留着，下载中心「重试」从断点接着下。
///
/// 不支持的形态如实报错（[AnimeEpisodeDownloadUnsupported]），不猜：独立音轨的
/// master（音视频分开的 rendition）、`#EXT-X-BYTERANGE`、SAMPLE-AES / DRM。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/utils/misc/resumable_downloader.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteDownloadCancelled;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/net/hls_relay_normalizer.dart';

/// 首字节 / 流内空闲超时：与互联视频下载的 `downloadStallTimeout` 同量级。一个
/// 分片 / 一段直链字节超过这么久一个字节都不来，就当这次下载卡死了。
const Duration kAnimeEpisodeStallTimeout = Duration(seconds: 45);

/// keep-alive 连接空闲多久就关（HttpClient.idleTimeout）：分片是一条接一条串行拉的，
/// 两片之间的空档远小于它；这里显式钉住而不是依赖默认值。
const Duration kAnimeEpisodeIdleConnectionTimeout = Duration(seconds: 15);

/// 直链续传的验证器侧车后缀（`<dest>.part.validator`）。
const String kAnimeDirectValidatorSuffix = '.part.validator';

/// DASH 分离流合成下载（[AnimeEpisodeDownloader.downloadWithExternalAudio]）的
/// 画面分量后缀：`<dest>.video`。
const String kAnimeVideoComponentSuffix = '.video';

/// 外挂音轨分量后缀：`<dest>.audio<N>`。
String animeAudioComponentSuffix(int index) => '.audio$index';

/// 合成中间件后缀：`<dest>.mux.mkv`。
const String kAnimeMuxSuffix = '.mux.mkv';

/// 已下完的分量旁的「流身份」侧车（`<component>.done`）：记下这份完整字节来自哪条
/// 流（直链的 ETag / Last-Modified / 总长，或 HLS 流指纹），续传重跑时校验通过才
/// 复用，不通过才删掉重下（与 `.part.validator` 同口径）。
const String kAnimeComponentDoneSuffix = '.done';

/// 单个下载目标（成品或分量）旁 [AnimeEpisodeDownloader.download] 会派生的断点文件。
const List<String> _kAnimeDerivedSuffixes = <String>[
  '.part',
  kAnimeDirectValidatorSuffix,
  '.hls.part',
  '.hls.progress',
  '.remux.mp4',
];

/// 一集下载在 [dest] 旁可能留下的半成品 / 断点文件：直链 `.part` + 验证器侧车、
/// HLS 分片流 + 断点记录、转封装中间件；DASH 分离流还有画面分量 `.video`、
/// [audioComponents] 条外挂音轨分量 `.audioN`（各自带上述派生文件与 `.done` 侧车）
/// 以及合成中间件 `.mux.mkv`。
///
/// 下载中心「放弃」时音轨条数已不可知，实际删除走按文件名判定的
/// [deleteAnimeEpisodeDownloadLeftovers]（[isAnimeEpisodeDownloadLeftoverName] 与
/// 本清单同一套后缀，测试按本清单比对）。
List<File> animeEpisodeDownloadLeftovers(File dest, {int audioComponents = 0}) {
  List<File> derived(String path) => <File>[
    for (final String suffix in _kAnimeDerivedSuffixes) File('$path$suffix'),
  ];
  List<File> component(String path) => <File>[
    File(path),
    File('$path$kAnimeComponentDoneSuffix'),
    ...derived(path),
  ];
  return <File>[
    ...derived(dest.path),
    File('${dest.path}$kAnimeMuxSuffix'),
    ...component('${dest.path}$kAnimeVideoComponentSuffix'),
    for (int i = 0; i < audioComponents; i++)
      ...component('${dest.path}${animeAudioComponentSuffix(i)}'),
  ];
}

final RegExp _kAnimeLeftoverTail = RegExp(
  r'^(?:\.mux\.mkv'
  r'|(?:\.video|\.audio\d+)(?:\.done)?'
  r'|(?:\.video|\.audio\d+)?'
  r'(?:\.part|\.part\.validator|\.hls\.part|\.hls\.progress|\.remux\.mp4))$',
);

/// [fileName] 是不是成品名为 [destName] 的一集下载留下的半成品（见
/// [animeEpisodeDownloadLeftovers]）。成品本身不算。
bool isAnimeEpisodeDownloadLeftoverName(String destName, String fileName) {
  if (fileName.length <= destName.length || !fileName.startsWith(destName)) {
    return false;
  }
  return _kAnimeLeftoverTail.hasMatch(fileName.substring(destName.length));
}

/// 删掉 [dest] 旁一集下载留下的全部半成品（音轨分量条数不定，按文件名判定）。
/// 返回是否真的删了文件。单个文件删失败只记 debug 日志，继续删其余的。
Future<bool> deleteAnimeEpisodeDownloadLeftovers(File dest) async {
  final Directory parent = dest.parent;
  if (!await parent.exists()) return false;
  final String destName = dest.uri.pathSegments.isEmpty
      ? dest.path
      : dest.uri.pathSegments.last;
  bool deleted = false;
  await for (final FileSystemEntity entity in parent.list(followLinks: false)) {
    if (entity is! File) continue;
    final String name = entity.uri.pathSegments.last;
    if (!isAnimeEpisodeDownloadLeftoverName(destName, name)) continue;
    try {
      await entity.delete();
      deleted = true;
    } on Object catch (error) {
      debugPrint(
        '[anime-download] leftover ${entity.path} delete failed: $error',
      );
    }
  }
  return deleted;
}

/// 直链续传的验证器（落 `<dest>.part.validator`，与 `.part` 配对）：上一次响应的
/// ETag / Last-Modified / 总长。
@immutable
class DirectStreamValidator {
  const DirectStreamValidator({this.etag, this.lastModified, this.totalBytes});

  final String? etag;
  final String? lastModified;
  final int? totalBytes;

  /// 一个可比对的字段都没有：凭它无法确认续传的是同一份字节。
  bool get isEmpty =>
      (etag == null || etag!.isEmpty) &&
      (lastModified == null || lastModified!.isEmpty) &&
      totalBytes == null;

  String encode() => jsonEncode(<String, Object?>{
    'etag': etag,
    'lastModified': lastModified,
    'totalBytes': totalBytes,
  });

  /// 坏 JSON / 旧格式返回 null，**绝不抛**（当作没有侧车）。
  static DirectStreamValidator? tryParse(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      final Object? etag = decoded['etag'];
      final Object? lastModified = decoded['lastModified'];
      final Object? total = decoded['totalBytes'];
      return DirectStreamValidator(
        etag: etag is String && etag.isNotEmpty ? etag : null,
        lastModified: lastModified is String && lastModified.isNotEmpty
            ? lastModified
            : null,
        totalBytes: total is int && total >= 0 ? total : null,
      );
    } on Object {
      return null;
    }
  }

  /// 续传响应（206）是否仍是侧车记下的那份字节：两边都有的字段逐一比对，任一不同
  /// 即不是；**一个可比的字段都没有也算不是**（宁可重下，也不拼坏片）。
  bool sameStreamAs(ResumableDownloadResponse response) {
    int compared = 0;
    final String? etagNow = response.header(HttpHeaders.etagHeader);
    if (etag != null && etagNow != null && etagNow.isNotEmpty) {
      compared++;
      if (etagNow != etag) return false;
    }
    final String? modifiedNow = response.header(HttpHeaders.lastModifiedHeader);
    if (lastModified != null && modifiedNow != null && modifiedNow.isNotEmpty) {
      compared++;
      if (modifiedNow != lastModified) return false;
    }
    final int? totalNow = _contentRangeTotal(
      response.header(HttpHeaders.contentRangeHeader),
    );
    if (totalBytes != null && totalNow != null) {
      compared++;
      if (totalNow != totalBytes) return false;
    }
    return compared > 0;
  }

  static int? _contentRangeTotal(String? value) {
    if (value == null) return null;
    final RegExpMatch? match = RegExp(
      r'^bytes\s+\d+-\d+/(\d+)$',
    ).firstMatch(value.trim());
    return match == null ? null : int.tryParse(match.group(1)!);
  }
}

/// HLS 流指纹：媒体播放列表地址（去 query / fragment）+ 分片数 + 首分片地址（去
/// query / fragment）。签名链接的 token 一般在 query 里，同一条流每次重新取流
/// 指纹不变；换了变体 / hoster / 源站重切片，指纹就变。
String hlsStreamFingerprint(Uri mediaPlaylistUri, HlsMediaPlaylist playlist) {
  final List<HlsSegment> segments = playlist.segments;
  final String first = segments.isEmpty ? '' : _bareUri(segments.first.uri);
  return '${_bareUri(mediaPlaylistUri)}|${segments.length}|$first';
}

String _bareUri(Uri uri) => Uri(
  scheme: uri.scheme,
  userInfo: uri.userInfo,
  host: uri.host,
  port: uri.hasPort ? uri.port : null,
  path: uri.path,
).toString();

/// `.hls.progress` 的内容：流指纹 + 已完整写入的分片数 / 字节数。
@immutable
class HlsDownloadProgress {
  const HlsDownloadProgress({
    required this.stream,
    required this.segments,
    required this.bytes,
  });

  /// [hlsStreamFingerprint]。
  final String stream;
  final int segments;
  final int bytes;

  String encode() => jsonEncode(<String, Object>{
    'stream': stream,
    'segments': segments,
    'bytes': bytes,
  });

  /// 坏 JSON / 旧格式（不带指纹的 `分片数,字节数`）返回 null，**绝不抛**——
  /// 旧记录说不清是哪条流，只能从 0 下。
  static HlsDownloadProgress? tryParse(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      final Object? stream = decoded['stream'];
      final Object? segments = decoded['segments'];
      final Object? bytes = decoded['bytes'];
      if (stream is! String || segments is! int || bytes is! int) return null;
      if (segments < 0 || bytes < 0) return null;
      return HlsDownloadProgress(
        stream: stream,
        segments: segments,
        bytes: bytes,
      );
    } on Object {
      return null;
    }
  }
}

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

/// AES-128-CBC + PKCS7 解一个分片（native/fushi_compute，整片一次 FFI 调用）。
///
/// 原生库是硬依赖：缺失时抛 [FushiComputeUnavailableError]。长度不是块长整数倍 /
/// key、IV 长度非法 / 填充非法抛 [ArgumentError]（与原 pointycastle 实现同形态）。
Uint8List decryptHlsSegment(Uint8List data, Uint8List key, Uint8List iv) =>
    FushiComputeCrypto.instance.aesCbcPkcs7Decrypt(data, key, iv);

/// 分片的真实媒体字节：图片伪装前缀剥掉（BUG-2609），其余原样。
Uint8List unwrapHlsSegmentPayload(Uint8List bytes) {
  if (!looksLikeImagePrefix(bytes)) return bytes;
  final int? offset = disguisedMediaPayloadOffset(bytes);
  if (offset == null || offset <= 0) return bytes;
  return Uint8List.sublistView(bytes, offset);
}

/// 一份已下完的分量字节来自哪条流：直链用响应验证器（ETag / Last-Modified / 总长），
/// HLS 用流指纹（[hlsStreamFingerprint]，不含签名 query，换签名不算换流）。落在
/// `<component>.done` 侧车，重跑时与现取的流身份比对，一致才复用完整分量。
@immutable
class AnimeComponentIdentity {
  const AnimeComponentIdentity.direct(DirectStreamValidator this.direct)
    : hlsStream = null;
  const AnimeComponentIdentity.hls(String this.hlsStream) : direct = null;

  final DirectStreamValidator? direct;
  final String? hlsStream;

  String encode() => jsonEncode(<String, Object?>{
    if (hlsStream != null) 'hls': hlsStream,
    if (direct != null) 'direct': jsonDecode(direct!.encode()),
  });

  /// 坏 JSON / 空身份返回 null，**绝不抛**（当作没有侧车 → 不复用）。
  static AnimeComponentIdentity? tryParse(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      final Object? hls = decoded['hls'];
      if (hls is String && hls.isNotEmpty) {
        return AnimeComponentIdentity.hls(hls);
      }
      final Object? direct = decoded['direct'];
      if (direct is! Map<String, Object?>) return null;
      final DirectStreamValidator? validator = DirectStreamValidator.tryParse(
        jsonEncode(direct),
      );
      if (validator == null || validator.isEmpty) return null;
      return AnimeComponentIdentity.direct(validator);
    } on Object {
      return null;
    }
  }

  /// 是否同一份字节：HLS 比指纹；直链两边都有的字段逐一比对，任一不同即不是，
  /// **一个可比字段都没有也算不是**（宁可重下，也不拿来路不明的分量去合成）。
  bool matches(AnimeComponentIdentity other) {
    final String? stream = hlsStream;
    if (stream != null) return stream == other.hlsStream;
    final DirectStreamValidator? mine = direct;
    final DirectStreamValidator? theirs = other.direct;
    if (mine == null || theirs == null) return false;
    int compared = 0;
    bool same<T>(T? a, T? b) {
      if (a == null || b == null) return true;
      compared++;
      return a == b;
    }

    if (!same<String>(mine.etag, theirs.etag)) return false;
    if (!same<String>(mine.lastModified, theirs.lastModified)) return false;
    if (!same<int>(mine.totalBytes, theirs.totalBytes)) return false;
    return compared > 0;
  }
}

typedef AnimeEpisodeHttpClientFactory = HttpClient Function();

/// 一集的整片下载器。
class AnimeEpisodeDownloader {
  AnimeEpisodeDownloader({
    AnimeEpisodeHttpClientFactory? httpClientFactory,
    FfmpegBackend Function()? ffmpeg,
    this.stallTimeout = kAnimeEpisodeStallTimeout,
  }) : _httpClientFactory = httpClientFactory ?? createAppHttpClient,
       _ffmpeg = ffmpeg ?? resolveFfmpegBackend;

  final AnimeEpisodeHttpClientFactory _httpClientFactory;
  final FfmpegBackend Function() _ffmpeg;

  /// 首字节 / 流内空闲超时（测试可调短）。
  final Duration stallTimeout;

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
    await _downloadIdentified(
      url: url,
      headers: headers,
      dest: dest,
      onProgress: onProgress,
      onBytes: onBytes,
      cancelSignal: cancelSignal,
    );
  }

  /// [download] 的本体：下完后返回这份字节的流身份（直链响应的验证器 / HLS 流指纹；
  /// 直链一个验证器都没给时为 null），供分量的 `.done` 侧车落盘。
  Future<AnimeComponentIdentity?> _downloadIdentified({
    required String url,
    required Map<String, String> headers,
    required File dest,
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) async {
    final HttpClient client = _httpClientFactory();
    // 连不上要快速失败：工厂（createAppHttpClient）一般已经设了连接超时，没设的
    // （测试 / 别的工厂）补上同一个默认值。
    client.connectionTimeout ??= kAppHttpConnectionTimeout;
    client.idleTimeout = kAnimeEpisodeIdleConnectionTimeout;
    bool cancelled = false;
    unawaited(
      cancelSignal?.then((_) {
        cancelled = true;
        client.close(force: true);
      }),
    );
    AnimeComponentIdentity? identity;
    try {
      await dest.parent.create(recursive: true);
      if (looksLikeHlsUrl(url)) {
        identity = AnimeComponentIdentity.hls(
          await _downloadHls(
            client,
            Uri.parse(url),
            headers,
            dest,
            onProgress: onProgress,
            isCancelled: () => cancelled,
          ),
        );
      } else {
        final DirectStreamValidator? validator = await _downloadDirect(
          client,
          url,
          headers,
          dest,
          onProgress: onProgress,
          onBytes: onBytes,
        );
        identity = validator == null || validator.isEmpty
            ? null
            : AnimeComponentIdentity.direct(validator);
        // 有的 hoster 的 m3u8 地址没有后缀：下回来的其实是播放列表文本，按内容认出
        // 来就改走分片下载（播放列表很小，这一趟白下的代价可以忽略）。
        if (await _isPlaylistFile(dest)) {
          await dest.delete();
          identity = AnimeComponentIdentity.hls(
            await _downloadHls(
              client,
              Uri.parse(url),
              headers,
              dest,
              onProgress: onProgress,
              isCancelled: () => cancelled,
            ),
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
    return identity;
  }

  /// DASH 分离流（EXlaIL2eKQ）：画面流 + 扩展给的外挂音轨各自下载（直链 / HLS 同
  /// [download]，各自 `.part` 断点续传），再本地 `ffmpeg -c copy` 合成一个文件。
  ///
  /// 映射顺序：画面、画面自带音轨（若有，`0:a?`）、外挂音轨按序——与播放时
  /// `audio-add ... auto` 的默认选轨一致：自带原声的流仍默认放原声，纯视频流默认
  /// 放第一条外挂音频。输出用 Matroska（任意编码组合都装得下；mpv 按内容识别
  /// 容器，不看扩展名）。
  ///
  /// 外挂音轨既可能是 DASH 分离流的**唯一音频**，也可能是流自带原声之外的**替代
  /// 配音**：画面下完后用 ffprobe 看它有没有自带音轨。单条外挂音轨下载失败一律跳过
  /// 并记错误日志；只有画面没有（或探不出有）自带音轨、而外挂音轨又一条都没下成时
  /// 才如实抛出第一条的错误——留一个无声视频当「下载成功」正是本问题本身，而一条
  /// 替代配音 403 不该让整集带原声的下载失败。合成失败同样如实抛错。
  ///
  /// 暂停 / 续传：每个下完的分量旁落 `.done` 流身份侧车（[AnimeComponentIdentity]），
  /// 重跑时现取一次流身份（直链 `Range: bytes=0-0` 只读响应头 / HLS 取播放列表）比对，
  /// 一致就复用完整分量，不一致（换了画质 / 线路 / 源站换了文件）或比不出来才删掉
  /// 重下；未下完的 `.part` 仍由 [download] 按验证器续传。
  Future<void> downloadWithExternalAudio({
    required String url,
    required List<String> audioUrls,
    required Map<String, String> headers,
    required File dest,
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) async {
    if (audioUrls.isEmpty) {
      await download(
        url: url,
        headers: headers,
        dest: dest,
        onProgress: onProgress,
        onBytes: onBytes,
        cancelSignal: cancelSignal,
      );
      return;
    }
    bool cancelled = false;
    unawaited(cancelSignal?.then((_) => cancelled = true));
    final File video = File('${dest.path}$kAnimeVideoComponentSuffix');
    final List<File> audios = <File>[
      for (int i = 0; i < audioUrls.length; i++)
        File('${dest.path}${animeAudioComponentSuffix(i)}'),
    ];
    const double videoShare = 0.8;
    final double audioShare = (0.95 - videoShare) / audioUrls.length;
    await _downloadComponent(
      url: url,
      headers: headers,
      component: video,
      onProgress: onProgress == null
          ? null
          : (double value) => onProgress(value * videoShare),
      onBytes: onBytes,
      cancelSignal: cancelSignal,
    );
    final bool? videoHasAudio = await _probeHasAudioStream(video);
    final List<File> ready = <File>[];
    Object? firstError;
    StackTrace? firstStack;
    for (int i = 0; i < audioUrls.length; i++) {
      final double base = videoShare + audioShare * i;
      try {
        await _downloadComponent(
          url: audioUrls[i],
          headers: headers,
          component: audios[i],
          onProgress: onProgress == null
              ? null
              : (double value) => onProgress(base + value * audioShare),
          cancelSignal: cancelSignal,
        );
        ready.add(audios[i]);
      } on RemoteDownloadCancelled {
        rethrow;
      } on Object catch (error, stack) {
        if (cancelled) throw const RemoteDownloadCancelled();
        firstError ??= error;
        firstStack ??= stack;
        ErrorLogService.instance.log(
          'AnimeEpisodeDownloader.externalAudioTrack',
          StateError(
            'external audio track $i of ${dest.path} failed, skipped '
            '(video has own audio: ${videoHasAudio ?? 'unknown'}): $error',
          ),
          stack,
        );
      }
    }
    if (ready.isEmpty && videoHasAudio != true) {
      // 画面没有自带音轨（或探不出来）、外挂音频又一条都没下成：成品只会是无声视频。
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
    final File muxed = File('${dest.path}$kAnimeMuxSuffix');
    if (await muxed.exists()) await muxed.delete();
    final FfmpegRunResult result = await _ffmpeg().run(
      buildExternalAudioMuxArgs(
        videoPath: video.path,
        audioPaths: <String>[for (final File f in ready) f.path],
        outputPath: muxed.path,
      ),
      const Duration(minutes: 30),
    );
    if (result.returnCode != 0 ||
        !await muxed.exists() ||
        await muxed.length() == 0) {
      if (await muxed.exists()) await muxed.delete();
      final String output = result.output;
      // 已下完的分量与 `.done` 侧车留着：重试直接复用，放弃时由
      // [deleteAnimeEpisodeDownloadLeftovers] 一并删掉。
      throw StateError(
        'ffmpeg mux of separate audio for ${dest.path} failed '
        '(exit ${result.returnCode}): '
        '${output.length > 2000 ? output.substring(output.length - 2000) : output}',
      );
    }
    if (await dest.exists()) await dest.delete();
    await muxed.rename(dest.path);
    // 分量、`.done` 侧车、跳过的音轨留下的 `.part` 等全部清掉。
    await deleteAnimeEpisodeDownloadLeftovers(dest);
    onProgress?.call(1.0);
  }

  /// 下一个分量：已有完整分量且 `.done` 侧车的流身份与现取的一致就直接复用；否则
  /// 删掉完整分量（`.part` 留给 [download] 按验证器续传）重下，下完落新侧车。
  Future<void> _downloadComponent({
    required String url,
    required Map<String, String> headers,
    required File component,
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) async {
    final File done = File('${component.path}$kAnimeComponentDoneSuffix');
    if (await component.exists()) {
      final AnimeComponentIdentity? stored = await _readComponentIdentity(done);
      if (stored != null &&
          await _componentLengthPlausible(component, stored)) {
        final AnimeComponentIdentity? now = await _probeIdentity(
          url,
          headers,
          stored,
          cancelSignal,
        );
        if (now != null && stored.matches(now)) {
          onProgress?.call(1.0);
          return;
        }
      }
      await component.delete();
    }
    await _deleteQuietly(done);
    final AnimeComponentIdentity? identity = await _downloadIdentified(
      url: url,
      headers: headers,
      dest: component,
      onProgress: onProgress,
      onBytes: onBytes,
      cancelSignal: cancelSignal,
    );
    if (identity == null) return; // 比不出身份：下次重跑照常重下。
    try {
      await done.writeAsString(identity.encode(), flush: true);
    } on Object catch (error) {
      debugPrint('[anime-download] component identity write failed: $error');
    }
  }

  static Future<AnimeComponentIdentity?> _readComponentIdentity(
    File file,
  ) async {
    try {
      if (!await file.exists()) return null;
      return AnimeComponentIdentity.tryParse(await file.readAsString());
    } on Object {
      return null;
    }
  }

  /// 直链分量的长度必须等于侧车记下的总长（被截断 / 被改过的分量不复用）。
  static Future<bool> _componentLengthPlausible(
    File component,
    AnimeComponentIdentity stored,
  ) async {
    final int length = await component.length();
    if (length == 0) return false;
    final int? total = stored.direct?.totalBytes;
    return total == null || total == length;
  }

  /// 现取一次 [url] 的流身份（与 [stored] 同类）：HLS 取播放列表算指纹；直链发
  /// `Range: bytes=0-0` 只读响应头。网络失败 / 非 2xx / 一个验证器都没有返回 null
  /// （比不出来 → 不复用）；取消如实抛 [RemoteDownloadCancelled]。
  Future<AnimeComponentIdentity?> _probeIdentity(
    String url,
    Map<String, String> headers,
    AnimeComponentIdentity stored,
    Future<void>? cancelSignal,
  ) async {
    final HttpClient client = _httpClientFactory();
    client.connectionTimeout ??= kAppHttpConnectionTimeout;
    client.idleTimeout = kAnimeEpisodeIdleConnectionTimeout;
    bool cancelled = false;
    unawaited(
      cancelSignal?.then((_) {
        cancelled = true;
        client.close(force: true);
      }),
    );
    try {
      final Uri uri = Uri.parse(url);
      if (stored.hlsStream != null) {
        final ({HlsMediaPlaylist playlist, Uri uri}) media =
            await _loadMediaPlaylist(client, uri, headers);
        return AnimeComponentIdentity.hls(
          hlsStreamFingerprint(media.uri, media.playlist),
        );
      }
      final ResumableDownloadResponse response = await _open(
        client,
        uri,
        <String, String>{...headers, HttpHeaders.rangeHeader: 'bytes=0-0'},
      ).timeout(stallTimeout);
      await _abandon(response);
      final int status = response.statusCode;
      if (status != HttpStatus.partialContent && status != HttpStatus.ok) {
        return null;
      }
      final int? total = status == HttpStatus.partialContent
          ? DirectStreamValidator._contentRangeTotal(
              response.header(HttpHeaders.contentRangeHeader),
            )
          : int.tryParse(
              response.header(HttpHeaders.contentLengthHeader) ?? '',
            );
      final String? etag = response.header(HttpHeaders.etagHeader);
      final String? modified = response.header(HttpHeaders.lastModifiedHeader);
      final DirectStreamValidator validator = DirectStreamValidator(
        etag: etag == null || etag.isEmpty ? null : etag,
        lastModified: modified == null || modified.isEmpty ? null : modified,
        totalBytes: total,
      );
      return validator.isEmpty
          ? null
          : AnimeComponentIdentity.direct(validator);
    } on Object catch (error) {
      if (cancelled) throw const RemoteDownloadCancelled();
      debugPrint('[anime-download] component identity probe failed: $error');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 画面分量有没有自带音轨（ffprobe 列音频流）。探不出来（缺 ffprobe / 超时 /
  /// 非 0 退出）返回 null——调用方把「不知道」当「可能没有」处理。
  Future<bool?> _probeHasAudioStream(File video) async {
    try {
      final FfmpegRunResult result = await _ffmpeg().runProbe(<String>[
        '-v',
        'error',
        '-select_streams',
        'a',
        '-show_entries',
        'stream=index',
        '-of',
        'csv=p=0',
        video.path,
      ], const Duration(seconds: 30));
      if (result.returnCode != 0) return null;
      return result.output.trim().isNotEmpty;
    } on Object catch (error) {
      debugPrint('[anime-download] audio stream probe failed: $error');
      return null;
    }
  }

  /// 纯函数：画面 + 外挂音轨的 `ffmpeg -c copy` 合成参数（见
  /// [downloadWithExternalAudio]）。
  @visibleForTesting
  static List<String> buildExternalAudioMuxArgs({
    required String videoPath,
    required List<String> audioPaths,
    required String outputPath,
  }) {
    return <String>[
      '-hide_banner',
      '-y',
      '-i',
      videoPath,
      for (final String audio in audioPaths) ...<String>['-i', audio],
      '-map',
      '0:v',
      '-map',
      '0:a?',
      for (int i = 0; i < audioPaths.length; i++) ...<String>[
        '-map',
        '${i + 1}:a',
      ],
      '-c',
      'copy',
      '-f',
      'matroska',
      outputPath,
    ];
  }

  Future<DirectStreamValidator?> _downloadDirect(
    HttpClient client,
    String url,
    Map<String, String> headers,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
  }) async {
    final File part = File('${dest.path}.part');
    final File validatorFile = File('${dest.path}$kAnimeDirectValidatorSuffix');
    final DirectStreamValidator? stored = await _readValidator(validatorFile);
    if ((stored == null || stored.isEmpty) && await part.exists()) {
      // 没有可比对的身份（旧版本留下的 part / 上次服务器一个验证器都没给）：
      // 宁可从 0 重下，也不冒把两条流拼成坏片的险。
      await part.delete();
    }
    DirectStreamValidator? latest;
    final ResumableDownloader downloader = ResumableDownloader(
      url: url,
      destination: dest,
      partFile: part,
      resumeState: stored == null
          ? null
          : ResumableDownloadState(
              etag: stored.etag,
              lastModified: stored.lastModified,
            ),
      firstByteTimeout: stallTimeout,
      bodyTimeout: stallTimeout,
      open: (Uri uri, Map<String, String> rangeHeaders) async {
        final ResumableDownloadResponse response = await _open(
          client,
          uri,
          <String, String>{...headers, ...rangeHeaders},
        );
        final bool resumed =
            rangeHeaders.containsKey(HttpHeaders.rangeHeader) &&
            response.statusCode == HttpStatus.partialContent;
        if (!resumed || stored == null || stored.sameStreamAs(response)) {
          return response;
        }
        // 服务器无视 If-Range 照回 206，但 ETag / 总长已经变了：这条响应作废，不带
        // Range 重开——ResumableDownloader 见到 200 就丢弃旧 part 从 0 写。
        await _abandon(response);
        return _open(client, uri, headers);
      },
      onMeta: (ResumableDownloadMetaInfo meta) {
        // 本次响应的验证器落侧车（与 .part 配对），供中断后下一次续传比对。
        final DirectStreamValidator validator = DirectStreamValidator(
          etag: meta.etag,
          lastModified: meta.lastModified,
          totalBytes: meta.totalBytes,
        );
        latest = validator;
        _writeValidatorSync(validatorFile, validator);
      },
      onProgress: (int received, int? total) {
        onBytes?.call(received, total);
        if (total != null && total > 0) onProgress?.call(received / total);
      },
    );
    try {
      await downloader.download();
    } finally {
      // 下完（part 已换名成 dest）清侧车；失败 / 中断保留（与 .part 配对供续传）。
      if (!await part.exists()) await _deleteQuietly(validatorFile);
    }
    return latest;
  }

  static Future<DirectStreamValidator?> _readValidator(File file) async {
    try {
      if (!await file.exists()) return null;
      return DirectStreamValidator.tryParse(await file.readAsString());
    } on Object {
      return null;
    }
  }

  /// onMeta 是同步回调：侧车很小，同步写保证它先于 body 落盘。写失败只损失续传
  /// 能力（下次没有侧车 → 从 0），不影响本次下载。
  static void _writeValidatorSync(File file, DirectStreamValidator validator) {
    try {
      if (validator.isEmpty) {
        if (file.existsSync()) file.deleteSync();
        return;
      }
      file.writeAsStringSync(validator.encode(), flush: true);
    } on Object catch (error) {
      debugPrint('[anime-download] validator write failed: $error');
    }
  }

  static Future<void> _abandon(ResumableDownloadResponse response) async {
    try {
      await response.stream.listen(null).cancel();
    } on Object {
      // 丢弃中的响应出什么错都无所谓。
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // best-effort
    }
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
    // 首字节与流内空闲都有上限：卡死的分片抛 TimeoutException（任务失败、断点
    // 记录留着，重试从这一片接着下），而不是永远挂着。
    final HttpClientResponse response = await request.close().timeout(
      stallTimeout,
    );
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in response.timeout(stallTimeout)) {
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
  /// 连同它的最终地址一起返回（流指纹要用）。
  Future<({HlsMediaPlaylist playlist, Uri uri})> _loadMediaPlaylist(
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
        return (
          playlist: parseHlsMediaPlaylist(text, response.finalUri),
          uri: response.finalUri,
        );
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

  Future<String> _downloadHls(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
    File dest, {
    required bool Function() isCancelled,
    void Function(double progress)? onProgress,
  }) async {
    final ({HlsMediaPlaylist playlist, Uri uri}) media =
        await _loadMediaPlaylist(client, uri, headers);
    final HlsMediaPlaylist playlist = media.playlist;
    final List<HlsSegment> segments = playlist.segments;
    if (segments.isEmpty) {
      throw const AnimeEpisodeDownloadUnsupported('empty HLS playlist');
    }
    final String fingerprint = hlsStreamFingerprint(media.uri, playlist);
    final File part = File('${dest.path}.hls.part');
    final File progressFile = File('${dest.path}.hls.progress');
    // 断点：记的是「流指纹 + 已完整写入的分片数 + 字节数」。指纹对不上（这次取到的
    // 是另一条流）或记录读不懂就从头来；part 比记录长（上次写到一半被杀）就截回
    // 记录的长度；比记录短（part 被删 / 被截）也从头来。
    int done = 0;
    int written = 0;
    if (await progressFile.exists() && await part.exists()) {
      final HlsDownloadProgress? record = HlsDownloadProgress.tryParse(
        await progressFile.readAsString(),
      );
      final int length = await part.length();
      if (record != null &&
          record.stream == fingerprint &&
          record.segments <= segments.length &&
          length >= record.bytes) {
        done = record.segments;
        written = record.bytes;
      }
    }
    // 从头来：旧记录（别的流 / 读不懂）一并作废，part 下面以 write 模式截空。
    if (done == 0) await _deleteQuietly(progressFile);
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
        await progressFile.writeAsString(
          HlsDownloadProgress(
            stream: fingerprint,
            segments: index + 1,
            bytes: written,
          ).encode(),
          flush: true,
        );
        onProgress?.call((index + 1) / segments.length);
      }
    } finally {
      await sink.close();
    }
    await _finishHls(part, dest, fragmented: playlist.isFragmentedMp4);
    if (await progressFile.exists()) await progressFile.delete();
    return fingerprint;
  }

  /// 分片流 → mp4：`-c copy` 转封装（TS 里的 ADTS AAC 要 `aac_adtstoasc`）。
  /// 只映射音视频（`0:v?` / `0:a?`）：TS 里常混着 timed ID3 / SCTE-35 等数据流，
  /// mp4 muxer 装不下它们，`-map 0` 会让整次转封装失败。
  /// 转封装失败原样保留分片流（mpv 按内容识别容器），不当下载失败，但记进错误
  /// 日志——用户拿到的是 TS 而不是 mp4，排障时要看得到为什么。
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
        '0:v?',
        '-map',
        '0:a?',
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
      final String output = result.output;
      ErrorLogService.instance.log(
        'AnimeEpisodeDownloader.remux',
        StateError(
          'ffmpeg remux of ${dest.path} failed '
          '(exit ${result.returnCode}); keeping the segment stream: '
          '${output.length > 2000 ? output.substring(output.length - 2000) : output}',
        ),
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'AnimeEpisodeDownloader.remuxUnavailable',
        error,
        stack,
      );
    }
    if (await remuxed.exists()) await remuxed.delete();
    await part.rename(dest.path);
  }
}
