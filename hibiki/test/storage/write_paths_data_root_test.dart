import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/storage/app_paths.dart';

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

  setUp(() {
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

  test('未设自定义数据根 → 三个写路径落平台 Documents 默认根', () async {
    AppPaths.debugDataRootReader = () async => '';

    expect((await AppPaths.videoSubtitlesDirectory()).path,
        equals(p.join(defaultDocs.path, 'video_subtitles')));
    expect((await AppPaths.videoCoversDirectory()).path,
        equals(p.join(defaultDocs.path, 'video_covers')));
    expect(
        p.equals(await AudiobookStorage.audiobooksRootDir(),
            p.join(defaultDocs.path, 'audiobooks')),
        isTrue);
  });

  test('data_root 指向不存在目录 → 回退默认（不落失效路径）', () async {
    AppPaths.debugDataRootReader = () async => p.join(tmp.path, 'missing');

    expect((await AppPaths.videoCoversDirectory()).path,
        equals(p.join(defaultDocs.path, 'video_covers')));
    expect(
        p.equals(await AudiobookStorage.audiobooksRootDir(),
            p.join(defaultDocs.path, 'audiobooks')),
        isTrue);
  });
}
