/// 统一互联模块层（设计 docs/specs/2026-11-23-interconnect-music-library-design.md §3.5，拍板
/// design-imusic-q0 选 a）的验收：
///
/// 1. 六个迁进模块层的功能（漫画 OCR 任务、通用任务、代下载、BT 引擎、订阅、助手）全接上时，
///    `/api/capabilities` 与迁移前**逐字节相同**（[_kLegacyCapabilitiesJson] 是迁移前的服务器在同样
///    装配下吐出的原文）；
/// 2. 都没接时键不出现、前缀仍被模块占住回 404（不掉进 WebDAV 文件树）；
/// 3. 模块前缀 / 能力键冲突、模块内路由遮蔽在构造时就报错；同有同无的能力键一次求值；
/// 4. 统一流票：签发 → Range 取流 → 释放即作废；签发凭据吊销即作废（BUG-4393）；视频票不能走统一
///    取流路径，音乐票也不能拿去取视频。
/// 5. 棘轮（文件末尾的几条「守卫」）：端点表之外还没收口的东西——handler 里的二级路径分发、handler 里
///    各判各的 TLS / 已配对设备门、免 Basic 的面——逐项列名、只减不增。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/torrent/remote_torrent_wire.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi_engine/sync/downloads/host_download_host.dart';
import 'package:fushi_engine/sync/fushi_manga_ocr_host.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_service.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_manager.dart';
import 'package:fushi_engine/sync/interconnect_module.dart';
import 'package:fushi_engine/sync/library_media_streams.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:fushi_engine/sync/torrent_engine/host_torrent_engine.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

const String _token = 'module-layer-token';
const String _peerToken = 'peer-token-1';

/// 迁移前（815279ce19，即 develop d095b87a48 + 设计稿）的服务器在 [_startFull] 同样装配下 `/api/capabilities` 的原文，
/// 加上之后新增、与模块层无关的能力位（`liveLibrary.onlineItems`，在线源条目同步 1037455d2a；
/// `liveLibrary.videoSidecarAudio`，远端外挂音轨 1f681d0624 / BUG-5509）。
const String _kLegacyCapabilitiesJson =
    '{"srsChangesV1":true,"mangaOcr":{"supported":false,"modelsReady":fal'
    'se},"jobs":{"kinds":[]},"downloads":{"supported":true,"backend":"emb'
    'edded","kinds":["video"],"deleteFilesParam":true},"torrentEngine":{"'
    'supported":true,"backend":"embedded","features":[],"pauseControlAvai'
    'lable":null,"detailAvailable":null,"allowedRoots":[]},"subscriptions'
    '":{"supported":true,"providers":["nyaa"]},"assistant":{"available":t'
    'rue},"lookup":{"dictionary":false,"history":false},"mining":false,"g'
    'ameStream":false,"hostUpdate":false,"webdav":{"treeListingLevels":2}'
    ',"liveLibrary":{"dictionaries":false,"books":false,"audio":false,"lo'
    'calAudioContentIdV2":false,"videos":false,"manga":false,"videoMetada'
    'ta":false,"tags":false,"pdfBooks":false,"mediaLinks":false,"onlineItems":false,"streamVi'
    'deos":false,"deletionTombstones":false,"videoDeletion":false,"videoT'
    'ranscode":false,"videoSubtitleDefault":false,"videoSubtitleDefaultEp'
    'isode":false,"videoSubtitleClear":false,"videoSidecarSubtitles":fals'
    'e,"videoSidecarAudio":false,"discShareV1":false,"videoClipExport":false,"videoClipAudioDiscTit'
    'le":false,"videoClipAudioDiscTitleAngle":false,"videoClipAudioDiscTi'
    'tleDvd":false,"videoClipAudioDiscTitleDvdAngle":false,"videoSubtitle'
    'Backfill":false,"videoGraphicSubtitleTrack":false,"videoMetadataOrde'
    'ring":false,"serviceConfig":false,"sourceShare":false,"pluginRelay":'
    'false,"profileTransfer":false},"tls":{"enabled":false},"pairing":{"v'
    '2":true}}';

