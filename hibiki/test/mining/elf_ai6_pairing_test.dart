import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

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
    final Map<String, dynamic> expected =
        data['expected'] as Map<String, dynamic>;
    expect(expected['cards'], <Map<String, dynamic>>[
      <String, dynamic>{
        'text_id': 'ai6-dialogue',
        'audio_backend': 'resource_audio',
        'audio_id': 'voice-arc-entry',
      },
    ]);
    expect(expected['thread_filtered_events'], 1);
    expect(expected['session_clean'], isTrue);
  });
}
