import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_repository_client.dart';

void main() {
  test('normalizes repository homepages and GitHub project URLs', () {
    expect(
      AidokuRepositoryClient.normalizeRepositoryUri(
        'https://aidoku-community.github.io/sources',
      ).toString(),
      'https://aidoku-community.github.io/sources/index.min.json',
    );
    expect(
      AidokuRepositoryClient.normalizeRepositoryUri(
        'https://github.com/Aidoku-Community/sources',
      ).toString(),
      'https://aidoku-community.github.io/sources/index.min.json',
    );
  });

  test('parses the Aidoku 0.7 repository schema and relative URLs', () async {
    final AidokuRepositoryClient client = AidokuRepositoryClient(
      client: MockClient((http.Request request) async {
        expect(
          request.url.toString(),
          'https://example.com/repo/index.min.json',
        );
        return http.Response(
          jsonEncode(<String, Object?>{
            'name': 'Example Sources',
            'sources': <Object?>[
              <String, Object?>{
                'id': 'en.example',
                'name': 'Example',
                'version': 3,
                'languages': <Object?>['en'],
                'downloadURL': 'sources/en.example-v3.aix',
                'iconURL': 'icons/en.example-v3.png',
                'baseURL': 'https://manga.example',
                'minAppVersion': '0.8.0',
                'contentRating': 1,
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    final AidokuRepositoryIndex index =
        await client.fetch('https://example.com/repo');

    expect(index.name, 'Example Sources');
    expect(index.sources, hasLength(1));
    expect(index.sources.single.id, 'en.example');
    expect(index.sources.single.version, 3);
    expect(
      index.sources.single.downloadUri.toString(),
      'https://example.com/repo/sources/en.example-v3.aix',
    );
    expect(
      index.sources.single.iconUri.toString(),
      'https://example.com/repo/icons/en.example-v3.png',
    );
    client.close();
  });

  test('rejects non-HTTPS repositories before making a request', () async {
    final AidokuRepositoryClient client = AidokuRepositoryClient(
      client: MockClient((http.Request request) async {
        fail('HTTP repositories must be rejected before this request');
      }),
    );

    await expectLater(
      client.fetch('http://example.com/repo'),
      throwsA(
        isA<AidokuRepositoryException>().having(
          (AidokuRepositoryException error) => error.code,
          'code',
          'INSECURE_URL',
        ),
      ),
    );
    client.close();
  });

  test('rejects a repository redirect that downgrades to HTTP', () async {
    final AidokuRepositoryClient client = AidokuRepositoryClient(
      client: MockClient((http.Request request) async {
        expect(request.url.scheme, 'https');
        return http.Response(
          '',
          302,
          headers: <String, String>{
            'location': 'http://example.com/insecure/index.min.json',
          },
        );
      }),
    );

    await expectLater(
      client.fetch('https://example.com/repository'),
      throwsA(
        isA<AidokuRepositoryException>().having(
          (AidokuRepositoryException error) => error.code,
          'code',
          'INSECURE_URL',
        ),
      ),
    );
    client.close();
  });

  test('streams a repository package to a bounded local file', () async {
    final AidokuRepositoryClient client = AidokuRepositoryClient(
      client: MockClient((http.Request request) async {
        return http.Response.bytes(<int>[1, 2, 3, 4], 200);
      }),
    );
    final Directory root =
        await Directory.systemTemp.createTemp('fushi-aidoku-download-test-');
    addTearDown(() async => root.delete(recursive: true));
    final AidokuRepositorySource source = AidokuRepositorySource(
      id: 'en.example',
      name: 'Example',
      version: 1,
      languages: const <String>['en'],
      downloadUri: Uri.parse('https://example.com/source.aix'),
    );

    final File downloaded =
        await client.download(source, File('${root.path}/source.aix'));

    expect(await downloaded.readAsBytes(), <int>[1, 2, 3, 4]);
    client.close();
  });
}
