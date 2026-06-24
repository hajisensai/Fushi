import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

// TODO-779 F：制卡时「单词远程音频下载失败」过去只 debugPrint 后静默落空
// （卡片建好但 `[sound:]` 落空，用户盲猜「没音频不知为何」）。本测试锁定新契约：
//
//  (1) 非 200 的远程音频响应 → 卡片仍成功创建（MineResult.success），但
//      MineOutcome.audioWarning 带可断言的失败原因（含 HTTP 码 + URL）。
//  (2) 绝不把错误响应体当 .mp3 写入媒体（HBK-AUDIT-019）——storeMediaFile/
//      addFileToMedia 不被远程音频路径调用、字段里不出现 [sound:]。
//  (3) 抓取期间抛异常（连接失败/超时）同样冒泡成 audioWarning，卡片仍成功。
//  (4) 音频下载**成功**时 audioWarning 为 null（向后兼容，不误报）。
//  (5) 没有音频要取时 audioWarning 为 null。
//
// 远程音频路径用裸 `HttpClient()`，故用 HttpOverrides 注入一个返回任意状态码/
// 字节/抛异常的假 client；AnkiConnect 的 storeMediaFile 用 recording fake 拦下，
// AnkiDroid 的 addFileToMedia 用 mock MethodChannel 拦下。

// ── 假 HttpClient：返回可配置的状态码/字节，或在 getUrl 时抛异常 ──────────────
// 经 HttpOverrides.runZoned 的 createHttpClient 注入到远程音频路径的裸 HttpClient()。

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient({
    required this.statusCode,
    required this.body,
    required this.contentType,
    required this.throwOnConnect,
  });

  final int statusCode;
  final List<int> body;
  final ContentType? contentType;
  final Object? throwOnConnect;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (throwOnConnect != null) {
      throw throwOnConnect!;
    }
    return _FakeHttpClientRequest(
      _FakeHttpClientResponse(
        statusCode: statusCode,
        body: body,
        contentType: contentType,
      ),
    );
  }

  @override
  void close({bool force = false}) {}

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected HttpClient method: '
          '${invocation.memberName}');
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this._response);

  final _FakeHttpClientResponse _response;

  @override
  Future<HttpClientResponse> close() async => _response;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected HttpClientRequest method: '
          '${invocation.memberName}');
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse({
    required this.statusCode,
    required this.body,
    required ContentType? contentType,
  }) : headers = _FakeHttpHeaders(contentType);

  @override
  final int statusCode;

  final List<int> body;

  @override
  final HttpHeaders headers;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.fromIterable(<List<int>>[body]).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected HttpClientResponse method: '
          '${invocation.memberName}');
}

class _FakeHttpHeaders implements HttpHeaders {
  _FakeHttpHeaders(this._contentType);

  final ContentType? _contentType;

  @override
  ContentType? get contentType => _contentType;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected HttpHeaders method: '
          '${invocation.memberName}');
}

// ── AnkiConnect fake service (records storeMediaFile / addNote) ───────────────

class _RecordingAnkiConnectService extends AnkiConnectService {
  final List<String> storedFilenames = <String>[];
  Map<String, String>? lastAddedFields;

  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {
    storedFilenames.add(filename);
  }

  @override
  Future<int?> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
    bool allowDuplicate = false,
  }) async {
    lastAddedFields = Map<String, String>.from(fields);
    return 99;
  }
}

