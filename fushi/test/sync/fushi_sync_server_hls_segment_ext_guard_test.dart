// BUG-2630 守卫：互联转码 HLS playlist 里的每个 URI 都必须过 FFmpeg hls demuxer 的
// 扩展名白名单，否则随包 libmpv（Android / iOS / macOS 是 FFmpeg 6.1.6，Windows 是
// master 构建）连分段都不会去取。这道门是 2025 年安全加固回移到维护分支的：
// 6.1.3+ / 7.1.1+ / 8.0 有，6.1.0～6.1.2 与 7.0.x / 7.1.0 没有——下面常量名里的
// 「61」指对照的 6.1.6 源码。
//
// FFmpeg 6.1.6 `libavformat/hls.c` `test_segment()`（`extension_picky` 默认开）：
//   matchA = av_match_ext(url, allowed) + 2 * (ff_match_url_ext(url, allowed) > 0)
//   !matchA → "URL … is not in allowed_segment_extensions" → AVERROR_INVALIDDATA
// 探得分段是 mp4 格式时还要 matchF：url 扩展名在 mp4 demuxer 的扩展名表里，或在
// `ts,m2t,m2ts,mts,mpg,m4s,mpeg,mpegts,cmfv,cmfa` 特例里；`!(matchA & matchF)` 也拒。
// `ff_match_url_ext`（`libavformat/format.c`）取 **query 之前**的路径尾扩展名，
// `av_match_name` 逐项整词比对（大小写不敏感）。下面是同一判据的 Dart 移植，用真
// `FushiSyncServer` 签发 playlist、按 hls.c 的方式把相对 URI 解析成绝对 URL 再验。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/live_transcode.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';

/// FFmpeg 6.1.6 `hls.c` 的 `allowed_segment_extensions` 默认值（逐字；8.0 相同）。
const String kFfmpeg61AllowedSegmentExtensions =
    '3gp,aac,avi,ac3,eac3,flac,mkv,m3u8,m4a,m4s,m4v,mpg,mov,mp2,mp3,mp4,mpeg,'
    'mpegts,ogg,ogv,oga,ts,vob,vtt,wav,webvtt,cmfv,cmfa,ec3,fmp4,html';

/// FFmpeg 6.1 mov/mp4 demuxer 的 `extensions`（`libavformat/mov.c`）。
const String kFfmpeg61Mp4DemuxerExtensions =
    'mov,mp4,m4a,3gp,3g2,mj2,psp,m4b,ism,ismv,isma,f4v,avif';

/// `test_segment()` 对 mp4 / aac 分段额外放行的扩展名（YouTube 的 .ts 装 aac）。
const String kFfmpeg61Mp4SegmentExtraExtensions =
    'ts,m2t,m2ts,mts,mpg,m4s,mpeg,mpegts,cmfv,cmfa';

/// `test_segment()` 对探得 mpegts 格式的分段认的扩展名（mpegts demuxer 自己没有
/// `extensions` 表，hls.c 用这张硬编码表）。
const String kFfmpeg61MpegtsSegmentExtensions =
    'ts,m2t,m2ts,mts,mpg,m4s,mpeg,mpegts,html';

/// 分段探出来是什么格式（决定 `test_segment()` 走哪张 matchF 表）。
enum ProbedFormat { mp4, mpegts, none }

/// `av_match_name`：逗号分隔逐项整词比对，`ALL` 通配，大小写不敏感。
bool avMatchName(String name, String names) {
  for (final String candidate in names.split(',')) {
    if (candidate == 'ALL') return true;
    if (candidate.toLowerCase() == name.toLowerCase()) return true;
  }
  return false;
}

/// `av_match_ext`：整个字符串里最后一个 `.` 之后的所有字符当扩展名（含 query）。
bool avMatchExt(String filename, String extensions) {
  final int dot = filename.lastIndexOf('.');
  if (dot < 0) return false;
  return avMatchName(filename.substring(dot + 1), extensions);
}

/// `ff_match_url_ext`：只认绝对 URL；从 query 起点向前找 `.`，不越过 path 起点。
bool ffMatchUrlExt(String url, String extensions) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return false;
  final String path = uri.path;
  final int dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  return avMatchName(path.substring(dot + 1), extensions);
}

