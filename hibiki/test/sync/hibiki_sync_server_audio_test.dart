import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';

/// Fake 库服务：本地音频 + 有声书方法真实记录调用；dict/books 方法存根。
class _FakeLibraryService implements HibikiLibraryHostService {
  // ── dict stubs ──────────────────────────────────────────────────────────────
  @override
  Future<List<RemoteDictionaryInfo>> listDictionaries() async =>
      <RemoteDictionaryInfo>[];

  @override
  Future<File> exportDictionary(String name) async =>
      throw UnimplementedError('not used in audio test');

  @override
  Future<void> importDictionary(File packageFile) async {}

  @override
  Future<void> deleteDictionary(String name) async {}

  // ── books stubs ─────────────────────────────────────────────────────────────
  @override
  Future<List<RemoteBookInfo>> listBooks() async => <RemoteBookInfo>[];

  @override
  Future<File> exportBook(String title) async =>
      throw UnimplementedError('not used in audio test');

  @override
  Future<void> importBook(File epubFile) async {}

  @override
  Future<void> deleteBook(String title) async {}

  final Map<String, RemoteBookProgress> bookProgress =
      <String, RemoteBookProgress>{};

  @override
  Future<RemoteBookProgress> getBookProgress(String bookKey) async =>
      bookProgress[bookKey] ?? RemoteBookProgress.empty;

  @override
  Future<void> putBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {
    final RemoteBookProgress current =
        bookProgress[bookKey] ?? RemoteBookProgress.empty;
    bookProgress[bookKey] =
        resolveBookProgressSync(local: current, remote: progress);
  }

  // ── 本地音频（真实记录）────────────────────────────────────────────────────────
  final List<RemoteLocalAudioInfo> localAudioEntries = <RemoteLocalAudioInfo>[
    const RemoteLocalAudioInfo(displayName: 'NHK'),
  ];
  final List<String> deletedLocalAudio = <String>[];

  /// importLocalAudio 收到的文件内容（string 形式）。
  final List<String> importedLocalAudio = <String>[];

  @override
  Future<List<RemoteLocalAudioInfo>> listLocalAudio() async =>
      localAudioEntries;

  @override
  Future<File> exportLocalAudio(String displayName) async {
    if (!localAudioEntries
        .any((RemoteLocalAudioInfo a) => a.displayName == displayName)) {
      throw StateError('local audio not found: $displayName');
    }
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_la_exp');
    final File f = File('${tmp.path}/$displayName.localaudio');
    f.writeAsBytesSync(utf8.encode('LOCALAUDIO:$displayName'));
    return f;
  }

  @override
  Future<void> importLocalAudio(File packageFile) async {
    importedLocalAudio.add(await packageFile.readAsString());
  }

  @override
  Future<void> deleteLocalAudio(String displayName) async =>
      deletedLocalAudio.add(displayName);

  // ── 有声书（真实记录）──────────────────────────────────────────────────────────
  final List<RemoteAudiobookInfo> audiobookEntries = <RemoteAudiobookInfo>[
    const RemoteAudiobookInfo(bookKey: 'sample_book', title: 'Sample Book'),
  ];
  final List<String> deletedAudiobooks = <String>[];

  /// importAudiobook 收到的 (content, bookKeyOverride) 对。
  final List<(String, String?)> importedAudiobooks = <(String, String?)>[];

  @override
  Future<List<RemoteAudiobookInfo>> listAudiobooks() async => audiobookEntries;

  @override
  Future<File> exportAudiobook(String bookKey) async {
    if (!audiobookEntries
        .any((RemoteAudiobookInfo ab) => ab.bookKey == bookKey)) {
      throw StateError('audiobook not found: $bookKey');
    }
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_ab_exp');
    final File f = File('${tmp.path}/$bookKey.audiobook');
    f.writeAsBytesSync(utf8.encode('AUDIOBOOK:$bookKey'));
    return f;
  }

  @override
  Future<void> importAudiobook(File packageFile,
      {String? bookKeyOverride}) async {
    importedAudiobooks.add((await packageFile.readAsString(), bookKeyOverride));
  }

  @override
  Future<void> deleteAudiobook(String bookKey) async =>
      deletedAudiobooks.add(bookKey);

  // ── video stubs (P4-1) ────────────────────────────────────────────────────
  @override
  Future<List<RemoteVideoInfo>> listVideos() async => <RemoteVideoInfo>[];

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      null;

  @override
  Future<File?> resolveVideoSubtitle(String id,
          {String langCode = 'ja', int episodeIndex = 0}) async =>
      null;

