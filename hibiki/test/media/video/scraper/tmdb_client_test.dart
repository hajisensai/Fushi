import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart'
    show ScrapeNetworkException;
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/scraper/tmdb_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('parseTmdbMultiResponse 过滤与映射', () {
    test('滤掉 person，映射 tv/movie，别名收 original_*、评分一位小数', () {
      const String body = '''
{"results":[
  {"media_type":"person","id":1,"name":"Someone","profile_path":"/p.jpg"},
  {"media_type":"tv","id":100,"name":"进击的巨人","original_name":"進撃の巨人",
   "poster_path":"/tv.jpg","first_air_date":"2013-04-07","vote_average":8.65},
  {"media_type":"movie","id":200,"title":"你的名字","original_title":"君の名は。",
   "poster_path":"/mv.jpg","release_date":"2016-08-26","vote_average":8.5}
]}''';
      final List<ScrapeCandidate> list = parseTmdbMultiResponse(body);
      expect(list, hasLength(2)); // person 被滤掉

      final ScrapeCandidate tv = list[0];
      expect(tv.source, ScrapeSource.tmdb);
      expect(tv.type, ScrapeEntryType.tv);
      expect(tv.entryId, '100');
      expect(tv.title, '进击的巨人');
      expect(tv.aliases, <String>['進撃の巨人']);
      expect(tv.year, 2013);
      expect(tv.posterUrl, 'https://image.tmdb.org/t/p/original/tv.jpg');
      expect(tv.detailUrl, 'https://www.themoviedb.org/tv/100');
      expect(tv.ratingText, 'TMDB 8.7'); // 8.65(≈8.6500000003) → 一位小数进为 8.7

      final ScrapeCandidate mv = list[1];
      expect(mv.type, ScrapeEntryType.movie);
      expect(mv.title, '你的名字');
      expect(mv.aliases, <String>['君の名は。']);
      expect(mv.year, 2016);
      expect(mv.detailUrl, 'https://www.themoviedb.org/movie/200');
    });

    test('poster_path 空 → 跳过', () {
      const String body = '''
{"results":[
  {"media_type":"tv","id":1,"name":"NoPoster","poster_path":null},
  {"media_type":"movie","id":2,"title":"Empty","poster_path":""}
]}''';
      expect(parseTmdbMultiResponse(body), isEmpty);
    });

    test('vote_average=0 → ratingText 为 null', () {
      const String body = '''
{"results":[{"media_type":"tv","id":3,"name":"Z","poster_path":"/z.jpg",
  "vote_average":0}]}''';
      expect(parseTmdbMultiResponse(body).first.ratingText, isNull);
    });

    test('results 缺失 → 空；非法 JSON → 抛异常', () {
      expect(parseTmdbMultiResponse('{}'), isEmpty);
      expect(
        () => parseTmdbMultiResponse('nope'),
        throwsA(isA<ScrapeNetworkException>()),
      );
    });
  });

  group('TmdbClient.search', () {
    test('URL 含 zh-CN / query / api_key，成功映射', () async {
      Uri? captured;
      final MockClient client = MockClient((http.Request req) async {
        captured = req.url;
        return http.Response.bytes(
          utf8.encode('{"results":[{"media_type":"movie","id":9,'
              '"title":"片","poster_path":"/x.jpg","release_date":"2020-01-01"}]}'),
          200,
        );
      });
      final List<ScrapeCandidate> list =
          await TmdbClient(apiKey: 'KEY123', client: client).search('片');

      expect(list, hasLength(1));
      expect(captured?.queryParameters['language'], 'zh-CN');
      expect(captured?.queryParameters['query'], '片');
      expect(captured?.queryParameters['api_key'], 'KEY123');
    });

    test('401 响应 → 抛 ScrapeNetworkException(statusCode=401)', () async {
      final MockClient client =
          MockClient((http.Request req) async => http.Response('nope', 401));
      await expectLater(
        TmdbClient(apiKey: 'bad', client: client).search('x'),
        throwsA(
          isA<ScrapeNetworkException>().having(
              (ScrapeNetworkException e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });
  });

  // BUG-1310：TMDB 搜索响应本就带 backdrop_path / overview / vote_count，此前整条
  // 丢弃 —— 于是详情页宽幅 hero 没有横图可用（只能拿 2:3 海报硬撑，BUG-1298），
  // 简介和评分人数也永远是空的。TMDB 没有接进本流水线的详情端点，搜索响应就是它
  // 全部资料的唯一来源，在这里不接住就等于永久丢失。
  group('TMDB 富字段映射 — BUG-1310', () {
    test('读 backdrop_path / overview / vote_count', () {
      const String body = '''
{"results":[
  {"media_type":"tv","id":100,"name":"转生王女","original_name":"転生王女",
   "poster_path":"/p.jpg","backdrop_path":"/bd.jpg","overview":"一部关于魔法的故事。",
   "first_air_date":"2023-01-04","vote_average":8.2,"vote_count":1234}
]}''';
      final ScrapeCandidate c = parseTmdbMultiResponse(body).single;

      expect(
        c.backdropUrl,
        'https://image.tmdb.org/t/p/original/bd.jpg',
        reason: '横版背景必须用 original 档：hero 跨整屏，4K 下缩略档就是一片糊',
      );
      expect(c.summary, '一部关于魔法的故事。');
      expect(c.rating, 8.2);
      expect(c.ratingCount, 1234);
    });

    test('缺 backdrop_path / overview 时为 null，但候选仍保留', () {
      // 冷门条目常无背景图 —— 那不该让整个候选作废（海报才是刮削的必需品）。
      const String body = '''
{"results":[
  {"media_type":"movie","id":200,"title":"某片","poster_path":"/p.jpg",
   "release_date":"2020-01-01","vote_average":0}
]}''';
      final ScrapeCandidate c = parseTmdbMultiResponse(body).single;

      expect(c.backdropUrl, isNull);
      expect(c.summary, isNull);
      expect(c.posterUrl, 'https://image.tmdb.org/t/p/original/p.jpg',
          reason: '无背景图不得使候选作废');
      expect(c.rating, isNull, reason: 'vote_average=0 是「没人评过」，不是 0 分');
      expect(c.ratingCount, isNull);
    });
  });
}
