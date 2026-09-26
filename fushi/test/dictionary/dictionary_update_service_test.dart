import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

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

  group('DictionaryUpdateService.fetchRemoteIndexResult', () {
    test('合法 revision 明确标记检查成功', () async {
      final Dio dio = _dioWith(
        _FakeAdapter((String url) => _body('{"revision":"2026-07-29"}')),
      );

      final DictionaryRemoteIndexResult result =
          await DictionaryUpdateService.fetchRemoteIndexResult(
        'https://x/index.json',
        dio: dio,
      );

      expect(result.succeeded, isTrue);
      expect(result.revision, '2026-07-29');
    });

    test('网络失败与坏 index 明确标记检查失败', () async {
      final Dio networkDio = _dioWith(
        _FakeAdapter(
          (String url) =>
              throw DioError(requestOptions: RequestOptions(path: url)),
        ),
      );
      final Dio invalidDio = _dioWith(
        _FakeAdapter((String url) => _body('{"title":"missing revision"}')),
      );

      final DictionaryRemoteIndexResult networkResult =
          await DictionaryUpdateService.fetchRemoteIndexResult(
        'https://x/network.json',
        dio: networkDio,
      );
      final DictionaryRemoteIndexResult invalidResult =
          await DictionaryUpdateService.fetchRemoteIndexResult(
        'https://x/invalid.json',
        dio: invalidDio,
      );

      expect(networkResult.succeeded, isFalse);
      expect(networkResult.revision, isNull);
      expect(invalidResult.succeeded, isFalse);
      expect(invalidResult.revision, isNull);
    });
  });

  // 用户报告（2026-09-26）：「更新」按钮要自己下新包选文件，和 Yomitan 不一样。
  // 两个根因：钉了版本号的 downloadUrl 用本地旧地址下回来还是旧包；旧版导入的
  // 词典 metadata 缺来源字段，被判不可更新。下面钉这两条的纯函数契约。
  const String pixivOldIndex = '{"title":"Pixiv Light [2026-03-26]","format":3,'
      '"revision":"2026-03-26","isUpdatable":true,'
      '"indexUrl":"https://github.com/MarvNC/pixiv-yomitan/releases/latest/download/pixiv_light_index.json",'
      '"downloadUrl":"https://github.com/MarvNC/pixiv-yomitan/releases/download/2026-03-26/PixivLight_2026-03-26.zip"}';
  const String pixivNewZip =
      'https://github.com/MarvNC/pixiv-yomitan/releases/download/2026-04-20/PixivLight_2026-04-20.zip';

  group('远端 index 的 downloadUrl（钉版本号的包地址）', () {
    test('fetchRemoteIndexResult 带回远端声明的新包地址', () async {
      final Dio dio = _dioWith(_FakeAdapter((String url) =>
          _body('{"revision":"2026-04-20","downloadUrl":"$pixivNewZip"}')));

      final DictionaryRemoteIndexResult result =
          await DictionaryUpdateService.fetchRemoteIndexResult(
        'https://x/pixiv_light_index.json',
        dio: dio,
      );

      expect(result.succeeded, isTrue);
      expect(result.downloadUrl, pixivNewZip);
    });

    test('resolveDownloadUrl：远端优先，本地旧地址不能再被用来「更新」', () {
      final Map<String, String> local =
          parseSourceMetadataFromIndexJson(pixivOldIndex);
      const DictionaryRemoteIndexResult remote =
          DictionaryRemoteIndexResult.success('2026-04-20',
              downloadUrl: pixivNewZip);

      expect(remote.resolveDownloadUrl(local['downloadUrl']!), pixivNewZip);
    });

    test('远端没声明 downloadUrl → 回退本地（releases/latest 恒指最新）', () {
      const DictionaryRemoteIndexResult remote =
          DictionaryRemoteIndexResult.success('JMdict.2026-04-01');
      const String latest =
          'https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/JMdict.zip';

      expect(remote.resolveDownloadUrl(latest), latest);
      expect(
        DictionaryUpdateService.parseDownloadUrlFromIndexJson(
            '{"revision":"x","downloadUrl":"  "}'),
        isNull,
      );
      expect(
          DictionaryUpdateService.parseDownloadUrlFromIndexJson('bad'), isNull);
    });
  });

  group('旧词典来源字段回填（kDictSourceProbeKey）', () {
    test('缺全部来源字段 → 需要回填；已有来源字段或已回填过 → 不需要', () {
      expect(needsSourceMetadataBackfill(const <String, String>{}), isTrue);
      expect(
        needsSourceMetadataBackfill(const <String, String>{'typeProbe': '1'}),
        isTrue,
        reason: '类型自愈标记不是来源字段',
      );
      expect(
        needsSourceMetadataBackfill(const <String, String>{'revision': 'r'}),
        isFalse,
      );
      expect(
        needsSourceMetadataBackfill(
            const <String, String>{kDictSourceProbeKey: '1'}),
        isFalse,
      );
    });

    test('用磁盘 index.json 回填后，旧导入的 Pixiv 变成可在线更新', () {
      final Dictionary legacy = Dictionary(
        name: 'Pixiv Light [2026-03-26]',
        formatKey: 'yomichan',
        order: 0,
        metadata: const <String, String>{'typeProbe': '1'},
      );
      expect(legacy.isUpdatable, isFalse, reason: '回填前：被判不可更新');

      final Dictionary backfilled = legacy.copyWith(
        metadata: mergeBackfilledSourceMetadata(
          legacy.metadata,
          parseSourceMetadataFromIndexJson(pixivOldIndex),
        ),
      );

      expect(backfilled.isUpdatable, isTrue);
      expect(backfilled.revision, '2026-03-26');
      expect(backfilled.metadata['typeProbe'], '1');
      expect(needsSourceMetadataBackfill(backfilled.metadata), isFalse);
    });

    test('包里本来没有来源字段 → 仍打标记，下次启动不再读盘', () {
      final Map<String, String> merged = mergeBackfilledSourceMetadata(
        const <String, String>{},
        parseSourceMetadataFromIndexJson('{"title":"大辞林","revision":""}'),
      );

      expect(merged[kDictSourceProbeKey], '1');
      expect(needsSourceMetadataBackfill(merged), isFalse);
      expect(merged.containsKey('isUpdatable'), isFalse);
    });

    test('已有 metadata 压过 index.json（不覆盖权威值）', () {
      final Map<String, String> merged = mergeBackfilledSourceMetadata(
        const <String, String>{'targetLanguage': 'zh'},
        parseSourceMetadataFromIndexJson(
            '{"targetLanguage":"ja","revision":"r"}'),
      );

      expect(merged['targetLanguage'], 'zh');
      expect(merged['revision'], 'r');
    });

    test('坏 JSON → 空 Map，不抛', () {
      expect(parseSourceMetadataFromIndexJson('{oops'), isEmpty);
      expect(parseSourceMetadataFromIndexJson('[1]'), isEmpty);
    });
  });
}
