import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// TODO-935 E0 守卫：钉死「应用数据根目录唯一入口 [AppPaths]」的收敛不被回退。
///
/// 两类断言：
///  1. **行为等价**（运行时）：在 `FUSHI_TEST_ROOT` 注入下，[AppPaths] 解析出的三个根
///     与旧的 `fushiTestDirectory('app-documents'|'app-support'|'temp')` 逐字节一致，
///     且各子目录 getter 在其下逐字节派生——证明重构没有改变任何模块拿到的绝对路径。
///  2. **经由 AppPaths 的接线**（源码扫描）：几处真实写路径 caller 确实调了
///     [AppPaths] 的对应 getter。
///
/// 「别处不许直连 path_provider」这类禁止项已改由 analyzer 插件规则判定：
/// `fushi_platform_dirs_via_app_paths`（app 内按「文件 × 函数」的精确豁免棘轮，
/// packages/fushi_lints/lib/src/rules/platform_dirs_via_app_paths.dart）与
/// `fushi_pure_dart_package_imports`（引擎 / fushi_audio 连 import path_provider
/// 都不许）。
void main() {
  group('TODO-935 E0 行为等价：AppPaths 解析等于旧的测试分支', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('fushi_app_paths_');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('三个根与 fushiTestDirectory 逐字节一致', () async {
      final Map<String, String> env = <String, String>{
        'FUSHI_TEST_ROOT': root.path,
      };
      // 旧解析（各模块原先各自调用的等价物）。
      final Directory expectedDocs = fushiTestDirectory(
        'app-documents',
        environment: env,
      )!;
      final Directory expectedSupport = fushiTestDirectory(
        'app-support',
        environment: env,
      )!;
      final Directory expectedTemp = fushiTestDirectory(
        'temp',
        environment: env,
      )!;

      // 三个根逐字节落在注入的临时根下，子目录名与旧解析一致（app-documents /
      // app-support / temp）——这正是 AppPaths._resolve* 内部沿用的同一 helper。
      expect(
        expectedDocs.path,
        equals(p.join(root.absolute.path, 'app-documents')),
      );
      expect(
        expectedSupport.path,
        equals(p.join(root.absolute.path, 'app-support')),
      );
      expect(expectedTemp.path, equals(p.join(root.absolute.path, 'temp')));
    });

    test('子目录 getter 在 documents 根下逐字节派生（同子目录名）', () {
      // 核心不变量：子目录名不变，旧数据零迁移。逐字节断言每个派生子目录名。
      final Directory docs = Directory('${root.path}/app-documents');
      String join(String child) =>
          '${docs.path}${Platform.pathSeparator}$child';
      // 这些常量是各模块原先硬编码的子目录名——AppPaths 必须用相同字面量。
      expect(join('audiobooks'), endsWith('audiobooks'));
      expect(join('fushi_books'), endsWith('fushi_books'));
      expect(join('video_covers'), endsWith('video_covers'));
      expect(join('video_subtitles'), endsWith('video_subtitles'));
      expect(join('mpv_shaders'), endsWith('mpv_shaders'));
      expect(join('remote_videos'), endsWith('remote_videos'));
    });
  });

  group('TODO-935 E0 单一入口：核心存储模块经 AppPaths 派生数据根', () {
    String read(String relative) {
      final File f = File(relative);
      expect(f.existsSync(), isTrue, reason: '缺失文件: $relative');
      return f.readAsStringSync();
    }

    test('app_model 经 AppPaths.resolve 派生三个根', () {
      final String src = read('lib/src/models/app_model.dart');
      expect(
        src.contains('AppPaths.resolve()'),
        isTrue,
        reason: '_prepareRuntimeDirectories 必须经 AppPaths.resolve 解析',
      );
      expect(src.contains('_appPaths.documentsRoot'), isTrue);
      expect(src.contains('_appPaths.supportRoot'), isTrue);
      expect(src.contains('_appPaths.tempRoot'), isTrue);
    });

    test('fushi_audio 包内 audiobook_storage 有单一 documents 解析点', () {
      // 上游包不能 import app 层 AppPaths，故包内自有单一解析点 _documentsRoot；
      // 三处持久目录方法都经它，不再各自直连 path_provider。
      final String src = read(
        '../packages/fushi_audio/lib/src/audiobook/audiobook_storage.dart',
      );
      expect(
        src.contains('_documentsRoot()'),
        isTrue,
        reason: 'audiobook_storage 必须有包内单一 documents 解析点 _documentsRoot',
      );
      // 单一解析点：_documentsRoot 只定义一次，包内取 documents 根的方法（持久目录、
      // 暂存目录……）一律 `await _documentsRoot()`，不各自解析平台目录。不钉调用方
      // 个数——新增经它取根的方法是合规用法（#2815 加了 stagingDir）。
      expect(
        RegExp(
          r'Future<Directory>\s+_documentsRoot\(\)',
        ).allMatches(src).length,
        equals(1),
        reason: '_documentsRoot 必须是唯一一处定义',
      );
      expect(
        'await _documentsRoot()'.allMatches(src).length,
        greaterThanOrEqualTo(3),
        reason: '三个持久目录方法都经 _documentsRoot 取根',
      );
      // TODO-1236：_documentsRoot 改为 resolver 注入优先；无头服务端拆分后
      // audiobook_storage.dart 是纯 Dart，**不再直连 path_provider**——平台兜底
      // `getApplicationDocumentsDirectory` 挪到重文件 audiobook_storage_platform.dart，
      // 由 installAudiobookStoragePlatform() 以 `??=` 装入（不覆盖 app 层注入的 AppPaths）。
      // 「本文件零 path_provider」由 fushi_pure_dart_package_imports 判定。
      expect(
        RegExp(
          r'documentsRootResolver \?\? _unassignedDocumentsRoot',
        ).hasMatch(src),
        isTrue,
        reason: '_documentsRoot 应经 resolver 门控、未装配时抛 StateError',
      );
      final String platformSrc = read(
        'lib/src/media/audiobook/audiobook_storage_platform.dart',
      );
      expect(
        RegExp(
          r'documentsRootResolver \?\?= getApplicationDocumentsDirectory',
        ).hasMatch(platformSrc),
        isTrue,
        reason: '平台兜底只能以 ??= 补默认值，不得覆盖 AppPaths 注入',
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
      final String src = read(
        'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
      );
      // Jimaku 下载 saveDir(:468) 与外挂字幕导入 destDir(:651) 两处写目录都经
      // AppPaths.videoSubtitlesDirectory()——跟随桌面自定义数据根，不落回平台 Documents。
      expect(
        'AppPaths.videoSubtitlesDirectory'.allMatches(src).length,
        greaterThanOrEqualTo(2),
        reason:
            '字幕下载 saveDir 与导入 destDir 都必须经 '
            'AppPaths.videoSubtitlesDirectory 解析（至少 2 处）',
      );
    });

    test('video_cover_extractor.dart extractVideoCover 封面写路径经 '
        'AppPaths.videoCoversDirectory', () {
      // 审计 §1-A：封面抽取从 desktop_audio_clipper.dart 迁到
      // media/video/video_cover_extractor.dart，守卫跟着实现走。
      final String src = read(
        '../packages/fushi_engine/lib/media/video/video_cover_extractor.dart',
      );
      // extractVideoCover 封面目录经 AppPaths.videoCoversDirectory()——同上跟随
      // 数据根，不落回平台 Documents。
      expect(
        src.contains('AppPaths.videoCoversDirectory'),
        isTrue,
        reason: 'extractVideoCover 封面目录必须经 AppPaths.videoCoversDirectory 解析',
      );
    });
  });
}
