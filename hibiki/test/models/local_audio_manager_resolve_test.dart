import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/local_audio_manager.dart';

/// TODO-1171: internal local-audio copies must resolve by FILENAME onto the
/// local database directory so a config imported from another machine (whose
/// absolute path prefix does not exist here) still finds the DB.
void main() {
  group('LocalAudioManager.isInternalCopyName', () {
    test('matches internal copy naming with either separator', () {
      expect(
        LocalAudioManager.isInternalCopyName('/a/b/local_audio_123.db'),
        isTrue,
      );
      expect(
        LocalAudioManager.isInternalCopyName(r'C:\Users\x\local_audio_9.db'),
        isTrue,
        reason: 'Windows backslash path from another machine must be handled',
      );
    });

    test('rejects external references and odd shapes', () {
      // BUG-483 reference mode points at the user original file (own naming).
      expect(LocalAudioManager.isInternalCopyName('/d/dicts/jpod.db'), isFalse);
      expect(LocalAudioManager.isInternalCopyName('local_audio_.db'), isFalse);
      expect(
          LocalAudioManager.isInternalCopyName('local_audio_1.txt'), isFalse);
      expect(LocalAudioManager.isInternalCopyName(''), isFalse);
    });
  });

  group('LocalAudioManager.resolveInternalPath', () {
    test('re-homes an internal copy from another machine by filename', () {
      const String stored = r'C:\Users\MACHINE_A\support\local_audio_777.db';
      final String resolved =
          LocalAudioManager.resolveInternalPath(stored, '/home/b/support');
      expect(resolved, endsWith('local_audio_777.db'));
      expect(resolved, startsWith('/home/b/support'));
      expect(resolved, isNot(contains('MACHINE_A')));
    });

    test('is idempotent on a path already under the local dir', () {
      const String dir = '/home/b/support';
      const String stored = '$dir/local_audio_777.db';
      expect(
        LocalAudioManager.resolveInternalPath(stored, dir),
        LocalAudioManager.resolveInternalPath(
          LocalAudioManager.resolveInternalPath(stored, dir),
          dir,
        ),
      );
    });

    test('leaves an external reference path untouched', () {
      const String ext = r'D:\my_dicts\forvo.db';
      expect(
        LocalAudioManager.resolveInternalPath(ext, '/home/b/support'),
        ext,
      );
    });
  });
}
