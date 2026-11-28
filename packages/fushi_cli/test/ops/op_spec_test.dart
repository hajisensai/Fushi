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

void main() {
  group('OpArgs.parse（HTTP 与进程内共用）', () {
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
        unknown: OpUnknownParams.reject,
      );
      expect(args.requiredText(_key), 'k 1');
      expect(args.integer(_limit), 12);
      expect(args.boolean(_flag), isTrue);
      expect(args.text(_mode), 'b');
      expect(args.strings(_tags), <String>['x']);
      final OpArgs bodyFirst = OpArgs.parse(
        _get,
        const CtlCall(
          method: 'GET',
          path: '/api/admin/things/k',
          params: <String, String>{'key': 'k'},
          query: <String, String>{'limit': '1'},
          body: <String, Object?>{'limit': 2},
        ),
        unknown: OpUnknownParams.reject,
      );
      expect(bodyFirst.integer(_limit), 2);
    });

    test('类型 / 枚举 / 必填 / http(s) 错误一律 400，文案只在这里产生', () {
      CtlCall call(Map<String, String> query) => CtlCall(
        method: 'GET',
        path: '/api/admin/things/k',
        params: const <String, String>{'key': 'k'},
        query: query,
      );
      expect(
        () => OpArgs.parse(
          _get,
          call(<String, String>{'limit': 'x'}),
          unknown: OpUnknownParams.warn,
        ),
        _bad('limit 必须是整数'),
      );
      expect(
        () => OpArgs.parse(
          _get,
          call(<String, String>{'mode': 'c'}),
          unknown: OpUnknownParams.warn,
        ),
        _bad('mode 只能是 a / b'),
      );
      expect(
        () => OpArgs.parse(
          _get,
          const CtlCall(method: 'GET', path: '/api/admin/things/'),
          unknown: OpUnknownParams.warn,
        ),
        _bad('key 缺失'),
      );
      expect(
        () => OpArgs.parse(
          _fetch,
          const CtlCall(
            method: 'POST',
            path: '/api/admin/things/k/fetch',
            params: <String, String>{'key': 'k'},
            body: <String, Object?>{'link': 'file:///etc/passwd'},
          ),
          unknown: OpUnknownParams.warn,
        ),
        _bad('link 只认 http(s) 地址：file:///etc/passwd'),
      );
    });

    test('空白字符串视为没给：不按枚举判，必填的取值报缺失', () {
      final OpArgs args = OpArgs.parse(
        _get,
        const CtlCall(
          method: 'GET',
          path: '/api/admin/things/k',
          params: <String, String>{'key': 'k'},
          query: <String, String>{'mode': '  '},
        ),
        unknown: OpUnknownParams.reject,
      );
      expect(args.text(_mode), isNull);
    });

    test('未知参数：HTTP 直连只告警照常执行，进程内拒绝', () {
      const CtlCall call = CtlCall(
        method: 'GET',
        path: '/api/admin/things/k',
        params: <String, String>{'key': 'k'},
        query: <String, String>{'extra': '1'},
      );
      expect(
        OpArgs.parse(
          _get,
          call,
          unknown: OpUnknownParams.warn,
        ).requiredText(_key),
        'k',
      );
      expect(
        () => OpArgs.parse(_get, call, unknown: OpUnknownParams.reject),
        _bad('未知参数：extra'),
      );
    });

    test('取值传了别的操作的参数对象 / 类型不对是编程错误', () {
      final OpArgs args = OpArgs.direct(
        _get,
        pathArgs: const <String, String>{'key': 'k'},
      );
      expect(() => args.text(_link), throwsStateError);
      expect(() => args.integer(_mode), throwsStateError);
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
