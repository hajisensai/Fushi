import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_channel.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

/// BUG-708 — 桌面悬浮字幕点词在后台听书时被静默丢弃。
///
/// 根因：[AudiobookSession.installReaderSurfaces] / [restoreDefaultSurfaces] 把
/// channel 点词 handler 的重接线 (`_setupFloatingLyricHandlers`) **门控在
/// `if (_showFloatingLyric())`**。当偏好 `show_floating_lyric=false`（悬浮条被
/// 手动 toggle 拉起）时，reader detach 后重接线被跳过，[FloatingLyricChannel] 的
/// `_onLookupText` 残留为已卸载 reader 页的 `_lookupFromFloatingLyric`——它
/// `if (!mounted) return` 会吞掉每一次原生点词回调（全局查词永不触发）。
///
/// 本卷用行为断言钉「不论 `show_floating_lyric` 真假，attach 一定接上 reader
/// handler、detach 一定还原 app 级默认 handler」——重接线绝不能被偏好门控。
void main() {
  const FloatingLyricStyle style = FloatingLyricStyle(
    fontSize: 16,
    textColor: 0,
    bgColor: 0,
    buttonTextColor: 0,
    buttonBgColor: 0,
    highlightColor: 0,
    activeColor: 0,
  );

  AudiobookSession makeSession(void Function(String, int) appLevelLookup) {
    return AudiobookSession(
      audioHandler: () => null,
      // 复现前提：偏好开关 false（悬浮条临时拉起时的真实状态）。旧代码正是用它
      // 门控重接线，从而漏接 handler。
      showFloatingLyric: () => false,
      showMediaNotification: () => false,
      floatingLyricContextLines: () => 0,
      floatingLyricStyle: () => style,
      floatingLyricClickLookup: () => false,
      onFloatingLyricLookup: appLevelLookup,
      controlStreams: AudioControlStreams(
        playStream: const Stream<void>.empty(),
        seekStream: const Stream<Duration>.empty(),
        skipNextStream: const Stream<void>.empty(),
        skipPreviousStream: const Stream<void>.empty(),
        toggleFloatingLyricStream: const Stream<void>.empty(),
      ),
    );
  }

  /// 模拟原生悬浮条点词：经 channel 二进制消息触发
  /// [FloatingLyricChannel] 的 method-call handler（= setEventHandlers 装的
  /// `_handleNativeCall`），从而调到当前 `_onLookupText`。
  Future<void> sendNativeLookup(String text, int index) async {
    const StandardMethodCodec codec = StandardMethodCodec();
    final ByteData data = codec.encodeMethodCall(
      MethodCall('lookupText', <String, Object?>{'text': text, 'index': index}),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      HibikiChannels.floatingLyric.name,
      data,
      (ByteData? _) {},
    );
  }

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // host 不可用：悬浮窗出向调用短路，但 setEventHandlers 仍装 method-call
    // handler + 静态 _onLookupText（无 isSupported 门），故点词路由可被测。
    FloatingLyricChannel.platformOverride = false;
  });
  tearDown(() {
    FloatingLyricChannel.platformOverride = null;
    FloatingLyricChannel.clearEventHandlers();
  });

  test(
      'BUG-708: install/restoreDefaultSurfaces 无条件重接 channel 点词 handler，'
      '即使 show_floating_lyric=false（后台听书点词不再静默丢）', () async {
    final List<String> calls = <String>[];
    final AudiobookSession session =
        makeSession((String t, int i) => calls.add('app:$t'));

    // reader attach：channel 必须接上 reader 的点词 handler（即便偏好开关 false）。
    session.installReaderSurfaces(
      floatingLyricStyle: () => style,
      onFloatingLyricLookup: (String t, int i) => calls.add('reader:$t'),
    );
    await sendNativeLookup('あ', 0);
    expect(calls, <String>['reader:あ'],
        reason: 'attach 必须重接 reader handler，不得被 show_floating_lyric 门控');

    // reader detach：channel 必须还原 app 级默认 handler（无 !mounted 门），
    // 否则残留已卸载 reader handler → 点词被 `if (!mounted) return` 吞掉。
    calls.clear();
    session.restoreDefaultSurfaces();
    await sendNativeLookup('い', 0);
    expect(calls, <String>['app:い'],
        reason: 'detach 必须还原 app 级默认 handler，不得被 show_floating_lyric 门控');
  });
}
