import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hibiki/src/media/torrent/qbittorrent_client.dart';

void main() {
  test('uploads metainfo as qBittorrent multipart torrents field', () async {
    int addCalls = 0;
    final MockClient httpClient = MockClient((http.Request request) async {
      if (request.url.path == '/api/v2/auth/login') {
        return http.Response(
          'Ok.',
          200,
          headers: <String, String>{'set-cookie': 'SID=session; path=/'},
        );
      }
      if (request.url.path == '/api/v2/torrents/add') {
        addCalls++;
        expect(request.headers['cookie'], 'SID=session');
        expect(
            request.headers['content-type'], contains('multipart/form-data'));
        final String body = latin1.decode(request.bodyBytes);
        expect(body, contains('name="torrents"'));
        expect(body, contains('filename="safe_name.torrent"'));
        expect(body, contains('name="category"'));
        expect(body, contains('anime'));
        expect(body, contains('torrent-body'));
        return http.Response('Ok.', 200);
      }
      return http.Response('not found', 404);
    });
    final QBittorrentClient client = QBittorrentClient(
      baseUrl: 'http://localhost:8080',
      username: 'user',
      password: 'password',
      client: httpClient,
    );

    final bool ok = await client.addTorrentFile(
      Uint8List.fromList(utf8.encode('torrent-body')),
      fileName: '../safe name.torrent',
      category: 'anime',
      sequentialDownload: true,
    );

    expect(ok, isTrue);
    expect(addCalls, 1);
  });
}
