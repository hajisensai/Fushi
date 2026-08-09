import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/media/video/metadata/video_nfo_builder.dart';
import 'package:xml/xml.dart';

void main() {
  VideoMetadataPerson person(
    String name, {
    String? profileUrl,
    String? tmdbId,
  }) =>
      VideoMetadataPerson(
        name: name,
        profileUrl: profileUrl,
        ids: tmdbId == null
            ? const <VideoMetadataId>[]
            : <VideoMetadataId>[
                VideoMetadataId(type: 'tmdb', value: tmdbId),
              ],
      );

  XmlDocument parse(Uint8List bytes) => XmlDocument.parse(utf8.decode(bytes));

  String? firstText(XmlDocument document, String name) {
    final Iterable<XmlElement> elements = document.findAllElements(name);
    return elements.isEmpty ? null : elements.first.innerText.trim();
  }

  test('movie 输出 UTF-8、多 ID、MoviePilot 默认 ID 与完整人物字段', () {
    final VideoMetadataWork work = VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: VideoMetadataMediaKind.movie,
      title: '你 & 我 <电影>',
      originalTitle: 'You & Me',
      year: 2026,
      premiered: '2026-08-08',
      plot: '第一幕 <开始> & 第二幕',
      rating: 8.6,
      ratingVotes: 1234,
      runtimeMinutes: 121,
      contentRating: 'PG-13',
      genres: const <String>['动画', '动画', '奇幻'],
      studios: const <String>['Studio A'],
      countries: const <String>['日本'],
      keywords: const <String>['异世界'],
      ids: const <VideoMetadataId>[
        VideoMetadataId(type: 'TMDB', value: '42', isDefault: true),
        VideoMetadataId(type: 'imdb', value: 'tt0042'),
        VideoMetadataId(type: 'tvdb', value: '420'),
        VideoMetadataId(type: 'tmdb', value: '42'),
      ],
      credits: <VideoMetadataCredit>[
        VideoMetadataCredit(
          kind: VideoMetadataCreditKind.director,
          person: person('导演 A', tmdbId: '10'),
        ),
        VideoMetadataCredit(
          kind: VideoMetadataCreditKind.writer,
          person: person('编剧 B', tmdbId: '11'),
          order: 1,
        ),
        VideoMetadataCredit(
          kind: VideoMetadataCreditKind.voiceActor,
          person: person(
            '声优 C',
            tmdbId: '12',
            profileUrl: 'https://image.example/c.jpg',
          ),
          character: VideoMetadataCharacter(name: '角色 & C'),
          language: 'ja',
          order: 2,
        ),
      ],
    );

    final Uint8List bytes = VideoNfoBuilder.buildMovie(work);
    expect(bytes.take(3), isNot(<int>[0xef, 0xbb, 0xbf]));
    final String xml = utf8.decode(bytes);
    expect(xml, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));

    final XmlDocument document = parse(bytes);
    expect(document.rootElement.name.local, 'movie');
    expect(firstText(document, 'title'), '你 & 我 <电影>');
    expect(firstText(document, 'plot'), '第一幕 <开始> & 第二幕');
    expect(firstText(document, 'outline'), '第一幕 <开始> & 第二幕');
    expect(firstText(document, 'tmdbid'), '42');
    expect(firstText(document, 'imdbid'), 'tt0042');
    expect(firstText(document, 'tvdbid'), '420');

    final List<XmlElement> ids = document.findAllElements('uniqueid').toList();
    expect(ids, hasLength(3));
    expect(
      ids
          .singleWhere((XmlElement id) => id.getAttribute('type') == 'imdb')
          .getAttribute('default'),
      'true',
    );
    expect(
      ids
          .singleWhere((XmlElement id) => id.getAttribute('type') == 'tmdb')
          .getAttribute('default'),
      'false',
    );
    expect(document.findAllElements('genre').map((XmlElement e) => e.innerText),
        <String>['动画', '奇幻']);

    final XmlElement director = document.findAllElements('director').single;
    expect(director.innerText, '导演 A');
    expect(director.getAttribute('tmdbid'), '10');
    expect(document.findAllElements('credits').single.innerText, '编剧 B');
    final XmlElement actor = document.findAllElements('actor').single;
    expect(actor.getElement('name')?.innerText, '声优 C');
    expect(actor.getElement('type')?.innerText, 'VoiceActor');
    expect(actor.getElement('role')?.innerText, '角色 & C');
    expect(actor.getElement('language')?.innerText, 'ja');
    expect(actor.getElement('tmdbid')?.innerText, '12');
    expect(actor.getElement('thumb')?.innerText, 'https://image.example/c.jpg');
    expect(actor.getElement('profile')?.innerText,
        'https://www.themoviedb.org/person/12');
  });

  test('tvshow 使用选定非 TMDB 主源 ID，并写 season/episode=-1', () {
    final VideoMetadataWork work = VideoMetadataWork(
      provider: VideoMetadataProviderKind.bangumi,
      kind: VideoMetadataMediaKind.tv,
      title: '作品',
      ids: const <VideoMetadataId>[
        VideoMetadataId(type: 'tmdb', value: '100', isDefault: true),
        VideoMetadataId(type: 'bangumi', value: '200'),
      ],
    );

    final XmlDocument document = parse(VideoNfoBuilder.buildTvShow(work));
    expect(document.rootElement.name.local, 'tvshow');
    expect(firstText(document, 'season'), '-1');
    expect(firstText(document, 'episode'), '-1');
    final XmlElement defaultId = document
        .findAllElements('uniqueid')
        .singleWhere((XmlElement id) => id.getAttribute('default') == 'true');
    expect(defaultId.getAttribute('type'), 'bangumi');
    expect(defaultId.innerText, '200');
  });

  test('season 输出 season 根、日期、编号和多 ID', () {
    final VideoMetadataSeason season = VideoMetadataSeason(
      seasonNumber: 2,
      title: '第二季',
      plot: '季简介',
      airDate: '2025-04-01',
      ids: const <VideoMetadataId>[
        VideoMetadataId(type: 'tmdb', value: '222'),
      ],
    );

    final XmlDocument document = parse(VideoNfoBuilder.buildSeason(
      season,
      primaryProvider: VideoMetadataProviderKind.tmdb,
    ));
    expect(document.rootElement.name.local, 'season');
    expect(firstText(document, 'title'), '第二季');
    expect(firstText(document, 'premiered'), '2025-04-01');
    expect(firstText(document, 'releasedate'), '2025-04-01');
    expect(firstText(document, 'seasonnumber'), '2');
    expect(firstText(document, 'tmdbid'), '222');
  });

  test('episode 只输出确定字段，使用真实分集 ID 和客串资料', () {
    final VideoMetadataEpisode episode = VideoMetadataEpisode(
      seasonNumber: 1,
      episodeNumber: 7,
      title: '第七集',
      plot: '含非法 CDATA 结束串 ]]> 仍应生成合法 XML',
      airDate: '2026-01-07',
      rating: 7.5,
      ids: const <VideoMetadataId>[
        VideoMetadataId(type: 'tmdb', value: '7007'),
      ],
      credits: <VideoMetadataCredit>[
        VideoMetadataCredit(
          kind: VideoMetadataCreditKind.guest,
          person: person('客串'),
        ),
      ],
    );

    final Uint8List bytes = VideoNfoBuilder.buildEpisode(
      episode,
      primaryProvider: VideoMetadataProviderKind.tmdb,
    );
    final XmlDocument document = parse(bytes);
    expect(document.rootElement.name.local, 'episodedetails');
    expect(firstText(document, 'tmdbid'), '7007');
    expect(firstText(document, 'season'), '1');
    expect(firstText(document, 'episode'), '7');
    expect(firstText(document, 'year'), '2026');
    expect(firstText(document, 'runtime'), isNull);
    expect(firstText(document, 'plot'), contains(']]>'));
    expect(
        document.findAllElements('actor').single.getElement('type')?.innerText,
        'GuestStar');
  });

  test('episode 缺少真实标题时不把文件名或占位名写进 NFO', () {
    final XmlDocument document = parse(VideoNfoBuilder.buildEpisode(
      VideoMetadataEpisode(
        seasonNumber: 2,
        episodeNumber: 3,
        title: '',
      ),
    ));

    expect(firstText(document, 'title'), isNull);
    expect(firstText(document, 'season'), '2');
    expect(firstText(document, 'episode'), '3');
  });

  test('共享 DTO 防止调用方事后修改集合并提供深相等', () {
    final List<String> aliases = <String>['A'];
    final VideoMetadataWork first = VideoMetadataWork(
      provider: VideoMetadataProviderKind.anilist,
      kind: VideoMetadataMediaKind.tv,
      title: '标题',
      aliases: aliases,
      rawPayload: <String, Object?>{
        'nested': <Object?>[1, 'x'],
      },
    );
    aliases.add('B');
    final VideoMetadataWork second = VideoMetadataWork(
      provider: VideoMetadataProviderKind.anilist,
      kind: VideoMetadataMediaKind.tv,
      title: '标题',
      aliases: const <String>['A'],
      rawPayload: <String, Object?>{
        'nested': <Object?>[1, 'x'],
      },
    );

    expect(first.aliases, <String>['A']);
    expect(() => first.aliases.add('C'), throwsUnsupportedError);
    expect(
      () => (first.rawPayload!['nested']! as List<Object?>).add('changed'),
      throwsUnsupportedError,
    );
    expect(first, second);
    expect(first.hashCode, second.hashCode);
  });
}
