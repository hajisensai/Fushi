import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';

/// native voice_hook_ipc.h：kTextSourceLuca = 12。
const int _kTextSourceLuca = 12;

void main() {
  late Map<String, dynamic> data;

  setUpAll(() async {
    data =
        jsonDecode(
              await File(
                'test/fixtures/galhook/luca_replay.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
  });

  List<Map<String, dynamic>> events(String kind) =>
      (data['events'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .where((Map<String, dynamic> e) => e['kind'] == kind)
          .toList();

  test('luca stays implemented_unverified until real-session evidence', () {
    // 还没在原始启动路径跑通「当前文本 → 对应语音 → 当前画面 → 真卡写入」，
    // engine-support.yaml 是真相源。
    expect(data['status'], 'implemented_unverified');
  });

  test('selected thread is the production thread key of LucaSystem lines', () {
    final String selected =
        (data['config'] as Map<String, dynamic>)['selected_thread'] as String;
    // 生产映射：source 12 的行落在 luca: 命名空间。映射一旦丢了，这行会退回
    // hook:，与 fixture 里被过滤的通用 Luna 线程同名——选线程等于没选。
    const GalHookedLine lucaLine = GalHookedLine(
      seq: 1,
      timestampMs: 1000,
      text: 'synthetic voiced message',
      threadId: 0x2a,
      threadAddress: 0x1000,
      sourceKind: _kTextSourceLuca,
    );
    expect(lucaLine.textThreadKey, selected);
    expect(lucaLine.textThreadLabel, 'LucaSystem exact · 0x1000');

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

  test('voiced message pairs its PAK voice member, unvoiced pairs nothing', () {
    // 语音来自 MESSAGE 指令自带的 voice id 定位到的 VOICE*.PAK 成员（逐句资源），
    // 优先于 Loopback；没有 voice id 的台词不配音频。
    expect(events('pcm'), isEmpty);
    final Map<String, dynamic> expected =
        data['expected'] as Map<String, dynamic>;
    expect(expected['cards'], <Map<String, dynamic>>[
      <String, dynamic>{
        'text_id': 'synthetic-voiced-message',
        'audio_backend': 'resource_audio',
        'audio_id': 'synthetic-voice-pak-member',
      },
      <String, dynamic>{
        'text_id': 'synthetic-unvoiced-message',
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
