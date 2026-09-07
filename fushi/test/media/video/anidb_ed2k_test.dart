import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/anidb_ed2k.dart';

void main() {
  test('RFC 1320 MD4 standard vectors below one ED2K chunk', () {
    final Map<String, String> vectors = <String, String>{
      '': '31d6cfe0d16ae931b73c59d7e0c089c0',
      'a': 'bde52cb31de33e46245e05fbdbd6fb24',
      'abc': 'a448017aaf21d8525fc10ae87aa6729d',
      'message digest': 'd9130a8164549fe818874806e1c7014b',
      'abcdefghijklmnopqrstuvwxyz': 'd79e1c308aa5bbcdeea8ed63df412da9',
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789':
          '043f8582f241db351ce627e153e7f0e4',
      '12345678901234567890123456789012345678901234567890123456789012345678901234567890':
          'e33b4ddc9c38f2199c3e7b164fcc0536',
    };
    for (final MapEntry<String, String> vector in vectors.entries) {
      final AnidbEd2kAccumulator digest = AnidbEd2kAccumulator();
      // One-byte updates also exercise partial MD4 block buffering.
      for (final int byte in utf8.encode(vector.key)) {
        digest.add(<int>[byte]);
      }
      expect(digest.finish(), (vector.value, null));
    }
  });

  test('AniDB published exact-boundary red and blue zero-file vectors', () {
    // https://wiki.anidb.net/Ed2k-hash: these variants are deliberately distinct.
    final List<(int, String, String)> vectors = <(int, String, String)>[
      (
        anidbEd2kChunkSize,
        'fc21d9af828f92a8df64beac3357425d',
        'd7def262a127cd79096a108e7a9fc138'
      ),
      (
        anidbEd2kChunkSize * 2,
        '114b21c63a74b6ca922291a11177dd5c',
        '194ee9e4fa79b2ee9f8829284c466051'
      ),
    ];
    final Uint8List buffer = Uint8List(65536);
    for (final (int size, String red, String blue) in vectors) {
      final AnidbEd2kAccumulator digest = AnidbEd2kAccumulator();
      for (int offset = 0; offset < size; offset += buffer.length) {
        digest.add(Uint8List.sublistView(
            buffer, 0, (size - offset).clamp(0, buffer.length)));
      }
      expect(digest.finish(), (red, blue));
      expect(() => digest.add(<int>[1]), throwsStateError);
    }
  });

  test('file worker returns stat, digest and monotonic progress', () async {
    final Directory directory = await Directory.systemTemp.createTemp('ed2k-');
    addTearDown(() => directory.delete(recursive: true));
    final File file =
        await File('${directory.path}/video').writeAsString('abc');
    final List<int> progress = <int>[];
    final AnidbEd2kHash result =
        await hashAnidbFile(file.path, onProgress: (int done, int total) {
      progress.add(done);
      expect(total, 3);
    });
    expect(result.ed2k, 'a448017aaf21d8525fc10ae87aa6729d');
    expect(result.alternativeEd2k, isNull);
    expect(result.size, 3);
    expect(result.modifiedAt, (await file.stat()).modified);
    expect(progress, <int>[0, 3]);
  });

  test('nonempty final chunk matches independent OpenSSL MD4 composition', () {
    // OpenSSL 3 legacy MD4(MD4(9728000 zero bytes) + MD4(one zero byte)).
    final AnidbEd2kAccumulator digest = AnidbEd2kAccumulator();
    final Uint8List buffer = Uint8List(64000);
    for (int i = 0; i < 152; i++) {
      digest.add(buffer);
    }
    digest.add(<int>[0]);
    expect(digest.finish(), ('06329e9dba1373512c06386fe29e3c65', null));
  });

  test('file changed during hashing is rejected', () async {
    final Directory directory = await Directory.systemTemp.createTemp('ed2k-');
    addTearDown(() => directory.delete(recursive: true));
    final File file = File('${directory.path}/video');
    final RandomAccessFile writer = await file.open(mode: FileMode.write);
    await writer.truncate(anidbEd2kChunkSize * 4);
    await writer.close();
    bool changed = false;
    await expectLater(
        hashAnidbFile(file.path, onProgress: (int done, int total) {
          if (!changed && done > 0) {
            changed = true;
            file.writeAsBytesSync(<int>[1], mode: FileMode.append);
          }
        }),
        throwsA(isA<FileSystemException>()));
    expect(changed, isTrue);
  });

  test('cancelled before start does not open the file', () async {
    await expectLater(hashAnidbFile('not-a-file', isCancelled: () => true),
        throwsA(isA<AnidbHashCancelled>()));
  });

  test('cancelling on progress terminates hashing', () async {
    final Directory directory = await Directory.systemTemp.createTemp('ed2k-');
    addTearDown(() => directory.delete(recursive: true));
    final File file = File('${directory.path}/video');
    final RandomAccessFile writer = await file.open(mode: FileMode.write);
    await writer.truncate(anidbEd2kChunkSize * 4);
    await writer.close();
    bool cancelled = false;
    await expectLater(
        hashAnidbFile(file.path,
            isCancelled: () => cancelled,
            onProgress: (int done, int total) {
              cancelled = done > 0;
            }),
        throwsA(isA<AnidbHashCancelled>()));
    // Completion guarantees the native file handle has already been released.
    // Windows fails this immediately if cancellation merely kills the isolate.
    file.deleteSync();
    expect(file.existsSync(), isFalse);
  });

  test('progress callback failure also waits for the file handle to close',
      () async {
    final Directory directory = await Directory.systemTemp.createTemp('ed2k-');
    addTearDown(() => directory.delete(recursive: true));
    final File file = File('${directory.path}/video');
    final RandomAccessFile writer = await file.open(mode: FileMode.write);
    await writer.truncate(anidbEd2kChunkSize * 4);
    await writer.close();
    final StateError failure = StateError('progress failed');
    await expectLater(
        hashAnidbFile(file.path, onProgress: (int done, int total) {
          if (done > 0) throw failure;
        }),
        throwsA(same(failure)));
    file.deleteSync();
    expect(file.existsSync(), isFalse);
  });

  test('missing file preserves actionable I/O exception', () async {
    await expectLater(hashAnidbFile('missing-ed2k-file'),
        throwsA(isA<FileSystemException>()));
  });
}
