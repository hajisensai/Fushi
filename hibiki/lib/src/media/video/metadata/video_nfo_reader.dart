library;

import 'dart:io';

import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/media/video/scraper/sidecar_scanner.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// 完整 Kodi/MoviePilot NFO 读取器。只返回文件中确定存在的字段；在线资料可在上层补缺。
class VideoNfoReader {
  const VideoNfoReader({this.generatedArtifactChecker});

  final SidecarGeneratedArtifactChecker? generatedArtifactChecker;

  Future<VideoMetadataWork?> readForPaths({
    required String sourceRoot,
    required String fallbackTitle,
    required List<String> videoPaths,
  }) async {
    if (videoPaths.isEmpty) return null;
    final String root = p.normalize(p.absolute(sourceRoot));
    XmlDocument? workDocument;
    String? workPath;
    for (final String videoPath in videoPaths) {
      final String stemNfo = p.setExtension(videoPath, '.nfo');
      final List<String> candidates = <String>[stemNfo];
      String directory = p.dirname(p.normalize(p.absolute(videoPath)));
      while (_inside(root, directory)) {
        candidates.add(p.join(directory, 'tvshow.nfo'));
        candidates.add(p.join(directory, 'movie.nfo'));
        if (p.equals(directory, root)) break;
        final String parent = p.dirname(directory);
        if (p.equals(parent, directory)) break;
        directory = parent;
      }
      for (final String candidate in candidates) {
        final XmlDocument? document = await _readExternal(candidate);
        if (document == null) continue;
        final String rootName = document.rootElement.name.local.toLowerCase();
        if (rootName == 'movie' || rootName == 'tvshow') {
          workDocument = document;
          workPath = candidate;
          break;
        }
      }
      if (workDocument != null) break;
    }

    final List<_EpisodeNfo> episodeNfos = <_EpisodeNfo>[];
    for (final String videoPath in videoPaths) {
      final XmlDocument? document = await _readExternal(
        p.setExtension(videoPath, '.nfo'),
      );
      if (document?.rootElement.name.local.toLowerCase() != 'episodedetails') {
        continue;
      }
      final VideoNameInfo parsed = parseVideoFilename(p.basename(videoPath));
      final int? season = _int(document!, 'season') ?? parsed.season;
      final int? episode = _int(document, 'episode') ?? parsed.episode;
      if (season == null || episode == null) continue;
      episodeNfos.add(_EpisodeNfo(
        seasonNumber: season,
        metadata: VideoMetadataEpisode(
          seasonNumber: season,
          episodeNumber: episode,
          title: _text(document, 'title') ?? '',
          plot: _text(document, 'plot') ?? _text(document, 'outline'),
          airDate: _text(document, 'aired'),
          year: _int(document, 'year'),
          rating: _double(document, 'rating'),
          runtimeMinutes: _int(document, 'runtime'),
          ids: _ids(document),
          credits: _credits(document),
        ),
      ));
    }
    if (workDocument == null && episodeNfos.isEmpty) return null;

    final XmlDocument? doc = workDocument;
    final String rootName = doc?.rootElement.name.local.toLowerCase() ?? '';
    final VideoMetadataMediaKind kind = rootName == 'movie'
        ? VideoMetadataMediaKind.movie
        : VideoMetadataMediaKind.tv;
    final List<VideoMetadataId> ids =
        doc == null ? const <VideoMetadataId>[] : _ids(doc);
    final VideoMetadataProviderKind provider = _provider(ids);
    final Map<int, List<VideoMetadataEpisode>> bySeason =
        <int, List<VideoMetadataEpisode>>{};
    for (final _EpisodeNfo value in episodeNfos) {
      bySeason
          .putIfAbsent(value.seasonNumber, () => <VideoMetadataEpisode>[])
          .add(value.metadata);
    }
    return VideoMetadataWork(
      provider: provider,
      kind: kind,
      title:
          doc == null ? fallbackTitle : (_text(doc, 'title') ?? fallbackTitle),
      originalTitle: doc == null ? null : _text(doc, 'originaltitle'),
      tagline: doc == null ? null : _text(doc, 'tagline'),
      year: doc == null ? null : _int(doc, 'year'),
      premiered:
          doc == null ? null : (_text(doc, 'premiered') ?? _text(doc, 'aired')),
      plot: doc == null ? null : (_text(doc, 'plot') ?? _text(doc, 'outline')),
      rating: doc == null ? null : _double(doc, 'rating'),
      ratingVotes: doc == null ? null : _int(doc, 'votes'),
      runtimeMinutes: doc == null ? null : _int(doc, 'runtime'),
      contentRating: doc == null ? null : _text(doc, 'mpaa'),
      status: doc == null ? null : _text(doc, 'status'),
      genres: doc == null ? const <String>[] : _texts(doc, 'genre'),
      studios: doc == null ? const <String>[] : _texts(doc, 'studio'),
      countries: doc == null ? const <String>[] : _texts(doc, 'country'),
      keywords: doc == null ? const <String>[] : _texts(doc, 'tag'),
      ids: ids,
      credits: doc == null ? const <VideoMetadataCredit>[] : _credits(doc),
      seasons: <VideoMetadataSeason>[
        for (final MapEntry<int, List<VideoMetadataEpisode>> entry
            in bySeason.entries)
          VideoMetadataSeason(
            seasonNumber: entry.key,
            title: 'Season ${entry.key}',
            episodeCount: entry.value.length,
            episodes: entry.value
              ..sort((VideoMetadataEpisode a, VideoMetadataEpisode b) =>
                  a.episodeNumber.compareTo(b.episodeNumber)),
          ),
      ]..sort((VideoMetadataSeason a, VideoMetadataSeason b) =>
          a.seasonNumber.compareTo(b.seasonNumber)),
      rawPayload: <String, Object?>{
        'source': 'nfo',
        if (workPath != null) 'path': workPath,
      },
    );
  }

