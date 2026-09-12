import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/floating_dict_channel.dart';

/// Android 悬浮词典（原生 TextView 窗口）不经 popup.js 的 buildMinePayload，
/// 制卡 payload 与 ♪ 播放在 Dart 侧各自接回 app 内同一条单词音频链。
/// 这里钉住两条契约：payload 带/不带 audio 的形状；native `playAudio` 调用
/// 会把 word/reading 交给注册的播放处理器。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildFloatingDictMinePayload', () {
    test('resolved audio ref lands in the audio field', () {
      final Map<String, String> fields = buildFloatingDictMinePayload(
        word: '宇野',
        reading: 'うの',
        meaning: 'plain meaning',
        audioRef: '/data/user/0/app/cache/local_audio/uno.mp3',
      );
      expect(fields['expression'], '宇野');
      expect(fields['reading'], 'うの');
      expect(fields['glossary'], 'plain meaning');
      expect(fields['audio'], '/data/user/0/app/cache/local_audio/uno.mp3');
    });

    test('empty or missing audio ref omits the audio key', () {
      expect(
        buildFloatingDictMinePayload(
          word: 'a',
          reading: 'a',
          meaning: 'm',
        ).containsKey('audio'),
        isFalse,
      );
      expect(
        buildFloatingDictMinePayload(
          word: 'a',
          reading: 'a',
          meaning: 'm',
          audioRef: '',
        ).containsKey('audio'),
        isFalse,
      );
    });
  });

  group('FloatingDictChannel playAudio', () {
    tearDown(FloatingDictChannel.clearEventHandlers);

    test('native playAudio call reaches the registered handler', () async {
      final List<(String, String)> played = <(String, String)>[];
      FloatingDictChannel.setEventHandlers(
        onSearch: (_) async => null,
        onAnkiExport: (_, __, ___) async {},
        onPlayAudio: (String word, String reading) async {
          played.add((word, reading));
        },
      );
      await FloatingDictChannel.debugHandleNativeCall(
        const MethodCall('playAudio', <String, Object?>{
          'word': '見る',
          'reading': 'みる',
        }),
      );
      expect(played, <(String, String)>[('見る', 'みる')]);
    });

    test('empty word is ignored', () async {
      int calls = 0;
      FloatingDictChannel.setEventHandlers(
        onSearch: (_) async => null,
        onAnkiExport: (_, __, ___) async {},
        onPlayAudio: (_, __) async {
          calls++;
        },
      );
      await FloatingDictChannel.debugHandleNativeCall(
        const MethodCall('playAudio', <String, Object?>{'word': ''}),
      );
      expect(calls, 0);
    });
  });
}
