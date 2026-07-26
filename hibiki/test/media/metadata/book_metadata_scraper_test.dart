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

    test('缺 large 用 common；无任何封面 → 跳过该条', () {
      const String body = '''
{"data":[
  {"id":2,"name":"A","images":{"common":"https://img/c.jpg"}},
  {"id":3,"name":"B","images":{}},
  {"id":4,"name":"C"}
]}''';
      final List<BookScrapeCandidate> list = parseBookSearchResponse(body);
      expect(list, hasLength(1)); // 只有 id=2 有封面
      expect(list.first.coverUrl, 'https://img/c.jpg');
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
}