  Future<XmlDocument?> _readExternal(String path) async {
    final File file = File(path);
    if (!await file.exists()) return null;
    if (generatedArtifactChecker != null &&
        await generatedArtifactChecker!.isUnmodifiedGeneratedArtifact(
          p.normalize(p.absolute(path)),
        )) {
      return null;
    }
    try {
      return XmlDocument.parse(await file.readAsString());
    } on Object {
      return null;
    }
  }

  static bool _inside(String root, String candidate) =>
      p.equals(root, candidate) || p.isWithin(root, candidate);

  static String? _text(XmlDocument doc, String name) {
    for (final XmlElement element in doc.findAllElements(name)) {
      final String value = element.innerText.trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  static List<String> _texts(XmlDocument doc, String name) => <String>{
        for (final XmlElement element in doc.findAllElements(name))
          if (element.innerText.trim().isNotEmpty) element.innerText.trim(),
      }.toList(growable: false);

  static int? _int(XmlDocument doc, String name) =>
      int.tryParse(_text(doc, name) ?? '');

  static double? _double(XmlDocument doc, String name) =>
      double.tryParse(_text(doc, name) ?? '');

  static List<VideoMetadataId> _ids(XmlDocument doc) {
    final Map<String, VideoMetadataId> values = <String, VideoMetadataId>{};
    for (final XmlElement element in doc.findAllElements('uniqueid')) {
      final String? type = element.getAttribute('type')?.trim().toLowerCase();
      final String value = element.innerText.trim();
      if (type == null || type.isEmpty || value.isEmpty) continue;
      values[type] = VideoMetadataId(
        type: type,
        value: value,
        isDefault: element.getAttribute('default')?.toLowerCase() == 'true',
      );
    }
    for (final String type in const <String>[
      'tmdb',
      'tvdb',
      'imdb',
      'bangumi',
      'anilist',
      'douban'
    ]) {
      final String? value = _text(doc, '${type}id');
      if (value != null) {
        values.putIfAbsent(
            type, () => VideoMetadataId(type: type, value: value));
      }
    }
    return values.values.toList(growable: false);
  }

  static VideoMetadataProviderKind _provider(List<VideoMetadataId> ids) {
    for (final VideoMetadataId id
        in ids.where((VideoMetadataId value) => value.isDefault)) {
      final VideoMetadataProviderKind? provider =
          VideoMetadataProviderKind.values.asNameMap()[id.type];
      if (provider != null && provider != VideoMetadataProviderKind.fanart) {
        return provider;
      }
    }
    for (final VideoMetadataProviderKind provider
        in const <VideoMetadataProviderKind>[
      VideoMetadataProviderKind.tmdb,
      VideoMetadataProviderKind.bangumi,
      VideoMetadataProviderKind.anilist,
      VideoMetadataProviderKind.douban,
    ]) {
      if (ids.any((VideoMetadataId id) => id.type == provider.name)) {
        return provider;
      }
    }
    return VideoMetadataProviderKind.tmdb;
  }

  static List<VideoMetadataCredit> _credits(XmlDocument doc) {
    final List<VideoMetadataCredit> result = <VideoMetadataCredit>[];
    for (final XmlElement element in doc.findAllElements('director')) {
      final String name = element.innerText.trim();
      if (name.isEmpty) continue;
      result.add(VideoMetadataCredit(
        kind: VideoMetadataCreditKind.director,
        person: VideoMetadataPerson(name: name),
        order: result.length,
      ));
    }
    for (final XmlElement element in doc.findAllElements('credits')) {
      final String name = element.innerText.trim();
      if (name.isEmpty) continue;
      result.add(VideoMetadataCredit(
        kind: VideoMetadataCreditKind.writer,
        person: VideoMetadataPerson(name: name),
        order: result.length,
      ));
    }
    for (final XmlElement actor in doc.findAllElements('actor')) {
      String? child(String name) {
        final Iterable<XmlElement> nodes = actor.findElements(name);
        return nodes.isEmpty ? null : nodes.first.innerText.trim();
      }

      final String? name = child('name');
      if (name == null || name.isEmpty) continue;
      final String type = child('type')?.toLowerCase() ?? '';
      final String? role = child('role');
      result.add(VideoMetadataCredit(
        kind: type.contains('voice')
            ? VideoMetadataCreditKind.voiceActor
            : type.contains('guest')
                ? VideoMetadataCreditKind.guest
                : VideoMetadataCreditKind.actor,
        person: VideoMetadataPerson(
          name: name,
          profileUrl: child('thumb'),
          ids: <VideoMetadataId>[
            if (child('tmdbid') case final String id when id.isNotEmpty)
              VideoMetadataId(type: 'tmdb', value: id),
          ],
        ),
        character: role == null || role.isEmpty
            ? null
            : VideoMetadataCharacter(name: role),
        language: child('language'),
        order: int.tryParse(child('order') ?? '') ?? result.length,
      ));
    }
    return result;
  }
}

VideoMetadataWork mergeNfoAuthority(
  VideoMetadataWork nfo,
  VideoMetadataWork online,
) =>
    online.copyWith(
      title: nfo.title,
      originalTitle: nfo.originalTitle ?? online.originalTitle,
      tagline: nfo.tagline ?? online.tagline,
      year: nfo.year ?? online.year,
      premiered: nfo.premiered ?? online.premiered,
      plot: nfo.plot ?? online.plot,
      rating: nfo.rating ?? online.rating,
      ratingVotes: nfo.ratingVotes ?? online.ratingVotes,
      runtimeMinutes: nfo.runtimeMinutes ?? online.runtimeMinutes,
      contentRating: nfo.contentRating ?? online.contentRating,
      status: nfo.status ?? online.status,
      genres: nfo.genres.isEmpty ? online.genres : nfo.genres,
      studios: nfo.studios.isEmpty ? online.studios : nfo.studios,
      countries: nfo.countries.isEmpty ? online.countries : nfo.countries,
      keywords: nfo.keywords.isEmpty ? online.keywords : nfo.keywords,
      ids: <VideoMetadataId>{...nfo.ids, ...online.ids}.toList(),
      credits: nfo.credits.isEmpty ? online.credits : nfo.credits,
      seasons: nfo.seasons.isEmpty ? online.seasons : nfo.seasons,
    );

class _EpisodeNfo {
  const _EpisodeNfo({required this.seasonNumber, required this.metadata});

  final int seasonNumber;
  final VideoMetadataEpisode metadata;
}
