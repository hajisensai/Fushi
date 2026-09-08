import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 从 bookKey 解析出启动 [AudiobookSession] 所需的全部材料（音频文件 / 初值 / persist
/// 回调 / 书元数据），供 reader 页与书架长按入口共用，消除「解析音频文件 + 装 persist」
/// 这套逻辑在两处重复。
///
/// 返回 null = 该书没有可播放的有声书 / 字幕书（无记录或无音频文件），调用方据此提示。
class AudiobookSessionLauncher {
  AudiobookSessionLauncher(this._db);

  final FushiDatabase _db;

  /// 解析一本书的会话启动材料。优先 Audiobook 记录，回退 SrtBook（与 reader
  /// `_resolveAudioSlot` 同序）。
  Future<AudiobookSessionStartRequest?> resolve(String bookKey) async {
    final _SessionSource? source = await _pickSource(bookKey);
    if (source == null) return null;
    final SrtBook? srtBook = source.srtBook;
    if (srtBook != null) {
      return _resolveSrtBook(srtBook, source.audiobook, source.audioFiles);
    }
    return _resolveAudiobook(source.audiobook, source.audioFiles, bookKey);
  }

  /// 该书有声书进度的最后写入时刻（epoch 毫秒；无可播放的有声书 / 从未写过返回 0），
  /// 供 reader 开书时与阅读进度 `updatedAt` 做 LWW 仲裁（BUG-2258）。
  ///
  /// 读的是 [resolve] **会真正启动**的那个来源的键（Audiobook 行 = bookKey，SrtBook 行
  /// = uid）——两行可能并存（v29 回填的配对行 + audioOnly 行），而 SRT 重导入会给 uid 键
  /// 盖新时间戳、会话却加载 bookKey 键的旧位置；取两键较大值会让一个从不被加载的
  /// 时间戳赢下仲裁。选来源与 [resolve] 共用 [_pickSource]，不另抄一份优先序。
  /// 不起 audio_service、不读 cue；文件存在性探测与 reader 的音频槽并行，不挡首屏。
  Future<int> readPositionUpdatedAtMs(String bookKey) async {
    final _SessionSource? source = await _pickSource(bookKey);
    if (source == null) return 0;
    return AudiobookRepository(_db).readPositionUpdatedAtMs(source.positionKey);
  }

  /// 会话来源的唯一裁决点：Audiobook 行（有可播放音频）优先，否则 SrtBook 行（有可
  /// 播放音频），都没有 = 无有声书。[resolve] 与 [readPositionUpdatedAtMs] 共用，保证
  /// 「启动哪个」与「读哪个键的时间戳」永远一致。
  Future<_SessionSource?> _pickSource(String bookKey) async {
    final AudiobookRow? abRow = await _db.getAudiobookByBookKey(bookKey);
    if (abRow != null) {
      final Audiobook audiobook = _audiobookFromRow(abRow);
      final List<File> audioFiles = await _resolveAudioFiles(
        audioPaths: audiobook.audioPaths,
        audioRoot: audiobook.audioRoot,
      );
      if (audioFiles.isNotEmpty) {
        return _SessionSource(
          audiobook: audiobook,
          audioFiles: audioFiles,
          positionKey: bookKey,
        );
      }
    }
    final SrtBookRow? srtRow = await _db.getSrtBookByBookKey(bookKey);
    if (srtRow == null) return null;
    final SrtBook srtBook = _srtBookFromRow(srtRow);
    final List<File> audioFiles = await _resolveAudioFiles(
      audioPaths: srtBook.audioPaths,
      audioRoot: srtBook.audioRoot,
    );
    if (audioFiles.isEmpty) return null;
    return _SessionSource(
      audiobook: Audiobook()
        ..bookKey = srtBook.uid
        ..audioRoot = srtBook.audioRoot
        ..audioPaths = srtBook.audioPaths
        ..alignmentFormat = 'srt'
        ..alignmentPath = srtBook.srtPath,
      audioFiles: audioFiles,
      positionKey: srtBook.uid,
      srtBook: srtBook,
    );
  }

