// Android 系统画中画「窗口上的播放 / 暂停键」契约测试（gap-vidmisc-4 / BUG-4794）。
//
// 系统只画 app 经 RemoteAction 交给它的键；这里钉住 Dart 一侧的四件事：
//   1. enter / update 把播放态与标题带给原生（图标跟播放态走）；
//   2. update 去重——播放器每个进度 tick 都通知一次，不能跟着发 binder 往返；
//   3. 原生的 onAction 回程落到 actions 流，并最终只让**一份**同步器执行；
//   4. 换集后新页挂载的同步器把新比例推给窗口，比例未知时不乱跳。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/mobile/android_picture_in_picture.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

class _FakePlayback extends ChangeNotifier {
  bool playing = true;
  double? aspectRatio = 16 / 9;
  int toggles = 0;

  void tick() => notifyListeners();
}

Widget _sync(_FakePlayback playback, {String label = 'Play / pause'}) {
  return AndroidPictureInPicturePlaybackSync(
    playback: playback,
    isPlaying: () => playback.playing,
    aspectRatio: () => playback.aspectRatio,
    playPauseLabel: label,
    onPlayPause: () => playback.toggles++,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  List<Map<Object?, Object?>> updates() => calls
      .where((MethodCall c) => c.method == 'update')
      .map((MethodCall c) => c.arguments as Map<Object?, Object?>)
      .toList();

  setUp(() {
    calls = <MethodCall>[];
    AndroidPictureInPicture.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FushiChannels.pictureInPicture, (
          MethodCall call,
        ) async {
          calls.add(call);
          switch (call.method) {
            case 'isSupported':
            case 'enter':
              return true;
            case 'isActive':
              return false;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FushiChannels.pictureInPicture, null);
    AndroidPictureInPicture.resetForTesting();
  });

  group('AndroidPictureInPicture 动作键参数', () {
    // enter 要先过能力探测（非 Android 恒不支持）。只在这一组开平台覆盖：
    // testWidgets 在 tearDown 之前就检查 foundation 调试变量有没有复位。
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('enter 带 controls 时把播放态与标题送给原生', () async {
      await AndroidPictureInPicture.enter(
        aspectRatio: 16 / 9,
        controls: const PictureInPictureControls(
          playing: true,
          playPauseLabel: '播放 / 暂停',
        ),
      );

      final Map<Object?, Object?> args =
          calls.firstWhere((MethodCall c) => c.method == 'enter').arguments
              as Map<Object?, Object?>;
      expect(args['playing'], isTrue);
      expect(args['playPauseLabel'], '播放 / 暂停');
    });

    test('enter 不带 controls 时不出现动作键参数（窗口上只有系统键）', () async {
      await AndroidPictureInPicture.enter(aspectRatio: 16 / 9);

      final Map<Object?, Object?> args =
          calls.firstWhere((MethodCall c) => c.method == 'enter').arguments
              as Map<Object?, Object?>;
      expect(args.containsKey('playing'), isFalse);
      expect(args.containsKey('playPauseLabel'), isFalse);
    });

    test('不在 PiP 里 update 不发调用', () async {
      final bool sent = await AndroidPictureInPicture.update(
        aspectRatio: 16 / 9,
        controls: const PictureInPictureControls(
          playing: true,
          playPauseLabel: 'x',
        ),
      );

      expect(sent, isFalse);
      expect(calls, isEmpty);
    });

    test('update 与 enter 送出的内容相同则不发；播放态翻转才发', () async {
      const PictureInPictureControls playing = PictureInPictureControls(
        playing: true,
        playPauseLabel: 'x',
      );
      const PictureInPictureControls paused = PictureInPictureControls(
        playing: false,
        playPauseLabel: 'x',
      );
      await AndroidPictureInPicture.enter(
        aspectRatio: 16 / 9,
        controls: playing,
      );

      expect(
        await AndroidPictureInPicture.update(
          aspectRatio: 16 / 9,
          controls: playing,
        ),
        isFalse,
        reason: '进度 tick 不改变播放态与比例，不该有通道往返',
      );
      expect(updates(), isEmpty);

      expect(
        await AndroidPictureInPicture.update(
          aspectRatio: 16 / 9,
          controls: paused,
        ),
        isTrue,
      );
      expect(updates().single['playing'], isFalse);
      expect(updates().single['aspectRatio'], 16 / 9);
    });

    test('update 的比例同样被钳制；null 比例沿用上次送出的值', () async {
      const PictureInPictureControls playing = PictureInPictureControls(
        playing: true,
        playPauseLabel: 'x',
      );
      await AndroidPictureInPicture.enter(
        aspectRatio: 16 / 9,
        controls: playing,
      );

      await AndroidPictureInPicture.update(aspectRatio: 3, controls: playing);
      expect(updates().single['aspectRatio'], 2.39);

      // 新一集尺寸未知：比例保持 2.39，只有按钮变化才发。
      expect(
        await AndroidPictureInPicture.update(
          aspectRatio: null,
          controls: playing,
        ),
        isFalse,
      );
      await AndroidPictureInPicture.update(
        aspectRatio: null,
        controls: const PictureInPictureControls(
          playing: false,
          playPauseLabel: 'x',
        ),
      );
      expect(updates().last['aspectRatio'], 2.39);
      expect(updates().last['playing'], isFalse);
    });

    test('退出 PiP 清掉去重账：再进来一定重新送', () async {
      const PictureInPictureControls playing = PictureInPictureControls(
        playing: true,
        playPauseLabel: 'x',
      );
      AndroidPictureInPicture.debugHandleModeChanged(true);
      await AndroidPictureInPicture.update(
        aspectRatio: 16 / 9,
        controls: playing,
      );
      AndroidPictureInPicture.debugHandleModeChanged(false);
      AndroidPictureInPicture.debugHandleModeChanged(true);
      await AndroidPictureInPicture.update(
        aspectRatio: 16 / 9,
        controls: playing,
      );

      expect(updates(), hasLength(2));
    });
  });

  group('AndroidPictureInPicture 动作键回程', () {
    test('原生 onAction 落到 actions 流；不认识的名字丢弃', () async {
      final List<PictureInPictureAction> seen = <PictureInPictureAction>[];
      final StreamSubscription<PictureInPictureAction> sub =
          AndroidPictureInPicture.actions.listen(seen.add);
      addTearDown(sub.cancel);

      // 走真实的通道入口（原生 → Dart），而不是只调测试入口。
      final ByteData message = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onAction', 'playPause'),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            FushiChannels.pictureInPicture.name,
            message,
            (ByteData? _) {},
          );
      AndroidPictureInPicture.debugHandleAction('seekForward');
      await pumpEventQueue();

      expect(seen, <PictureInPictureAction>[PictureInPictureAction.playPause]);
    });
  });

  group('AndroidPictureInPicturePlaybackSync', () {
    /// 摆出「上一集已经在 PiP 里、窗口参数是 4:3 + 给定播放态」，并清掉这次铺垫
    /// 产生的调用记录。
    Future<void> previousEpisodeInPictureInPicture({
      required bool playing,
    }) async {
      AndroidPictureInPicture.debugHandleModeChanged(true);
      await AndroidPictureInPicture.update(
        aspectRatio: 4 / 3,
        controls: PictureInPictureControls(
          playing: playing,
          playPauseLabel: 'Play / pause',
        ),
      );
      calls.clear();
    }

    testWidgets('PiP 里挂载即把当前播放态与比例推给窗口（换集后的新页）', (WidgetTester tester) async {
      // 上一集进的 PiP：窗口上留着上一集的比例与「暂停」图标。
      await previousEpisodeInPictureInPicture(playing: false);
      final _FakePlayback playback = _FakePlayback();

      await tester.pumpWidget(_sync(playback));
      await tester.pump();

      expect(updates().single['aspectRatio'], 16 / 9);
      expect(updates().single['playing'], isTrue);
      expect(updates().single['playPauseLabel'], 'Play / pause');
    });

    testWidgets('新一集尺寸未知时不动窗口比例，解析出来后才换', (WidgetTester tester) async {
      await previousEpisodeInPictureInPicture(playing: true);
      final _FakePlayback playback = _FakePlayback()..aspectRatio = null;

      await tester.pumpWidget(_sync(playback));
      await tester.pump();
      expect(updates(), isEmpty, reason: '比例未知 + 播放态没变：不该先跳一次 16:9');

      playback
        ..aspectRatio = 2.0
        ..tick();
      await tester.pump();
      expect(updates().single['aspectRatio'], 2.0);
    });

    testWidgets('进度 tick 不发调用，播放态翻转发一次', (WidgetTester tester) async {
      AndroidPictureInPicture.debugHandleModeChanged(true);
      final _FakePlayback playback = _FakePlayback();
      await tester.pumpWidget(_sync(playback));
      await tester.pump();
      final int baseline = updates().length;

      playback
        ..tick()
        ..tick()
        ..tick();
      await tester.pump();
      expect(updates(), hasLength(baseline));

      playback
        ..playing = false
        ..tick();
      await tester.pump();
      expect(updates(), hasLength(baseline + 1));
      expect(updates().last['playing'], isFalse);
    });

    testWidgets('窗口上的播放 / 暂停键回到播放器', (WidgetTester tester) async {
      AndroidPictureInPicture.debugHandleModeChanged(true);
      final _FakePlayback playback = _FakePlayback();
      await tester.pumpWidget(_sync(playback));

      AndroidPictureInPicture.debugHandleAction('playPause');
      await tester.pump();

      expect(playback.toggles, 1);
    });

    testWidgets('同时挂两份时一次点击只执行一遍，后挂的卸载后前一份接手', (WidgetTester tester) async {
      AndroidPictureInPicture.debugHandleModeChanged(true);
      final _FakePlayback page = _FakePlayback();
      final _FakePlayback fullscreen = _FakePlayback();
      await tester.pumpWidget(
        Column(
          children: <Widget>[
            KeyedSubtree(
              key: const ValueKey<String>('page'),
              child: _sync(page),
            ),
            KeyedSubtree(
              key: const ValueKey<String>('fullscreen'),
              child: _sync(fullscreen),
            ),
          ],
        ),
      );

      AndroidPictureInPicture.debugHandleAction('playPause');
      await tester.pump();
      expect(page.toggles + fullscreen.toggles, 1, reason: '两份都响应 = 暂停完立刻又播');
      expect(fullscreen.toggles, 1, reason: '只认最后挂载的那一份');

      await tester.pumpWidget(
        Column(
          children: <Widget>[
            KeyedSubtree(
              key: const ValueKey<String>('page'),
              child: _sync(page),
            ),
          ],
        ),
      );
      AndroidPictureInPicture.debugHandleAction('playPause');
      await tester.pump();
      expect(page.toggles, 1);
      expect(fullscreen.toggles, 1);
    });

    testWidgets('卸载后不再监听播放器、不再响应动作键', (WidgetTester tester) async {
      AndroidPictureInPicture.debugHandleModeChanged(true);
      final _FakePlayback playback = _FakePlayback();
      await tester.pumpWidget(_sync(playback));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      final int baseline = updates().length;

      playback
        ..playing = false
        ..tick();
      AndroidPictureInPicture.debugHandleAction('playPause');
      await tester.pump();

      expect(updates(), hasLength(baseline));
      expect(playback.toggles, 0);
    });
  });

  group('BUG-4794：换集后的新页拿得到「已在 PiP 里」', () {
    test('modeChanges 只在翻转时发事件，晚订阅者收不到当前值——只能靠 isActive 播种', () async {
      AndroidPictureInPicture.debugHandleModeChanged(true);
      await pumpEventQueue();

      final List<bool> seen = <bool>[];
      final StreamSubscription<bool> sub = AndroidPictureInPicture.modeChanges
          .listen(seen.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      expect(seen, isEmpty, reason: '新页订阅时系统窗口没动，不会补发一条 true');
      expect(AndroidPictureInPicture.isActive, isTrue, reason: '同步读得到当前值');
    });
  });
}
