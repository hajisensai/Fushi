import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_playback_remote.dart';

/// 只用作身份的假遥控面。
class _FakeRemote implements VideoPlaybackRemote {
  _FakeRemote(this.name);

  final String name;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  String toString() => name;
}

void main() {
  test('登记即成为 current，注销后回到 null', () {
    final VideoPlaybackRemoteRegistry registry = VideoPlaybackRemoteRegistry();
    final _FakeRemote a = _FakeRemote('a');
    expect(registry.current.value, isNull);
    registry.register(a);
    expect(registry.current.value, same(a));
    registry.unregister(a);
    expect(registry.current.value, isNull);
    expect(registry.debugLength, 0);
  });

  test('叠加：最后登记的在上；注销上层回落到下层', () {
    final VideoPlaybackRemoteRegistry registry = VideoPlaybackRemoteRegistry();
    final _FakeRemote lower = _FakeRemote('lower');
    final _FakeRemote upper = _FakeRemote('upper');
    registry
      ..register(lower)
      ..register(upper);
    expect(registry.current.value, same(upper));
    registry.unregister(upper);
    expect(registry.current.value, same(lower));
  });

  test('dispose 只清自己：下层先注销不影响上层', () {
    final VideoPlaybackRemoteRegistry registry = VideoPlaybackRemoteRegistry();
    final _FakeRemote lower = _FakeRemote('lower');
    final _FakeRemote upper = _FakeRemote('upper');
    registry
      ..register(lower)
      ..register(upper);
    registry.unregister(lower);
    expect(registry.current.value, same(upper));
    expect(registry.debugLength, 1);
    // 重复注销 / 注销未登记的都是 no-op。
    registry
      ..unregister(lower)
      ..unregister(_FakeRemote('stranger'));
    expect(registry.current.value, same(upper));
  });

  test('重复登记不改变栈序', () {
    final VideoPlaybackRemoteRegistry registry = VideoPlaybackRemoteRegistry();
    final _FakeRemote lower = _FakeRemote('lower');
    final _FakeRemote upper = _FakeRemote('upper');
    registry
      ..register(lower)
      ..register(upper)
      ..register(lower);
    expect(registry.current.value, same(upper));
    expect(registry.debugLength, 2);
  });

  test('current 变化会通知监听者', () {
    final VideoPlaybackRemoteRegistry registry = VideoPlaybackRemoteRegistry();
    int notified = 0;
    registry.current.addListener(() => notified++);
    final _FakeRemote a = _FakeRemote('a');
    registry
      ..register(a)
      ..unregister(a);
    expect(notified, 2);
  });
}
