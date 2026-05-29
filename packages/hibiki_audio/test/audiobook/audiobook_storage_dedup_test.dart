import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/src/audiobook/audiobook_storage.dart';
import 'package:path/path.dart' as p;

/// Regression test for HBK-AUDIT-004: persistFileWithProgress must not let two
/// source files with the same basename (e.g. disc1/01.m4a vs disc2/01.m4a)
/// overwrite each other at an identical destination.
void main() {
  test('persistFileWithProgress dedupes colliding basenames instead of '
      'overwriting', () async {
    final Directory tmp =
        await Directory.systemTemp.createTemp('hibiki_persist_test_');
    addTearDown(() => tmp.delete(recursive: true));

    final Directory persistDir = Directory(p.join(tmp.path, 'persist'))
      ..createSync(recursive: true);

    // Two distinct source files that share the basename "01.m4a".
    final Directory disc1 = Directory(p.join(tmp.path, 'disc1'))..createSync();
    final Directory disc2 = Directory(p.join(tmp.path, 'disc2'))..createSync();
    final File a = File(p.join(disc1.path, '01.m4a'))..writeAsStringSync('AAA');
    final File b = File(p.join(disc2.path, '01.m4a'))
      ..writeAsStringSync('BBBBBB');

    final String destA =
        await AudiobookStorage.persistFileWithProgress(a, persistDir);
    final String destB =
        await AudiobookStorage.persistFileWithProgress(b, persistDir);

    // Distinct destinations, both present, content preserved (no overwrite).
    expect(destA, isNot(equals(destB)));
    expect(File(destA).existsSync(), isTrue);
    expect(File(destB).existsSync(), isTrue);
    expect(File(destA).readAsStringSync(), 'AAA');
    expect(File(destB).readAsStringSync(), 'BBBBBB');

    // Exactly two persisted files.
    final int count = persistDir
        .listSync()
        .whereType<File>()
        .where((f) => AudiobookStorage.isAudioFile(f.path))
        .length;
    expect(count, 2);
  });
}
