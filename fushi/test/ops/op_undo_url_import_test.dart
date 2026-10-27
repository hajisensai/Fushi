import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';

import '../helpers/test_platform_services.dart';

/// URL 导入的撤销往返（spec §11）：导入 → 撤销 = 删掉刚建的视频条目（走 library 域的
/// 条目删除路由）；条目已被用户删掉 → superseded。全程经整张 app 操作目录，与 AI 页同口径。

class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._prefs) : super(testPlatformServices());

  final FushiDatabase _db;
  final PreferencesRepository _prefs;

  @override
  FushiDatabase get database => _db;

  @override
  PreferencesRepository get prefsRepo => _prefs;

  @override
  bool get isMigrationReadonly => false;
}

class _Ref implements WidgetRef {
  _Ref(this.model);

  final AppModel model;

  @override
  T read<T>(ProviderListenable<T> provider) => model as T;

  @override
  void invalidate(ProviderOrFamily provider) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试不该用到 ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late OpCatalog catalog;
  late OpInvoker invoker;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final OpContext context = OpContext(ref: _Ref(_TestAppModel(db, prefs)));
    catalog = buildAppOpCatalog(context, buildDomainOpRoutes(context));
    invoker = OpInvoker(catalog);
  });

  tearDown(() => db.close());

  Future<OpInvocation> run(String id, Map<String, Object?> args) {
    final FushiOp op = catalog[id]!;
    return invoker.invoke(
      id,
      args,
      caller: OpCaller.model,
      captureUndo: true,
      grantedGates: <String>{
        for (final OpParam g in op.spec.gateParams) g.name,
      },
    );
  }

  Future<OpUndoStatus> undo(OpInvocation invocation) async {
    final Map<String, Object?> payload =
        jsonDecode(jsonEncode(invocation.undo!.payload))
            as Map<String, Object?>;
    return (await catalog[invocation.op.id]!.undo!.revert(payload)).status;
  }

  test('url 域两条路由都在目录里：probe 只读、import 可撤销', () {
    expect(catalog['url.probe']!.risk, OpRisk.read);
    expect(catalog['url.import']!.risk, OpRisk.write);
    expect(catalog['url.import']!.undo, isNotNull);
  });

  test('导入 → 撤销删掉刚建的条目；之前已有的条目不受影响', () async {
    const String url = 'https://cdn.example.com/show/ep01.mp4';
    final OpInvocation first = await run('url.import', <String, Object?>{
      'url': url,
    });
    final OpInvocation second = await run('url.import', <String, Object?>{
      'url': url,
    });
    final VideoBookRepository repo = VideoBookRepository(db);
    expect(await repo.listAll(), hasLength(2));
    final String secondUid = (second.result! as Map)['bookUid'] as String;
    final String firstUid = (first.result! as Map)['bookUid'] as String;

    expect(await undo(second), OpUndoStatus.done);
    expect(await repo.getByBookUid(secondUid), isNull);
    expect(await repo.getByBookUid(firstUid), isNotNull);
  });

  test('导入后用户已经删了这条 → superseded', () async {
    final OpInvocation imported = await run('url.import', <String, Object?>{
      'url': 'https://www.bilibili.com/video/BV1xx',
    });
    final String uid = (imported.result! as Map)['bookUid'] as String;
    await VideoBookRepository(db).deleteVideoBook(uid);
    expect(await undo(imported), OpUndoStatus.superseded);
  });
}
