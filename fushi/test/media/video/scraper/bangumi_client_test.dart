import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/scraper/bangumi_client.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('parseBangumiSearchResponse 映射', () {
    // 夹具形态即真实 `/v0/search/subjects` 响应形态：评分是**嵌套**
    // `rating:{score,total}`，响应里没有顶层 `score` 键。以前这里伪造了一个扁平
    // `"score":8.1`，解析器读扁平键就"通过"了，而生产环境三个评分字段恒空。
    test('name_cn 优先、别名收 name、year/type/eps/评分/detailUrl 正确', () {
      const String body = '''
{"data":[
  {"id":325285,"name":"無職転生Ⅲ","name_cn":"无职转生Ⅲ",
   "images":{"large":"https://img/large.jpg","common":"https://img/common.jpg"},
   "date":"2026-01-10","eps":12,"platform":"TV",
   "rating":{"score":8.1,"total":35890}}
]}''';
      final List<ScrapeCandidate> list = parseBangumiSearchResponse(body);
      expect(list, hasLength(1));
      final ScrapeCandidate c = list.first;
      expect(c.source, ScrapeSource.bangumi);
      expect(c.entryId, '325285');
      expect(c.title, '无职转生Ⅲ'); // name_cn 优先
      expect(c.aliases, <String>['無職転生Ⅲ']); // 别名收 name
      expect(c.year, 2026);
      expect(c.type, ScrapeEntryType.tv);
      expect(c.episodeCount, 12);
      expect(c.posterUrl, 'https://img/large.jpg'); // 优先 large
      expect(c.detailUrl, 'https://bgm.tv/subject/325285');
      expect(c.ratingText, 'Bangumi 8.1');
      // 契约：ratingText 只是 rating 的展示化文本，二者必须同源同时填。
      expect(c.rating, 8.1);
      expect(c.ratingCount, 35890);
    });

    test('name_cn 为空 → title 回退 name，无别名', () {
      const String body = '''
{"data":[
  {"id":1,"name":"ワンピース","name_cn":"",
   "images":{"large":"https://img/l.jpg"},"eps":1000,"platform":"TV"}
]}''';
      final List<ScrapeCandidate> list = parseBangumiSearchResponse(body);
      expect(list.first.title, 'ワンピース');
      expect(list.first.aliases, isEmpty);
    });

    test('缺 large 用 common 原图；所有尺寸皆缺 → 跳过该条', () {
      const String body = '''
{"data":[
  {"id":2,"name":"A","images":{"common":"https://lain.bgm.tv/r/400/pic/cover/l/a/b/c.jpg"}},
  {"id":3,"name":"B","images":{}},
  {"id":4,"name":"C"}
]}''';
      final List<ScrapeCandidate> list = parseBangumiSearchResponse(body);
      expect(list, hasLength(1)); // 只有 id=2 有海报
      expect(
        list.first.posterUrl,
        'https://lain.bgm.tv/pic/cover/l/a/b/c.jpg',
      );
    });

    test('eps=0 → episodeCount 为 null；rating.score=0 是「暂无评分」→ 评分三字段全空',
        () {
      const String body = '''
{"data":[
  {"id":5,"name":"D","images":{"large":"https://img/l.jpg"},
   "eps":0,"rating":{"score":0,"total":0}}
]}''';
      final ScrapeCandidate c = parseBangumiSearchResponse(body).first;
      expect(c.episodeCount, isNull);
      expect(c.ratingText, isNull);
      expect(c.rating, isNull);
      expect(c.ratingCount, isNull);
    });

    test('无 rating 节点 → 评分三字段全空且不抛', () {
      const String body = '''
{"data":[
  {"id":6,"name":"E","images":{"large":"https://img/l.jpg"},"eps":12}
]}''';
      final ScrapeCandidate c = parseBangumiSearchResponse(body).first;
      expect(c.rating, isNull);
      expect(c.ratingCount, isNull);
      expect(c.ratingText, isNull);
    });

    test('扁平 score 回退仍受支持（旧缓存 / 旧夹具兼容）', () {
      const String body = '''
{"data":[
  {"id":7,"name":"F","images":{"large":"https://img/l.jpg"},
   "eps":12,"score":7.2}
]}''';
      final ScrapeCandidate c = parseBangumiSearchResponse(body).first;
      expect(c.rating, 7.2);
      expect(c.ratingText, 'Bangumi 7.2');
      // 扁平形态只有分数、没有人数。
      expect(c.ratingCount, isNull);
    });

    test('嵌套 rating.score 优先于扁平 score', () {
      const String body = '''
{"data":[
  {"id":8,"name":"G","images":{"large":"https://img/l.jpg"},
   "eps":12,"score":1.1,"rating":{"score":9.3,"total":42}}
]}''';
      final ScrapeCandidate c = parseBangumiSearchResponse(body).first;
      expect(c.rating, 9.3);
      expect(c.ratingCount, 42);
    });

    test('platform 剧场版/Movie→movie、OVA→ova、其它→unknown', () {
      List<ScrapeCandidate> parse(String platform) =>
          parseBangumiSearchResponse(
            '{"data":[{"id":9,"name":"X","platform":"$platform",'
            '"images":{"large":"https://i/l.jpg"}}]}',
          );
      expect(parse('剧场版').first.type, ScrapeEntryType.movie);
      expect(parse('Movie').first.type, ScrapeEntryType.movie);
      expect(parse('OVA').first.type, ScrapeEntryType.ova);
      expect(parse('WEB').first.type, ScrapeEntryType.unknown);
    });

    test('data 缺失或非数组 → 空列表（不抛）', () {
      expect(parseBangumiSearchResponse('{}'), isEmpty);
      expect(parseBangumiSearchResponse('{"data":null}'), isEmpty);
    });

    test('非法 JSON → 抛 ScrapeNetworkException', () {
      expect(
        () => parseBangumiSearchResponse('not json'),
        throwsA(isA<ScrapeNetworkException>()),
      );
    });
  });

  group('BangumiClient.search', () {
    test('带 UA / Content-Type 头、body 含 keyword+filter、成功映射', () async {
      Map<String, String>? capturedHeaders;
      Object? capturedBody;
      Uri? capturedUri;
      final MockClient client = MockClient((http.Request req) async {
        capturedHeaders = req.headers;
        capturedBody = jsonDecode(req.body);
        capturedUri = req.url;
        return http.Response.bytes(
          utf8.encode('{"data":[{"id":7,"name":"テスト","name_cn":"测试",'
              '"images":{"large":"https://i/l.jpg"},"platform":"TV","eps":24}]}'),
          200,
        );
      });
      final List<ScrapeCandidate> list =
          await BangumiClient(client: client).search('鬼滅', limit: 5);

      expect(list, hasLength(1));
      expect(list.first.title, '测试');
      // UA 头必须带（Bangumi 要求可识别 UA）。
      expect(
        capturedHeaders?['user-agent'],
        'fushi-reader/scraper (https://github.com/hajisensai)',
      );
      expect(capturedHeaders?['content-type'], contains('application/json'));
      // body 结构正确（keyword + filter.type=[2]）。
      final Map<String, Object?> body =
          (capturedBody as Map).cast<String, Object?>();
      expect(body['keyword'], '鬼滅');
      expect((body['filter'] as Map)['type'], <int>[2]);
      expect(capturedUri?.queryParameters['limit'], '5');
    });

    test('500 响应 → 抛 ScrapeNetworkException(statusCode=500)', () async {
      final MockClient client =
          MockClient((http.Request req) async => http.Response('err', 500));
      await expectLater(
        BangumiClient(client: client).search('x'),
        throwsA(
          isA<ScrapeNetworkException>().having(
              (ScrapeNetworkException e) => e.statusCode, 'statusCode', 500),
        ),
      );
    });
  });
}
