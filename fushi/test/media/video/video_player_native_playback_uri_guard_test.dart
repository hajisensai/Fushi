import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2455 源码守卫：native 播放器拿到的每一个 URL 都必须过 `nativePlaybackUri`。
///
/// 钉不变式而非写法：`VideoPlayerController.load` 里 `Media(...)` 的主流 URL 与
/// `AudioTrack.uri(...)` 的外挂音轨 URL 是 native 自己去取的两个入口，任何一个绕开
/// 收口，互联 host 的自签 https 就又落回 libmpv 自己做 TLS（curl 后端默认校验 →
/// 打不开）。这类回归 analyze 全绿、单测全绿，只有真机能看见，所以钉在源码上。
void main() {
  final String src = File(
    'lib/src/media/video/video_player_controller.dart',
  ).readAsStringSync();

  test('主流 URL 经 nativePlaybackUri 收口', () {
    expect(
      src,
      contains('final String sourceUri = nativePlaybackUri('),
      reason: 'sourceUri 必须由 nativePlaybackUri 产出（BUG-2455）',
    );
    expect(
      src,
      isNot(contains('final String sourceUri = mediaUri ??')),
      reason: '不得再直接把 mediaUri 交给 Media()',
    );
  });

  test('外挂音轨 URL 经 nativePlaybackUri 收口', () {
    // 收口结果还要记进 `_externalAudioNativeUri`（判「本次外挂音轨打不开」，
    // 反馈 s3sOy3sD1J），所以先绑定成局部变量，再交给 AudioTrack.uri。
    const String binding =
        'final String audioNativeUri = nativePlaybackUri(externalAudioTrackUrl);';
    const String attach = 'AudioTrack.uri(audioNativeUri)';
    final int bindAt = src.indexOf(binding);
    final int attachAt = src.indexOf(attach);
    expect(bindAt, greaterThanOrEqualTo(0), reason: '外挂音轨 URL 必须先过收口');
    expect(attachAt, greaterThan(bindAt), reason: 'AudioTrack.uri 必须用收口后的值');
    expect(
      src.substring(bindAt + binding.length, attachAt),
      isNot(contains('audioNativeUri =')),
      reason: '收口与 audio-add 之间不得改写 audioNativeUri',
    );
    // 唯一外挂入口：不存在把裸 URL（或任何别的值）交给 AudioTrack.uri 的第二处。
    expect(
      RegExp(r'AudioTrack\.uri\(').allMatches(src).length,
      1,
      reason: 'AudioTrack.uri 只允许出现在收口后的那一处',
    );
    expect(src, isNot(contains('AudioTrack.uri(externalAudioTrackUrl)')));
  });

  test('反向断言：守卫盯的两处确实存在于 load 路径上', () {
    // 方法体被删空 / 改名时上面的 isNot 会恒真，这里钉住两个入口本身还在。
    expect(src, contains('Media('));
    expect(src, contains('setAudioTrack('));
    expect(
      src,
      contains("import 'package:fushi/src/utils/net/app_native_proxy.dart'"),
    );
  });
}
