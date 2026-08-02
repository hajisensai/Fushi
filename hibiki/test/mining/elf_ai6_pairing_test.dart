import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';

void main() {
  test('elf_ai6 fixture keeps voice.arc above mixed loopback', () async {
    final Map<String, dynamic> data = jsonDecode(
      await File(
        'test/fixtures/galhook/elf_ai6_replay.json',
      ).readAsString(),
    ) as Map<String, dynamic>;
    expect(data['status'], 'implemented_unverified');
    final Map<String, dynamic> config = data['config'] as Map<String, dynamic>;
    expect(
      config['audio_priority'],
      <String>['resource_audio', 'pcm', 'loopback'],
    );
    final List<dynamic> events = data['events'] as List<dynamic>;
    expect(
      events.where(
        (dynamic event) => (event as Map<String, dynamic>)['id'] == 'mixed-bgm',
      ),
      hasLength(1),
    );
    final Map<String, dynamic> text = events
        .cast<Map<String, dynamic>>()
        .singleWhere(
          (Map<String, dynamic> event) => event['id'] == 'ai6-dialogue',
        );
    final Map<String, dynamic> resource = events
        .cast<Map<String, dynamic>>()
        .singleWhere(
            (Map<String, dynamic> event) => event['kind'] == 'resource_audio');
    final int textTs = text['timestamp_ms'] as int;
    final int resourceTs = resource['timestamp_ms'] as int;
    final int textEventId = text['text_event_id'] as int;
    expect(resource['paired_text_event_id'], textEventId);
    final String marked =
        '${resourceTs}_hibiki_textseq${textEventId}_elf_ai6_3175862.ogg';
    expect(
      pickPairedGameResource(
        oggFileNames: <String>[marked],
        wavFileNames: const <String>[],
        textTsMs: textTs,
        textEventId: textEventId,
      ),
      marked,
      reason: 'AI6 在文本之后读取 voice.arc，必须靠稳定事件 ID 命中资源',
    );
    expect(
      pickPairedGameResource(
        oggFileNames: <String>[marked],
        wavFileNames: const <String>[],
        textTsMs: textTs,
        textEventId: textEventId + 1,
      ),
      isNull,
      reason: '邻句不得仅按时间猜中带事件 ID 的资源',
    );
    expect(
      pickPairedGameResource(
        oggFileNames: <String>['${resourceTs}_elf_ai6_3175862.ogg'],
        wavFileNames: const <String>[],
        textTsMs: textTs,
        textEventId: textEventId,
      ),
      isNull,
      reason: '晚于文本的无标资源不得冒充稳定配对',
    );
    final Map<String, dynamic> expected =
        data['expected'] as Map<String, dynamic>;
    expect(expected['thread_filtered_events'], 1);
    expect(expected['session_clean'], isTrue);
  });
}
