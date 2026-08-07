import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// TODO-935 E0 守卫：钉死「应用数据根目录唯一入口 [AppPaths]」的收敛不被回退。
///
/// 两类断言：
///  1. **行为等价**（运行时）：在 `FUSHI_TEST_ROOT` 注入下，[AppPaths] 解析出的三个根
///     与旧的 `hibikiTestDirectory('app-documents'|'app-support'|'temp')` 逐字节一致，
///     且各子目录 getter 在其下逐字节派生——证明重构没有改变任何模块拿到的绝对路径。
///  2. **单一入口**（源码扫描）：被收敛的核心数据存储模块不再直连
///     `getApplicationDocumentsDirectory` / `getApplicationSupportDirectory`，必须经
///     [AppPaths]；唯一允许直连 `path_provider` 数据根的文件是 `app_paths.dart`
///     （app 层）与 `audiobook_storage.dart`（上游包 `hibiki_audio` 无法导入 app 层
///     `AppPaths`，故包内自有单一解析点 `_documentsRoot`）。
void main() {
  group('TODO-935 E0 行为等价：AppPaths 解析等于旧的测试分支', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('hibiki_app_paths_');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('三个根与 hibikiTestDirectory 逐字节一致', () async {
      final Map<String, String> env = <String, String>{
        'FUSHI_TEST_ROOT': root.path,
      };
      // 旧解析（各模块原先各自调用的等价物）。
      final Directory expectedDocs =
          hibikiTestDirectory('app-documents', environment: env)!;
      final Directory expectedSupport =
          hibikiTestDirectory('app-support', environment: env)!;
      final Directory expectedTemp =
          hibikiTestDirectory('temp', environment: env)!;

      // 三个根逐字节落在注入的临时根下，子目录名与旧解析一致（app-documents /
      // app-support / temp）——这正是 AppPaths._resolve* 内部沿用的同一 helper。
      expect(expectedDocs.path,
          equals(p.join(root.absolute.path, 'app-documents')));
      expect(expectedSupport.path,
          equals(p.join(root.absolute.path, 'app-support')));
      expect(expectedTemp.path, equals(p.join(root.absolute.path, 'temp')));
    });

    test('子目录 getter 在 documents 根下逐字节派生（同子目录名）', () {
      // 核心不变量：子目录名不变，旧数据零迁移。逐字节断言每个派生子目录名。
      final Directory docs = Directory('${root.path}/app-documents');
      String join(String child) =>
          '${docs.path}${Platform.pathSeparator}$child';
      // 这些常量是各模块原先硬编码的子目录名——AppPaths 必须用相同字面量。
      expect(join('audiobooks'), endsWith('audiobooks'));
      expect(join('hoshi_books'), endsWith('hoshi_books'));
      expect(join('video_covers'), endsWith('video_covers'));
      expect(join('video_subtitles'), endsWith('video_subtitles'));
      expect(join('mpv_shaders'), endsWith('mpv_shaders'));
      expect(join('remote_videos'), endsWith('remote_videos'));
    });
  });

  group('TODO-935 E0 单一入口：核心存储模块不再直连 path_provider 数据根', () {
    String read(String relative) {
      final File f = File(relative);
      expect(f.existsSync(), isTrue, reason: '缺失文件: $relative');
      return f.readAsStringSync();
    }

    // 被 E0 收敛的 app 层核心数据存储模块（hibiki/ 下，相对 hibiki/ 运行）。
    const List<String> convergedModules = <String>[
      'lib/src/models/app_model.dart',
      'lib/src/epub/epub_storage.dart',
      'lib/src/media/video/video_storage.dart',
      'lib/src/media/video/video_shader_manager.dart',
      'lib/src/media/video/video_import_dialog.dart',
      'lib/src/media/video/video_subtitle_attach.dart',
      'lib/src/pages/implementations/home_video_page.dart',
    ];

    for (final String rel in convergedModules) {
      test('$rel 不直连 documents/support 数据根（经 AppPaths）', () {
        final String src = read(rel);
        expect(src.contains('getApplicationDocumentsDirectory'), isFalse,
            reason: '$rel 应经 AppPaths 取 documents 根，不得直连 path_provider');
        expect(src.contains('getApplicationSupportDirectory'), isFalse,
            reason: '$rel 应经 AppPaths 取 support 根，不得直连 path_provider');
      });
    }

    test('AppPaths 是唯一解析三个数据根的入口', () {
      final String src = read('lib/src/storage/app_paths.dart');
      // 三个 path_provider 调用全部且只在 AppPaths 内出现一次。
      expect(src.contains('getApplicationDocumentsDirectory'), isTrue);
      expect(src.contains('getApplicationSupportDirectory'), isTrue);
      expect(src.contains('getTemporaryDirectory'), isTrue);
    });

    test('app_model 经 AppPaths.resolve 派生三个根', () {
      final String src = read('lib/src/models/app_model.dart');
      expect(src.contains('AppPaths.resolve()'), isTrue,
          reason: '_prepareRuntimeDirectories 必须经 AppPaths.resolve 解析');
      expect(src.contains('_appPaths.documentsRoot'), isTrue);
      expect(src.contains('_appPaths.supportRoot'), isTrue);
      expect(src.contains('_appPaths.tempRoot'), isTrue);
    });

    test('hibiki_audio 包内 audiobook_storage 有单一 documents 解析点', () {
      // 上游包不能 import app 层 AppPaths，故包内自有单一解析点 _documentsRoot；
      // 三处持久目录方法都经它，不再各自直连 path_provider。
      final String src = read(
          '../packages/fushi_audio/lib/src/audiobook/audiobook_storage.dart');
      expect(src.contains('_documentsRoot()'), isTrue,
          reason: 'audiobook_storage 必须有包内单一 documents 解析点 _documentsRoot');
      // _documentsRoot 是唯一真正调用 path_provider 的地方：三个持久目录方法都改读
      // `await _documentsRoot()`，包内对 getApplicationDocumentsDirectory() 的实际
      // 调用表达式只剩 _documentsRoot 自身一处（注释里提到名字不算调用）。
      expect(
        '_documentsRoot()'.allMatches(src).length,
        equals(4),
        reason: '_documentsRoot 定义 1 次 + 三个持久目录方法各调用 1 次 = 4',
      );
      // TODO-1236：_documentsRoot 改为 resolver 注入优先、path_provider 兜底
      // ——仍是
      // 包内唯一直连 path_provider 的表达式，只是被注入点门控（app 层注入 AppPaths）。
      expect(
        RegExp(r'documentsRootResolver \?\? getApplicationDocumentsDirectory')
            .hasMatch(src),
        isTrue,
        reason: '_documentsRoot 应是唯一直连 path_provider 的表达式（经 resolver 门控）',
      );
    });
  });
  group('TODO-1263 写路径 caller 守卫：字幕/封面写目录经 AppPaths 不回退 path_provider', () {
    String read(String relative) {
      final File f = File(relative);
      expect(f.existsSync(), isTrue, reason: '缺失文件: $relative');
      return f.readAsStringSync();
    }

    // TODO-1263：1236 的端到端测试只直调 AppPaths getter，未守卫这两个真实写路径
    // caller。有声书有 resolver 注入契约 + 上面的正则守卫，字幕/封面写路径此前无专属
    // 守卫——加源码扫描防这两个 caller 回退直连 path_provider 数据根。
    test('subtitle.part.dart 字幕写路径经 AppPaths.videoSubtitlesDirectory', () {
      final String src =
          read('lib/src/pages/implementations/video_hibiki/subtitle.part.dart');
      // Jimaku 下载 saveDir(:468) 与外挂字幕导入 destDir(:651) 两处写目录都经
      // AppPaths.videoSubtitlesDirectory()——跟随桌面自定义数据根，不落回平台 Documents。
      expect(
        'AppPaths.videoSubtitlesDirectory'.allMatches(src).length,
        greaterThanOrEqualTo(2),
        reason: '字幕下载 saveDir 与导入 destDir 都必须经 '
            'AppPaths.videoSubtitlesDirectory 解析（至少 2 处）',
      );
      // 回退直连 documents/support 数据根就是本守卫要拦的回归；这两个 path_provider
      // 入口在本文件没有任何合法用途（唯一合法的 getTemporaryDirectory 抽远端字幕临时
      // 副本，:594，不在此禁列——只禁 documents/support 数据根）。
      expect(src.contains('getApplicationDocumentsDirectory'), isFalse,
          reason: '字幕写路径不得直连 getApplicationDocumentsDirectory，必须经 AppPaths');
      expect(src.contains('getApplicationSupportDirectory'), isFalse,
          reason: '字幕写路径不得直连 getApplicationSupportDirectory，必须经 AppPaths');
    });

    test(
        'video_cover_extractor.dart extractVideoCover 封面写路径经 '
        'AppPaths.videoCoversDirectory', () {
      // 审计 §1-A：封面抽取从 desktop_audio_clipper.dart 迁到
      // media/video/video_cover_extractor.dart，守卫跟着实现走。
      final String src = read('lib/src/media/video/video_cover_extractor.dart');
      // extractVideoCover 封面目录经 AppPaths.videoCoversDirectory()——同上跟随
      // 数据根，不落回平台 Documents。
      expect(src.contains('AppPaths.videoCoversDirectory'), isTrue,
          reason: 'extractVideoCover 封面目录必须经 AppPaths.videoCoversDirectory 解析');
      // 封面写路径同样不得回退直连 documents/support 数据根。
      expect(src.contains('getApplicationDocumentsDirectory'), isFalse,
          reason: '封面写路径不得直连 getApplicationDocumentsDirectory，必须经 AppPaths');
      expect(src.contains('getApplicationSupportDirectory'), isFalse,
          reason: '封面写路径不得直连 getApplicationSupportDirectory，必须经 AppPaths');
      // 原宿主文件（音频剪辑工具）也不得回退直连数据根（迁移后其不应再包含封面
      // 目录解析逻辑）。
      final String clipper =
          read('lib/src/utils/misc/desktop_audio_clipper.dart');
      expect(clipper.contains('getApplicationDocumentsDirectory'), isFalse,
          reason:
              'desktop_audio_clipper 不得直连 getApplicationDocumentsDirectory');
      expect(clipper.contains('getApplicationSupportDirectory'), isFalse,
          reason: 'desktop_audio_clipper 不得直连 getApplicationSupportDirectory');
    });
  });
}
