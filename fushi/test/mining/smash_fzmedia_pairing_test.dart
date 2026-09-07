import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('smash_fzmedia fixture pairs each selected-thread line with its FCD ogg',
      () async {
    final Map<String, dynamic> data = jsonDecode(
      await File(
        'test/fixtures/galhook/smash_fzmedia_replay.json',
      ).readAsString(),
    ) as Map<String, dynamic>;
    // 还没回到原始启动路径跑通「当前文本 → 对应语音 → 当前画面 → 真卡写入」，
    // 支持状态就只能是 implemented_unverified（engine-support.yaml 是真相源）。
    expect(data['status'], 'implemented_unverified');

    final Map<String, dynamic> config = data['config'] as Map<String, dynamic>;
    expect(config['selected_thread'], 'smash-exact-kag-text-layer');
    // FCD 里的 ogg 是逐句资源，晚到也要等：late 那条 available_at_ms 比 timestamp_ms
    // 晚 380ms，等待窗口小于它就会掉回 pcm/loopback。
    expect(config['resource_late_wait_ms'], 500);

    final Map<String, dynamic> expected =
        data['expected'] as Map<String, dynamic>;
    // 两句都必须配到 resource_audio。fixture 里同时喂了 loopback 与 pcm 事件——
    // 任何一条卡片掉到那两个 backend 上，就说明资源通道没走通而降级了。
    expect(expected['cards'], <Map<String, dynamic>>[
      <String, dynamic>{
        'text_id': 'synthetic-paragraph-line',
        'audio_backend': 'resource_audio',
        'audio_id': 'synthetic-fcd-ogg-early',
      },
      <String, dynamic>{
        'text_id': 'synthetic-second-line',
        'audio_backend': 'resource_audio',
        'audio_id': 'synthetic-fcd-ogg-late',
      },
    ]);
    // 同文本重发一次必须被去重（KAG 重排会把同一段再投一遍）。
    expect(expected['duplicate_text_events'], 1);
    // UI 线程那条必须被线程过滤挡掉——掉了就等于没在选线程。
    expect(expected['thread_filtered_events'], 1);
    expect(expected['session_clean'], isTrue);
  });
}
