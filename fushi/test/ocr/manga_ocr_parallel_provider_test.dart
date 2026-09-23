import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

/// 只省略平台/词典启动；偏好读写、通知与两个生产 provider 均使用真实实现。
class _PreferencesReadyAppModel extends AppModel {
  _PreferencesReadyAppModel(PreferencesRepository preferences, Directory root)
    : super(testPlatformServices()) {
    wireLocalAudioForTesting(prefsRepo: preferences, databaseDirectory: root);
    // wireLocalAudioForTesting 不含 initialise 中的偏好通知接线。
    preferences.addListener(notifyListeners);
  }

  @override
  bool get isInitialised => true;
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'AppModel 修改并行数会经 provider 立即放行原注册表中的排队任务',
    () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'manga_ocr_parallel_provider_',
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async => root.path,
      );
      final FushiDatabase database = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final PreferencesRepository preferences = PreferencesRepository(database);
      await preferences.loadFromDb();
      final AppModel appModel = _PreferencesReadyAppModel(preferences, root);
      await appModel.setMangaOcrParallelTasks(1);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      );
      final MangaOcrJobRegistry registry = container.read(
        mangaOcrJobRegistryProvider,
      );
      final List<StreamController<MangaOcrBackgroundEvent>> sources =
          List<StreamController<MangaOcrBackgroundEvent>>.generate(
            4,
            (int _) => StreamController<MangaOcrBackgroundEvent>(),
          );
      final List<Future<MangaOcrRunningJob?>> started =
          <Future<MangaOcrRunningJob?>>[];
      addTearDown(() async {
        // 先清排队者，再取消运行者，失败路径也不留下等待全局名额的任务。
        for (int index = sources.length - 1; index >= 0; index--) {
          await registry.cancel('book-$index');
          unawaited(sources[index].close());
        }
        await Future.wait(started);
        container.dispose();
        await database.close();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      for (int index = 0; index < sources.length; index++) {
        final String directory = p.join(root.path, 'book-$index');
        started.add(
          registry.enqueue(
            job: MangaOcrBackgroundJob(
              bookKey: 'book-$index',
              managedDirectory: directory,
              engine: MangaOcrEngineId.localOnnx,
              events: sources[index].stream,
            ),
            mangaJsonPath: p.join(directory, 'manga.json'),
          ),
        );
      }
      final MangaOcrRunningJob first = (await started.first)!;
      await Future<void>.delayed(Duration.zero);
      expect(registry.all, hasLength(1));
      expect(
        sources
            .skip(1)
            .every(
              (StreamController<MangaOcrBackgroundEvent> source) =>
                  !source.hasListener,
            ),
        isTrue,
      );

      // 刻意不手动 refreshConcurrencyLimit / notifyListeners，也不先结束第一卷。
      // 去掉生产 provider 的 ref.listen 后，第二、三卷将一直等不到运行名额。
      await appModel.setMangaOcrParallelTasks(3);
      await Future.wait(
        started.skip(1).take(2),
      ).timeout(const Duration(seconds: 2));

      expect(
        container.read(mangaOcrJobRegistryProvider),
        same(registry),
        reason: '设置变化必须唤醒既有队列，不能重建注册表丢失任务',
      );
      expect(registry.running('book-0'), same(first));
      expect(first.isEnded, isFalse);
      expect(first.isCancelled, isFalse);
      expect(registry.all, hasLength(3));
      expect(sources[3].hasListener, isFalse, reason: '即时扩容仍须遵守用户选择的三个名额');
      expect(registry.queuedDirectories('book-3'), <String>[
        p.join(root.path, 'book-3'),
      ]);
    },
    skip: Platform.isAndroid || Platform.isIOS,
  );
}