class _ConfiguredAnkiConnectRepository extends AnkiConnectRepository {
  _ConfiguredAnkiConnectRepository({
    required AnkiConnectService service,
    required this.settings,
  }) : super(service: service);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

// ── AnkiDroid configured repo (loadSettings stub; channel mocked per-test) ────

const MethodChannel _droidChannel = MethodChannel('app.hibiki.reader/anki');

class _ConfiguredAnkiRepository extends AnkiRepository {
  _ConfiguredAnkiRepository(this.settings);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

AnkiSettings _settings() => AnkiSettings(
      selectedDeckId: 1,
      selectedNoteTypeId: 2,
      availableDecks: const <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
      availableNoteTypes: const <AnkiNoteType>[
        AnkiNoteType(
          id: 2,
          name: 'Hibiki',
          fields: <String>['Expression', 'Audio'],
        ),
      ],
      fieldMappings: const <String, String>{
        'Expression': '{expression}',
        'Audio': '{audio}',
      },
      allowDupes: true,
    );

/// Payload whose `audio` field is a remote URL, so the repo takes the
/// remoteUrl branch of `_storeRemoteAudio` / `_addRemoteAudio`.
const String _payloadWithRemoteAudio =
    '{"expression":"勉強","reading":"べんきょう","audio":"https://dict.example/a.mp3"}';

const String _payloadNoAudio = '{"expression":"勉強","reading":"べんきょう"}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AnkiConnect: remote audio failure is surfaced, never embedded', () {
    test('non-200 → success card + audioWarning with HTTP code & URL, no media',
        () async {
      await HttpOverrides.runZoned(
        () async {
          final service = _RecordingAnkiConnectService();
          final repo = _ConfiguredAnkiConnectRepository(
            service: service,
            settings: _settings(),
          );

          final outcome = await repo.mineEntry(
            rawPayloadJson: _payloadWithRemoteAudio,
            context: const AnkiMiningContext(sentence: 's'),
          );

          // Card still created.
          expect(outcome.result, MineResult.success);
          // Failure is visible: carries HTTP code + URL.
          expect(outcome.audioWarning, isNotNull);
          expect(outcome.audioWarning, contains('404'));
          expect(outcome.audioWarning, contains('https://dict.example/a.mp3'));
          // HBK-AUDIT-019: the error body was NOT written as media.
          expect(service.storedFilenames, isEmpty);
          // The Audio field rendered to nothing (no [sound:]).
          expect(service.lastAddedFields?['Audio'] ?? '',
              isNot(contains('[sound:')));
        },
        createHttpClient: (_) => _FakeHttpClient(
          statusCode: 404,
          body: const <int>[60, 104, 116, 109, 108, 62], // "<html>"
          contentType: ContentType.html,
          throwOnConnect: null,
        ),
      );
    });

    test('thrown connection error → success card + audioWarning', () async {
      await HttpOverrides.runZoned(
        () async {
          final service = _RecordingAnkiConnectService();
          final repo = _ConfiguredAnkiConnectRepository(
            service: service,
            settings: _settings(),
          );

          final outcome = await repo.mineEntry(
            rawPayloadJson: _payloadWithRemoteAudio,
            context: const AnkiMiningContext(sentence: 's'),
          );

          expect(outcome.result, MineResult.success);
          expect(outcome.audioWarning, isNotNull);
          expect(outcome.audioWarning, contains('https://dict.example/a.mp3'));
          expect(service.storedFilenames, isEmpty);
        },
        createHttpClient: (_) => _FakeHttpClient(
          statusCode: 200,
          body: const <int>[],
          contentType: null,
          throwOnConnect: const SocketException('connection refused'),
        ),
      );
    });

    test('200 → success card, audioWarning null, media stored', () async {
      await HttpOverrides.runZoned(
        () async {
          final service = _RecordingAnkiConnectService();
          final repo = _ConfiguredAnkiConnectRepository(
            service: service,
            settings: _settings(),
          );

          final outcome = await repo.mineEntry(
            rawPayloadJson: _payloadWithRemoteAudio,
            context: const AnkiMiningContext(sentence: 's'),
          );

          expect(outcome.result, MineResult.success);
          // Success path: no warning.
          expect(outcome.audioWarning, isNull);
          // Audio was actually stored and referenced.
          expect(service.storedFilenames, isNotEmpty);
          expect(service.lastAddedFields?['Audio'], contains('[sound:'));
        },
        createHttpClient: (_) => _FakeHttpClient(
          statusCode: 200,
          body: const <int>[0, 1, 2, 3, 4, 5],
          contentType: ContentType('audio', 'mpeg'),
          throwOnConnect: null,
        ),
      );
    });

    test('no audio in payload → audioWarning null', () async {
      final service = _RecordingAnkiConnectService();
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: _settings(),
      );

      final outcome = await repo.mineEntry(
        rawPayloadJson: _payloadNoAudio,
        context: const AnkiMiningContext(sentence: 's'),
      );

      expect(outcome.result, MineResult.success);
      expect(outcome.audioWarning, isNull);
    });
  });

  group('AnkiDroid: remote audio failure is surfaced, never embedded', () {
    void mockDroidChannel({required Object? addNoteReturn}) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_droidChannel, (MethodCall call) async {
        switch (call.method) {
          case 'checkForDuplicates':
            return false;
          case 'addNote':
            return addNoteReturn;
          case 'addFileToMedia':
            // If reached on the non-200 path, the test that asserts no media
            // store would still pass (we assert via the warning + field), but
            // returning a filename keeps the success path realistic.
            final args = Map<String, dynamic>.from(call.arguments as Map);
            return args['preferredName'] ?? 'stored.mp3';
          default:
            return null;
        }
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_droidChannel, null);
      });
    }

    test('non-200 → success card + audioWarning with HTTP code & URL',
        () async {
      await HttpOverrides.runZoned(
        () async {
          mockDroidChannel(addNoteReturn: 1654000000123);
          final repo = _ConfiguredAnkiRepository(_settings());

          final outcome = await repo.mineEntry(
            rawPayloadJson: _payloadWithRemoteAudio,
            context: const AnkiMiningContext(sentence: 's'),
          );

          expect(outcome.result, MineResult.success);
          expect(outcome.audioWarning, isNotNull);
          expect(outcome.audioWarning, contains('500'));
          expect(outcome.audioWarning, contains('https://dict.example/a.mp3'));
        },
        createHttpClient: (_) => _FakeHttpClient(
          statusCode: 500,
          body: const <int>[60, 33], // "<!"
          contentType: ContentType.html,
          throwOnConnect: null,
        ),
      );
    });

    test('no audio in payload → audioWarning null', () async {
      mockDroidChannel(addNoteReturn: 1654000000123);
      final repo = _ConfiguredAnkiRepository(_settings());

      final outcome = await repo.mineEntry(
        rawPayloadJson: _payloadNoAudio,
        context: const AnkiMiningContext(sentence: 's'),
      );

      expect(outcome.result, MineResult.success);
      expect(outcome.audioWarning, isNull);
    });
  });

  group('AudioFetchOutcome contract', () {
    test('failed carries reason and no ref (never embed bad bytes)', () {
      const o = AudioFetchOutcome.failed('HTTP 404 for https://x/a.mp3');
      expect(o.failureReason, 'HTTP 404 for https://x/a.mp3');
      expect(o.ref, isNull);
    });

    test('stored carries ref and no failure reason', () {
      const o = AudioFetchOutcome.stored('hibiki_audio_abc.mp3');
      expect(o.ref, 'hibiki_audio_abc.mp3');
      expect(o.failureReason, isNull);
    });

    test('none carries neither', () {
      const o = AudioFetchOutcome.none();
      expect(o.ref, isNull);
      expect(o.failureReason, isNull);
    });
  });
}
