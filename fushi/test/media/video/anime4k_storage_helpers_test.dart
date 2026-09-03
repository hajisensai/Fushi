import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_shader_downloader.dart';
import 'package:path/path.dart' as p;

/// 存储页 Anime4K 助手：清单并集、占用统计、删除只碰清单内文件。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('anime4k_storage_test');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄延迟释放：留给系统临时目录清理。
    }
  });

  void writeFile(String name, int bytes) {
    File(p.join(dir.path, name))
        .writeAsBytesSync(List<int>.filled(bytes, 0x61));
  }

  test('清单是全预设文件名的去重并集且非空', () {
    final List<String> manifest = anime4kManifestFileNames();
    expect(manifest, isNotEmpty);
    expect(manifest.toSet().length, manifest.length);
    for (final Anime4kPreset preset in kAnime4kPresets) {
      for (final String name in preset.fileNames) {
        expect(manifest, contains(name));
      }
    }
  });

  test('占用统计只数清单内文件', () {
    final String known = anime4kManifestFileNames().first;
    writeFile(known, 100);
    writeFile('My_Custom_Shader.glsl', 999);
    expect(anime4kInstalledBytesIn(dir), 100);
  });

  test('删除只删清单内文件，用户自导入着色器不碰', () {
    final List<String> manifest = anime4kManifestFileNames();
    writeFile(manifest[0], 10);
    writeFile(manifest[1], 20);
    writeFile('My_Custom_Shader.glsl', 30);

    final List<String> deleted = deleteAnime4kFilesIn(dir);

    expect(deleted.toSet(), <String>{manifest[0], manifest[1]});
    expect(File(p.join(dir.path, manifest[0])).existsSync(), isFalse);
    expect(File(p.join(dir.path, manifest[1])).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'My_Custom_Shader.glsl')).existsSync(), isTrue,
        reason: '非清单文件（用户自导入）绝不能被删');
    expect(anime4kInstalledBytesIn(dir), 0);
  });

  test('目录不存在时删除/统计安全返回', () {
    final Directory missing = Directory(p.join(dir.path, 'missing'));
    expect(deleteAnime4kFilesIn(missing), isEmpty);
    expect(anime4kInstalledBytesIn(missing), 0);
  });
}
