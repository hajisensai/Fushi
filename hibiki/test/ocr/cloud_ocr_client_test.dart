/// P4 云端 VLM 手写兜底：请求体结构（inline_data/prompt）、成功解析、
/// 非 200 / 超时 / 空回错误、以及服务层闸门（默认关 → 零网络调用）。
/// http 层用 fake [HttpClientAdapter]，不发真请求。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/ocr/cloud_ocr_client.dart';

/// 记录请求并按脚本回话的 fake adapter。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_FakeAdapter adapter) {
  final Dio dio = Dio();
  dio.httpClientAdapter = adapter;
  return dio;
}

ResponseBody _jsonResponse(Object body, {int status = 200}) {
  return ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    },
  );
}

Object _candidates(String text) {
  return <String, Object?>{
    'candidates': <Object?>[
      <String, Object?>{
        'content': <String, Object?>{
          'parts': <Object?>[
            <String, Object?>{'text': text},
          ],
        },
      },
    ],
  };
}

final Uint8List _png = Uint8List.fromList(<int>[1, 2, 3, 4]);

void main() {
  group('纯函数', () {
    test('resolveCloudOcrModel：空/空白 → 默认档', () {
      expect(resolveCloudOcrModel(null), kCloudOcrDefaultModel);
      expect(resolveCloudOcrModel('  '), kCloudOcrDefaultModel);
      expect(resolveCloudOcrModel('gemini-2.5-pro'), 'gemini-2.5-pro');
    });

    test('isCloudOcrAvailable：开关开 + key 非空才可用', () {
      expect(isCloudOcrAvailable(enabled: true, apiKey: 'k'), isTrue);
      expect(isCloudOcrAvailable(enabled: false, apiKey: 'k'), isFalse);
      expect(isCloudOcrAvailable(enabled: true, apiKey: '  '), isFalse);
    });

    test('stripMarkdownFences：剥 ```/```json 围栏，普通文本原样', () {
      expect(stripMarkdownFences('こんにちは'), 'こんにちは');
      expect(stripMarkdownFences('```\nこんにちは\n```'), 'こんにちは');
      expect(stripMarkdownFences('```json\n{"a":1}\n```'), '{"a":1}');
      expect(stripMarkdownFences('```\n二行\nテキスト\n```'), '二行\nテキスト');
    });

    test('buildCloudOcrRequestBody：inline_data PNG base64 + 转写提示词', () {
      final Map<String, Object?> body = buildCloudOcrRequestBody(_png);
      final List<Object?> contents = body['contents']! as List<Object?>;
      final Map<String, Object?> turn =
          contents.single! as Map<String, Object?>;
      final List<Object?> parts = turn['parts']! as List<Object?>;
      expect(parts, hasLength(2));
      final Map<String, Object?> inline = (parts[0]!
          as Map<String, Object?>)['inline_data']! as Map<String, Object?>;
      expect(inline['mime_type'], 'image/png');
      expect(inline['data'], base64Encode(_png));
      final String prompt =
          (parts[1]! as Map<String, Object?>)['text']! as String;
      expect(prompt, kCloudOcrPrompt);
      // 提示词红线：逐字转写、竖排右→左、只回原文。
      expect(prompt.contains('一字一句'), isTrue);
      expect(prompt.contains('縦書き'), isTrue);
      expect(prompt.contains('原文のみ'), isTrue);
    });
  });

  group('CloudOcrClient', () {
    test('成功：URL 含模型与 key、请求体结构正确、解析首候选并剥围栏', () async {
      final _FakeAdapter adapter = _FakeAdapter((RequestOptions o) async =>
          _jsonResponse(_candidates('```\nこんにちは\n```')));
      final CloudOcrClient client = CloudOcrClient(
        apiKey: 'test-key',
        model: null,
        dio: _dioWith(adapter),
      );

      final String text = await client.transcribePng(_png);
      expect(text, 'こんにちは');

      final RequestOptions request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.path,
          '/v1beta/models/$kCloudOcrDefaultModel:generateContent');
      expect(request.uri.queryParameters['key'], 'test-key');
      // 请求体是 buildCloudOcrRequestBody 的结构。
      final Map<String, Object?> data = request.data! as Map<String, Object?>;
      expect(data.keys, contains('contents'));
    });

    test('模型可设置覆盖', () async {
      final _FakeAdapter adapter = _FakeAdapter(
          (RequestOptions o) async => _jsonResponse(_candidates('x')));
      final CloudOcrClient client = CloudOcrClient(
        apiKey: 'k',
        model: 'gemini-2.5-pro',
        dio: _dioWith(adapter),
      );
      await client.transcribePng(_png);
      expect(adapter.requests.single.uri.path,
          '/v1beta/models/gemini-2.5-pro:generateContent');
    });

    test('非 200 → CloudOcrException（含状态码与 API error.message）', () async {
      final _FakeAdapter adapter = _FakeAdapter(
          (RequestOptions o) async => _jsonResponse(<String, Object?>{
                'error': <String, Object?>{'message': 'API key not valid'},
              }, status: 400));
      final CloudOcrClient client =
          CloudOcrClient(apiKey: 'bad', dio: _dioWith(adapter));
      await expectLater(
        client.transcribePng(_png),
        throwsA(isA<CloudOcrException>().having(
          (CloudOcrException e) => e.message,
          'message',
          allOf(contains('400'), contains('API key not valid')),
        )),
      );
    });

    test('超时（DioError）→ CloudOcrException（network error）', () async {
      final _FakeAdapter adapter = _FakeAdapter((RequestOptions o) async {
        throw DioError.connectionTimeout(
          timeout: const Duration(seconds: 1),
          requestOptions: o,
        );
      });
      final CloudOcrClient client =
          CloudOcrClient(apiKey: 'k', dio: _dioWith(adapter));
      await expectLater(
        client.transcribePng(_png),
        throwsA(isA<CloudOcrException>().having(
          (CloudOcrException e) => e.message,
          'message',
          contains('network error'),
        )),
      );
    });

    test('空回（无候选/空文本）→ CloudOcrException', () async {
      final _FakeAdapter adapter = _FakeAdapter((RequestOptions o) async =>
          _jsonResponse(<String, Object?>{'candidates': <Object?>[]}));
      final CloudOcrClient client =
          CloudOcrClient(apiKey: 'k', dio: _dioWith(adapter));
      await expectLater(
        client.transcribePng(_png),
        throwsA(isA<CloudOcrException>().having(
          (CloudOcrException e) => e.message,
          'message',
          contains('empty'),
        )),
      );
    });

    test('key 为空 → 本地即失败，零请求', () async {
      final _FakeAdapter adapter = _FakeAdapter(
          (RequestOptions o) async => _jsonResponse(_candidates('x')));
      final CloudOcrClient client =
          CloudOcrClient(apiKey: '  ', dio: _dioWith(adapter));
      await expectLater(
          client.transcribePng(_png), throwsA(isA<CloudOcrException>()));
      expect(adapter.requests, isEmpty);
    });
  });

  group('CloudOcrService 闸门（红线：默认关 → 零网络调用）', () {
    test('开关关：抛 StateError 且 adapter 零调用', () async {
      final _FakeAdapter adapter = _FakeAdapter(
          (RequestOptions o) async => _jsonResponse(_candidates('x')));
      final CloudOcrService service = CloudOcrService(
        enabled: false,
        apiKey: 'valid-key',
        dio: _dioWith(adapter),
      );
      expect(service.isAvailable, isFalse);
      expect(() => service.transcribePng(_png), throwsStateError);
      expect(adapter.requests, isEmpty, reason: '关着时零网络调用（红线）');
    });

    test('开关开但 key 空：同样拦下，零调用', () async {
      final _FakeAdapter adapter = _FakeAdapter(
          (RequestOptions o) async => _jsonResponse(_candidates('x')));
      final CloudOcrService service = CloudOcrService(
        enabled: true,
        apiKey: '',
        dio: _dioWith(adapter),
      );
      expect(service.isAvailable, isFalse);
      expect(() => service.transcribePng(_png), throwsStateError);
      expect(adapter.requests, isEmpty);
    });

    test('开关开 + key 非空：放行并透传结果', () async {
      final _FakeAdapter adapter = _FakeAdapter(
          (RequestOptions o) async => _jsonResponse(_candidates('テスト')));
      final CloudOcrService service = CloudOcrService(
        enabled: true,
        apiKey: 'k',
        model: '',
        dio: _dioWith(adapter),
      );
      expect(service.isAvailable, isTrue);
      expect(await service.transcribePng(_png), 'テスト');
      expect(adapter.requests, hasLength(1));
    });
  });
}
