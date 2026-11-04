import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';

/// native voice_hook_ipc.h：kTextSourceSoftpal = 16。
const int _kTextSourceSoftpal = 16;

void main() {
  late Map<String, dynamic> data;

  setUpAll(() async {
    data =
        jsonDecode(
              await File(
                'test/fixtures/galhook/softpal_replay.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
  });

  List<Map<String, dynamic>> events(String kind) =>
      (data['events'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .where((Map<String, dynamic> e) => e['kind'] == kind)
          .toList();

  test('softpal stays implemented_unverified until real-session evidence', () {
    // 还没在原始启动路径跑通「当前文本 → 对应语音 → 当前画面 → 真卡写入」，
    // engine-support.yaml 是真相源。
    expect(data['status'], 'implemented_unverified');
  });

  test('selected thread is the production thread key of SoftPal pages', () {
    final String selected =
        (data['config'] as Map<String, dynamic>)['selected_thread'] as String;
    // 生产映射：source 16 的行落在 softpal: 命名空间。映射一旦丢了，这行会退回
    // hook:，与 fixture 里被过滤的通用 Luna 线程同名——选线程等于没选。
    const GalHookedLine softpalLine = GalHookedLine(
      seq: 1,
      timestampMs: 1000,
      text: 'synthetic voiced page',
      threadId: 0x2a,
      threadAddress: 0x1000,
      sourceKind: _kTextSourceSoftpal,
    );
    expect(softpalLine.textThreadKey, selected);
    expect(softpalLine.textThreadLabel, 'SoftPal exact · 0x1000');

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

  test('voiced page pairs its PAC voice entry, narration pairs nothing', () {
    // 语音是与正文同一引擎步加载的 voice.pac 条目（逐句资源，带正文的文本事件号），
    // 优先于 Loopback；没有语音的旁白不配音频。
    expect(events('pcm'), isEmpty);
    final Map<String, dynamic> expected =
        data['expected'] as Map<String, dynamic>;
    expect(expected['cards'], <Map<String, dynamic>>[
      <String, dynamic>{
        'text_id': 'synthetic-voiced-page',
        'audio_backend': 'resource_audio',
        'audio_id': 'synthetic-voice-pac-entry',
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
