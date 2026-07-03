import 'dart:async';

import 'package:hibiki/src/media/video/youtube_source_resolver.dart';

/// 解析好的「一句 YouTube 片段制卡请求」的裸值：喂给引擎的 ffmpeg 输入 + 视频时间窗 + 文本。
/// 与 [ImmersionMiningRequest] 解耦（此文件不依赖 anki 层），由 app_model 再套引擎。
class YoutubeClipRequest {
  const YoutubeClipRequest({
    required this.mediaSource,
    required this.audioSource,
    required this.clipStartMs,
    required this.clipEndMs,
    required this.fields,
    required this.sentence,
    required this.cueSentence,
    required this.documentTitle,
  });

  /// GIF/帧的 ffmpeg 输入（低分辨率挖矿流 URL，无则回落播放流）。
  final String mediaSource;

  /// 音频段抽取源：muxed 挖矿流自带音轨时为 null（引擎从 [mediaSource] 抽）；分离流时为
  /// audio-only 流 URL。
  final String? audioSource;
  final int clipStartMs;
  final int clipEndMs;
  final Map<String, String> fields;
  final String sentence;
  final String? cueSentence;
  final String? documentTitle;
}

typedef YoutubeResolver = Future<YoutubeResolvedSource> Function(String url);

/// 批量 YouTube 制卡的流解析层：把 videoId + 视频时间窗解析成 [YoutubeClipRequest]。
/// 内置 TTL 缓存——一次「生成全部」里同一视频的 N 张卡只解析一次流（解析走网络、~数秒）。
/// 缓存的是**进行中的 Future**，故即便多张卡并发解析同一视频也只发一次网络请求；解析失败则从缓存
/// 剔除（不让 rejected future 卡住 TTL 内的重试）。[resolve]/[now] 可注入便于单测。
class YoutubeClipMiner {
  YoutubeClipMiner({
    YoutubeResolver? resolve,
    DateTime Function()? now,
    this.ttl = const Duration(minutes: 3),
  })  : _resolve = resolve ?? ((String url) => resolveYoutubeSource(url)),
        _now = now ?? DateTime.now;

  final YoutubeResolver _resolve;
  final DateTime Function() _now;
  final Duration ttl;
  final Map<String, _CachedSource> _cache = <String, _CachedSource>{};

  Future<YoutubeClipRequest> buildRequest({
    required String videoId,
    required int startMs,
    required int endMs,
    required Map<String, String> fields,
    required String sentence,
    String? cueSentence,
    String? documentTitle,
  }) async {
    final YoutubeResolvedSource src = await _resolvedFor(videoId);
    return YoutubeClipRequest(
      // GIF/帧从低分辨率挖矿流（miningVideoUrl，无则回落播放流）。
      mediaSource: src.miningVideoUrl ?? src.streamUrl,
      // muxed 挖矿流自带音轨 → audioSource=null（引擎从视频源抽音频）；分离流 → audio-only URL。
      audioSource: src.miningVideoHasAudio ? null : src.audioStreamUrl,
      clipStartMs: startMs,
      clipEndMs: endMs,
      fields: fields,
      sentence: sentence,
      cueSentence: cueSentence,
      documentTitle: documentTitle ?? src.title,
    );
  }

  Future<YoutubeResolvedSource> _resolvedFor(String videoId) {
    final DateTime t = _now();
    final _CachedSource? hit = _cache[videoId];
    if (hit != null && t.difference(hit.at) < ttl) return hit.future;
    final Future<YoutubeResolvedSource> fut =
        _resolve('https://www.youtube.com/watch?v=$videoId');
    _cache[videoId] = _CachedSource(fut, t);
    // 失败即从缓存剔除（否则 TTL 内都返回同一个 rejected future，卡住重试）。这个独立监听器
    // 自己吞掉清理分支的错误（不 rethrow），调用方仍从 await fut 拿到原始异常。
    unawaited(fut.then<void>((_) {}, onError: (Object e, StackTrace s) {
      if (identical(_cache[videoId]?.future, fut)) _cache.remove(videoId);
    }));
    return fut;
  }
}

class _CachedSource {
  const _CachedSource(this.future, this.at);
  final Future<YoutubeResolvedSource> future;
  final DateTime at;
}
