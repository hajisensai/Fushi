import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/sources/shinnku_discovery_source.dart';
import 'package:fushi/src/media/external_provider.dart';

/// 仿真 RSC 流片段（行前有序号,answer 数组内嵌其中）。
const String _rscBody = '''
1:"\$Sreact.fragment"
2:I[28237,["/_next/static/chunks/x.js"],""]
7:{"initialSearchTerm":"ATRI"}
a:{"answer":[{"id":"0/win/ATRI -My Dear Moments- v1.3.7z","info":{"file_path":"0/win/ATRI -My Dear Moments- v1.3.7z","upload_timestamp":1714176370808,"file_size":3781414904}},{"id":"合集id","info":{"file_path":"合集系列/浮士德galgame游戏合集/5/2020年6月/[200619] ATRI steam edition (files).rar","upload_timestamp":1714207573092,"file_size":945105047}},{"id":"0/apk/ATRI[han].apk","info":{"file_path":"0/apk/ATRI[han].apk","upload_timestamp":1714207573092,"file_size":1000}}]}
b:{"other":true}
''';

void main() {
  test('RSC 载荷解析 + 直链推导 + 类型标注', () async {
    Uri? captured;
    Map<String, String>? capturedHeaders;
    final ShinnkuDiscoverySource source = ShinnkuDiscoverySource(
      client: MockClient((http.Request request) async {
        captured = request.url;
        capturedHeaders = request.headers;
        return http.Response.bytes(utf8.encode(_rscBody), 200);
      }),
    );

    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.game, query: 'ATRI'),
    );

    expect(captured!.path, '/search');
    expect(captured!.queryParameters['q'], 'ATRI');
    expect(capturedHeaders!['RSC'], '1');

    final List<DiscoveryEntry> entries = result.items.single.entries;
    expect(entries, hasLength(3));

    final DiscoveryResourceItem win = entries[0] as DiscoveryResourceItem;
    expect(win.title, 'ATRI -My Dear Moments- v1.3.7z');
    expect(win.note, '熟肉');
    expect(win.sizeBytes, 3781414904);
    final DiscoveryHttpPayload winPayload =
        win.payload! as DiscoveryHttpPayload;
    expect(
      winPayload.url,
      'https://zd.shinnku.top/file/shinnku/0/'
      'win/ATRI%20-My%20Dear%20Moments-%20v1.3.7z',
    );

    final DiscoveryResourceItem collection =
        entries[1] as DiscoveryResourceItem;
    expect(collection.note, '生肉');
    final DiscoveryHttpPayload collectionPayload =
        collection.payload! as DiscoveryHttpPayload;
    expect(
      collectionPayload.url,
      startsWith('https://galgamedownload.date/%60%E3%80%90'),
      reason: '合集走 B2 桶且首段带反引号前缀(%60)',
    );
    expect(collectionPayload.url, isNot(contains('合集系列')));

    final DiscoveryResourceItem apk = entries[2] as DiscoveryResourceItem;
    expect(apk.note, '手机');
    expect(apk.detailUrl, contains('/files/0/apk/'));
  });

  test('第 2 页起空页收尾,不打网络', () async {
    int calls = 0;
    final ShinnkuDiscoverySource source = ShinnkuDiscoverySource(
      client: MockClient((http.Request request) async {
        calls++;
        return http.Response('', 500);
      }),
    );
    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(
        kind: DiscoveryMediaKind.game,
        query: 'x',
        page: 2,
      ),
    );
    expect(calls, 0);
    expect(result.items.single.entries, isEmpty);
    expect(result.items.single.hasMore, isFalse);
  });

  test('载荷里没有 answer 数组按 invalidResponse 失败(站点改版探测器)', () async {
    final ShinnkuDiscoverySource source = ShinnkuDiscoverySource(
      client: MockClient(
        (http.Request request) async =>
            http.Response.bytes(utf8.encode('1:"nothing here"'), 200),
      ),
    );
    expect(
      () => source.search(
        const DiscoveryRequest(kind: DiscoveryMediaKind.game, query: 'x'),
      ),
      throwsA(
        isA<ExternalProviderFailure>().having(
          (ExternalProviderFailure f) => f.kind,
          'kind',
          ExternalProviderFailureKind.invalidResponse,
        ),
      ),
    );
  });

  group('extractShinnkuAnswer', () {
    test('字符串内的括号与转义不破坏配平', () {
      const String body =
          r'x:{"answer":[{"id":"a[1]\"b","info":{"file_path":"p/[x] y.7z"}}]}';
      final List<dynamic>? answer = extractShinnkuAnswer(body);
      expect(answer, hasLength(1));
      expect(
        ((answer![0] as Map<String, dynamic>)['info']
            as Map<String, dynamic>)['file_path'],
        'p/[x] y.7z',
      );
    });

    test('第一个 marker 是坏 JSON 时继续找下一个', () {
      const String body =
          '{"answer": "not-array"} {"answer":[{"id":"ok","info":{"file_path":"a/b"}}]}';
      final List<dynamic>? answer = extractShinnkuAnswer(body);
      expect(answer, hasLength(1));
    });

    test('无 marker 返回 null', () {
      expect(extractShinnkuAnswer('nothing'), isNull);
    });
  });

  group('shinnkuDownloadUrl / shinnkuGameTypeNote', () {
    test('zd 前缀熟肉走 zd.shinnku.top', () {
      expect(
        shinnkuDownloadUrl('zd/1501-2000/x.rar'),
        'https://zd.shinnku.top/file/shinnku/zd/1501-2000/x.rar',
      );
      expect(shinnkuGameTypeNote('zd/1501-2000/x.rar'), '熟肉');
    });

    test('合集系列剥首段换 B2 桶前缀', () {
      final String url = shinnkuDownloadUrl('合集系列/子目录/y.rar');
      expect(url, startsWith('https://galgamedownload.date/'));
      expect(url, contains('%60')); // 反引号前缀
      expect(url, contains(Uri.encodeComponent('子目录')));
      expect(shinnkuGameTypeNote('合集系列/子目录/y.rar'), '生肉');
    });

    test('其余按手机标注', () {
      expect(shinnkuGameTypeNote('0/krkr/z.7z'), '手机');
    });
  });
}
