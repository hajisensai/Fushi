import 'dart:convert';
import 'dart:io';

import 'package:hibiki/src/media/audiobook/audiobook_session.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 从 bookKey 解析出启动 [AudiobookSession] 所需的全部材料（音频文件 / 初值 / persist
/// 回调 / 书元数据），供 reader 页与书架长按入口共用，消除「解析音频文件 + 装 persist」
/// 这套逻辑在两处重复。
///
/// 返回 null = 该书没有可播放的有声书 / 字幕书（无记录或无音频文件），调用方据此提示。
class AudiobookSessionLauncher {
  AudiobookSessionLauncher(this._db);

  final HibikiDatabase _db;

  /// 解析一本书的会话启动材料。优先 Audiobook 记录，回退 SrtBook（与 reader
  /// `_resolveAudioSlot` 同序）。
  Future<AudiobookSessionStartRequest?> resolve(String bookKey) async {
    final AudiobookRow? abRow = await _db.getAudiobookByBookKey(bookKey);
    if (abRow != null) {
      final AudiobookSessionStartRequest? req =
          await _resolveAudiobook(abRow, bookKey);
      if (req != null) return req;
    }
    final SrtBookRow? srtRow = await _db.getSrtBookByBookKey(bookKey);
    if (srtRow != null) {
      return _resolveSrtBook(srtRow);
    }
    return null;
  }

  Future<AudiobookSessionStartRequest?> _resolveAudiobook(
    AudiobookRow row,
    String bookKey,
  ) async {
    final Audiobook audiobook = _audiobookFromRow(row);
    final List<File> audioFiles = await _resolveAudioFiles(
      audioPaths: audiobook.audioPaths,
      audioRoot: audiobook.audioRoot,
    );
    if (audioFiles.isEmpty) return null;

    final AudiobookRepository repo = AudiobookRepository(_db);
    final SessionPrefs prefs = await _readPrefs(repo, bookKey);
    final SessionPersistCallbacks persist = _persistFor(repo, bookKey);
    final (String title, String? author, String? coverPath) =
        await _bookMeta(bookKey);
    // 后台听书无 reader 喂 cue（reader 才调 setChapterCues）；这里一次性把全书 cue
    // 取出随 request 返回，让 session.start 直接灌进控制器，否则 _chapterCues 为空、
    // _updateCurrentCue 提前 return、currentCue 恒 null → 悬浮窗推空串（TODO-354
    // 「开着悬浮字幕进书再出来才有字」根因）。后台一本书按扁平 cue 处理（无章节上
    // 下文），与 reader 的 sasayaki/allSrtDefault 分支同序。
    final List<AudioCue> cues = await repo.cuesForBook(bookKey);

    return AudiobookSessionStartRequest(
      info: SessionBookInfo(
        bookKey: bookKey,
        audiobook: audiobook,
        title: title,
        mediaIdentifier: 'hoshi://book/$bookKey',
        author: author,
        coverPath: coverPath,
      ),
      audioFiles: audioFiles,
      prefs: prefs,
      persist: persist,
      cues: cues,
    );
  }

  Future<AudiobookSessionStartRequest?> _resolveSrtBook(SrtBookRow row) async {
    final SrtBook srtBook = _srtBookFromRow(row);
    final List<File> audioFiles = await _resolveAudioFiles(
      audioPaths: srtBook.audioPaths,
      audioRoot: srtBook.audioRoot,
    );
    if (audioFiles.isEmpty) return null;

    final Audiobook synthetic = Audiobook()
      ..bookKey = srtBook.uid
      ..audioRoot = srtBook.audioRoot
      ..audioPaths = srtBook.audioPaths
      ..alignmentFormat = 'srt'
      ..alignmentPath = srtBook.srtPath;

    final AudiobookRepository repo = AudiobookRepository(_db);
    final String key = srtBook.uid;
    final SessionPrefs prefs = await _readPrefs(repo, key);
    final SessionPersistCallbacks persist = _persistFor(repo, key);
    // SRT 书的 cue 全挂在 SrtParser.defaultChapter 下（扁平），用 SrtBookRepository
    // 按 uid 取（与 reader `_primeAudioCuesForCurrentBook` 的 `_srtBookUid` 分支同源）。
    final SrtBookRepository srtRepo = SrtBookRepository(_db);
    final List<AudioCue> cues = await srtRepo.cuesFor(key);

    return AudiobookSessionStartRequest(
      info: SessionBookInfo(
        bookKey: key,
        audiobook: synthetic,
        title: srtBook.title,
        mediaIdentifier: 'hoshi://book/'
            '${srtBook.bookKey.isNotEmpty ? srtBook.bookKey : key}',
        author: srtBook.author,
        coverPath: srtBook.coverPath,
      ),
      audioFiles: audioFiles,
      prefs: prefs,
      persist: persist,
      cues: cues,
    );
  }

