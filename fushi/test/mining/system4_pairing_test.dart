import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';

/// native voice_hook_ipc.h：kTextSourceSystem4 = 17。
const int _kTextSourceSystem4 = 17;

void main() {
  late Map<String, dynamic> data;

  setUpAll(() async {
    data =
        jsonDecode(
              await File(
                'test/fixtures/galhook/system4_replay.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
  });

  List<Map<String, dynamic>> events(String kind) =>
      (data['events'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .where((Map<String, dynamic> e) => e['kind'] == kind)
          .toList();

  test('system4 stays implemented_unverified until real-session evidence', () {
    // 还没在原始启动路径跑通「当前文本 → 对应语音 → 当前画面 → 真卡写入」，
    // engine-support.yaml 是真相源。
    expect(data['status'], 'implemented_unverified');
  });

  test('selected thread is the production thread key of System4 pages', () {
    final String selected =
        (data['config'] as Map<String, dynamic>)['selected_thread'] as String;
    // 生产映射：source 17 的行落在 system4: 命名空间。映射一旦丢了，这行会退回
    // hook:，与 fixture 里被过滤的通用 Luna 线程同名——选线程等于没选。
    const GalHookedLine system4Line = GalHookedLine(
      seq: 1,
      timestampMs: 1000,
      text: 'synthetic message page',
      threadId: 0x2a,
      threadAddress: 0x1000,
      sourceKind: _kTextSourceSystem4,
    );
    expect(system4Line.textThreadKey, selected);
    expect(system4Line.textThreadLabel, 'System4 exact · 0x1000');

    const GalHookedLine genericLine = GalHookedLine(
      seq: 2,
      timestampMs: 900,
      text: 'synthetic generic hook text',
      threadId: 0x2a,
    );
    final List<String> filteredThreads = events('text')
        .map((Map<String, dynamic> e) => e['thread'] as String)
        .where((String thread) => thread != selected)
        .toList();
    expect(filteredThreads, <String?>[genericLine.textThreadKey]);
  });

  test('message page falls back to loopback, narration pairs nothing', () {
    // 实测样本没有配音：引擎不声明语音资源，正文页只有 loopback 降级音频；
    // 没有任何声音的旁白页不配音频。
    expect(events('resource_audio'), isEmpty);
    expect(events('pcm'), isEmpty);
    final Map<String, dynamic> expected =
        data['expected'] as Map<String, dynamic>;
    expect(expected['cards'], <Map<String, dynamic>>[
      <String, dynamic>{
        'text_id': 'synthetic-message-page',
        'audio_backend': 'loopback',
        'audio_id': 'synthetic-loopback',
      },
      <String, dynamic>{
        'text_id': 'synthetic-narration-page',
        'audio_backend': null,
        'audio_id': null,
      },
    ]);
    // 同一句重发一次（同文本 300ms 内）必须被去重。
    expect(expected['duplicate_text_events'], 1);
    expect(expected['thread_filtered_events'], 1);
    expect(expected['session_clean'], isTrue);
  });
}
