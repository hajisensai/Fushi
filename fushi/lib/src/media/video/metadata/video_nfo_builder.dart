/// MoviePilot/Kodi 兼容的视频 NFO 生成器。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';

/// 生成 UTF-8（无 BOM）的 movie/tvshow/season/episodedetails NFO。
class VideoNfoBuilder {
  const VideoNfoBuilder._();

  /// 按作品类型生成 `<movie>` 或 `<tvshow>` NFO。
  static Uint8List buildWork(VideoMetadataWork work) => switch (work.kind) {
        VideoMetadataMediaKind.movie => buildMovie(work),
        VideoMetadataMediaKind.tv => buildTvShow(work),
      };

  /// 生成 `<movie>` NFO。
  static Uint8List buildMovie(VideoMetadataWork work) {
    if (work.kind != VideoMetadataMediaKind.movie) {
      throw ArgumentError.value(work.kind, 'work.kind', '必须是 movie');
    }
    return _encode(_buildDocument('movie', (XmlBuilder builder) {
      _writeWorkCommon(builder, work);
      _text(builder, 'title', work.title);
      _text(builder, 'originaltitle', work.originalTitle);
      _text(builder, 'premiered', work.premiered);
      _number(builder, 'year', work.year ?? _yearFromDate(work.premiered));
    }));
  }

  /// 生成 `<tvshow>` NFO。
  static Uint8List buildTvShow(VideoMetadataWork work) {
    if (work.kind != VideoMetadataMediaKind.tv) {
      throw ArgumentError.value(work.kind, 'work.kind', '必须是 tv');
    }
    return _encode(_buildDocument('tvshow', (XmlBuilder builder) {
      _writeWorkCommon(builder, work);
      _text(builder, 'title', work.title);
      _text(builder, 'originaltitle', work.originalTitle);
      _text(builder, 'premiered', work.premiered);
      _number(builder, 'year', work.year ?? _yearFromDate(work.premiered));
      _number(builder, 'season', -1);
      _number(builder, 'episode', -1);
    }));
  }

  /// 生成 `<season>` NFO。
  static Uint8List buildSeason(
    VideoMetadataSeason season, {
    VideoMetadataProviderKind? primaryProvider,
  }) =>
      _encode(_buildDocument('season', (XmlBuilder builder) {
        _writeIds(builder, season.ids, primaryProvider: primaryProvider);
        _plot(builder, season.plot);
        _text(builder, 'title', season.title);
        _text(builder, 'premiered', season.airDate);
        _text(builder, 'releasedate', season.airDate);
        _number(builder, 'year', season.year ?? _yearFromDate(season.airDate));
        _number(builder, 'seasonnumber', season.seasonNumber);
      }));

  /// 生成 `<episodedetails>` NFO。
  static Uint8List buildEpisode(
    VideoMetadataEpisode episode, {
    VideoMetadataProviderKind? primaryProvider,
  }) =>
      _encode(_buildDocument('episodedetails', (XmlBuilder builder) {
        _writeIds(builder, episode.ids, primaryProvider: primaryProvider);
        _text(builder, 'title', episode.title);
        _plot(builder, episode.plot);
        _text(builder, 'aired', episode.airDate);
        _number(
          builder,
          'year',
          episode.year ?? _yearFromDate(episode.airDate),
        );
        _number(builder, 'season', episode.seasonNumber);
        _number(builder, 'episode', episode.episodeNumber);
        _number(builder, 'rating', episode.rating);
        _number(builder, 'runtime', episode.runtimeMinutes);
        _writeCredits(builder, episode.credits);
      }));

  static XmlDocument _buildDocument(
    String rootName,
    void Function(XmlBuilder builder) writeChildren,
  ) {
    final XmlBuilder builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(rootName, nest: () => writeChildren(builder));
    return builder.buildDocument();
  }

  static Uint8List _encode(XmlDocument document) => Uint8List.fromList(
        utf8.encode(
          '${document.toXmlString(pretty: true, indent: '  ', newLine: '\n')}\n',
        ),
      );

  static void _writeWorkCommon(
    XmlBuilder builder,
    VideoMetadataWork work,
  ) {
    _writeIds(builder, work.ids, primaryProvider: work.provider);
    _plot(builder, work.plot);
    _writeCredits(builder, work.credits);
    for (final String genre in _nonEmpty(work.genres)) {
      _text(builder, 'genre', genre);
    }
    _number(builder, 'rating', work.rating);
    _number(builder, 'votes', work.ratingVotes);
    _text(builder, 'mpaa', work.contentRating);
    for (final String studio in _nonEmpty(work.studios)) {
      _text(builder, 'studio', studio);
    }
    for (final String country in _nonEmpty(work.countries)) {
      _text(builder, 'country', country);
    }
    for (final String keyword in _nonEmpty(work.keywords)) {
      _text(builder, 'tag', keyword);
    }
    _number(builder, 'runtime', work.runtimeMinutes);
  }

  static void _writeIds(
    XmlBuilder builder,
    List<VideoMetadataId> rawIds, {
    VideoMetadataProviderKind? primaryProvider,
  }) {
    final List<VideoMetadataId> ids = _deduplicateIds(rawIds);
    if (ids.isEmpty) {
      return;
    }

    final int defaultIndex = _defaultIdIndex(ids, primaryProvider);
    for (int index = 0; index < ids.length; index += 1) {
      final VideoMetadataId id = ids[index];
      final String type = id.type.trim().toLowerCase();
      builder.element(
        'uniqueid',
        attributes: <String, String>{
          'type': type,
          'default': index == defaultIndex ? 'true' : 'false',
        },
        nest: id.value.trim(),
      );
    }

    for (final String type in const <String>['tmdb', 'tvdb', 'imdb']) {
      final VideoMetadataId? id = ids
          .where((VideoMetadataId value) =>
              value.type.trim().toLowerCase() == type)
          .firstOrNull;
      if (id != null) {
        _text(builder, '${type}id', id.value);
      }
    }
  }

