import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// `app.fushi.reader/audio_loopback` 的测试替身，语义照抄 native
/// （`audio_loopback_capture.cpp` + `audio_loopback_leases.h`）：每次 start 发一张新租约，
/// stop 只交回带来的那张（未知 / 缺省租约无操作），最后一张交回时这一路停、钉住的
/// 快照一并作废；grabRecent / pinSnapshot 只认活租约；saveSnapshot 只认最近一份快照。
class FakeLoopbackNative {
  FakeLoopbackNative(this.channel, {Uint8List? pcm})
    : pcm = pcm ?? voiceLikePcm();

  final MethodChannel channel;
  final Uint8List pcm;
  final List<MethodCall> calls = <MethodCall>[];
  final Set<int> leases = <int>{};
  int _nextLease = 0;
  int _nextSnapshot = 0;
  int _pinned = 0;

  /// 下一次 start 回失败（模拟 start 失败后调用方的兜底 stop）。
  bool failNextStart = false;

  /// 这一路此刻在不在录（= 还有活租约）。
  bool get running => leases.isNotEmpty;

  static const Map<String, Object?> format = <String, Object?>{
    'sampleRate': 16000,
    'channels': 1,
    'bitsPerSample': 16,
    'isFloat': false,
  };

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    final Map<Object?, Object?> args =
        (call.arguments as Map<Object?, Object?>?) ??
        const <Object?, Object?>{};
    switch (call.method) {
      case 'start':
        if (failNextStart) {
          failNextStart = false;
          return <String, Object?>{'error': 'start failed', 'code': 'busy'};
        }
        final int lease = ++_nextLease;
        leases.add(lease);
        return <String, Object?>{...format, 'lease': lease};
      case 'stop':
        leases.remove(args['lease']);
        if (!running) _pinned = 0;
        return null;
      case 'grabRecent':
        if (!leases.contains(args['lease'])) {
          return <String, Object?>{'error': 'no audio buffered'};
        }
        return <String, Object?>{...format, 'pcm': pcm};
      case 'pinSnapshot':
        if (!leases.contains(args['lease'])) {
          return <String, Object?>{'error': 'no audio buffered'};
        }
        _pinned = ++_nextSnapshot;
        return <String, Object?>{'id': _pinned};
      case 'saveSnapshot':
        if (_pinned == 0 || args['id'] != _pinned) {
          return <String, Object?>{'error': 'snapshot unavailable'};
        }
        File(args['path']! as String).writeAsBytesSync(pcm);
        return format;
    }
    return null;
  }
}

/// 16 kHz 单声道 16-bit：前 1 秒静音、中间 1 秒「说话」（方波）、最后 1 秒静音。
Uint8List voiceLikePcm() {
  const int rate = 16000;
  final ByteData data = ByteData(rate * 3 * 2);
  for (int i = rate; i < rate * 2; i++) {
    data.setInt16(i * 2, (i ~/ 20).isEven ? 8000 : -8000, Endian.little);
  }
  return data.buffer.asUint8List();
}
