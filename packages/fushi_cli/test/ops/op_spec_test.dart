import 'package:fushi_cli/fushi_cli.dart';
import 'package:test/test.dart';

const OpParam _key = OpParam.string(
  'key',
  description: 'Thing key.',
  required: true,
  inPath: true,
);
const OpParam _limit = OpParam.integer('limit', description: 'Max rows.');
const OpParam _flag = OpParam.boolean('deep', description: 'Deep.');
const OpParam _mode = OpParam.string(
  'mode',
  description: 'Mode.',
  enumValues: <String>['a', 'b'],
);
const OpParam _tags = OpParam.stringList('tags', description: 'Tags.');
const OpParam _link = OpParam.remoteUrl(
  'link',
  description: 'Fetched.',
  httpOnly: true,
);

const OpSpec _get = OpSpec(
  id: 'thing.get',
  method: 'GET',
  pattern: '/api/admin/things/:key',
  summary: 'Get a thing.',
  params: <OpParam>[_key, _limit, _flag, _mode, _tags],
);

const OpSpec _fetch = OpSpec(
  id: 'thing.fetch',
  method: 'POST',
  pattern: '/api/admin/things/:key/fetch',
  summary: 'Fetch a thing from an address.',
  risk: OpRisk.irreversible,
  params: <OpParam>[_key, _link],
);

Matcher _bad(String message) => throwsA(
  isA<CtlFailure>()
      .having((CtlFailure f) => f.status, 'status', 400)
      .having((CtlFailure f) => f.message, 'message', message),
);

const OpParam _gateParam = OpParam.userGate(
  'confirm',
  description: 'User agreed.',
);

const OpSpec _gated = OpSpec(
  id: 'thing.wipe',
  method: 'POST',
  pattern: '/api/admin/things/wipe',
  summary: 'Wipe things.',
  risk: OpRisk.irreversible,
  params: <OpParam>[_gateParam],
);

