import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/import/real_path_directory_picker.dart'
    show listSubdirectories;

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

    test('audiobook_import_dialog._pickAudioDir calls pickRealDirectoryPath',
        () {
      final String src =
          File('lib/src/media/audiobook/audiobook_import_dialog.dart')
              .readAsStringSync();
      expect(src.contains('pickRealDirectoryPath('), isTrue);
    });

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
  });
}
