import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart' show AudioCue;
import 'package:hibiki/src/media/video/youtube_source_resolver.dart';
import 'package:hibiki/src/mining/youtube_clip_miner.dart';

YoutubeResolvedSource _fakeSource({required bool muxed}) => YoutubeResolvedSource(
      streamUrl: 'https://v/play',
      audioStreamUrl: muxed ? null : 'https://v/audio',
      miningVideoUrl: 'https://v/mine',
      miningVideoHasAudio: muxed,
      title: 'T',
      httpHeaders: const <String, String>{},
      cues: const <AudioCue>[],
    );

void main() {
  test('separate streams -> audioSource is the audio-only url', () async {
    int calls = 0;
    final YoutubeClipMiner miner = YoutubeClipMiner(
      resolve: (String url) async {
        calls++;
        return _fakeSource(muxed: false);
      },
      now: () => DateTime(2026, 1, 1),
    );
    final YoutubeClipRequest r = await miner.buildRequest(
      videoId: 'abc',
      startMs: 1000,
      endMs: 4000,
      fields: <String, String>{'sentence': 's'},
      sentence: 's',
    );
    expect(r.mediaSource, 'https://v/mine');
    expect(r.audioSource, 'https://v/audio');
    expect(r.clipStartMs, 1000);
    expect(r.clipEndMs, 4000);
    expect(r.documentTitle, 'T');
    expect(calls, 1);
  });

  test('muxed fallback -> audioSource null (engine takes audio from muxed)',
      () async {
    final YoutubeClipMiner miner = YoutubeClipMiner(
      resolve: (String url) async => _fakeSource(muxed: true),
      now: () => DateTime(2026, 1, 1),
    );
    final YoutubeClipRequest r = await miner.buildRequest(
      videoId: 'abc',
      startMs: 0,
      endMs: 2000,
      fields: <String, String>{},
      sentence: 's',
    );
    expect(r.mediaSource, 'https://v/mine');
    expect(r.audioSource, isNull);
  });

  test('same videoId within TTL resolves once (cache hit)', () async {
    int calls = 0;
    DateTime clock = DateTime(2026, 1, 1, 0, 0, 0);
    final YoutubeClipMiner miner = YoutubeClipMiner(
      resolve: (String url) async {
        calls++;
        return _fakeSource(muxed: false);
      },
      now: () => clock,
    );
    await miner.buildRequest(
        videoId: 'abc',
        startMs: 0,
        endMs: 1000,
        fields: const <String, String>{},
        sentence: 'a');
    clock = clock.add(const Duration(seconds: 30));
    await miner.buildRequest(
        videoId: 'abc',
        startMs: 2000,
        endMs: 3000,
        fields: const <String, String>{},
        sentence: 'b');
    expect(calls, 1);
  });

  test('cache expires after TTL', () async {
    int calls = 0;
    DateTime clock = DateTime(2026, 1, 1, 0, 0, 0);
    final YoutubeClipMiner miner = YoutubeClipMiner(
      resolve: (String url) async {
        calls++;
        return _fakeSource(muxed: false);
      },
      now: () => clock,
    );
    await miner.buildRequest(
        videoId: 'abc',
        startMs: 0,
        endMs: 1000,
        fields: const <String, String>{},
        sentence: 'a');
    clock = clock.add(const Duration(minutes: 5));
    await miner.buildRequest(
        videoId: 'abc',
        startMs: 0,
        endMs: 1000,
        fields: const <String, String>{},
        sentence: 'a');
    expect(calls, 2);
  });
}
