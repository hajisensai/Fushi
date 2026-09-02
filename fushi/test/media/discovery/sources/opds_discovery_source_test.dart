/// `OpdsDiscoverySource` 的行为契约：域过滤、认证边界、链接驱动分页、
/// 响应体嗅探、失败收敛。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/media/discovery/sources/opds_discovery_source.dart';
import 'package:fushi/src/media/external_provider.dart';

OpdsServerConfig _config({
  String username = 'reader',
  String password = 'pw',
  String url = 'https://books.example.com/api/v1/opds',
}) =>
    OpdsServerConfig(
      id: 'srv1',
      name: 'My Books',
      catalogUrl: Uri.parse(url),
      username: username,
      password: password,
    );

OpdsDiscoverySource _source(MockClient client, {OpdsServerConfig? config}) =>
    OpdsDiscoverySource(config: config ?? _config(), client: client);

http.Response _xml(String body,
        {String contentType = 'application/atom+xml'}) =>
    http.Response.bytes(
      utf8.encode(body),
      200,
      headers: <String, String>{'content-type': contentType},
    );

/// 一页 acquisition feed：一本 epub + 一卷 cbz + 一个子目录。
const String _mixedFeed = '''
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <title>Series</title>
    <link href="/api/v1/opds/series"
          type="application/atom+xml;profile=opds-catalog;kind=navigation"/>
  </entry>
  <entry>
    <title>A Novel</title><id>urn:n:1</id>
    <link rel="http://opds-spec.org/acquisition" href="/dl/1"
          type="application/epub+zip" length="1024"/>
  </entry>
  <entry>
    <title>A Comic</title><id>urn:c:1</id>
    <link rel="http://opds-spec.org/acquisition" href="/dl/2"
          type="application/vnd.comicbook+zip"/>
  </entry>
</feed>
''';

