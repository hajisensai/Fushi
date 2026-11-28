import 'dart:async';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_specs_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/startup/database_session.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';
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

      await switch (boundary) {
        'closeDatabase' => model.closeDatabase(),
        'closeForPopup' => model.closeForPopup(),
        _ => model.closeForSrsWriteHost(),
      };

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

    await model.retryInitialise();

    expect(db.closeCalls, 1);
    expect(model.reopened, hasLength(1));
    final _CountingDatabase next = model.reopened.single;
    expect(identical(model.database, next), isTrue);
    expect(identical(model.videoSpecsService, oldSpecs), isFalse);
    expect(identical(model.dictRepo, oldRepo), isFalse);
    expect(identical(model.galgameRepo, oldGalgame), isFalse);
    expect(model.isDictionaryRepoReady, isTrue);
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
    bool connectionOpenWhileQuiescing = false;
    Future<void> quiesce() async {
      quiesced++;
      connectionOpenWhileQuiescing = db.closeCalls == 0;
    }

    model.addDatabaseCloseQuiescer(quiesce);
    await model.retryInitialise();
    expect(quiesced, 1);
    expect(connectionOpenWhileQuiescing, isTrue);

    await model.closeDatabase();
    expect(quiesced, 2, reason: '登记表是进程级的：下一代关闭时同样要等');
    model.removeDatabaseCloseQuiescer(quiesce);
  });

  test('dispose 也经这一代收尾：连接被关', () async {
    final _CountingDatabase db = _CountingDatabase(NativeDatabase.memory());
    final _GenerationAppModel model = _GenerationAppModel()
      ..wireDatabaseForTesting(db);

    model.dispose();
    await pumpEventQueue();

    expect(db.closeCalls, 1);
  });
}
