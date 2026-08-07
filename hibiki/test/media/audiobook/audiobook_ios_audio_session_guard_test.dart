import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audiobook playback configures iOS audio session as playback', () {
    final String source = File(
      '../packages/fushi_audio/lib/src/audiobook/audiobook_controller.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('AVAudioSessionCategory.playback'),
      reason: 'iOS audiobook playback must use the playback category so it '
          'does not go silent under the system silent switch.',
    );
    expect(
      source,
      contains('AVAudioSessionMode.spokenAudio'),
      reason: 'Audiobooks should use the iOS spoken-audio mode.',
    );
  });
}
