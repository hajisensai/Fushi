// 「限速也作用于局域网」开关的 Dart 侧链路守卫 —— **不需要 native DLL**。
//
// 为什么不用 embedded_pipeline_test 那种真 DLL 用例：那些用例要
// `FUSHI_TORRENT_LIB`，在绝大多数 CI 环境里整组 skip（见
// native/fushi_torrent/README.md 的「CI 覆盖缺口」）。而"用户打开开关后，
// limit_local_peers 这个 1 到底有没有真的传进 C ABI"是本功能唯一的命脉，
// 必须由一条**任何环境都会跑**的用例守住。
//
// 做法：用 Pointer.fromFunction 把 C ABI 伪造成 Dart 函数，经
// FushiTorrentBindings.fromLookup 注入，于是整条
// EmbeddedTorrentSession.applyLimits → bindings → C 入参 可以被真实断言。

import 'dart:ffi';

import 'package:fushi_torrent/fushi_torrent.dart';
import 'package:test/test.dart';

/// 伪造的 session 句柄（只需非 nullptr；native 侧不会真的解引用它）。
final Pointer<Void> _fakeSession = Pointer<Void>.fromAddress(0xF00D);

/// 最近一次进入 C ABI 的入参记录。
class _Call {
  const _Call(this.symbol, this.downloadBps, this.uploadBps,
      this.connectionsLimit, this.limitLocalPeers);

  final String symbol;
  final int downloadBps;
  final int uploadBps;
  final int connectionsLimit;

  /// `ht_apply_limits`（老入口）没有这个参数，记为 null。
  final int? limitLocalPeers;

  @override
  String toString() => '$symbol(d=$downloadBps, u=$uploadBps, '
      'c=$connectionsLimit, lan=$limitLocalPeers)';
}

_Call? _lastCall;

int _fakeApplyLimits(
    Pointer<Void> session, int download, int upload, int connections) {
  _lastCall = _Call('ht_apply_limits', download, upload, connections, null);
  return 1;
}

int _fakeApplyLimitsEx(Pointer<Void> session, int download, int upload,
    int connections, int limitLocalPeers) {
  _lastCall = _Call(
      'ht_apply_limits_ex', download, upload, connections, limitLocalPeers);
  return 1;
}

/// 返回伪 session 指针的 ht_session_create。用 Pointer<Void> 做返回值需要
/// 一个能被 FFI 表达的形式，这里直接用地址整数转换。
Pointer<Void> _fakeSessionCreatePtr(
        Pointer<Char> listenInterfaces, int enableDht) =>
    _fakeSession;

/// 构造一组只实现本测试所需符号的假绑定。
///
/// [withEx] = false 时 `ht_apply_limits_ex` 查不到 —— 精确复刻"Dart 侧更新了、
/// 随包的预编译 DLL 还是旧的"这个真实部署形态。
FushiTorrentBindings _fakeBindings({required bool withEx}) {
  Pointer<T> lookup<T extends NativeType>(String symbol) {
    switch (symbol) {
      case 'ht_session_create':
        return Pointer.fromFunction<Pointer<Void> Function(Pointer<Char>, Int)>(
                _fakeSessionCreatePtr)
            .cast<T>();
      case 'ht_apply_limits':
        return Pointer.fromFunction<Int Function(Pointer<Void>, Int, Int, Int)>(
          _fakeApplyLimits,
          0,
        ).cast<T>();
      case 'ht_apply_limits_ex':
        if (!withEx) {
          throw ArgumentError("Failed to lookup symbol '$symbol'");
        }
        return Pointer.fromFunction<
            Int Function(Pointer<Void>, Int, Int, Int, Int)>(
          _fakeApplyLimitsEx,
          0,
        ).cast<T>();
    }
    throw ArgumentError("Failed to lookup symbol '$symbol'");
  }

  return FushiTorrentBindings.fromLookup(lookup);
}

EmbeddedTorrentSession _session({required bool withEx}) {
  final EmbeddedTorrentEngine engine =
      EmbeddedTorrentEngine.fromBindings(_fakeBindings(withEx: withEx));
  final EmbeddedTorrentSession? s = EmbeddedTorrentSession.open(engine);
  expect(s, isNotNull, reason: 'fake ht_session_create must yield a handle');
  return s!;
}

void main() {
  setUp(() => _lastCall = null);

  group('applyLimits → local peer class flag', () {
    test('默认（开关关）走 _ex 且 limit_local_peers = 0', () {
      final bool ok = _session(withEx: true)
          .applyLimits(downloadBps: 4096, uploadBps: 2048);

      expect(ok, isTrue);
      expect(_lastCall!.symbol, 'ht_apply_limits_ex');
      // 这一条是「默认行为完全不变」的守卫：默认必须显式下发 0，
      // native 才会把 local peer class 的上限写回「不限」。
      expect(_lastCall!.limitLocalPeers, 0);
      expect(_lastCall!.downloadBps, 4096);
      expect(_lastCall!.uploadBps, 2048);
    });

    test('开关打开时 limit_local_peers = 1 真的传进 C ABI', () {
      final bool ok = _session(withEx: true).applyLimits(
        downloadBps: 4096,
        uploadBps: 2048,
        connectionsLimit: 50,
        limitLocalPeers: true,
      );

      expect(ok, isTrue);
      expect(_lastCall!.symbol, 'ht_apply_limits_ex');
      // 负向验证的靶心：把 EmbeddedTorrentSession.applyLimits 里
      // `limitLocalPeers ? 1 : 0` 改回硬编码 0，这条必红。
      expect(_lastCall!.limitLocalPeers, 1);
      expect(_lastCall!.connectionsLimit, 50);
    });

    test('速率归一化：<=0 一律下发 0（不限），不会漏成负数', () {
      _session(withEx: true)
          .applyLimits(downloadBps: -1, limitLocalPeers: true);

      expect(_lastCall!.downloadBps, lessThanOrEqualTo(0));
      expect(_lastCall!.limitLocalPeers, 1);
    });
  });

  group('旧 DLL（无 ht_apply_limits_ex 符号）降级', () {
    test('探针如实报告不支持', () {
      expect(_session(withEx: false).supportsLocalPeerRateLimit, isFalse);
      expect(_session(withEx: true).supportsLocalPeerRateLimit, isTrue);
    });

    test('不崩：退回老入口，全局限速照常应用', () {
      final bool ok = _session(withEx: false)
          .applyLimits(downloadBps: 4096, uploadBps: 2048);

      expect(ok, isTrue, reason: '没要求限局域网时，老 DLL 完全能满足');
      expect(_lastCall!.symbol, 'ht_apply_limits');
      expect(_lastCall!.downloadBps, 4096);
    });

    test('要求限局域网但库不支持 → 返回 false，绝不假装成功', () {
      final bool ok = _session(withEx: false)
          .applyLimits(downloadBps: 4096, limitLocalPeers: true);

      expect(ok, isFalse);
      expect(_lastCall!.symbol, 'ht_apply_limits');
    });
  });
}