  @override
  Future<({int positionMs, int updatedAtMs})> getVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async =>
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {}
}

void main() {
  late HibikiSyncServer server;
  late _FakeLibraryService lib;
  const String token = 'test-token-audio';
  late String base;
  String authHeader() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  setUp(() async {
    lib = _FakeLibraryService();
    server = HibikiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_audio_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: lib,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async => server.stop());

  // ════════════════════════════════════════════════════════════════════════════
  // capabilities
  // ════════════════════════════════════════════════════════════════════════════

  test('GET /api/capabilities reports audio == true when service injected',
      () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/capabilities'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    final Map<String, dynamic> json =
        jsonDecode(await res.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    final Map<dynamic, dynamic> live =
        json['liveLibrary'] as Map<dynamic, dynamic>;
    expect(live['audio'], true,
        reason: 'audio capability must be true when library service is set');
    c.close();
  });

  // ════════════════════════════════════════════════════════════════════════════
  // /api/library/localaudio
  // ════════════════════════════════════════════════════════════════════════════

  group('local audio', () {
    // ── list ──────────────────────────────────────────────────────────────────

    test('GET /api/library/localaudio lists entries', () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req =
          await c.getUrl(Uri.parse('$base/api/library/localaudio'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200);
      final List<dynamic> json =
          jsonDecode(await res.transform(utf8.decoder).join()) as List<dynamic>;
      expect(json.length, 1);
      final Map<dynamic, dynamic> first = json.first as Map<dynamic, dynamic>;
      expect(first['displayName'], 'NHK');
      c.close();
    });

    // ── GET single ────────────────────────────────────────────────────────────

    test('GET /api/library/localaudio/<name> streams bytes', () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req =
          await c.getUrl(Uri.parse('$base/api/library/localaudio/NHK'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200);
      expect(res.headers.contentType?.mimeType, 'application/octet-stream');
      final String body = await res.transform(utf8.decoder).join();
      expect(body, 'LOCALAUDIO:NHK');
      c.close();
    });

    test('GET /api/library/localaudio/<missing> returns 404', () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req =
          await c.getUrl(Uri.parse('$base/api/library/localaudio/NoSuchEntry'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 404);
      await res.drain<void>();
      c.close();
    });

    // ── PUT ───────────────────────────────────────────────────────────────────

    test('PUT /api/library/localaudio/<name> imports body', () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req =
          await c.putUrl(Uri.parse('$base/api/library/localaudio/NewAudio'));
      req.headers.set('authorization', authHeader());
      req.add(utf8.encode('LOCALAUDIO:NewAudio'));
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, anyOf(200, 201, 204));
      expect(lib.importedLocalAudio, contains('LOCALAUDIO:NewAudio'));
      c.close();
    });

    // ── DELETE ────────────────────────────────────────────────────────────────

    test('DELETE /api/library/localaudio/<name> returns 204 and records call',
        () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req =
          await c.deleteUrl(Uri.parse('$base/api/library/localaudio/NHK'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, anyOf(200, 204));
      expect(lib.deletedLocalAudio, contains('NHK'));
      c.close();
    });

    // ── 401 unauthenticated ───────────────────────────────────────────────────

    test('unauthenticated request returns 401', () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req =
          await c.getUrl(Uri.parse('$base/api/library/localaudio'));
      // 不设 Authorization 头
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 401);
      await res.drain<void>();
      c.close();
    });

    // ── path traversal 403 ────────────────────────────────────────────────────

    test('path-traversal displayName is rejected with 403', () async {
      final HttpClient c = HttpClient();

      final HttpClientRequest delReq = await c
          .deleteUrl(Uri.parse('$base/api/library/localaudio/%2e%2e%2fevil'));
      delReq.headers.set('authorization', authHeader());
      final HttpClientResponse delRes = await delReq.close();
      expect(delRes.statusCode, 403,
          reason: 'DELETE with "../evil" must be 403 Forbidden');
      await delRes.drain<void>();
      expect(lib.deletedLocalAudio, isEmpty,
          reason: 'no deletion must occur for a traversal name');

      final HttpClientRequest getReq = await c
          .getUrl(Uri.parse('$base/api/library/localaudio/%2e%2e%2fevil'));
      getReq.headers.set('authorization', authHeader());
      final HttpClientResponse getRes = await getReq.close();
      expect(getRes.statusCode, 403,
          reason: 'GET with "../evil" must be 403 Forbidden');
      await getRes.drain<void>();

      c.close();
    });

    // ── no service injected → 404 ─────────────────────────────────────────────

    test('localaudio endpoints return 404 when no service injected', () async {
      final HibikiSyncServer bare = HibikiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk_la_bare').path,
        port: 0,
        token: token,
        allowLan: false,
        // libraryService 为 null
      );
      await bare.start();
      final String bareBase = 'http://127.0.0.1:${bare.port}';
      final HttpClient c = HttpClient();
      final HttpClientRequest req =
          await c.getUrl(Uri.parse('$bareBase/api/library/localaudio'));
      req.headers.set('authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 404);
      await res.drain<void>();
      c.close();
      await bare.stop();
    });

    // ── CJK displayName ───────────────────────────────────────────────────────

    test('GET /api/library/localaudio/<CJK> 正确解码中文名', () async {
      lib.localAudioEntries
          .add(const RemoteLocalAudioInfo(displayName: '日本語音声'));
      final HttpClient c = HttpClient();
      final String encoded = Uri.encodeComponent('日本語音声');
      final HttpClientRequest req =
          await c.getUrl(Uri.parse('$base/api/library/localaudio/$encoded'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200, reason: 'GET 日本語音声 应返回 200，双重解码会致 500');
      final String body = await res.transform(utf8.decoder).join();
      expect(body, 'LOCALAUDIO:日本語音声',
          reason: 'server 应以正确 CJK 名调用 exportLocalAudio');
      c.close();
    });

    test('DELETE /api/library/localaudio/<CJK> 以中文名删除', () async {
      lib.localAudioEntries
          .add(const RemoteLocalAudioInfo(displayName: '日本語音声'));
      final HttpClient c = HttpClient();
      final String encoded = Uri.encodeComponent('日本語音声');
      final HttpClientRequest req =
          await c.deleteUrl(Uri.parse('$base/api/library/localaudio/$encoded'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, anyOf(200, 204));
      expect(lib.deletedLocalAudio, contains('日本語音声'),
          reason: 'deleteLocalAudio 应以解码后中文名被调用');
      c.close();
    });
  });

  // ════════════════════════════════════════════════════════════════════════════
  // /api/library/audiobooks
  // ════════════════════════════════════════════════════════════════════════════

  group('audiobooks', () {
    // ── list ──────────────────────────────────────────────────────────────────

    test('GET /api/library/audiobooks lists entries', () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req =
          await c.getUrl(Uri.parse('$base/api/library/audiobooks'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200);
      final List<dynamic> json =
          jsonDecode(await res.transform(utf8.decoder).join()) as List<dynamic>;
      expect(json.length, 1);
      final Map<dynamic, dynamic> first = json.first as Map<dynamic, dynamic>;
      expect(first['bookKey'], 'sample_book');
      expect(first['title'], 'Sample Book');
      c.close();
    });

    // ── GET single ────────────────────────────────────────────────────────────

    test('GET /api/library/audiobooks/<key> streams bytes', () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req =
          await c.getUrl(Uri.parse('$base/api/library/audiobooks/sample_book'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200);
      expect(res.headers.contentType?.mimeType, 'application/octet-stream');
      final String body = await res.transform(utf8.decoder).join();
      expect(body, 'AUDIOBOOK:sample_book');
      c.close();
    });

    test('GET /api/library/audiobooks/<missing> returns 404', () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req = await c
          .getUrl(Uri.parse('$base/api/library/audiobooks/no_such_book'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 404);
      await res.drain<void>();
      c.close();
    });

    // ── PUT（含 bookKeyOverride 断言）────────────────────────────────────────

    test(
        'PUT /api/library/audiobooks/<key> imports body and passes bookKeyOverride',
        () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req =
          await c.putUrl(Uri.parse('$base/api/library/audiobooks/new_book'));
      req.headers.set('authorization', authHeader());
      req.add(utf8.encode('AUDIOBOOK:new_book'));
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, anyOf(200, 201, 204));
      // 断言 fake 收到了正确内容 AND bookKeyOverride == 'new_book'
      expect(
        lib.importedAudiobooks,
        contains(('AUDIOBOOK:new_book', 'new_book')),
        reason: 'importAudiobook 应收到 bookKeyOverride == "new_book"',
      );
      c.close();
    });

    // ── DELETE ────────────────────────────────────────────────────────────────

    test('DELETE /api/library/audiobooks/<key> returns 204 and records call',
        () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req = await c
          .deleteUrl(Uri.parse('$base/api/library/audiobooks/sample_book'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, anyOf(200, 204));
      expect(lib.deletedAudiobooks, contains('sample_book'));
      c.close();
    });

    // ── 401 unauthenticated ───────────────────────────────────────────────────

    test('unauthenticated request returns 401', () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req =
          await c.getUrl(Uri.parse('$base/api/library/audiobooks'));
      // 不设 Authorization 头
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 401);
      await res.drain<void>();
      c.close();
    });

    // ── path traversal 403 ────────────────────────────────────────────────────

    test('path-traversal bookKey is rejected with 403', () async {
      final HttpClient c = HttpClient();

      final HttpClientRequest delReq = await c
          .deleteUrl(Uri.parse('$base/api/library/audiobooks/%2e%2e%2fevil'));
      delReq.headers.set('authorization', authHeader());
      final HttpClientResponse delRes = await delReq.close();
      expect(delRes.statusCode, 403,
          reason: 'DELETE with "../evil" must be 403 Forbidden');
      await delRes.drain<void>();
      expect(lib.deletedAudiobooks, isEmpty,
          reason: 'no deletion must occur for a traversal key');

      final HttpClientRequest getReq = await c
          .getUrl(Uri.parse('$base/api/library/audiobooks/%2e%2e%2fevil'));
      getReq.headers.set('authorization', authHeader());
      final HttpClientResponse getRes = await getReq.close();
      expect(getRes.statusCode, 403,
          reason: 'GET with "../evil" must be 403 Forbidden');
      await getRes.drain<void>();

      c.close();
    });

    // ── no service injected → 404 ─────────────────────────────────────────────

    test('audiobooks endpoints return 404 when no service injected', () async {
      final HibikiSyncServer bare = HibikiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk_ab_bare').path,
        port: 0,
        token: token,
        allowLan: false,
        // libraryService 为 null
      );
      await bare.start();
      final String bareBase = 'http://127.0.0.1:${bare.port}';
      final HttpClient c = HttpClient();
      final HttpClientRequest req =
          await c.getUrl(Uri.parse('$bareBase/api/library/audiobooks'));
      req.headers.set('authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 404);
      await res.drain<void>();
      c.close();
      await bare.stop();
    });

    // ── CJK bookKey ───────────────────────────────────────────────────────────

    test('GET /api/library/audiobooks/<CJK> 正确解码中文 bookKey', () async {
      lib.audiobookEntries
          .add(const RemoteAudiobookInfo(bookKey: '三体有声书', title: '三体'));
      final HttpClient c = HttpClient();
      final String encoded = Uri.encodeComponent('三体有声书');
      final HttpClientRequest req =
          await c.getUrl(Uri.parse('$base/api/library/audiobooks/$encoded'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200, reason: 'GET 三体有声书 应返回 200，双重解码会致 500');
      final String body = await res.transform(utf8.decoder).join();
      expect(body, 'AUDIOBOOK:三体有声书',
          reason: 'server 应以正确 CJK key 调用 exportAudiobook');
      c.close();
    });

    test('PUT /api/library/audiobooks/<CJK> 传递正确的 bookKeyOverride', () async {
      final HttpClient c = HttpClient();
      final String encoded = Uri.encodeComponent('三体有声书');
      final HttpClientRequest req =
          await c.putUrl(Uri.parse('$base/api/library/audiobooks/$encoded'));
      req.headers.set('authorization', authHeader());
      req.add(utf8.encode('AUDIOBOOK:三体有声书'));
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, anyOf(200, 201, 204),
          reason: 'PUT 三体有声书 应成功（2xx）');
      expect(
        lib.importedAudiobooks,
        contains(('AUDIOBOOK:三体有声书', '三体有声书')),
        reason: 'importAudiobook 应以 bookKeyOverride="三体有声书" 被调用',
      );
      c.close();
    });

    test('DELETE /api/library/audiobooks/<CJK> 以中文 key 删除', () async {
      lib.audiobookEntries
          .add(const RemoteAudiobookInfo(bookKey: '三体有声书', title: '三体'));
      final HttpClient c = HttpClient();
      final String encoded = Uri.encodeComponent('三体有声书');
      final HttpClientRequest req =
          await c.deleteUrl(Uri.parse('$base/api/library/audiobooks/$encoded'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, anyOf(200, 204));
      expect(lib.deletedAudiobooks, contains('三体有声书'),
          reason: 'deleteAudiobook 应以解码后中文 key 被调用');
      c.close();
    });
  });
}
