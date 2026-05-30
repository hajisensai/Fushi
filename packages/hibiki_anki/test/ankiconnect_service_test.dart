import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/src/ankiconnect/ankiconnect_service.dart';

// HBK-AUDIT-051: the AnkiConnect network IPC layer was untested — only model
// JSON round-trips were covered. These tests exercise the real request shaping
// (endpoint, JSON body, action/version=6 protocol envelope), response parsing,
// and error mapping by injecting a fake HttpClient via the service's
// `clientFactory` seam (no real socket is opened).

void main() {
  // Captures the requests issued through one factory so assertions can inspect
  // the exact URL and JSON body the service put on the wire.
  late List<_FakeRequest> issued;

  /// Build a service whose every `_invoke` gets a fresh fake client returning
  /// [status] + a JSON envelope `{result, error}`. Each issued request is
  /// recorded in [issued].
  AnkiConnectService serviceReturning({
    int status = 200,
    Object? result,
    Object? error,
    String? rawBody,
  }) {
    issued = <_FakeRequest>[];
    final String body = rawBody ??
        jsonEncode(<String, Object?>{'result': result, 'error': error});
    return AnkiConnectService(
      host: '127.0.0.1',
      port: 8765,
      clientFactory: () {
        final response = _FakeResponse(status, utf8.encode(body));
        final request = _FakeRequest(response);
        issued.add(request);
        return _FakeHttpClient(request);
      },
    );
  }

  Map<String, dynamic> lastBody() =>
      jsonDecode(issued.single.bodyString) as Map<String, dynamic>;

  group('request envelope', () {
    test('posts to the configured host/port at path / over http', () async {
      final service = serviceReturning(result: const <String>[]);
      await service.getDeckNames();

      final Uri url = issued.single.url!;
      expect(url.scheme, 'http');
      expect(url.host, '127.0.0.1');
      expect(url.port, 8765);
      expect(url.path, '/');
    });

    test('every call carries action + version 6', () async {
      final service = serviceReturning(result: const <String>[]);
      await service.getModelNames();

      final body = lastBody();
      expect(body['action'], 'modelNames');
      expect(body['version'], 6);
    });

    test('omits params when none are supplied', () async {
      final service = serviceReturning(result: const <String>[]);
      await service.getDeckNames();
      expect(lastBody().containsKey('params'), isFalse);
    });

    test('includes params when supplied', () async {
      final service = serviceReturning(result: const <String>[]);
      await service.getModelFields('Basic');
      final body = lastBody();
      expect(body['action'], 'modelFieldNames');
      expect(body['params'], <String, dynamic>{'modelName': 'Basic'});
    });
  });

  group('result parsing', () {
    test('getDeckNames returns the result list as strings', () async {
      final service = serviceReturning(result: <String>['Default', '日本語']);
      expect(await service.getDeckNames(), <String>['Default', '日本語']);
    });

    test('getModelFields returns the field list', () async {
      final service =
          serviceReturning(result: <String>['Front', 'Back', 'Reading']);
      expect(await service.getModelFields('Basic'),
          <String>['Front', 'Back', 'Reading']);
    });
  });

  group('error mapping', () {
    test('non-200 HTTP status throws AnkiConnectException', () async {
      final service = serviceReturning(status: 500, result: null);
      expect(
        () => service.getDeckNames(),
        throwsA(isA<AnkiConnectException>()
            .having((e) => e.message, 'message', contains('500'))),
      );
    });

    test('a non-null error field throws AnkiConnectException with its text',
        () async {
      final service = serviceReturning(error: 'collection is not available');
      expect(
        () => service.getModelNames(),
        throwsA(isA<AnkiConnectException>().having(
            (e) => e.message, 'message', 'collection is not available')),
      );
    });

    test('checkConnection returns null when version succeeds', () async {
      final service = serviceReturning(result: 6);
      expect(await service.checkConnection(), isNull);
    });

    test('checkConnection surfaces the AnkiConnect error message', () async {
      final service = serviceReturning(error: 'unauthorized');
      expect(await service.checkConnection(), 'unauthorized');
    });

    test(
        'checkConnection reports a connect failure for a non-AnkiConnect throw',
        () async {
      // A malformed (non-JSON) body makes jsonDecode throw a non-Anki error,
      // which checkConnection must wrap rather than leak.
      final service = serviceReturning(rawBody: 'not json at all');
      final String? result = await service.checkConnection();
      expect(result, isNotNull);
      expect(result, contains('Cannot connect to AnkiConnect'));
    });
  });

  group('isDuplicate query shaping', () {
    test('builds a deck/field scoped findNotes query', () async {
      final service = serviceReturning(result: const <int>[]);
      await service.isDuplicate(
        deckName: 'Mining',
        fieldName: 'Expression',
        fieldValue: '勉強',
      );
      final body = lastBody();
      expect(body['action'], 'findNotes');
      expect((body['params'] as Map)['query'], 'deck:"Mining" "Expression:勉強"');
    });

    test('escapes double quotes in the field value', () async {
      final service = serviceReturning(result: const <int>[]);
      await service.isDuplicate(
        deckName: 'Mining',
        fieldName: 'Expression',
        fieldValue: 'a"b',
      );
      expect((lastBody()['params'] as Map)['query'],
          r'deck:"Mining" "Expression:a\"b"');
    });

    test('returns true when findNotes returns matches', () async {
      final service = serviceReturning(result: <int>[1, 2, 3]);
      expect(
        await service.isDuplicate(
            deckName: 'D', fieldName: 'F', fieldValue: 'v'),
        isTrue,
      );
    });

    test('returns false when findNotes returns no matches', () async {
      final service = serviceReturning(result: const <int>[]);
      expect(
        await service.isDuplicate(
            deckName: 'D', fieldName: 'F', fieldValue: 'v'),
        isFalse,
      );
    });
  });

  group('addNote payload', () {
    test('wraps the note with deck/model/fields/tags and dup option', () async {
      final service = serviceReturning(result: 1234567890);
      await service.addNote(
        deckName: 'Mining',
        modelName: 'Lapis',
        fields: <String, String>{'Expression': '勉強', 'Reading': 'べんきょう'},
        tags: <String>['hibiki', 'mined'],
        allowDuplicate: true,
      );

      final body = lastBody();
      expect(body['action'], 'addNote');
      final note = (body['params'] as Map)['note'] as Map;
      expect(note['deckName'], 'Mining');
      expect(note['modelName'], 'Lapis');
      expect(note['fields'],
          <String, dynamic>{'Expression': '勉強', 'Reading': 'べんきょう'});
      expect(note['tags'], <String>['hibiki', 'mined']);
      expect((note['options'] as Map)['allowDuplicate'], isTrue);
    });

    test('defaults allowDuplicate to false', () async {
      final service = serviceReturning(result: 1);
      await service.addNote(
        deckName: 'D',
        modelName: 'M',
        fields: const <String, String>{'F': 'v'},
        tags: const <String>[],
      );
      final note = (lastBody()['params'] as Map)['note'] as Map;
      expect((note['options'] as Map)['allowDuplicate'], isFalse);
    });

    test('propagates an AnkiConnect error from addNote', () async {
      final service = serviceReturning(
          error: 'cannot create note because it is a duplicate');
      expect(
        () => service.addNote(
          deckName: 'D',
          modelName: 'M',
          fields: const <String, String>{'F': 'v'},
          tags: const <String>[],
        ),
        throwsA(isA<AnkiConnectException>()),
      );
    });
  });

  group('storeMediaFile payload', () {
    test('sends filename + base64 data', () async {
      final service = serviceReturning(result: 'hibiki_audio_abc.mp3');
      await service.storeMediaFile(
        filename: 'hibiki_audio_abc.mp3',
        data: 'QUJD',
      );
      final params = lastBody()['params'] as Map;
      expect(lastBody()['action'], 'storeMediaFile');
      expect(params['filename'], 'hibiki_audio_abc.mp3');
      expect(params['data'], 'QUJD');
    });
  });
}

// ── Fake dart:io HttpClient stack ────────────────────────────────────────────
// Only the surface the service touches is implemented; everything else routes
// through noSuchMethod and is never invoked by these tests.

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._request);
  final _FakeRequest _request;
  bool closed = false;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    _request.url = url;
    return _request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this._response);
  final _FakeResponse _response;
  final BytesBuilder _body = BytesBuilder();
  final _FakeHeaders _headers = _FakeHeaders();
  Uri? url;

  String get bodyString => utf8.decode(_body.takeBytes());

  @override
  HttpHeaders get headers => _headers;

  @override
  void add(List<int> data) => _body.add(data);

  @override
  Future<HttpClientResponse> close() async => _response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  // contentType= and all other header mutations are no-ops for the fake.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, this._bytes);

  @override
  final int statusCode;
  final List<int> _bytes;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable(<List<int>>[_bytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
