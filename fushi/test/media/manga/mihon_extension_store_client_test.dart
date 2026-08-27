import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/utils/net/github_mirrors.dart';

void main() {
  group('Mihon extension repositories', () {
    test('parses current JSON including an embedded extension list', () async {
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        client: MockClient((http.Request request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'name': 'Fixture repository',
              'badgeLabel': 'Fixture',
              'signingKey': 'AA:BB',
              'contact': <String, Object?>{
                'website': 'https://repo.example/about',
              },
              'extensionList': <String, Object?>{
                'extensions': <Object?>[
                  <String, Object?>{
                    'name': 'Fixture extension',
                    'packageName': 'org.example.fixture',
                    'resources': <String, Object?>{
                      'apkUrl': 'apk/fixture.apk',
                      'iconUrl': 'icons/fixture.png',
                    },
                    'extensionLib': '1.6',
                    'versionCode': 7,
                    'versionName': '1.6.7',
                    'contentWarning': 'CONTENT_WARNING_SAFE',
                    'sources': <Object?>[
                      <String, Object?>{
                        'id': '9223372036854775807',
                        'name': 'Fixture source',
                        'language': 'en',
                        'homeUrl': 'https://source.example',
                      },
                    ],
                  },
                ],
              },
            }),
            HttpStatus.ok,
          );
        }),
      );
      addTearDown(client.close);

      final MihonStoreFetchResult result =
          await client.fetchStore('https://repo.example/index.json');
      final MihonStore store = result.store!;
      final List<MihonAvailableExtension> extensions =
          await client.fetchExtensions(store);

      expect(store.format, MihonStoreFormat.currentJson);
      expect(store.signingKey, 'AA:BB');
      expect(extensions.single.apkUrl, 'https://repo.example/apk/fixture.apk');
      expect(extensions.single.sources.single.id, '9223372036854775807');
    });

    test('parses protobuf and keeps a 64-bit source id as a string', () async {
      const int sourceId = 9007199254740993;
      final Uint8List source = _message(<List<int>>[
        _varintField(1, sourceId),
        _stringField(2, 'Proto source'),
        _stringField(3, 'ja'),
        _stringField(4, 'https://source.example'),
      ]);
      final Uint8List resources = _message(<List<int>>[
        _stringField(1, 'apk/proto.apk'),
        _stringField(2, 'icon/proto.png'),
      ]);
      final Uint8List extension = _message(<List<int>>[
        _stringField(1, 'Proto extension'),
        _stringField(2, 'org.example.proto'),
        _bytesField(3, resources),
        _stringField(4, '1.6'),
        _varintField(5, 12),
        _stringField(6, '1.6.12'),
        _varintField(7, 1),
        _bytesField(8, source),
      ]);
      final Uint8List extensionList =
          _message(<List<int>>[_bytesField(1, extension)]);
      final Uint8List repository = _message(<List<int>>[
        _stringField(1, 'Proto repository'),
        _stringField(2, 'Proto'),
        _stringField(3, 'aabbccdd'),
        _bytesField(101, extensionList),
      ]);
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        client: MockClient(
          (http.Request request) async =>
              http.Response.bytes(repository, HttpStatus.ok),
        ),
      );
      addTearDown(client.close);

      final MihonStore store =
          (await client.fetchStore('https://repo.example/index.proto')).store!;
      final MihonAvailableExtension extensionResult =
          (await client.fetchExtensions(store)).single;

      expect(store.format, MihonStoreFormat.currentProtobuf);
      expect(extensionResult.packageName, 'org.example.proto');
      expect(extensionResult.sources.single.id, '$sourceId');
    });

    test('supports gzip legacy repo.json and index.min.json', () async {
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        client: MockClient((http.Request request) async {
          if (request.url.path.endsWith('/repo.json')) {
            return http.Response.bytes(
              gzip.encode(utf8.encode(jsonEncode(<String, Object?>{
                'meta': <String, Object?>{
                  'name': 'Legacy repository',
                  'shortName': 'Legacy',
                  'signingKeyFingerprint': '',
                },
              }))),
              HttpStatus.ok,
            );
          }
          return http.Response.bytes(
            gzip.encode(utf8.encode(jsonEncode(<Object?>[
              <String, Object?>{
                'name': 'Tachiyomi: Legacy fixture',
                'pkg': 'org.example.legacy',
                'apk': 'legacy.apk',
                'lang': 'en',
                'code': 3,
                'version': '1.4.3',
                'nsfw': 0,
                'sources': <Object?>[],
              },
            ]))),
            HttpStatus.ok,
          );
        }),
      );
      addTearDown(client.close);

      final MihonStore store =
          (await client.fetchStore('https://legacy.example/index.min.json'))
              .store!;
      final MihonAvailableExtension extension =
          (await client.fetchExtensions(store)).single;

      expect(store.format, MihonStoreFormat.legacy);
      expect(extension.name, 'Legacy fixture');
      expect(extension.apkUrl, 'https://legacy.example/apk/legacy.apk');
    });

    test('follows validated redirects and rejects HTTPS downgrade', () async {
      final String repository = jsonEncode(<String, Object?>{
        'name': 'Redirect repository',
        'badgeLabel': 'Redirect',
        'signingKey': 'aabb',
        'extensionList': <String, Object?>{'extensions': <Object?>[]},
      });
      final MihonExtensionStoreClient allowed = MihonExtensionStoreClient(
        client: MockClient((http.Request request) async {
          if (request.url.path == '/start') {
            return http.Response(
              '',
              HttpStatus.found,
              headers: <String, String>{'location': '/final'},
            );
          }
          return http.Response(repository, HttpStatus.ok);
        }),
      );
      addTearDown(allowed.close);
      expect(
        (await allowed.fetchStore('https://repo.example/start')).store!.name,
        'Redirect repository',
      );

      final MihonExtensionStoreClient downgraded = MihonExtensionStoreClient(
        client: MockClient(
          (http.Request request) async => http.Response(
            '',
            HttpStatus.found,
            headers: <String, String>{
              'location': 'http://repo.example/final',
            },
          ),
        ),
      );
      addTearDown(downgraded.close);
      await expectLater(
        downgraded.fetchStore('https://repo.example/start'),
        throwsA(
          isA<MihonRuntimeException>().having(
              (MihonRuntimeException e) => e.code, 'code', 'INSECURE_URL'),
        ),
      );
    });

    test('requires signingKey for current repositories', () async {
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        client: MockClient(
          (http.Request request) async => http.Response(
            jsonEncode(<String, Object?>{
              'name': 'Unsigned',
              'badgeLabel': 'Unsigned',
            }),
            HttpStatus.ok,
          ),
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.fetchStore('https://repo.example/index.json'),
        throwsA(
          isA<MihonRuntimeException>().having(
              (MihonRuntimeException e) => e.code, 'code', 'INVALID_STORE'),
        ),
      );
    });

    test('enforces declared and gzip-expanded 10 MiB limits', () async {
      final MihonExtensionStoreClient declared = MihonExtensionStoreClient(
        client: MockClient(
          (http.Request request) async => http.Response(
            '{}',
            HttpStatus.ok,
            headers: <String, String>{
              HttpHeaders.contentLengthHeader: '${mihonStoreMaxBytes + 1}',
            },
          ),
        ),
      );
      addTearDown(declared.close);
      await expectLater(
        declared.fetchStore('https://repo.example/index.json'),
        throwsA(
          isA<MihonRuntimeException>().having(
            (MihonRuntimeException e) => e.code,
            'code',
            'DOWNLOAD_TOO_LARGE',
          ),
        ),
      );

      final Uint8List compressed = Uint8List.fromList(
        gzip.encode(Uint8List(mihonStoreMaxBytes + 1)),
      );
      final MihonExtensionStoreClient expanded = MihonExtensionStoreClient(
        client: MockClient(
          (http.Request request) async =>
              http.Response.bytes(compressed, HttpStatus.ok),
        ),
      );
      addTearDown(expanded.close);
      await expectLater(
        expanded.fetchStore('https://repo.example/index.pb.gz'),
        throwsA(
          isA<MihonRuntimeException>().having(
            (MihonRuntimeException e) => e.code,
            'code',
            'DOWNLOAD_TOO_LARGE',
          ),
        ),
      );
    });

    // BUG: 数组分支（用户填 `/index.min.json`）拿到 `repo.json` 后曾经把 `index_v2`
    // 整个忽略，只有对象分支跟随。keiyoushi 已迁到 `index_v2`，旧数组索引只剩占位
    // 条目，据此推出的 `apk/` 直链在仓库里不存在 —— 装什么都 `STORE_HTTP_404`。
    test('follows index_v2 from a legacy index.min.json entry point', () async {
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        client: MockClient((http.Request request) async {
          if (request.url.path.endsWith('/repo.json')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'index_v2': 'https://legacy.example/index.json',
                'meta': <String, Object?>{
                  'name': 'Legacy repository',
                  'shortName': 'Legacy',
                  'signingKeyFingerprint': 'aabb',
                },
              }),
              HttpStatus.ok,
            );
          }
          if (request.url.path.endsWith('/index.json')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'name': 'Migrated repository',
                'badgeLabel': 'Migrated',
                'signingKey': 'aabb',
                'extensionList': <String, Object?>{
                  'extensions': <Object?>[
                    <String, Object?>{
                      'name': 'Migrated extension',
                      'packageName': 'org.example.migrated',
                      'resources': <String, Object?>{
                        'apkUrl': 'https://cdn.example/releases/migrated.apk',
                        'iconUrl': 'icons/migrated.png',
                      },
                      'extensionLib': '1.6',
                      'versionCode': 9,
                      'versionName': '1.6.9',
                      'contentWarning': 'CONTENT_WARNING_SAFE',
                      'sources': <Object?>[],
                    },
                  ],
                },
              }),
              HttpStatus.ok,
            );
          }
          return http.Response(
            jsonEncode(<Object?>[
              <String, Object?>{
                'name': 'Outdated App',
                'pkg': 'org.example.stub',
                'apk': 'stub.apk',
                'lang': 'all',
                'code': 1,
                'version': '1.4.1',
                'nsfw': 0,
                'sources': <Object?>[],
              },
            ]),
            HttpStatus.ok,
          );
        }),
      );
      addTearDown(client.close);

      final MihonStore store =
          (await client.fetchStore('https://legacy.example/index.min.json'))
              .store!;
      final List<MihonAvailableExtension> extensions =
          await client.fetchExtensions(store);

      expect(store.format, MihonStoreFormat.currentJson);
      expect(store.indexUrl, 'https://legacy.example/index.json');
      expect(
        extensions.single.apkUrl,
        'https://cdn.example/releases/migrated.apk',
      );
    });

    // `index_v2` 是仓库方自由填的地址，可以指回一个 `index.min.json` 形成环。
    test('stops an index_v2 loop instead of recursing forever', () async {
      int requests = 0;
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        client: MockClient((http.Request request) async {
          requests += 1;
          if (request.url.path.endsWith('/repo.json')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'index_v2': 'https://loop.example/index.min.json',
                'meta': <String, Object?>{'name': 'Loop repository'},
              }),
              HttpStatus.ok,
            );
          }
          return http.Response(jsonEncode(<Object?>[]), HttpStatus.ok);
        }),
      );
      addTearDown(client.close);

      await expectLater(
        client.fetchStore('https://loop.example/index.min.json'),
        throwsA(
          isA<MihonRuntimeException>().having(
            (MihonRuntimeException e) => e.code,
            'code',
            'TOO_MANY_INDEX_HOPS',
          ),
        ),
      );
      expect(requests, lessThan(10));
    });

    // 报错必须说清是哪个地址 404 了，但不能把 release 资产 302 过去的签名 query
    // （`sig=` / `jwt=`）写进文案 —— 那会进 UI 和上传的日志。
    test('names the failing URL without leaking signed query', () async {
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        client: MockClient((http.Request request) async {
          if (request.url.query.isEmpty) {
            return http.Response(
              '',
              HttpStatus.found,
              headers: <String, String>{
                HttpHeaders.locationHeader:
                    'https://cdn.example/asset.apk?sig=SECRET&jwt=SECRET',
              },
            );
          }
          return http.Response('', HttpStatus.notFound);
        }),
      );
      addTearDown(client.close);

      await expectLater(
        client.downloadApk('https://repo.example/releases/missing.apk'),
        throwsA(
          isA<MihonRuntimeException>()
              .having(
                (MihonRuntimeException e) => e.code,
                'code',
                'STORE_HTTP_404',
              )
              .having(
                (MihonRuntimeException e) => e.message,
                'message',
                allOf(
                  contains('https://cdn.example/asset.apk'),
                  isNot(contains('SECRET')),
                ),
              ),
        ),
      );
    });
  });

  // BUG-1875：仓库索引 / 扩展列表 / APK 几乎全在 GitHub raw / release 直链上，GFW
  // 机器直连 github.com 吃满 20s 连接超时后整轮失败，而 app 早有一份对这类直链有效
  // 的镜像名单从没在这里用上。
  group('GitHub mirror fallback', () {
    const String direct = 'https://github.com/o/r/raw/repo/index.json';
    const String firstMirror = 'https://ghfast.top/$direct';
    final String repository = jsonEncode(<String, Object?>{
      'name': 'Mirrored repository',
      'badgeLabel': 'Mirror',
      'signingKey': 'aabb',
      'extensionList': <String, Object?>{'extensions': <Object?>[]},
    });

    test('direct socket failure → first mirror serves the index', () async {
      final List<String> requested = <String>[];
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        client: MockClient((http.Request request) async {
          requested.add(request.url.toString());
          if (request.url.toString() == direct) {
            throw const SocketException('HTTP connection timed out');
          }
          if (request.url.toString() == firstMirror) {
            return http.Response(repository, HttpStatus.ok);
          }
          fail('unexpected request ${request.url}');
        }),
      );
      addTearDown(client.close);

      final MihonStoreFetchResult result = await client.fetchStore(direct);

      expect(result.store!.name, 'Mirrored repository');
      expect(requested, <String>[direct, firstMirror]);
    });

    test('http.ClientException from IOClient also counts as transport failure',
        () async {
      final List<String> requested = <String>[];
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        client: MockClient((http.Request request) async {
          requested.add(request.url.toString());
          if (request.url.toString() == direct) {
            throw http.ClientException('connection closed', request.url);
          }
          return http.Response(repository, HttpStatus.ok);
        }),
      );
      addTearDown(client.close);

      expect(
        (await client.fetchStore(direct)).store!.name,
        'Mirrored repository',
      );
      expect(requested, <String>[direct, firstMirror]);
    });

    test('a mirror that answers 404 is skipped, the next mirror still serves',
        () async {
      // 公共 gh 代理对存在的资源乱返 404/403 是常态：镜像的 HTTP 错误只是
      // 「换下一个」，不能像直连 404 那样被当成权威结论。
      const String secondMirror = 'https://gh-proxy.com/$direct';
      final List<String> requested = <String>[];
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        client: MockClient((http.Request request) async {
          requested.add(request.url.toString());
          if (request.url.toString() == direct) {
            throw const SocketException('HTTP connection timed out');
          }
          if (request.url.toString() == firstMirror) {
            return http.Response('', HttpStatus.notFound);
          }
          if (request.url.toString() == secondMirror) {
            return http.Response(repository, HttpStatus.ok);
          }
          fail('unexpected request ${request.url}');
        }),
      );
      addTearDown(client.close);

      expect(
        (await client.fetchStore(direct)).store!.name,
        'Mirrored repository',
      );
      expect(requested, <String>[direct, firstMirror, secondMirror]);
    });

    test('direct 404 is final — mirrors are never asked', () async {
      final List<String> requested = <String>[];
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        client: MockClient((http.Request request) async {
          requested.add(request.url.toString());
          return http.Response('', HttpStatus.notFound);
        }),
      );
      addTearDown(client.close);

      await expectLater(
        client.fetchStore(direct),
        throwsA(
          isA<MihonRuntimeException>().having(
            (MihonRuntimeException e) => e.code,
            'code',
            'STORE_HTTP_404',
          ),
        ),
      );
      expect(requested, <String>[direct]);
    });

    test('non-GitHub host has no mirrors: failure propagates after 1 request',
        () async {
      int requests = 0;
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        client: MockClient((http.Request request) async {
          requests += 1;
          throw const SocketException('unreachable');
        }),
      );
      addTearDown(client.close);

      await expectLater(
        client.fetchStore('https://repo.example/index.json'),
        throwsA(isA<SocketException>()),
      );
      expect(requests, 1);
    });

    test('every candidate down → the direct error is rethrown, not the last',
        () async {
      final List<String> requested = <String>[];
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        client: MockClient((http.Request request) async {
          requested.add(request.url.toString());
          if (request.url.toString() == direct) {
            throw const SocketException('direct timed out');
          }
          throw SocketException('Failed host lookup: ${request.url.host}');
        }),
      );
      addTearDown(client.close);

      await expectLater(
        client.fetchStore(direct),
        throwsA(
          isA<SocketException>().having(
            (SocketException e) => e.message,
            'message',
            'direct timed out',
          ),
        ),
      );
      expect(requested.length, 1 + kGitHubMirrorPrefixes.length);
      expect(requested.first, direct);
    });

    test('the total fetch budget stops the mirror walk early', () async {
      final List<String> requested = <String>[];
      DateTime clock = DateTime(2026, 1, 1);
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        fetchBudget: const Duration(seconds: 45),
        now: () => clock,
        client: MockClient((http.Request request) async {
          requested.add(request.url.toString());
          clock = clock.add(const Duration(seconds: 20)); // 每次尝试烧掉 20s
          throw const SocketException('direct timed out');
        }),
      );
      addTearDown(client.close);

      await expectLater(
        client.fetchStore(direct),
        throwsA(
          isA<SocketException>().having(
            (SocketException e) => e.message,
            'message',
            'direct timed out',
          ),
        ),
      );
      // 预算 45s、每次烧 20s：直连 + 2 个镜像后过点，剩下的镜像不再尝试——
      // 没有总闸时这里会是 1 + 5 个镜像全轮一遍。
      expect(requested.length, 3);
      expect(requested.first, direct);
    });

    test('302 hop to raw.githubusercontent.com gets its own fallback',
        () async {
      const String rawDirect =
          'https://raw.githubusercontent.com/o/r/repo/index.json';
      const String rawMirror = 'https://ghfast.top/$rawDirect';
      final List<String> requested = <String>[];
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        client: MockClient((http.Request request) async {
          requested.add(request.url.toString());
          switch (request.url.toString()) {
            case direct:
              return http.Response(
                '',
                HttpStatus.found,
                headers: <String, String>{
                  HttpHeaders.locationHeader: rawDirect,
                },
              );
            case rawDirect:
              throw TimeoutException('no bytes');
            case rawMirror:
              return http.Response(repository, HttpStatus.ok);
          }
          fail('unexpected request ${request.url}');
        }),
      );
      addTearDown(client.close);

      expect(
        (await client.fetchStore(direct)).store!.name,
        'Mirrored repository',
      );
      expect(requested, <String>[direct, rawDirect, rawMirror]);
    });

    test('downloadApk inherits the same fallback', () async {
      const String apk = 'https://github.com/o/r/releases/download/v1/x.apk';
      const String apkMirror = 'https://ghfast.top/$apk';
      final List<String> requested = <String>[];
      final MihonExtensionStoreClient client = MihonExtensionStoreClient(
        client: MockClient((http.Request request) async {
          requested.add(request.url.toString());
          if (request.url.toString() == apk) {
            throw const SocketException('HTTP connection timed out');
          }
          return http.Response.bytes(<int>[1, 2, 3], HttpStatus.ok);
        }),
      );
      addTearDown(client.close);

      expect(await client.downloadApk(apk), <int>[1, 2, 3]);
      expect(requested, <String>[apk, apkMirror]);
    });
  });
}

Uint8List _message(List<List<int>> fields) =>
    Uint8List.fromList(fields.expand((List<int> field) => field).toList());

List<int> _stringField(int number, String value) =>
    _bytesField(number, utf8.encode(value));

List<int> _bytesField(int number, List<int> value) => <int>[
      ..._varint((number << 3) | 2),
      ..._varint(value.length),
      ...value,
    ];

List<int> _varintField(int number, int value) => <int>[
      ..._varint(number << 3),
      ..._varint(value),
    ];

List<int> _varint(int value) {
  final List<int> result = <int>[];
  int remaining = value;
  do {
    int byte = remaining & 0x7f;
    remaining >>= 7;
    if (remaining != 0) byte |= 0x80;
    result.add(byte);
  } while (remaining != 0);
  return result;
}
