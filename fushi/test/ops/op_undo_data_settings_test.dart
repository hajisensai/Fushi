import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 路由经 [OpContext.ref] 读 provider；测试里把它转给一个真 [ProviderContainer]
/// （不需要 widget 树，也就不进 testWidgets 的 fake async）。
class _ContainerRef implements WidgetRef {
  _ContainerRef(this.container);

  final ProviderContainer container;

  @override
  T read<T>(ProviderListenable<T> provider) => container.read(provider);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试 ref 不支持 ${invocation.memberName}');
}

/// spec §11 撤销往返：数据与设置其余部分（`op_descriptions_data.dart` /
/// `op_descriptions_settings_more.dart`）声明的撤销形态，各取一条走
/// 「执行 → 撤销 → 与执行前一致」，可能被手动改过的再走一条 superseded。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel pathProvider = MethodChannel(
    'plugins.flutter.io/path_provider',
  );
  late FushiDatabase db;
  late AppModel appModel;
  late ProviderContainer container;
  late OpContext context;
  late OpCatalog catalog;
  late OpInvoker invoker;
  late Directory tempDir;

  // TtsServices 是进程内单例、绑第一份偏好仓：整个文件共用一套库与偏好。
  setUpAll(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    tempDir = Directory.systemTemp.createTempSync('fushi_op_undo_');
    // 删声音会去 support 根下清孤儿参考音频：path_provider 指到临时目录。
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      (MethodCall call) async => tempDir.path,
    );
    AppPaths.debugDataRootReader = () async => null;
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
      ..wireDatabaseForTesting(db);
    container = ProviderContainer(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => appModel),
        platformServicesProvider.overrideWithValue(appModel.platformServices),
      ],
    );
    // 路由每次先 reload Profile 视图模型；与它首次读取时的异步加载并发会让
    // ensureDefaultProfile 跑两遍撞唯一约束（app 里视图模型早已加载过）。先建好默认。
    await container.read(profileRepositoryProvider).ensureDefaultProfile();
    context = OpContext(ref: _ContainerRef(container));
    catalog = buildAppOpCatalog(context, buildDomainOpRoutes(context));
    invoker = OpInvoker(catalog);
  });

  tearDownAll(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null);
    AppPaths.debugDataRootReader = null;
    container.dispose();
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<OpUndoRecord> run(String id, Map<String, Object?> args) async {
    final FushiOp op = catalog[id]!;
    final OpInvocation invocation = await invoker.invoke(
      id,
      args,
      caller: OpCaller.model,
      // 与 AI 运行时一致：可逆操作的表态参数直接注入。
      grantedGates: <String>{
        for (final OpParam p in op.spec.gateParams) p.name,
      },
      captureUndo: true,
    );
    expect(invocation.undo, isNotNull, reason: '$id 没给撤销载荷');
    return invocation.undo!;
  }

  Future<OpUndoStatus> undo(String id, OpUndoRecord record) async =>
      (await catalog[id]!.undo!.revert(record.payload)).status;

  Future<Object?> get(String pattern) => catalog.ops
      .firstWhere(
        (FushiOp op) => op.route.method == 'GET' && op.route.pattern == pattern,
      )
      .route
      .handler(CtlCall(method: 'GET', path: pattern));

  Future<Object?> call(
    String id,
    Map<String, Object?> args, {
    Set<String> gates = const <String>{},
  }) async => (await invoker.invoke(id, args, grantedGates: gates)).result;

  group('AI 提供商（设置 › 模型 › LLM）', () {
    test('新增（顺带设默认）→ 撤销：提供商删掉、原默认设回', () async {
      final Map<Object?, Object?> seed =
          await call('settings.ai.provider.add', <String, Object?>{
                'preset': 'ollama',
                'name': 'seed',
                'makeDefault': true,
              })
              as Map;
      final String seedId = '${(seed['provider'] as Map)['id']}';
      final Object? before = await get('/api/admin/ai/providers');

      final OpUndoRecord record = await run(
        'settings.ai.provider.add',
        <String, Object?>{
          'preset': 'ollama',
          'name': 'second',
          'makeDefault': true,
        },
      );
      final Map<Object?, Object?> mid =
          await get('/api/admin/ai/providers') as Map;
      expect((mid['providers'] as List).length, 2);
      expect(mid['defaultProviderId'], isNot(seedId));

      expect(await undo('settings.ai.provider.add', record), OpUndoStatus.done);
      expect(await get('/api/admin/ai/providers'), before);
    });

    test('改字段 → 撤销还原；之后被手动改过 → superseded 且不覆盖', () async {
      final Map<Object?, Object?> listed =
          await get('/api/admin/ai/providers') as Map;
      final String id = '${((listed['providers'] as List).first as Map)['id']}';
      // 先给 model 一个非空原值（原值为空的情形另一条用例钉住）。
      await call('settings.ai.provider.update', <String, Object?>{
        'id': id,
        'model': 'base',
      });
      final Object? before = await get('/api/admin/ai/providers');

      final OpUndoRecord record = await run(
        'settings.ai.provider.update',
        <String, Object?>{
          'id': id,
          'model': 'qwen3:8b',
          'rpm': 30,
          'enabled': false,
        },
      );
      expect(
        await undo('settings.ai.provider.update', record),
        OpUndoStatus.done,
      );
      expect(await get('/api/admin/ai/providers'), before);

      final OpUndoRecord again = await run(
        'settings.ai.provider.update',
        <String, Object?>{'id': id, 'model': 'by-ai'},
      );
      await call('settings.ai.provider.update', <String, Object?>{
        'id': id,
        'model': 'by-user',
      });
      expect(
        await undo('settings.ai.provider.update', again),
        OpUndoStatus.superseded,
      );
      final Map<Object?, Object?> after =
          await get('/api/admin/ai/providers') as Map;
      expect(((after['providers'] as List).first as Map)['model'], 'by-user');
    });

    test('模型改不了已有提供商的 baseUrl（改 URL 会把已存 key 发到新地址）', () async {
      final Map<Object?, Object?> listed =
          await get('/api/admin/ai/providers') as Map;
      final Map<Object?, Object?> first =
          (listed['providers'] as List).first as Map;
      final String id = '${first['id']}';
      expect(
        catalog['settings.ai.provider.update']!.spec.params.map(
          (OpParam p) => p.name,
        ),
        isNot(contains('baseUrl')),
      );
      await expectLater(
        invoker.invoke('settings.ai.provider.update', <String, Object?>{
          'id': id,
          'baseUrl': 'https://attacker.invalid/v1',
        }, caller: OpCaller.model),
        throwsA(isA<CtlFailure>()),
      );
      final Map<Object?, Object?> after =
          ((await get('/api/admin/ai/providers') as Map)['providers'] as List)
                  .firstWhere((Object? r) => (r as Map)['id'] == id)
              as Map;
      expect(after['baseUrl'], first['baseUrl']);
    });

    test('原值为空的字段：撤销把它清回空（路由认显式空串），其余字段一并还原', () async {
      final Map<Object?, Object?> added =
          await call('settings.ai.provider.add', <String, Object?>{
                'preset': 'ollama',
                'name': 'empty-model',
              })
              as Map;
      final String id = '${(added['provider'] as Map)['id']}';
      final OpUndoRecord record = await run(
        'settings.ai.provider.update',
        <String, Object?>{'id': id, 'model': 'set-by-ai', 'rpm': 12},
      );
      expect(
        await undo('settings.ai.provider.update', record),
        OpUndoStatus.done,
      );
      final Map<Object?, Object?> row =
          ((await get('/api/admin/ai/providers') as Map)['providers'] as List)
                  .firstWhere((Object? r) => (r as Map)['id'] == id)
              as Map;
      expect(row['rpm'], 0, reason: '其余字段已还原');
      expect(row['model'] ?? '', '', reason: '原来为空的模型清回空');
      await call(
        'settings.ai.provider.delete',
        <String, Object?>{'id': id},
        gates: <String>{'confirm'},
      );
    });

    test('功能指派 / 默认提供商 → 撤销还原', () async {
      final Object? before = await get('/api/admin/ai/features');
      final OpUndoRecord assign = await run(
        'settings.ai.feature.assign',
        <String, Object?>{'feature': 'dictStyle', 'provider': 'off'},
      );
      expect(
        await undo('settings.ai.feature.assign', assign),
        OpUndoStatus.done,
      );
      expect(await get('/api/admin/ai/features'), before);

      final OpUndoRecord def = await run(
        'settings.ai.default.set',
        <String, Object?>{'provider': 'none'},
      );
      expect(
        ((await get('/api/admin/ai/features')) as Map)['defaultProviderId'],
        isNull,
      );
      expect(await undo('settings.ai.default.set', def), OpUndoStatus.done);
      expect(await get('/api/admin/ai/features'), before);
    });
  });

  group('模块顺序 / 朗读', () {
    test('模块排序 → 撤销还原', () async {
      final Map<Object?, Object?> before =
          await get('/api/admin/modules') as Map;
      final List<Object?> order = before['order'] as List;
      final OpUndoRecord record = await run('modules.order', <String, Object?>{
        'order': <Object?>[order.last, order[1]],
      });
      expect(((await get('/api/admin/modules')) as Map)['order'], isNot(order));
      expect(await undo('modules.order', record), OpUndoStatus.done);
      expect(((await get('/api/admin/modules')) as Map)['order'], order);
    });

    test('朗读语速 → 撤销还原；手动改过 → superseded', () async {
      final Object? before = ((await get('/api/admin/voices')) as Map)['speed'];
      final OpUndoRecord record = await run(
        'settings.voice.speed',
        <String, Object?>{'speed': 1.5},
      );
      expect(await undo('settings.voice.speed', record), OpUndoStatus.done);
      expect(((await get('/api/admin/voices')) as Map)['speed'], before);

      final OpUndoRecord again = await run(
        'settings.voice.speed',
        <String, Object?>{'speed': 1.5},
      );
      await call('settings.voice.speed', <String, Object?>{'speed': 0.75});
      expect(
        await undo('settings.voice.speed', again),
        OpUndoStatus.superseded,
      );
      expect(((await get('/api/admin/voices')) as Map)['speed'], 0.75);
    });
  });

  group('朗读声音', () {
    test('新增（设为默认）→ 撤销；改名 → 撤销 / 手动改过 superseded', () async {
      final Map<Object?, Object?> engines =
          await get('/api/admin/voices/engines') as Map;
      final String engine =
          '${((engines['engines'] as List).first as Map)['id']}';
      final Object? before = await get('/api/admin/voices');

      final OpUndoRecord added = await run(
        'settings.voice.add',
        <String, Object?>{'engine': engine, 'name': 'ai-voice', 'use': true},
      );
      final String voiceId =
          '${((await get('/api/admin/voices')) as Map)['activeId']}';
      expect(await undo('settings.voice.add', added), OpUndoStatus.done);
      expect(await get('/api/admin/voices'), before);

      // 改名的往返要有一条现成的声音：先手动建一条（不经 AI）。
      final Map<Object?, Object?> seed =
          await call('settings.voice.add', <String, Object?>{
                'engine': engine,
                'name': 'seed-voice',
              })
              as Map;
      final String seedId = '${(seed['voice'] as Map)['id']}';
      expect(seedId, isNot(voiceId));
      final Object? beforeRename = await get('/api/admin/voices');
      final OpUndoRecord renamed = await run(
        'settings.voice.update',
        <String, Object?>{'id': seedId, 'name': 'renamed-by-ai'},
      );
      expect(await undo('settings.voice.update', renamed), OpUndoStatus.done);
      expect(await get('/api/admin/voices'), beforeRename);

      final OpUndoRecord again = await run(
        'settings.voice.update',
        <String, Object?>{'id': seedId, 'name': 'renamed-by-ai'},
      );
      await call('settings.voice.update', <String, Object?>{
        'id': seedId,
        'name': 'renamed-by-user',
      });
      expect(
        await undo('settings.voice.update', again),
        OpUndoStatus.superseded,
      );
      final Map<Object?, Object?> voices =
          await get('/api/admin/voices') as Map;
      expect(
        ((voices['voices'] as List).firstWhere(
              (Object? v) => (v as Map)['id'] == seedId,
            )
            as Map)['name'],
        'renamed-by-user',
      );
    });
  });

  group('快捷键', () {
    test('steal 抢绑定 → 撤销：两个动作都回到原绑定', () async {
      final Map<Object?, Object?> listed =
          await get('/api/admin/shortcuts') as Map;
      final List<Map<Object?, Object?>> rows = <Map<Object?, Object?>>[
        for (final Object? r in listed['shortcuts'] as List) r as Map,
      ];
      final Map<Object?, Object?> owner = rows.first;
      final Map<Object?, Object?> thief = rows.firstWhere(
        (Map<Object?, Object?> r) =>
            r['scope'] == owner['scope'] && r['action'] != owner['action'],
      );
      // 测试夹具的注册表是空的：先给 owner 一个绑定，再让 thief 抢走。
      await call('settings.shortcut.set', <String, Object?>{
        'action': owner['action'],
        'bindings': <Object?>['Ctrl+Alt+F12'],
        'conflict': 'keep',
      });
      final Map<Object?, Object?> before =
          await get('/api/admin/shortcuts') as Map;
      final Object? token =
          ((before['shortcuts'] as List).firstWhere(
                (Object? r) => (r as Map)['action'] == owner['action'],
              )
              as Map)['tokens'];

      final OpUndoRecord record =
          await run('settings.shortcut.set', <String, Object?>{
            'action': thief['action'],
            'bindings': token,
            'mode': 'add',
            'conflict': 'steal',
          });
      expect(await get('/api/admin/shortcuts'), isNot(before));
      expect(await undo('settings.shortcut.set', record), OpUndoStatus.done);
      expect(await get('/api/admin/shortcuts'), before);
    });

    test('全部恢复默认 → 撤销还原；之后手动改过 → superseded', () async {
      final Object? before = await get('/api/admin/shortcuts');
      final OpUndoRecord record = await run(
        'settings.shortcut.reset',
        <String, Object?>{'all': true},
      );
      expect(await get('/api/admin/shortcuts'), isNot(before));
      expect(await undo('settings.shortcut.reset', record), OpUndoStatus.done);
      expect(await get('/api/admin/shortcuts'), before);

      final Map<Object?, Object?> listed =
          await get('/api/admin/shortcuts') as Map;
      final Object? action =
          ((listed['shortcuts'] as List).first as Map)['action'];
      final OpUndoRecord again = await run(
        'settings.shortcut.set',
        <String, Object?>{
          'action': action,
          'bindings': <Object?>['Ctrl+Alt+F11'],
          'conflict': 'keep',
        },
      );
      await call('settings.shortcut.set', <String, Object?>{
        'action': action,
        'bindings': <Object?>['Ctrl+Alt+F10'],
        'conflict': 'keep',
      });
      final Object? manual = await get('/api/admin/shortcuts');
      expect(
        await undo('settings.shortcut.set', again),
        OpUndoStatus.superseded,
      );
      expect(await get('/api/admin/shortcuts'), manual);
    });
  });

  group('Profile', () {
    // 新建会 switchProfile → AppModel.refreshPrefCache 要完整初始化的 mediaSources，
    // 夹具给不了；新建与复制共用同一个撤销形态（_createdProfileUndo），这里走复制。
    test('复制 → 撤销：删掉复制出来的那个，原 Profile 不动', () async {
      final Map<Object?, Object?> listed =
          await get('/api/admin/profiles') as Map;
      final Object? id = ((listed['profiles'] as List).first as Map)['id'];
      final Object? before = await get('/api/admin/profiles');
      final OpUndoRecord record = await run(
        'settings.profile.copy',
        <String, Object?>{'id': '$id', 'name': 'ai-copy'},
      );
      expect(
        ((await get('/api/admin/profiles')) as Map)['profiles'] as List,
        hasLength((listed['profiles'] as List).length + 1),
      );
      expect(await undo('settings.profile.copy', record), OpUndoStatus.done);
      expect(await get('/api/admin/profiles'), before);
      // 再撤一次：复制品已不在 → superseded，不会误删别的。
      expect(
        await undo('settings.profile.copy', record),
        OpUndoStatus.superseded,
      );
    });

    test('改名 → 撤销；手动改过 → superseded', () async {
      final Map<Object?, Object?> listed =
          await get('/api/admin/profiles') as Map;
      final Object? id = ((listed['profiles'] as List).first as Map)['id'];
      final Object? before = await get('/api/admin/profiles');

      final OpUndoRecord record = await run(
        'settings.profile.rename',
        <String, Object?>{'id': '$id', 'name': 'renamed-by-ai'},
      );
      expect(await undo('settings.profile.rename', record), OpUndoStatus.done);
      expect(await get('/api/admin/profiles'), before);

      final OpUndoRecord again = await run(
        'settings.profile.rename',
        <String, Object?>{'id': '$id', 'name': 'renamed-by-ai'},
      );
      await call('settings.profile.rename', <String, Object?>{
        'id': '$id',
        'name': 'renamed-by-user',
      });
      expect(
        await undo('settings.profile.rename', again),
        OpUndoStatus.superseded,
      );
      final Map<Object?, Object?> after =
          await get('/api/admin/profiles') as Map;
      expect(
        ((after['profiles'] as List).first as Map)['name'],
        'renamed-by-user',
      );
    });
  });
}
