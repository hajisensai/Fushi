import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';

/// BUG-1015 + BUG-1690 守卫。
///
/// BUG-1015：桌面首次查词自动发音无声 = just_audio_media_kit 首次平台激活吞掉
/// 第一段播放输出，需要用一段全零 PCM 静音走一遍完整播放周期预热掉冷启动。
/// BUG-1690：该预热**不得在 app 启动时执行**——预热要在真实音频输出设备上开渲染流，
/// 启动即预热会打断其他 app 正在播的音乐（iOS 激活音频会话直接暂停对方、蓝牙多点/
/// 独占输出被抢走）。预热必须惰性：首次真实播放前在同一条激活串行队列里就地执行。
///
/// 播放行为本身要真机验证（需 media_kit 平台），这里守三件可静态验证的事：
/// ① 预热用的 WAV 字节确实是合法、绝对无声（全零采样）的 PCM WAV；
/// ② 惰性预热接线：_play 在捕获 generation/入队真实周期前同步调用
///    _ensureWarmUpQueued，预热 body 走 _activation 队列、volume 0；
/// ③ 启动路径（main.dart）不再有任何预热/打开音频输出流的调用。
void main() {
  group('BUG-1015/BUG-1690 desktop lookup-audio lazy warm-up', () {
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

    test('warm-up is lazy: queued inside _play before the real cycle', () {
      final String desktop = File(
        'lib/src/utils/misc/desktop_audio_playback.dart',
      ).readAsStringSync();

      // _play 必须在捕获 generation（入队真实播放周期的第一步）之前同步排入预热，
      // 保证 FIFO 顺序：预热周期先于触发它的首次真实播放完成冷激活（BUG-1015）。
      final RegExp playPrelude = RegExp(
        r'static\s+Future<bool>\s+_play\('
        r'[\s\S]{0,600}?_ensureWarmUpQueued\(\);'
        r'[\s\S]{0,600}?_activation\.generation',
      );
      expect(playPrelude.hasMatch(desktop), isTrue,
          reason: '_play 必须先 _ensureWarmUpQueued() 再捕获 generation/入队真实周期');

      // _ensureWarmUpQueued 必须是同步入队：方法体在 _activation.run 之前不得有
      // await（否则真实周期可能抢先入队，首个真实播放又撞冷激活）。
      final RegExp queuedBody = RegExp(
        r'static\s+void\s+_ensureWarmUpQueued\(\)\s*\{\s*'
        r'if\s*\(_warmUpQueued\)\s*return;\s*'
        r'_warmUpQueued\s*=\s*true;\s*'
        r'_activation\.run<void>\(',
      );
      expect(queuedBody.hasMatch(desktop), isTrue,
          reason: '_ensureWarmUpQueued 必须同步（无 await）把预热 body 排进 _activation');

      // 预热 body 必须 volume 0（绝对无声）。
      expect(desktop.contains('await _player.setVolume(0.0);'), isTrue,
          reason: '预热必须以 volume 0 静音播放');
    });

    test('startup path opens NO audio stream (BUG-1690)', () {
      final String main = File('lib/main.dart').readAsStringSync();
      // 启动路径不得出现任何查词播放器预热/播放调用：启动开音频输出流会打断
      // 其他 app 正在播的音乐（iOS 会话激活 / 蓝牙多点抢输出）。
      for (final String banned in <String>[
        'warmUpLookupAudioPlayer',
        'DesktopAudioPlayback.',
        '_ensureWarmUpQueued',
      ]) {
        expect(main.contains(banned), isFalse,
            reason: 'main.dart 启动路径不得调用 $banned（BUG-1690：启动不开音频流）');
      }

      // TtsChannel 也不再暴露启动预热入口（唯一消费者曾是 main 启动路径；留着这个
      // 入口 = API 层面允许再次接回启动，删口子而不是靠调用点自觉）。
      final String tts =
          File('lib/src/utils/misc/tts_channel.dart').readAsStringSync();
      expect(tts.contains('warmUpLookupAudioPlayer'), isFalse,
          reason: 'TtsChannel 不得再暴露启动预热入口');
    });

    test(
        'BUG-2495: warm-up wait is driven by player terminal states, '
        'not a fixed budget clock', () {
      final String desktop = File(
        'lib/src/utils/misc/desktop_audio_playback.dart',
      ).readAsStringSync();
      final RegExp body = RegExp(
        r'static\s+void\s+_ensureWarmUpQueued\(\)\s*\{[\s\S]*?\n  \}\n',
      );
      final String? warmUp = body.firstMatch(desktop)?.group(0);
      expect(warmUp, isNotNull, reason: '找不到 _ensureWarmUpQueued 方法体');

      // 终态必须同时接受 completed（播完）与 idle（平台出错被 just_audio 停用）：
      // just_audio 0.9.x 丢掉平台 errorCode，出错只剩 idle 这一个信号；只等 completed
      // 会让设备打不开时白等到保险丝。
      final RegExp terminal = RegExp(
        r'firstWhere\([\s\S]*?ProcessingState\.completed[\s\S]*?\|\|'
        r'[\s\S]*?ProcessingState\.idle',
      );
      expect(terminal.hasMatch(warmUp!), isTrue,
          reason: '预热等待的终态必须是 completed || idle');

      // 不得再用固定的短预算时钟截断等待：2s 到期 → 队列放行 → 真实周期 stop() 把
      // 正在冷启动的 mpv 播放器拆掉，BUG-1015 复发。时钟只允许是卡死保险丝常量。
      expect(warmUp.contains('.timeout(_warmUpStuckValve)'), isTrue,
          reason: '等待超时只能引用卡死保险丝 _warmUpStuckValve');
      expect(RegExp(r'timeout\(\s*const\s+Duration').hasMatch(warmUp), isFalse,
          reason: '预热 body 不得内联固定 Duration 作为等待预算');
      final RegExp valve = RegExp(
        r'static\s+const\s+Duration\s+_warmUpStuckValve\s*=\s*'
        r'Duration\(seconds:\s*(\d+)\)',
      );
      final Match? valveMatch = valve.firstMatch(desktop);
      expect(valveMatch, isNotNull, reason: '缺少 _warmUpStuckValve 常量');
      expect(int.parse(valveMatch!.group(1)!), greaterThanOrEqualTo(10),
          reason: '保险丝必须远大于任何真实设备唤醒耗时（≥10s），否则又变回预算');

      // 无论结果都要记一条带耗时的诊断：这是下次定量判断「设备冷启动多慢」的唯一证据。
      expect(
          warmUp.contains(
            "logDiagnostic(\n          'DesktopAudioPlayback.warmUp'",
          ),
          isTrue,
          reason: '预热必须 logDiagnostic 记录终态与耗时');
      expect(warmUp.contains('elapsedMilliseconds'), isTrue,
          reason: '诊断必须带耗时');
    });
  });
}
