// 发现页 / 用户自配服务器的「下载到本机」落点不依赖下载中心已启动。
//
// 回归：默认下载根以前只在 `startAnimeDownloadService()` 里赋值，而那条服务只在
// 「浏览」模块启用时才起——iOS 上它恒不可用（App Store 合规），却照样能从自己的
// Audiobookshelf / OPDS / AList 下载。根是空串 → 落点退化成相对路径
// `discovery/<kind>`，任务永远失败。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    AppPaths.debugResetDocumentsLayoutCache();
    tmp = Directory.systemTemp.createTempSync('fushi_discovery_dir_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => tmp.path,
        );
  });

  tearDown(() {
    AppPaths.debugResetDocumentsLayoutCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<AppModel> prefsBackedAppModel() async {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    return _TestAppModel()
      ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tmp)
      ..wireDatabaseForTesting(db);
  }

  test('download center never started: destination is an absolute path '
      'under the default download root', () async {
    final AppModel appModel = await prefsBackedAppModel();
    expect(appModel.downloadDefaultSaveRoot, isEmpty);

    final String dir = await appModel.discoveryDownloadDirFor(
      DiscoveryMediaKind.audiobook,
    );

    expect(p.isAbsolute(dir), isTrue, reason: dir);
    expect(p.split(dir).sublist(p.split(dir).length - 4), <String>[
      'anime_downloads',
      'content',
      'discovery',
      'audiobook',
    ]);
    // 解析结果记下来，与下载中心之后启动时用的默认根是同一个值。
    expect(dir, startsWith(appModel.downloadDefaultSaveRoot));
  });

  test('configured download root still wins', () async {
    final AppModel appModel = await prefsBackedAppModel();
    final String configured = p.join(tmp.path, 'my_downloads');
    await appModel.prefsRepo.setDownloadSaveRoot(configured);

    final String dir = await appModel.discoveryDownloadDirFor(
      DiscoveryMediaKind.novel,
    );

    expect(dir, p.join(configured, 'discovery', 'novel'));
  });
}
