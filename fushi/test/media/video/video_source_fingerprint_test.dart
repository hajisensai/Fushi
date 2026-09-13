import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_source_fingerprint.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('video_source_identity_');
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'identical content at different names has the same full-file identity',
    () async {
      final List<int> bytes = List<int>.generate(400000, (int i) => i % 251);
      final File first = await File(
        '${directory.path}/first.mkv',
      ).writeAsBytes(bytes);
      final File second = await File(
        '${directory.path}/second.mkv',
      ).writeAsBytes(bytes);
      final VideoSourceFingerprint hashes = VideoSourceFingerprint();
      final String expected = sha256.convert(bytes).toString();
      expect(await hashes.fingerprint(first.path), expected);
      expect(await hashes.matches(second.path, expected), isTrue);
    },
  );

  test(
    'same name and size with a changed middle cannot match a cached card',
    () async {
      final List<int> bytes = List<int>.filled(400000, 1);
      final File file = await File(
        '${directory.path}/episode.mkv',
      ).writeAsBytes(bytes);
      final VideoSourceFingerprint hashes = VideoSourceFingerprint();
      final String original = await hashes.fingerprint(file.path);
      bytes[200000] = 2;
      await file.writeAsBytes(bytes);
      await file.setLastModified(
        DateTime.now().add(const Duration(seconds: 2)),
      );
      expect(await hashes.matches(file.path, original), isFalse);
      expect(
        await hashes.fingerprint(file.path),
        sha256.convert(bytes).toString(),
      );
    },
  );

  test(
    'streams, missing files and malformed fingerprints never validate',
    () async {
      final VideoSourceFingerprint hashes = VideoSourceFingerprint();
      expect(
        hashes.fingerprint('https://host/episode.mkv'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        hashes.fingerprint('${directory.path}/missing'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await hashes.matches('${directory.path}/missing', 'partial-hash'),
        isFalse,
      );
    },
  );
}
