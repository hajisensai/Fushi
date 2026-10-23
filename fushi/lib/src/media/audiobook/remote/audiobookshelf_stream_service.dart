/// 「流式播放这一本 / 这一集」的编排：书库标签页只调这里，不碰导入细节。
///
/// 流程：同一条目（播客再加单集）已经建过书就直接复用，不重复导入；否则取字幕（本机
/// 文件，或服务器条目里的文件）、取封面、按服务器音轨偏移切好时间轴、生成正文并落库。
/// 复用时顺手比对服务器现在的音轨表——服务器重扫过就按新偏移重切字幕。
library;

import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_subtitle_book.dart';
import 'package:fushi_engine/media/audiobook/standalone_subtitle_book.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// 字幕从哪来。
sealed class AudiobookshelfSubtitleChoice {
  const AudiobookshelfSubtitleChoice();
}

/// 用户选的本机文件。
class LocalSubtitleChoice extends AudiobookshelfSubtitleChoice {
  const LocalSubtitleChoice(this.path);
  final String path;
}

/// 服务器条目文件夹里的字幕文件。
class ServerSubtitleChoice extends AudiobookshelfSubtitleChoice {
  const ServerSubtitleChoice(this.file);
  final AudiobookshelfLibraryFile file;
}

/// 为一本书在服务器字幕文件里挑最像的那个：文件名主干与音频文件名主干相同的优先，
/// 其次与条目标题相同的，再其次只有一个字幕文件就是它。挑不出返回 null（让用户选）。
AudiobookshelfLibraryFile? suggestServerSubtitle(
  AudiobookshelfItemDetail detail, {
  AudiobookshelfEpisode? episode,
}) {
  final List<AudiobookshelfLibraryFile> candidates = detail.subtitleFiles;
  if (candidates.isEmpty) return null;
  String stem(String name) {
    final String base = p.basenameWithoutExtension(name).toLowerCase().trim();
    // `book.ja` / `book.en` 这类语言后缀去掉再比。
    return base.replaceFirst(RegExp(r'\.[a-z]{2,3}(-[a-z0-9]{2,4})?$'), '');
  }

  final Set<String> audioStems = <String>{
    for (final AudiobookshelfTrack t in detail.tracks)
      if (t.filename != null) stem(t.filename!),
    if (episode?.track.filename case final String name) stem(name),
  };
  for (final AudiobookshelfLibraryFile file in candidates) {
    if (audioStems.contains(stem(file.filename))) return file;
  }
  final String title = (episode?.title ?? detail.item.title)
      .toLowerCase()
      .trim();
  for (final AudiobookshelfLibraryFile file in candidates) {
    if (stem(file.filename) == title) return file;
  }
  return candidates.length == 1 ? candidates.single : null;
}

class AudiobookshelfStreamService {
  AudiobookshelfStreamService({
    required this.db,
    required this.api,
    required this.serverConfigId,
    http.Client Function()? httpClient,
    Directory? tempDir,
  }) : _httpClient = httpClient ?? createAppHttpIoClient,
       _tempDir = tempDir;

  final FushiDatabase db;
  final AudiobookshelfApi api;
  final String serverConfigId;
  final http.Client Function() _httpClient;
  final Directory? _tempDir;

  SrtBookRepository get _books => SrtBookRepository(db);
  RemoteAudioBindingRepository get _bindings =>
      RemoteAudioBindingRepository(db);

  /// 这个条目（单集）已经建好的书；没有为 null。
  Future<SrtBook?> findExisting({
    required String itemId,
    String? episodeId,
  }) async {
    final RemoteAudioBinding? binding = await _bindings.findForItem(
      serverConfigId: serverConfigId,
      itemId: itemId,
      episodeId: episodeId,
    );
    return binding == null ? null : _books.findByUid(binding.srtBookUid);
  }

  /// 音轨表：播客取这一集的唯一音频，书取全部音轨。
  static List<RemoteAudioTrack> tracksFor(
    AudiobookshelfItemDetail detail,
    AudiobookshelfEpisode? episode,
  ) => episode != null
      ? remoteTracksOf(<AudiobookshelfTrack>[episode.track])
      : remoteTracksOf(detail.tracks);

  /// 已建好的书：服务器重扫后音轨表变了就按新偏移重切字幕。返回是否重切过。
  Future<bool> refreshExisting({
    required SrtBook book,
    required AudiobookshelfItemDetail detail,
    AudiobookshelfEpisode? episode,
  }) => resplitAudiobookshelfSubtitleBook(
    repo: _books,
    bindings: _bindings,
    srtBookUid: book.uid,
    currentTracks: tracksFor(detail, episode),
  );

  /// 新建一本流式字幕书。书名：书取条目标题；播客单集取「节目 – 单集」，既好认也不
  /// 会和同节目别的单集撞名（正文 EPUB 按书名去重）。
  Future<SrtBook> create({
    required AudiobookshelfItem item,
    required AudiobookshelfItemDetail detail,
    AudiobookshelfEpisode? episode,
    required AudiobookshelfSubtitleChoice subtitle,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    StandaloneSubtitleBookProgress? onProgress,
  }) async {
    final List<RemoteAudioTrack> tracks = tracksFor(detail, episode);
    if (tracks.isEmpty) {
      throw StateError('Audiobookshelf item ${item.id} has no audio tracks');
    }

    final String subtitlePath;
    final String origin;
    switch (subtitle) {
      case LocalSubtitleChoice(:final String path):
        subtitlePath = path;
        origin = RemoteAudioBinding.subtitleOriginLocal;
      case ServerSubtitleChoice(:final AudiobookshelfLibraryFile file):
        final File downloaded = await downloadAudiobookshelfSubtitle(
          api: api,
          itemId: item.id,
          file: file,
          tempDir: _tempDir,
        );
        subtitlePath = downloaded.path;
        origin = RemoteAudioBinding.subtitleOriginServer(file.ino);
    }

    final String title = episode == null
        ? item.title
        : '${item.title} – ${episode.title}';
    return importAudiobookshelfSubtitleBook(
      db: db,
      repo: _books,
      bindings: _bindings,
      serverConfigId: serverConfigId,
      itemId: item.id,
      episodeId: episode?.id,
      tracks: tracks,
      title: title,
      author: item.authorName,
      subtitlePath: subtitlePath,
      subtitleOrigin: origin,
      policy: policy,
      tempDir: _tempDir,
      persistCover: (Directory persistDir) =>
          _persistCover(persistDir, item.id),
      onProgress: onProgress,
    );
  }

  /// 封面是免鉴权路由（`/api/items/:id/cover`）。取不到不算失败——书没封面照样能用。
  Future<String?> _persistCover(Directory persistDir, String itemId) async {
    final http.Client client = _httpClient();
    try {
      final http.Response response = await client
          .get(api.coverUri(itemId, width: 600))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
      final String type = response.headers['content-type'] ?? '';
      final String ext = type.contains('png')
          ? '.png'
          : type.contains('webp')
          ? '.webp'
          : '.jpg';
      final File file = File(p.join(persistDir.path, 'cover$ext'));
      await file.writeAsBytes(response.bodyBytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }
}
