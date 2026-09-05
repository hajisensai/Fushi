import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'unity_mono fixture pairs the selected thread with generic source PCM',
    () async {
      final Map<String, dynamic> data =
          jsonDecode(
                await File(
                  'test/fixtures/galhook/unity_mono_replay.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(data['status'], 'implemented_unverified');

      final Map<String, dynamic> config =
          data['config'] as Map<String, dynamic>;
      // Unity 的逐句语音是 AudioClip 资产，本轮没做资源层（真机 unity_events=0），
      // PCM 是它的最好档；loopback 仍须排在最后——它只是降级，不能冒充引擎级人声。
      expect(config['audio_priority'], <String>[
        'resource_audio',
        'pcm',
        'loopback',
      ]);
      expect(config['selected_thread'], 5);

      final Map<String, dynamic> expected =
          data['expected'] as Map<String, dynamic>;
      final List<dynamic> cards = expected['cards'] as List<dynamic>;
      expect(cards.single, <String, dynamic>{
        'text_id': 'unity-mono-line',
        'audio_backend': 'pcm',
        'audio_id': 'unity-mono-source-pcm',
      });
      // thread 11 是 UI 线程，必须被线程过滤挡掉——这条掉了就等于没在选线程。
      expect(expected['thread_filtered_events'], 1);
      expect(expected['duplicate_text_events'], 0);
      expect(expected['session_clean'], isTrue);
    },
  );
}
