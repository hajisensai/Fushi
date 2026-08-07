import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// TODO-1236：验证「有声书 / 字幕 / 封面」持久写路径的目录解析随桌面自定义数据根走。
///
/// TODO-935 承诺的「新写入跟随数据根」在 1226 施工时发现从未接上——以下子系统仍直连
/// `getApplicationDocumentsDirectory()`，自定义数据根生效后新写入落回平台 Documents：
///  - 有声书持久根（`AudiobookStorage`，上游包经 [AudiobookStorage.documentsRootResolver]
///    注入 [AppPaths.documentsRootDirectory]）；
///  - 视频外挂字幕副本（[AppPaths.videoSubtitlesDirectory]）；
///  - 视频封面（[AppPaths.videoCoversDirectory]）。
///
/// 用 [AppPaths.debugDataRootReader] 注入假 data_root，断言：
///  - 设了自定义数据根 → 三个写路径落 `<dataRoot>/documents/<child>`；
///  - 未设 → 落平台 Documents 默认根（逐字节等价老用户）。
///
/// `isDesktopPlatform` 在测试宿主（桌面 VM，含 CI Linux/Mac/Win）下恒 true。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory defaultDocs;

  /// BUG-1115：默认 documents 根 = `<平台 Documents>/Hibiki/data`（全新安装；本文件的
  /// mock support 根下没有 `hibiki.db`，故一律判为新装）。
  String defaultDocsRoot() => p.joinAll(<String>[
        defaultDocs.path,
        ...AppPaths.defaultDocumentsChildSegments,
      ]);

  setUp(() {
    AppPaths.debugResetDocumentsLayoutCache();
    tmp = Directory.systemTemp.createTempSync('hibiki_wpaths_');
    defaultDocs = Directory(p.join(tmp.path, 'default_documents'))
      ..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return defaultDocs.path;
        }
        if (call.method == 'getTemporaryDirectory') {
          return p.join(tmp.path, 'systemp');
        }
        if (call.method == 'getApplicationSupportDirectory') {
          return p.join(tmp.path, 'default_support');
        }
        return null;
      },
    );
    // 生产接线：app 启动期把有声书根解析接到 AppPaths（这里显式重放以端到端验证）。
    AudiobookStorage.documentsRootResolver = AppPaths.documentsRootDirectory;
  });

  tearDown(() {
    AppPaths.debugDataRootReader = null;
    AppPaths.debugResetDocumentsLayoutCache();
    AudiobookStorage.documentsRootResolver = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('自定义数据根生效 → 有声书/字幕/封面新写入落 <dataRoot>/documents/<child>', () async {
    final Directory dataRoot = Directory(p.join(tmp.path, 'NewRoot'))
      ..createSync(recursive: true);
    AppPaths.debugDataRootReader = () async => dataRoot.path;

    final String docsChild = p.join(dataRoot.path, 'documents');

    expect((await AppPaths.videoSubtitlesDirectory()).path,
        equals(p.join(docsChild, 'video_subtitles')));
    expect((await AppPaths.videoCoversDirectory()).path,
        equals(p.join(docsChild, 'video_covers')));
    // 有声书根经注入的 resolver → 也落新根。
    expect(
        p.equals(await AudiobookStorage.audiobooksRootDir(),
            p.join(docsChild, 'audiobooks')),
        isTrue);
  });

  test('未设自定义数据根（全新安装）→ 三个写路径落 <Documents>/Hibiki/data', () async {
    AppPaths.debugDataRootReader = () async => '';
    // 默认布局判定只在启动期的 resolve() 里做（mock support 根下无 hibiki.db → 新装）。
    await AppPaths.resolve();

    expect((await AppPaths.videoSubtitlesDirectory()).path,
        equals(p.join(defaultDocsRoot(), 'video_subtitles')));
    expect((await AppPaths.videoCoversDirectory()).path,
        equals(p.join(defaultDocsRoot(), 'video_covers')));
    expect(
        p.equals(await AudiobookStorage.audiobooksRootDir(),
            p.join(defaultDocsRoot(), 'audiobooks')),
        isTrue);
    // BUG-1115 的核心断言：用户文档根下不再直接出现 Hibiki 的内容目录。
    expect((await AppPaths.videoCoversDirectory()).path,
        isNot(equals(p.join(defaultDocs.path, 'video_covers'))));
  });

  test('data_root 指向不存在目录 → 回退默认（不落失效路径）', () async {
    AppPaths.debugDataRootReader = () async => p.join(tmp.path, 'missing');
    AppPaths.forceDefaultRootForSession = true; // 配置不可达时 resolve 会抛，显式回退默认根。
    addTearDown(() => AppPaths.forceDefaultRootForSession = false);
    await AppPaths.resolve();

    expect((await AppPaths.videoCoversDirectory()).path,
        equals(p.join(defaultDocsRoot(), 'video_covers')));
    expect(
        p.equals(await AudiobookStorage.audiobooksRootDir(),
            p.join(defaultDocsRoot(), 'audiobooks')),
        isTrue);
  });
}
