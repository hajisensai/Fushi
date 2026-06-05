import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/anilist_client.dart';
import 'package:hibiki/src/media/video/jimaku_client.dart';

void main() {
  group('parseAniListSearchResponse', () {
    test('解析 media 列表', () {
      const String body = '''
{"data":{"Page":{"media":[
  {"id":21,"title":{"romaji":"One Piece","english":"One Piece","native":"ワンピース"}},
  {"id":1,"title":{"romaji":"Cowboy Bebop","english":null,"native":"カウボーイビバップ"}}
]}}}''';
      final List<AniListMedia> media = parseAniListSearchResponse(body);
      expect(media, hasLength(2));
      expect(media[0].id, 21);
      expect(media[0].displayTitle, 'One Piece');
      expect(media[1].displayTitle, 'Cowboy Bebop');
    });

    test('displayTitle 优先级 romaji→english→native→id', () {
      expect(const AniListMedia(id: 5, english: 'E', native: 'N').displayTitle,
          'E');
      expect(const AniListMedia(id: 5, native: 'N').displayTitle, 'N');
      expect(const AniListMedia(id: 5).displayTitle, 'AniList #5');
    });

    test('结构不符 / 非法 JSON → 空', () {
      expect(parseAniListSearchResponse('not json'), isEmpty);
      expect(parseAniListSearchResponse('{"data":null}'), isEmpty);
      expect(parseAniListSearchResponse('{"data":{"Page":{"media":"x"}}}'),
          isEmpty);
    });
  });

  group('parseJimakuEntries', () {
    test('解析条目（name 回退 english_name / #id）', () {
      const String body = '''
[{"id":10,"name":"鬼滅の刃","anilist_id":101922},
 {"id":11,"english_name":"Demon Slayer"},
 {"id":12}]''';
      final List<JimakuEntry> entries = parseJimakuEntries(body);
      expect(entries, hasLength(3));
      expect(entries[0].name, '鬼滅の刃');
      expect(entries[0].anilistId, 101922);
      expect(entries[1].name, 'Demon Slayer');
      expect(entries[2].name, '#12');
    });

    test('非数组 / 非法 → 空', () {
      expect(parseJimakuEntries('{}'), isEmpty);
      expect(parseJimakuEntries('garbage'), isEmpty);
    });
  });

  group('parseJimakuFiles + JimakuFile', () {
    test('解析文件，缺 name/url 的跳过', () {
      const String body = '''
[{"name":"ep01.ja.srt","url":"https://x/ep01.srt","size":1234},
 {"name":"ep02.ass","url":"https://x/ep02.ass"},
 {"url":"https://x/no-name"}]''';
      final List<JimakuFile> files = parseJimakuFiles(body);
      expect(files, hasLength(2));
      expect(files[0].name, 'ep01.ja.srt');
      expect(files[0].size, 1234);
      expect(files[1].url, 'https://x/ep02.ass');
    });

    test('extension / isTextSubtitle', () {
      expect(const JimakuFile(name: 'a.SRT', url: 'u').extension, 'srt');
      expect(const JimakuFile(name: 'a.ass', url: 'u').isTextSubtitle, isTrue);
      expect(const JimakuFile(name: 'a.vtt', url: 'u').isTextSubtitle, isTrue);
      expect(const JimakuFile(name: 'a.zip', url: 'u').isTextSubtitle, isFalse);
      expect(const JimakuFile(name: 'noext', url: 'u').extension, '');
    });
  });
}
