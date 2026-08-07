import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reallive fixture keeps OVK resource above PCM fallback', () async {
    final Map<String, dynamic> data = jsonDecode(
      await File(
        'test/fixtures/galhook/reallive_replay.json',
      ).readAsString(),
    ) as Map<String, dynamic>;
    expect(data['status'], 'implemented_unverified');
    final Map<String, dynamic> config = data['config'] as Map<String, dynamic>;
    expect(
      config['audio_priority'],
      <String>['resource_audio', 'pcm', 'loopback'],
    );
    final Map<String, dynamic> expected =
        data['expected'] as Map<String, dynamic>;
    final List<dynamic> cards = expected['cards'] as List<dynamic>;
    expect(cards.single, <String, dynamic>{
      'text_id': 'reallive-line',
      'audio_backend': 'resource_audio',
      'audio_id': 'reallive-ovk-ogg',
    });
    expect(expected['session_clean'], isTrue);
  });
}