  Future<SessionPrefs> _readPrefs(
    AudiobookRepository repo,
    String bookKey,
  ) async {
    final List<Object> prefs = await Future.wait<Object>(<Future<Object>>[
      repo.readFollowAudio(bookKey),
      repo.readDelayMs(bookKey),
      repo.readSpeed(bookKey),
      repo.readPositionMs(bookKey),
      repo.readImagePauseSec(bookKey),
      repo.readVolume(bookKey),
    ]);
    return SessionPrefs(
      followAudio: prefs[0] as bool,
      delayMs: prefs[1] as int,
      speed: prefs[2] as double,
      positionMs: prefs[3] as int,
      imagePauseSec: prefs[4] as int,
      volume: prefs[5] as double,
    );
  }

  SessionPersistCallbacks _persistFor(
    AudiobookRepository repo,
    String bookKey,
  ) {
    return SessionPersistCallbacks(
      onPositionWrite: (String key, int posMs) =>
          repo.updatePositionMs(bookKey: key, positionMs: posMs),
      onDelayPersist: (int ms) => repo.updateDelayMs(bookKey: bookKey, ms: ms),
      onSpeedPersist: (double speed) =>
          repo.updateSpeed(bookKey: bookKey, speed: speed),
      onVolumePersist: (double volume) =>
          repo.updateVolume(bookKey: bookKey, volume: volume),
      onImagePausePersist: (int sec) =>
          repo.updateImagePauseSec(bookKey: bookKey, sec: sec),
      onFollowAudioPersist: (bool value) =>
          repo.updateFollowAudio(bookKey: bookKey, value: value),
    );
  }

  Future<(String, String?, String?)> _bookMeta(String bookKey) async {
    final EpubBookRow? row = await _db.getEpubBook(bookKey);
    if (row == null) return ('Hibiki', null, null);
    String? coverPath;
    if (row.coverPath != null && row.coverPath!.isNotEmpty) {
      String coverRel = row.coverPath!;
      if (coverRel.startsWith('/')) coverRel = coverRel.substring(1);
      final String candidate = '${row.extractDir}/$coverRel';
      if (File(candidate).existsSync()) coverPath = candidate;
    }
    coverPath ??= _firstExistingCover(row.extractDir);
    return (row.title, row.author, coverPath);
  }

  String? _firstExistingCover(String extractDir) {
    for (final String name in const <String>[
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
    ]) {
      final String candidate = '$extractDir/$name';
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  Future<List<File>> _resolveAudioFiles({
    required List<String>? audioPaths,
    required String? audioRoot,
  }) async {
    if (audioPaths != null && audioPaths.isNotEmpty) {
      final List<File> files = <File>[];
      for (final String path in audioPaths) {
        final File f = File(path);
        if (await f.exists()) files.add(f);
      }
      return files;
    }
    if (audioRoot != null) {
      final Directory dir = Directory(audioRoot);
      if (!await dir.exists()) return <File>[];
      final List<FileSystemEntity> entries = await dir.list().toList();
      final List<File> files = entries
          .whereType<File>()
          .where((File f) => AudiobookStorage.isAudioFile(f.path))
          .toList()
        ..sort((File a, File b) => compareAudioFilePath(a.path, b.path));
      return files;
    }
    return <File>[];
  }

  Audiobook _audiobookFromRow(AudiobookRow row) {
    final Audiobook ab = Audiobook()
      ..id = row.id
      ..bookKey = row.bookKey
      ..audioRoot = row.audioRoot
      ..alignmentFormat = row.alignmentFormat
      ..alignmentPath = row.alignmentPath;
    if (row.audioPathsJson != null) {
      ab.audioPaths =
          (jsonDecode(row.audioPathsJson!) as List<dynamic>).cast<String>();
    }
    return ab;
  }

  SrtBook _srtBookFromRow(SrtBookRow row) {
    final SrtBook book = SrtBook()
      ..id = row.id
      ..uid = row.uid
      ..title = row.title
      ..author = row.author
      ..audioRoot = row.audioRoot
      ..srtPath = row.srtPath
      ..coverPath = row.coverPath
      ..bookKey = row.bookKey;
    if (row.audioPathsJson != null) {
      book.audioPaths =
          (jsonDecode(row.audioPathsJson!) as List<dynamic>).cast<String>();
    }
    return book;
  }
}

/// 一本书的会话启动材料聚合。
class AudiobookSessionStartRequest {
  const AudiobookSessionStartRequest({
    required this.info,
    required this.audioFiles,
    required this.prefs,
    required this.persist,
    this.cues = const <AudioCue>[],
  });

  final SessionBookInfo info;
  final List<File> audioFiles;
  final SessionPrefs prefs;
  final SessionPersistCallbacks persist;

  /// 全书对齐 cue（扁平，无章节上下文）。供后台听书 [AudiobookSession.start] 在无
  /// reader 时灌进控制器，让 currentCue 在 load 后即可解析（悬浮窗有字）。reader 在场
  /// 时 reader 仍会按章节重新 setChapterCues，覆盖此扁平列表，行为不变。
  final List<AudioCue> cues;
}
