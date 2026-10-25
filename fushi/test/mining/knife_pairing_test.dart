import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';

/// native voice_hook_ipc.h：kTextSourceKnife = 13。
const int _kTextSourceKnife = 13;

void main() {
  late Map<String, dynamic> data;

  setUpAll(() async {
    data =
        jsonDecode(
              await File(
                'test/fixtures/galhook/knife_replay.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
  });

  List<Map<String, dynamic>> events(String kind) =>
      (data['events'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .where((Map<String, dynamic> e) => e['kind'] == kind)
          .toList();

  test('knife stays implemented_unverified until real-session evidence', () {
    // 还没在原始启动路径跑通「当前文本 → 对应语音 → 当前画面 → 真卡写入」，
    // engine-support.yaml 是真相源。
    expect(data['status'], 'implemented_unverified');
  });

  test('selected thread is the production thread key of knife lines', () {
    final String selected =
        (data['config'] as Map<String, dynamic>)['selected_thread'] as String;
    // 生产映射：source 13 的行落在 knife: 命名空间。映射一旦丢了，这行会退回
    // hook:，与 fixture 里被过滤的通用 Luna 线程同名——选线程等于没选。
    const GalHookedLine knifeLine = GalHookedLine(
      seq: 1,
      timestampMs: 1000,
      text: 'synthetic voiced message',
      threadId: 0x2a,
      threadAddress: 0x1000,
      sourceKind: _kTextSourceKnife,
    );
    expect(knifeLine.textThreadKey, selected);
    expect(knifeLine.textThreadLabel, 'knife exact · 0x1000');

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

  test('voiced message pairs its stream voice, unvoiced pairs nothing', () {
    // 语音来自台词开始时引擎读入的 stream/<voice id>.opus（逐句资源，hook 侧
    // 重封装成 Ogg Opus），优先于 Loopback；没有 VPLY 的台词不配音频。
    expect(events('pcm'), isEmpty);
    final Map<String, dynamic> expected =
        data['expected'] as Map<String, dynamic>;
    expect(expected['cards'], <Map<String, dynamic>>[
      <String, dynamic>{
        'text_id': 'synthetic-voiced-message',
        'audio_backend': 'resource_audio',
        'audio_id': 'synthetic-remuxed-stream-voice',
      },
      <String, dynamic>{
        'text_id': 'synthetic-unvoiced-message',
        'audio_backend': null,
        'audio_id': null,
      },
    ]);
    expect(expected['duplicate_text_events'], 1);
    expect(expected['thread_filtered_events'], 1);
    expect(expected['session_clean'], isTrue);
  });

  test('dumped .opus voice pairs by its committed text seq only', () {
    // native WriteVoiceOggAt 落盘名：<文本 tick>_fushi_textseq<TextSlot.seq>_<原文件名>。
    // knife 的原文件名保留 .opus 扩展名，内容是重封装后的 Ogg Opus。
    const List<String> dumped = <String>[
      '5000_fushi_textseq41_A00_01_00_0000_0.opus',
      '5000_fushi_textseq42_A00_01_00_0001_0.opus',
    ];
    expect(
      pickPairedVoiceOgg(oggFileNames: dumped, textTsMs: 5000, textEventId: 42),
      '5000_fushi_textseq42_A00_01_00_0001_0.opus',
    );
    // 别的句子的 seq 不能靠时间窗把这两条借走。
    expect(
      pickPairedVoiceOgg(oggFileNames: dumped, textTsMs: 5000, textEventId: 43),
      isNull,
    );
  });
}
