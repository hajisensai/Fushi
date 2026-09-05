import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'aos_sfa fixture pairs the selected thread with generic source PCM',
    () async {
      final Map<String, dynamic> data = jsonDecode(
        await File(
          'test/fixtures/galhook/aos_sfa_replay.json',
        ).readAsString(),
      ) as Map<String, dynamic>;
      expect(data['status'], 'implemented_unverified');

      final Map<String, dynamic> config =
          data['config'] as Map<String, dynamic>;
      // AOS 的逐句语音在 cv.aos 里，本轮没做资源层，PCM 是它的最好档；
      // loopback 仍须排在最后——它只是降级，不能冒充引擎级人声。
      expect(config['audio_priority'], <String>[
        'resource_audio',
        'pcm',
        'loopback',
      ]);
      expect(config['selected_thread'], 3);

      final List<dynamic> events = data['events'] as List<dynamic>;
      Map<String, dynamic> eventById(String id) =>
          events.cast<Map<String, dynamic>>().firstWhere(
                (Map<String, dynamic> e) => e['id'] == id,
              );

      // 「PCM 胜过 loopback」必须是**优先级**判出来的，不能是时间差碰巧判出来的。
      // 候选排序键是 (优先级, 时间差)，所以 fixture 故意把 loopback 放得比 PCM
      // **更靠近**台词：优先级一旦被抹平或调反，赢的就变成 loopback，
      // `galhook.py replay` 立刻对不上 expected 而 exit 2（已变异实测）。
      final int textAt = eventById('aos-line')['timestamp_ms'] as int;
      final int pcmGap =
          (eventById('aos-source-pcm')['timestamp_ms'] as int) - textAt;
      final int loopbackGap =
          (eventById('aos-loopback')['timestamp_ms'] as int) - textAt;
      expect(
        loopbackGap.abs(),
        lessThan(pcmGap.abs()),
        reason: 'loopback 必须比 PCM 更近，否则这条断言退化成「离得近的赢」',
      );

      final Map<String, dynamic> expected =
          data['expected'] as Map<String, dynamic>;
      final List<dynamic> cards = expected['cards'] as List<dynamic>;
      expect(cards.single, <String, dynamic>{
        'text_id': 'aos-line',
        'audio_backend': 'pcm',
        'audio_id': 'aos-source-pcm',
      });
      // thread 6 是 UI 线程，必须被线程过滤挡掉——这条掉了就等于没在选线程。
      expect(expected['thread_filtered_events'], 1);
      // 去重窗口是通用文本源唯一的闸门。fixture 里放了一条 300ms 后的同文本重播：
      // 断言写 0 的话（events 里根本没有重复文本）这条判据永远不会被触发，等于没测。
      expect(expected['duplicate_text_events'], 1);
      // 重播只能被去重掉，绝不能多长出一张卡。
      expect(cards.length, 1);
      expect(expected['session_clean'], isTrue);
    },
  );
}
