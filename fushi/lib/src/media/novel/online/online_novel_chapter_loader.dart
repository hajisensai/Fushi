import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// 一章的占位页刚换成正文（[OnlineNovelChapterLoader.ensureLoaded] 的结果）。
@immutable
class OnlineNovelChapterLoaded {
  const OnlineNovelChapterLoaded({
    required this.index,
    required this.characters,
    this.grownSpineCharacters,
  });

  /// 章号（0 基）。
  final int index;

  /// 正文的字数，口径与书行 `chaptersJson` 的 `characters` 相同
  /// （`EpubBook.chapterCharacterCount`）。算不出来（书行已不在）或已不可信
  /// （预取之后解压树被就地重建过）时为 null：调用方照样丢缓存，但不换字数。
  ///
  /// 阅读器开书时只读一次书行里的每章字数，取章之后必须靠它把内存里那一章的
  /// 字数从「占位文案长度」换成正文的，否则进度与统计都按占位页算（BUG-4809）。
  final int? characters;

  /// 取这一章让解压树的 spine 末尾长出了新章（网页小说书取回末尾「下一章」
  /// 占位后，在它后面再挂一个新的占位，novel-d6）时，书行重解析后的**全书**每章
  /// 字数（长度 = 新的 spine 章数，口径同 [characters]）；spine 没变为 null。
  ///
  /// 阅读器据此在会话内把多出来的尾部章节并进已打开的书（重解析解压树拿章节与
  /// 目录，字数取这里的），读完这一章就能接着翻到下一章，不必重开书。
  final List<int>? grownSpineCharacters;
}

/// 阅读器侧「按需取章」的统一接口：WebView 请求到一章正文文件、而它还是占位页
/// （带 `kLnReaderPendingChapterAttribute`）时，先把正文取回写进解压树。
///
/// 两个实现：LNReader 在线书（`LnReaderOnlineChapterLoader`，插件取章）与网页
/// 小说书（`WebNovelChapterLoader`，无界面 WebView 取页 + Rust 提取）。阅读器只认
/// 这个接口，不分来源。
abstract interface class OnlineNovelChapterLoader {
  /// [filePath] 对应的章（0 基）；不是本书的正文文件返回 null。
  int? chapterIndexForFile(String filePath);

  /// 确保 [filePath] 这一章已有正文。返回非 null = 占位页刚换成正文、调用方还没
  /// 确认过（调用方据此丢掉这一章的缓存、换上新字数）；不是本书正文 / 早已确认过
  /// 返回 null。取不到抛出（调用方照常下发占位页并提示原因）。
  Future<OnlineNovelChapterLoaded?> ensureLoaded(String filePath);

  /// 关书：还没开始的取章（含排队的后台预取）不再发起，等它的调用方拿到 null。
  /// 已经在取的那一章照常取完写盘（下次开书直接可读）。之后的请求一律 null。
  void dispose();
}

class _ChapterJob {
  _ChapterJob(this.index, {required this.background});

  final int index;

  /// 后台预取：只要还没开始，就排在所有前台请求后面。前台请求到同一章时改回
  /// false（有人在等它了）。
  bool background;

  final Completer<OnlineNovelChapterLoaded?> completer =
      Completer<OnlineNovelChapterLoaded?>();
}

/// 两个按需取章加载器共用的骨架：章节文件 ↔ 章号、同一章单飞、不同章串行、
/// 原子写。怎么取一章（[loadChapter]）留给各自实现。
///
/// 串行是刻意的：网文站普遍限流，并发只换来 429。所以「前台优先」做成排队顺序
/// ——还没开始的后台预取给前台请求让位，已经开始的照常取完（它的结果多半下一步
/// 就要用），不并发、不中途丢弃。
abstract class SerialOnlineNovelChapterLoader
    implements OnlineNovelChapterLoader {
  /// 书的解压目录；章节文件是它下面的 `OEBPS/chapter-<n>.xhtml`。
  String get extractDir;

  /// 本书正文章数；章号不小于它的文件不算本书正文。null = 不设上限。
  @protected
  int? get chapterLimit => null;

  /// 取第 [index] 章：占位页换成了正文返回结果；文件不在 / 早已是正文 / 取回
  /// 后发现书已被别处改过而放弃，返回 null；取不到抛出。只会被串行调用。
  @protected
  Future<OnlineNovelChapterLoaded?> loadChapter(int index);

  static final RegExp _chapterFilePattern = RegExp(
    r'^OEBPS/chapter-(\d+)\.xhtml$',
  );

  /// 进程内唯一的临时文件序号：同一本书可能同时有两个加载器实例（阅读器开着 +
  /// 作品页就地重建），固定的 `.part` 名会互踩。
  static int _tempSeq = 0;

  final Map<int, _ChapterJob> _jobs = <int, _ChapterJob>{};
  final List<_ChapterJob> _pending = <_ChapterJob>[];
  Future<void>? _draining;
  bool _disposed = false;

  /// 排队中的取章（含后台预取）全部结束。
  @visibleForTesting
  Future<void> whenIdle() async {
    Future<void>? draining;
    while ((draining = _draining) != null) {
      await draining;
    }
  }

  @override
  int? chapterIndexForFile(String filePath) {
    final String relative = p
        .relative(p.normalize(filePath), from: p.normalize(extractDir))
        .replaceAll(r'\', '/');
    final RegExpMatch? match = _chapterFilePattern.firstMatch(relative);
    if (match == null) return null;
    final int index = int.parse(match.group(1)!) - 1;
    final int? limit = chapterLimit;
    if (index < 0 || (limit != null && index >= limit)) return null;
    return index;
  }

  /// 排队取第 [index] 章。同一章已在排队 / 在取时共用那一次的结果。
  /// [background] = 后台预取（见 [_ChapterJob.background]）。
  @protected
  Future<OnlineNovelChapterLoaded?> ensureChapter(
    int index, {
    bool background = false,
  }) {
    final _ChapterJob? existing = _jobs[index];
    if (existing != null) {
      if (!background) existing.background = false;
      return existing.completer.future;
    }
    if (_disposed) return Future<OnlineNovelChapterLoaded?>.value();
    final _ChapterJob job = _ChapterJob(index, background: background);
    _jobs[index] = job;
    _pending.add(job);
    _draining ??= _drain();
    return job.completer.future;
  }

  _ChapterJob _takeNext() {
    final int foreground = _pending.indexWhere(
      (_ChapterJob job) => !job.background,
    );
    return _pending.removeAt(foreground < 0 ? 0 : foreground);
  }

  Future<void> _drain() async {
    // 先让出一拍再开工：调用方拿到 future 之后、第一章开取之前，`_draining`
    // 必须已经赋上值（[loadChapter] 同步跑完也不例外）。
    await null;
    while (_pending.isNotEmpty) {
      final _ChapterJob job = _takeNext();
      try {
        job.completer.complete(await loadChapter(job.index));
      } on Object catch (error, stack) {
        job.completer.completeError(error, stack);
      } finally {
        _jobs.remove(job.index);
      }
    }
    _draining = null;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final _ChapterJob job in _pending) {
      _jobs.remove(job.index);
      job.completer.complete(null);
    }
    _pending.clear();
  }

  /// 先写临时文件再改名：阅读器读到的要么是旧文件，要么是完整的新文件。
  @protected
  Future<void> writeAtomically(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final File temp = File('${target.path}.${++_tempSeq}.part');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
    } on Object {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }
}
