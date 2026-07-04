import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/import/real_path_directory_picker.dart'
    show listFilesInDirectory, listSubdirectories;

/// TODO-949 守卫：安卓「导入视频/有声书文件夹」改走真实路径目录浏览器
/// （`pickRealDirectoryPath`），而非 SAF content URI。
///
/// 两层：
/// 1) 纯函数 [listSubdirectories] 行为：在临时真实目录上验证只列直接子目录、
///    已排序、过滤掉文件、不存在/无权限兜底空——这是浏览器下钻的磁盘真值层。
/// 2) 源码扫描：两个导入入口必须调统一的 `pickRealDirectoryPath`，且 helper
///    自身按平台分支（安卓走权限+浏览器，非安卓维持 getDirectoryPath）。
void main() {
  group('listSubdirectories pure behaviour', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('hibiki_dir_picker_');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('lists only direct subdirectories, sorted, files excluded', () {
      Directory('${root.path}/beta').createSync();
      Directory('${root.path}/alpha').createSync();
      // 子目录里再建一层，确认不递归。
      Directory('${root.path}/alpha/nested').createSync();
      File('${root.path}/movie.mkv').writeAsStringSync('x');

      final List<String> subs = listSubdirectories(root.path);

      expect(subs.length, 2, reason: '只数直接子目录，文件与孙目录都不算');
      expect(subs[0].endsWith('alpha'), isTrue, reason: '已按路径排序');
      expect(subs[1].endsWith('beta'), isTrue);
      expect(
        subs.any((String s) => s.endsWith('movie.mkv')),
        isFalse,
        reason: '文件必须被过滤掉',
      );
      expect(
        subs.any((String s) => s.endsWith('nested')),
        isFalse,
        reason: '非递归：孙目录不出现',
      );
    });

    test('non-existent directory -> empty (no throw)', () {
      expect(listSubdirectories('${root.path}/does_not_exist'), isEmpty);
    });
  });

  // board 1112：文件模式浏览器的叶子层——列直接子文件、可按扩展名过滤。
  group('listFilesInDirectory pure behaviour', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('hibiki_file_picker_');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('lists only direct files, sorted, subdirs excluded (no filter)', () {
      File('${root.path}/b.mkv').writeAsStringSync('x');
      File('${root.path}/a.mp4').writeAsStringSync('x');
      Directory('${root.path}/sub').createSync();
      File('${root.path}/sub/nested.mkv').writeAsStringSync('x');

      final List<String> files = listFilesInDirectory(root.path);

      expect(files.length, 2, reason: '只数直接子文件，目录与孙文件都不算');
      expect(files[0].endsWith('a.mp4'), isTrue, reason: '已按路径排序');
      expect(files[1].endsWith('b.mkv'), isTrue);
      expect(
        files.any((String s) => s.endsWith('sub')),
        isFalse,
        reason: '目录必须被过滤掉',
      );
      expect(
        files.any((String s) => s.endsWith('nested.mkv')),
        isFalse,
        reason: '非递归：孙文件不出现',
      );
    });

    test('extension filter keeps only matching files (case-insensitive)', () {
      File('${root.path}/a.srt').writeAsStringSync('x');
      File('${root.path}/b.ASS').writeAsStringSync('x');
      File('${root.path}/c.vtt').writeAsStringSync('x');
      File('${root.path}/d.mkv').writeAsStringSync('x');
      File('${root.path}/e').writeAsStringSync('x'); // 无扩展名

      final List<String> subs = listFilesInDirectory(
        root.path,
        allowedExtensions: const <String>{'srt', 'ass', 'vtt', 'ssa'},
      );

      expect(
        subs.map((String s) => s.split(RegExp(r'[\\/]')).last).toSet(),
        <String>{'a.srt', 'b.ASS', 'c.vtt'},
        reason: '扩展名大小写不敏感命中，无关/无扩展名文件排除',
      );
    });

    test('non-existent directory -> empty (no throw)', () {
      expect(listFilesInDirectory('${root.path}/nope'), isEmpty);
    });
  });

  group('source guards: import folder uses unified real-path picker', () {
    test('video_import_dialog._pickFolder calls pickRealDirectoryPath', () {
      final String src = File('lib/src/media/video/video_import_dialog.dart')
          .readAsStringSync();
      expect(
        src.contains('pickRealDirectoryPath('),
        isTrue,
        reason: '视频导入文件夹必须走统一真实路径入口，'
            '而非直接 FilePicker.getDirectoryPath()（安卓返回不可用 SAF 串）',
      );
      // 直接的 getDirectoryPath 不该再出现在 _pickFolder 里。
      final int idx = src.indexOf('Future<void> _pickFolder()');
      final int end = src.indexOf('Future<', idx + 10);
      final String body = src.substring(idx, end);
      expect(
        body.contains('getDirectoryPath'),
        isFalse,
        reason: '_pickFolder 不得再直接调 getDirectoryPath',
      );
    });

    // 注：原「audiobook_import_dialog._pickAudioDir calls pickRealDirectoryPath」
    // 守卫已于 TODO-1031 作废——按用户「改成只支持一个音频」诉求，有声书导入删除了
    // 整个目录吞并入口 _pickAudioDir（会把一个文件夹下所有音频聚成一本），改为只保留
    // 多选文件（多段章节有声书仍可用）。故 audiobook_import_dialog.dart 不再含
    // pickRealDirectoryPath；视频侧 _pickFolder 的同名守卫（上方）仍有效保留。

    test('helper branches on Android + permission before browsing', () {
      final String src =
          File('lib/src/media/import/real_path_directory_picker.dart')
              .readAsStringSync();
      // 非安卓维持 getDirectoryPath（桌面/iOS 真实路径）。
      expect(
        src.contains('TargetPlatform.android') &&
            src.contains('getDirectoryPath'),
        isTrue,
        reason: '非安卓平台必须保留 getDirectoryPath 行为',
      );
      // 安卓必须先确保 MANAGE_EXTERNAL_STORAGE 权限，不得静默吞。
      expect(
        src.contains('requestExternalStoragePermissions') &&
            src.contains('hasExternalStoragePermission'),
        isTrue,
        reason: '安卓分支必须先请求并校验全文件访问权限',
      );
    });

    // board 1112：单文件视频/字幕导入改走真实路径文件浏览器（不复制到 cache）。
    test('video _pickVideo/_pickSubtitle call pickRealFilePath', () {
      final String src = File('lib/src/media/video/video_import_dialog.dart')
          .readAsStringSync();
      final String pickVideo = _methodBody(src, 'Future<void> _pickVideo()');
      final String pickSubtitle =
          _methodBody(src, 'Future<void> _pickSubtitle()');

      expect(
        pickVideo.contains('pickRealFilePath('),
        isTrue,
        reason: '单文件视频选择必须走真实路径文件浏览器，'
            '而非直接 FilePicker.pickFiles（安卓会复制到 cache）',
      );
      expect(
        pickVideo.contains('FilePicker.platform.pickFiles'),
        isFalse,
        reason: '_pickVideo 不得再直接调 FilePicker.pickFiles',
      );
      expect(
        pickSubtitle.contains('pickRealFilePath('),
        isTrue,
        reason: '单文件字幕选择必须走真实路径文件浏览器',
      );
      expect(
        pickSubtitle.contains('FilePicker.platform.pickFiles'),
        isFalse,
        reason: '_pickSubtitle 不得再直接调 FilePicker.pickFiles',
      );
    });

    test('pickRealFilePath falls back to file_picker without full access', () {
      final String src =
          File('lib/src/media/import/real_path_directory_picker.dart')
              .readAsStringSync();
      final String fileEntry =
          _methodBody(src, 'Future<String?> pickRealFilePath(');
      // 文件入口存在，且无全文件访问权限时回退（不静默返回 null / 不硬性要求授权）。
      expect(fileEntry.isNotEmpty, isTrue,
          reason: '必须存在 pickRealFilePath 文件入口');
      expect(
        fileEntry.contains('_fallbackPickFile'),
        isTrue,
        reason: '桌面/iOS 及安卓无全文件访问必须回退 file_picker（逃生口）',
      );
    });
  });
}

/// 取从 [signature] 起到下一个顶层 `Future<`/`class ` 声明前的方法体切片，供
/// 源码守卫按方法定位。粗粒度但足够断言「这个方法里出现/不出现某调用」。
String _methodBody(String src, String signature) {
  final int idx = src.indexOf(signature);
  if (idx < 0) return '';
  final int nextFuture = src.indexOf('Future<', idx + signature.length);
  final int nextClass = src.indexOf('\nclass ', idx + signature.length);
  int end = src.length;
  for (final int cand in <int>[nextFuture, nextClass]) {
    if (cand >= 0 && cand < end) end = cand;
  }
  return src.substring(idx, end);
}
