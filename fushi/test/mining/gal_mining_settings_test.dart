import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_mining_settings.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart' show PcmFormat;
import 'package:fushi/src/mining/galgame_audio_source.dart' show GalAudioSlice;
import 'package:fushi/src/mining/galgame_line_voice_window.dart'
    show applyGalMiningAudioLimit;
import 'package:fushi_engine/mining/immersion_mining_request.dart';

/// 1 kHz、单声道、16 位：1 ms = 2 字节，便于直接按毫秒断言长度。
const PcmFormat _format = PcmFormat(
  sampleRate: 1000,
  channels: 1,
  bitsPerSample: 16,
  isFloat: false,
);

GalAudioSlice _slice(int ms, {int fill = 0x11}) => GalAudioSlice(
  pcm: Uint8List(ms * 2)..fillRange(0, ms * 2, fill),
  format: _format,
);

int _ms(GalAudioSlice slice) => slice.pcm.length ~/ 2;

const GalMiningSettings _global = GalMiningSettings(
  imageMode: VideoMiningImageMode.gif,
  animatedFormat: MiningAnimatedFormat.avif,
  stillFormat: MiningStillFormat.jpg,
  clipFormat: MiningClipFormat.webmVp9,
  audioLimit: GalMiningAudioLimit(mode: GalMiningAudioMode.auto, seconds: 8),
);

