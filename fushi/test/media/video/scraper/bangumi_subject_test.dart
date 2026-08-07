/// Bangumi 条目详情解析（「抄 Bangumi」的资料层）单测。
///
/// 覆盖 [parseBangumiSubjectResponse] 纯函数与 [BangumiClient.fetchSubject] 的
/// 端点/异常契约，全部走 MockClient，无真实网络。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/scraper/bangumi_client.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 一个结构完整的 Bangumi `/v0/subjects/{id}` 响应体。
String _subjectBody({
  Object? rating = const <String, Object?>{'score': 8.4, 'total': 1234},
  Object? infobox,
  int eps = 12,
  int totalEpisodes = 13,
}) =>
    jsonEncode(<String, Object?>{
      'id': 253,
      'type': 2,
      'name': 'カウボーイビバップ',
      'name_cn': '星际牛仔',
      'summary': '2071 年，人类离开了荒废的地球。',
      'date': '1998-04-03',
      'platform': 'TV',
      'eps': eps,
      'total_episodes': totalEpisodes,
      'rating': rating,
      'tags': <Object?>[
        <String, Object?>{'name': '科幻', 'count': 900},
        <String, Object?>{'name': '太空', 'count': 700},
        <String, Object?>{'name': 42}, // 非法：应被跳过
      ],
      'infobox': infobox ??
          <Object?>[
            <String, Object?>{'key': '导演', 'value': '渡辺信一郎'},
            <String, Object?>{
              'key': '别名',
              'value': <Object?>[
                <String, Object?>{'v': 'Cowboy Bebop'},
                <String, Object?>{'k': '简体', 'v': '星际牛仔'},
              ],
            },
            <String, Object?>{'key': '空值', 'value': '   '}, // 应被跳过
          ],
    });

