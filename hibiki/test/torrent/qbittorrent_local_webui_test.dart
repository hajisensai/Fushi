import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/torrent/qbittorrent_client.dart';

void main() {
  test('qB WebUI contract works through the real local HTTP stack', () async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final List<String> requests = <String>[];
    final List<Map<String, String>> forms = <Map<String, String>>[];

    final Future<void> serving = () async {
      await for (final HttpRequest request in server) {
        requests.add(request.uri.path);
        if (request.method == 'POST') {
          final String body = await utf8.decoder.bind(request).join();
          forms.add(Uri.splitQueryString(body));
        }
        final HttpResponse response = request.response;
        switch (request.uri.path) {
          case '/api/v2/auth/login':
            response
              ..statusCode = HttpStatus.ok
              ..headers.add(HttpHeaders.setCookieHeader, 'SID=local-test')
              ..write('Ok.');
          case '/api/v2/app/version':
            expect(request.headers.value(HttpHeaders.cookieHeader),
                contains('SID=local-test'));
            response
              ..statusCode = HttpStatus.ok
              ..write('v5.0.4');
          case '/api/v2/torrents/createCategory':
            response.statusCode = HttpStatus.ok;
          case '/api/v2/torrents/add':
            response
              ..statusCode = HttpStatus.ok
              ..write('Ok.');
          case '/api/v2/torrents/info':
            response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(jsonEncode(<Map<String, Object>>[
                <String, Object>{
                  'hash': 'abc123',
                  'name': 'Example Show 02',
                  'progress': 0.5,
                  'state': 'downloading',
                  'save_path': r'C:\Downloads',
                  'content_path': r'C:\Downloads\Example Show 02.mkv',
                  'amount_left': 1024,
                },
              ]));
          case '/api/v2/torrents/files':
            response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(jsonEncode(<Map<String, Object>>[
                <String, Object>{
                  'name': 'Example Show 02.mkv',
                  'size': 2048,
                  'progress': 0.5,
                  'index': 0,
                },
              ]));
          default:
            response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      }
    }();

    final QBittorrentClient client = QBittorrentClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      username: 'admin',
      password: 'secret',
      requestTimeout: const Duration(seconds: 2),
    );
    try {
      expect(await client.fetchVersion(), 'v5.0.4');
      expect(await client.ensureCategory('hibiki'), isTrue);
      expect(
        await client.addTorrents(
          <String>['magnet:?xt=urn:btih:abc123'],
          category: 'hibiki',
          sequentialDownload: true,
          firstLastPiecePrio: true,
        ),
        isTrue,
      );
      final torrents = await client.fetchTorrents(category: 'hibiki');
      expect(torrents, hasLength(1));
      expect(torrents.single.hash, 'abc123');
      final files = await client.fetchTorrentFiles('abc123');
      expect(files, hasLength(1));
      expect(files.single.name, 'Example Show 02.mkv');

      expect(requests, <String>[
        '/api/v2/auth/login',
        '/api/v2/app/version',
        '/api/v2/torrents/createCategory',
        '/api/v2/torrents/add',
        '/api/v2/torrents/info',
        '/api/v2/torrents/files',
      ]);
      expect(
        forms.any((Map<String, String> form) =>
            form['category'] == 'hibiki' &&
            form['urls'] == 'magnet:?xt=urn:btih:abc123' &&
            form['sequentialDownload'] == 'true' &&
            form['firstLastPiecePrio'] == 'true'),
        isTrue,
      );
    } finally {
      client.close();
      await server.close(force: true);
      await serving;
    }
  });
}
