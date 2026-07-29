import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';

void main() {
  group('Mihon extension repositories', () {
    test('rejects literal loopback and private hosts before transport',
        () async {
      for (final String rawUrl in <String>[
        'http://127.0.0.1/index.json',
        'https://10.0.0.8/index.json',
      ]) {
        int sends = 0;
        final MihonExtensionStoreClient client = _testStoreClient(
          client: MockClient((http.Request request) async {
            sends++;
            return http.Response(
              jsonEncode(<String, Object?>{
                'name': 'Unsafe fixture',
                'badgeLabel': 'Unsafe',
                'signingKey': 'aabb',
                'extensionList': <String, Object?>{
                  'extensions': <Object?>[],
                },
              }),
              HttpStatus.ok,
            );
          }),
        );
        addTearDown(client.close);

        Object? failure;
        try {
          await client.fetchStore(rawUrl, allowInsecure: true);
        } on Object catch (error) {
          failure = error;
        }
        expect(
          failure,
          isA<MihonRuntimeException>().having(
            (MihonRuntimeException error) => error.code,
            'code',
            'UNSAFE_NETWORK_TARGET',
          ),
          reason: 'transport sends for $rawUrl: $sends',
        );
        expect(sends, 0, reason: 'must reject $rawUrl before transport');
      }
    });

    test('rejects a redirect to metadata before the second transport',
        () async {
      final List<Uri> requests = <Uri>[];
      final MihonExtensionStoreClient client = _testStoreClient(
        client: MockClient((http.Request request) async {
          requests.add(request.url);
          if (request.url.host == 'repo.example') {
            return http.Response(
              '',
              HttpStatus.found,
              headers: <String, String>{
                HttpHeaders.locationHeader:
                    'http://169.254.169.254/latest/meta-data',
              },
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'name': 'Metadata fixture',
              'badgeLabel': 'Metadata',
              'signingKey': 'aabb',
              'extensionList': <String, Object?>{
                'extensions': <Object?>[],
              },
            }),
            HttpStatus.ok,
          );
        }),
      );
      addTearDown(client.close);

      Object? failure;
      try {
        await client.fetchStore(
          'https://repo.example/start',
          allowInsecure: true,
        );
      } on Object catch (error) {
        failure = error;
      }
      expect(
        failure,
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException error) => error.code,
          'code',
          'UNSAFE_NETWORK_TARGET',
        ),
        reason: 'transport requests: $requests',
      );
      expect(
        requests,
        <Uri>[Uri.parse('https://repo.example/start')],
      );
    });

    test('rejects link-local, mapped, ULA, metadata, and numeric aliases',
        () async {
      for (final String rawUrl in <String>[
        'https://169.254.169.254/latest/meta-data',
        'https://[::ffff:127.0.0.1]/index.json',
        'https://[fc00::1]/index.json',
        'https://metadata.google.internal/computeMetadata/v1',
        'http://2130706433/index.json',
        'http://0177.0.0.1/index.json',
      ]) {
        int sends = 0;
        final MihonExtensionStoreClient client = _testStoreClient(
          client: MockClient((http.Request request) async {
            sends++;
            return http.Response('{}', HttpStatus.ok);
          }),
        );
        addTearDown(client.close);

        await expectLater(
          client.fetchStore(rawUrl, allowInsecure: true),
          throwsA(
            isA<MihonRuntimeException>().having(
              (MihonRuntimeException error) => error.code,
              'code',
              'UNSAFE_NETWORK_TARGET',
            ),
          ),
          reason: rawUrl,
        );
        expect(sends, 0, reason: rawUrl);
      }
    });

    test('rejects a private DNS answer before transport', () async {
      int sends = 0;
      final MihonExtensionStoreClient client = _testStoreClient(
        client: MockClient((http.Request request) async {
          sends++;
          return http.Response('{}', HttpStatus.ok);
        }),
        resolver: (String host) async =>
            <InternetAddress>[InternetAddress('192.168.1.8')],
      );
      addTearDown(client.close);

      await expectLater(
        client.fetchStore('https://repo.example/index.json'),
        throwsA(
          isA<MihonRuntimeException>().having(
            (MihonRuntimeException error) => error.code,
            'code',
            'UNSAFE_NETWORK_TARGET',
          ),
        ),
      );
      expect(sends, 0);
    });

    test('rejects DNS rebinding when the connected peer is private', () async {
      int sends = 0;
      final MihonExtensionStoreClient client = _testStoreClient(
        client: MockClient((http.Request request) async {
          sends++;
          return http.Response('{}', HttpStatus.ok);
        }),
        resolver: (String host) async =>
            <InternetAddress>[InternetAddress('93.184.216.34')],
        connectedPeer: (http.StreamedResponse response) =>
            InternetAddress('127.0.0.1'),
      );
      addTearDown(client.close);

      await expectLater(
        client.fetchStore('https://repo.example/index.json'),
        throwsA(
          isA<MihonRuntimeException>().having(
            (MihonRuntimeException error) => error.code,
            'code',
            'UNSAFE_NETWORK_TARGET',
          ),
        ),
      );
      expect(sends, 1, reason: 'peer is known only after transport connects');
    });

    test('rejects proxy-backed injected transports', () async {
      int sends = 0;
      final MihonExtensionStoreClient client = _testStoreClient(
        client: MockClient((http.Request request) async {
          sends++;
          return http.Response('{}', HttpStatus.ok);
        }),
        proxyDetected: (http.StreamedResponse response) => true,
      );
      addTearDown(client.close);

      await expectLater(
        client.fetchStore('https://repo.example/index.json'),
        throwsA(
          isA<MihonRuntimeException>().having(
            (MihonRuntimeException error) => error.code,
            'code',
            'UNSAFE_NETWORK_PROXY',
          ),
        ),
      );
      expect(sends, 1);
    });

    test('manual redirects disable transport redirects on every hop', () async {
      final List<bool> followRedirects = <bool>[];
      final List<Uri> requests = <Uri>[];
      final MihonExtensionStoreClient client = _testStoreClient(
        client: MockClient((http.Request request) async {
          followRedirects.add(request.followRedirects);
          requests.add(request.url);
          if (request.url.path.endsWith('/start')) {
            return http.Response(
              '',
              HttpStatus.found,
              headers: <String, String>{
                HttpHeaders.locationHeader: '../repo/final.json',
              },
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'name': 'Public HTTP fixture',
              'badgeLabel': 'Public',
              'signingKey': 'aabb',
              'extensionList': <String, Object?>{
                'extensions': <Object?>[],
              },
            }),
            HttpStatus.ok,
          );
        }),
      );
      addTearDown(client.close);

      final MihonStore store = (await client.fetchStore(
        'http://repo.example/root/start',
        allowInsecure: true,
      ))
          .store!;

      expect(store.name, 'Public HTTP fixture');
      expect(followRedirects, <bool>[false, false]);
      expect(
        requests,
        <Uri>[
          Uri.parse('http://repo.example/root/start'),
          Uri.parse('http://repo.example/repo/final.json'),
        ],
      );
    });

    test('parses current JSON including an embedded extension list', () async {
      final MihonExtensionStoreClient client = _testStoreClient(
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
      final MihonExtensionStoreClient client = _testStoreClient(
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
      final MihonExtensionStoreClient client = _testStoreClient(
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
      final MihonExtensionStoreClient allowed = _testStoreClient(
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

      final MihonExtensionStoreClient downgraded = _testStoreClient(
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
      final MihonExtensionStoreClient client = _testStoreClient(
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
      final MihonExtensionStoreClient declared = _testStoreClient(
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
      final MihonExtensionStoreClient expanded = _testStoreClient(
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
  });
}

MihonExtensionStoreClient _testStoreClient({
  required http.Client client,
  MihonHostResolver? resolver,
  MihonConnectedPeer? connectedPeer,
  MihonProxyDetector? proxyDetected,
}) =>
    MihonExtensionStoreClient(
      client: client,
      resolver: resolver ??
          (String host) async =>
              <InternetAddress>[InternetAddress('93.184.216.34')],
      connectedPeer: connectedPeer ??
          (http.StreamedResponse response) => InternetAddress('93.184.216.34'),
      proxyDetected: proxyDetected ?? (http.StreamedResponse response) => false,
    );

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