void main() {
  group('OpArgs.parse（HTTP 与进程内共用一份转换）', () {
    CtlCall get(Map<String, String> query, {Map<String, Object?>? body}) =>
        CtlCall(
          method: 'GET',
          path: '/api/admin/things/k',
          params: const <String, String>{'key': 'k'},
          query: query,
          body: body ?? const <String, Object?>{},
        );

    test('GET 的 query 值按声明类型转换；body 优先于 query', () {
      final OpArgs args = OpArgs.parse(
        _get,
        const CtlCall(
          method: 'GET',
          path: '/api/admin/things/k%201',
          params: <String, String>{'key': 'k 1'},
          query: <String, String>{
            'limit': '12',
            'deep': 'yes',
            'mode': 'b',
            'tags': ' x ',
          },
        ),
        surface: OpCallSurface.inProcess,
      );
      expect(args.requiredText(_key), 'k 1');
      expect(args.integer(_limit), 12);
      expect(args.boolean(_flag), isTrue);
      expect(args.text(_mode), 'b');
      expect(args.strings(_tags), <String>['x']);
      final OpArgs bodyFirst = OpArgs.parse(
        _get,
        get(
          <String, String>{'limit': '1'},
          body: <String, Object?>{'limit': 2},
        ),
        surface: OpCallSurface.inProcess,
      );
      expect(bodyFirst.integer(_limit), 2);
    });

    test('进程内口径：类型 / 枚举 / 必填 / 未知参数在 parse 当场 400', () {
      OpArgs parse(CtlCall call) =>
          OpArgs.parse(_get, call, surface: OpCallSurface.inProcess);
      expect(
        () => parse(get(<String, String>{'limit': 'x'})),
        _bad('limit 必须是整数'),
      );
      expect(
        () => parse(
          get(const <String, String>{}, body: <String, Object?>{'limit': 1.5}),
        ),
        _bad('limit 必须是整数'),
      );
      expect(
        () => parse(get(<String, String>{'mode': 'c'})),
        _bad('mode 只能是 a / b'),
      );
      // 空白也按枚举判（迁移前进程内调用器的行为）。
      expect(
        () => parse(get(<String, String>{'mode': '  '})),
        _bad('mode 只能是 a / b'),
      );
      expect(
        () => parse(const CtlCall(method: 'GET', path: '/api/admin/things/')),
        _bad('key 缺失'),
      );
      expect(
        () => parse(get(<String, String>{'extra': '1'})),
        _bad('未知参数：extra'),
      );
    });

    test('HTTP 口径：与手写 CtlCall 取值一致——取值时才校验、数字截断、空白视为没给、'
        '未知参数只告警', () {
      OpArgs parse(CtlCall call) =>
          OpArgs.parse(_get, call, surface: OpCallSurface.http);
      // parse 本身不报参数错：handler 里先做的模块门 / 只读门仍先于参数错误。
      final OpArgs bad = parse(
        get(<String, String>{'limit': 'x', 'mode': 'c', 'extra': '1'}),
      );
      expect(() => bad.integer(_limit), _bad('limit 必须是整数'));
      expect(() => bad.text(_mode), _bad('mode 只能是 a / b'));
      expect(bad.requiredText(_key), 'k');
      final OpArgs lenient = parse(
        get(
          <String, String>{'mode': '  '},
          body: <String, Object?>{
            'limit': 1.5,
            'tags': <Object?>['a', null, ' '],
          },
        ),
      );
      expect(lenient.integer(_limit), 1);
      expect(lenient.text(_mode), isNull);
      expect(lenient.strings(_tags), <String>['a']);
      final OpArgs missing = parse(
        const CtlCall(method: 'GET', path: '/api/admin/things/'),
      );
      expect(() => missing.requiredText(_key), _bad('key 缺失'));
    });

    test('httpOnly 在取值时查（两种口径都是）；必填地址的文案不带参数名、可选的带', () {
      for (final OpCallSurface surface in OpCallSurface.values) {
        final OpArgs args = OpArgs.parse(
          _fetch,
          const CtlCall(
            method: 'POST',
            path: '/api/admin/things/k/fetch',
            params: <String, String>{'key': 'k'},
            body: <String, Object?>{'link': ' file:///etc/passwd '},
          ),
          surface: surface,
        );
        expect(
          () => args.text(_link),
          _bad('link 只认 http(s) 地址：file:///etc/passwd'),
        );
        expect(
          () => args.requiredText(_link),
          _bad('只认 http(s) 地址：file:///etc/passwd'),
        );
      }
    });

    test('取值传了别的操作的参数对象 / 类型不对 / 读法不对是编程错误', () {
      final OpArgs args = OpArgs.direct(
        _get,
        pathArgs: const <String, String>{'key': 'k'},
      );
      expect(() => args.text(_link), throwsStateError);
      expect(() => args.integer(_mode), throwsStateError);
      expect(() => args.gate(_flag), throwsStateError);
      expect(() => OpArgs.direct(_gated).boolean(_gateParam), throwsStateError);
    });
  });

  group('表态参数必须被实现读过（FushiOp.run）', () {
    const CtlCall call = CtlCall(
      method: 'POST',
      path: '/api/admin/things/wipe',
      body: <String, Object?>{'confirm': true},
    );

    test('读了：HTTP 与进程内都照常返回', () async {
      final FushiOp op = _gated.bind(
        handler: (OpArgs args) async => <String, Object?>{
          'ok': args.gate(_gateParam),
        },
      );
      expect(await op.route.handler(call), <String, Object?>{'ok': true});
      final OpInvocation invoked =
          await OpInvoker(
            OpCatalog.build(<CtlRoute>[op.route], const <OpDescription>[]),
          ).invoke(
            'thing.wipe',
            const <String, Object?>{},
            grantedGates: const <String>{'confirm'},
          );
      expect(invoked.result, <String, Object?>{'ok': true});
    });

    test('没读就完成了操作：HTTP 与进程内都抛 StateError', () async {
      final FushiOp op = _gated.bind(handler: (OpArgs args) async => null);
      await expectLater(op.route.handler(call), throwsStateError);
      await expectLater(
        OpInvoker(
          OpCatalog.build(<CtlRoute>[op.route], const <OpDescription>[]),
        ).invoke(
          'thing.wipe',
          const <String, Object?>{},
          grantedGates: const <String>{'confirm'},
        ),
        throwsStateError,
      );
    });

    test('实现自己拒绝（没读到表态）不算漏读；已有长期同意时不要求再读', () async {
      final FushiOp refuses = _gated.bind(
        handler: (OpArgs args) async => throw const CtlFailure.rejected('nope'),
      );
      await expectLater(
        refuses.route.handler(call),
        throwsA(isA<CtlFailure>()),
      );
      bool granted = true;
      final FushiOp standing = _gated.bind(
        handler: (OpArgs args) async => 'done',
        consentGranted: () => granted,
      );
      expect(await standing.route.handler(call), 'done');
      granted = false;
      await expectLater(standing.route.handler(call), throwsStateError);
    });

    test('按别的操作的声明解析的参数不许拿来执行', () async {
      final FushiOp op = _gated.bind(
        handler: (OpArgs args) async => args.gate(_gateParam),
      );
      await expectLater(
        op.run(
          OpArgs.direct(_get, pathArgs: const <String, String>{'key': 'k'}),
        ),
        throwsStateError,
      );
    });
  });

  group('构造期约束', () {
    FushiOp bind(OpSpec spec) =>
        spec.bind(handler: (OpArgs args) async => null);

    test('remoteUrl 参数的操作必须先确认', () {
      const OpSpec bad = OpSpec(
        id: 'thing.peek',
        method: 'GET',
        pattern: '/api/admin/peek',
        summary: 'Peek.',
        params: <OpParam>[_link],
      );
      expect(() => bind(bad), throwsArgumentError);
      expect(bind(_fetch).spec.needsConfirmation, isTrue);
    });

    test('名字是地址类的参数必须显式选语义角色（默认拒绝）', () {
      for (final String name in <String>[
        'url',
        'coverUrl',
        'link',
        'links',
        'endpoint',
        'magnet',
        'href',
        'host',
        'serverAddress',
      ]) {
        expect(
          () => bind(
            OpSpec(
              id: 'thing.peek',
              method: 'GET',
              pattern: '/api/admin/peek',
              summary: 'Peek.',
              params: <OpParam>[OpParam.string(name, description: 'x')],
            ),
          ),
          throwsArgumentError,
          reason: name,
        );
        expect(
          () => bind(
            OpSpec(
              id: 'thing.peek',
              method: 'GET',
              pattern: '/api/admin/peek',
              summary: 'Peek.',
              params: <OpParam>[OpParam.stringList(name, description: 'x')],
            ),
          ),
          throwsArgumentError,
          reason: '$name（数组）',
        );
        // 选了角色就行：不请求的地址不必确认。
        for (final OpParam ok in <OpParam>[
          OpParam.fixedHostUrl(name, description: 'x'),
          OpParam.storedAddress(name, description: 'x'),
          OpParam.entityRef(name, description: 'x'),
        ]) {
          bind(
            OpSpec(
              id: 'thing.peek',
              method: 'GET',
              pattern: '/api/admin/peek',
              summary: 'Peek.',
              params: <OpParam>[ok],
            ),
          );
        }
      }
      // 旧描述（OpDescription）走同一组校验。
      expect(
        () => const OpDescription(
          id: 'thing.peek',
          method: 'GET',
          pattern: '/api/admin/peek',
          summary: 'Peek.',
          params: <OpParam>[OpParam.string('url', description: 'x')],
        ).bind(CtlRoute.get('/api/admin/peek', (CtlCall c) async => null)),
        throwsArgumentError,
      );
      // 名字不是地址类、或类型装不下地址的不管。
      bind(
        const OpSpec(
          id: 'thing.peek',
          method: 'GET',
          pattern: '/api/admin/peek',
          summary: 'Peek.',
          params: <OpParam>[
            OpParam.string('hostess', description: 'x'),
            OpParam.boolean('followLinks', description: 'x'),
          ],
        ),
      );
    });

    test('id 是「装第三方代码」形状的操作必须声明 installsCode', () {
      for (final String id in <String>[
        'online.extension.install',
        'online.extension.install-from-url',
        'online.extension.update',
        'online.repo.add',
        'music.plugin.install',
        'music.plugin.import',
      ]) {
        expect(
          () => bind(
            OpSpec(
              id: id,
              method: 'POST',
              pattern: '/api/admin/install',
              summary: 'Install.',
              risk: OpRisk.irreversible,
            ),
          ),
          throwsArgumentError,
          reason: id,
        );
        bind(
          OpSpec(
            id: id,
            method: 'POST',
            pattern: '/api/admin/install',
            summary: 'Install.',
            risk: OpRisk.irreversible,
            installsCode: true,
          ),
        );
      }
      // 列表 / 卸载 / 启停不装新代码。
      for (final String id in <String>[
        'online.extension.list',
        'online.extension.remove',
        'online.repo.remove',
        'music.plugin.enable',
      ]) {
        bind(
          OpSpec(
            id: id,
            method: 'POST',
            pattern: '/api/admin/x',
            summary: 'X.',
            risk: OpRisk.irreversible,
          ),
        );
      }
    });

    test('装扩展必须先确认', () {
      const OpSpec bad = OpSpec(
        id: 'thing.install',
        method: 'POST',
        pattern: '/api/admin/install',
        summary: 'Install.',
        risk: OpRisk.irreversible,
        installsCode: true,
      );
      expect(bind(bad).spec.needsConfirmation, isTrue);
      const OpSpec unconfirmed = OpSpec(
        id: 'thing.install',
        method: 'POST',
        pattern: '/api/admin/install',
        summary: 'Install.',
        risk: OpRisk.write,
        installsCode: true,
      );
      expect(
        () => unconfirmed.bind(
          handler: (OpArgs args) async => null,
          undo: OpUndo(
            record: (OpArgs c, Map<String, Object?> b, Object? r) =>
                const OpUndoRecord(payload: <String, Object?>{}),
            revert: (Map<String, Object?> p) async =>
                const OpUndoOutcome.done(),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('inPath 与模式不一致 / 写操作不可撤销 / 坏 id 都在构造时炸', () {
      expect(
        () => bind(
          const OpSpec(
            id: 'thing.get',
            method: 'GET',
            pattern: '/api/admin/things/:id',
            summary: 'Get.',
            params: <OpParam>[_key],
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => bind(
          const OpSpec(
            id: 'thing.set',
            method: 'PUT',
            pattern: '/api/admin/x',
            summary: 'Set.',
            risk: OpRisk.write,
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => bind(
          const OpSpec(
            id: 'thing_get',
            method: 'GET',
            pattern: '/api/admin/x',
            summary: 'Get.',
          ),
        ),
        throwsArgumentError,
      );
    });

    test('语义角色不进线上 schema', () {
      expect(_link.toJsonSchema(), <String, Object?>{
        'type': 'string',
        'description': 'Fetched.',
      });
      expect(_link.toJson(), <String, Object?>{
        'name': 'link',
        'type': 'string',
        'description': 'Fetched.',
      });
    });
  });

  group('派生路由与调用器', () {
    test('HTTP 直连经派生路由按声明解析后调同一个实现', () async {
      final List<OpArgs> seen = <OpArgs>[];
      final FushiOp op = _get.bind(
        handler: (OpArgs args) async {
          seen.add(args);
          return <String, Object?>{'limit': args.integer(_limit)};
        },
      );
      expect(op.route.op, same(op));
      expect(op.route.method, 'GET');
      expect(op.route.pattern, '/api/admin/things/:key');
      final Object? result = await op.route.handler(
        const CtlCall(
          method: 'GET',
          path: '/api/admin/things/k',
          params: <String, String>{'key': 'k'},
          query: <String, String>{'limit': '3', 'stray': 'x'},
        ),
      );
      expect(result, <String, Object?>{'limit': 3});
      final OpCatalog catalog = OpCatalog.build(<CtlRoute>[
        op.route,
      ], const <OpDescription>[]);
      expect(catalog['thing.get'], same(op));
      final OpInvocation invoked = await OpInvoker(
        catalog,
      ).invoke('thing.get', <String, Object?>{'key': 'k', 'limit': 4});
      expect(invoked.result, <String, Object?>{'limit': 4});
      expect(
        () => OpInvoker(
          catalog,
        ).invoke('thing.get', <String, Object?>{'key': 'k', 'stray': 1}),
        throwsA(isA<CtlFailure>()),
      );
    });

    test('必填的 spread 参数：传了对象就铺进 body 顶层并执行，不传才报缺失（BUG-5616）', () async {
      // 与 video.subtitle.glossary.set 同形：旧描述 + 手写路由按动态键名读 body。
      final List<Map<String, Object?>> bodies = <Map<String, Object?>>[];
      final OpCatalog catalog = OpCatalog.build(
        <CtlRoute>[
          CtlRoute.put('/api/admin/table', (CtlCall call) async {
            bodies.add(call.body);
            return null;
          }),
        ],
        <OpDescription>[
          OpDescription(
            id: 'thing.table.set',
            method: 'PUT',
            pattern: '/api/admin/table',
            summary: 'Replace the table.',
            risk: OpRisk.write,
            params: const <OpParam>[
              OpParam.string('scope', description: 'Scope.'),
              OpParam.object(
                'table',
                description: 'The full new table.',
                required: true,
                spread: true,
              ),
            ],
            undo: OpUndo(
              record: (OpArgs c, Map<String, Object?> b, Object? r) =>
                  const OpUndoRecord(payload: <String, Object?>{}),
              revert: (Map<String, Object?> p) async =>
                  const OpUndoOutcome.done(),
            ),
          ),
        ],
      );
      final OpInvoker invoker = OpInvoker(catalog);
      await invoker.invoke('thing.table.set', <String, Object?>{
        'scope': 's',
        'table': <String, Object?>{
          'entries': <Object?>[1, 2],
        },
      }, caller: OpCaller.model);
      expect(bodies.single, <String, Object?>{
        'scope': 's',
        'entries': <Object?>[1, 2],
      });
      await expectLater(
        invoker.invoke('thing.table.set', <String, Object?>{'scope': 's'}),
        _bad('table 缺失'),
      );
      await expectLater(
        invoker.invoke('thing.table.set', <String, Object?>{
          'table': <String, Object?>{'scope': 'x'},
        }),
        _bad('table.scope 与参数重名'),
      );
      expect(bodies, hasLength(1));
    });

    test('旧描述挂不到 OpSpec 派生的路由上（一个操作只声明一次）', () {
      final FushiOp op = _get.bind(handler: (OpArgs args) async => null);
      expect(
        () => OpCatalog.build(
          <CtlRoute>[op.route],
          const <OpDescription>[
            OpDescription(
              id: 'thing.again',
              method: 'GET',
              pattern: '/api/admin/things/:key',
              summary: 'Again.',
              params: <OpParam>[_key],
            ),
          ],
        ),
        throwsStateError,
      );
    });

    test('CLI 请求从声明拼：GET 进 query、POST 进 body，null 不带', () {
      final CtlRequestSpec get = CtlRequestSpec.op(
        _get,
        pathArgs: const <String, String>{'key': 'a/b'},
        args: const <String, Object?>{'limit': 5, 'mode': null},
      );
      expect(get.method, 'GET');
      expect(get.path, '/api/admin/things/a%2Fb');
      expect(get.query, <String, String>{'limit': '5'});
      final CtlRequestSpec post = CtlRequestSpec.op(
        _fetch,
        pathArgs: const <String, String>{'key': 'k'},
        args: const <String, Object?>{'link': 'https://x/'},
      );
      expect(post.method, 'POST');
      expect(post.path, '/api/admin/things/k/fetch');
      expect(post.body, <String, Object?>{'link': 'https://x/'});
    });
  });
}
