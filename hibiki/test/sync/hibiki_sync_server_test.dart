import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_utils.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

void main() {
  group('HibikiSyncServer', () {
    late HibikiSyncServer server;
    late Directory tempDir;
    late String token;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('hibiki_server_test_');
      final syncDataDir = Directory('${tempDir.path}/sync-data');
      await syncDataDir.create();
      final rootDir = Directory('${syncDataDir.path}/$kSyncRootFolderName');
      await rootDir.create();
      final bookDir = Directory('${rootDir.path}/TestBook');
      await bookDir.create();
      await File('${bookDir.path}/progress_1234_0.5.json')
          .writeAsString(jsonEncode({
        'dataId': 0,
        'exploredCharCount': 500,
        'progress': 0.5,
        'lastBookmarkModified': 1234,
      }));

      token = HibikiSyncServer.generateToken();
      server = HibikiSyncServer(
        syncDataDir: tempDir.path,
        port: 0,
        token: token,
        allowLan: true,
      );
    });

    tearDown(() async {
      await server.stop();
      await tempDir.delete(recursive: true);
    });

    test('generateToken produces 256-bit+ base64url token', () {
      final t = HibikiSyncServer.generateToken();
      expect(t.length, greaterThanOrEqualTo(40));
      final decoded = base64Url.decode(base64Url.normalize(t));
      expect(decoded.length, 32); // 256 bits
    });

    test('starts and stops without error', () async {
      await server.start();
      expect(server.isRunning, isTrue);
      expect(server.port, isNot(0));
      await server.stop();
      expect(server.isRunning, isFalse);
    });

    test('rejects unauthenticated requests', () async {
      await server.start();
      final client = HttpClient();
      final request = await client.openUrl(
        'PROPFIND',
        Uri.parse('http://localhost:${server.port}/$kSyncRootFolderName/'),
      );
      request.headers.set('Depth', '0');
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 401);
      client.close();
    });

    test('rejects wrong token', () async {
      await server.start();
      final client = HttpClient();
      final request = await client.openUrl(
        'PROPFIND',
        Uri.parse('http://localhost:${server.port}/$kSyncRootFolderName/'),
      );
      request.headers.set('Authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:wrongtoken'))}');
      request.headers.set('Depth', '0');
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 401);
      client.close();
    });

    test('accepts authenticated PROPFIND on root', () async {
      await server.start();
      final client = HttpClient();
      final request = await client.openUrl(
        'PROPFIND',
        Uri.parse('http://localhost:${server.port}/$kSyncRootFolderName/'),
      );
      request.headers.set('Authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
      request.headers.set('Depth', '1');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      expect(response.statusCode, 207);
      expect(body, contains('TestBook'));
      client.close();
    });

    test('GET returns file contents', () async {
      await server.start();
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(
        'http://localhost:${server.port}/$kSyncRootFolderName/TestBook/progress_1234_0.5.json',
      ));
      request.headers.set('Authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      expect(response.statusCode, 200);
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['exploredCharCount'], 500);
      client.close();
    });

    test('PUT creates new file', () async {
      await server.start();
      final client = HttpClient();
      final request = await client.openUrl(
        'PUT',
        Uri.parse(
            'http://localhost:${server.port}/$kSyncRootFolderName/TestBook/test.json'),
      );
      request.headers.set('Authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
      request.headers.set('Content-Type', 'application/json');
      request.add(utf8.encode('{"hello":"world"}'));
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 201);

      final file = File(
          '${tempDir.path}/sync-data/$kSyncRootFolderName/TestBook/test.json');
      expect(file.existsSync(), isTrue);
      expect(jsonDecode(file.readAsStringSync()), {'hello': 'world'});
      client.close();
    });

    test('DELETE removes file', () async {
      await server.start();
      final testFile = File(
          '${tempDir.path}/sync-data/$kSyncRootFolderName/TestBook/to_delete.json');
      await testFile.writeAsString('{}');
      expect(testFile.existsSync(), isTrue);

      final client = HttpClient();
      final request = await client.openUrl(
        'DELETE',
        Uri.parse(
            'http://localhost:${server.port}/$kSyncRootFolderName/TestBook/to_delete.json'),
      );
      request.headers.set('Authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 204);
      expect(testFile.existsSync(), isFalse);
      client.close();
    });

    test('MKCOL creates directory', () async {
      await server.start();
      final client = HttpClient();
      final request = await client.openUrl(
        'MKCOL',
        Uri.parse(
            'http://localhost:${server.port}/$kSyncRootFolderName/NewBook/'),
      );
      request.headers.set('Authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 201);
      expect(
        Directory('${tempDir.path}/sync-data/$kSyncRootFolderName/NewBook')
            .existsSync(),
        isTrue,
      );
      client.close();
    });

    test('rejects path traversal attempts', () async {
      await server.start();
      final client = HttpClient();
      for (final path in [
        '/../../../etc/passwd',
        '/$kSyncRootFolderName/../../etc/passwd',
        '/%2e%2e/%2e%2e/etc/passwd',
      ]) {
        final request = await client.getUrl(
          Uri.parse('http://localhost:${server.port}$path'),
        );
        request.headers.set('Authorization',
            'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, anyOf(403, 404),
            reason: 'Path $path should be rejected');
      }
      client.close();
    });

    test('HEAD returns file metadata', () async {
      await server.start();
      final client = HttpClient();
      final request = await client.openUrl(
        'HEAD',
        Uri.parse(
            'http://localhost:${server.port}/$kSyncRootFolderName/TestBook/progress_1234_0.5.json'),
      );
      request.headers.set('Authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 200);
      expect(response.headers.value('content-type'), 'application/json');
      client.close();
    });

    test('remote dictionary lookup requires auth and returns popup payload',
        () async {
      final HibikiSyncServer lookupServer = HibikiSyncServer(
        syncDataDir: tempDir.path,
        port: 0,
        token: token,
        allowLan: true,
        remoteLookupService: _FakeRemoteLookupService(),
      );
      await server.stop();
      server = lookupServer;
      await server.start();

      final client = HttpClient();
      final unauthenticated = await client.postUrl(Uri.parse(
        'http://localhost:${server.port}/api/lookup/dictionary',
      ));
      unauthenticated.headers.contentType = ContentType.json;
      unauthenticated.add(utf8.encode(jsonEncode(<String, dynamic>{
        'term': '猫',
        'wildcards': false,
        'maximumTerms': 3,
      })));
      final rejected = await unauthenticated.close();
      await rejected.drain<void>();
      expect(rejected.statusCode, 401);

      final request = await client.postUrl(Uri.parse(
        'http://localhost:${server.port}/api/lookup/dictionary',
      ));
      request.headers
        ..set('Authorization',
            'Basic ${base64Encode(utf8.encode('hibiki:$token'))}')
        ..contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(<String, dynamic>{
        'term': '猫',
        'wildcards': true,
        'maximumTerms': 3,
      })));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;

      expect(response.statusCode, 200);
      expect(json['type'], 'dictionaryResult');
      expect(json['result'], isA<Map<String, dynamic>>());
      expect(json['popupJson'], contains('remote-popup'));
      client.close();
    });

    test('remote audio lookup returns a naked-player URL guarded by opaque id',
        () async {
      final HibikiSyncServer lookupServer = HibikiSyncServer(
        syncDataDir: tempDir.path,
        port: 0,
        token: token,
        allowLan: true,
        remoteLookupService: _FakeRemoteLookupService(),
      );
      await server.stop();
      server = lookupServer;
      await server.start();

      final client = HttpClient();
      final unauthenticated = await client.postUrl(Uri.parse(
        'http://localhost:${server.port}/api/lookup/audio',
      ));
      unauthenticated.headers.contentType = ContentType.json;
      unauthenticated.add(utf8.encode(jsonEncode(<String, dynamic>{
        'expression': '猫',
        'reading': 'ねこ',
      })));
      final rejected = await unauthenticated.close();
      await rejected.drain<void>();
      expect(rejected.statusCode, 401);

      final request = await client.postUrl(Uri.parse(
        'http://localhost:${server.port}/api/lookup/audio',
      ));
      request.headers
        ..set('Authorization',
            'Basic ${base64Encode(utf8.encode('hibiki:$token'))}')
        ..contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(<String, dynamic>{
        'expression': '猫',
        'reading': 'ねこ',
        'path': '../../secret.mp3',
      })));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;

      expect(response.statusCode, 200);
      expect(json['type'], 'audioResult');
      expect(json['contentType'], 'audio/mpeg');
      final String url = json['url'] as String;
      expect(url, contains('/api/lookup/audio/file?id='));
      expect(url, isNot(contains('secret.mp3')));

      final invalidRequest = await client.getUrl(Uri.parse(
        'http://localhost:${server.port}/api/lookup/audio/file?id=missing',
      ));
      final invalidResponse = await invalidRequest.close();
      await invalidResponse.drain<void>();
      expect(invalidResponse.statusCode, 404);

      final fileRequest = await client.getUrl(Uri.parse(url));
      final fileResponse = await fileRequest.close();
      final bytes = await fileResponse.fold<List<int>>(
        <int>[],
        (List<int> previous, List<int> element) => previous..addAll(element),
      );
      expect(fileResponse.statusCode, 200);
      expect(fileResponse.headers.value('content-type'), 'audio/mpeg');
      expect(bytes, <int>[1, 2, 3, 4]);
      client.close();
    });

    test('remote audio file id expires before naked playback', () async {
      DateTime now = DateTime(2026, 1, 1, 12);
      final HibikiSyncServer lookupServer = HibikiSyncServer(
        syncDataDir: tempDir.path,
        port: 0,
        token: token,
        allowLan: true,
        remoteLookupService: _FakeRemoteLookupService(),
        now: () => now,
      );
      await server.stop();
      server = lookupServer;
      await server.start();

      final client = HttpClient();
      final request = await client.postUrl(Uri.parse(
        'http://localhost:${server.port}/api/lookup/audio',
      ));
      request.headers
        ..set('Authorization',
            'Basic ${base64Encode(utf8.encode('hibiki:$token'))}')
        ..contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(<String, dynamic>{
        'expression': '猫',
        'reading': 'ねこ',
      })));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final String url = json['url'] as String;

      now = now.add(const Duration(minutes: 5, seconds: 1));
      final fileRequest = await client.getUrl(Uri.parse(url));
      final fileResponse = await fileRequest.close();
      await fileResponse.drain<void>();

      expect(response.statusCode, 200);
      expect(fileResponse.statusCode, 404);
      client.close();
    });
  });

  group('HibikiSyncServer.generateToken', () {
    test('produces unique tokens', () {
      final tokens = List.generate(10, (_) => HibikiSyncServer.generateToken());
      expect(tokens.toSet().length, 10);
    });
  });
}

class _FakeRemoteLookupService implements HibikiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    final DictionarySearchResult result = DictionarySearchResult(
      searchTerm: term,
      entries: <DictionaryEntry>[
        DictionaryEntry(
          dictionaryName: 'remote',
          word: term,
          reading: 'ねこ',
          meaning: 'remote meaning',
        ),
      ],
    );
    result.popupJson = '{"source":"remote-popup"}';
    return result;
  }

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async {
    return RemoteAudioLookup(
      bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      contentType: 'audio/mpeg',
    );
  }
}
