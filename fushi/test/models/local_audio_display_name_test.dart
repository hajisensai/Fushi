import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/local_audio_display_name.dart';

void main() {
  group('localAudioDisplayNameFor', () {
    test('names a generic Yomitan android.db after its sources', () {
      expect(
        localAudioDisplayNameFor('android.db', <String>[
          'ozk5',
          'forvo',
          'nhk16',
          'daijisen',
          'jpod',
          'shinmeikai8',
          'forvo_ext',
          'taas',
          'forvo_ext2',
        ]),
        'daijisen · forvo · forvo_ext +6',
      );
    });

    test('lists every source when there are few', () {
      expect(
        localAudioDisplayNameFor('Android.DB', <String>['oald10']),
        'oald10',
      );
      expect(
        localAudioDisplayNameFor('android.db', <String>['nhk16', 'jpod', '']),
        'jpod · nhk16',
      );
    });

    test('keeps a user-chosen file name without the .db extension', () {
      expect(
        localAudioDisplayNameFor('android_english.db', <String>['oald10']),
        'android_english',
      );
      expect(
        localAudioDisplayNameFor('NHK 発音.db', <String>['nhk16']),
        'NHK 発音',
      );
      expect(
        localAudioDisplayNameFor('audio.sqlite', <String>['nhk16']),
        'audio.sqlite',
      );
    });

    test('falls back to the file name when sources are unreadable', () {
      expect(localAudioDisplayNameFor('android.db', <String>[]), 'android');
      expect(localAudioDisplayNameFor('.db', <String>[]), '.db');
    });
  });
}
