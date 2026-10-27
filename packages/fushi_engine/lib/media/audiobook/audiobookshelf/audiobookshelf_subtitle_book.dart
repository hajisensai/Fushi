/// Audiobookshelf 条目 + 字幕 → 可查词制卡的「远端字幕书」。
///
/// 音频留在服务器上流式播放，本机只落字幕与正文（`SrtBook` 的音频路径保持为空），
/// 另在 `remote_audio_bindings` 里记下它对应服务器上哪个条目 / 单集、各音轨的偏移。
/// 字幕里的时间是**整本书**时间轴，导入时按音轨偏移切成各文件内的本地时间
/// （[splitCuesAcrossTracks]），播放器才能把第二个文件以后的句子对上。
library;

import 'dart:io';

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart'
    show parseCuesForFormat;
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/audiobook/standalone_subtitle_book.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
import 'package:path/path.dart' as p;

/// 把服务器条目里的字幕文件取到本机临时目录，返回本地文件。
///
/// 落盘文件名保留原扩展名（`parseCuesForFormat` 按扩展名分派解析器），并加上条目
/// id 前缀避免两本书里同名的 `subtitle.srt` 互相覆盖。体积有上限（见
/// [AudiobookshelfApi.fetchLibraryTextFile]）。
Future<File> downloadAudiobookshelfSubtitle({
  required AudiobookshelfApi api,
  required String itemId,
  required AudiobookshelfLibraryFile file,
  Directory? tempDir,
}) async {
  final List<int> bytes = await api.fetchLibraryTextFile(itemId, file.ino);
  final Directory dir = tempDir ?? await enginePaths.tempRootDirectory();
  await dir.create(recursive: true);
  final String safeName = safeWindowsFileName(p.basename(file.filename));
  final File out = File(p.join(dir.path, 'abs_${itemId}_$safeName'));
  await out.writeAsBytes(bytes, flush: true);
  return out;
}

/// 音轨表（服务器给的毫秒偏移与时长）→ 绑定里存的音轨。
List<RemoteAudioTrack> remoteTracksOf(List<AudiobookshelfTrack> tracks) =>
    <RemoteAudioTrack>[
      for (final AudiobookshelfTrack t in tracks)
        RemoteAudioTrack(
          ino: t.ino,
          startOffsetMs: t.startOffsetMs,
          durationMs: t.durationMs,
          mimeType: t.mimeType,
          sizeBytes: t.sizeBytes,
          filename: t.filename,
        ),
    ];

/// 导入一本远端字幕书：解析 [subtitlePath]（null = 不挂字幕，纯听书）、按 [tracks] 切时间轴、生成正文、落
/// `SrtBook` 与绑定，返回落库的 [SrtBook]。
///
/// - [subtitleOrigin]：`local`（用户选的本机文件）或
///   `RemoteAudioBinding.subtitleOriginServer(ino)`（取自服务器条目）。
/// - 绑定写失败时回滚刚落的字幕书与正文 EPUB 再抛，不留下「书架有卡却没有音频来源」
///   的半成品（那样的书会被当成普通只有字幕的书，点播放什么也不会发生）。
Future<SrtBook> importAudiobookshelfSubtitleBook({
  required FushiDatabase db,
  required SrtBookRepository repo,
  required RemoteAudioBindingRepository bindings,
  required String serverConfigId,
  required String itemId,
  String? episodeId,
  required List<RemoteAudioTrack> tracks,
  required String title,
  String? author,
  String? subtitlePath,
  String subtitleOrigin = RemoteAudioBinding.subtitleOriginLocal,
  required DuplicatePolicy policy,
  Directory? tempDir,
  Future<String?> Function(Directory persistDir)? persistCover,
  StandaloneSubtitleBookProgress? onProgress,
}) async {
  if (tracks.isEmpty) {
    throw ArgumentError.value(tracks, 'tracks', 'a remote book needs audio');
  }
  final List<AudioTrackSpan> spans = <AudioTrackSpan>[
    for (final RemoteAudioTrack t in tracks) t.span,
  ];
  final SrtBook book = await importStandaloneSubtitleBook(
    db: db,
    repo: repo,
    title: title,
    author: author,
    subtitlePath: subtitlePath,
    policy: policy,
    tempDir: tempDir,
    persistCover: persistCover,
    onProgress: onProgress,
    cueTransform: (List<AudioCue> cues) => splitCuesAcrossTracks(cues, spans),
  );
  final int now = DateTime.now().millisecondsSinceEpoch;
  try {
    await bindings.save(
      RemoteAudioBinding(
        srtBookUid: book.uid,
        provider: RemoteAudioBinding.providerAudiobookshelf,
        serverConfigId: serverConfigId,
        itemId: itemId,
        episodeId: episodeId,
        tracks: tracks,
        subtitleOrigin: subtitleOrigin,
        createdAt: now,
        updatedAt: now,
      ),
    );
  } catch (e, stack) {
    engineLog.log('importAudiobookshelfSubtitleBook.binding', e, stack);
    await repo.delete(book.uid);
    if (book.bookKey.isNotEmpty) await db.deleteEpubBook(book.bookKey);
    rethrow;
  }
  return book;
}

/// 服务器重扫后音轨表变了：按新偏移重切已存的字幕并更新绑定。
///
/// 返回 true = 确实重切了；绑定不存在、音轨表没变、或字幕书 / 字幕文件已不在时返回
/// false（什么都不动）。字幕原文取自本机持久化的那份 `srtPath`，不再请求服务器。
/// 重切整组替换 cue，播放进度键按真实时间位置换编码（`saveCues` 内的既有逻辑）。
Future<bool> resplitAudiobookshelfSubtitleBook({
  required SrtBookRepository repo,
  required RemoteAudioBindingRepository bindings,
  required String srtBookUid,
  required List<RemoteAudioTrack> currentTracks,
}) async {
  final RemoteAudioBinding? binding = await bindings.get(srtBookUid);
  if (binding == null || currentTracks.isEmpty) return false;
  if (binding.sameTracksAs(currentTracks)) return false;
  final SrtBook? book = await repo.findByUid(srtBookUid);
  if (book == null) return false;
  final File subtitle = File(book.srtPath);
  if (!await subtitle.exists()) return false;

  final List<AudioCue> parsed = await parseCuesForFormat(
    subtitle,
    srtBookUid,
    0,
  );
  final List<AudioCue> cues = splitCuesAcrossTracks(parsed, <AudioTrackSpan>[
    for (final RemoteAudioTrack t in currentTracks) t.span,
  ]);
  await repo.saveCues(uid: srtBookUid, cues: cues);
  await bindings.save(
    binding.copyWith(
      tracks: currentTracks,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ),
  );
  return true;
}