MockClient _client(String body, {int status = 200}) =>
    MockClient((http.Request req) async {
      return http.Response.bytes(
        utf8.encode(body),
        status,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    });

void main() {
  group('parseBangumiSubjectResponse 字段映射', () {
    test('标题优先 name_cn，原名收 name；简介/放送/详情页照抄', () {
      final ScrapeMetadata meta = parseBangumiSubjectResponse(_subjectBody());
      expect(meta.source, ScrapeSource.bangumi);
      expect(meta.subjectId, '253');
      expect(meta.title, '星际牛仔');
      expect(meta.originalTitle, 'カウボーイビバップ');
      expect(meta.summary, contains('2071'));
      expect(meta.airDate, '1998-04-03');
      expect(meta.detailUrl, 'https://bgm.tv/subject/253');
    });

    test('主标题用了 name（无 name_cn）时原名不自我重复', () {
      final Map<String, Object?> raw =
          jsonDecode(_subjectBody()) as Map<String, Object?>;
      raw.remove('name_cn');
      final ScrapeMetadata meta = parseBangumiSubjectResponse(jsonEncode(raw));
      expect(meta.title, 'カウボーイビバップ');
      expect(meta.originalTitle, isNull);
    });

    test('评分取 rating.score / rating.total', () {
      final ScrapeMetadata meta = parseBangumiSubjectResponse(_subjectBody());
      expect(meta.rating, 8.4);
      expect(meta.ratingCount, 1234);
    });

    test('score=0 是「暂无评分」而非 0 分 → 按缺失处理', () {
      final ScrapeMetadata meta = parseBangumiSubjectResponse(_subjectBody(
        rating: const <String, Object?>{'score': 0, 'total': 0},
      ));
      expect(meta.rating, isNull);
      expect(meta.ratingCount, isNull);
    });

    test('话数优先 total_episodes，缺失回退 eps', () {
      expect(
        parseBangumiSubjectResponse(_subjectBody()).episodeCount,
        13,
      );
      expect(
        parseBangumiSubjectResponse(
          _subjectBody(totalEpisodes: 0),
        ).episodeCount,
        12,
      );
      expect(
        parseBangumiSubjectResponse(
          _subjectBody(eps: 0, totalEpisodes: 0),
        ).episodeCount,
        isNull,
      );
    });

    test('标签按源顺序保留，非法条目跳过', () {
      final ScrapeMetadata meta = parseBangumiSubjectResponse(_subjectBody());
      expect(meta.tags.map((ScrapeTag t) => t.name), <String>['科幻', '太空']);
      expect(meta.tags.first.count, 900);
    });

    test('infobox：字符串直取，[{k,v}] 数组摊平成 " / " 串，空值行丢弃', () {
      final ScrapeMetadata meta = parseBangumiSubjectResponse(_subjectBody());
      expect(meta.infobox.length, 2);
      expect(meta.infobox.first.key, '导演');
      expect(meta.infobox.first.value, '渡辺信一郎');
      expect(meta.infobox[1].key, '别名');
      expect(meta.infobox[1].value, 'Cowboy Bebop / 简体: 星际牛仔');
    });

    test('缺 tags / infobox 字段 → 空列表而非抛异常', () {
      final ScrapeMetadata meta = parseBangumiSubjectResponse(jsonEncode(
        <String, Object?>{'id': 1, 'name': 'x'},
      ));
      expect(meta.tags, isEmpty);
      expect(meta.infobox, isEmpty);
      expect(meta.title, 'x');
    });

    test('非法 JSON / 非对象 / 无标题 → ScrapeNetworkException', () {
      expect(
        () => parseBangumiSubjectResponse('not json'),
        throwsA(isA<ScrapeNetworkException>()),
      );
      expect(
        () => parseBangumiSubjectResponse('[]'),
        throwsA(isA<ScrapeNetworkException>()),
      );
      expect(
        () => parseBangumiSubjectResponse('{"id":1}'),
        throwsA(isA<ScrapeNetworkException>()),
      );
    });
  });

  group('BangumiClient.fetchSubject', () {
    test('打 /v0/subjects/{id}，utf8 解码中日文不乱码', () async {
      late Uri seen;
      final BangumiClient client = BangumiClient(
        client: MockClient((http.Request req) async {
          seen = req.url;
          return http.Response.bytes(
            utf8.encode(_subjectBody()),
            200,
            headers: const <String, String>{
              // 刻意不带 charset：走 bodyBytes+utf8 才不会被 latin1 毁掉。
              'content-type': 'application/json',
            },
          );
        }),
      );
      final ScrapeMetadata meta = await client.fetchSubject('253');
      expect(seen.toString(), 'https://api.bgm.tv/v0/subjects/253');
      expect(meta.title, '星际牛仔');
      expect(meta.originalTitle, 'カウボーイビバップ');
    });

    test('404（条目不存在/已删）→ ScrapeNetworkException 带状态码', () async {
      final BangumiClient client =
          BangumiClient(client: _client('{}', status: 404));
      await expectLater(
        client.fetchSubject('999999'),
        throwsA(
          isA<ScrapeNetworkException>().having(
              (ScrapeNetworkException e) => e.statusCode, 'status', 404),
        ),
      );
    });
  });

  group('parseBangumiSubjectDetailAsCandidate（id 直连改绑映射）', () {
    test('详情体映射为候选：评分取 rating.score、话数回退 total_episodes', () {
      const String body = '{"id":253,"name":"カウボーイビバップ",'
          '"name_cn":"星际牛仔","date":"1998-04-03","platform":"TV",'
          '"eps":0,"total_episodes":26,'
          '"rating":{"score":8.4,"total":1234},'
          '"images":{"large":"https://img/l.jpg"}}';
      final ScrapeCandidate? c = parseBangumiSubjectDetailAsCandidate(body);
      expect(c, isNotNull);
      expect(c!.entryId, '253');
      expect(c.title, '星际牛仔');
      expect(c.posterUrl, 'https://img/l.jpg');
      expect(c.year, 1998);
      expect(c.type, ScrapeEntryType.tv);
      expect(c.episodeCount, 26);
      expect(c.ratingText, 'Bangumi 8.4');
    });

    test('无海报 → null（对封面刮削无用）；结构异常 → 抛异常', () {
      expect(
        parseBangumiSubjectDetailAsCandidate('{"id":1,"name":"x"}'),
        isNull,
      );
      expect(
        () => parseBangumiSubjectDetailAsCandidate('not json'),
        throwsA(isA<ScrapeNetworkException>()),
      );
    });
  });

  group('BangumiClient.fetchSubjectCandidate', () {
    test('200 → 候选；404 → null（条目不存在按空处理，不抛）', () async {
      const String body = '{"id":9,"name":"n","name_cn":"中文名",'
          '"images":{"large":"https://img/l.jpg"}}';
      final BangumiClient ok = BangumiClient(client: _client(body));
      final ScrapeCandidate? c = await ok.fetchSubjectCandidate('9');
      expect(c?.entryId, '9');
      expect(c?.title, '中文名');

      final BangumiClient missing =
          BangumiClient(client: _client('{}', status: 404));
      expect(await missing.fetchSubjectCandidate('999999'), isNull);
    });

    test('非 2xx（非 404）→ 抛 ScrapeNetworkException', () async {
      final BangumiClient bad =
          BangumiClient(client: _client('{}', status: 500));
      await expectLater(
        bad.fetchSubjectCandidate('9'),
        throwsA(isA<ScrapeNetworkException>()),
      );
    });
  });
}
