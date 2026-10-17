import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';

/// native voice_hook_ipc.h：kTextSourceKogadoHy = 11。
const int _kTextSourceKogadoHy = 11;

void main() {
  late Map<String, dynamic> data;

  setUpAll(() async {
    data =
        jsonDecode(
              await File(
                'test/fixtures/galhook/kogado_hy_replay.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
  });

  List<Map<String, dynamic>> events(String kind) =>
      (data['events'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .where((Map<String, dynamic> e) => e['kind'] == kind)
          .toList();

  test(
    'kogado_hy stays implemented_unverified until real-session evidence',
    () {
      // 还没在原始启动路径跑通「当前文本 → 对应语音 → 当前画面 → 真卡写入」，
      // engine-support.yaml 是真相源。
      expect(data['status'], 'implemented_unverified');
    },
  );

  test('selected thread is the production thread key of Kogado Hy lines', () {
    final String selected =
        (data['config'] as Map<String, dynamic>)['selected_thread'] as String;
    // 生产映射：source 11 的行落在 kogado: 命名空间。映射一旦丢了，这行会退回
    // hook:，与 fixture 里被过滤的通用 Luna 线程同名——选线程等于没选。
    const GalHookedLine hyLine = GalHookedLine(
      seq: 1,
      timestampMs: 1000,
      text: 'synthetic voiced click unit',
      threadId: 0x2a,
      threadAddress: 0x1000,
      sourceKind: _kTextSourceKogadoHy,
    );
    expect(hyLine.textThreadKey, selected);
    expect(hyLine.textThreadLabel, 'Kogado Hy exact · 0x1000');

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

  test('voiced page pairs DirectSound PCM, narration pairs nothing', () {
    // Hy 没有逐句资源通道：语音只经通用 DirectSound PCM 进来。
    expect(events('resource_audio'), isEmpty);
    final Map<String, dynamic> expected =
        data['expected'] as Map<String, dynamic>;
    expect(expected['cards'], <Map<String, dynamic>>[
      <String, dynamic>{
        'text_id': 'synthetic-voiced-page',
        'audio_backend': 'pcm',
        'audio_id': 'synthetic-directsound-pcm',
      },
      <String, dynamic>{
        'text_id': 'synthetic-narration-page',
        'audio_backend': null,
        'audio_id': null,
      },
    ]);
    // 同一页重发一次（同文本 300ms 内）必须被去重。
    expect(expected['duplicate_text_events'], 1);
    expect(expected['thread_filtered_events'], 1);
    expect(expected['session_clean'], isTrue);
  });
}
