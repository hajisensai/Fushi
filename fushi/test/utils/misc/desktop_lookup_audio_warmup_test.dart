import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';

/// BUG-1015 守卫：桌面首次查词自动发音无声 = just_audio_media_kit 首次平台激活吞掉
/// 第一段播放输出。修复在启动时用一段全零 PCM 静音走一遍完整播放周期预热掉冷启动。
///
/// 播放行为本身要真机验证（需 media_kit 平台），这里守两件可静态验证的事：
/// ① 预热用的 WAV 字节确实是合法、绝对无声（全零采样）的 PCM WAV；
/// ② 预热被正确接线：main 启动调用、TtsChannel 平台门控、DesktopAudioPlayback 静音走 _play。
void main() {
  group('BUG-1015 desktop lookup-audio warm-up', () {
    test('silent warm-up WAV is a valid, fully-silent 16-bit PCM WAV', () {
      final Uint8List bytes = DesktopAudioPlayback.debugSilentWavBytes();
      final ByteData bd = ByteData.sublistView(bytes);

      String ascii(int offset, int len) => String.fromCharCodes(
            bytes.sublist(offset, offset + len),
          );

      // 头部标记。
      expect(ascii(0, 4), 'RIFF');
      expect(ascii(8, 4), 'WAVE');
      expect(ascii(12, 4), 'fmt ');
      expect(ascii(36, 4), 'data');

      // PCM 格式参数。
      expect(bd.getUint32(16, Endian.little), 16, reason: 'PCM fmt chunk size');
      expect(bd.getUint16(20, Endian.little), 1, reason: 'audioFormat=PCM');
      expect(bd.getUint16(22, Endian.little), 1, reason: 'mono');
      expect(bd.getUint16(34, Endian.little), 16, reason: '16-bit');

      // 尺寸自洽：dataSize 与实际字节数、RIFF chunkSize 一致。
      final int dataSize = bd.getUint32(40, Endian.little);
      expect(bytes.length, 44 + dataSize);
      expect(bd.getUint32(4, Endian.little), 36 + dataSize);

      // 关键：data 区必须全零 = 绝对无声，绝不在预热时发出任何可听声响。
      for (int i = 44; i < bytes.length; i++) {
        expect(bytes[i], 0, reason: 'silent sample at byte $i');
      }
    });

    test(
        'warm-up is wired: main → TtsChannel (platform-gated) → _play(volume 0)',
        () {
      final String main = File('lib/main.dart').readAsStringSync();
      // 启动预热在 media_kit 初始化之后、fire-and-forget，不阻塞启动。
      expect(main.contains('warmUpLookupAudioPlayer()'), isTrue,
          reason: 'main 必须启动查词播放器预热');
      final int initIdx = main.indexOf('MediaKit.ensureInitialized()');
      final int warmIdx = main.indexOf('warmUpLookupAudioPlayer()');
      expect(initIdx, greaterThanOrEqualTo(0));
      expect(warmIdx, greaterThan(initIdx), reason: '预热必须在 media_kit 初始化之后');

      final String tts =
          File('lib/src/utils/misc/tts_channel.dart').readAsStringSync();
      // 平台门控：Android 直接 return（原生 MediaPlayer 无此冷启动）。
      expect(
        RegExp(r'warmUpLookupAudioPlayer\(\)\s*async\s*\{\s*if\s*\(_isSupported\)\s*return;')
            .hasMatch(tts),
        isTrue,
        reason: 'warmUpLookupAudioPlayer 必须对 Android(_isSupported) 短路 no-op',
      );
      expect(tts.contains('DesktopAudioPlayback.warmUp()'), isTrue);

      final String desktop = File(
        'lib/src/utils/misc/desktop_audio_playback.dart',
      ).readAsStringSync();
      // 预热必须走既有 _play 串行队列且 volume 0（不与真实播放交错、绝对无声）。
      expect(
        RegExp(r"_play\([^;]*'warmUp',\s*0\.0\)").hasMatch(desktop),
        isTrue,
        reason: '预热必须复用 _play 并以 volume 0 静音播放',
      );
    });
  });
}
