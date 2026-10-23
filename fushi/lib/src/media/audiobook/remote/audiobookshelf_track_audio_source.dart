/// Audiobookshelf 一条音轨的按需流式源。
///
/// 播放器（经 just_audio 的 127.0.0.1 本机代理）每次 seek / 缓冲都会带着字节区间来
/// 要数据；这里把区间转成对服务器的 Range 请求，令牌**每次请求现取**，过期了就在
/// [AudiobookshelfApi.openRange] 里刷新重试——所以播放一小时以后再 seek 也不会 401。
///
/// 为什么不直接 `AudioSource.uri(url, headers: …)`：请求头在建源时就固定了，一小时后
/// 令牌过期，之后的 seek / 换轨 / 断线重连全部 401；写 `?token=` 则会让令牌出现在
/// URL 里（ffmpeg 失败日志会打印输入地址）。走本机代理还有个好处：原生播放器看到的
/// 只是回环明文，服务器的 TLS / 自签证书 / 明文策略都不影响它。
///
/// just_audio 把 [StreamAudioSource] 标成 experimental（0.9.x 起 API 未变）；升级
/// just_audio 时先跑 `audiobookshelf_track_audio_source_test.dart`。
// ignore_for_file: experimental_member_use
library;

import 'dart:async';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

class AudiobookshelfTrackAudioSource extends StreamAudioSource {
  AudiobookshelfTrackAudioSource({
    required AudiobookshelfApi api,
    required this.itemId,
    required this.ino,
    this.mimeType,
    this.sizeBytes,
  }) : _api = api,
       super(tag: 'abs:$itemId:$ino');

  final AudiobookshelfApi _api;
  final String itemId;
  final String ino;
  final String? mimeType;

  /// 服务器报的文件大小；未知时从响应头推。
  final int? sizeBytes;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    // just_audio 的 end 是**开区间**，HTTP Range 的 end 是闭区间。
    final int? firstByte = start;
    final int? lastByte = end == null ? null : end - 1;
    final http.StreamedResponse response = await _api.openRange(
      _api.fileUri(itemId, ino),
      start: firstByte,
      end: lastByte,
    );

    final int offset = firstByte ?? 0;
    final int? total = sizeBytes ?? audiobookshelfTotalLength(response);
    // 服务器没按 Range 回 206（回了整份 200）：自己跳过 offset 之前的字节。
    final bool ranged = response.statusCode == 206;
    Stream<List<int>> body = response.stream;
    if (!ranged && offset > 0) body = _skip(body, offset);
    if (lastByte != null && !ranged) body = _take(body, lastByte - offset + 1);

    final int? contentLength = _contentLength(
      response,
      ranged: ranged,
      offset: offset,
      lastByte: lastByte,
      total: total,
    );
    return StreamAudioResponse(
      sourceLength: total,
      contentLength: contentLength,
      offset: offset,
      stream: body,
      contentType: audiobookshelfPlayableMime(mimeType),
    );
  }

  static int? _contentLength(
    http.StreamedResponse response, {
    required bool ranged,
    required int offset,
    required int? lastByte,
    required int? total,
  }) {
    if (ranged) return response.contentLength;
    final int? whole = response.contentLength ?? total;
    if (whole == null) return null;
    final int available = whole - offset;
    if (lastByte == null) return available;
    final int wanted = lastByte - offset + 1;
    return wanted < available ? wanted : available;
  }

  static Stream<List<int>> _skip(Stream<List<int>> source, int count) async* {
    int remaining = count;
    await for (final List<int> chunk in source) {
      if (remaining >= chunk.length) {
        remaining -= chunk.length;
        continue;
      }
      yield remaining == 0 ? chunk : chunk.sublist(remaining);
      remaining = 0;
    }
  }

  static Stream<List<int>> _take(Stream<List<int>> source, int count) async* {
    int remaining = count;
    await for (final List<int> chunk in source) {
      if (remaining <= 0) return;
      if (chunk.length <= remaining) {
        remaining -= chunk.length;
        yield chunk;
      } else {
        yield chunk.sublist(0, remaining);
        return;
      }
    }
  }
}

/// 响应里的文件总大小：206 取 `Content-Range: bytes a-b/total` 的 total，200 取
/// `Content-Length`。取不到返回 null。
int? audiobookshelfTotalLength(http.StreamedResponse response) {
  final String? range = response.headers['content-range'];
  if (range != null) {
    final int slash = range.lastIndexOf('/');
    if (slash >= 0) {
      final int? total = int.tryParse(range.substring(slash + 1).trim());
      if (total != null) return total;
    }
  }
  return response.statusCode == 200 ? response.contentLength : null;
}

/// 播放器认的 MIME。`.m4b` 的 `audio/x-m4b` 在各平台解码器里不一定被认，实质就是
/// MP4 音频；缺失时按最常见的 mp3。
String audiobookshelfPlayableMime(String? mime) {
  final String value = (mime ?? '').trim().toLowerCase();
  if (value.isEmpty) return 'audio/mpeg';
  if (value == 'audio/x-m4b' || value == 'audio/m4b') return 'audio/mp4';
  return value;
}
