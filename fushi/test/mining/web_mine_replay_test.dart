import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/web_mine_replay.dart';

/// 假宿主：位置只在「播放中」且假时钟推进时前移；seek 立刻落位（页面轮询相位由
/// 假时钟的 100 ms 粒度模拟）。
class _FakeHost implements WebMineReplayHost {
  _FakeHost(this.clock);

  final _FakeClock clock;
  int pos = 0;
  bool playing = false;
  bool seekLands = true;
  bool playWorks = true;
  int screenshots = 0;
  int? screenshotAtPos;
  final List<String> log = <String>[];

  @override
  int? get positionMs => pos;

  @override
  bool get isPlaying => playing;

  @override
  Future<void> seek(int ms) async {
    log.add('seek:$ms');
    if (seekLands) pos = ms;
  }

  @override
  Future<void> play() async {
    log.add('play');
    if (playWorks) playing = true;
  }

  @override
  Future<void> pause() async {
    log.add('pause');
    playing = false;
  }

  @override
  Future<Uint8List?> screenshot() async {
    screenshots++;
    screenshotAtPos ??= pos;
    return Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47]);
  }
}

class _FakeClock {
  DateTime now = DateTime(2026, 8, 30, 12);
  _FakeHost? host;

  Future<void> sleep(Duration d) async {
    now = now.add(d);
    final _FakeHost? h = host;
    if (h != null && h.playing) h.pos += d.inMilliseconds;
  }
}

class _FakeAudio implements GalAudioSource {
  int? lastBackMs;
  bool empty = false;

  @override
  Future<PcmFormat?> start() async => const PcmFormat(
    sampleRate: 48000,
    channels: 2,
    bitsPerSample: 16,
    isFloat: false,
  );

  @override
  Future<void> stop() async {}

  @override
  Future<GalAudioSlice?> grabRecent(int backMs) async {
    lastBackMs = backMs;
    if (empty) return null;
    return GalAudioSlice(
      pcm: Uint8List(48000 * 4 * backMs ~/ 1000),
      format: const PcmFormat(
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
        isFloat: false,
      ),
    );
  }
}

WebMineReplayRunner _runner(
  _FakeHost host,
  _FakeClock clock, {
  GalAudioSource? audio,
  Future<Uint8List?> Function(GalAudioSlice)? encode,
}) {
  return WebMineReplayRunner(
    host: host,
    audioSource: audio,
    encodeAudio:
        encode ?? (GalAudioSlice s) async => Uint8List.fromList(<int>[1, 2, 3]),
    sleep: clock.sleep,
    now: () => clock.now,
  );
}

void main() {
  test('正常路径：seek 到 cue 前 300ms → 播过末尾 → 暂停 → 中点截帧 + 按墙钟回取音频', () async {
    final _FakeClock clock = _FakeClock();
    final _FakeHost host = _FakeHost(clock);
    clock.host = host;
    final _FakeAudio audio = _FakeAudio();
    final WebMineReplayRunner r = _runner(host, clock, audio: audio);

    final WebMineReplayCapture cap = await r.capture(
      cueStartMs: 10000,
      cueEndMs: 13000,
    );

    expect(host.log.first, 'pause');
    expect(host.log, contains('seek:9700'));
    expect(host.log.last, 'pause');
    expect(cap.warnings, isEmpty, reason: cap.warnings.join(','));
    expect(cap.cover, isNotNull);
    expect(host.screenshots, 1);
    // 中点 11500 之后的第一拍截帧（100 ms 轮询粒度）。
    expect(host.screenshotAtPos, inInclusiveRange(11500, 11700));
    // 播到 13250 才停：从 9700 起算 ≈ 3550 ms 播放 + 150 ms 余量。
    expect(audio.lastBackMs, inInclusiveRange(3600, 3900));
    expect(cap.audio, isNotNull);
    expect(host.playing, isFalse);
  });

  test('无 loopback（非 Windows / 插件缺失）：只截帧、audio null、warning 说明', () async {
    final _FakeClock clock = _FakeClock();
    final _FakeHost host = _FakeHost(clock);
    clock.host = host;
    final WebMineReplayRunner r = _runner(host, clock);
    final WebMineReplayCapture cap = await r.capture(
      cueStartMs: 1000,
      cueEndMs: 2000,
    );
    expect(cap.audio, isNull);
    expect(cap.cover, isNotNull);
    expect(cap.warnings, <String>['loopback_unavailable']);
  });

  test('播放起不来（DRM 报错/未登录）：超时后不录音、不截帧、回 play_timeout 并暂停', () async {
    final _FakeClock clock = _FakeClock();
    final _FakeHost host = _FakeHost(clock)..playWorks = false;
    clock.host = host;
    final _FakeAudio audio = _FakeAudio();
    final WebMineReplayRunner r = _runner(host, clock, audio: audio);
    final WebMineReplayCapture cap = await r.capture(
      cueStartMs: 5000,
      cueEndMs: 7000,
    );
    expect(cap.warnings, contains('play_timeout'));
    expect(cap.audio, isNull);
    expect(cap.cover, isNull);
    expect(audio.lastBackMs, isNull, reason: '没播过就不该回取音频');
    expect(host.log.last, 'pause');
  });

  test('seek 不落位：记 seek_timeout 但仍继续播放录制（站点 seek 有时静默）', () async {
    final _FakeClock clock = _FakeClock();
    final _FakeHost host = _FakeHost(clock)
      ..seekLands = false
      ..pos = 20000;
    clock.host = host;
    final _FakeAudio audio = _FakeAudio();
    final WebMineReplayRunner r = _runner(host, clock, audio: audio);
    final WebMineReplayCapture cap = await r.capture(
      cueStartMs: 5000,
      cueEndMs: 6000,
    );
    expect(cap.warnings, contains('seek_timeout'));
    expect(cap.audio, isNotNull);
  });

  test('cue 末尾等不到（站点卡缓冲）：按 cue 长度 + 8 s 硬停，仍暂停并回取已播部分', () async {
    final _FakeClock clock = _FakeClock();
    final _FakeHost host = _FakeHost(clock);
    // 播放中但位置不前进（缓冲）：clock.host 不挂，pos 冻结。
    final _FakeAudio audio = _FakeAudio();
    final WebMineReplayRunner r = _runner(host, clock, audio: audio);
    final WebMineReplayCapture cap = await r.capture(
      cueStartMs: 5000,
      cueEndMs: 6000,
    );
    expect(cap.warnings, contains('cue_end_timeout'));
    expect(host.log.last, 'pause');
    expect(cap.cover, isNotNull, reason: '中点没轮到也要在暂停处补一张');
    expect(audio.lastBackMs, inInclusiveRange(9000, 9300));
  });

  test('loopback 取空 / 编码失败各自落 warning，封面不受影响', () async {
    final _FakeClock clock = _FakeClock();
    final _FakeHost host = _FakeHost(clock);
    clock.host = host;
    final _FakeAudio audio = _FakeAudio()..empty = true;
    WebMineReplayCapture cap = await _runner(
      host,
      clock,
      audio: audio,
    ).capture(cueStartMs: 1000, cueEndMs: 1500);
    expect(cap.warnings, contains('loopback_empty'));
    expect(cap.cover, isNotNull);

    final _FakeHost host2 = _FakeHost(clock);
    clock.host = host2;
    cap = await _runner(
      host2,
      clock,
      audio: _FakeAudio(),
      encode: (GalAudioSlice s) async => null,
    ).capture(cueStartMs: 1000, cueEndMs: 1500);
    expect(cap.warnings, contains('audio_encode_failed'));
    expect(cap.audio, isNull);
  });
}