void main() {
  test('browse:出版物按域过滤，目录恒保留', () async {
    final OpdsDiscoverySource source = _source(
      MockClient((http.Request request) async => _xml(_mixedFeed)),
    );
    final ProviderBatchResult<DiscoveryResultPage> novels = await source.browse(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel),
    );
    final List<DiscoveryEntry> novelEntries = novels.items.single.entries;
    expect(novelEntries.whereType<DiscoveryFolder>().single.title, 'Series');
    final DiscoveryResourceItem novel =
        novelEntries.whereType<DiscoveryResourceItem>().single;
    expect(novel.title, 'A Novel');
    expect(novel.kind, DiscoveryMediaKind.novel);

    final ProviderBatchResult<DiscoveryResultPage> manga = await source.browse(
      const DiscoveryRequest(kind: DiscoveryMediaKind.manga),
    );
    final List<DiscoveryResourceItem> mangaItems =
        manga.items.single.entries.whereType<DiscoveryResourceItem>().toList();
    expect(mangaItems.single.title, 'A Comic', reason: '漫画域不该列出只有 epub 的条目');
    // 目录在两个域下都在：里面装什么要点进去才知道。
    expect(
        manga.items.single.entries.whereType<DiscoveryFolder>(), hasLength(1));
    source.close();
  });

  test('payload 带扩展名文件名——直链无后缀时这是导入能否成功的唯一依据', () async {
    final OpdsDiscoverySource source = _source(
      MockClient((http.Request request) async => _xml(_mixedFeed)),
    );
    final ProviderBatchResult<DiscoveryResultPage> result = await source.browse(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel),
    );
    final DiscoveryResourceItem item =
        result.items.single.entries.whereType<DiscoveryResourceItem>().single;
    final DiscoveryHttpPayload payload = item.payload! as DiscoveryHttpPayload;
    // 直链是 /dl/1（无扩展名）；下载队列不读 Content-Disposition，
    // 不给 fileName 就会落成无后缀文件并被分类器判 unknownFileType。
    expect(payload.url, 'https://books.example.com/dl/1');
    expect(payload.fileName, 'A Novel.epub');
    expect(payload.sizeBytes, 1024);
    source.close();
  });

  test('认证头只发给配置服务器自己的 origin', () async {
    final Map<String, String?> seen = <String, String?>{};
    final OpdsDiscoverySource source = _source(
      MockClient((http.Request request) async {
        seen[request.url.host] = request.headers['Authorization'];
        return _xml('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <title>Offsite</title><id>urn:o:1</id>
    <link rel="http://opds-spec.org/acquisition"
          href="https://cdn.other-host.net/dl/9"
          type="application/epub+zip"/>
  </entry>
</feed>
''');
      }),
    );
    final ProviderBatchResult<DiscoveryResultPage> result = await source.browse(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel),
    );
    expect(seen['books.example.com'], startsWith('Basic '));

    final DiscoveryHttpPayload payload = result.items.single.entries
        .whereType<DiscoveryResourceItem>()
        .single
        .payload! as DiscoveryHttpPayload;
    // 下载链接指向第三方主机：绝不能把用户的 OPDS 密码附上去。
    expect(payload.url, 'https://cdn.other-host.net/dl/9');
    expect(payload.headers.containsKey('Authorization'), isFalse,
        reason: '凭据绑定 origin，不跟着链接走');
    source.close();
  });

  test('匿名目录不发认证头', () async {
    String? seen = 'unset';
    final OpdsDiscoverySource source = _source(
      MockClient((http.Request request) async {
        seen = request.headers['Authorization'];
        return _xml('<feed xmlns="http://www.w3.org/2005/Atom"/>');
      }),
      config: _config(username: '', password: ''),
    );
    await source.browse(const DiscoveryRequest(kind: DiscoveryMediaKind.novel));
    expect(seen, isNull);
    source.close();
  });

  test('分页走 rel=next 的服务端地址，而不是自拼 ?page=N', () async {
    final List<String> requested = <String>[];
    final OpdsDiscoverySource source = _source(
      MockClient((http.Request request) async {
        requested.add(request.url.toString());
        if (request.url.query.contains('cursor=abc')) {
          return _xml('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry><title>P2</title><id>urn:p:2</id>
    <link rel="http://opds-spec.org/acquisition" href="/dl/2"
          type="application/epub+zip"/></entry>
</feed>
''');
        }
        return _xml('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <link rel="next" href="/api/v1/opds/books?cursor=abc"/>
  <entry><title>P1</title><id>urn:p:1</id>
    <link rel="http://opds-spec.org/acquisition" href="/dl/1"
          type="application/epub+zip"/></entry>
</feed>
''');
      }),
    );

    const String path = 'https://books.example.com/api/v1/opds/books';
    final ProviderBatchResult<DiscoveryResultPage> first = await source.browse(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel, path: path),
    );
    expect(first.items.single.hasMore, isTrue);

    final ProviderBatchResult<DiscoveryResultPage> second = await source.browse(
      const DiscoveryRequest(
        kind: DiscoveryMediaKind.novel,
        path: path,
        page: 2,
      ),
    );
    expect(
      (second.items.single.entries.single as DiscoveryResourceItem).title,
      'P2',
    );
    expect(second.items.single.hasMore, isFalse);
    expect(requested.last,
        'https://books.example.com/api/v1/opds/books?cursor=abc');
    // 第二页只多发了一次请求：第一页的 next 已被记住，没有从头回走。
    expect(requested, hasLength(2));
    source.close();
  });

  test('search:经 OpenSearch 描述文档拿模板，再用模板发搜索', () async {
    final List<String> requested = <String>[];
    final OpdsDiscoverySource source = _source(
      MockClient((http.Request request) async {
        requested.add(request.url.toString());
        if (request.url.path.endsWith('/opensearch.xml')) {
          return _xml('''
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
  <Url type="application/atom+xml;profile=opds-catalog"
       template="/api/v1/opds/search?q={searchTerms}"/>
</OpenSearchDescription>
''');
        }
        if (request.url.path.endsWith('/search')) {
          return _xml('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry><title>Hit</title><id>urn:h:1</id>
    <link rel="http://opds-spec.org/acquisition" href="/dl/h"
          type="application/epub+zip"/></entry>
</feed>
''');
        }
        return _xml('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <link rel="search" href="/opensearch.xml"
        type="application/opensearchdescription+xml"/>
</feed>
''');
      }),
    );

    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: '雪国'),
    );
    expect(
      (result.items.single.entries.single as DiscoveryResourceItem).title,
      'Hit',
    );
    expect(requested.last, contains('q=%E9%9B%AA%E5%9B%BD'));

    // 模板已缓存：第二次搜索不再重探根 feed 与描述文档。
    requested.clear();
    await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'x'),
    );
    expect(requested, hasLength(1));
    source.close();
  });

  test('服务器不提供搜索时收敛成 unsupported，而不是拼个假 URL 打过去', () async {
    final OpdsDiscoverySource source = _source(
      MockClient(
        (http.Request request) async =>
            _xml('<feed xmlns="http://www.w3.org/2005/Atom"/>'),
      ),
    );
    await expectLater(
      source.search(
        const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'q'),
      ),
      throwsA(
        isA<ExternalProviderFailure>().having(
          (ExternalProviderFailure f) => f.kind,
          'kind',
          ExternalProviderFailureKind.unsupported,
        ),
      ),
    );
    source.close();
  });

  test('嗅探优先于 Content-Type：JSON 体被标成 text/xml 也能解析', () async {
    // 自建服务端把 OPDS feed 标错 MIME 是实测存在的情形。
    final OpdsDiscoverySource source = _source(
      MockClient(
        (http.Request request) async => _xml(
          '{"publications":[{"metadata":{"title":"JsonBook"},'
          '"links":[{"rel":"http://opds-spec.org/acquisition",'
          '"href":"/dl/j","type":"application/epub+zip"}]}]}',
          contentType: 'text/xml',
        ),
      ),
    );
    final ProviderBatchResult<DiscoveryResultPage> result = await source.browse(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel),
    );
    expect(
      (result.items.single.entries.single as DiscoveryResourceItem).title,
      'JsonBook',
    );
    source.close();
  });

  test('401/403 收敛成 unauthorized/forbidden，消息里不带地址或凭据', () async {
    for (final (int status, ExternalProviderFailureKind kind)
        in <(int, ExternalProviderFailureKind)>[
      (401, ExternalProviderFailureKind.unauthorized),
      (403, ExternalProviderFailureKind.forbidden),
    ]) {
      final OpdsDiscoverySource source = _source(
        MockClient((http.Request request) async => http.Response('no', status)),
      );
      await expectLater(
        source.browse(const DiscoveryRequest(kind: DiscoveryMediaKind.novel)),
        throwsA(
          isA<ExternalProviderFailure>()
              .having((ExternalProviderFailure f) => f.kind, 'kind', kind)
              .having(
                (ExternalProviderFailure f) => f.message,
                'message',
                isNot(anyOf(contains('books.example.com'), contains('pw'))),
              ),
        ),
      );
      source.close();
    }
  });

  test('畸形响应体收敛成 invalidResponse，不把 feed 片段带进消息', () async {
    final OpdsDiscoverySource source = _source(
      MockClient((http.Request request) async => _xml('<feed><broken')),
    );
    await expectLater(
      source.browse(const DiscoveryRequest(kind: DiscoveryMediaKind.novel)),
      throwsA(
        isA<ExternalProviderFailure>().having(
          (ExternalProviderFailure f) => f.kind,
          'kind',
          ExternalProviderFailureKind.invalidResponse,
        ),
      ),
    );
    source.close();
  });

  test('源 id 由配置 id 派生且稳定（停用开关按它持久化）', () {
    expect(opdsSourceIdFor('srv1'), 'opds-srv1');
    final OpdsDiscoverySource source = _source(
      MockClient((http.Request request) async => _xml('<feed/>')),
    );
    expect(source.id, 'opds-srv1');
    expect(source.displayName, 'My Books');
    expect(source.capabilities.kinds, <DiscoveryMediaKind>{
      DiscoveryMediaKind.novel,
      DiscoveryMediaKind.manga,
    });
    source.close();
  });

  group('isSameOpdsOrigin', () {
    test('默认端口归一后同源', () {
      expect(
        isSameOpdsOrigin(
          Uri.parse('https://h/a'),
          Uri.parse('https://h:443/b'),
        ),
        isTrue,
      );
    });
    test('scheme/host/端口任一不同即异源', () {
      expect(
        isSameOpdsOrigin(Uri.parse('https://h/a'), Uri.parse('http://h/a')),
        isFalse,
      );
      expect(
        isSameOpdsOrigin(Uri.parse('https://h/a'), Uri.parse('https://i/a')),
        isFalse,
      );
      expect(
        isSameOpdsOrigin(
          Uri.parse('https://h/a'),
          Uri.parse('https://h:8443/a'),
        ),
        isFalse,
      );
    });
  });
}
