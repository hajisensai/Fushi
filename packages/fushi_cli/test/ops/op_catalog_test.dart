import 'package:fushi_cli/fushi_cli.dart';
import 'package:test/test.dart';

void main() {
  late List<CtlCall> calls;
  late Map<String, Object?> store;

  List<CtlRoute> routes() => <CtlRoute>[
    CtlRoute.get('/api/admin/things/:key', (CtlCall call) async {
      calls.add(call);
      return <String, Object?>{
        'key': call.params['key'],
        'value': store[call.params['key']],
      };
    }),
    CtlRoute.put('/api/admin/things/:key', (CtlCall call) async {
      calls.add(call);
      store[call.params['key']!] = call.body['value'];
      return <String, Object?>{'ok': true};
    }),
    CtlRoute.post('/api/admin/things/:key/delete', (CtlCall call) async {
      calls.add(call);
      if (call.optBool('confirm') != true) {
        throw const CtlFailure.badRequest('需 confirm');
      }
      store.remove(call.params['key']);
      return null;
    }),
    CtlRoute.get('/api/admin/undescribed', (CtlCall call) async => null),
  ];

  final List<OpDescription> descriptions = <OpDescription>[
    OpDescription(
      id: 'things.get',
      method: 'GET',
      pattern: '/api/admin/things/:key',
      summary: 'Read one thing by key.',
      params: const <OpParam>[
        OpParam.string(
          'key',
          description: 'Thing key.',
          required: true,
          inPath: true,
        ),
      ],
    ),
    OpDescription(
      id: 'things.set',
      method: 'PUT',
      pattern: '/api/admin/things/:key',
      summary: 'Set the value of a thing.',
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.string(
          'key',
          description: 'Thing key.',
          required: true,
          inPath: true,
        ),
        OpParam.integer('value', description: 'New value.', required: true),
      ],
      undo: OpUndo(
        capture: (CtlCall call) async => <String, Object?>{
          'key': call.params['key'],
          'old': store[call.params['key']],
        },
        record: (CtlCall call, Map<String, Object?> before, Object? result) =>
            OpUndoRecord(
              payload: <String, Object?>{...before, 'new': call.body['value']},
              before: '${before['old']}',
              after: '${call.body['value']}',
            ),
        revert: (Map<String, Object?> payload) async {
          if (store[payload['key']] != payload['new']) {
            return const OpUndoOutcome.superseded();
          }
          store[payload['key']! as String] = payload['old'];
          return const OpUndoOutcome.done();
        },
      ),
    ),
    OpDescription(
      id: 'things.delete',
      method: 'POST',
      pattern: '/api/admin/things/:key/delete',
      summary: 'Delete a thing permanently.',
      risk: OpRisk.irreversible,
      params: const <OpParam>[
        OpParam.string(
          'key',
          description: 'Thing key.',
          required: true,
          inPath: true,
        ),
        OpParam.userGate('confirm', description: 'User confirmed.'),
      ],
    ),
  ];

  setUp(() {
    calls = <CtlCall>[];
    store = <String, Object?>{'a': 1};
  });

  test('描述按 METHOD pattern 挂到路由上；对不上就抛', () {
    final OpCatalog catalog = OpCatalog.build(routes(), descriptions);
    expect(catalog.ops.map((FushiOp op) => op.id), <String>[
      'things.get',
      'things.set',
      'things.delete',
    ]);
    expect(
      () => OpCatalog.build(routes(), <OpDescription>[
        const OpDescription(
          id: 'x',
          method: 'GET',
          pattern: '/api/admin/nope',
          summary: 'x',
        ),
      ]),
      throwsStateError,
    );
  });

  test('给模型的 schema 不含表态参数；needsConfirmation 只看风险与 confirm', () {
    final OpCatalog catalog = OpCatalog.build(routes(), descriptions);
    final FushiOpSpec del = catalog['things.delete']!.spec;
    expect((del.modelSchema()['properties']! as Map).keys, <String>['key']);
    expect(del.needsConfirmation, isTrue);
    expect(catalog['things.set']!.spec.needsConfirmation, isFalse);
    expect(catalog['things.set']!.spec.undoable, isTrue);
    final FushiOpSpec roundTrip = FushiOpSpec.fromJson(del.toJson());
    expect(roundTrip.toJson(), del.toJson());
  });

  test('模型调用在 CtlCall 上带 fromModel（参数填不出来），用户调用不带', () async {
    final OpInvoker invoker = OpInvoker(
      OpCatalog.build(routes(), descriptions),
    );
    await invoker.invoke('things.set', <String, Object?>{
      'key': 'a',
      'value': 1,
    }, caller: OpCaller.model);
    await invoker.invoke('things.set', <String, Object?>{
      'key': 'a',
      'value': 2,
    });
    expect(calls.map((CtlCall c) => c.fromModel), <bool>[true, false]);
    // 模型想自己塞一个同名参数：未知参数 400，进不了 body。
    expect(
      () => invoker.invoke('things.set', <String, Object?>{
        'key': 'a',
        'value': 3,
        'fromModel': false,
      }, caller: OpCaller.model),
      throwsA(isA<CtlFailure>()),
    );
  });

  test('invoker 代入路径参数、类型转换并抓撤销快照', () async {
    final OpInvoker invoker = OpInvoker(
      OpCatalog.build(routes(), descriptions),
    );
    final OpInvocation result = await invoker.invoke(
      'things.set',
      <String, Object?>{'key': 'a b', 'value': '7'},
      caller: OpCaller.model,
      captureUndo: true,
    );
    expect(calls.single.path, '/api/admin/things/a%20b');
    expect(calls.single.params, <String, String>{'key': 'a b'});
    expect(store['a b'], 7);
    expect(result.undo!.payload, <String, Object?>{
      'key': 'a b',
      'old': null,
      'new': 7,
    });
    final OpUndoOutcome undo = await invoker.catalog['things.set']!.undo!
        .revert(result.undo!.payload);
    expect(undo.status, OpUndoStatus.done);
    expect(store.containsKey('a b'), isTrue);
    expect(store['a b'], isNull);
  });

  test('执行后被手动改过：撤销报 superseded，不覆盖', () async {
    final OpInvoker invoker = OpInvoker(
      OpCatalog.build(routes(), descriptions),
    );
    final OpInvocation result = await invoker.invoke(
      'things.set',
      <String, Object?>{'key': 'a', 'value': 2},
      captureUndo: true,
    );
    store['a'] = 99;
    final OpUndoOutcome undo = await invoker.catalog['things.set']!.undo!
        .revert(result.undo!.payload);
    expect(undo.status, OpUndoStatus.superseded);
    expect(store['a'], 99);
  });

  test('模型填不出表态参数；只有运行时注入才生效', () async {
    final OpInvoker invoker = OpInvoker(
      OpCatalog.build(routes(), descriptions),
    );
    await expectLater(
      invoker.invoke('things.delete', <String, Object?>{
        'key': 'a',
        'confirm': true,
      }, caller: OpCaller.model),
      throwsA(
        isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
      ),
    );
    expect(store, contains('a'));
    await invoker.invoke(
      'things.delete',
      <String, Object?>{'key': 'a'},
      caller: OpCaller.model,
      grantedGates: <String>{'confirm'},
    );
    expect(store, isNot(contains('a')));
  });

  test('未知参数 / 缺必填 / 类型错 / 不可用 / 未就绪 都回 CtlFailure', () async {
    bool available = true;
    bool ready = true;
    final OpCatalog catalog = OpCatalog.build(routes(), <OpDescription>[
      descriptions[0],
      OpDescription(
        id: 'things.set',
        method: 'PUT',
        pattern: '/api/admin/things/:key',
        summary: 'Set.',
        risk: OpRisk.write,
        params: descriptions[1].params,
        undo: descriptions[1].undo,
        availability: () => available
            ? const OpAvailability.available()
            : const OpAvailability.unavailable('module_disabled'),
      ),
    ]);
    final OpInvoker invoker = OpInvoker(catalog, ready: () => ready);
    Future<int> status(String id, Map<String, Object?> args) async {
      try {
        await invoker.invoke(id, args, caller: OpCaller.model);
        return 200;
      } on CtlFailure catch (f) {
        return f.status;
      }
    }

    expect(await status('nope', const <String, Object?>{}), 404);
    expect(
      await status('things.get', <String, Object?>{'key': 'a', 'x': 1}),
      400,
    );
    expect(await status('things.get', const <String, Object?>{}), 400);
    expect(
      await status('things.set', <String, Object?>{'key': 'a', 'value': 'abc'}),
      400,
    );
    available = false;
    expect(
      await status('things.set', <String, Object?>{'key': 'a', 'value': 1}),
      422,
    );
    available = true;
    ready = false;
    expect(await status('things.get', <String, Object?>{'key': 'a'}), 409);
  });

  test('检索：id 段命中排在前面，只返回可用的', () {
    final OpCatalog catalog = OpCatalog.build(routes(), descriptions);
    expect(catalog.search('delete thing').first.id, 'things.delete');
    expect(catalog.search('set value').first.id, 'things.set');
    expect(catalog.search('zzz'), isEmpty);
  });

  test('ops 路由：ls / describe / call（yes 给全部表态参数）', () async {
    final OpInvoker invoker = OpInvoker(
      OpCatalog.build(routes(), descriptions),
    );
    final List<CtlRoute> opRoutes = buildOpCatalogRoutes(() => invoker);
    CtlRoute route(String method, String pattern) => opRoutes.firstWhere(
      (CtlRoute r) => r.method == method && r.pattern == pattern,
    );
    final Object? ls = await route(
      'GET',
      kCtlOpsPath,
    ).handler(const CtlCall(method: 'GET', path: kCtlOpsPath));
    expect((ls! as Map)['ops'], hasLength(3));
    final Object? described = await route('GET', kCtlOpsDescribePath).handler(
      const CtlCall(
        method: 'GET',
        path: '/api/admin/ops/describe/things.delete',
        params: <String, String>{'id': 'things.delete'},
      ),
    );
    expect((described! as Map)['risk'], 'irreversible');
    expect((described as Map)['available'], isTrue);
    await route('POST', kCtlOpsCallPath).handler(
      const CtlCall(
        method: 'POST',
        path: kCtlOpsCallPath,
        body: <String, Object?>{
          'id': 'things.delete',
          'args': <String, Object?>{'key': 'a'},
          'yes': true,
        },
      ),
    );
    expect(store, isNot(contains('a')));
  });
}
