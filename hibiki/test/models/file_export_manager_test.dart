import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/file_export_manager.dart';

void main() {
  late FileExportManager manager;
  late Directory exportDir;
  late Directory altDir;

  setUp(() {
    exportDir = Directory('/fake/export');
    altDir = Directory('/fake/alternate');
    manager = FileExportManager(
      exportDirectory: exportDir,
      alternateExportDirectory: altDir,
    );
  });

  group('FileExportManager', () {
    test('getImageExportFile uses export directory', () {
      final File f = manager.getImageExportFile();
      expect(f.path, contains('export'));
      expect(f.path, endsWith('exportImage.jpg'));
    });

    test('getImageExportFile fallback uses alternate directory', () {
      final File f = manager.getImageExportFile(fallback: true);
      expect(f.path, contains('alternate'));
      expect(f.path, endsWith('exportImage.jpg'));
    });

    test('getAudioExportFile defaults to mp3', () {
      final File f = manager.getAudioExportFile();
      expect(f.path, endsWith('exportAudio.mp3'));
    });

    test('getAudioExportFile respects ext parameter', () {
      final File f = manager.getAudioExportFile(ext: 'wav');
      expect(f.path, endsWith('exportAudio.wav'));
    });

    test('getImageCompressedFile uses export directory', () {
      final File f = manager.getImageCompressedFile();
      expect(f.path, contains('export'));
      expect(f.path, endsWith('compressedImage.jpg'));
    });

    test('getPreviewImageFile uses provided directory and index', () {
      final Directory dir = Directory('/tmp/preview');
      final File f = manager.getPreviewImageFile(dir, 3);
      expect(f.path, contains('preview'));
      expect(f.path, endsWith('previewImage3.jpg'));
    });

    test('getThumbnailFile uses export directory', () {
      final File f = manager.getThumbnailFile();
      expect(f.path, contains('export'));
      expect(f.path, endsWith('thumbnail.jpg'));
    });

    test('directories are exposed via getters', () {
      expect(manager.exportDirectory.path, equals(exportDir.path));
      expect(
          manager.alternateExportDirectory.path, equals(altDir.path));
    });
  });
}
