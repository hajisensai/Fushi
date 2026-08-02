import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/reader/manga_volume_key_paging_controller.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const StandardMethodCodec codec = StandardMethodCodec();

  Future<void> sendNative(String method) async {
    final Completer<void> replied = Completer<void>();
    messenger.handlePlatformMessage(
      HibikiChannels.volumeKeys.name,
      codec.encodeMethodCall(MethodCall(method)),
      (_) => replied.complete(),
    );
    await replied.future;
  }

  test('Android ownership, repeat throttling and release use the real channel',
      () async {
    final List<MethodCall> outbound = <MethodCall>[];
    messenger.setMockMethodCallHandler(HibikiChannels.volumeKeys, (call) async {
      outbound.add(call);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(HibikiChannels.volumeKeys, null);
    });

    DateTime now = DateTime(2026);
    final List<String> turns = <String>[];
    final MangaVolumeKeyPagingController controller =
        MangaVolumeKeyPagingController(
      onPrevious: () => turns.add('previous'),
      onNext: () => turns.add('next'),
      now: () => now,
    );

    controller.apply(enabled: true, platformSupported: true);
    await Future<void>.delayed(Duration.zero);
    expect(outbound, <MethodCall>[
      const MethodCall('setInterceptEnabled', true),
    ]);

    await sendNative('onVolumeDown');
    await sendNative('onVolumeDown');
    expect(turns, <String>['next'], reason: '同一 ACTION_DOWN repeat 不得堆满队列');

    now = now.add(const Duration(milliseconds: 180));
    await sendNative('onVolumeUp');
    expect(turns, <String>['next', 'previous']);

    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(outbound.last, const MethodCall('setInterceptEnabled', false));
    await sendNative('onVolumeDown');
    expect(turns, <String>['next', 'previous'], reason: '销毁后 handler 必须已清空');
  });

  test('unsupported platform never takes native ownership', () async {
    final List<MethodCall> outbound = <MethodCall>[];
    messenger.setMockMethodCallHandler(HibikiChannels.volumeKeys, (call) async {
      outbound.add(call);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(HibikiChannels.volumeKeys, null);
    });
    final MangaVolumeKeyPagingController controller =
        MangaVolumeKeyPagingController(onPrevious: () {}, onNext: () {});
    controller.apply(enabled: true, platformSupported: false);
    await Future<void>.delayed(Duration.zero);
    expect(outbound, isEmpty);
  });
}