class _OcrService implements MangaOcrService {
  @override
  bool get isSupportedPlatform => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _DownloadHost implements HostDownloadHost {
  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
    'supported': true,
    'backend': 'embedded',
    'kinds': <String>['video'],
  };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _SubscriptionHost implements HostSubscriptionHost {
  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
    'supported': true,
    'providers': <String>['nyaa'],
  };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _TorrentEngine implements HostTorrentEngine {
  @override
  Future<TorrentEngineCapability> capability() async =>
      const TorrentEngineCapability(supported: true, backend: 'embedded');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Assistant implements HostAssistantProvider {
  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
    'available': true,
  };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 测试用模块：提供一种流（音乐曲目），id → 临时目录里的文件。
class _StreamModule extends InterconnectHostModule {
  _StreamModule(this.files);

  final Map<String, File> files;
  final String prefix = '/api/test-module';

  @override
  String get name => 'testModule';

  @override
  List<InterconnectCapability> get capabilities => <InterconnectCapability>[
    InterconnectCapability('testModule', () => <String, Object?>{'v': 1}),
  ];

  @override
  List<InterconnectRoute> get routes => <InterconnectRoute>[
    InterconnectRoute(
      InterconnectPath.subtree(prefix),
      trust: InterconnectTrust.credential,
      handler: handle,
    ),
  ];

  Future<shelf.Response> handle(InterconnectRequest request) async =>
      shelf.Response.ok(
        jsonEncode(<String, Object?>{
          'path': request.path,
          'pairedPeer': await request.isPairedPeer(),
          'hasFingerprint': request.credentialFingerprint != null,
        }),
      );

  @override
  Map<LibraryMediaStreamKind, LibraryMediaResolver> get streamResolvers =>
      <LibraryMediaStreamKind, LibraryMediaResolver>{
        LibraryMediaStreamKind.musicTrack: (LibraryMediaRequest r) async {
          final File? f = files[r.id];
          return f == null ? null : LibraryMediaFile(f);
        },
      };
}

class _PrefixModule extends InterconnectHostModule {
  _PrefixModule(this.name, List<String> prefixes)
    : routes = <InterconnectRoute>[
        for (final String prefix in prefixes)
          InterconnectRoute(
            InterconnectPath.subtree(prefix),
            trust: InterconnectTrust.credential,
            handler: (InterconnectRequest _) async => shelf.Response.ok(''),
          ),
      ];

  @override
  final String name;

  @override
  final List<InterconnectRoute> routes;
}

/// 任意路由 / 能力位的测试模块。
class _DeclaredModule extends InterconnectHostModule {
  _DeclaredModule(
    this.name, {
    this.routes = const <InterconnectRoute>[],
    this.capabilities = const <InterconnectCapability>[],
  });

  @override
  final String name;

  @override
  final List<InterconnectRoute> routes;

  @override
  final List<InterconnectCapability> capabilities;
}

InterconnectRoute _ok(
  InterconnectPath path, {
  Set<String>? methods,
  InterconnectTrust trust = InterconnectTrust.credential,
  String body = '',
}) => InterconnectRoute(
  path,
  methods: methods,
  trust: trust,
  handler: (InterconnectRequest _) async => shelf.Response.ok(body),
);

bool _always(String _) => true;

String _basic(String password) =>
    'Basic ${base64Encode(utf8.encode('hibiki:$password'))}';

Future<({int status, String body, Map<String, String> headers})> _send(
  FushiSyncServer server,
  String method,
  String pathAndQuery, {
  String? password = _token,
  Object? json,
  Map<String, String> headers = const <String, String>{},
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$pathAndQuery'),
    );
    if (password != null) req.headers.set('authorization', _basic(password));
    headers.forEach(req.headers.set);
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(json));
    }
    final HttpClientResponse res = await req.close();
    final List<int> bytes = <int>[
      for (final List<int> chunk in await res.toList()) ...chunk,
    ];
    final String body = utf8.decode(bytes, allowMalformed: true);
    final Map<String, String> out = <String, String>{};
    res.headers.forEach((String k, List<String> v) => out[k] = v.join(','));
    return (status: res.statusCode, body: body, headers: out);
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('interconnect_module_layer_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<FushiSyncServer> start({
    bool full = false,
    List<InterconnectHostModule> modules = const <InterconnectHostModule>[],
  }) async {
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: tmp.path,
      port: 0,
      token: _token,
      mangaOcrJobs: full
          ? MangaOcrHostJobManager(
              service: _OcrService(),
              jobRoot: Directory('${tmp.path}/ocr'),
            )
          : null,
      hostJobs: full
          ? HostJobManager(
              jobRoot: Directory('${tmp.path}/jobs'),
              runners: const [],
            )
          : null,
      downloads: full ? _DownloadHost() : null,
      torrentEngine: full ? _TorrentEngine() : null,
      subscriptions: full ? _SubscriptionHost() : null,
      assistant: full ? _Assistant() : null,
      modules: modules,
    );
    server.pairedPeerCredentialsProvider = () async => <String, String>{
      'peer-1': _peerToken,
    };
    await server.start();
    addTearDown(server.stop);
    return server;
  }

  test('六个功能全接：能力 JSON 与迁移前逐字节相同', () async {
    final FushiSyncServer server = await start(full: true);
    final res = await _send(server, 'GET', '/api/capabilities');
    expect(res.status, 200);
    expect(res.body, _kLegacyCapabilitiesJson);
  });

  test('都没接：键不出现，前缀仍归模块回 404（不落进 WebDAV）', () async {
    final FushiSyncServer server = await start();
    final res = await _send(server, 'GET', '/api/capabilities');
    final Map<String, dynamic> caps =
        jsonDecode(res.body) as Map<String, dynamic>;
    for (final String key in <String>[
      'mangaOcr',
      'jobs',
      'downloads',
      'torrentEngine',
      'subscriptions',
      'assistant',
    ]) {
      expect(caps.containsKey(key), isFalse, reason: key);
    }
    final Map<String, String> offBodies = <String, String>{
      '/api/ocr/job': 'Manga OCR off',
      '/api/jobs': 'Host jobs off',
      '/api/jobs/x': 'Host jobs off',
      '/api/downloads': 'Host downloads off',
      '/api/torrent-engine/torrents': 'Host torrent engine off',
      '/api/subscriptions': 'Host subscriptions off',
      '/api/assistant': 'Host assistant off',
    };
    for (final MapEntry<String, String> e in offBodies.entries) {
      for (final String method in <String>['GET', 'PUT']) {
        final r = await _send(server, method, e.key);
        expect(r.status, 404, reason: '$method ${e.key}');
        expect(r.body, e.value, reason: '$method ${e.key}');
      }
    }
    expect(Directory('${tmp.path}/sync-data/api').existsSync(), isFalse);
  });

  test('BT 引擎：共享 token 403，已配对设备放行到 handler', () async {
    final FushiSyncServer server = await start(full: true);
    final shared = await _send(server, 'GET', '/api/torrent-engine/torrents');
    expect(shared.status, 403);
    expect(shared.body, '{"error":"paired_peer_required"}');
  });

  test('新模块：经 modules 注册即分发、拼能力位，请求带上身份', () async {
    final FushiSyncServer server = await start(
      modules: <InterconnectHostModule>[_StreamModule(<String, File>{})],
    );
    final caps =
        jsonDecode((await _send(server, 'GET', '/api/capabilities')).body)
            as Map<String, dynamic>;
    expect(caps['testModule'], <String, Object?>{'v': 1});
    final shared = await _send(server, 'GET', '/api/test-module/a/b');
    expect(jsonDecode(shared.body), <String, Object?>{
      'path': '/api/test-module/a/b',
      'pairedPeer': false,
      'hasFingerprint': true,
    });
    final peer = await _send(
      server,
      'GET',
      '/api/test-module',
      password: _peerToken,
    );
    expect((jsonDecode(peer.body) as Map<String, dynamic>)['pairedPeer'], true);
    final anon = await _send(server, 'GET', '/api/test-module', password: null);
    expect(anon.status, 401, reason: '模块路由一律要 Basic');
  });

  group('模块表构造即查冲突', () {
    test('前缀相同 / 互为前缀 / 与内置模块冲突都报错', () {
      expect(
        () => InterconnectModuleTable(<InterconnectHostModule>[
          _PrefixModule('a', <String>['/api/x']),
          _PrefixModule('b', <String>['/api/x/y']),
        ]),
        throwsArgumentError,
      );
      expect(
        () => InterconnectModuleTable(<InterconnectHostModule>[
          _PrefixModule('a', <String>['/api/x']),
          _PrefixModule('a', <String>['/api/y']),
        ]),
        throwsArgumentError,
      );
      expect(
        () => InterconnectModuleTable(<InterconnectHostModule>[
          _PrefixModule('a', <String>['/api/x/']),
        ]),
        throwsArgumentError,
      );
      expect(
        () => FushiSyncServer(
          syncDataDir: tmp.path,
          port: 0,
          token: _token,
          modules: <InterconnectHostModule>[
            _PrefixModule('rogue', <String>['/api/jobs']),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('/api/xy 不归 /api/x', () {
      final InterconnectModuleTable table = InterconnectModuleTable(
        <InterconnectHostModule>[
          _PrefixModule('a', <String>['/api/x']),
        ],
      );
      expect(table.lookup('/api/x', 'GET'), isA<InterconnectRouteHit>());
      expect(table.lookup('/api/x/1', 'GET'), isA<InterconnectRouteHit>());
      expect(table.lookup('/api/xy', 'GET'), isA<InterconnectRouteMiss>());
    });

    test('精确路径 / under / where 的跨模块冲突', () {
      InterconnectModuleTable two(InterconnectPath a, InterconnectPath b) =>
          InterconnectModuleTable(<InterconnectHostModule>[
            _DeclaredModule('a', routes: <InterconnectRoute>[_ok(a)]),
            _DeclaredModule('b', routes: <InterconnectRoute>[_ok(b)]),
          ]);
      expect(
        () => two(
          const InterconnectPath.exact('/api/m'),
          const InterconnectPath.exact('/api/m'),
        ),
        throwsArgumentError,
      );
      expect(
        () => two(
          const InterconnectPath.exact('/api/x/y'),
          const InterconnectPath.subtree('/api/x'),
        ),
        throwsArgumentError,
      );
      expect(
        () => two(
          const InterconnectPath.under('/api/x/'),
          const InterconnectPath.where('/api/x/y', _always),
        ),
        throwsArgumentError,
      );
      // 互不相交的不报：一条精确路径是另一条的「前缀」、under 不含前缀本身。
      two(
        const InterconnectPath.exact('/api/m'),
        const InterconnectPath.exact('/api/m/targets'),
      );
      two(
        const InterconnectPath.under('/api/v/'),
        const InterconnectPath.exact('/api/v'),
      );
      // 同一模块里可以先窄后宽（免 Basic 的子路径 + 整棵子树）。
      InterconnectModuleTable(<InterconnectHostModule>[
        _DeclaredModule(
          'a',
          routes: <InterconnectRoute>[
            _ok(
              const InterconnectPath.exact('/api/a/s'),
              methods: <String>{'GET'},
            ),
            _ok(const InterconnectPath.subtree('/api/a')),
          ],
        ),
      ]);
    });

    test('路由的方法集：非空、大写；路径命中而方法不受理是单独一态（405）', () {
      expect(
        () => _ok(const InterconnectPath.exact('/api/a'), methods: <String>{}),
        throwsArgumentError,
      );
      expect(
        () => _ok(
          const InterconnectPath.exact('/api/a'),
          methods: <String>{'get'},
        ),
        throwsArgumentError,
      );
      final InterconnectModuleTable table = InterconnectModuleTable(
        <InterconnectHostModule>[
          _DeclaredModule(
            'a',
            routes: <InterconnectRoute>[
              _ok(
                const InterconnectPath.exact('/api/a'),
                methods: <String>{'POST'},
              ),
            ],
          ),
        ],
      );
      expect(table.lookup('/api/a', 'POST'), isA<InterconnectRouteHit>());
      expect(
        table.lookup('/api/a', 'GET'),
        isA<InterconnectRouteMethodNotAllowed>(),
      );
      expect(table.lookup('/api/b', 'GET'), isA<InterconnectRouteMiss>());
    });

    test('模块内遮蔽：一条路由声明的每个方法都必须到得了', () {
      InterconnectModuleTable build(List<InterconnectRoute> routes) =>
          InterconnectModuleTable(<InterconnectHostModule>[
            _DeclaredModule('m', routes: routes),
          ]);
      const InterconnectTrust ticket = InterconnectTrust.urlTicket('测试票');
      const Set<String> get = <String>{'GET'};

      // 宽的写在了窄的前面：免 Basic 的取流子路径永远到不了（会悄悄变成要 Basic）。
      for (final InterconnectPath narrow in const <InterconnectPath>[
        InterconnectPath.exact('/api/v/1/stream'),
        InterconnectPath.subtree('/api/v/1'),
        InterconnectPath.under('/api/v/1/'),
        InterconnectPath.where('/api/v', _always),
      ]) {
        for (final InterconnectPath wide in const <InterconnectPath>[
          InterconnectPath.subtree('/api/v'),
          InterconnectPath.under('/api/v/'),
        ]) {
          // under('/api/v/') 不含 `/api/v` 本身，盖不住以它为根的 where。
          final bool shadowed =
              !(wide is InterconnectUnderPath &&
                  narrow is InterconnectWherePath);
          final List<InterconnectRoute> routes = <InterconnectRoute>[
            _ok(wide),
            _ok(narrow, methods: get, trust: ticket),
          ];
          expect(
            () => build(routes),
            shadowed ? throwsArgumentError : returnsNormally,
            reason: '$wide 在 $narrow 之前',
          );
          expect(
            () => build(routes.reversed.toList()),
            returnsNormally,
            reason: '先窄后宽合法：$narrow 在 $wide 之前',
          );
        }
      }

      // 原盘那种写法：同一路径模式，前一条只收 GET（免 Basic），后一条不限方法兜底——合法；反过来不行。
      final List<InterconnectRoute> disc = <InterconnectRoute>[
        _ok(
          const InterconnectPath.under('/api/d/'),
          methods: get,
          trust: ticket,
        ),
        _ok(const InterconnectPath.under('/api/d/')),
      ];
      expect(() => build(disc), returnsNormally);
      expect(() => build(disc.reversed.toList()), throwsArgumentError);

      // 方法集只要有一个被前面盖住就算（那个方法在后一条上是死的）；不相交则各收各的。
      expect(
        () => build(<InterconnectRoute>[
          _ok(const InterconnectPath.subtree('/api/s'), methods: get),
          _ok(
            const InterconnectPath.exact('/api/s/x'),
            methods: <String>{'GET', 'HEAD'},
            trust: ticket,
          ),
        ]),
        throwsArgumentError,
      );
      expect(
        () => build(<InterconnectRoute>[
          _ok(const InterconnectPath.subtree('/api/s'), methods: get),
          _ok(
            const InterconnectPath.exact('/api/s/x'),
            methods: <String>{'POST'},
          ),
        ]),
        returnsNormally,
      );
      // 同一条路由写了两遍。
      expect(
        () => build(<InterconnectRoute>[
          _ok(const InterconnectPath.exact('/api/e'), methods: get),
          _ok(const InterconnectPath.exact('/api/e'), methods: get),
        ]),
        throwsArgumentError,
      );
      // where 的谓词不透明：只认「同一棵子树、同一个谓词」。
      expect(
        () => build(<InterconnectRoute>[
          _ok(const InterconnectPath.where('/api/w', _always), methods: get),
          _ok(const InterconnectPath.where('/api/w', _always), methods: get),
        ]),
        throwsArgumentError,
      );
      expect(
        () => build(<InterconnectRoute>[
          _ok(const InterconnectPath.where('/api/w', _always), methods: get),
          _ok(const InterconnectPath.subtree('/api/w')),
        ]),
        returnsNormally,
      );
    });

    test('同有同无的能力键：一项声明只求值一次，写进每个键', () async {
      const InterconnectCapabilityGroup g = InterconnectCapabilityGroup(
        'g',
        <String>['x', 'y'],
      );
      int topCalls = 0;
      int memberCalls = 0;
      bool on = true;
      final InterconnectModuleTable table = InterconnectModuleTable(
        <InterconnectHostModule>[
          _DeclaredModule(
            'pair',
            capabilities: <InterconnectCapability>[
              InterconnectCapability.keys(const <String>['v2', 'v1'], () {
                topCalls++;
                return on ? true : null;
              }),
              InterconnectCapability.members(g, const <String>['y', 'x'], () {
                memberCalls++;
                return on;
              }),
            ],
          ),
        ],
      );
      expect(
        jsonEncode(await table.capabilities()),
        '{"v2":true,"v1":true,"g":{"x":true,"y":true}}',
      );
      expect((topCalls, memberCalls), (1, 1));
      on = false;
      expect(
        jsonEncode(await table.capabilities()),
        '{"g":{"x":false,"y":false}}',
        reason: '两个顶层键一起缺',
      );
      expect((topCalls, memberCalls), (2, 2));

      expect(
        () => InterconnectCapability.keys(const <String>[], () => true),
        throwsArgumentError,
      );
      expect(
        () => InterconnectModuleTable(<InterconnectHostModule>[
          _DeclaredModule(
            'dup',
            capabilities: <InterconnectCapability>[
              InterconnectCapability.keys(const <String>['a', 'a'], () => 1),
            ],
          ),
        ]),
        throwsArgumentError,
        reason: '一项里的键也不得重复',
      );
    });

    test('能力文档在同一个同步段里求值：异步能力位不把前后两项隔成两个时刻', () async {
      bool on = true;
      final InterconnectModuleTable table = InterconnectModuleTable(
        <InterconnectHostModule>[
          _DeclaredModule(
            'm',
            capabilities: <InterconnectCapability>[
              InterconnectCapability('before', () => on),
              InterconnectCapability('slow', () async {
                await Future<void>.delayed(Duration.zero);
                // 求值途中 host 状态变了（如用户关掉了复习模块）。
                on = false;
                return true;
              }),
              InterconnectCapability('after', () => on),
            ],
          ),
        ],
      );
      expect(
        jsonEncode(await table.capabilities()),
        '{"before":true,"slow":true,"after":true}',
      );
    });

    test('能力分组：成员须声明、恰好一个提供者；分组按成员序、落在第一个提供者处', () async {
      const InterconnectCapabilityGroup g = InterconnectCapabilityGroup(
        'g',
        <String>['x', 'y'],
      );
      InterconnectCapability member(String key, Object? v) =>
          InterconnectCapability.member(g, key, () => v);
      expect(
        () => InterconnectModuleTable(<InterconnectHostModule>[
          _DeclaredModule(
            'a',
            capabilities: <InterconnectCapability>[member('x', true)],
          ),
        ]),
        throwsArgumentError,
        reason: 'y 没人提供',
      );
      expect(
        () => InterconnectModuleTable(<InterconnectHostModule>[
          _DeclaredModule(
            'a',
            capabilities: <InterconnectCapability>[
              member('x', true),
              member('y', true),
              member('z', true),
            ],
          ),
        ]),
        throwsArgumentError,
        reason: 'z 不是成员',
      );
      expect(
        () => InterconnectModuleTable(<InterconnectHostModule>[
          _DeclaredModule(
            'a',
            capabilities: <InterconnectCapability>[
              member('x', true),
              member('y', true),
            ],
          ),
          _DeclaredModule(
            'b',
            capabilities: <InterconnectCapability>[member('x', false)],
          ),
        ]),
        throwsArgumentError,
        reason: 'x 重复提供',
      );
      final InterconnectModuleTable table = InterconnectModuleTable(
        <InterconnectHostModule>[
          _DeclaredModule(
            'top',
            capabilities: <InterconnectCapability>[
              InterconnectCapability('first', () => 1),
              InterconnectCapability('absent', () => null),
            ],
          ),
          _DeclaredModule(
            'b',
            capabilities: <InterconnectCapability>[member('y', false)],
          ),
          _DeclaredModule(
            'c',
            capabilities: <InterconnectCapability>[
              InterconnectCapability('last', () async => true),
              member('x', true),
            ],
          ),
        ],
      );
      expect(
        jsonEncode(await table.capabilities()),
        '{"first":1,"g":{"x":true,"y":false},"last":true}',
      );
    });
  });

  group('信任级', () {
    test('urlTicket / probe / bootstrap 只对声明的方法免 Basic；其余照常 401', () async {
      final FushiSyncServer server = await start(
        modules: <InterconnectHostModule>[
          _DeclaredModule(
            'trust',
            routes: <InterconnectRoute>[
              _ok(
                const InterconnectPath.exact('/api/t/stream'),
                methods: <String>{'GET'},
                trust: const InterconnectTrust.urlTicket('测试票'),
                body: 'ticket',
              ),
              _ok(
                const InterconnectPath.exact('/api/t/probe'),
                methods: <String>{'GET'},
                trust: InterconnectTrust.reachabilityProbe,
                body: 'probe',
              ),
              _ok(
                const InterconnectPath.exact('/api/t/pair'),
                methods: <String>{'POST'},
                trust: InterconnectTrust.pairingBootstrap,
                body: 'pair',
              ),
              _ok(const InterconnectPath.subtree('/api/t'), body: 'basic'),
            ],
          ),
        ],
      );
      Future<String> anon(String method, String path) async {
        final r = await _send(server, method, path, password: null);
        return '${r.status} ${r.body}';
      }

      expect(await anon('GET', '/api/t/stream'), '200 ticket');
      expect(await anon('POST', '/api/t/stream'), '401 ');
      expect(await anon('GET', '/api/t/probe'), '200 probe');
      expect(await anon('POST', '/api/t/pair'), '200 pair');
      expect(await anon('GET', '/api/t/pair'), '401 ');
      expect(await anon('GET', '/api/t/other'), '401 ');
      final r = await _send(server, 'POST', '/api/t/stream');
      expect('${r.status} ${r.body}', '200 basic', reason: '带凭据走宽路由');
    });

    test('queryTicketOrCredential：票有效免 Basic，无效落到 Basic', () async {
      final FushiSyncServer server = await start(
        modules: <InterconnectHostModule>[
          _DeclaredModule(
            'query',
            routes: <InterconnectRoute>[
              _ok(
                const InterconnectPath.exact('/api/q'),
                methods: <String>{'GET'},
                trust: InterconnectTrust.queryTicketOrCredential(
                  (shelf.Request r) async =>
                      r.url.queryParameters['key'] == 'good',
                ),
                body: 'q',
              ),
            ],
          ),
        ],
      );
      Future<int> status(String path, {String? password}) async =>
          (await _send(server, 'GET', path, password: password)).status;
      expect(await status('/api/q?key=good'), 200);
      expect(await status('/api/q?key=bad'), 401);
      expect(await status('/api/q?key=bad', password: _token), 200);
    });
  });

  group('统一流票', () {
    late File audio;
    late FushiSyncServer server;

    setUp(() async {
      audio = File('${tmp.path}/track.flac')
        ..writeAsBytesSync(List<int>.generate(1000, (int i) => i % 256));
      server = await start(
        modules: <InterconnectHostModule>[
          _StreamModule(<String, File>{'uid-1': audio}),
        ],
      );
    });

    Future<Map<String, dynamic>> issue(String id, {String? password}) async {
      final res = await _send(
        server,
        'POST',
        kLibraryMediaStreamUrlPath,
        password: password ?? _token,
        json: <String, Object?>{'kind': 'musicTrack', 'id': id},
      );
      expect(res.status, 200, reason: res.body);
      return jsonDecode(res.body) as Map<String, dynamic>;
    }

    String pathOf(String url) {
      final Uri u = Uri.parse(url);
      return '${u.path}?${u.query}';
    }

    test('签发 → 免 Basic Range 取流 206 → 释放后 403', () async {
      final Map<String, dynamic> grant = await issue('uid-1');
      final String path = pathOf(grant['url'] as String);
      expect(path, startsWith('$kLibraryMediaStreamPath?token='));
      final ranged = await _send(
        server,
        'GET',
        path,
        password: null,
        headers: <String, String>{'range': 'bytes=10-19'},
      );
      expect(ranged.status, 206);
      expect(ranged.body.length, 10);
      expect(server.mediaStreamCount, 1);
      expect(server.videoStreamTokenCount, 0);

      final released = await _send(
        server,
        'POST',
        '$kLibraryMediaStreamReleasePath?ticket=${grant['ticket']}',
      );
      expect(released.status, 204);
      expect(server.mediaStreamCount, 0);
      final after = await _send(server, 'GET', path, password: null);
      expect(after.status, 403);
    });

    test('只有签发者能释放', () async {
      final Map<String, dynamic> grant = await issue('uid-1');
      final other = await _send(
        server,
        'POST',
        '$kLibraryMediaStreamReleasePath?ticket=${grant['ticket']}',
        password: _peerToken,
      );
      expect(other.status, 204);
      expect(server.mediaStreamCount, 1, reason: '别人的凭据释放不动');
    });

    test('签发凭据被吊销即作废（BUG-4393）', () async {
      final Map<String, dynamic> grant = await issue(
        'uid-1',
        password: _peerToken,
      );
      final String path = pathOf(grant['url'] as String);
      expect((await _send(server, 'GET', path, password: null)).status, 200);
      server.pairedPeerCredentialsProvider = () async => <String, String>{};
      server.invalidatePeerTokenCache();
      final revoked = await _send(server, 'GET', path, password: null);
      expect(revoked.status, 403);
      expect(revoked.body, 'Token revoked');
      expect(server.mediaStreamCount, 0);
    });

    test('未知 id 404、未知种类 / 没人提供的种类拒签、签发要 Basic', () async {
      expect(
        (await _send(
          server,
          'POST',
          kLibraryMediaStreamUrlPath,
          json: <String, Object?>{'kind': 'musicTrack', 'id': 'nope'},
        )).status,
        404,
      );
      expect(
        (await _send(
          server,
          'POST',
          kLibraryMediaStreamUrlPath,
          json: <String, Object?>{'kind': 'musicVideo', 'id': '1'},
        )).status,
        404,
      );
      expect(
        (await _send(
          server,
          'POST',
          kLibraryMediaStreamUrlPath,
          json: <String, Object?>{'kind': 'bogus', 'id': '1'},
        )).status,
        400,
      );
      expect(
        (await _send(
          server,
          'POST',
          kLibraryMediaStreamUrlPath,
          password: null,
          json: <String, Object?>{'kind': 'musicTrack', 'id': 'uid-1'},
        )).status,
        401,
      );
    });

    test('音乐票取不了视频，视频路径也不认音乐票', () async {
      final Map<String, dynamic> grant = await issue('uid-1');
      final video = await _send(
        server,
        'GET',
        '/api/library/videos/uid-1/stream?token=${grant['ticket']}',
        password: null,
      );
      expect(video.status, isNot(200));
      expect(video.status, isNot(206));
    });
  });

  group('LibraryMediaStreams', () {
    test('上限淘汰最旧者，TTL 过期清掉，onDrop 每张都回调', () {
      DateTime clock = DateTime(2026, 11, 23);
      final List<String> dropped = <String>[];
      final LibraryMediaStreams streams = LibraryMediaStreams(
        now: () => clock,
        capacity: 3,
        onDrop: dropped.add,
      );
      final List<String> tokens = <String>[];
      for (int i = 0; i < 4; i++) {
        clock = clock.add(const Duration(seconds: 1));
        tokens.add(
          streams.issue(
            kind: LibraryMediaStreamKind.musicTrack,
            id: 'u$i',
            issuer: 'f',
          ),
        );
      }
      expect(streams.length, 3);
      expect(streams.contains(tokens.first), isFalse);
      expect(dropped, <String>[tokens.first]);
      clock = clock.add(const Duration(hours: 7));
      streams.prune();
      expect(streams.length, 0);
      expect(dropped, hasLength(4));
    });

    test('release 只认同种类同 id，并连带附属票', () {
      final LibraryMediaStreams streams = LibraryMediaStreams(
        now: DateTime.now,
      );
      final String main = streams.issue(
        kind: LibraryMediaStreamKind.musicVideo,
        id: '7',
        issuer: 'f',
      );
      streams.issue(
        kind: LibraryMediaStreamKind.musicVideo,
        id: '7',
        issuer: 'f',
        ticket: main,
      );
      expect(
        streams.release(
          kind: LibraryMediaStreamKind.musicTrack,
          id: '7',
          ticket: main,
        ),
        isEmpty,
      );
      expect(
        streams.release(
          kind: LibraryMediaStreamKind.musicVideo,
          id: '7',
          ticket: main,
        ),
        hasLength(2),
      );
      expect(streams.length, 0);
    });

    test('同一种流只能注册一个解析器', () {
      final LibraryMediaStreams streams = LibraryMediaStreams(
        now: DateTime.now,
      );
      streams.registerResolver(
        LibraryMediaStreamKind.musicTrack,
        (LibraryMediaRequest _) async => null,
      );
      expect(
        () => streams.registerResolver(
          LibraryMediaStreamKind.musicTrack,
          (LibraryMediaRequest _) async => null,
        ),
        throwsStateError,
      );
    });
  });

  /// 服务器本体各文件的源码：文件名 → 内容。
  Map<String, String> serverFiles() => <String, String>{
    for (final File f in <File>[
      File('lib/sync/fushi_sync_server.dart'),
      for (final FileSystemEntity f in Directory(
        'lib/sync/fushi_sync_server',
      ).listSync())
        if (f is File && f.path.endsWith('.dart')) f,
    ])
      f.uri.pathSegments.last: f.readAsStringSync(),
  };

  test('守卫：服务器本体不手写路径分支，端点只经端点表登记', () {
    // 放宽名单：服务器本体里现存的每一处「拿路径做判断」，`文件: 原文片段` → 出现次数。A1 已把
    // `_handleRequest` 的一级分支全部迁完；名单里剩两类——
    //   · handler 在自己的前置门（库服务 null → 404 等）之后再按子路径分的**二级**分发。拆成独立路由要先
    //     给模块加「前置门 + 子路由 + 模块内兜底 404」的声明，不在 A1；
    //   · 与端点无关的文件系统路径判断（`canonicalFsPath`、`davPath`、解析结果判空），列在这里只因为正则
    //     分不出来。
    // 只列现存项、只减不增：新增一处即红；迁走一处也红，提醒从这里删掉。
    //
    // 正则认的写法：任何名字里带 path 的标识符做 `==` / `!=` / `.startsWith(` / `.endsWith(` / `.contains(`
    // / `switch (…)`，以及任何值与名字以 Path 结尾的标识符（路径常量）比较。换个不带 path 的变量名再拿
    // 字面量比，由下一条「`/api/` 字面量」守卫按文件计数卡住。两条都是词法棘轮，不是结构保证：二级分发
    // 迁进端点表之后它们才能整条删掉。
    const Map<String, int> notYetMigrated = <String, int>{
      'fushi_sync_server.dart: reqPath.startsWith(prefix': 1,
      'fushi_sync_server.dart: reqPath.endsWith(fullSuffix': 1,
      'fushi_sync_server.dart: path == null': 1,
      'fushi_sync_server.dart: canonicalFsPath != canonicalRoot': 1,
      "fushi_sync_server.dart: canonicalFsPath.startsWith('\$canonicalRoot\${p.separator}'":
          1,
      "fushi_sync_server.dart: reqPath.contains('/fushi-srs/'": 1,
      "fushi_sync_server.dart: reqPath.startsWith('/'": 2,
      'host_routes.part.dart: reqPath.startsWith(kSrsRemoteStoreV2PathPrefix':
          1,
      "library.part.dart: reqPath == '/api/library/dictionaries'": 1,
      "library.part.dart: reqPath == '/api/library/books'": 1,
      'library.part.dart: reqPath.startsWith(bookPrefix': 2,
      'library.part.dart: reqPath.endsWith(coverSuffix': 1,
      'library.part.dart: reqPath.endsWith(progressSuffix': 1,
      "library.part.dart: reqPath == '/api/library/localaudio'": 1,
      "library.part.dart: reqPath == '/api/library/audiobooks'": 1,
      'library.part.dart: reqPath.startsWith(audiobookPrefix': 3,
      'library.part.dart: reqPath.endsWith(positionSuffix': 1,
      'library.part.dart: reqPath.endsWith(delaySuffix': 1,
      'library.part.dart: reqPath.endsWith(subtitlesSuffix': 1,
      "lookup.part.dart: reqPath == '/api/lookup/dictionary'": 1,
      "lookup.part.dart: reqPath == '/api/lookup/dictionary/styles'": 1,
      "lookup.part.dart: reqPath == '/api/lookup/dictionary/media'": 1,
      "lookup.part.dart: reqPath == '/api/lookup/audio'": 1,
      "lookup.part.dart: reqPath == '/api/lookup/audio/list'": 1,
      "lookup.part.dart: reqPath == '/api/lookup/audio/file'": 1,
      'lookup.part.dart: path == null': 1,
      'lookup.part.dart: switch (path)': 1,
      'plugin_relay.part.dart: reqPath.startsWith(kInterconnectPluginRelayStreamPrefix':
          1,
      'plugin_relay.part.dart: reqPath == kInterconnectPluginRelayPath': 1,
      'plugin_relay.part.dart: reqPath != kInterconnectPluginRelayInvokePath':
          1,
      'plugin_relay.part.dart: reqPath != kInterconnectPluginRelayCoversPath':
          1,
      'plugin_relay.part.dart: reqPath != kInterconnectPluginRelayMediaPath': 1,
      'plugin_relay.part.dart: reqPath == kInterconnectPluginRelayInvokePath':
          1,
      'plugin_relay.part.dart: reqPath == kInterconnectPluginRelayCoversPath':
          1,
      'plugin_relay.part.dart: path.startsWith(kInterconnectPluginRelayStreamPrefix':
          1,
      'source_share.part.dart: reqPath == kInterconnectSourceSharePath': 1,
      "video.part.dart: reqPath == '/api/library/videos'": 1,
      "video.part.dart: reqPath.startsWith('/api/library/videos/'": 2,
      'video.part.dart: reqPath.startsWith(prefix': 1,
      'video.part.dart: reqPath.endsWith(suffix': 1,
      'video.part.dart: path.startsWith(prefix': 1,
      'video.part.dart: path.endsWith(suffix': 1,
      "video_metadata.part.dart: reqPath == '/api/library/metadata'": 1,
      "video_metadata.part.dart: reqPath == '/api/library/metadata/candidates'":
          1,
      "video_metadata.part.dart: reqPath == '/api/library/metadata/scrape'": 1,
      "video_metadata.part.dart: reqPath == '/api/library/metadata/episode-groups'":
          1,
      "video_metadata.part.dart: reqPath == '/api/library/metadata/episode-group'":
          1,
      "video_metadata.part.dart: reqPath.endsWith('/episode-groups'": 1,
      "webdav.part.dart: davPath.endsWith('/'": 1,
    };
    final RegExp branch = RegExp(
      r'\b\w*[Pp]ath\w*\s*[!=]=\s*[^\s;)|&,]+'
      r'|\b\w*[Pp]ath\w*\.(?:startsWith|endsWith|contains)\(\s*[^\s,)]+'
      r'|switch\s*\(\s*\w*[Pp]ath\w*\s*\)'
      r'|[!=]=\s*\w*[Pp]ath\b',
    );
    final Map<String, int> found = <String, int>{};
    serverFiles().forEach((String name, String source) {
      for (final RegExpMatch m in branch.allMatches(source)) {
        final String key =
            '$name: ${m.group(0)!.replaceAll(RegExp(r'\s+'), ' ')}';
        found[key] = (found[key] ?? 0) + 1;
      }
    });
    expect(
      found,
      notYetMigrated,
      reason: '路径分支一律写进端点表（InterconnectRoute）；放宽名单只减不增，迁走的要从名单删掉',
    );
  });

  test('守卫：`/api/` 路径字面量只在端点表里，其余文件按现存数只减不增', () {
    // 端点表（host_routes.part.dart）之外，服务器本体里现存的 `/api/` 字面量个数：都是上一条名单里那些
    // 二级分发和从路径里切 id 用的前缀。新端点的路径写进端点表，不在 handler 里再出现一次。
    const Map<String, int> literalsOutsideTable = <String, int>{
      'fushi_sync_server.dart': 2,
      'library.part.dart': 10,
      'lookup.part.dart': 8,
      'video.part.dart': 13,
      'video_metadata.part.dart': 5,
    };
    final RegExp literal = RegExp('[\'"]/api/');
    final Map<String, int> found = <String, int>{};
    serverFiles().forEach((String name, String source) {
      if (name == 'host_routes.part.dart') return;
      final int n = literal.allMatches(source).length;
      if (n > 0) found[name] = n;
    });
    expect(found, literalsOutsideTable, reason: '只减不增；减了要同步改小这里的数');
  });

  test('守卫：handler 里各判各的 TLS / 已配对设备 /「我的设备」门只减不增', () {
    // 「必须 HTTPS」「仅已配对设备」「仅我的设备」今天由各 handler 按各自的顺序和错误体判，端点表的信任级
    // 只管要不要 Basic。把它们收成路由上的声明（pairedPeer / ownerDevice / tlsRequired）要连判门顺序和
    // 错误体一起统一，会改 wire，属于 A2（docs/bugs/BUG-5298 的「剩余」段）。在那之前按现存次数卡住：
    // 新端点不许再手写一道，要先把声明式的门做出来。
    const Map<String, int> handlerGates = <String, int>{
      // 7 处 handler 内的「没开 TLS 就拒」。
      '_securityContext == null': 7,
      // 9 处调用 + 1 处定义。
      '_validatePeerAuth(': 10,
      'isOwnerDevicePeer(': 3,
    };
    final String all = serverFiles().values.join('\n');
    expect(<String, int>{
      for (final String gate in handlerGates.keys)
        gate: gate.allMatches(all).length,
    }, handlerGates);
  });

  test('守卫：免 Basic 的面逐条列名，多开一个即红', () {
    // 端点表里信任级不是 credential 的全部路由（从真实服务器的表派生）。urlTicket / pairingBootstrap /
    // reachabilityProbe 的门在各自的 handler 里，类型只保证「显式选了一种」，保证不了「门真的在」——所以
    // 新开一个免 Basic 的面必须过这里的人工复核：确认 handler 里有票据 / 配对窗口校验，再把它加进名单。
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: tmp.path,
      port: 0,
      token: _token,
    );
    final List<String> exempt = <String>[
      for (final (InterconnectHostModule m, InterconnectRoute r)
          in server.endpointTable.routes)
        if (r.trust is! InterconnectCredentialTrust)
          '${m.name}: ${(r.methods?.toList()?..sort())?.join('/') ?? '*'} '
              '${r.path} → ${r.trust}',
    ];
    expect(exempt, <String>[
      'lookup: GET/HEAD /api/lookup/audio/file → urlTicket(查词音频短时 id)',
      'lookup: GET/HEAD /api/media/dictionary → queryTicketOrCredential',
      'libraryVideos: GET /api/library/videos/**? → urlTicket(视频流 token)',
      'libraryDiscShare: GET /api/library/disc/* → urlTicket(原盘会话 token)',
      'libraryMediaStreams: GET/HEAD /api/library/media/stream → urlTicket(统一流票)',
      'pluginRelay: GET/HEAD /api/interconnect/plugin-relay/**? → urlTicket(插件中继流票)',
      'pairing: POST /api/pair → pairingBootstrap',
      'pairing: POST /api/pair/v2 → pairingBootstrap',
      'pairing: POST /api/pair/v2/confirm → pairingBootstrap',
      'pairing: GET /api/ping → reachabilityProbe',
    ]);
  });

  test('守卫：游戏串流的路径只登记在 GameStreamEndpoint，端点表与服务分发都从它派生', () {
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: tmp.path,
      port: 0,
      token: _token,
    );
    final InterconnectModuleTable table = server.endpointTable;
    for (final GameStreamEndpoint endpoint in GameStreamEndpoint.values) {
      final String sample = endpoint.isPrefix
          ? '${endpoint.path}s1/join'
          : endpoint.path;
      expect(GameStreamEndpoint.of(sample), endpoint);
      expect(
        table.lookup(sample, 'POST'),
        isA<InterconnectRouteHit>().having(
          (InterconnectRouteHit hit) => hit.module.name,
          'module',
          'gameStream',
        ),
        reason: sample,
      );
    }
    expect(
      table.routes
          .where(
            ((InterconnectHostModule, InterconnectRoute) e) =>
                e.$1.name == 'gameStream',
          )
          .length,
      GameStreamEndpoint.values.length,
      reason: '表里的串流路由一条不多、一条不少',
    );
    // 路径字面量不在别处再抄一份（服务内部的分发按枚举穷尽 switch，漏一个编不过）。
    final RegExp literal = RegExp('[\'"]/api/game-stream');
    final Map<String, int> found = <String, int>{};
    for (final FileSystemEntity f in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final int n = literal.allMatches(f.readAsStringSync()).length;
      if (n > 0) found[f.uri.pathSegments.last] = n;
    }
    expect(found, <String, int>{
      'game_stream_service.dart': GameStreamEndpoint.values.length,
    });
    expect(GameStreamEndpoint.carriesMineBody('/api/game-stream/mine'), isTrue);
    expect(
      GameStreamEndpoint.carriesMineBody('/api/game-stream/sessions/s1/mine'),
      isTrue,
    );
    expect(
      GameStreamEndpoint.carriesMineBody('/api/game-stream/sessions/s1/join'),
      isFalse,
    );
    expect(GameStreamEndpoint.carriesMineBody('/api/library/mine'), isFalse);
  });

  test('守卫：服务器本体不再持有已迁进模块层的功能的处理函数 / 字段', () {
    final String server = serverFiles().values.join('\n');
    for (final String banned in <String>[
      'kTorrentEngineRoutePrefix',
      // 免 Basic 表与能力位手拼段已并进端点表。
      '_kPublicRoutes',
      '_capabilitiesBase',
      'handleMangaOcrRequest(',
      'handleHostJobRequest(',
      'handleHostDownloadRequest(',
      'handleHostTorrentEngineRequest(',
      'handleHostAssistantRequest(',
      'handleHostSubscriptionRequest(',
      'HostAssistantSessions? _assistant',
      'HostJobManager? _hostJobs',
      '_VideoStreamToken> _videoStreamTokens',
    ]) {
      expect(server.contains(banned), isFalse, reason: banned);
    }
  });
}