/// `test_segment()` 的判定：分段 URL 能不能过 FFmpeg 6.1 的门（[probed] = 分段
/// 探出来的格式；本仓的 TS 分段恒为 [ProbedFormat.mpegts]）。
bool ffmpegHlsAcceptsSegmentUrl(
  String url, {
  ProbedFormat probed = ProbedFormat.mpegts,
}) {
  final int matchA =
      (avMatchExt(url, kFfmpeg61AllowedSegmentExtensions) ? 1 : 0) +
      (ffMatchUrlExt(url, kFfmpeg61AllowedSegmentExtensions) ? 2 : 0);
  if (matchA == 0) return false;
  int matchF;
  switch (probed) {
    case ProbedFormat.none:
      return true;
    case ProbedFormat.mp4:
      matchF =
          (avMatchExt(url, kFfmpeg61Mp4DemuxerExtensions) ? 1 : 0) +
          (ffMatchUrlExt(url, kFfmpeg61Mp4DemuxerExtensions) ? 2 : 0);
      matchF |=
          (avMatchExt(url, kFfmpeg61Mp4SegmentExtraExtensions) ? 1 : 0) +
          (ffMatchUrlExt(url, kFfmpeg61Mp4SegmentExtraExtensions) ? 2 : 0);
    case ProbedFormat.mpegts:
      matchF =
          (avMatchExt(url, kFfmpeg61MpegtsSegmentExtensions) ? 1 : 0) +
          (ffMatchUrlExt(url, kFfmpeg61MpegtsSegmentExtensions) ? 2 : 0);
  }
  return (matchA & matchF) != 0;
}

class _SingleVideoLibrary implements FushiLibraryHostService {
  _SingleVideoLibrary() {
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_hls_ext');
    videoFile = File('${tmp.path}/sample.mp4')
      ..writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
  }

  late final File videoFile;

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      id == 'v1' ? videoFile : null;

  @override
  Future<File?> resolveVideoSubtitle(
    String id, {
    String langCode = '',
    int episodeIndex = 0,
  }) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 不该被本守卫触达');
}

/// ffprobe 替身：固定 15.5 秒，让 playlist 有三段。
class _FixedDurationBackend implements FfmpegBackend {
  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async =>
      FfmpegRunResult(returnCode: 0, output: '');

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      FfmpegRunResult(
        returnCode: 0,
        output: jsonEncode(<String, Object?>{
          'format': <String, Object?>{'duration': '15.5'},
          'streams': <Object?>[],
        }),
      );
}

