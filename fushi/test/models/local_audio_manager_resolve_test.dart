import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/local_audio_manager.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:path/path.dart' as p;

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
        LocalAudioManager.isInternalCopyName('local_audio_1.txt'),
        isFalse,
      );
      expect(LocalAudioManager.isInternalCopyName(''), isFalse);
    });
  });

  group('LocalAudioManager.resolveInternalPath', () {
    test('re-homes an internal copy from another machine by filename', () {
      const String stored = r'C:\Users\MACHINE_A\support\local_audio_777.db';
      final String resolved = LocalAudioManager.resolveInternalPath(
        stored,
        '/home/b/support',
      );
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

    // BUG-3269：用户把别处拷来的 `local_audio_<数字>.db` 放进 Download 并以引用
    // 模式选中。文件名像内部副本，但它就在本机这条路径上——重挂到库目录下一个
    // 不存在的同名文件，设置页恒报「不可用」、native 也查不到发音。
    group('BUG-3269 existing reference with an internal-looking name', () {
      late Directory sandbox;
      late String supportDir;
      late String referenced;

      setUp(() {
        sandbox = Directory.systemTemp.createTempSync('bug3269_');
        supportDir = p.join(sandbox.path, 'support');
        Directory(supportDir).createSync();
        final Directory download = Directory(
          p.join(sandbox.path, 'Download', 'Fushi Dictionary Bank', 'Audio'),
        )..createSync(recursive: true);
        referenced = p.join(download.path, 'local_audio_1782831652275.db');
        File(referenced).writeAsStringSync('db');
      });

      tearDown(() => sandbox.deleteSync(recursive: true));

      test('resolves to the existing file instead of the support dir', () {
        final String resolved = LocalAudioManager.resolveInternalPath(
          referenced,
          supportDir,
        );
        expect(resolved, referenced);
        expect(File(resolved).existsSync(), isTrue);
      });

      test('backup / data-root rewrite keeps the existing reference', () {
        final String body = jsonEncode(<Map<String, Object?>>[
          <String, Object?>{
            'path': referenced,
            'displayName': 'local_audio_1782831652275.db',
            'enabled': true,
          },
        ]);
        final String rewritten = normalizeLocalAudioDbsJson(
          's:$body',
          supportDir,
        );
        final List<dynamic> entries =
            jsonDecode(rewritten.substring(2)) as List<dynamic>;
        expect((entries.single as Map<String, dynamic>)['path'], referenced);
      });

      test('a missing internal-named path still re-homes by filename', () {
        File(referenced).deleteSync();
        expect(
          LocalAudioManager.resolveInternalPath(referenced, supportDir),
          p.join(supportDir, 'local_audio_1782831652275.db'),
        );
      });
    });
  });
}