  Future<AudiobookSessionStartRequest?> _resolveAudiobook(
    Audiobook audiobook,
    List<File> audioFiles,
    String bookKey,
  ) async {
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
        // BUG-1018 (A1)：通知/悬浮窗元数据走与书架同一 override 书名通道，
        // 编辑对话框改名后媒体通知同步显示新名；无 override 回退 DB 原名。
        title: ReaderFushiSource.instance.overrideTitleForBookKey(bookKey) ??
            title,
        mediaIdentifier: 'fushi://book/$bookKey',
        isSrtBookSource: false,
        author: author,
        coverPath: coverPath,
      ),
      audioFiles: audioFiles,
      prefs: prefs,
      persist: persist,
      cues: cues,
    );
  }

  Future<AudiobookSessionStartRequest?> _resolveSrtBook(
    SrtBook srtBook,
    Audiobook synthetic,
    List<File> audioFiles,
  ) async {
    final AudiobookRepository repo = AudiobookRepository(_db);
    final String key = srtBook.uid;
    final SessionPrefs prefs = await _readPrefs(repo, key);
    final SessionPersistCallbacks persist = _persistFor(repo, key);
    // SRT 书的 cue 全挂在 SrtParser.defaultChapter 下（扁平），用 SrtBookRepository
    // 按 uid 取（与 reader `_primeAudioCuesForCurrentBook` 的 `_srtBookUid` 分支同源）。
    final SrtBookRepository srtRepo = SrtBookRepository(_db);
    final List<AudioCue> cues = await srtRepo.cuesFor(key);

    // BUG-1018 (A1)：override 书名按身份取——EPUB 配对行挂在 bookKey 身份上，
    // standalone SRT 书挂在 `hoshi://srtbook/<uid>` 身份上（A3）。
    final String? overrideTitle = srtBook.bookKey.isNotEmpty
        ? ReaderFushiSource.instance.overrideTitleForBookKey(srtBook.bookKey)
        : ReaderFushiSource.instance.overrideTitleForSrtUid(srtBook.uid);

    return AudiobookSessionStartRequest(
      info: SessionBookInfo(
        bookKey: key,
        audiobook: synthetic,
        title: overrideTitle ?? srtBook.title,
        mediaIdentifier: 'fushi://book/'
            '${srtBook.bookKey.isNotEmpty ? srtBook.bookKey : key}',
        isSrtBookSource: true,
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
    if (row == null) return ('Fushi', null, null);
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

  /// 播放装载的文件解析在 fushi_audio 的 [resolveAudiobookPlaybackFiles]。
  ///
  /// 注意它**不是**删除判据：`audioPaths` 为空时这里会枚举 `audioRoot` 整个目录，
  /// 多认一个文件顶多多一条轨；删除走 `audiobook_local_files.dart`，只认显式登记
  /// 的路径。
  Future<List<File>> _resolveAudioFiles({
    required List<String>? audioPaths,
    required String? audioRoot,
  }) =>
      resolveAudiobookPlaybackFiles(
        audioPaths: audioPaths,
        audioRoot: audioRoot,
      );

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
/// [AudiobookSessionLauncher._pickSource] 的裁决结果：要播的 [audiobook]（SrtBook 来源
/// 时是 uid 身份的合成对象）、已确认存在的 [audioFiles]、持久化位置/时间戳用的
/// [positionKey]；[srtBook] 非空 = 来源是 SrtBook 行。
class _SessionSource {
  const _SessionSource({
    required this.audiobook,
    required this.audioFiles,
    required this.positionKey,
    this.srtBook,
  });

  final Audiobook audiobook;
  final List<File> audioFiles;
  final String positionKey;
  final SrtBook? srtBook;
}

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

  bool get isSrtBookSource => info.isSrtBookSource;

  /// 全书对齐 cue（扁平，无章节上下文）。供后台听书 [AudiobookSession.start] 在无
  /// reader 时灌进控制器，让 currentCue 在 load 后即可解析（悬浮窗有字）。reader 在场
  /// 时 reader 仍会按章节重新 setChapterCues，覆盖此扁平列表，行为不变。
  final List<AudioCue> cues;
}
