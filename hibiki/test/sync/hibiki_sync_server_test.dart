import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';

void main() {
  group('HibikiSyncServer', () {
    late HibikiSyncServer server;
    late Directory tempDir;
    late String token;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('hibiki_server_test_');
      final syncDataDir = Directory('${tempDir.path}/sync-data');
      await syncDataDir.create();
      final rootDir = Directory('${syncDataDir.path}/ttu-reader-data');
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
        Uri.parse('http://localhost:${server.port}/ttu-reader-data/'),
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
        Uri.parse('http://localhost:${server.port}/ttu-reader-data/'),
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
        Uri.parse('http://localhost:${server.port}/ttu-reader-data/'),
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
        'http://localhost:${server.port}/ttu-reader-data/TestBook/progress_1234_0.5.json',
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
            'http://localhost:${server.port}/ttu-reader-data/TestBook/test.json'),
      );
      request.headers.set('Authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
      request.headers.set('Content-Type', 'application/json');
      request.add(utf8.encode('{"hello":"world"}'));
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 201);

      final file =
          File('${tempDir.path}/sync-data/ttu-reader-data/TestBook/test.json');
      expect(file.existsSync(), isTrue);
      expect(jsonDecode(file.readAsStringSync()), {'hello': 'world'});
      client.close();
    });

    test('DELETE removes file', () async {
      await server.start();
      final testFile =
          File('${tempDir.path}/sync-data/ttu-reader-data/TestBook/to_delete.json');
      await testFile.writeAsString('{}');
      expect(testFile.existsSync(), isTrue);

      final client = HttpClient();
      final request = await client.openUrl(
        'DELETE',
        Uri.parse(
            'http://localhost:${server.port}/ttu-reader-data/TestBook/to_delete.json'),
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
            'http://localhost:${server.port}/ttu-reader-data/NewBook/'),
      );
      request.headers.set('Authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 201);
      expect(
        Directory('${tempDir.path}/sync-data/ttu-reader-data/NewBook').existsSync(),
        isTrue,
      );
      client.close();
    });

    test('rejects path traversal attempts', () async {
      await server.start();
      final client = HttpClient();
      for (final path in [
        '/../../../etc/passwd',
        '/ttu-reader-data/../../etc/passwd',
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
            'http://localhost:${server.port}/ttu-reader-data/TestBook/progress_1234_0.5.json'),
      );
      request.headers.set('Authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 200);
      expect(response.headers.value('content-type'), 'application/json');
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
