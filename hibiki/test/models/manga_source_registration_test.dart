import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/models/app_model.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  // AppModel 的 DefaultCacheManager 字段在构造时就异步打开缓存目录，会经
  // path_provider 平台通道；单测里没有插件实现，mock 一个临时目录即可。
  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_manga_reg_path_provider');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  test('MangaFushiSource 注册在 ReaderMediaType 下（三源并存不互覆）', () {
    final AppModel appModel = AppModel(testPlatformServices());
    appModel.populateMediaTypes();
    appModel.populateMediaSources();

    expect(MangaFushiSource.instance.mediaType, ReaderMediaType.instance);

    final Map<String, MediaSource>? readerSources =
        appModel.mediaSources[ReaderMediaType.instance];
    expect(readerSources, isNotNull);
    expect(
      readerSources!['reader_manga'],
      same(MangaFushiSource.instance),
    );
    // 既有 EPUB / PDF 源必须仍在（无覆盖）。
    expect(readerSources['reader_fushi'], same(ReaderFushiSource.instance));
    expect(readerSources['reader_pdf'], same(ReaderPdfSource.instance));
  });

  test('漫画 MediaItem 经 getMediaSource 解析到 MangaFushiSource', () {
    // 这正是书架打开路径在 appModel.openMedia 前做的查表：证明打开漫画会路由到
    // 漫画源（currentMediaSource / 制卡 / 关书同步都依赖它）。
    final AppModel appModel = AppModel(testPlatformServices());
    appModel.populateMediaTypes();
    appModel.populateMediaSources();

    final MediaItem mangaItem = MediaItem(
      // 身份统一 fushi://book/<bookKey>（无 manga:// 特例）。
      mediaIdentifier: ReaderFushiSource.mediaIdentifierFor('テスト漫画'),
      title: 'テスト漫画',
      mediaTypeIdentifier: ReaderMediaType.instance.uniqueKey,
      mediaSourceIdentifier: MangaFushiSource.kUniqueKey,
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: true,
    );

    expect(
      mangaItem.getMediaSource(appModel: appModel),
      same(MangaFushiSource.instance),
    );
  });
}