void main() {
  group('FFmpeg 判据移植自检', () {
    test('裸 hlsseg?token= 被拒：这正是 BUG-2630 的形态', () {
      expect(
        ffmpegHlsAcceptsSegmentUrl(
          'https://127.0.0.1:45777/api/library/videos/v/hlsseg?token=abc&n=0',
        ),
        isFalse,
      );
    });

    test('query 里带点时 av_match_ext 被带偏，靠 ff_match_url_ext 认路径扩展名', () {
      expect(
        ffmpegHlsAcceptsSegmentUrl('https://h/x/hlsseg.m4s?token=a.b&n=0'),
        isTrue,
      );
      expect(
        avMatchExt('https://h/x/hlsseg.m4s?token=a.b&n=0', 'm4s'),
        isFalse,
        reason: 'av_match_ext 只看整串最后一个点，会把 "b&n=0" 当扩展名',
      );
      expect(
        ffMatchUrlExt('https://h/x/hlsseg.m4s?token=a.b&n=0', 'm4s'),
        isTrue,
      );
      // 反过来 av_match_ext 也会把 query 尾巴上的 .m4s 认成扩展名——真 FFmpeg 就是
      // 这样，所以本仓不靠这种巧合，扩展名一律放在路径上。
      expect(ffmpegHlsAcceptsSegmentUrl('https://h/x/seg?token=a.m4s'), isTrue);
    });

    test('相对 URI 不过 ff_match_url_ext（hls.c 会先 ff_make_absolute_url）', () {
      expect(ffMatchUrlExt('hlsseg.m4s?token=a', 'm4s'), isFalse);
      expect(ffMatchUrlExt('https://h/hlsseg.m4s?token=a', 'm4s'), isTrue);
    });
  });

  group('真 host 签发的 playlist', () {
    late FushiSyncServer server;
    late String base;
    late HttpClient client;
    const String token = 'hls-ext-guard-token';

    setUp(() async {
      setFfmpegBackendForTesting(_FixedDurationBackend());
      // 测试里没有可 exec 的 ffmpeg，能力位要显式打开才会签发转码 token。
      setTranscodeAvailableForTesting(true);
      server = FushiSyncServer(
        syncDataDir: Directory.systemTemp
            .createTempSync('hbk_hls_ext_srv')
            .path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: _SingleVideoLibrary(),
      );
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      setFfmpegBackendForTesting(null);
      setTranscodeAvailableForTesting(null);
    });

    Future<String> fetch(String url, {bool withAuth = true}) async {
      final HttpClientRequest req = await client.getUrl(Uri.parse(url));
      if (withAuth) {
        req.headers.set(
          HttpHeaders.authorizationHeader,
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
        );
      }
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200, reason: url);
      return res.transform(utf8.decoder).join();
    }

    test('playlist 的每个分段 URI 都能过 FFmpeg 6.1 的扩展名门', () async {
      final Map<String, dynamic> issued =
          jsonDecode(
                await fetch(
                  '$base/api/library/videos/v1/streamurl'
                  '?maxWidth=854&maxBitrate=800000',
                ),
              )
              as Map<String, dynamic>;
      expect(issued['transcoded'], isTrue);
      final Uri playlistUrl = Uri.parse(issued['url'] as String);
      expect(
        ffMatchUrlExt(playlistUrl.toString(), 'm3u8'),
        isTrue,
        reason: 'playlist 自己也要带 .m3u8',
      );
      final String text = await fetch(playlistUrl.toString(), withAuth: false);

      final List<String> segmentUris = <String>[];
      for (final String line in const LineSplitter().convert(text)) {
        if (line.startsWith('#EXT-X-MAP:')) {
          fail('TS 分段不该有初始化段（fMP4 在 FFmpeg 6.1 客户端 seek 必坏）：$line');
        } else if (line.isNotEmpty && !line.startsWith('#')) {
          segmentUris.add(line);
        }
      }
      expect(segmentUris, hasLength(3));

      // hls.c 先把相对 URI 解析成绝对 URL（ff_make_absolute_url）再验扩展名。
      for (final String uri in segmentUris) {
        final String absolute = playlistUrl.resolve(uri).toString();
        expect(
          ffmpegHlsAcceptsSegmentUrl(absolute, probed: ProbedFormat.mpegts),
          isTrue,
          reason: '分段 $absolute 会被 FFmpeg 6.1 hls demuxer 拒开',
        );
        expect(
          Uri.parse(absolute).path.endsWith('/$kTranscodeSegmentPathSuffix'),
          isTrue,
          reason: '分段路径尾必须是 $kTranscodeSegmentPathSuffix',
        );
      }
    });

    test('分段端点在带扩展名的路径上真的能被路由到（豁免 Basic + token 门）', () async {
      final Map<String, dynamic> issued =
          jsonDecode(
                await fetch(
                  '$base/api/library/videos/v1/streamurl'
                  '?maxWidth=854&maxBitrate=800000',
                ),
              )
              as Map<String, dynamic>;
      final Uri playlistUrl = Uri.parse(issued['url'] as String);
      final Uri segment = playlistUrl.resolve(
        '$kTranscodeSegmentPathSuffix?${playlistUrl.query}&n=99',
      );
      final HttpClientRequest req = await client.getUrl(segment);
      final HttpClientResponse res = await req.close();
      // 越界段号 → 404「Segment out of range」，说明请求已到达分段 handler
      // （没被 Basic 中间件挡成 401、也没落到兜底 404 之外的分支）。
      expect(res.statusCode, 404);
      expect(await res.transform(utf8.decoder).join(), 'Segment out of range');
      final HttpClientRequest bad = await client.getUrl(
        playlistUrl.resolve('$kTranscodeSegmentPathSuffix?n=0'),
      );
      final HttpClientResponse badRes = await bad.close();
      expect(badRes.statusCode, 401, reason: '没 token 仍是 401，门没被放开');
      await badRes.drain<void>();
    });
  });
}
