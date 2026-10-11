/// 一句 TTS 音频的按需流式源：播放器（经 just_audio 本机代理）请求时才向调度器要
/// 这一句，没合成好就挂起等待——播放器表现为缓冲中，合成完从文件按 Range 返回。
///
/// just_audio 把 [StreamAudioSource] 标成 experimental（0.9.x 起 API 未变）；升级
/// just_audio 时先跑 `tts_sentence_audio_source_test.dart`。
// ignore_for_file: experimental_member_use
library;

import 'dart:io';

import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_synthesis_scheduler.dart';
import 'package:just_audio/just_audio.dart';

class TtsSentenceAudioSource extends StreamAudioSource {
  TtsSentenceAudioSource({
    required TtsSynthesisScheduler scheduler,
    required this.index,
  }) : _scheduler = scheduler,
       super(tag: 'tts:$index');

  final TtsSynthesisScheduler _scheduler;
  final int index;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final TtsCachedAudio audio = await _scheduler.ensure(index);
    final File file = File(audio.path);
    final int length = await file.length();
    final int from = (start ?? 0).clamp(0, length);
    final int to = (end ?? length).clamp(from, length);
    return StreamAudioResponse(
      sourceLength: length,
      contentLength: to - from,
      offset: from,
      stream: file.openRead(from, to),
      contentType: audio.format.mimeType,
    );
  }
}
