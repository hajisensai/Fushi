import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('parseBangumiSearchResponse 映射', () {
    test('name_cn 优先、别名收 name、year/type/eps/score/detailUrl 正确', () {
      const String body = '''
{"data":[
  {"id":325285,"name":"無職転生Ⅲ","name_cn":"无职转生Ⅲ",
   "images":{"large":"https://img/large.jpg","common":"https://img/common.jpg"},
   "date":"2026-01-10","eps":12,"platform":"TV","score":8.1}
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

    test('缺 large 用 common；large/common 皆缺 → 跳过该条', () {
      const String body = '''
{"data":[
  {"id":2,"name":"A","images":{"common":"https://img/c.jpg"}},
  {"id":3,"name":"B","images":{}},
  {"id":4,"name":"C"}
]}''';
      final List<ScrapeCandidate> list = parseBangumiSearchResponse(body);
      expect(list, hasLength(1)); // 只有 id=2 有海报
      expect(list.first.posterUrl, 'https://img/c.jpg');
    });

    test('eps=0 → episodeCount 为 null；score=0 → ratingText 为 null', () {
      const String body = '''
{"data":[
  {"id":5,"name":"D","images":{"large":"https://img/l.jpg"},
   "eps":0,"score":0}
]}''';
      final ScrapeCandidate c = parseBangumiSearchResponse(body).first;
      expect(c.episodeCount, isNull);
      expect(c.ratingText, isNull);
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
        'hibiki-reader/scraper (https://github.com/hajisensai)',
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