void main() {
  group('applyGalMiningAudioLimit（反馈 II3jOBIhT5）', () {
    test('auto 原样返回，几十秒 BGM 也不动（现状）', () {
      final GalAudioSlice slice = _slice(40000);
      expect(
        identical(
          applyGalMiningAudioLimit(slice, GalMiningAudioLimit.unlimited),
          slice,
        ),
        isTrue,
      );
    });

    test('maxLength 把超长截取截到前 N 秒，保留开头', () {
      final GalAudioSlice slice = _slice(40000);
      slice.pcm[0] = 0x7F;
      final GalAudioSlice limited = applyGalMiningAudioLimit(
        slice,
        const GalMiningAudioLimit(
          mode: GalMiningAudioMode.maxLength,
          seconds: 5,
        ),
      );
      expect(_ms(limited), 5000);
      expect(limited.pcm[0], 0x7F, reason: '窗口从台词到达开始，开头才是这句');
    });

    test('maxLength 不动短于上限的切片', () {
      final GalAudioSlice slice = _slice(1200);
      final GalAudioSlice limited = applyGalMiningAudioLimit(
        slice,
        const GalMiningAudioLimit(
          mode: GalMiningAudioMode.maxLength,
          seconds: 5,
        ),
      );
      expect(identical(limited, slice), isTrue);
    });

    test('fixedLength 长截短补：补的是静音（零值），原内容不变', () {
      const GalMiningAudioLimit fixed = GalMiningAudioLimit(
        mode: GalMiningAudioMode.fixedLength,
        seconds: 3,
      );
      expect(_ms(applyGalMiningAudioLimit(_slice(9000), fixed)), 3000);

      final GalAudioSlice padded = applyGalMiningAudioLimit(
        _slice(1000),
        fixed,
      );
      expect(_ms(padded), 3000);
      expect(padded.pcm.sublist(0, 2000).every((int b) => b == 0x11), isTrue);
      expect(padded.pcm.sublist(2000).every((int b) => b == 0), isTrue);
    });

    test('截断按帧对齐（立体声 16 位不切开半个采样帧）', () {
      const PcmFormat stereo = PcmFormat(
        sampleRate: 44100,
        channels: 2,
        bitsPerSample: 16,
        isFloat: false,
      );
      final GalAudioSlice slice = GalAudioSlice(
        pcm: Uint8List(stereo.byteRate * 10),
        format: stereo,
      );
      final GalAudioSlice limited = applyGalMiningAudioLimit(
        slice,
        const GalMiningAudioLimit(
          mode: GalMiningAudioMode.maxLength,
          seconds: 2,
        ),
      );
      expect(limited.pcm.length % stereo.blockAlign, 0);
      expect(limited.pcm.length, stereo.byteRate * 2);
    });

    test('秒数越界一律夹到 1..60', () {
      expect(
        const GalMiningAudioLimit(
          mode: GalMiningAudioMode.maxLength,
          seconds: 0,
        ).limitMs,
        kGalMiningAudioSecondsMin * 1000,
      );
      expect(
        const GalMiningAudioLimit(
          mode: GalMiningAudioMode.fixedLength,
          seconds: 999,
        ).limitMs,
        kGalMiningAudioSecondsMax * 1000,
      );
      expect(GalMiningAudioLimit.unlimited.limitMs, isNull);
      expect(
        const GalMiningAudioLimit(mode: GalMiningAudioMode.off).skipsAudio,
        isTrue,
      );
    });
  });

  group('GalGameMiningOverrides（反馈 3dRZdakRdJ）', () {
    test('JSON 往返保持每一项', () {
      const GalGameMiningOverrides overrides = GalGameMiningOverrides(
        imageMode: VideoMiningImageMode.currentFrame,
        animatedFormat: MiningAnimatedFormat.webp,
        stillFormat: MiningStillFormat.png,
        clipFormat: MiningClipFormat.mp4H264,
        audioMode: GalMiningAudioMode.off,
        audioSeconds: 12,
      );
      expect(GalGameMiningOverrides.decode(overrides.encode()), overrides);
    });

    test('空覆盖层落空串；空串 / 坏 JSON / 未知值都读成「跟随全局」', () {
      expect(GalGameMiningOverrides.none.encode(), '');
      expect(GalGameMiningOverrides.decode(''), GalGameMiningOverrides.none);
      expect(
        GalGameMiningOverrides.decode('{oops'),
        GalGameMiningOverrides.none,
      );
      expect(GalGameMiningOverrides.decode(null), GalGameMiningOverrides.none);
      final GalGameMiningOverrides dirty = GalGameMiningOverrides.decode(
        '{"imageMode":"subtitle_start","audioMode":"loud",'
        '"stillFormat":"bmp","audioSeconds":"7"}',
      );
      expect(dirty.isEmpty, isTrue);
    });

    test('copyWith 的 clear 把指定项清回跟随全局，其余不动', () {
      const GalGameMiningOverrides overrides = GalGameMiningOverrides(
        audioMode: GalMiningAudioMode.maxLength,
        audioSeconds: 4,
        stillFormat: MiningStillFormat.png,
      );
      final GalGameMiningOverrides cleared = overrides.copyWith(
        clear: const <GalMiningOverrideField>{
          GalMiningOverrideField.audioMode,
          GalMiningOverrideField.audioSeconds,
        },
      );
      expect(cleared.audioMode, isNull);
      expect(cleared.audioSeconds, isNull);
      expect(cleared.stillFormat, MiningStillFormat.png);
    });
  });

  group('GalMiningSettings.resolve', () {
    test('没有覆盖 = 全局', () {
      expect(
        GalMiningSettings.resolve(
          global: _global,
          overrides: GalGameMiningOverrides.none,
        ),
        _global,
      );
    });

    test('覆盖逐项压过全局；只覆盖模式时沿用全局秒数', () {
      final GalMiningSettings resolved = GalMiningSettings.resolve(
        global: _global,
        overrides: const GalGameMiningOverrides(
          imageMode: VideoMiningImageMode.videoClip,
          audioMode: GalMiningAudioMode.fixedLength,
        ),
      );
      expect(resolved.imageMode, VideoMiningImageMode.videoClip);
      expect(resolved.animatedFormat, MiningAnimatedFormat.avif);
      expect(resolved.stillFormat, MiningStillFormat.jpg);
      expect(resolved.clipFormat, MiningClipFormat.webmVp9);
      expect(
        resolved.audioLimit,
        const GalMiningAudioLimit(
          mode: GalMiningAudioMode.fixedLength,
          seconds: 8,
        ),
      );
    });

    test('只覆盖秒数时沿用全局模式', () {
      final GalMiningSettings resolved = GalMiningSettings.resolve(
        global: _global.copyWithAudio(
          const GalMiningAudioLimit(
            mode: GalMiningAudioMode.maxLength,
            seconds: 8,
          ),
        ),
        overrides: const GalGameMiningOverrides(audioSeconds: 3),
      );
      expect(resolved.audioLimit.mode, GalMiningAudioMode.maxLength);
      expect(resolved.audioLimit.limitMs, 3000);
    });
  });
}

extension on GalMiningSettings {
  GalMiningSettings copyWithAudio(GalMiningAudioLimit audioLimit) =>
      GalMiningSettings(
        imageMode: imageMode,
        animatedFormat: animatedFormat,
        stillFormat: stillFormat,
        clipFormat: clipFormat,
        audioLimit: audioLimit,
      );
}
