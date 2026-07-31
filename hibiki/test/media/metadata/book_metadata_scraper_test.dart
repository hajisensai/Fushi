import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/metadata/book_metadata_scraper.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('parseBookSearchResponse 映射', () {
    test('name_cn 优先、封面取 large、year/summary/detailUrl 正确', () {
      const String body = '''
{"data":[
  {"id":9999,"name":"よつばと！","name_cn":"四叶妹妹！",
   "images":{"large":"https://img/large.jpg","common":"https://img/common.jpg"},
   "date":"2003-08-10","summary":"あずまきよひこ"}
]}''';
      final List<BookScrapeCandidate> list = parseBookSearchResponse(body);
      expect(list, hasLength(1));
      final BookScrapeCandidate c = list.first;
      expect(c.subjectId, '9999');
      expect(c.title, '四叶妹妹！'); // name_cn 优先
      expect(c.originalTitle, 'よつばと！'); // 原名与主标题不同才留
      expect(c.coverUrl, 'https://img/large.jpg'); // 满分辨率优先 large
      expect(c.year, 2003);
      expect(c.summary, 'あずまきよひこ');
      expect(c.detailUrl, 'https://bgm.tv/subject/9999');
    });

    test('name_cn 为空 → title 回退 name，无 originalTitle', () {
      const String body = '''
{"data":[
  {"id":1,"name":"ONE PIECE","name_cn":"",
   "images":{"large":"https://img/l.jpg"}}
]}''';
      final BookScrapeCandidate c = parseBookSearchResponse(body).first;
      expect(c.title, 'ONE PIECE');
      expect(c.originalTitle, isNull);
    });

    test('缺 large 用 common 原图；无任何封面 → 跳过该条', () {
      const String body = '''
{"data":[
  {"id":2,"name":"A","images":{"common":"https://lain.bgm.tv/pic/cover/c/a/b/c.jpg"}},
  {"id":3,"name":"B","images":{}},
  {"id":4,"name":"C"}
]}''';
      final List<BookScrapeCandidate> list = parseBookSearchResponse(body);
      expect(list, hasLength(1)); // 只有 id=2 有封面
      expect(
        list.first.coverUrl,
        'https://lain.bgm.tv/pic/cover/l/a/b/c.jpg',
      );
    });

    test('data 缺失/非数组 → 空列表（不抛）；非法 JSON → 抛', () {
      expect(parseBookSearchResponse('{}'), isEmpty);
      expect(parseBookSearchResponse('{"data":null}'), isEmpty);
      expect(
        () => parseBookSearchResponse('not json'),
        throwsA(isA<BookScrapeException>()),
      );
    });
  });

  group('BookMetadataScraper.search', () {
    test('POST filter.type=[1] 书籍，成功映射', () async {
      Object? capturedBody;
      final MockClient client = MockClient((http.Request req) async {
        capturedBody = jsonDecode(req.body);
        return http.Response.bytes(
          utf8.encode('{"data":[{"id":7,"name":"テスト","name_cn":"测试",'
              '"images":{"large":"https://i/l.jpg"}}]}'),
          200,
        );
      });
      final List<BookScrapeCandidate> list =
          await BookMetadataScraper(client: client).search('四叶', limit: 5);

      expect(list, hasLength(1));
      expect(list.first.title, '测试');
      final Map<String, Object?> body =
          (capturedBody as Map).cast<String, Object?>();
      expect(body['keyword'], '四叶');
      expect((body['filter'] as Map)['type'], <int>[1]); // 1 = 书籍
    });

    test('空关键词不发请求', () async {
      bool called = false;
      final MockClient client = MockClient((http.Request req) async {
        called = true;
        return http.Response('{}', 200);
      });
      expect(await BookMetadataScraper(client: client).search('  '), isEmpty);
      expect(called, isFalse);
    });

    test('404 → 空表（搜不到不是异常）；500 → 抛 BookScrapeException', () async {
      final MockClient notFound =
          MockClient((http.Request req) async => http.Response('x', 404));
      expect(await BookMetadataScraper(client: notFound).search('x'), isEmpty);

      final MockClient err =
          MockClient((http.Request req) async => http.Response('x', 500));
      await expectLater(
        BookMetadataScraper(client: err).search('x'),
        throwsA(isA<BookScrapeException>()),
      );
    });
  });

  group('fetchById / parseBookSubjectResponse（id 直连改绑映射）', () {
    test('详情体复用 mapBookSubject：候选字段正确', () {
      const String body = '{"id":9999,"name":"よつばと！","name_cn":"四叶妹妹！",'
          '"images":{"large":"https://img/large.jpg"},'
          '"date":"2003-08-10","summary":"s"}';
      final BookScrapeCandidate? c = parseBookSubjectResponse(body);
      expect(c, isNotNull);
      expect(c!.subjectId, '9999');
      expect(c.title, '四叶妹妹！');
      expect(c.coverUrl, 'https://img/large.jpg');
      expect(c.year, 2003);
    });

    test('无封面 → null；JSON 解码失败 → 抛 BookScrapeException', () {
      expect(parseBookSubjectResponse('{"id":1,"name":"x"}'), isNull);
      expect(
        () => parseBookSubjectResponse('not json'),
        throwsA(isA<BookScrapeException>()),
      );
    });

    test('fetchById：GET /subjects/{id}；404 → null；500 → 抛', () async {
      Uri? uri;
      final MockClient ok = MockClient((http.Request req) async {
        uri = req.url;
        return http.Response.bytes(
          utf8.encode('{"id":7,"name":"n",'
              '"images":{"large":"https://img/l.jpg"}}'),
          200,
        );
      });
      final BookScrapeCandidate? c =
          await BookMetadataScraper(client: ok).fetchById('7');
      expect(uri?.path, '/v0/subjects/7');
      expect(c?.subjectId, '7');

      final MockClient notFound =
          MockClient((http.Request req) async => http.Response('x', 404));
      expect(
          await BookMetadataScraper(client: notFound).fetchById('7'), isNull);

      final MockClient err =
          MockClient((http.Request req) async => http.Response('x', 500));
      await expectLater(
        BookMetadataScraper(client: err).fetchById('7'),
        throwsA(isA<BookScrapeException>()),
      );
    });
  });
}
