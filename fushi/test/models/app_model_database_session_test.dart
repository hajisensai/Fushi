import 'dart:async';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_specs_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/startup/database_session.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

class _CountingDatabase extends FushiDatabase {
  _CountingDatabase(QueryExecutor executor) : super.forTesting(executor);

  int closeCalls = 0;

  @override
  Future<void> close() {
    closeCalls++;
    return super.close();
  }
}

/// 下一次「平台初始化」只接上一份新库（真实的关库 / 重试 / dispose 边界是生产代码）。
class _GenerationAppModel extends AppModel {
  _GenerationAppModel() : super(testPlatformServices());

  final List<_CountingDatabase> reopened = <_CountingDatabase>[];

  @override
  Future<void> initialise() async {
    final _CountingDatabase db = _CountingDatabase(NativeDatabase.memory());
    reopened.add(db);
    wireDatabaseForTesting(db, dictionaryRepository: DictionaryRepository(db));
  }
}

/// 每条真的关连接的路径（生产代码）。
final Map<String, Future<void> Function(AppModel model)> _closeBoundaries =
    <String, Future<void> Function(AppModel model)>{
      'closeDatabase': (AppModel model) => model.closeDatabase(),
      'closeForPopup': (AppModel model) => model.closeForPopup(),
      'closeForSrsWriteHost': (AppModel model) => model.closeForSrsWriteHost(),
      'retryInitialise': (AppModel model) => model.retryInitialise(),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final String boundary in <String>[
    'closeDatabase',
    'closeForPopup',
    'closeForSrsWriteHost',
  ]) {
    test('$boundary 关掉这一代：连接关一次，之后经模型取库抛类型化异常', () async {
      final _CountingDatabase db = _CountingDatabase(NativeDatabase.memory());
      final _GenerationAppModel model = _GenerationAppModel()
        ..wireDatabaseForTesting(
          db,
          dictionaryRepository: DictionaryRepository(db),
        );
      int closeSignals = 0;
      model.databaseCloseNotifier.addListener(() => closeSignals++);
      final VideoSpecsService specs = model.videoSpecsService;
      expect(model.isDatabaseReady, isTrue);
      expect(model.isDictionaryRepoReady, isTrue);

      await _closeBoundaries[boundary]!(model);

      expect(db.closeCalls, 1);
      expect(closeSignals, 1);
      expect(model.isDatabaseReady, isFalse);
      expect(model.isDictionaryRepoReady, isFalse);
      expect(
        ExitFlushRegistry.instance.callbackCount,
        0,
        reason: '词典仓库的退出 flush 随这一代注销',
      );
      expect(
        () => model.database,
        throwsA(isA<DatabaseSessionClosedException>()),
      );
      expect(
        () => model.videoSpecsService,
        throwsA(isA<DatabaseSessionClosedException>()),
        reason: '旧一代的服务已随关库丢弃，不能再绑到已关闭的连接上',
      );
      expect(specs, isNotNull);
    });
  }

  for (final MapEntry<String, Future<void> Function(AppModel)> boundary
      in _closeBoundaries.entries) {
    test('${boundary.key}：关库前等登记的写手，等的时候「已初始化」与「库可用」都已经是 false、'
        '连接还开着', () async {
      final _CountingDatabase db = _CountingDatabase(NativeDatabase.memory());
      final _GenerationAppModel model = _GenerationAppModel()
        ..wireDatabaseForTesting(db)
        ..markInitialisedForTesting();
      final List<String> seen = <String>[];
      Future<void> quiesce() async {
        // 登记方（SRS 同步的 canRun）据这两个门闩不开新一轮。
        seen.add(
          'initialised=${model.isInitialised} '
          'ready=${model.isDatabaseReady} '
          'connectionClosed=${db.closeCalls > 0}',
        );
      }

      model.addDatabaseCloseQuiescer(quiesce);
      await boundary.value(model);
      model.removeDatabaseCloseQuiescer(quiesce);

      expect(seen, <String>[
        'initialised=false ready=false connectionClosed=false',
      ]);
      expect(db.closeCalls, 1);
    });

    test('${boundary.key}：合集观察者随这一代撤掉（BUG-1569②）', () async {
      final _CountingDatabase db = _CountingDatabase(NativeDatabase.memory());
      final _GenerationAppModel model = _GenerationAppModel()
        ..wireDatabaseForTesting(db);
      installCollectionsSyncWatcher(db: db);
      addTearDown(uninstallCollectionsSyncWatcher);
      expect(collectionsSyncWatcherInstalledForTest, isTrue);

      await boundary.value(model);

      expect(collectionsSyncWatcherInstalledForTest, isFalse);
    });
  }

  test('关闭途中「库可用」门闩已经关上，懒建的绑库服务不会再被建出来', () async {
    final _CountingDatabase db = _CountingDatabase(NativeDatabase.memory());
    final _GenerationAppModel model = _GenerationAppModel()
      ..wireDatabaseForTesting(db);
    final Completer<void> gate = Completer<void>();
    Future<void> quiesce() => gate.future;
    model.addDatabaseCloseQuiescer(quiesce);

    final Future<void> closing = model.closeDatabase();
    await pumpEventQueue();

    expect(db.closeCalls, 0, reason: '还卡在等写手，连接没关');
    expect(model.isDatabaseReady, isFalse);
    expect(
      () => model.videoSpecsService,
      throwsA(isA<DatabaseSessionClosedException>()),
    );
    expect(
      () => model.galgameRepo,
      throwsA(isA<DatabaseSessionClosedException>()),
    );
    expect(
      model.databaseSessionForTesting!.debugOwnedLabels.withSession,
      isEmpty,
      reason: '被拒的懒建没有在正在关的这一代上留下任何东西',
    );

    gate.complete();
    await closing;
    model.removeDatabaseCloseQuiescer(quiesce);
    expect(db.closeCalls, 1);
  });

  test('懒建的绑库服务登记在当前这一代上，关库后槽位清空', () async {
    final _CountingDatabase db = _CountingDatabase(NativeDatabase.memory());
    final _GenerationAppModel model = _GenerationAppModel()
      ..wireDatabaseForTesting(db);
    model
      ..videoSpecsService
      ..galgameRepo
      ..onlineMangaReshelf
      ..mangaDownloadService;

    expect(
      model.databaseSessionForTesting!.debugOwnedLabels.withSession,
      containsAll(<String>[
        'videoSpecsService',
        'galgameRepo',
        'onlineMangaReshelf',
        'mangaDownloadService',
      ]),
    );
    expect(
      model.databaseSessionForTesting!.debugOwnedLabels.withConnection,
      <String>['databaseCloseQuiescers'],
    );

    await model.closeDatabase();

    final ({List<String> withConnection, List<String> withSession}) left =
        model.databaseSessionForTesting!.debugOwnedLabels;
    expect(left.withSession, isEmpty);
    expect(left.withConnection, isEmpty);
    expect(model.animeDownloadService, isNull);
  });

  test('重试开库后拿到的是新一代的资源，旧一代的连接只关一次', () async {
    final _CountingDatabase db = _CountingDatabase(NativeDatabase.memory());
    final _GenerationAppModel model = _GenerationAppModel()
      ..wireDatabaseForTesting(
        db,
        dictionaryRepository: DictionaryRepository(db),
      );
    final VideoSpecsService oldSpecs = model.videoSpecsService;
    final DictionaryRepository oldRepo = model.dictRepo;
    final Object oldGalgame = model.galgameRepo;
    final Object oldReshelf = model.onlineMangaReshelf;

    await model.retryInitialise();

    expect(db.closeCalls, 1);
    expect(model.reopened, hasLength(1));
    final _CountingDatabase next = model.reopened.single;
    expect(identical(model.database, next), isTrue);
    expect(identical(model.videoSpecsService, oldSpecs), isFalse);
    expect(identical(model.dictRepo, oldRepo), isFalse);
    expect(identical(model.galgameRepo, oldGalgame), isFalse);
    expect(identical(model.onlineMangaReshelf, oldReshelf), isFalse);
    expect(model.isDictionaryRepoReady, isTrue);
    expect(model.isDatabaseReady, isTrue);
    expect(next.closeCalls, 0);

    await model.closeDatabase();
    expect(next.closeCalls, 1);
    expect(db.closeCalls, 1);
  });

  test('关库前等登记的写手收尾，一代一次', () async {
    final _CountingDatabase db = _CountingDatabase(NativeDatabase.memory());
    final _GenerationAppModel model = _GenerationAppModel()
      ..wireDatabaseForTesting(db);
    int quiesced = 0;
    Future<void> quiesce() async => quiesced++;

    model.addDatabaseCloseQuiescer(quiesce);
    await model.retryInitialise();
    expect(quiesced, 1);

    await model.closeDatabase();
    expect(quiesced, 2, reason: '登记表是进程级的：下一代关闭时同样要等');
    model.removeDatabaseCloseQuiescer(quiesce);
  });

  test('后台写手的排空上界只由 closeDatabase 的调用方给（BUG-1505）', () async {
    final _GenerationAppModel unbounded = _GenerationAppModel()
      ..wireDatabaseForTesting(_CountingDatabase(NativeDatabase.memory()));
    await unbounded.closeDatabase();
    expect(
      unbounded.databaseSessionForTesting!.drainTimeout,
      isNull,
      reason: '迁移导入 / 备份导入 / 数据根迁移不给上界：等到真收尾',
    );

    final _GenerationAppModel exiting = _GenerationAppModel()
      ..wireDatabaseForTesting(_CountingDatabase(NativeDatabase.memory()));
    await exiting.closeDatabase(
      pipelineDrainTimeout: const Duration(seconds: 2),
    );
    expect(
      exiting.databaseSessionForTesting!.drainTimeout,
      const Duration(seconds: 2),
    );
  });

  test('dispose 收尾这一代的模型侧资源；连接、它名下的后台工作、关库信号都不动', () async {
    final _CountingDatabase db = _CountingDatabase(NativeDatabase.memory());
    final _GenerationAppModel model = _GenerationAppModel()
      ..wireDatabaseForTesting(
        db,
        dictionaryRepository: DictionaryRepository(db),
      );
    int quiesced = 0;
    Future<void> quiesce() async => quiesced++;
    model.addDatabaseCloseQuiescer(quiesce);
    int closeSignals = 0;
    model.databaseCloseNotifier.addListener(() => closeSignals++);
    model.videoSpecsService;
    installCollectionsSyncWatcher(db: db);
    addTearDown(uninstallCollectionsSyncWatcher);

    model.dispose();
    await pumpEventQueue();

    expect(model.isDictionaryRepoReady, isFalse);
    expect(ExitFlushRegistry.instance.callbackCount, 0);
    expect(collectionsSyncWatcherInstalledForTest, isFalse);
    expect(
      model.databaseSessionForTesting!.debugOwnedLabels.withSession,
      isEmpty,
    );
    expect(model.isDatabaseReady, isFalse);
    expect(quiesced, 0, reason: '关库前要等的写手只属于「关连接」，销毁模型不关连接');
    expect(closeSignals, 0);
    expect(db.closeCalls, 0);
    expect(
      await db.runBackgroundWork<int>(
        'after-dispose',
        (DatabaseWorkToken _) async => 1,
      ),
      1,
      reason: '销毁模型不让这个连接的后台工作进入关闭态',
    );
    await db.close();
  });
}