  static int _defaultIdIndex(
    List<VideoMetadataId> ids,
    VideoMetadataProviderKind? primaryProvider,
  ) {
    if (primaryProvider == VideoMetadataProviderKind.tmdb) {
      final int imdb = ids.indexWhere(
        (VideoMetadataId id) => id.type.trim().toLowerCase() == 'imdb',
      );
      if (imdb >= 0) {
        return imdb;
      }
    }
    if (primaryProvider != null) {
      final int providerId = ids.indexWhere(
        (VideoMetadataId id) =>
            id.type.trim().toLowerCase() == primaryProvider.name,
      );
      if (providerId >= 0) {
        return providerId;
      }
    }
    final int explicit = ids.indexWhere((VideoMetadataId id) => id.isDefault);
    if (explicit >= 0) {
      return explicit;
    }
    return 0;
  }

  static List<VideoMetadataId> _deduplicateIds(
    List<VideoMetadataId> ids,
  ) {
    final Set<String> seen = <String>{};
    final List<VideoMetadataId> result = <VideoMetadataId>[];
    for (final VideoMetadataId id in ids) {
      final String type = id.type.trim().toLowerCase();
      final String value = id.value.trim();
      if (type.isEmpty || value.isEmpty || !seen.add('$type\u0000$value')) {
        continue;
      }
      result.add(VideoMetadataId(
        type: type,
        value: value,
        isDefault: id.isDefault,
      ));
    }
    return result;
  }

  static void _plot(XmlBuilder builder, String? value) {
    final String? plot = _trimmed(value);
    if (plot == null) {
      return;
    }
    for (final String name in const <String>['plot', 'outline']) {
      builder.element(name, nest: () {
        // XML 不允许 CDATA 内出现 `]]>`；这类罕见文本回落到普通转义文本。
        if (plot.contains(']]>')) {
          builder.text(plot);
        } else {
          builder.cdata(plot);
        }
      });
    }
  }

  static void _writeCredits(
    XmlBuilder builder,
    List<VideoMetadataCredit> rawCredits,
  ) {
    final List<VideoMetadataCredit> credits = rawCredits.toList()
      ..sort((VideoMetadataCredit a, VideoMetadataCredit b) {
        final int byOrder = a.order.compareTo(b.order);
        if (byOrder != 0) {
          return byOrder;
        }
        return a.person.name.compareTo(b.person.name);
      });

    for (final VideoMetadataCredit credit in credits) {
      final String? name = _trimmed(credit.person.name);
      if (name == null) {
        continue;
      }
      switch (credit.kind) {
        case VideoMetadataCreditKind.director:
          builder.element(
            'director',
            attributes: _tmdbAttribute(credit.person),
            nest: name,
          );
        case VideoMetadataCreditKind.writer:
          builder.element(
            'credits',
            attributes: _tmdbAttribute(credit.person),
            nest: name,
          );
        case VideoMetadataCreditKind.actor:
        case VideoMetadataCreditKind.guest:
        case VideoMetadataCreditKind.voiceActor:
          builder.element('actor', nest: () {
            _text(builder, 'name', name);
            _text(
                builder,
                'type',
                switch (credit.kind) {
                  VideoMetadataCreditKind.guest => 'GuestStar',
                  VideoMetadataCreditKind.voiceActor => 'VoiceActor',
                  _ => 'Actor',
                });
            _text(builder, 'role', credit.character?.name);
            _text(builder, 'language', credit.language);
            _number(builder, 'order', credit.order);
            final String? tmdbId = _personId(credit.person, 'tmdb');
            _text(builder, 'tmdbid', tmdbId);
            _text(builder, 'thumb', credit.person.profileUrl);
            if (tmdbId != null) {
              _text(
                builder,
                'profile',
                'https://www.themoviedb.org/person/$tmdbId',
              );
            }
          });
      }
    }
  }

  static Map<String, String> _tmdbAttribute(VideoMetadataPerson person) {
    final String? tmdbId = _personId(person, 'tmdb');
    return tmdbId == null
        ? const <String, String>{}
        : <String, String>{'tmdbid': tmdbId};
  }

  static String? _personId(VideoMetadataPerson person, String type) {
    for (final VideoMetadataId id in person.ids) {
      if (id.type.trim().toLowerCase() == type && id.value.trim().isNotEmpty) {
        return id.value.trim();
      }
    }
    return null;
  }

  static Iterable<String> _nonEmpty(Iterable<String> values) sync* {
    final Set<String> seen = <String>{};
    for (final String value in values) {
      final String? normalized = _trimmed(value);
      if (normalized != null && seen.add(normalized)) {
        yield normalized;
      }
    }
  }

  static void _text(XmlBuilder builder, String name, String? value) {
    final String? text = _trimmed(value);
    if (text != null) {
      builder.element(name, nest: text);
    }
  }

  static void _number(XmlBuilder builder, String name, num? value) {
    if (value != null) {
      builder.element(name, nest: value.toString());
    }
  }

  static String? _trimmed(String? value) {
    final String? trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static int? _yearFromDate(String? value) {
    final String? date = _trimmed(value);
    if (date == null || date.length < 4) {
      return null;
    }
    return int.tryParse(date.substring(0, 4));
  }
}

extension _FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull {
    final Iterator<T> iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
