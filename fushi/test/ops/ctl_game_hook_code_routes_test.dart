import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/mining/galgame_hook_code_profile.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_game_hook_code_routes.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_game_hook_codes.dart';

import '../helpers/test_platform_services.dart';

Matcher _status(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());

  @override
  bool moduleEnabled(ModuleId module) => true;
}

class _Ref implements WidgetRef {
  _Ref(this.model);

  final AppModel model;

  @override
  T read<T>(ProviderListenable<T> provider) => model as T;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试不该用到 ${invocation.memberName}');
}

LunaHookCodeProfile _profile(String hook, {String label = ''}) =>
    LunaHookCodeProfile(
      executableSha256: 'a' * 64,
      moduleName: '',
      moduleSha256: '',
      codepage: 932,
      hookCode: hook,
      label: label,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late LunaHookCodeProfileStore store;
  late bool windows;
  late OpContext context;
  late List<CtlRoute> routes;
  late OpCatalog catalog;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hook_code_ctl_');
    store = LunaHookCodeProfileStore(File(p.join(tmp.path, 'profiles.tsv')));
    await store.save(<LunaHookCodeProfile>[_profile('HS-8@0:game.exe')]);
    windows = true;
    context = OpContext(ref: _Ref(_TestAppModel()));
    debugOverrideGameHookCodeCtlDeps(
      context,
      GameHookCodeCtlDeps(
        store: () async => store,
        available: () => windows,
        gamesEnabled: () => true,
      ),
    );
    routes = buildGameHookCodeCtlRoutes(context);
    catalog = OpCatalog.build(
      routes,
      describeGameHookCodeOps(OpDescribeKit(context, routes)),
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Object?> call(
    String method,
    String pattern, {
    Map<String, Object?> body = const <String, Object?>{},
  }) {
    final CtlRoute route = routes.singleWhere(
      (CtlRoute r) => r.method == method && r.pattern == pattern,
    );
    return route.handler(
      CtlCall(method: method, path: pattern, params: const {}, body: body),
    );
  }

  Map<String, Object?> asMap(Object? v) => (v! as Map).cast<String, Object?>();

  test('列出 / 导出（已存在要 overwrite）', () async {
    final Map<String, Object?> listed = asMap(
      await call('GET', kGameHookCodeCtlRoot),
    );
    expect(listed['profiles'], hasLength(1));
    final String out = p.join(tmp.path, 'out.tsv');
    await call(
      'POST',
      '$kGameHookCodeCtlRoot/export',
      body: <String, Object?>{'path': out},
    );
    expect(
      parseLunaHookCodeProfiles(File(out).readAsStringSync()),
      hasLength(1),
    );
    expect(
      () => call(
        'POST',
        '$kGameHookCodeCtlRoot/export',
        body: <String, Object?>{'path': out},
      ),
      _status(409),
    );
    await call(
      'POST',
      '$kGameHookCodeCtlRoot/export',
      body: <String, Object?>{'path': out, 'overwrite': true},
    );
    expect(
      () => call(
        'POST',
        '$kGameHookCodeCtlRoot/export',
        body: <String, Object?>{'path': 'out.tsv'},
      ),
      _status(400),
    );
  });

  test('导入坏文件 422、配置不变；非 Windows 501', () async {
    final String bad = p.join(tmp.path, 'bad.tsv');
    File(bad).writeAsStringSync('x\ty\n');
    final String before = store.file.readAsStringSync();
    expect(
      () => call(
        'POST',
        '$kGameHookCodeCtlRoot/import',
        body: <String, Object?>{'path': bad},
      ),
      _status(422),
    );
    expect(store.file.readAsStringSync(), before);
    windows = false;
    expect(() => call('GET', kGameHookCodeCtlRoot), _status(501));
  });

  test('导入 → 撤销写回原配置；之后被改过 → superseded', () async {
    final String incoming = p.join(tmp.path, 'in.tsv');
    File(incoming).writeAsStringSync(
      encodeLunaHookCodeProfiles(<LunaHookCodeProfile>[
        _profile('HS-4@0:a.exe', label: 'A'),
        _profile('HS-4@0:b.exe', label: 'B'),
      ]),
    );
    // 导入前是用户手写过的表（多一行注释）：撤销要逐字写回，不能解析后重新编码丢掉注释。
    store.file.writeAsStringSync(
      '${store.file.readAsStringSync()}# 手写备注：这台机器的补丁版\n',
    );
    final String original = store.file.readAsStringSync();
    Future<OpInvocation> run() => OpInvoker(catalog).invoke(
      'game.hook-codes.import',
      <String, Object?>{'path': incoming},
      caller: OpCaller.model,
      captureUndo: true,
    );
    Future<OpUndoStatus> undo(OpInvocation invocation) async =>
        (await catalog['game.hook-codes.import']!.undo!.revert(
          jsonDecode(jsonEncode(invocation.undo!.payload))
              as Map<String, Object?>,
        )).status;

    final OpInvocation first = await run();
    expect(await store.load(), hasLength(2));
    expect(await undo(first), OpUndoStatus.done);
    expect(store.file.readAsStringSync(), original);

    final OpInvocation second = await run();
    await store.upsert(_profile('HS-4@0:c.exe'));
    expect(await undo(second), OpUndoStatus.superseded);
    expect(await store.load(), hasLength(3));
  });
}
