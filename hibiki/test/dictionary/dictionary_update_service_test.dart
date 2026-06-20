import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

/// TODO-609：DictionaryUpdateService 比对逻辑——纯函数守卫。
///
/// needsUpdate(local, remote)：远端 revision 非空且与本地不同 → 需更新。
/// remote 为 null/空（拉取失败或远端无 revision）→ 保守判 false（不误报有更新）。
/// parseRevisionFromIndexJson：从远端 index.json 文本取 revision，坏 JSON → null。
/// 可编程假 [HttpClientAdapter]：按 URL 返回 body 或抛错，验证 fetchRemoteIndex
/// 的网络契约（200 解析 revision / 失败返 null / body 空返 null / 注入不关闭）。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final FutureOr<ResponseBody> Function(String url) handler;
  bool closed = false;
  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return handler(options.uri.toString());
  }
}

Dio _dioWith(_FakeAdapter adapter) {
  final Dio dio = Dio();
  dio.httpClientAdapter = adapter;
  return dio;
}

ResponseBody _body(String text, {int status = 200}) =>
    ResponseBody.fromString(text, status, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>['application/json'],
    });

void main() {
  group('DictionaryUpdateService.needsUpdate', () {
    test('本地与远端 revision 相同 → false', () {
      expect(
        DictionaryUpdateService.needsUpdate('2026-06-20', '2026-06-20'),
        isFalse,
      );
    });

    test('本地与远端不同 → true', () {
      expect(
        DictionaryUpdateService.needsUpdate('2026-06-19', '2026-06-20'),
        isTrue,
      );
    });

    test('远端 null（拉取失败）→ false（不误报）', () {
      expect(DictionaryUpdateService.needsUpdate('2026-06-19', null), isFalse);
    });

    test('远端空串 → false', () {
      expect(DictionaryUpdateService.needsUpdate('2026-06-19', ''), isFalse);
    });

    test('本地空 + 远端非空 → true', () {
      expect(DictionaryUpdateService.needsUpdate('', '2026-06-20'), isTrue);
    });
  });

  group('DictionaryUpdateService.parseRevisionFromIndexJson', () {
    test('合法 index.json → revision', () {
      expect(
        DictionaryUpdateService.parseRevisionFromIndexJson(
          '{"title":"JMdict","revision":"2026-06-20"}',
        ),
        '2026-06-20',
      );
    });

    test('无 revision 字段 → null', () {
      expect(
        DictionaryUpdateService.parseRevisionFromIndexJson('{"title":"X"}'),
        isNull,
      );
    });

    test('revision 空串 → null', () {
      expect(
        DictionaryUpdateService.parseRevisionFromIndexJson('{"revision":""}'),
        isNull,
      );
    });

    test('坏 JSON → null（不崩）', () {
      expect(
        DictionaryUpdateService.parseRevisionFromIndexJson('not json'),
        isNull,
      );
    });

    test('顶层非对象 → null', () {
      expect(
        DictionaryUpdateService.parseRevisionFromIndexJson('[1,2]'),
        isNull,
      );
    });
  });

  group('DictionaryUpdateService.fetchRemoteIndex (注入 Dio)', () {
    test('200 + 合法 index.json → revision', () async {
      final _FakeAdapter adapter =
          _FakeAdapter((String url) => _body('{"revision":"2026-06-20"}'));
      final Dio dio = _dioWith(adapter);
      final String? rev = await DictionaryUpdateService.fetchRemoteIndex(
        'https://x/index.json',
        dio: dio,
      );
      expect(rev, '2026-06-20');
      // 注入的 Dio 不应被 fetchRemoteIndex 关闭（调用方负责生命周期）。
      expect(adapter.closed, isFalse);
    });

    test('body 空 → null', () async {
      final Dio dio = _dioWith(_FakeAdapter((String url) => _body('')));
      expect(
        await DictionaryUpdateService.fetchRemoteIndex('https://x/i.json',
            dio: dio),
        isNull,
      );
    });

    test('网络抛错 → null（不崩）', () async {
      final Dio dio = _dioWith(_FakeAdapter((String url) =>
          throw DioError(requestOptions: RequestOptions(path: url))));
      expect(
        await DictionaryUpdateService.fetchRemoteIndex('https://x/i.json',
            dio: dio),
        isNull,
      );
    });

    test('空 indexUrl → null（不发请求）', () async {
      expect(await DictionaryUpdateService.fetchRemoteIndex(''), isNull);
    });
  });
}
